import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'auth_motion.dart';
import 'auth_visuals.dart';

/// Brand lock-up: large outlined shield with medical cross + teal glow,
/// the ERAS word-mark and the full system name beneath it.
class ErasMark extends StatelessWidget {
  const ErasMark({super.key, this.scale = 1});

  final double scale;

  @override
  Widget build(BuildContext context) {
    final skin = AuthSkin.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AuthShield(
          key: const ValueKey('eras-brand-shield'),
          size: 62 * scale,
          outlined: true,
        ),
        SizedBox(width: 14 * scale),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'ERAS',
                style: TextStyle(
                  fontSize: 30 * scale,
                  height: 1,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2.2,
                  color: skin.text,
                ),
              ),
              SizedBox(height: 5 * scale),
              // The constrained width makes the subtitle break exactly like
              // the reference: "Emergency Resource" / "Allocation System".
              SizedBox(
                width: 148 * scale,
                child: Text(
                  'Emergency Resource Allocation System',
                  style: TextStyle(
                    fontSize: 10.5 * math.max(scale, .8),
                    height: 1.45,
                    letterSpacing: .25,
                    color: skin.textDim,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Light/dark toggle. The layout and colours are unchanged; the toggle
/// glides: the thumb slides with a soft glow while the sun and moon icons
/// cross-fade, all within one 300ms motion (instant under reduced motion).
class ThemeSwitch extends StatelessWidget {
  const ThemeSwitch({super.key});
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final duration =
        AuthMotion.scaled(context, const Duration(milliseconds: 300));
    const curve = Curves.easeOutCubic;
    return Semantics(
        button: true,
        label: dark ? 'Switch to light theme' : 'Switch to dark theme',
        child: InkWell(
          onTap: ThemeController.toggle,
          borderRadius: BorderRadius.circular(24),
          child: AnimatedContainer(
              duration: duration,
              curve: curve,
              width: 76,
              height: 38,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                  color: dark ? const Color(0xFF142A43) : Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                      color: dark ? const Color(0xFF31506E) : AppColors.border),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: .08),
                        blurRadius: 12)
                  ]),
              child: Stack(children: [
                AnimatedAlign(
                    key: const ValueKey('theme-switch-thumb'),
                    duration: duration,
                    curve: curve,
                    alignment:
                        dark ? Alignment.centerRight : Alignment.centerLeft,
                    child: AnimatedContainer(
                        duration: duration,
                        curve: curve,
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: dark
                                ? const Color(0xFF236BDC)
                                : const Color(0xFFFFF0C2),
                            boxShadow: [
                              BoxShadow(
                                  color: (dark
                                          ? const Color(0xFF236BDC)
                                          : const Color(0xFFF5A623))
                                      .withValues(alpha: .35),
                                  blurRadius: 8)
                            ]))),
                Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: AnimatedOpacity(
                            key: const ValueKey('theme-switch-sun'),
                            duration: duration,
                            curve: curve,
                            opacity: dark ? .45 : 1,
                            child: const Icon(Icons.light_mode_rounded,
                                size: 16, color: Color(0xFFF5A623))))),
                Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: AnimatedOpacity(
                            key: const ValueKey('theme-switch-moon'),
                            duration: duration,
                            curve: curve,
                            opacity: dark ? 1 : .45,
                            child: const Icon(Icons.dark_mode_rounded,
                                size: 16, color: Color(0xFFBBD3F8))))),
              ])),
        ));
  }
}

/// Layout shell for the authentication experience.
///
/// The light theme reproduces the reference composition on a 1648x926
/// canvas: branding top-left, hero + emergency-network illustration + flow
/// strip + status cards on the left, the login/register card centre-right,
/// the "Why ERAS?" column to its right and the trust card bottom-right.
/// The dark theme keeps the existing ERAS dark design language.
class AuthShell extends StatelessWidget {
  const AuthShell({super.key, required this.child});

  final Widget child;

  /// Reference canvas the design was authored against.
  static const double referenceWidth = 1648;
  static const double referenceHeight = 926;

