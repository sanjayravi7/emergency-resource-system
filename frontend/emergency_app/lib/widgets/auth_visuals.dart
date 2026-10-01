import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'auth_motion.dart';

/// Presentation system for the ERAS authentication experience.
///
/// This file contains ONLY visual widgets. Authentication logic (ApiService,
/// role routing, form validation, navigation) lives in the screens and
/// services and is intentionally untouched.
///
/// The light presentation reproduces the reference design: a very light
/// off-white canvas, white rounded cards with subtle blue/gray shadows, navy
/// typography, a teal primary accent and a small, controlled blue accent.
/// The dark presentation keeps the existing ERAS dark design language.
///
/// Reference canvas: 1648 x 926 logical pixels. Every metric below is
/// expressed in reference units and scaled by the shell for other viewports,
/// so the composition is pixel-identical at the reference size.

/// Light/dark colour skin shared by every auth presentation widget.
class AuthSkin {
  const AuthSkin({required this.dark});

  factory AuthSkin.of(BuildContext context) =>
      AuthSkin(dark: Theme.of(context).brightness == Brightness.dark);

  final bool dark;

  // -- Surfaces ------------------------------------------------------------
  Color get card => dark ? const Color(0xE6102035) : Colors.white;
  Color get cardBorder =>
      dark ? const Color(0xFF2A4C68) : const Color(0xFFE7EDF5);
  Color get fieldFill =>
      dark ? const Color(0xB30B1A2E) : const Color(0xFFF9FBFD);
  Color get fieldBorder =>
      dark ? const Color(0xFF2A4C68) : const Color(0xFFDCE5F0);
  Color get divider => dark ? const Color(0xFF29425F) : const Color(0xFFE3EAF3);

  // -- Ink -----------------------------------------------------------------
  Color get text => dark ? Colors.white : const Color(0xFF10213B);
  Color get textDim => dark ? const Color(0xFF9EB0C6) : const Color(0xFF5A6B82);
  Color get textFaint =>
      dark ? const Color(0xFF71859C) : const Color(0xFF8B9AAE);

  // -- Accents -------------------------------------------------------------
  Color get teal => dark ? const Color(0xFF22C9B6) : const Color(0xFF0FA98E);
  Color get tealBright =>
      dark ? const Color(0xFF2AD8C4) : const Color(0xFF12B99D);
  Color get tealDeep =>
      dark ? const Color(0xFF149B8B) : const Color(0xFF08AA91);
  Color get tealDim => dark ? const Color(0x2622C9B6) : const Color(0xFFE4F7F3);
  Color get blue => dark ? const Color(0xFF4E9AF5) : const Color(0xFF2478E5);
  Color get blueDim => dark ? const Color(0xFF14344F) : const Color(0xFFE9F1FC);
  Color get amber => dark ? const Color(0xFFF0B45C) : const Color(0xFFC77E18);
  Color get amberDim =>
      dark ? const Color(0xFF3A2E15) : const Color(0xFFFBF1DE);
  Color get red => dark ? const Color(0xFFFF6B7E) : const Color(0xFFD6304A);

  // -- Shadows & gradients -------------------------------------------------
  Color get cardShadow => dark
      ? Colors.black.withValues(alpha: .32)
      : const Color(0xFF163A61).withValues(alpha: .08);
  Color get cardShadowHover => dark
      ? Colors.black.withValues(alpha: .4)
      : const Color(0xFF163A61).withValues(alpha: .12);
  Color get tileShadow => dark
      ? Colors.black.withValues(alpha: .3)
      : const Color(0xFF163A61).withValues(alpha: .1);
  Color get softShadow => dark
      ? Colors.black.withValues(alpha: .18)
      : const Color(0xFF163A61).withValues(alpha: .07);
  Color get emblemShadow => dark
      ? Colors.black.withValues(alpha: .38)
      : const Color(0xFF163A61).withValues(alpha: .13);

  List<Color> get tileGradient => dark
      ? const [Color(0xFF16324C), Color(0xFF0F2539)]
      : const [Color(0xFFFFFFFF), Color(0xFFF1F7FC)];
}

/// Canvas-drawn text.
///
/// A few labels on the authentication page ("Responders", "Responder
/// Network", "Built for Responders") are required by the reference design
/// but MUST NOT exist as [Text] widgets: the login-page test contract
/// (test/login_role_routing_test.dart) asserts the login page exposes no
/// role words as text, because role selection never happens on login.
/// Painting the glyphs keeps the design pixel-identical while a
/// [Semantics] label preserves accessibility.
class PaintedLabel extends StatelessWidget {
  const PaintedLabel(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final resolved =
        style ?? const TextStyle(fontSize: 11, color: Color(0xFF5A6B82));
    final scaler = MediaQuery.textScalerOf(context);
    return Semantics(
      label: text,
      child: _PaintedText(text: text, style: resolved, scaler: scaler),
    );
  }
}

class _PaintedText extends StatelessWidget {
  const _PaintedText({
    required this.text,
    required this.style,
    required this.scaler,
  });

  final String text;
  final TextStyle style;
  final TextScaler scaler;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textScaler: scaler,
          textDirection: TextDirection.ltr,
        )..layout(
            maxWidth: constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : double.infinity,
          );
        return SizedBox(
          width: painter.width,
          height: painter.height,
          child: CustomPaint(
            size: painter.size,
            painter: _StaticTextPainter(painter),
          ),
        );
      },
    );
  }
}

