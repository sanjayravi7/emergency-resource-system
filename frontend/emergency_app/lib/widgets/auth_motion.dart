import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Motion system for the ERAS authentication experience.
///
/// Small, reusable animation primitives shared by the auth screens:
/// entrance reveals, ambient drifting, hover lifts, press feedback, focus
/// glows and pointer parallax. Every primitive follows the same contract:
///
///   * it respects the platform reduced-motion setting
///     (MediaQuery.disableAnimations): entrances collapse to a short fade
///     and all other motion is disabled entirely,
///   * it never changes layout - all motion is paint-only (opacity and
///     transforms), so animated widgets keep their exact geometry,
///   * every [AnimationController] it creates is disposed.
///
/// Ambient motion (anything that repeats forever, like the floating
/// network emblem) additionally runs only while [AuthMotion.ambientEnabled]
/// is true. Widget tests require animations to settle, so ambient motion
/// stays off under `flutter test`; [AuthMotion.debugAmbientOverride] lets a
/// test opt back in deliberately.
abstract final class AuthMotion {
  /// True when compiled by `flutter test` (which defines FLUTTER_TEST).
  static const bool _testDefine = bool.fromEnvironment('FLUTTER_TEST');

  /// Test-only override for [ambientEnabled].
  @visibleForTesting
  static bool? debugAmbientOverride;

  /// Whether infinitely repeating (ambient) animations may run.
  ///
  /// Besides the FLUTTER_TEST compile-time define, the binding type is
  /// checked as a fallback: production apps run on
  /// [WidgetsFlutterBinding], test bindings do not.
  static bool get ambientEnabled {
    final override = debugAmbientOverride;
    if (override != null) return override;
    if (_testDefine) return false;
    return WidgetsBinding.instance is WidgetsFlutterBinding;
  }

  /// The reduced-motion accessibility setting for [context].
  static bool reducedMotionOf(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// [duration], or [Duration.zero] when reduced motion is requested, so
  /// implicitly animated widgets jump straight to their end state.
  static Duration scaled(BuildContext context, Duration duration) =>
      reducedMotionOf(context) ? Duration.zero : duration;

  /// Creates a repeating controller for ambient motion, or null when
  /// ambient motion must not run (tests or reduced motion).
  static AnimationController? maybeAmbientController({
    required TickerProvider vsync,
    required BuildContext context,
    required Duration period,
  }) {
    if (!ambientEnabled || reducedMotionOf(context)) return null;
    return AnimationController(vsync: vsync, duration: period)..repeat();
  }
}

/// One-shot entrance animation: fade in while translating from [offset]
/// (logical pixels) and scaling from [beginScale] to 1.
///
/// [delay] staggers the reveal without extra timers (the delay is part of
/// the controller timeline, as an [Interval]), so the animation always
/// settles and never leaks a pending [Timer] into tests.
///
/// Under reduced motion the reveal is a short fade only: no translation,
/// no scale and no stagger.
class EntranceReveal extends StatefulWidget {
  const EntranceReveal({
    super.key,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 600),
    this.offset = const Offset(0, 14),
    this.beginScale = 1,
    this.curve = Curves.easeOutCubic,
    required this.child,
  });

  final Duration delay;
  final Duration duration;
  final Offset offset;
  final double beginScale;
  final Curve curve;
  final Widget child;

  @override
  State<EntranceReveal> createState() => _EntranceRevealState();
}

class _EntranceRevealState extends State<EntranceReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);
  late Animation<double> _progress;
  bool _reduced = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _reduced = AuthMotion.reducedMotionOf(context);
    if (_reduced) {
      _controller.duration = const Duration(milliseconds: 160);
      _progress = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    } else {
      final total = widget.delay + widget.duration;
      _controller.duration = total;
      final start = total.inMicroseconds == 0
          ? 0.0
          : widget.delay.inMicroseconds / total.inMicroseconds;
      _progress = CurvedAnimation(
        parent: _controller,
        curve: Interval(start, 1, curve: widget.curve),
      );
    }
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _progress,
      child: widget.child,
      builder: (context, child) {
        final t = _progress.value;
        Widget result = child!;
        if (!_reduced) {
          if (widget.beginScale != 1) {
            final scale = widget.beginScale + (1 - widget.beginScale) * t;
            result = Transform.scale(scale: scale, child: result);
          }
          if (widget.offset != Offset.zero) {
            result = Transform.translate(
              offset: widget.offset * (1 - t),
              child: result,
            );
          }
        }
        // Semantics stay on during the fade so assistive technology (and
        // keyboard focus) never loses the revealed controls.
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          alwaysIncludeSemantics: true,
          child: result,
        );
      },
    );
  }
}

