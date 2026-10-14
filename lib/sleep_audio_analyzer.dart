import 'dart:math' as math;
import 'dart:typed_data';

/// 麦克风音频分析器（纯内存、实时处理，不保存任何音频）
///
/// 输入：16kHz / 单声道 / 16-bit PCM 字节流。
/// 输出两类线索：
///  1. 环境声突发（说话、咳嗽、翻动被子等）→ [isQuiet] 判断最近是否安静
///  2. 呼吸节律：对"每 100ms 的音量包络"做自相关，
///     若在 2~7 秒周期内出现稳定的周期性，则认为检测到规律呼吸 → [breathingDetected]
class SleepAudioAnalyzer {
  /// 采样率（需与 RecordConfig 保持一致）
  static const int sampleRate = 16000;

  /// 每帧 100ms = 1600 个采样点
  static const int frameSamples = 1600;

  /// 呼吸分析窗口：400 帧 = 40 秒
  static const int windowFrames = 400;

  /// 至少积累 30 秒包络才开始分析呼吸
  static const int minFramesForBreathing = 300;

  /// 呼吸周期搜索范围：2.0s ~ 7.0s（约 8.5 ~ 30 次/分钟）
  static const int minLag = 20;
  static const int maxLag = 70;

  /// 前 5 秒为基线学习期，不判定突发
  static const int warmupFrames = 50;

  /// 当前音量超过基线多少倍视为"突发声音"
  static const double spikeRatio = 3.0;

  /// 突发声音的绝对音量下限（线性 RMS，约 -44 dBFS），避免极安静环境下误触发
  static const double spikeFloorRms = 0.006;

  /// 自相关峰值超过该值视为"本秒存在呼吸节律"
  static const double breathPeakThreshold = 0.30;

  /// 包络调制深度（标准差/均值）下限，过于平坦的包络不可能是呼吸
  static const double minModulationDepth = 0.05;

  /// 连续多少秒存在节律才确认为"检测到呼吸"
  static const int breathConfirmSeconds = 20;

  // ───────────────────────── 内部状态 ─────────────────────────

  final List<double> _envelope = <double>[];
  double _sumSquares = 0.0;
  int _sampleCount = 0;
  int? _carryByte; // 上一个数据块遗留的半个采样（奇数字节）
  double? _baseline;
  int _frameIndex = 0;
  DateTime? _lastSpikeAt;
  int _breathStreak = 0;

  /// 当前音量（dBFS，约 -120 ~ 0）
  double levelDb = -120.0;

  /// 是否已经收到过音频数据
  bool hasSignal = false;

  /// 是否已确认检测到规律呼吸
  bool breathingDetected = false;

  /// 最近 [seconds] 秒内是否没有突发声音
  bool isQuiet(int seconds) {
    final DateTime? t = _lastSpikeAt;
    return t == null || DateTime.now().difference(t).inSeconds >= seconds;
  }

  /// 清空所有状态（每次重新开始检测时调用）
  void reset() {
    _envelope.clear();
    _sumSquares = 0.0;
    _sampleCount = 0;
    _carryByte = null;
    _baseline = null;
    _frameIndex = 0;
    _lastSpikeAt = null;
    _breathStreak = 0;
    levelDb = -120.0;
    hasSignal = false;
    breathingDetected = false;
  }

  /// 接收一块 PCM16（小端）字节数据，块大小不限
  void addPcm16(Uint8List bytes) {
    int i = 0;

    // 先拼上上次遗留的半个采样
    if (_carryByte != null && bytes.isNotEmpty) {
      _consume(_toInt16(_carryByte!, bytes[0]));
      _carryByte = null;
      i = 1;
    }
    for (; i + 1 < bytes.length; i += 2) {
      _consume(_toInt16(bytes[i], bytes[i + 1]));
    }
    if (i < bytes.length) {
      _carryByte = bytes[i];
    }
  }

  static int _toInt16(int lo, int hi) {
    int v = lo | (hi << 8);
    if (v >= 0x8000) v -= 0x10000;
    return v;
  }

  void _consume(int sample) {
    final double d = sample / 32768.0;
    _sumSquares += d * d;
    _sampleCount++;
    if (_sampleCount >= frameSamples) {
      final double rms = math.sqrt(_sumSquares / _sampleCount);
      _sumSquares = 0.0;
      _sampleCount = 0;
      _onFrame(rms);
    }
  }

  /// 处理一帧（100ms）的 RMS 音量
  void _onFrame(double rms) {
    hasSignal = true;
    levelDb = 20.0 * math.log(rms + 1e-6) / math.ln10;

    _baseline ??= rms;
    final double baseline = _baseline!;

    final bool isSpike = _frameIndex >= warmupFrames &&
        rms > spikeFloorRms &&
        rms > baseline * spikeRatio;

    if (isSpike) {
      _lastSpikeAt = DateTime.now();
      // 突发时基线仅缓慢跟随，防止一次响动就抬高基线
      _baseline = baseline * 0.998 + rms * 0.002;
    } else {
      // 学习期更快收敛；之后以约 20 秒的时间常数跟随环境底噪
      final double alpha = _frameIndex < warmupFrames ? 0.05 : 0.005;
      _baseline = baseline * (1 - alpha) + rms * alpha;
    }

    _envelope.add(rms);
    if (_envelope.length > windowFrames) {
      _envelope.removeAt(0);
    }
    _frameIndex++;

    // 每 10 帧（1 秒）分析一次呼吸节律
    if (_frameIndex % 10 == 0) {
      _analyzeBreathing();
    }
  }

  /// 对音量包络做自相关，寻找 2~7 秒周期的稳定节律
  void _analyzeBreathing() {
    if (_envelope.length < minFramesForBreathing) {
      breathingDetected = false;
      return;
    }

    // 1) 5 点滑动平均，平滑掉高频抖动
    const int k = 5;
    final int n = _envelope.length - k + 1;
    final List<double> x = List<double>.filled(n, 0.0);
    for (int i = 0; i < n; i++) {
      double s = 0.0;
      for (int j = 0; j < k; j++) {
        s += _envelope[i + j];
      }
      x[i] = s / k;
    }

    // 2) 去均值，并计算调制深度
    double mean = 0.0;
    for (final double v in x) {
      mean += v;
    }
    mean /= n;

    double energy = 0.0;
    for (int i = 0; i < n; i++) {
      x[i] -= mean;
      energy += x[i] * x[i];
    }
    final double std = math.sqrt(energy / n);
    final double depth = mean > 1e-9 ? std / mean : 0.0;

    double peak = 0.0;
    if (energy > 1e-12 && depth >= minModulationDepth) {
      // 3) 无偏归一化自相关，取 2~7 秒滞后范围内的最大值
      final double variance = energy / n;
      for (int lag = minLag; lag <= maxLag && lag < n; lag++) {
        double acc = 0.0;
        for (int i = 0; i + lag < n; i++) {
          acc += x[i] * x[i + lag];
        }
        final double r = (acc / (n - lag)) / variance;
        if (r > peak) peak = r;
      }
    }

    // 4) 需要连续多秒都有节律才确认；中断时快速衰减
    if (peak >= breathPeakThreshold) {
      _breathStreak++;
    } else {
      _breathStreak = math.max(0, _breathStreak - 2);
    }
    breathingDetected = _breathStreak >= breathConfirmSeconds;
  }
}