  /// Below this width the three columns stack vertically.
  static const double desktopBreakpoint = 1150;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
        body: AnimatedContainer(
            duration: const Duration(milliseconds: 350),
            decoration: BoxDecoration(
                gradient: dark
                    ? const RadialGradient(
                        center: Alignment(-.35, -.25),
                        radius: 1.25,
                        colors: [
                            Color(0xFF102B42),
                            Color(0xFF071321),
                            Color(0xFF050E19)
                          ])
                    : const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                            Color(0xFFFFFFFF),
                            Color(0xFFF4F8FC),
                            Color(0xFFEDF4F9)
                          ])),
            child: SafeArea(child: LayoutBuilder(builder: (context, c) {
              final size = c.biggest;
              final desktop = size.width >= desktopBreakpoint;
              final scale = desktop
                  ? (size.width / referenceWidth).clamp(.68, 1.0).toDouble()
                  : (size.width / desktopBreakpoint).clamp(.56, .8).toDouble();
              return Stack(children: [
                if (dark)
                  Positioned.fill(child: CustomPaint(painter: _GridPainter()))
                else
                  const Positioned.fill(child: _AmbientBackdrop()),
                if (desktop)
                  _DesktopComposition(scale: scale, child: child)
                else
                  _NarrowComposition(scale: scale, child: child),
              ]);
            }))));
  }
}

/// Desktop: the reference three-column composition.
class _DesktopComposition extends StatelessWidget {
  const _DesktopComposition({required this.scale, required this.child});

  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final s = scale;
    return Padding(
      padding: EdgeInsets.fromLTRB(55 * s, 40 * s, 55 * s, 40 * s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              EntranceReveal(
                duration: const Duration(milliseconds: 600),
                offset: const Offset(0, 10),
                beginScale: .96,
                child: ErasMark(scale: s),
              ),
              const Spacer(),
              const ThemeSwitch(),
            ],
          ),
          SizedBox(height: 32 * s),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _StoryColumn(scale: s)),
                SizedBox(width: 30 * s),
                SizedBox(
                  width: 400 * s,
                  child: EntranceReveal(
                    delay: const Duration(milliseconds: 200),
                    duration: const Duration(milliseconds: 650),
                    offset: const Offset(0, 18),
                    beginScale: .985,
                    child: _AuthCardColumn(scale: s, child: child),
                  ),
                ),
                SizedBox(width: 26 * s),
                SizedBox(
                  width: 302 * s,
                  child: _SideColumn(scale: s),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Left region: hero heading, network illustration (flexes), flow strip and
/// the status cards pinned to the bottom of the band.
///
/// When the window is too short for the full composition the region falls
/// back to vertical scrolling with a fixed-size illustration.
class _StoryColumn extends StatelessWidget {
  const _StoryColumn({required this.scale});

  final double scale;

  /// Smallest usable illustration height, in reference units.
  static const double _minIllustration = 130;

  /// Largest illustration height before the composition looks stretched,
  /// in reference units.
  static const double _maxIllustration = 400;

  /// Exact height of everything except the illustration. Mirrors the
  /// metrics used by the child widgets (including their minimum floors) so
  /// the flex branch can never overflow.
  double _fixedHeight(double s) {
    final heading = 3 * 46 * s * 1.14;
    final subtext = 2 * 15.5 * s * 1.5;
    final flowTile = math.max(42.0, 54 * s);
    final flowLabel = math.max(9.0, 10.5 * s) * 1.3;
    final flow = flowTile + math.max(5.0, 6 * s) + flowLabel;
    final statusCard = 2 * math.max(10.0, 12 * s) + math.max(30.0, 34 * s);
    final status = 2 * statusCard + math.max(10.0, 12 * s);
    return heading +
        14 * s +
        subtext +
        22 * s +
        18 * s +
        flow +
        22 * s +
        status;
  }

  @override
  Widget build(BuildContext context) {
    final skin = AuthSkin.of(context);
    final s = scale;
    final headingSize = 46 * s;
    final bodySize = 15.5 * s;
    final navy = TextStyle(
      fontSize: headingSize,
      height: 1.14,
      letterSpacing: -1.3,
      fontWeight: FontWeight.w900,
      color: skin.text,
    );
    final teal = TextStyle(
      fontSize: headingSize,
      height: 1.14,
      letterSpacing: -1.3,
      fontWeight: FontWeight.w900,
      color: skin.tealBright,
    );
    // Staggered line-by-line hero reveal; the logo/heading themselves stay
    // outside the parallax so they remain stationary under the pointer.
    Widget heroLine(int index, Widget line) => EntranceReveal(
          delay: Duration(milliseconds: 120 + 100 * index),
          duration: const Duration(milliseconds: 550),
          offset: const Offset(0, 12),
          child: line,
        );
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        heroLine(0, Text('Right Resource.', style: navy)),
        heroLine(1, Text('Right Place.', style: navy)),
        heroLine(
          2,
          Text(
            'Right Time.',
            key: const ValueKey('auth-hero-right-time'),
            style: teal,
          ),
        ),
        SizedBox(height: 14 * s),
        EntranceReveal(
          delay: const Duration(milliseconds: 440),
          duration: const Duration(milliseconds: 550),
          offset: const Offset(0, 10),
          child: Text(
            'Smarter coordination. Faster response.\n'
            'Better outcomes for every emergency.',
            style: TextStyle(
              fontSize: bodySize,
              height: 1.5,
              color: skin.textDim,
            ),
          ),
        ),
      ],
    );
    return PointerParallax(
      enabled: !AuthMotion.reducedMotionOf(context),
      builder: (context, pointer) {
        final bottom = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: 18 * s),
            EntranceReveal(
              delay: const Duration(milliseconds: 550),
              duration: const Duration(milliseconds: 550),
              offset: const Offset(0, 8),
              child: ParallaxLayer(
                pointer: pointer,
                depth: 2,
                child: AuthFlowStrip(
                  key: const ValueKey('auth-flow'),
                  scale: s,
                ),
              ),
            ),
            SizedBox(height: 22 * s),
            AuthStatusCards(
              key: const ValueKey('auth-status-cards'),
              scale: s,
              entranceDelay: const Duration(milliseconds: 650),
            ),
          ],
        );
        Widget network() => EntranceReveal(
              delay: const Duration(milliseconds: 350),
              duration: const Duration(milliseconds: 650),
              offset: Offset.zero,
              beginScale: .98,
              child: ParallaxLayer(
                pointer: pointer,
                depth: 4,
                child: AuthNetworkDiagram(
                  key: const ValueKey('auth-network'),
                  scale: s,
                ),
              ),
            );
        Widget diagram(double maxHeight) => Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: network(),
              ),
            );
        return LayoutBuilder(
          builder: (context, constraints) {
            final scrollFallback =
                constraints.maxHeight < _fixedHeight(s) + _minIllustration * s;
            if (scrollFallback) {
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    heading,
                    SizedBox(height: 22 * s),
                    SizedBox(height: 210 * s, child: network()),
                    bottom,
                  ],
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                heading,
                SizedBox(height: 22 * s),
                Expanded(
                  child: diagram(_maxIllustration * s),
                ),
                bottom,
              ],
            );
          },
        );
      },
    );
  }
}

