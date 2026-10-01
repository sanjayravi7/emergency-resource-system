import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'auth_motion_env_stub.dart'
    if (dart.library.io) 'auth_motion_env_io.dart';

/// Shared motion primitives for the ERAS authentication experience.
///
/// Everything here is intentionally restrained: short, purposeful
/// transitions and a few pixels of perpetual "alive" motion on the network
/// illustration. Nothing here changes layout size (only opacity, transform
/// and decoration are animated), so these helpers cannot introduce overflow.
///
/// Perpetual/ambient effects (floating, pulsing, idle sheens, background
/// drift) are automatically disabled:
///   - when the platform/user requests reduced motion
///     (`MediaQuery.disableAnimations`), and
///   - while running under the automated widget-test runner, so continuous
///     animations never fight `WidgetTester.pumpAndSettle`.
/// Entrance and interaction animations (fades, hovers, focus, taps) are
/// finite and always run; they simply collapse to a short fade under
/// reduced motion.
library;

/// Whether perpetual ambient motion is allowed to run at all in this
/// process. Always true for real users; false only under `flutter test`.
final bool kAmbientMotionAllowed = !isFlutterTestProcess;

/// The platform/user "reduced motion" preference.
bool reducedMotionOf(BuildContext context) =>
    MediaQuery.maybeOf(context)?.disableAnimations ?? false;

/// Whether ambient (perpetual, non-interactive) motion should run right
/// now: allowed in this process AND not suppressed by reduced motion.
bool ambientMotionOf(BuildContext context) =>
    kAmbientMotionAllowed && !reducedMotionOf(context);

/// Duration helper: returns [duration] normally, or near-zero when reduced
/// motion is requested, so implicit animations still "complete" instantly
/// instead of being skipped (which can leave widgets in a half-built
/// state for some implicit animation widgets).
Duration authMotionDuration(BuildContext context, Duration duration) =>
    reducedMotionOf(context) ? const Duration(milliseconds: 1) : duration;

/// Timeline shared by every top-of-page entrance animation (the ERAS logo,
/// hero heading lines, login card, "Why ERAS?" column and status cards).
/// Owned by [AuthEntranceScope] and read by [AuthStagger].
class AuthEntranceScope extends InheritedWidget {
  const AuthEntranceScope({
    super.key,
    required this.animation,
    required super.child,
  });

  final Animation<double> animation;

  static Animation<double>? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AuthEntranceScope>()
      ?.animation;

  @override
  bool updateShouldNotify(AuthEntranceScope oldWidget) =>
      animation != oldWidget.animation;
}

/// Wraps [child] with a slice of the shared [AuthEntranceScope] timeline:
/// a gentle fade + upward slide (+ optional scale), staggered by [start].
///
/// When no [AuthEntranceScope] is present (e.g. a widget rendered in
/// isolation in a unit test) this renders [child] unchanged, already
/// "settled" - it never blocks or hides content.
class AuthStagger extends StatefulWidget {
  const AuthStagger({
    super.key,
    required this.child,
    this.start = 0.0,
    this.end = 0.6,
    this.offset = 14,
    this.beginScale = 1,
    this.curve = Curves.easeOutCubic,
  });

  final Widget child;

  /// Start/end of this element's reveal, as a fraction (0..1) of the
  /// shared entrance timeline.
  final double start;
  final double end;

  /// Upward travel distance in logical pixels.
  final double offset;

  /// Starting scale (1 disables the scale effect entirely).
  final double beginScale;

  final Curve curve;

  @override
  State<AuthStagger> createState() => _AuthStaggerState();
}

class _AuthStaggerState extends State<AuthStagger> {
  Animation<double>? _parent;
  Animation<double>? _animation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final parent = AuthEntranceScope.maybeOf(context);
    if (!identical(parent, _parent)) {
      _parent = parent;
      _animation = parent == null
          ? null
          : CurvedAnimation(
              parent: parent,
              curve: Interval(
                widget.start.clamp(0.0, 1.0),
                widget.end.clamp(0.0, 1.0),
                curve: widget.curve,
              ),
            );
    }
  }

  @override
  Widget build(BuildContext context) {
    final animation = _animation;
    if (animation == null) return widget.child;
    final reduced = reducedMotionOf(context);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final t = animation.value.clamp(0.0, 1.0);
        Widget result = Opacity(opacity: t, child: child);
        if (!reduced) {
          if (widget.beginScale != 1) {
            final s = widget.beginScale + (1 - widget.beginScale) * t;
            result = Transform.scale(scale: s, child: result);
          }
          result = Transform.translate(
            offset: Offset(0, (1 - t) * widget.offset),
            child: result,
          );
        }
        return result;
      },
      child: widget.child,
    );
  }
}