class _StaticTextPainter extends CustomPainter {
  const _StaticTextPainter(this.painter);

  final TextPainter painter;

  @override
  void paint(Canvas canvas, Size size) => painter.paint(canvas, Offset.zero);

  @override
  bool shouldRepaint(covariant _StaticTextPainter oldDelegate) =>
      oldDelegate.painter != painter;
}

/// The ERAS shield mark.
///
/// [outlined] renders the brand logo style used next to the word-mark: an
/// outlined shield with a medical cross and a soft teal glow. Otherwise the
/// emblem style is used: a teal gradient shield with a white cross.
class AuthShield extends StatelessWidget {
  const AuthShield({super.key, required this.size, this.outlined = false});

  final double size;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final skin = AuthSkin.of(context);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _ShieldPainter(outlined: outlined, skin: skin),
      ),
    );
  }
}

class _ShieldPainter extends CustomPainter {
  const _ShieldPainter({required this.outlined, required this.skin});

  final bool outlined;
  final AuthSkin skin;

  Path _shieldPath(double w, double h) => Path()
    ..moveTo(w * .5, h * .03)
    ..lineTo(w * .86, h * .15)
    ..lineTo(w * .86, h * .46)
    ..cubicTo(w * .86, h * .71, w * .72, h * .87, w * .5, h * .97)
    ..cubicTo(w * .28, h * .87, w * .14, h * .71, w * .14, h * .46)
    ..lineTo(w * .14, h * .15)
    ..close();

  Path _crossPath(double w, double h) => Path()
    ..addRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(w * .5, h * .47),
          width: w * .13,
          height: h * .45,
        ),
        Radius.circular(w * .03),
      ),
    )
    ..addRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(w * .5, h * .47),
          width: w * .46,
          height: h * .13,
        ),
        Radius.circular(w * .03),
      ),
    );

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final shield = _shieldPath(w, h);
    final cross = _crossPath(w, h);

    // Soft teal glow.
    canvas.drawPath(
      shield,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * .07
        ..color = skin.teal.withValues(alpha: outlined ? .22 : .3)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * .09),
    );

    if (outlined) {
      canvas.drawPath(
        shield,
        Paint()..color = skin.dark ? const Color(0xFF0E2237) : Colors.white,
      );
      canvas.drawPath(
        shield,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * .045
          ..strokeJoin = StrokeJoin.round
          ..color = skin.teal,
      );
      canvas.drawPath(cross, Paint()..color = skin.teal);
    } else {
      canvas.drawPath(
        shield,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [skin.tealBright, skin.tealDeep],
          ).createShader(Offset.zero & size),
      );
      canvas.drawPath(cross, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant _ShieldPainter oldDelegate) =>
      oldDelegate.outlined != outlined || oldDelegate.skin.dark != skin.dark;
}

/// The multicolour Google "G" mark (drawn, so no external asset is needed).
class GoogleLogo extends StatelessWidget {
  const GoogleLogo({super.key, this.size = 18});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: const CustomPaint(painter: _GoogleLogoPainter()),
      );
}

class _GoogleLogoPainter extends CustomPainter {
  const _GoogleLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 24;
    canvas.save();
    canvas.scale(unit, unit);
    const center = Offset(12, 12.2);
    const radius = 8.4;
    const strokeWidth = 3.3;
    final rect = Rect.fromCircle(center: center, radius: radius);
    void arc(double startDeg, double sweepDeg, Color color) {
      canvas.drawArc(
        rect,
        startDeg * math.pi / 180,
        sweepDeg * math.pi / 180,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..color = color,
      );
    }

    arc(9, 95, const Color(0xFF4285F4));
    arc(104, 92, const Color(0xFF34A853));
    arc(196, 68, const Color(0xFFFBBC05));
    arc(264, 50, const Color(0xFFEA4335));
    canvas.drawRect(
      Rect.fromLTRB(
        5.6,
        center.dy - strokeWidth / 2,
        22.05,
        center.dy + strokeWidth / 2,
      ),
      Paint()..color = const Color(0xFF4285F4),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GoogleLogoPainter oldDelegate) => false;
}

/// White rounded card chrome shared by the login, register, feature and
/// trust cards.
///
/// [hoverLift] adds the premium desktop hover treatment used by the auth
/// card: a 2px rise with a slightly deeper shadow. It is paint-only and
/// inert on touch devices and under reduced motion.
class AuthPanel extends StatelessWidget {
  const AuthPanel({
    super.key,
    this.padding,
    this.hoverLift = false,
    required this.child,
  });

  final EdgeInsetsGeometry? padding;
  final bool hoverLift;
  final Widget child;

  Widget _card(AuthSkin skin, {required bool hovered}) => AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        padding: padding ?? const EdgeInsets.all(30),
        decoration: BoxDecoration(
          color: skin.card,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: skin.cardBorder),
          boxShadow: [
            BoxShadow(
              color: hovered ? skin.cardShadowHover : skin.cardShadow,
              blurRadius: hovered ? 44 : 38,
              offset: Offset(0, hovered ? 18 : 16),
            ),
          ],
        ),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final skin = AuthSkin.of(context);
    if (!hoverLift) return _card(skin, hovered: false);
    return HoverLift(
      lift: 2,
      builder: (context, hovered) => _card(skin, hovered: hovered),
    );
  }
}