/// Paint-only vertical drift driven by a shared ambient [animation].
///
/// The offset follows a full sine cycle per animation loop, so a
/// [AnimationController.repeat] loop is seamless. When [animation] is null
/// (ambient motion disabled) the child renders statically.
class AmbientDrift extends StatelessWidget {
  const AmbientDrift({
    super.key,
    required this.animation,
    this.amplitude = 3,
    this.phase = 0,
    required this.child,
  });

  final Animation<double>? animation;

  /// Maximum displacement, in logical pixels.
  final double amplitude;

  /// Cycle offset (0..1) so multiple layers drift asynchronously.
  final double phase;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final drift = animation;
    if (drift == null) return child;
    return AnimatedBuilder(
      animation: drift,
      child: child,
      builder: (context, child) {
        final angle = (drift.value + phase) * 2 * math.pi;
        return Transform.translate(
          offset: Offset(0, math.sin(angle) * amplitude),
          child: child,
        );
      },
    );
  }
}

/// Hover interaction wrapper: translates its subtree up by [lift] pixels
/// (and optionally scales it) while the mouse is over it, and reports the
/// hover flag to [builder] so callers can deepen shadows or accents.
///
/// Hover only ever comes from mouse pointers, so this is inert on touch
/// devices. Under reduced motion the lift is skipped entirely.
class HoverLift extends StatefulWidget {
  const HoverLift({
    super.key,
    this.lift = 2,
    this.hoverScale = 1,
    this.duration = const Duration(milliseconds: 200),
    this.enabled = true,
    required this.builder,
  });

  final double lift;
  final double hoverScale;
  final Duration duration;
  final bool enabled;
  final Widget Function(BuildContext context, bool hovered) builder;

  @override
  State<HoverLift> createState() => _HoverLiftState();
}

class _HoverLiftState extends State<HoverLift> {
  bool _hovered = false;

  void _setHovered(bool value) {
    if (_hovered != value && mounted) setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AuthMotion.reducedMotionOf(context);
    final hovered = _hovered && widget.enabled && !reduced;
    final scale = hovered ? widget.hoverScale : 1.0;
    final transform =
        Matrix4.translationValues(0, hovered ? -widget.lift : 0, 0)
          ..multiply(Matrix4.diagonal3Values(scale, scale, 1));
    return MouseRegion(
      opaque: false,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: AnimatedContainer(
        duration: reduced ? Duration.zero : widget.duration,
        curve: Curves.easeOutCubic,
        transform: transform,
        transformAlignment: Alignment.center,
        child: widget.builder(context, hovered),
      ),
    );
  }
}

/// Press feedback: scales the child to [pressedScale] while a pointer is
/// down. Purely visual; tap handling stays with the wrapped control.
class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    this.pressedScale = .98,
    this.enabled = true,
    required this.child,
  });

  final double pressedScale;
  final bool enabled;
  final Widget child;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value && mounted) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AuthMotion.reducedMotionOf(context);
    final pressed = _pressed && widget.enabled && !reduced;
    return Listener(
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: pressed ? widget.pressedScale : 1,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// Soft focus glow painted behind a form field while any descendant (the
/// field itself) holds focus. The wrapper adds no padding or size, so the
/// field keeps its exact layout.
class FocusGlow extends StatefulWidget {
  const FocusGlow({
    super.key,
    required this.glowColor,
    this.borderRadius = 12,
    required this.child,
  });

  final Color glowColor;
  final double borderRadius;
  final Widget child;

  @override
  State<FocusGlow> createState() => _FocusGlowState();
}

class _FocusGlowState extends State<FocusGlow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      skipTraversal: true,
      includeSemantics: false,
      onFocusChange: (focused) => setState(() => _focused = focused),
      child: AnimatedContainer(
        duration: AuthMotion.scaled(context, const Duration(milliseconds: 180)),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          boxShadow: [
            BoxShadow(
              color: widget.glowColor.withValues(alpha: _focused ? .14 : 0),
              blurRadius: _focused ? 14 : 4,
              spreadRadius: _focused ? 1 : 0,
            ),
          ],
        ),
        child: widget.child,
      ),
    );
  }
}