/// Extremely subtle perpetual vertical float, used by the network
/// illustration (the central emblem and its surrounding nodes). Renders
/// [child] completely unchanged (no wrapping transform applied) whenever
/// ambient motion is not currently running, so the illustration is pixel
/// identical to the un-animated design at rest, under reduced motion, and
/// in automated tests.
class AmbientFloat extends StatefulWidget {
  const AmbientFloat({
    super.key,
    required this.child,
    this.amplitude = 3,
    this.period = const Duration(seconds: 4),
    this.phase = 0,
  });

  final Widget child;

  /// Maximum vertical travel in logical pixels (peak-to-centre).
  final double amplitude;

  final Duration period;

  /// Phase offset in radians, so siblings don't float in lockstep.
  final double phase;

  @override
  State<AmbientFloat> createState() => _AmbientFloatState();
}

class _AmbientFloatState extends State<AmbientFloat>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.period,
  );
  bool _running = false;

  void _sync(bool enabled) {
    if (enabled == _running) return;
    _running = enabled;
    if (enabled) {
      _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _sync(ambientMotionOf(context));
    if (!_running) return widget.child;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final dy = widget.amplitude *
            math.sin(2 * math.pi * _controller.value + widget.phase);
        return Transform.translate(offset: Offset(0, dy), child: child);
      },
      child: widget.child,
    );
  }
}

/// Toggles the eye/visibility style icon with a quick fade + scale instead
/// of an instant swap.
Widget authAnimatedSwitchIcon(
  BuildContext context, {
  required bool state,
  required IconData whenTrue,
  required IconData whenFalse,
}) {
  final reduced = reducedMotionOf(context);
  return AnimatedSwitcher(
    duration: Duration(milliseconds: reduced ? 0 : 180),
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: ScaleTransition(scale: animation, child: child),
    ),
    child: Icon(
      state ? whenTrue : whenFalse,
      key: ValueKey<bool>(state),
    ),
  );
}

/// A checkbox that plays a tiny, premium scale "pop" whenever its value
/// flips - never a continuous animation, so it is always `pumpAndSettle`
/// safe.
class BouncyCheckbox extends StatefulWidget {
  const BouncyCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool?> onChanged;

  @override
  State<BouncyCheckbox> createState() => _BouncyCheckboxState();
}

class _BouncyCheckboxState extends State<BouncyCheckbox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.14), weight: 1),
    TweenSequenceItem(tween: Tween(begin: 1.14, end: 1.0), weight: 1),
  ]).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

  @override
  void didUpdateWidget(covariant BouncyCheckbox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !reducedMotionOf(context)) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _scale,
        builder: (context, child) =>
            Transform.scale(scale: _scale.value, child: child),
        child: Checkbox(value: widget.value, onChanged: widget.onChanged),
      );
}

/// Wraps an input field with a soft, focus-aware glow and a very subtle
/// hover border enhancement. Purely decorative: it never changes the
/// field's size, so it cannot cause layout jumps.
class AuthAnimatedField extends StatefulWidget {
  const AuthAnimatedField({
    super.key,
    required this.focusNode,
    required this.child,
  });

  final FocusNode focusNode;
  final Widget child;

  @override
  State<AuthAnimatedField> createState() => AuthAnimatedFieldState();
}

class AuthAnimatedFieldState extends State<AuthAnimatedField> {
  bool hovered = false;
  bool focused = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_handleFocusChange);
  }

  void _handleFocusChange() {
    if (!mounted) return;
    final hasFocus = widget.focusNode.hasFocus;
    if (hasFocus != focused) setState(() => focused = hasFocus);
  }

  @override
  void didUpdateWidget(covariant AuthAnimatedField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_handleFocusChange);
      widget.focusNode.addListener(_handleFocusChange);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_handleFocusChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final duration = authMotionDuration(
      context,
      const Duration(milliseconds: 180),
    );
    final glow = focused
        ? [
            BoxShadow(
              color: const Color(0xFF2478E5).withValues(alpha: .20),
              blurRadius: 16,
              spreadRadius: 1,
            ),
          ]
        : hovered
            ? [
                BoxShadow(
                  color: const Color(0xFF2478E5).withValues(alpha: .08),
                  blurRadius: 10,
                ),
              ]
            : const <BoxShadow>[];
    return MouseRegion(
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: AnimatedContainer(
        duration: duration,
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: glow,
        ),
        child: widget.child,
      ),
    );
  }
}
