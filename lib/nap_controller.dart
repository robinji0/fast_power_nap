import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'sleep_audio_analyzer.dart';

/// 午休流程的阶段
enum NapPhase {
  /// 空闲：等待用户点击 START NAP
  idle,

  /// 检测中：等待入睡（首次入睡，或午休中醒来后的"重新入睡"）
  detecting,

  /// 午休中：已判定入睡，倒计时进行中
  napping,

  /// 结束
  finished,
}

/// 结束原因
enum NapEndReason {
  /// 倒计时正常走完
  completed,

  /// 中途醒来后长时间没有重新入睡，提前结束
  wokeUp,
}

/// 入睡敏感度：用户平时大约需要多久才能睡着
enum SleepOnset {
  /// 快：约 3 分钟（秒睡体质）
  fast,

  /// 标准：约 7 分钟
  standard,

  /// 慢：约 12 分钟（需要慢慢放松）
  slow,
}

/// 麦克风状态
enum MicStatus { off, starting, active, denied, error }

/// 内核控制器：传感器融合入睡判定、醒来监测、倒计时、音频、屏幕常亮。
///
/// 入睡判定（融合三路信号）：
///  1. 体动：加速度计，累计静止达到"所需静止时长"（硬性条件）
///  2. 环境声：最近 20 秒没有突发声音（说话/咳嗽等），否则暂缓判定
///  3. 呼吸声：检测到规律呼吸节律时，所需静止时长缩短为 67%
/// 若麦克风不可用，则自动退化为只用体动判断。
///
/// 体动容错：入睡需要的时间可能长达 12 分钟，期间翻个身很正常，所以
///  - 轻微动作（翻身）：每次只扣掉一半已累计的静止时间
///  - 大幅动作（起身、拿起手机）：静止时间清零
///
/// 午休中持续用加速度计监测"醒来"：连续多秒出现强烈动作，
/// 则暂停倒计时并重新检测入睡；单次翻身不会被误判为醒来。
class NapController extends ChangeNotifier {
  // ───────────────────────── 固定参数 ─────────────────────────

  /// 推荐的午休时长（分钟）
  static const int recommendedNapMinutes = 20;

  /// 自定义午休时长的范围（分钟）
  static const int minNapMinutes = 5;
  static const int maxNapMinutes = 90;

  /// 快捷选项（分钟）
  static const List<int> napPresets = <int>[10, 15, 20, 30, 45];

  /// 标准重力加速度 (m/s²)
  static const double _gravity = 9.80665;

  /// 轻微体动阈值：合加速度偏离重力 / 相邻采样变化
  static const double motionDeviationThreshold = 0.5;
  static const double motionDeltaThreshold = 0.3;

  /// 强烈动作阈值（高于轻微体动，用于"清零"与"醒来"判定）
  static const double wakeDeviation = 1.2;
  static const double wakeDelta = 0.8;

  /// 醒来判定：在最近 10 秒内，至少有 5 个"秒"存在强烈动作
  static const int wakeWindowSeconds = 10;
  static const int wakeBucketsNeeded = 5;

  /// 醒来后，在"所需入睡时长"之外再多给 10 分钟重新入睡，超时则提前结束
  static const int resumeExtraSeconds = 600;

  /// 检测到规律呼吸时，所需静止时长的缩放系数
  static const double breathingFactor = 0.67;

  /// 环境声"安静"的判定窗口（秒）
  static const int quietWindowSeconds = 20;

  /// 静止时间超过"所需时长 × 该系数"时，忽略环境声条件
  /// （防止在嘈杂环境里永远无法入睡）
  static const double audioGateOverrideFactor = 1.5;

  // ───────────────────────── 用户设置 ─────────────────────────

  SleepOnset _onset = SleepOnset.standard;
  int _napMinutes = recommendedNapMinutes;
  bool _whiteNoise = true; // 入睡后播放白噪音
  bool _useMic = true; // 检测阶段使用麦克风辅助
  bool _dimScreen = true; // 入睡后黑屏并调至最低亮度

  SleepOnset get onset => _onset;
  int get napMinutes => _napMinutes;
  bool get whiteNoiseEnabled => _whiteNoise;
  bool get micEnabled => _useMic;
  bool get dimScreenEnabled => _dimScreen;