/// Centre column: the login/register card, vertically centred, scrolling
/// only when the window is shorter than the card.
class _AuthCardColumn extends StatelessWidget {
  const _AuthCardColumn({required this.scale, required this.child});

  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [child],
            ),
          ),
        ),
      );
}

/// Right region: the "Why ERAS?" feature column with the trust card pinned
/// below it.
class _SideColumn extends StatelessWidget {
  const _SideColumn({required this.scale});

  final double scale;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: EntranceReveal(
              delay: const Duration(milliseconds: 330),
              duration: const Duration(milliseconds: 600),
              child: WhyErasCard(scale: scale, fillHeight: true),
            ),
          ),
          SizedBox(height: 16 * scale),
          EntranceReveal(
            delay: const Duration(milliseconds: 430),
            duration: const Duration(milliseconds: 600),
            offset: const Offset(0, 10),
            child: TrustCard(scale: scale),
          ),
        ],
      );
}

/// Tablet/mobile: the three columns stack vertically, preserving the visual
/// hierarchy (brand, hero, login/register, feature cards, status cards)
/// without ever overflowing horizontally.
class _NarrowComposition extends StatelessWidget {
  const _NarrowComposition({required this.scale, required this.child});

  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final skin = AuthSkin.of(context);
    final s = scale;
    final markScale = math.max(s, .62);
    final headingSize = 46 * markScale;
    final cardScale = math.max(s, .78);
    final navy = TextStyle(
      fontSize: headingSize,
      height: 1.14,
      letterSpacing: -1.3,
      fontWeight: FontWeight.w900,
      color: skin.text,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // The reference's mobile order is brand, hero, login/register,
        // feature cards, status cards. The illustration and flow strip are
        // only kept when the viewport is large enough for them to coexist
        // with the card hierarchy (tablet and up); they are dropped on
        // phones so the auth card stays near the top of the page.
        final showHero = constraints.maxHeight >= 700;
        final showHeroVisuals =
            constraints.maxWidth >= 760 && constraints.maxHeight >= 720;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 36),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: math.min(700, constraints.maxWidth - 48),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      EntranceReveal(
                        duration: const Duration(milliseconds: 600),
                        offset: const Offset(0, 10),
                        beginScale: .96,
                        child: ErasMark(scale: markScale),
                      ),
                      const Spacer(),
                      const ThemeSwitch(),
                    ],
                  ),
                  if (showHero) ...[
                    SizedBox(height: 26),
                    EntranceReveal(
                      delay: const Duration(milliseconds: 80),
                      duration: const Duration(milliseconds: 550),
                      offset: const Offset(0, 12),
                      child: Text('Right Resource.', style: navy),
                    ),
                    EntranceReveal(
                      delay: const Duration(milliseconds: 180),
                      duration: const Duration(milliseconds: 550),
                      offset: const Offset(0, 12),
                      child: Text('Right Place.', style: navy),
                    ),
                    EntranceReveal(
                      delay: const Duration(milliseconds: 280),
                      duration: const Duration(milliseconds: 550),
                      offset: const Offset(0, 12),
                      child: Text(
                        'Right Time.',
                        style: TextStyle(
                          fontSize: headingSize,
                          height: 1.14,
                          letterSpacing: -1.3,
                          fontWeight: FontWeight.w900,
                          color: skin.tealBright,
                        ),
                      ),
                    ),
                    SizedBox(height: 14),
                    EntranceReveal(
                      delay: const Duration(milliseconds: 380),
                      duration: const Duration(milliseconds: 550),
                      offset: const Offset(0, 10),
                      child: Text(
                        'Smarter coordination. Faster response.\n'
                        'Better outcomes for every emergency.',
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.5,
                          color: skin.textDim,
                        ),
                      ),
                    ),
                  ],
                  if (showHeroVisuals) ...[
                    SizedBox(height: 18),
                    EntranceReveal(
                      delay: const Duration(milliseconds: 260),
                      duration: const Duration(milliseconds: 600),
                      offset: Offset.zero,
                      beginScale: .98,
                      child: SizedBox(
                        height: 210,
                        child: AuthNetworkDiagram(
                          key: const ValueKey('auth-network'),
                          scale: s,
                        ),
                      ),
                    ),
                    SizedBox(height: 16),
                    EntranceReveal(
                      delay: const Duration(milliseconds: 340),
                      duration: const Duration(milliseconds: 550),
                      offset: const Offset(0, 8),
                      child: AuthFlowStrip(
                        key: const ValueKey('auth-flow'),
                        scale: math.max(s, .66),
                      ),
                    ),
                  ],
                  SizedBox(height: 26),
                  EntranceReveal(
                    delay: const Duration(milliseconds: 120),
                    duration: const Duration(milliseconds: 650),
                    offset: const Offset(0, 18),
                    beginScale: .985,
                    child: child,
                  ),
                  SizedBox(height: 20),
                  EntranceReveal(
                    delay: const Duration(milliseconds: 220),
                    duration: const Duration(milliseconds: 600),
                    child: WhyErasCard(scale: cardScale),
                  ),
                  SizedBox(height: 16),
                  EntranceReveal(
                    delay: const Duration(milliseconds: 300),
                    duration: const Duration(milliseconds: 600),
                    offset: const Offset(0, 10),
                    child: TrustCard(scale: cardScale),
                  ),
                  SizedBox(height: 16),
                  AuthStatusCards(
                    key: const ValueKey('auth-status-cards'),
                    scale: cardScale,
                    entranceDelay: const Duration(milliseconds: 360),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Barely perceptible light drift for the light theme: one soft teal/blue
/// radial highlight slowly orbits a small ellipse behind the content, so
/// the page feels polished without visibly "moving". Renders nothing when
/// ambient motion is unavailable (tests, reduced motion), keeping the
/// reference background untouched.
class _AmbientBackdrop extends StatefulWidget {
  const _AmbientBackdrop();

  @override
  State<_AmbientBackdrop> createState() => _AmbientBackdropState();
}

class _AmbientBackdropState extends State<_AmbientBackdrop>
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
      period: const Duration(seconds: 18),
    );
  }

  @override
  void dispose() {
    _ambient?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ambient = _ambient;
    if (ambient == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: CustomPaint(
        painter: _AmbientBackdropPainter(ambient),
        size: Size.infinite,
      ),
    );
  }
}

class _AmbientBackdropPainter extends CustomPainter {
  _AmbientBackdropPainter(this.animation) : super(repaint: animation);

  final Animation<double> animation;

  @override
  void paint(Canvas canvas, Size size) {
    final t = animation.value * 2 * math.pi;
    final center = Offset(
      size.width * (.32 + .05 * math.cos(t)),
      size.height * (.3 + .07 * math.sin(t)),
    );
    final radius = size.shortestSide * .75;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFF12B99D).withValues(alpha: .05),
            const Color(0xFF2478E5).withValues(alpha: .025),
            const Color(0x00FFFFFF),
          ],
          stops: const [0, .55, 1],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
  }

  @override
  bool shouldRepaint(covariant _AmbientBackdropPainter oldDelegate) =>
      oldDelegate.animation != animation;
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xFF5C8BA7).withValues(alpha: .045)
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 42) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    for (double y = 0; y < size.height; y += 42) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) => false;
}