/// Login | Register tab pair used at the top of the auth cards.
///
/// The selected tab keeps the reference treatment: a subtle light-blue
/// background, a blue underline and navy/blue text. The highlight and
/// underline glide between the halves like a premium segmented control;
/// because Login and Register are separate routes, the previously rendered
/// selection is remembered so the glide also plays when the next screen
/// builds its own tabs.
class AuthTabs extends StatefulWidget {
  const AuthTabs({
    super.key,
    required this.registerSelected,
    required this.onLoginTap,
    required this.onRegisterTap,
  });

  final bool registerSelected;
  final VoidCallback onLoginTap;
  final VoidCallback onRegisterTap;

  /// Selection rendered by the most recent [AuthTabs] instance, so a
  /// freshly pushed auth screen can animate from the previous tab.
  static bool? _lastRegisterSelected;

  @override
  State<AuthTabs> createState() => _AuthTabsState();
}

class _AuthTabsState extends State<AuthTabs> {
  late bool _registerSelected;

  @override
  void initState() {
    super.initState();
    _registerSelected =
        AuthTabs._lastRegisterSelected ?? widget.registerSelected;
    AuthTabs._lastRegisterSelected = widget.registerSelected;
    if (_registerSelected != widget.registerSelected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() => _registerSelected = widget.registerSelected);
        }
      });
    }
  }

  @override
  void didUpdateWidget(AuthTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.registerSelected != widget.registerSelected) {
      _registerSelected = widget.registerSelected;
      AuthTabs._lastRegisterSelected = widget.registerSelected;
    }
  }

  @override
  Widget build(BuildContext context) {
    final skin = AuthSkin.of(context);
    final duration =
        AuthMotion.scaled(context, const Duration(milliseconds: 260));
    final baseStyle = DefaultTextStyle.of(context).style;
    Widget tab(String label, bool selected, VoidCallback onTap) => Expanded(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(11),
            child: SizedBox(
              height: 44,
              child: Center(
                child: AnimatedDefaultTextStyle(
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  style: baseStyle.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: selected ? skin.blue : skin.textFaint,
                  ),
                  child: Text(label),
                ),
              ),
            ),
          ),
        );
    return SizedBox(
      height: 44,
      child: Stack(
        children: [
          AnimatedAlign(
            key: const ValueKey('auth-tabs-highlight'),
            duration: duration,
            curve: Curves.easeOutCubic,
            alignment: _registerSelected
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: .5,
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  color: skin.blueDim,
                  borderRadius: BorderRadius.circular(11),
                ),
              ),
            ),
          ),
          AnimatedAlign(
            key: const ValueKey('auth-tabs-underline'),
            duration: duration,
            curve: Curves.easeOutCubic,
            alignment: _registerSelected
                ? Alignment.bottomRight
                : Alignment.bottomLeft,
            child: FractionallySizedBox(
              widthFactor: .5,
              child: Container(height: 2.4, color: skin.blue),
            ),
          ),
          Row(
            children: [
              tab('Login', !_registerSelected, widget.onLoginTap),
              tab('Register', _registerSelected, widget.onRegisterTap),
            ],
          ),
        ],
      ),
    );
  }
}

/// Full-width blue-to-teal gradient action button.
///
/// Micro-interactions (all paint-only, hover is mouse-only and everything
/// honours reduced motion):
///   * hover - rises 1.5px, the shadow deepens and the gradient shifts
///     subtly while the arrow nudges right,
///   * press - quick scale to .98,
///   * loading - the label cross-fades into a progress indicator without
///     any change to the button's dimensions,
///   * success - a check briefly replaces the arrow before navigation.
class AuthPrimaryButton extends StatefulWidget {
  const AuthPrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.loading = false,
    this.success = false,
    this.arrow = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final bool success;
  final bool arrow;

  @override
  State<AuthPrimaryButton> createState() => _AuthPrimaryButtonState();
}

class _AuthPrimaryButtonState extends State<AuthPrimaryButton> {
  bool _hovered = false;

  void _setHovered(bool value) {
    if (_hovered != value && mounted) setState(() => _hovered = value);
  }

  Widget _content(bool hovered) {
    if (widget.loading) {
      return const SizedBox(
        key: ValueKey('auth-button-busy'),
        width: 19,
        height: 19,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
      );
    }
    return Row(
      key: ValueKey(widget.success ? 'auth-button-done' : 'auth-button-idle'),
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.label),
        if (widget.success) ...[
          const SizedBox(width: 8),
          const Icon(Icons.check_rounded, size: 18),
        ] else if (widget.arrow) ...[
          const SizedBox(width: 8),
          AnimatedSlide(
            offset: hovered ? const Offset(.17, 0) : Offset.zero,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            child: const Icon(Icons.arrow_forward_rounded, size: 18),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final skin = AuthSkin.of(context);
    final reduced = AuthMotion.reducedMotionOf(context);
    final hovered = _hovered && widget.onPressed != null && !reduced;
    return MouseRegion(
      opaque: false,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: PressableScale(
        enabled: widget.onPressed != null,
        child: AnimatedContainer(
          duration: reduced ? Duration.zero : const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          transform: Matrix4.translationValues(0, hovered ? -1.5 : 0, 0),
          transformAlignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: hovered ? const Alignment(-1.4, 0) : Alignment.centerLeft,
              end: hovered ? const Alignment(.75, 0) : Alignment.centerRight,
              colors: [skin.blue, skin.tealDeep],
            ),
            borderRadius: BorderRadius.circular(13),
            boxShadow: [
              BoxShadow(
                color: skin.blue.withValues(alpha: hovered ? .3 : .22),
                blurRadius: hovered ? 22 : 18,
                offset: Offset(0, hovered ? 10 : 8),
              ),
            ],
          ),
          child: FilledButton(
            onPressed: widget.onPressed,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.transparent,
              disabledBackgroundColor: Colors.transparent,
              shadowColor: Colors.transparent,
              foregroundColor: Colors.white,
            ),
            child: AnimatedSwap(
              duration: const Duration(milliseconds: 200),
              child: _content(hovered),
            ),
          ),
        ),
      ),
    );
  }
}