/// Fade + subtle scale cross-fade between children, used for small icon
/// swaps (password visibility, selection markers). Children must carry
/// distinct keys.
class AnimatedSwap extends StatelessWidget {
  const AnimatedSwap({
    super.key,
    this.duration = const Duration(milliseconds: 180),
    required this.child,
  });

  final Duration duration;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: AuthMotion.scaled(context, duration),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: .85, end: 1).animate(animation),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// Plays a tiny scale pulse whenever [trigger] changes value - used by the
/// remember-me checkbox so toggling feels tactile. Settles immediately and
/// never pulses on first build.
class TogglePulse extends StatefulWidget {
  const TogglePulse({super.key, required this.trigger, required this.child});

  final Object? trigger;
  final Widget child;

  @override
  State<TogglePulse> createState() => _TogglePulseState();
}

class _TogglePulseState extends State<TogglePulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: 1,
  );

  @override
  void didUpdateWidget(TogglePulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trigger != widget.trigger &&
        !AuthMotion.reducedMotionOf(context)) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: Tween<double>(begin: .86, end: 1)
          .chain(CurveTween(curve: Curves.easeOutCubic))
          .animate(_controller),
      child: widget.child,
    );
  }
}

/// Mouse-follow parallax source. Tracks the pointer across its bounds as a
/// normalised offset (-1..1 on both axes) and exposes it to [builder];
/// pair with [ParallaxLayer] to shift individual layers by a few pixels.
///
/// Hover events exist only for mouse pointers, so touch and stylus input
/// never move the layers. Disable it entirely (reduced motion) with
/// [enabled].
class PointerParallax extends StatefulWidget {
  const PointerParallax({
    super.key,
    this.enabled = true,
    required this.builder,
  });

  final bool enabled;
  final Widget Function(BuildContext context, ValueListenable<Offset> pointer)
      builder;

  @override
  State<PointerParallax> createState() => _PointerParallaxState();
}

class _PointerParallaxState extends State<PointerParallax> {
  final ValueNotifier<Offset> _pointer = ValueNotifier<Offset>(Offset.zero);

  @override
  void dispose() {
    _pointer.dispose();
    super.dispose();
  }

  void _handleHover(PointerHoverEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || box.size.isEmpty) return;
    final local = box.globalToLocal(event.position);
    _pointer.value = Offset(
      ((local.dx / box.size.width) * 2 - 1).clamp(-1.0, 1.0),
      ((local.dy / box.size.height) * 2 - 1).clamp(-1.0, 1.0),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.builder(context, _pointer);
    return MouseRegion(
      opaque: false,
      onHover: _handleHover,
      onExit: (_) => _pointer.value = Offset.zero,
      child: widget.builder(context, _pointer),
    );
  }
}

/// A layer shifted by a [PointerParallax] pointer value, scaled by [depth]
/// logical pixels and smoothed so movement feels weighty rather than
/// twitchy. Paint-only: layout is never affected.
class ParallaxLayer extends StatelessWidget {
  const ParallaxLayer({
    super.key,
    required this.pointer,
    this.depth = 4,
    required this.child,
  });

  final ValueListenable<Offset> pointer;

  /// Maximum displacement, in logical pixels.
  final double depth;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Offset>(
      valueListenable: pointer,
      child: child,
      builder: (context, value, child) => TweenAnimationBuilder<Offset>(
        tween: Tween<Offset>(begin: Offset.zero, end: value * depth),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        child: child,
        builder: (context, offset, child) =>
            Transform.translate(offset: offset, child: child),
      ),
    );
  }
}
