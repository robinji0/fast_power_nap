import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';

import 'main.dart' show FastPowerNapApp;
import 'nap_controller.dart';

/// 信号指示灯的状态
enum _SignalState { on, pending, off }

/// 屏幕亮度模式
enum _DimLevel {
  /// 正常：恢复系统亮度与系统栏
  off,

  /// 黑屏：亮度调到最低 + 纯黑覆盖层 + 沉浸模式
  dark,

  /// 临时查看：轻触黑屏后短暂显示界面（仍保持极低亮度）
  peek,
}

/// 主界面：一个巨大的圆形按钮 + 状态文案 + 倒计时 + 检测信号指示
class NapHomePage extends StatefulWidget {
  const NapHomePage({super.key});

  @override
  State<NapHomePage> createState() => _NapHomePageState();
}

class _NapHomePageState extends State<NapHomePage>
    with SingleTickerProviderStateMixin {
  late final NapController _controller;

  /// 检测阶段的"呼吸"脉冲动画
  late final AnimationController _pulse;
  late final Animation<double> _pulseScale;

  /// 黑屏模式状态
  _DimLevel _dimLevel = _DimLevel.off;
  bool _peeking = false;
  Timer? _peekTimer;

  static const Color _accent = FastPowerNapApp.accent;

  /// 轻触黑屏后临时显示界面的时长
  static const Duration _peekDuration = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _controller = NapController();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    _pulseScale = Tween<double>(begin: 0.96, end: 1.04).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
    _controller.addListener(_onControllerChanged);
    _controller.loadSettings(); // 读取上次保存的设置
  }

  void _onControllerChanged() {
    _syncPulse();
    _syncDim();
  }

  /// 仅在检测阶段运行脉冲动画，其余阶段停止以省电
  void _syncPulse() {
    if (_controller.phase == NapPhase.detecting) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      if (_pulse.isAnimating) _pulse.stop();
      _pulse.value = 0.5;
    }
  }

  // ───────────────────────── 黑屏模式 ─────────────────────────

  /// 是否应处于黑屏（午休中 + 设置开启）
  bool get _wantDim =>
      _controller.phase == NapPhase.napping && _controller.dimScreenEnabled;

  /// 根据控制器状态同步亮度模式
  void _syncDim() {
    final bool wantDim = _wantDim;
    if (!wantDim) {
      _peeking = false;
      _peekTimer?.cancel();
    }
    final _DimLevel target =
        !wantDim ? _DimLevel.off : (_peeking ? _DimLevel.peek : _DimLevel.dark);
    if (target == _dimLevel) return;
    _dimLevel = target;
    _applyDimLevel(target);
  }

  Future<void> _applyDimLevel(_DimLevel level) async {
    try {
      switch (level) {
        case _DimLevel.dark:
          await SystemChrome.setEnabledSystemUIMode(
            SystemUiMode.immersiveSticky,
          );
          await ScreenBrightness.instance.setApplicationScreenBrightness(0.0);
          break;
        case _DimLevel.peek:
          await ScreenBrightness.instance.setApplicationScreenBrightness(0.1);
          break;
        case _DimLevel.off:
          await ScreenBrightness.instance.resetApplicationScreenBrightness();
          await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
          break;
      }
    } catch (e) {
      // 亮度调节失败不应影响午休流程
      debugPrint('Apply dim level failed: $e');
    }
  }

  /// 轻触黑屏：临时显示界面 5 秒，然后自动恢复黑屏
  void _onOverlayTap() {
    setState(() => _peeking = true);
    _syncDim();
    _peekTimer?.cancel();
    _peekTimer = Timer(_peekDuration, () {
      if (!mounted) return;
      setState(() => _peeking = false);
      _syncDim();
    });
  }

  @override
  void dispose() {
    _peekTimer?.cancel();
    _controller.removeListener(_onControllerChanged);
    _pulse.dispose();
    _controller.dispose(); // 内部销毁 Timer / 传感器与麦克风订阅 / 播放器
    // 退出页面时确保亮度与系统栏恢复正常
    _applyDimLevel(_DimLevel.off);
    super.dispose();
  }

  // ───────────────────────── 文案 ─────────────────────────

  String _title() {
    switch (_controller.phase) {
      case NapPhase.idle:
        return '请将手机平放在枕头旁';
      case NapPhase.detecting:
        return _controller.isResuming ? '检测到你醒来了，计时已暂停' : '正在等待入睡检测';
      case NapPhase.napping:
        return '正在进行 ${_controller.napMinutes} 分钟深度恢复';
      case NapPhase.finished:
        return _controller.endReason == NapEndReason.completed
            ? '午休结束，精力已充电'
            : '午休提前结束';
    }
  }

  String _subtitle() {
    switch (_controller.phase) {
      case NapPhase.idle:
        return 'Place your phone flat beside your pillow';
      case NapPhase.detecting:
        return _controller.isResuming
            ? 'Awake detected. Timer paused.'
            : 'Waiting for sleep detection';
      case NapPhase.napping:
        return '${_controller.napMinutes}-minute deep recovery in progress';
      case NapPhase.finished:
        return _controller.endReason == NapEndReason.completed
            ? 'Nap complete. Recharged.'
            : 'Session ended early';
    }
  }

  // ───────────────────────── 构建 ─────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: _controller,
        builder: (BuildContext context, Widget? _) {
          final NapPhase phase = _controller.phase;
          final bool showDarkOverlay = _wantDim && !_peeking;

          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    children: <Widget>[
                      const SizedBox(height: 36),
                      const Text(
                        'FAST POWER NAP',
                        style: TextStyle(
                          fontSize: 13,
                          letterSpacing: 5,
                          color: Colors.white38,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(flex: 2),
                      _buildStatusText(phase),
                      const Spacer(flex: 2),
                      _buildMainCircle(phase),
                      const Spacer(flex: 2),
                      _buildBottomArea(phase),
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
              // 入睡后的纯黑覆盖层（OLED 屏幕黑色像素不发光）
              if (showDarkOverlay)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _onOverlayTap,
                    child: const ColoredBox(color: Colors.black),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// 顶部状态文案（中文主文案 + 英文副文案）
  Widget _buildStatusText(NapPhase phase) {
    final String title = _title();
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 400),
      child: Column(
        key: ValueKey<String>('$phase-$title'),
        children: <Widget>[
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _subtitle(),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: Colors.white38),
          ),
        ],
      ),
    );
  }

  /// 巨大的居中圆形按钮 / 倒计时显示区
  Widget _buildMainCircle(NapPhase phase) {
    double? ringValue;
    if (phase == NapPhase.detecting) {
      ringValue = _controller.detectProgress;
    } else if (phase == NapPhase.napping) {
      ringValue = _controller.napProgress;
    } else if (phase == NapPhase.finished) {
      ringValue = 1.0;
    }

    final bool tappable = phase == NapPhase.idle || phase == NapPhase.finished;

    return SizedBox(
      width: 300,
      height: 300,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          if (ringValue != null)
            SizedBox(
              width: 296,
              height: 296,
              child: CircularProgressIndicator(
                value: ringValue,
                strokeWidth: 3,
                backgroundColor: const Color(0x1AFFFFFF),
                valueColor: const AlwaysStoppedAnimation<Color>(_accent),
              ),
            ),
          ScaleTransition(
            scale: phase == NapPhase.detecting
                ? _pulseScale
                : const AlwaysStoppedAnimation<double>(1.0),
            child: GestureDetector(
              onTap: !tappable
                  ? null
                  : () {
                      if (phase == NapPhase.idle) {
                        _controller.start();
                      } else {
                        _controller.reset();
                      }
                    },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeOut,
                width: 250,
                height: 250,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const RadialGradient(
                    colors: <Color>[Color(0xFF1B2440), Color(0xFF0B0F1E)],
                  ),
                  border: Border.all(
                    color: phase == NapPhase.idle
                        ? _accent
                        : const Color(0x33FFFFFF),
                    width: 1.5,
                  ),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: _accent.withAlpha(
                        phase == NapPhase.napping ? 40 : 70,
                      ),
                      blurRadius: phase == NapPhase.idle ? 50 : 30,
                      spreadRadius: phase == NapPhase.idle ? 4 : 0,
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  child: _buildCircleContent(phase),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 圆内内容：随阶段变化
  Widget _buildCircleContent(NapPhase phase) {
    switch (phase) {
      case NapPhase.idle:
        return const Text(
          'START NAP',
          key: ValueKey<String>('idle'),
          style: TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w700,
            letterSpacing: 3,
            color: Colors.white,
          ),
        );
      case NapPhase.detecting:
        if (_controller.isResuming) {
          // 醒来后暂停：显示暂停图标与保留的剩余时间
          return Column(
            key: const ValueKey<String>('paused'),
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.pause_circle_outline, size: 44, color: _accent),
              const SizedBox(height: 10),
              const Text(
                'PAUSED',
                style: TextStyle(
                  fontSize: 16,
                  letterSpacing: 4,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _controller.remainingText,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w300,
                  color: Colors.white54,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
            ],
          );
        }
        return const Column(
          key: ValueKey<String>('detecting'),
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.bedtime_outlined, size: 44, color: _accent),
            SizedBox(height: 14),
            Text(
              'DETECTING',
              style: TextStyle(
                fontSize: 16,
                letterSpacing: 4,
                color: Colors.white70,
              ),
            ),
          ],
        );
      case NapPhase.napping:
        return FittedBox(
          key: const ValueKey<String>('napping'),
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              _controller.remainingText,
              style: const TextStyle(
                fontSize: 76,
                fontWeight: FontWeight.w200,
                color: Colors.white,
                fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
        );
      case NapPhase.finished:
        final bool completed = _controller.endReason == NapEndReason.completed;
        return Column(
          key: const ValueKey<String>('finished'),
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              completed ? Icons.wb_sunny_outlined : Icons.check_circle_outline,
              size: 48,
              color: _accent,
            ),
            const SizedBox(height: 14),
            Text(
              completed ? 'WAKE UP' : 'DONE',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                letterSpacing: 4,
                color: Colors.white,
              ),
            ),
          ],
        );
    }
  }

  // ───────────────────────── 底部区域 ─────────────────────────

  Widget _buildBottomArea(NapPhase phase) {
    return SizedBox(
      height: 120,
      child: Column(
        children: <Widget>[
          if (_controller.errorMessage != null)
            Text(
              _controller.errorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Color(0xFFFF8A80)),
            )
          else
            ..._buildInfo(phase),
          const SizedBox(height: 10),
          if (phase == NapPhase.detecting || phase == NapPhase.napping)
            TextButton(
              onPressed: _controller.cancel,
              child: const Text(
                'CANCEL',
                style: TextStyle(letterSpacing: 3, fontSize: 13),
              ),
            ),
          if (phase == NapPhase.idle)
            TextButton.icon(
              onPressed: _openSettings,
              icon: const Icon(Icons.tune, size: 16),
              label: const Text(
                'SETTINGS',
                style: TextStyle(letterSpacing: 3, fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }

  /// 各阶段的辅助信息
  List<Widget> _buildInfo(NapPhase phase) {
    const TextStyle infoStyle = TextStyle(
      fontSize: 14,
      color: Colors.white54,
      fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
    );

    switch (phase) {
      case NapPhase.idle:
        return <Widget>[
          Text(
            '入睡判定约 ${_controller.requiredStillSeconds ~/ 60} 分钟'
            ' · 午休 ${_controller.napMinutes} 分钟',
            style: infoStyle,
          ),
        ];
      case NapPhase.detecting:
        return <Widget>[
          _buildSignalChips(),
          const SizedBox(height: 10),
          Text(_detectingInfo(), style: infoStyle, textAlign: TextAlign.center),
        ];
      case NapPhase.napping:
        return <Widget>[
          Text(
            _controller.dimScreenEnabled ? '轻触黑屏可查看倒计时' : '正在监测是否醒来',
            style: infoStyle,
          ),
        ];
      case NapPhase.finished:
        return <Widget>[
          Text(
            '实际午休 ${NapController.formatSeconds(_controller.sleptSeconds)}'
            ' · 醒来 ${_controller.wakeCount} 次',
            style: infoStyle,
          ),
        ];
    }
  }

  String _detectingInfo() {
    switch (_controller.micStatus) {
      case MicStatus.denied:
        return '未授予麦克风权限，仅使用体动判断';
      case MicStatus.error:
        return '麦克风不可用，仅使用体动判断';
      case MicStatus.starting:
        return '正在启动麦克风…';
      case MicStatus.active:
      case MicStatus.off:
        return '需累计静止 ${NapController.formatSeconds(_controller.effectiveRequiredSeconds)}'
            '${_controller.breathing ? '（已检测到呼吸，缩短判定时间）' : ''}';
    }
  }

  /// 三路检测信号指示：体动 / 呼吸 / 环境声
  Widget _buildSignalChips() {
    final bool micOn = _controller.micStatus == MicStatus.active;
    final bool stillOk = _controller.motionStillSeconds >=
        _controller.effectiveRequiredSeconds;

    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 6,
      children: <Widget>[
        _chip(
          'STILL ${_controller.stillText}',
          stillOk ? _SignalState.on : _SignalState.pending,
        ),
        _chip(
          'BREATH',
          !micOn
              ? _SignalState.off
              : (_controller.breathing
                  ? _SignalState.on
                  : _SignalState.pending),
        ),
        _chip(
          'QUIET',
          !micOn
              ? _SignalState.off
              : (_controller.audioQuiet
                  ? _SignalState.on
                  : _SignalState.pending),
        ),
      ],
    );
  }

  Widget _chip(String label, _SignalState state) {
    final Color color;
    final IconData icon;
    switch (state) {
      case _SignalState.on:
        color = _accent;
        icon = Icons.check_circle;
        break;
      case _SignalState.pending:
        color = Colors.white54;
        icon = Icons.radio_button_unchecked;
        break;
      case _SignalState.off:
        color = Colors.white24;
        icon = Icons.remove_circle_outline;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withAlpha(150)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1.5,
              color: color,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────── 设置面板 ─────────────────────────

  void _openSettings() {
    // "自定义"模式的界面状态：当前时长不在快捷选项里时，默认处于自定义
    bool customNap = !NapController.napPresets.contains(_controller.napMinutes);

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0B0F1E),
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setSheetState) {
            return ListenableBuilder(
              listenable: _controller,
              builder: (BuildContext context, Widget? _) {
                return SafeArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        _sectionTitle('入睡敏感度'),
                        const SizedBox(height: 12),
                        _buildOnsetSelector(),
                        const SizedBox(height: 8),
                        Text(
                          _onsetHint(_controller.onset),
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.white54,
                          ),
                        ),
                        const SizedBox(height: 24),
                        _sectionTitle('午休时长'),
                        const SizedBox(height: 12),
                        _buildNapDurationSelector(
                          customNap,
                          (bool v) => setSheetState(() => customNap = v),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '从判定入睡后开始计时，不含入睡前的检测时间。',
                          style: TextStyle(fontSize: 13, color: Colors.white54),
                        ),
                        const SizedBox(height: 16),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _controller.dimScreenEnabled,
                          onChanged: (bool v) =>
                              _controller.updateSettings(dimScreen: v),
                          title: const Text('入睡后黑屏'),
                          subtitle: const Text(
                            '屏幕调到最暗并显示纯黑画面（OLED 屏几乎不发光）。'
                            '应用仍在运行，继续监测醒来并准时响铃。轻触屏幕可临时查看倒计时。',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white54,
                            ),
                          ),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _controller.micEnabled,
                          onChanged: (bool v) =>
                              _controller.updateSettings(useMic: v),
                          title: const Text('麦克风辅助判断'),
                          subtitle: const Text(
                            '检测呼吸声与环境声，更准确。仅在检测阶段录音，'
                            '音频在手机内存中实时分析，不保存、不上传。',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white54,
                            ),
                          ),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _controller.whiteNoiseEnabled,
                          onChanged: (bool v) =>
                              _controller.updateSettings(whiteNoise: v),
                          title: const Text('入睡后播放白噪音'),
                          subtitle: const Text(
                            '入睡判定成功后才开始播放，避免掩盖呼吸声。',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white54,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    );
  }

  /// 入睡敏感度：快 / 标准 / 慢
  Widget _buildOnsetSelector() {
    Widget label(String name, String minutes) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(name),
          Text(
            minutes,
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
        ],
      );
    }

    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<SleepOnset>(
        showSelectedIcon: false,
        segments: <ButtonSegment<SleepOnset>>[
          ButtonSegment<SleepOnset>(
            value: SleepOnset.fast,
            label: label('快', '3 分钟'),
          ),
          ButtonSegment<SleepOnset>(
            value: SleepOnset.standard,
            label: label('标准', '7 分钟'),
          ),
          ButtonSegment<SleepOnset>(
            value: SleepOnset.slow,
            label: label('慢', '12 分钟'),
          ),
        ],
        selected: <SleepOnset>{_controller.onset},
        onSelectionChanged: (Set<SleepOnset> s) {
          _controller.updateSettings(onset: s.first);
        },
      ),
    );
  }

  String _onsetHint(SleepOnset s) {
    switch (s) {
      case SleepOnset.fast:
        return '约 3 分钟判定入睡，适合躺下就睡着的人。';
      case SleepOnset.standard:
        return '约 7 分钟判定入睡，适合大多数人。';
      case SleepOnset.slow:
        return '约 12 分钟判定入睡，适合需要慢慢放松的人。';
    }
  }

  /// 午休时长：快捷选项 + 自定义滑块
  Widget _buildNapDurationSelector(
    bool customNap,
    ValueChanged<bool> setCustomNap,
  ) {
    final int minutes = _controller.napMinutes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final int m in NapController.napPresets)
              ChoiceChip(
                label: Text(
                  m == NapController.recommendedNapMinutes
                      ? '$m 分钟 · Recommended'
                      : '$m 分钟',
                ),
                selected: !customNap && minutes == m,
                selectedColor: _accent.withAlpha(70),
                onSelected: (bool _) {
                  setCustomNap(false);
                  _controller.updateSettings(napMinutes: m);
                },
              ),
            ChoiceChip(
              label: const Text('自定义'),
              selected: customNap,
              selectedColor: _accent.withAlpha(70),
              onSelected: (bool _) => setCustomNap(true),
            ),
          ],
        ),
        if (customNap) ...<Widget>[
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: Slider(
                  value: minutes.toDouble(),
                  min: NapController.minNapMinutes.toDouble(),
                  max: NapController.maxNapMinutes.toDouble(),
                  divisions:
                      NapController.maxNapMinutes - NapController.minNapMinutes,
                  label: '$minutes 分钟',
                  onChanged: (double v) {
                    _controller.updateSettings(napMinutes: v.round());
                  },
                ),
              ),
              SizedBox(
                width: 64,
                child: Text(
                  '$minutes 分钟',
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 14, color: Colors.white70),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