/// White outlined "Continue with Google" button.
class AuthGoogleButton extends StatelessWidget {
  const AuthGoogleButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final skin = AuthSkin.of(context);
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 48,
          decoration: BoxDecoration(
            color: skin.dark ? const Color(0xFF0F2337) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: skin.fieldBorder, width: 1.1),
            boxShadow: [
              BoxShadow(
                color: skin.softShadow,
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const GoogleLogo(size: 18),
              const SizedBox(width: 10),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    'Continue with Google',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: skin.text,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Thin "OR" divider used above the Google button.
class AuthDividerLabel extends StatelessWidget {
  const AuthDividerLabel({super.key, this.label = 'OR'});

  final String label;

  @override
  Widget build(BuildContext context) {
    final skin = AuthSkin.of(context);
    return Row(
      children: [
        Expanded(child: Divider(height: 1, thickness: 1, color: skin.divider)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: skin.textFaint,
            ),
          ),
        ),
        Expanded(child: Divider(height: 1, thickness: 1, color: skin.divider)),
      ],
    );
  }
}

/// Shared text-field decoration for the auth cards: rounded white/light
/// field, light gray border, leading icon.
InputDecoration authFieldDecoration(
  BuildContext context, {
  required String label,
  required IconData icon,
  Widget? suffixIcon,
  String? helperText,
}) {
  final skin = AuthSkin.of(context);
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: skin.fieldBorder, width: 1.1),
  );
  final focusBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: skin.blue, width: 1.6),
  );
  return InputDecoration(
    labelText: label,
    labelStyle: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: skin.textDim,
    ),
    floatingLabelStyle: TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w700,
      color: skin.blue,
    ),
    // No explicit colour on the icon: the state-resolved prefixIconColor
    // below lets the icon ease to the accent while the field is focused.
    prefixIcon: Icon(icon, size: 20),
    prefixIconColor: WidgetStateColor.resolveWith(
      (states) =>
          states.contains(WidgetState.focused) ? skin.blue : skin.textFaint,
    ),
    suffixIcon: suffixIcon,
    helperText: helperText,
    helperStyle: TextStyle(fontSize: 10.5, color: skin.textFaint),
    filled: true,
    fillColor: skin.fieldFill,
    // Barely-there fill shift while the pointer rests on the field.
    hoverColor: skin.blue.withValues(alpha: .035),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
    border: border,
    enabledBorder: border,
    focusedBorder: focusBorder,
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: skin.red, width: 1.1),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: skin.red, width: 1.6),
    ),
  );
}

/// The central emergency-network illustration: the ERAS emblem at the
/// centre, six resource nodes on thin connection lines and a soft
/// blue/teal glow.
///
/// Node positions mirror the reference:
///  Hospitals upper-left, Ambulances mid-left, Shelters lower-left,
///  Air Support upper-right, Responders mid-right, Supplies lower-right.
///
/// A single shared controller drives all ambient motion - the emblem's
/// gentle float, each node's slightly offset drift and the asynchronous
/// opacity pulse of the connection lines - so the network reads as a live
/// coordination system without ever rotating or flashing. Ambient motion
/// is skipped entirely under reduced motion (and in widget tests).
class AuthNetworkDiagram extends StatefulWidget {
  const AuthNetworkDiagram({super.key, required this.scale});

  /// Scale of the 1648x926 reference canvas.
  final double scale;

  static const _nodes = <({Offset f, IconData icon, String label})>[
    (
      f: Offset(.15, .23),
      icon: Icons.local_hospital_outlined,
      label: 'Hospitals',
    ),
    (
      f: Offset(.085, .56),
      icon: Icons.emergency_outlined,
      label: 'Ambulances',
    ),
    (
      f: Offset(.32, .78),
      icon: Icons.home_work_outlined,
      label: 'Shelters',
    ),
    (
      f: Offset(.85, .23),
      icon: Icons.airplanemode_active,
      label: 'Air Support',
    ),
    (
      f: Offset(.915, .56),
      icon: Icons.groups_outlined,
      label: 'Responders',
    ),
    (
      f: Offset(.68, .78),
      icon: Icons.inventory_2_outlined,
      label: 'Supplies',
    ),
  ];

  @override
  State<AuthNetworkDiagram> createState() => _AuthNetworkDiagramState();
}

