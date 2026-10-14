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
  /// 20 分钟倒计时正常走完
  completed,

  /// 中途醒来后长时间没有重新入睡，提前结束
  wokeUp,
}

/// 入睡判定严格度
enum Strictness {
  /// 宽松：静止 2 分钟，容忍轻微动静
  relaxed,

  /// 标准：静止 3 分钟（推荐）
  standard,

  /// 严格：静止 4 分钟，几乎不动才算入睡
  strict,
}

/// 麦克风状态
enum MicStatus { off, starting, active, denied, error }

/// 内核控制器：传感器融合入睡判定、醒来监测、倒计时、音频、屏幕常亮。
///
/// 入睡判定（融合三路信号）：
///  1. 体动：加速度计，连续静止达到"所需静止时长"（硬性条件）
///  2. 环境声：最近 20 秒没有突发声音（说话/咳嗽等），否则暂缓判定
///  3. 呼吸声：检测到规律呼吸节律时，所需静止时长缩短为 67%
/// 若麦克风不可用，则自动退化为只用体动判断。
///
/// 午休中持续用加速度计监测"醒来"：连续多秒出现强烈动作（起身、拿起手机），
/// 则暂停倒计时并重新检测入睡；单次翻身不会被误判为醒来。
class NapController extends ChangeNotifier {
  // ───────────────────────── 固定参数 ─────────────────────────

  /// 午休时长（20 分钟）
  static const int napSeconds = 1200;

  /// 标准重力加速度 (m/s²)
  static const double _gravity = 9.80665;

  /// 醒来判定：强烈动作的偏差阈值（高于入睡检测的体动阈值，翻身不会触发）
  static const double wakeDeviation = 1.2;
  static const double wakeDelta = 0.8;

  /// 醒来判定：在最近 10 秒内，至少有 5 个"秒"存在强烈动作
  static const int wakeWindowSeconds = 10;
  static const int wakeBucketsNeeded = 5;

  /// 醒来后超过 10 分钟仍未重新入睡，则提前结束本次午休
  static const int resumeTimeoutSeconds = 600;

  /// 检测到规律呼吸时，所需静止时长的缩放系数
  static const double breathingFactor = 0.67;

  /// 环境声"安静"的判定窗口（秒）
  static const int quietWindowSeconds = 20;

  /// 静止时间超过"所需时长 × 该系数"时，忽略环境声条件
  /// （防止在嘈杂环境里永远无法入睡）
  static const double audioGateOverrideFactor = 1.5;

  // ───────────────────────── 用户设置 ─────────────────────────

  Strictness _strictness = Strictness.standard;
  bool _whiteNoise = true; // 入睡后播放白噪音
  bool _useMic = true; // 检测阶段使用麦克风辅助

  Strictness get strictness => _strictness;
  bool get whiteNoiseEnabled => _whiteNoise;
  bool get micEnabled => _useMic;

  /// 当前严格度下，基础的"所需静止秒数"
  int get requiredStillSeconds {
    switch (_strictness) {
      case Strictness.relaxed:
        return 120;
      case Strictness.standard:
        return 180;
      case Strictness.strict:
        return 240;
    }
  }

  /// 体动判定：合加速度偏离重力的阈值（越小越敏感）
  double get _motionDeviationThreshold {
    switch (_strictness) {
      case Strictness.relaxed:
        return 0.8;
      case Strictness.standard:
        return 0.5;
      case Strictness.strict:
        return 0.3;
    }
  }

  /// 体动判定：相邻采样变化阈值
  double get _motionDeltaThreshold {
    switch (_strictness) {
      case Strictness.relaxed:
        return 0.5;
      case Strictness.standard:
        return 0.3;
      case Strictness.strict:
        return 0.2;
    }
  }

  // ───────────────────────── 内部状态 ─────────────────────────

  NapPhase _phase = NapPhase.idle;
  NapEndReason? _endReason;
  bool _resuming = false; // 是否处于"醒来后重新入睡"的检测中
  int _wakeCount = 0;
  int _motionStillSeconds = 0;
  int _remainingSeconds = napSeconds;
  double _detectProgress = 0.0;
  bool _audioQuiet = true;
  bool _breathing = false;
  MicStatus _micStatus = MicStatus.off;
  String? _errorMessage;
  bool _disposed = false;

  DateTime _lastMotionAt = DateTime.now();
  DateTime? _resumeStartedAt;
  DateTime? _napEndAt;
  double? _lastMagnitude;

  /// 当前这一秒内是否出现过强烈动作
  bool _strongMotionThisSecond = false;