  /// 午休时长（秒）
  int get napSeconds => _napMinutes * 60;

  /// 当前敏感度下，基础的"所需静止秒数"
  int get requiredStillSeconds {
    switch (_onset) {
      case SleepOnset.fast:
        return 180;
      case SleepOnset.standard:
        return 420;
      case SleepOnset.slow:
        return 720;
    }
  }

  // ───────────────────────── 内部状态 ─────────────────────────

  NapPhase _phase = NapPhase.idle;
  NapEndReason? _endReason;
  bool _resuming = false; // 是否处于"醒来后重新入睡"的检测中
  int _wakeCount = 0;
  int _motionStillSeconds = 0;
  int _remainingSeconds = recommendedNapMinutes * 60;
  double _detectProgress = 0.0;
  bool _audioQuiet = true;
  bool _breathing = false;
  MicStatus _micStatus = MicStatus.off;
  String? _errorMessage;
  bool _disposed = false;

  // 体动累计相关
  bool _inMotionEpisode = false; // 是否处于一次"体动事件"中
  int _quietRun = 0; // 连续安静的秒数（用于判断体动事件结束）
  bool _moderateInSecond = false; // 当前这一秒内是否出现轻微体动
  bool _strongInSecond = false; // 当前这一秒内是否出现强烈动作

  DateTime? _resumeStartedAt;
  DateTime? _napEndAt;
  double? _lastMagnitude;

  /// 最近 N 秒的"强烈动作"滑动窗口（午休中醒来监测）
  final Queue<bool> _wakeWindow = Queue<bool>();

  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<Uint8List>? _micSub;
  Timer? _ticker;

  final SleepAudioAnalyzer _analyzer = SleepAudioAnalyzer();
  AudioRecorder? _recorder;

  final AudioPlayer _noisePlayer = AudioPlayer();
  final AudioPlayer _alarmPlayer = AudioPlayer();
  Uint8List? _noiseBytes;
  Uint8List? _alarmBytes;

  // ───────────────────────── 对外只读属性 ─────────────────────────

  NapPhase get phase => _phase;
  NapEndReason? get endReason => _endReason;
  bool get isResuming => _resuming;
  int get wakeCount => _wakeCount;
  int get motionStillSeconds => _motionStillSeconds;
  int get remainingSeconds => _remainingSeconds;
  bool get audioQuiet => _audioQuiet;
  bool get breathing => _breathing;
  MicStatus get micStatus => _micStatus;
  String? get errorMessage => _errorMessage;

  /// 当前实际所需静止秒数（检测到呼吸时缩短）
  int get effectiveRequiredSeconds => _breathing
      ? (requiredStillSeconds * breathingFactor).round()
      : requiredStillSeconds;

  /// 入睡检测进度 0.0 ~ 1.0（条件未全部满足时最多 0.99）
  double get detectProgress => _detectProgress;

  /// 午休进度 0.0 ~ 1.0
  double get napProgress =>
      (1 - _remainingSeconds / napSeconds).clamp(0.0, 1.0).toDouble();

  /// 实际已午休的秒数（不含暂停期间）
  int get sleptSeconds => napSeconds - _remainingSeconds;

  String get remainingText => formatSeconds(_remainingSeconds);
  String get stillText => formatSeconds(_motionStillSeconds);