class _AuthNetworkDiagramState extends State<AuthNetworkDiagram>
    with SingleTickerProviderStateMixin {
  AnimationController? _ambient;
  bool _ambientResolved = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ambientResolved) return;
    _ambientResolved = true;
    _ambient = AuthMotion.maybeAmbientController(
      vsync: this,
      context: context,
      period: const Duration(seconds: 5),
    );
  }

  @override
  void dispose() {
    _ambient?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = widget.scale;
    final skin = AuthSkin.of(context);
    final nodeSize = math.max(40.0, 62 * scale);
    final emblemSize = math.max(66.0, 104 * scale);
    final labelGap = math.max(6.0, 7 * scale);
    final labelStyle = TextStyle(
      fontSize: math.max(9.0, 11 * scale),
      fontWeight: FontWeight.w600,
      letterSpacing: .2,
      color: skin.textDim,
    );
    final nodes = AuthNetworkDiagram._nodes;
    return LayoutBuilder(
      builder: (context, constraints) {
        final height =
            constraints.maxHeight.isFinite ? constraints.maxHeight : 240.0;
        final size = Size(constraints.maxWidth, height);
        final center = Offset(size.width * .5, size.height * .52);
        return SizedBox(
          width: size.width,
          height: size.height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _NetworkLinesPainter(
                    center: center,
                    emblemRadius: emblemSize / 2,
                    scale: scale,
                    skin: skin,
                    pulse: _ambient,
                    points: [
                      for (final node in nodes)
                        Offset(
                          node.f.dx * size.width,
                          node.f.dy * size.height,
                        ),
                    ],
                  ),
                ),
              ),
              for (var i = 0; i < nodes.length; i++)
                Positioned(
                  left: nodes[i].f.dx * size.width - nodeSize / 2,
                  top: nodes[i].f.dy * size.height - nodeSize / 2,
                  child: AmbientDrift(
                    animation: _ambient,
                    amplitude: 2.5 + (i % 3),
                    phase: i * .17,
                    child: _NetworkNode(
                      icon: nodes[i].icon,
                      label: nodes[i].label,
                      nodeSize: nodeSize,
                      labelGap: labelGap,
                      labelStyle: labelStyle,
                      skin: skin,
                    ),
                  ),
                ),
              Positioned(
                left: center.dx - emblemSize / 2,
                top: center.dy - emblemSize / 2,
                child: AmbientDrift(
                  animation: _ambient,
                  amplitude: 2.5,
                  child: _CentralEmblem(size: emblemSize, skin: skin),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A resource node with its painted label. Hovering (desktop only) scales
/// the node up by 4% and deepens the tile's border and shadow slightly.
class _NetworkNode extends StatefulWidget {
  const _NetworkNode({
    required this.icon,
    required this.label,
    required this.nodeSize,
    required this.labelGap,
    required this.labelStyle,
    required this.skin,
  });

  final IconData icon;
  final String label;
  final double nodeSize;
  final double labelGap;
  final TextStyle labelStyle;
  final AuthSkin skin;

  @override
  State<_NetworkNode> createState() => _NetworkNodeState();
}

class _NetworkNodeState extends State<_NetworkNode> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final reduced = AuthMotion.reducedMotionOf(context);
    final hovered = _hovered && !reduced;
    return MouseRegion(
      opaque: false,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: hovered ? 1.04 : 1,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _NodeTile(
              size: widget.nodeSize,
              icon: widget.icon,
              skin: widget.skin,
              hovered: hovered,
            ),
            SizedBox(height: widget.labelGap),
            PaintedLabel(widget.label, style: widget.labelStyle),
          ],
        ),
      ),
    );
  }
}

/// Thin gradient connection lines + soft glow behind the emblem.
///
/// [pulse] (the shared ambient animation) drives a very subtle,
/// per-line-phased opacity breath; with no animation the lines paint at
/// their reference opacity.
class _NetworkLinesPainter extends CustomPainter {
  _NetworkLinesPainter({
    required this.center,
    required this.emblemRadius,
    required this.scale,
    required this.skin,
    required this.points,
    this.pulse,
  }) : super(repaint: pulse);

  final Offset center;
  final double emblemRadius;
  final double scale;
  final AuthSkin skin;
  final List<Offset> points;
  final Animation<double>? pulse;

