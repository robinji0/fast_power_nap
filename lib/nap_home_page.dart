import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import 'main.dart' show PowerNapApp;
import 'nap_controller.dart';

/// 信号指示灯的状态
enum _SignalState { on, pending, off }

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

  static const Color _accent = PowerNapApp.accent;

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
    _controller.addListener(_syncPulse);
    _controller.loadSettings(); // 读取上次保存的设置
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

  @override
  void dispose() {
    _controller.removeListener(_syncPulse);
    _pulse.dispose();
    _controller.dispose(); // 内部销毁 Timer / 传感器与麦克风订阅 / 播放器
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
        return '正在进行 20 分钟深度恢复';
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
        return '20-minute deep recovery in progress';
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
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _controller,
          builder: (BuildContext context, Widget? _) {
            final NapPhase phase = _controller.phase;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                children: <Widget>[
                  const SizedBox(height: 36),
                  const Text(
                    'POWER NAP AI',
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
            );
          },
        ),
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
            '静止 ${NapController.formatSeconds(_controller.requiredStillSeconds)} 后自动开始倒计时',
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
          const Text('正在监测是否醒来', style: infoStyle),
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
        return '需静止 ${NapController.formatSeconds(_controller.effectiveRequiredSeconds)}'
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
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0B0F1E),
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) {
        return ListenableBuilder(
          listenable: _controller,
          builder: (BuildContext context, Widget? _) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      '入睡判定严格度',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<Strictness>(
                        showSelectedIcon: false,
                        segments: const <ButtonSegment<Strictness>>[
                          ButtonSegment<Strictness>(
                            value: Strictness.relaxed,
                            label: Text('宽松'),
                          ),
                          ButtonSegment<Strictness>(
                            value: Strictness.standard,
                            label: Text('标准'),
                          ),
                          ButtonSegment<Strictness>(
                            value: Strictness.strict,
                            label: Text('严格'),
                          ),
                        ],
                        selected: <Strictness>{_controller.strictness},
                        onSelectionChanged: (Set<Strictness> s) {
                          _controller.updateSettings(strictness: s.first);
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _strictnessHint(_controller.strictness),
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.white54,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _controller.micEnabled,
                      onChanged: (bool v) =>
                          _controller.updateSettings(useMic: v),
                      title: const Text('麦克风辅助判断'),
                      subtitle: const Text(
                        '检测呼吸声与环境声，更准确。仅在检测阶段录音，'
                        '音频在手机内存中实时分析，不保存、不上传。',
                        style: TextStyle(fontSize: 12, color: Colors.white54),
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
                        style: TextStyle(fontSize: 12, color: Colors.white54),
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
  }

  String _strictnessHint(Strictness s) {
    switch (s) {
      case Strictness.relaxed:
        return '静止 2 分钟即可，容忍轻微动静。适合容易翻身的人。';
      case Strictness.standard:
        return '静止 3 分钟，推荐设置。';
      case Strictness.strict:
        return '静止 4 分钟，几乎不动才算入睡。减少"躺着没睡"被误判。';
    }
  }
}