  static String formatSeconds(int total) {
    final int m = total ~/ 60;
    final int s = total % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // ───────────────────────── 设置读写 ─────────────────────────

  Future<void> loadSettings() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      final int idx = (p.getInt('sleepOnset') ?? 1).clamp(0, 2);
      _onset = SleepOnset.values[idx];
      _napMinutes = (p.getInt('napMinutes') ?? recommendedNapMinutes)
          .clamp(minNapMinutes, maxNapMinutes);
      _whiteNoise = p.getBool('whiteNoise') ?? true;
      _useMic = p.getBool('useMic') ?? true;
      _dimScreen = p.getBool('dimScreen') ?? true;
      if (_phase == NapPhase.idle) {
        _remainingSeconds = napSeconds;
      }
      _safeNotify();
    } catch (e) {
      debugPrint('Load settings failed: $e');
    }
  }

  /// 仅在非运行状态下允许修改设置
  Future<void> updateSettings({
    SleepOnset? onset,
    int? napMinutes,
    bool? whiteNoise,
    bool? useMic,
    bool? dimScreen,
  }) async {
    if (_phase == NapPhase.detecting || _phase == NapPhase.napping) return;

    if (onset != null) _onset = onset;
    if (napMinutes != null) {
      _napMinutes = napMinutes.clamp(minNapMinutes, maxNapMinutes);
    }
    if (whiteNoise != null) _whiteNoise = whiteNoise;
    if (useMic != null) _useMic = useMic;
    if (dimScreen != null) _dimScreen = dimScreen;

    // 空闲状态下，让主界面显示的剩余时间与新设置保持一致
    if (_phase == NapPhase.idle) {
      _remainingSeconds = napSeconds;
    }
    _safeNotify();

    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setInt('sleepOnset', _onset.index);
      await p.setInt('napMinutes', _napMinutes);
      await p.setBool('whiteNoise', _whiteNoise);
      await p.setBool('useMic', _useMic);
      await p.setBool('dimScreen', _dimScreen);
    } catch (e) {
      debugPrint('Save settings failed: $e');
    }
  }

  // ───────────────────────── 用户操作 ─────────────────────────

  /// 点击 START NAP：进入入睡检测阶段
  Future<void> start() async {
    if (_phase == NapPhase.detecting || _phase == NapPhase.napping) return;

    _errorMessage = null;
    _endReason = null;
    _resuming = false;
    _wakeCount = 0;
    _remainingSeconds = napSeconds;
    _detectProgress = 0.0;
    _audioQuiet = true;
    _breathing = false;
    _napEndAt = null;
    _resumeStartedAt = null;
    _lastMagnitude = null;
    _resetMotionTracking();
    _wakeWindow.clear();
    _phase = NapPhase.detecting;
    _safeNotify();

    // 保持屏幕常亮，防止锁屏后传感器/计时被系统暂停
    try {
      await WakelockPlus.enable();
    } catch (e) {
      debugPrint('Wakelock enable failed: $e');
    }

    _startAccelerometer();
    _startTicker();
    unawaited(_startMic());
  }

  /// 取消午休（检测中或午休中均可）
  Future<void> cancel() async {
    await _stopEverything();
    _phase = NapPhase.idle;
    _resuming = false;
    _motionStillSeconds = 0;
    _remainingSeconds = napSeconds;
    _detectProgress = 0.0;
    _safeNotify();
  }

  /// 结束页点击 DONE：回到空闲状态
  Future<void> reset() async {
    await _alarmPlayer.stop();
    _phase = NapPhase.idle;
    _endReason = null;
    _motionStillSeconds = 0;
    _remainingSeconds = napSeconds;
    _detectProgress = 0.0;
    _safeNotify();
  }

  /// 清空体动累计状态
  void _resetMotionTracking() {
    _motionStillSeconds = 0;
    _inMotionEpisode = false;
    _quietRun = 0;
    _moderateInSecond = false;
    _strongInSecond = false;
  }

  // ───────────────────────── 加速度计 ─────────────────────────

  void _startAccelerometer() {
    _accelSub?.cancel();
    _accelSub = accelerometerEventStream(
      samplingPeriod: SensorInterval.normalInterval,
    ).listen(
      _onAccelerometer,
      onError: (Object error) {
        _errorMessage = 'Accelerometer unavailable on this device';
        unawaited(cancel());
      },
      cancelOnError: true,
    );
  }

  /// 每次采样：同一路数据，在不同阶段用于不同目的
  ///  - 检测阶段：区分"轻微体动"和"强烈动作"，供每秒的累计逻辑使用
  ///  - 午休阶段：只关心"强烈动作"，用于醒来监测
  void _onAccelerometer(AccelerometerEvent e) {
    final double magnitude = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    final double deviation = (magnitude - _gravity).abs();
    final double delta =
        _lastMagnitude == null ? 0.0 : (magnitude - _lastMagnitude!).abs();
    _lastMagnitude = magnitude;

    final bool strong = deviation > wakeDeviation || delta > wakeDelta;
    final bool moderate = deviation > motionDeviationThreshold ||
        delta > motionDeltaThreshold;

    if (_phase == NapPhase.detecting) {
      if (strong) _strongInSecond = true;
      if (moderate) _moderateInSecond = true;
    } else if (_phase == NapPhase.napping) {
      if (strong) _strongInSecond = true;
    }
  }

  // ───────────────────────── 麦克风 ─────────────────────────

  Future<void> _startMic() async {
    if (!_useMic) {
      _micStatus = MicStatus.off;
      _safeNotify();
      return;
    }
    if (_micSub != null) return;

    _analyzer.reset();
    _micStatus = MicStatus.starting;
    _safeNotify();

    try {
      _recorder ??= AudioRecorder();
      final bool granted = await _recorder!.hasPermission();
      if (!granted) {
        _micStatus = MicStatus.denied;
        _safeNotify();
        return;
      }
      // 授权弹窗期间用户可能已取消
      if (_disposed || _phase != NapPhase.detecting) {
        _micStatus = MicStatus.off;
        return;
      }

      final Stream<Uint8List> stream = await _recorder!.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: SleepAudioAnalyzer.sampleRate,
          numChannels: 1,
        ),
      );

      if (_disposed || _phase != NapPhase.detecting) {
        await _recorder!.stop();
        _micStatus = MicStatus.off;
        return;
      }

      _micSub = stream.listen(
        _analyzer.addPcm16,
        onError: (Object e) {
          debugPrint('Mic stream error: $e');
          _micStatus = MicStatus.error;
          _safeNotify();
        },
        cancelOnError: true,
      );
      _micStatus = MicStatus.active;
      _safeNotify();
    } catch (e) {
      // 麦克风失败不影响核心流程，自动退化为只用体动判断
      debugPrint('Mic start failed: $e');
      _micStatus = MicStatus.error;
      _safeNotify();
    }
  }

  Future<void> _stopMic() async {
    await _micSub?.cancel();
    _micSub = null;
    try {
      final AudioRecorder? r = _recorder;
      if (r != null && await r.isRecording()) {
        await r.stop();
      }
    } catch (e) {
      debugPrint('Mic stop failed: $e');
    }
    _micStatus = MicStatus.off;
    _breathing = false;
  }

  // ───────────────────────── 统一的 1 秒定时器 ─────────────────────────

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  void _onTick() {
    if (_disposed) return;
    final DateTime now = DateTime.now();

    if (_phase == NapPhase.detecting) {
      _tickDetecting(now);
    } else if (_phase == NapPhase.napping) {
      _tickNapping(now);
    }
  }

  /// 检测阶段：累计静止时间，并融合体动、环境声、呼吸三路信号
  void _tickDetecting(DateTime now) {
    // 1) 更新累计静止秒数（带容错）
    if (_strongInSecond) {
      // 大幅动作：清零
      _motionStillSeconds = 0;
      _inMotionEpisode = true;
      _quietRun = 0;
    } else if (_moderateInSecond) {
      // 轻微体动（如翻身）：每次体动事件只扣一半，持续动作期间不继续累计也不再扣
      if (!_inMotionEpisode) {
        _motionStillSeconds = _motionStillSeconds ~/ 2;
        _inMotionEpisode = true;
      }
      _quietRun = 0;
    } else {
      _quietRun++;
      if (_quietRun >= 3) {
        _inMotionEpisode = false; // 连续 3 秒安静，视为本次体动结束
      }
      _motionStillSeconds++;
    }
    _strongInSecond = false;
    _moderateInSecond = false;

    // 2) 融合麦克风信号
    final bool micOn = _micStatus == MicStatus.active;
    _audioQuiet = !micOn || _analyzer.isQuiet(quietWindowSeconds);
    _breathing = micOn && _analyzer.breathingDetected;

    final int base = requiredStillSeconds;
    final int required = effectiveRequiredSeconds;
    final int still = _motionStillSeconds;

    // 条件：静止累计达标，且（环境安静，或已静止足够久而忽略环境声）
    final bool motionOk = still >= required;
    final bool audioOk =
        _audioQuiet || still >= (base * audioGateOverrideFactor).round();

    if (motionOk && audioOk) {
      _enterNapping(now);
      return;
    }

    // 进度条：静止达标但环境声未达标时停在 99%
    _detectProgress = motionOk ? 0.99 : (still / required).clamp(0.0, 0.99);

    // 醒来后长时间没有重新入睡 → 提前结束
    final DateTime? resumedAt = _resumeStartedAt;
    if (_resuming &&
        resumedAt != null &&
        now.difference(resumedAt).inSeconds >=
            requiredStillSeconds + resumeExtraSeconds) {
      unawaited(_finish(NapEndReason.wokeUp));
      return;
    }

    _safeNotify();
  }

  /// 午休阶段：更新倒计时，并监测是否醒来
  void _tickNapping(DateTime now) {
    // 1) 醒来监测：记录这一秒是否有强烈动作，维护滑动窗口
    _wakeWindow.addLast(_strongInSecond);
    _strongInSecond = false;
    while (_wakeWindow.length > wakeWindowSeconds) {
      _wakeWindow.removeFirst();
    }
    final int strongSeconds = _wakeWindow.where((bool b) => b).length;

    // 2) 更新剩余时间（基于墙上时间，避免 Timer 漂移）
    final int leftMs = _napEndAt!.difference(now).inMilliseconds;
    _remainingSeconds = math.max(0, (leftMs / 1000).ceil());

    if (leftMs <= 0) {
      unawaited(_finish(NapEndReason.completed));
      return;
    }

    if (strongSeconds >= wakeBucketsNeeded) {
      _onWakeDetected();
      return;
    }
    _safeNotify();
  }

  /// 判定入睡 → 开始（或继续）倒计时
  void _enterNapping(DateTime now) {
    _phase = NapPhase.napping;
    _resuming = false;
    _resumeStartedAt = null;
    _detectProgress = 1.0;
    _napEndAt = now.add(Duration(seconds: _remainingSeconds));
    _wakeWindow.clear();
    _strongInSecond = false;
    _safeNotify();

    // 入睡后关闭麦克风（省电、保护隐私），并开始播放白噪音
    unawaited(_stopMic());
    if (_whiteNoise) {
      unawaited(_startNoise());
    }
  }

  /// 午休中检测到醒来 → 暂停倒计时，回到检测阶段等待重新入睡
  void _onWakeDetected() {
    _wakeCount++;
    _phase = NapPhase.detecting;
    _resuming = true;
    _resumeStartedAt = DateTime.now();
    _resetMotionTracking();
    _detectProgress = 0.0;
    _audioQuiet = true;
    _breathing = false;
    _safeNotify();

    unawaited(_noisePlayer.stop());
    unawaited(_startMic());
  }

  /// 结束：停止一切，必要时播放提示音
  Future<void> _finish(NapEndReason reason) async {
    _ticker?.cancel();
    _ticker = null;
    _phase = NapPhase.finished;
    _endReason = reason;
    _resuming = false;
    if (reason == NapEndReason.completed) {
      _remainingSeconds = 0;
    }
    _safeNotify();

    await _accelSub?.cancel();
    _accelSub = null;
    await _stopMic();

    try {
      await _noisePlayer.stop();
    } catch (e) {
      debugPrint('Noise stop failed: $e');
    }
    if (reason == NapEndReason.completed) {
      await _playAlarm();
    }

    try {
      await WakelockPlus.disable();
    } catch (e) {
      debugPrint('Wakelock disable failed: $e');
    }
    _safeNotify();
  }

  // ───────────────────────── 音频播放 ─────────────────────────

  Future<void> _startNoise() async {
    try {
      _noiseBytes ??= _buildBrownNoiseWav();
      await _noisePlayer.setReleaseMode(ReleaseMode.loop);
      await _noisePlayer.play(BytesSource(_noiseBytes!), volume: 0.35);
    } catch (e) {
      debugPrint('Noise playback failed: $e');
    }
  }

  Future<void> _playAlarm() async {
    try {
      _alarmBytes ??= _buildAlarmWav();
      await _alarmPlayer.setReleaseMode(ReleaseMode.release);
      await _alarmPlayer.play(BytesSource(_alarmBytes!), volume: 0.9);
    } catch (e) {
      debugPrint('Alarm playback failed: $e');
    }
  }

  /// 合成 4 秒可无缝循环的布朗噪音（低沉柔和，适合助眠）
  static Uint8List _buildBrownNoiseWav() {
    const int sampleRate = 22050;
    const int total = sampleRate * 4;
    const int crossfade = 4410; // 0.2 秒首尾交叉淡化，消除循环接缝爆音
    final math.Random rnd = math.Random(42);

    final List<double> raw = List<double>.filled(total, 0.0);
    double last = 0.0;
    double peak = 0.0;
    for (int i = 0; i < total; i++) {
      final double white = rnd.nextDouble() * 2 - 1;
      last = (last + 0.02 * white) / 1.02;
      raw[i] = last;
      if (last.abs() > peak) peak = last.abs();
    }

    final int outLen = total - crossfade;
    final Int16List samples = Int16List(outLen);
    for (int i = 0; i < outLen; i++) {
      double v = raw[i];
      if (i < crossfade) {
        final double t = i / crossfade;
        v = raw[total - crossfade + i] * (1 - t) + raw[i] * t;
      }
      samples[i] = ((v / peak) * 0.8 * 32767).round();
    }
    return _buildWav(samples, sampleRate);
  }

  /// 合成温柔的三音上行提示音（C5 → E5 → G5）
  static Uint8List _buildAlarmWav() {
    const int sampleRate = 22050;
    const List<double> freqs = <double>[523.25, 659.25, 783.99];
    const double toneSeconds = 0.6;
    final int perTone = (sampleRate * toneSeconds).round();
    final Int16List samples = Int16List(perTone * freqs.length);

    for (int n = 0; n < freqs.length; n++) {
      for (int i = 0; i < perTone; i++) {
        final double t = i / sampleRate;
        final double envelope = math.sin(math.pi * i / perTone);
        final double v = math.sin(2 * math.pi * freqs[n] * t) * envelope * 0.5;
        samples[n * perTone + i] = (v * 32767).round();
      }
    }
    return _buildWav(samples, sampleRate);
  }

  /// 把 16-bit 单声道 PCM 采样封装为标准 WAV 字节流
  static Uint8List _buildWav(Int16List samples, int sampleRate) {
    final int dataLen = samples.length * 2;
    final ByteData bd = ByteData(44 + dataLen);

    void writeStr(int offset, String s) {
      for (int i = 0; i < s.length; i++) {
        bd.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    writeStr(0, 'RIFF');
    bd.setUint32(4, 36 + dataLen, Endian.little);
    writeStr(8, 'WAVE');
    writeStr(12, 'fmt ');
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, 1, Endian.little); // PCM
    bd.setUint16(22, 1, Endian.little); // 单声道
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, sampleRate * 2, Endian.little);
    bd.setUint16(32, 2, Endian.little);
    bd.setUint16(34, 16, Endian.little);
    writeStr(36, 'data');
    bd.setUint32(40, dataLen, Endian.little);
    for (int i = 0; i < samples.length; i++) {
      bd.setInt16(44 + i * 2, samples[i], Endian.little);
    }
    return bd.buffer.asUint8List();
  }

  // ───────────────────────── 资源释放 ─────────────────────────

  /// 停止传感器、麦克风、定时器、音频，并释放屏幕常亮
  Future<void> _stopEverything() async {
    _ticker?.cancel();
    _ticker = null;

    await _accelSub?.cancel();
    _accelSub = null;

    await _stopMic();

    try {
      await _noisePlayer.stop();
      await _alarmPlayer.stop();
    } catch (e) {
      debugPrint('Audio stop failed: $e');
    }

    try {
      await WakelockPlus.disable();
    } catch (e) {
      debugPrint('Wakelock disable failed: $e');
    }
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _ticker = null;
    _accelSub?.cancel();
    _accelSub = null;
    _micSub?.cancel();
    _micSub = null;
    _recorder?.dispose();
    _recorder = null;
    _noisePlayer.dispose();
    _alarmPlayer.dispose();
    WakelockPlus.disable();
    super.dispose();
  }
}