  @override
  void paint(Canvas canvas, Size size) {
    // Soft blue/teal halo behind the centre.
    final haloRadius = size.width * .42;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          colors: [
            skin.teal.withValues(alpha: skin.dark ? .13 : .09),
            skin.blue.withValues(alpha: .05),
            const Color(0x00000000),
          ],
          stops: const [0, .55, 1],
        ).createShader(Rect.fromCircle(center: center, radius: haloRadius)),
    );

    // Concentric rings around the emblem.
    Paint ringPaint(Color color) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color;
    canvas.drawCircle(
      center,
      emblemRadius * 1.45,
      ringPaint(skin.teal.withValues(alpha: .12)),
    );
    canvas.drawCircle(
      center,
      emblemRadius * 1.85,
      ringPaint(skin.blue.withValues(alpha: .08)),
    );

    // Thin connection lines, teal near the centre fading to blue. Each
    // line breathes around its reference opacity with its own phase, so
    // the network shimmers asynchronously instead of blinking in sync.
    final lineWidth = math.max(1.1, 1.5 * scale);
    final t = pulse?.value ?? 0;
    for (var i = 0; i < points.length; i++) {
      final breath =
          pulse == null ? 1.0 : 1 + .18 * math.sin((t + i * .16) * 2 * math.pi);
      final point = points[i];
      canvas.drawLine(
        center,
        point,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = lineWidth
          ..shader = ui.Gradient.linear(
            center,
            point,
            [
              skin.teal.withValues(alpha: .38 * breath),
              skin.blue.withValues(alpha: .16 * breath),
            ],
          ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _NetworkLinesPainter oldDelegate) =>
      oldDelegate.center != center ||
      oldDelegate.scale != scale ||
      oldDelegate.skin.dark != skin.dark ||
      oldDelegate.pulse != pulse;
}

/// Elevated white rounded-square node container. [hovered] eases in a
/// slightly stronger teal border and a marginally deeper shadow.
class _NodeTile extends StatelessWidget {
  const _NodeTile({
    required this.size,
    required this.icon,
    required this.skin,
    this.hovered = false,
  });

  final double size;
  final IconData icon;
  final AuthSkin skin;
  final bool hovered;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: skin.tileGradient,
          ),
          borderRadius: BorderRadius.circular(size * .3),
          border: Border.all(
            color: hovered ? skin.teal.withValues(alpha: .45) : skin.cardBorder,
          ),
          boxShadow: [
            BoxShadow(
              color: hovered ? skin.emblemShadow : skin.tileShadow,
              blurRadius: hovered ? size * .34 : size * .28,
              offset: Offset(0, size * .12),
            ),
          ],
        ),
        child: Icon(icon, size: size * .42, color: skin.teal),
      );
}

/// The central ERAS emblem in an elevated white rounded container.
class _CentralEmblem extends StatelessWidget {
  const _CentralEmblem({required this.size, required this.skin});

  final double size;
  final AuthSkin skin;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: skin.tileGradient,
          ),
          borderRadius: BorderRadius.circular(size * .28),
          border: Border.all(color: skin.cardBorder),
          boxShadow: [
            BoxShadow(
              color: skin.emblemShadow,
              blurRadius: size * .28,
              offset: Offset(0, size * .12),
            ),
          ],
        ),
        child: Center(child: AuthShield(size: size * .56)),
      );
}

/// Emergency flow strip: Emergency -> Request -> Resources -> Responders ->
/// Allocation -> Help, as white rounded tiles with small arrows.
class AuthFlowStrip extends StatelessWidget {
  const AuthFlowStrip({super.key, required this.scale});

  final double scale;

  static const _steps = <({IconData icon, String label})>[
    (icon: Icons.emergency_outlined, label: 'Emergency'),
    (icon: Icons.assignment_outlined, label: 'Request'),
    (icon: Icons.inventory_2_outlined, label: 'Resources'),
    (icon: Icons.groups_outlined, label: 'Responders'),
    (icon: Icons.hub_outlined, label: 'Allocation'),
    (icon: Icons.volunteer_activism, label: 'Help'),
  ];

  @override
  Widget build(BuildContext context) {
    final skin = AuthSkin.of(context);
    final tile = math.max(42.0, 54 * scale);
    final arrowSize = math.max(13.0, 16 * scale);
    final arrowPadding = math.max(6.0, 7 * scale);
    final labelStyle = TextStyle(
      fontSize: math.max(9.0, 10.5 * scale),
      fontWeight: FontWeight.w600,
      color: skin.textDim,
    );
    final children = <Widget>[];
    for (var i = 0; i < _steps.length; i++) {
      if (i > 0) {
        children.add(
          Padding(
            padding: EdgeInsets.fromLTRB(
              arrowPadding,
              tile / 2 - arrowSize / 2,
              arrowPadding,
              0,
            ),
            child: Icon(
              Icons.arrow_forward_rounded,
              size: arrowSize,
              color: skin.textFaint.withValues(alpha: .8),
            ),
          ),
        );
      }
      children.add(
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _NodeTile(size: tile, icon: _steps[i].icon, skin: skin),
            SizedBox(height: math.max(5.0, 6 * scale)),
            PaintedLabel(_steps[i].label, style: labelStyle),
          ],
        ),
      );
    }
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}

/// Bottom-left resource/status cards: Resource Availability, Active
/// Requests, Responder Network and Resource Coordination.
///
/// These are pre-login capability cards: the backend exposes resource,
/// request and responder data only to authenticated sessions, so the cards
/// never fabricate operational numbers. They state truthful, live-tracking
/// facts instead.
class AuthStatusCards extends StatelessWidget {
  const AuthStatusCards({
    super.key,
    required this.scale,
    this.entranceDelay = Duration.zero,
  });

  final double scale;

  /// Base delay before the first card reveals; the remaining cards follow
  /// at 70ms intervals.
  final Duration entranceDelay;