  /// 最近 N 秒的"强烈动作"滑动窗口
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
      final int idx = (p.getInt('strictness') ?? 1).clamp(0, 2);
      _strictness = Strictness.values[idx];
      _whiteNoise = p.getBool('whiteNoise') ?? true;
      _useMic = p.getBool('useMic') ?? true;
      _safeNotify();
    } catch (e) {
      debugPrint('Load settings failed: $e');
    }
  }

  /// 仅在空闲/结束状态下允许修改设置
  Future<void> updateSettings({
    Strictness? strictness,
    bool? whiteNoise,
    bool? useMic,
  }) async {
    if (_phase == NapPhase.detecting || _phase == NapPhase.napping) return;
    if (strictness != null) _strictness = strictness;
    if (whiteNoise != null) _whiteNoise = whiteNoise;
    if (useMic != null) _useMic = useMic;
    _safeNotify();

    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setInt('strictness', _strictness.index);
      await p.setBool('whiteNoise', _whiteNoise);
      await p.setBool('useMic', _useMic);
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
    _motionStillSeconds = 0;
    _remainingSeconds = napSeconds;
    _detectProgress = 0.0;
    _audioQuiet = true;
    _breathing = false;
    _napEndAt = null;
    _resumeStartedAt = null;
    _lastMagnitude = null;
    _strongMotionThisSecond = false;
    _wakeWindow.clear();
    _lastMotionAt = DateTime.now();
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

  // ───────────────────────── 加速度计 ─────────────────────────

  void _startAccelerometer() {
    _accelSub?.cancel();
    _accelSub = accelerometerEventStream(
      samplingPeriod: SensorInterval.normalInterval,
    ).listen(
      _onAccelerometer,
      onError: (Object error) {
        _errorMessage = '无法读取加速度计 / Accelerometer unavailable';
        unawaited(cancel());
      },
      cancelOnError: true,
    );
  }

  /// 每次采样：同一路数据，在不同阶段用于不同目的
  ///  - 检测阶段：判断"是否有体动"，用于重置静止计时
  ///  - 午休阶段：判断"是否有强烈动作"，用于醒来监测
  void _onAccelerometer(AccelerometerEvent e) {
    final double magnitude = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    final double deviation = (magnitude - _gravity).abs();
    final double delta =
        _lastMagnitude == null ? 0.0 : (magnitude - _lastMagnitude!).abs();
    _lastMagnitude = magnitude;

    if (_phase == NapPhase.detecting) {
      if (deviation > _motionDeviationThreshold ||
          delta > _motionDeltaThreshold) {
        _lastMotionAt = DateTime.now();
      }
    } else if (_phase == NapPhase.napping) {
      if (deviation > wakeDeviation || delta > wakeDelta) {
        _strongMotionThisSecond = true;
      }
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

  /// 检测阶段：融合体动、环境声、呼吸三路信号
  void _tickDetecting(DateTime now) {
    final int still = now.difference(_lastMotionAt).inSeconds;
    _motionStillSeconds = still;

    final bool micOn = _micStatus == MicStatus.active;
    _audioQuiet = !micOn || _analyzer.isQuiet(quietWindowSeconds);
    _breathing = micOn && _analyzer.breathingDetected;

    final int base = requiredStillSeconds;
    final int required = effectiveRequiredSeconds;

    // 条件：体动静止达标，且（环境安静，或已静止足够久而忽略环境声）
    final bool motionOk = still >= required;
    final bool audioOk =
        _audioQuiet || still >= (base * audioGateOverrideFactor).round();

    if (motionOk && audioOk) {
      _enterNapping(now);
      return;
    }

    // 进度条：体动达标但环境声未达标时停在 99%
    _detectProgress = motionOk ? 0.99 : (still / required).clamp(0.0, 0.99);

    // 醒来后长时间没有重新入睡 → 提前结束
    final DateTime? resumedAt = _resumeStartedAt;
    if (_resuming &&
        resumedAt != null &&
        now.difference(resumedAt).inSeconds >= resumeTimeoutSeconds) {
      unawaited(_finish(NapEndReason.wokeUp));
      return;
    }

    _safeNotify();
  }

  /// 午休阶段：更新倒计时，并监测是否醒来
  void _tickNapping(DateTime now) {
    // 1) 醒来监测：记录这一秒是否有强烈动作，维护滑动窗口
    _wakeWindow.addLast(_strongMotionThisSecond);
    _strongMotionThisSecond = false;
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
      _onWakeDetected(now);
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
    _strongMotionThisSecond = false;
    _safeNotify();

    // 入睡后关闭麦克风（省电、保护隐私），并开始播放白噪音
    unawaited(_stopMic());
    if (_whiteNoise) {
      unawaited(_startNoise());
    }
  }

  /// 午休中检测到醒来 → 暂停倒计时，回到检测阶段等待重新入睡
  void _onWakeDetected(DateTime now) {
    _wakeCount++;
    _phase = NapPhase.detecting;
    _resuming = true;
    _resumeStartedAt = now;
    _lastMotionAt = now;
    _motionStillSeconds = 0;
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