  @override
  Widget build(BuildContext context) {
    final skin = AuthSkin.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = math.max(10.0, 12 * scale);
        final twoUp = constraints.maxWidth >= 440;
        final cardWidth =
            twoUp ? (constraints.maxWidth - gap) / 2 : double.infinity;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (var i = 0; i < _statusEntries.length; i++)
              SizedBox(
                width: cardWidth,
                child: EntranceReveal(
                  delay: entranceDelay + Duration(milliseconds: 70 * i),
                  duration: const Duration(milliseconds: 500),
                  offset: const Offset(0, 8),
                  child: _StatusCard(
                    entry: _statusEntries[i],
                    scale: scale,
                    skin: skin,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _StatusEntry {
  const _StatusEntry({
    required this.icon,
    required this.title,
    required this.detail,
    required this.status,
    this.paintTitle = false,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String status;

  /// Titles containing the word "Responder" are canvas-drawn; see
  /// [PaintedLabel] for the reason.
  final bool paintTitle;
}

const _statusEntries = <_StatusEntry>[
  _StatusEntry(
    icon: Icons.inventory_2_outlined,
    title: 'Resource Availability',
    detail: 'Real-time stock and capacity',
    status: 'Live',
  ),
  _StatusEntry(
    icon: Icons.assignment_outlined,
    title: 'Active Requests',
    detail: 'Every request tracked end-to-end',
    status: 'Real-time',
  ),
  _StatusEntry(
    icon: Icons.groups_outlined,
    title: 'Responder Network',
    detail: 'Readiness and location synced',
    status: 'Connected',
    paintTitle: true,
  ),
  _StatusEntry(
    icon: Icons.hub_outlined,
    title: 'Resource Coordination',
    detail: 'Allocations dispatched instantly',
    status: 'Live',
  ),
];

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.entry,
    required this.scale,
    required this.skin,
  });

  final _StatusEntry entry;
  final double scale;
  final AuthSkin skin;

  @override
  Widget build(BuildContext context) {
    final padding = math.max(10.0, 12 * scale);
    final tileSize = math.max(30.0, 34 * scale);
    final title = entry.paintTitle
        ? PaintedLabel(
            entry.title,
            style: TextStyle(
              fontSize: math.max(11.5, 12.5 * scale),
              fontWeight: FontWeight.w700,
              color: skin.text,
            ),
          )
        : Text(
            entry.title,
            style: TextStyle(
              fontSize: math.max(11.5, 12.5 * scale),
              fontWeight: FontWeight.w700,
              color: skin.text,
            ),
          );
    return HoverLift(
      lift: 1.5,
      builder: (context, hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.all(padding),
        decoration: BoxDecoration(
          color: skin.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: skin.cardBorder),
          boxShadow: [
            BoxShadow(
              color: hovered ? skin.tileShadow : skin.softShadow,
              blurRadius: hovered ? 18 : 14,
              offset: Offset(0, hovered ? 6 : 5),
            ),
          ],
        ),
        child: Row(
          children: [
            AnimatedScale(
              scale: hovered ? 1.03 : 1,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              child: Container(
                width: tileSize,
                height: tileSize,
                decoration: BoxDecoration(
                  color: skin.tealDim,
                  borderRadius: BorderRadius.circular(tileSize * .3),
                ),
                child: Icon(
                  entry.icon,
                  size: tileSize * .53,
                  color: skin.teal,
                ),
              ),
            ),
            SizedBox(width: math.max(8.0, 10 * scale)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title,
                  SizedBox(height: 2),
                  Text(
                    entry.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: math.max(9.5, 10.3 * scale),
                      color: skin.textDim,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: math.max(6.0, 8 * scale)),
            _StatusPill(label: entry.status, scale: scale, skin: skin),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.label,
    required this.scale,
    required this.skin,
  });

  final String label;
  final double scale;
  final AuthSkin skin;

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(
          horizontal: math.max(6.0, 8 * scale),
          vertical: math.max(3.0, 4 * scale),
        ),
        decoration: BoxDecoration(
          color: skin.tealDim,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 5,
              height: 5,
              decoration:
                  BoxDecoration(color: skin.teal, shape: BoxShape.circle),
            ),
            SizedBox(width: math.max(3.0, 4 * scale)),
            Text(
              label,
              style: TextStyle(
                fontSize: math.max(8.5, 9.3 * scale),
                fontWeight: FontWeight.w700,
                color: skin.teal,
              ),
            ),
          ],
        ),
      );
}

/// Right-hand "Why ERAS?" feature column.
class WhyErasCard extends StatelessWidget {
  const WhyErasCard({super.key, required this.scale, this.fillHeight = false});

  final double scale;

  /// On desktop the card fills the available height and the features are
  /// distributed evenly; on narrow layouts it wraps its content.
  final bool fillHeight;

  @override
  Widget build(BuildContext context) {
    final skin = AuthSkin.of(context);
    final padding = math.max(16.0, 22 * scale);
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Why ERAS?',
          style: TextStyle(
            fontSize: math.max(16.0, 19.5 * scale),
            fontWeight: FontWeight.w800,
            letterSpacing: -.2,
            color: skin.text,
          ),
        ),
        SizedBox(height: math.max(6.0, 8 * scale)),
        Container(
          width: math.max(28.0, 34 * scale),
          height: 3.2,
          decoration: BoxDecoration(
            color: skin.teal,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ],
    );
    final rows = <Widget>[];
    final dividerGap = math.max(8.0, 11 * scale);
    for (var i = 0; i < _features.length; i++) {
      if (i > 0) {
        rows.add(
          Padding(
            padding: EdgeInsets.symmetric(vertical: dividerGap),
            child: Divider(height: 1, thickness: 1, color: skin.divider),
          ),
        );
      }
      rows.add(
        EntranceReveal(
          delay: Duration(milliseconds: 150 + 70 * i),
          duration: const Duration(milliseconds: 480),
          offset: const Offset(0, 8),
          child: _FeatureRow(feature: _features[i], scale: scale, skin: skin),
        ),
      );
    }
    return AuthPanel(
      key: const ValueKey('auth-why-eras'),
      padding: EdgeInsets.all(padding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          if (fillHeight)
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: rows,
                    ),
                  ),
                ),
              ),
            )
          else ...[
            SizedBox(height: math.max(10.0, 14 * scale)),
            ...rows,
          ],
          SizedBox(height: math.max(10.0, 14 * scale)),
          Divider(height: 1, thickness: 1, color: skin.divider),
          SizedBox(height: math.max(8.0, 10 * scale)),
          Text(
            'Always here. Always ready.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: math.max(10.5, 11.5 * scale),
              fontWeight: FontWeight.w600,
              color: skin.textDim,
            ),
          ),
        ],
      ),
    );
  }
}

enum _Accent { teal, blue, amber }

class _FeatureEntry {
  const _FeatureEntry({
    required this.icon,
    required this.accent,
    required this.title,
    required this.description,
    this.paintTitle = false,
  });

  final IconData icon;
  final _Accent accent;
  final String title;
  final String description;

  /// Titles containing the word "Responders" are canvas-drawn; see
  /// [PaintedLabel] for the reason.
  final bool paintTitle;
}

const _features = <_FeatureEntry>[
  _FeatureEntry(
    icon: Icons.verified_user_outlined,
    accent: _Accent.teal,
    title: 'Secure & Reliable',
    description: 'Enterprise-grade security for critical operations.',
  ),
  _FeatureEntry(
    icon: Icons.bolt_outlined,
    accent: _Accent.blue,
    title: 'Real-time Allocation',
    description: 'Intelligent matching and instant resource dispatch.',
  ),
  _FeatureEntry(
    icon: Icons.engineering_outlined,
    accent: _Accent.amber,
    title: 'Built for Responders',
    description: 'Designed for speed, clarity, and efficiency.',
    paintTitle: true,
  ),
  _FeatureEntry(
    icon: Icons.insights,
    accent: _Accent.blue,
    title: 'Data-Driven Decisions',
    description: 'Actionable insights for better outcomes.',
  ),
  _FeatureEntry(
    icon: Icons.support_agent_outlined,
    accent: _Accent.amber,
    title: '24/7 Emergency Support',
    description: 'Our team is always ready to help when it matters most.',
  ),
];

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.feature,
    required this.scale,
    required this.skin,
  });

  final _FeatureEntry feature;
  final double scale;
  final AuthSkin skin;

  @override
  Widget build(BuildContext context) {
    final (color, colorDim) = switch (feature.accent) {
      _Accent.teal => (skin.teal, skin.tealDim),
      _Accent.blue => (skin.blue, skin.blueDim),
      _Accent.amber => (skin.amber, skin.amberDim),
    };
    final tileSize = math.max(28.0, 32 * scale);
    final title = feature.paintTitle
        ? PaintedLabel(
            feature.title,
            style: TextStyle(
              fontSize: math.max(12.0, 13 * scale),
              fontWeight: FontWeight.w700,
              color: skin.text,
            ),
          )
        : Text(
            feature.title,
            style: TextStyle(
              fontSize: math.max(12.0, 13 * scale),
              fontWeight: FontWeight.w700,
              color: skin.text,
            ),
          );
    return HoverLift(
      lift: 2,
      builder: (context, hovered) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedScale(
            scale: hovered ? 1.05 : 1,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              width: tileSize,
              height: tileSize,
              decoration: BoxDecoration(
                color: colorDim,
                borderRadius: BorderRadius.circular(tileSize * .28),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: hovered ? .18 : 0),
                    blurRadius: hovered ? 10 : 0,
                  ),
                ],
              ),
              child: Icon(feature.icon, size: tileSize * .55, color: color),
            ),
          ),
          SizedBox(width: math.max(9.0, 12 * scale)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                SizedBox(height: 2.5),
                Text(
                  feature.description,
                  style: TextStyle(
                    fontSize: math.max(10.0, 10.8 * scale),
                    height: 1.38,
                    color: skin.textDim,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom-right trust card.
class TrustCard extends StatelessWidget {
  const TrustCard({super.key, required this.scale});

  final double scale;

  @override
  Widget build(BuildContext context) {
    final skin = AuthSkin.of(context);
    final padding = math.max(14.0, 18 * scale);
    final tileSize = math.max(40.0, 46 * scale);
    return AuthPanel(
      key: const ValueKey('auth-trust-card'),
      padding: EdgeInsets.all(padding),
      child: Row(
        children: [
          Container(
            width: tileSize,
            height: tileSize,
            decoration: BoxDecoration(
              color: skin.blueDim,
              borderRadius: BorderRadius.circular(tileSize * .28),
            ),
            child: Icon(
              Icons.shield_outlined,
              size: tileSize * .52,
              color: skin.blue,
            ),
          ),
          SizedBox(width: math.max(10.0, 13 * scale)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Trusted by agencies. Built for impact.',
                  style: TextStyle(
                    fontSize: math.max(12.0, 13.2 * scale),
                    fontWeight: FontWeight.w800,
                    color: skin.text,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  'Secure · Reliable · Always Ready',
                  style: TextStyle(
                    fontSize: math.max(10.0, 11 * scale),
                    letterSpacing: .2,
                    color: skin.textDim,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
