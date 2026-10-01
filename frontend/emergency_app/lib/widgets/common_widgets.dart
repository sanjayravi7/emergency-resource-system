import 'package:flutter/material.dart';

import '../models/eras_models.dart';
import '../services/socket_service.dart';
import '../theme/app_theme.dart';
import 'auth_motion.dart';

// ── Panel shell ────────────────────────────────────────────────────────────

class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.title,
    required this.child,
    this.hint = '',
    this.trailing,
  });

  final String title;
  final String hint;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);

    return AnimatedContainer(
      duration: AuthMotion.normal,
      curve: AuthMotion.outCurve,
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: p.surface,
        border: Border.all(color: p.cardBorder),
        borderRadius: BorderRadius.circular(8),
        boxShadow: p.dark
            ? [
                BoxShadow(
                  color: p.cardShadow,
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ]
            : const [],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: p.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: .8,
                      color: p.text,
                    ),
                  ),
                ),
                if (trailing != null)
                  trailing!
                else if (hint.isNotEmpty)
                  Flexible(
                    child: Text(
                      hint,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 11,
                        color: p.dark ? p.textDim : p.textFaint,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// Compact empty-state block. It is content-driven (no fixed / viewport
/// height) so a panel with nothing to show never turns into a giant blank
/// region. An optional [title] + [icon] give important empty states (for
/// example "NO COMPATIBLE REQUESTS") a clear, but still small, header.
class EmptyState extends StatelessWidget {
  const EmptyState(this.text, {super.key, this.title, this.icon});

  final String text;
  final String? title;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);

    return EntranceReveal(
      offset: const Offset(0, 6),
      duration: AuthMotion.normal,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 22, color: p.textFaint),
                  const SizedBox(height: 8),
                ],
                if (title != null) ...[
                  Text(
                    title!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: .6,
                      color: p.textDim,
                    ),
                  ),
                  const SizedBox(height: 5),
                ],
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: p.dark ? p.textDim : p.textFaint,
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class LegendItem extends StatelessWidget {
  const LegendItem({super.key, required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final labelWidget = Text(
          label,
          softWrap: true,
          style: TextStyle(
            fontSize: 11.5,
            color: p.textDim,
            height: 1.25,
          ),
        );

        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(top: 3),
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
            // Narrow phone widths (320 px) cannot fit the longest legend label
            // on one line. When the available width is bounded the label is
            // allowed to wrap instead of overflowing the Row; unbounded
            // layouts keep the original intrinsic sizing.
            if (constraints.hasBoundedWidth)
              Flexible(child: labelWidget)
            else
              labelWidget,
          ],
        );
      },
    );
  }
}

class ConnectionStatusIndicator extends StatelessWidget {
  const ConnectionStatusIndicator({
    super.key,
    required this.status,
    this.compact = false,
  });

  final RealtimeConnectionStatus status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);
    final (label, color, icon) = switch (status) {
      RealtimeConnectionStatus.connected => (
          'CONNECTED',
          p.teal,
          Icons.wifi_rounded
        ),
      RealtimeConnectionStatus.reconnecting => (
          'RECONNECTING',
          p.amber,
          Icons.sync_rounded
        ),
      RealtimeConnectionStatus.offline => (
          'OFFLINE',
          p.red,
          Icons.wifi_off_rounded
        ),
    };
    final borderColor = color.withValues(alpha: p.dark ? .42 : .35);

    return Semantics(
      label: 'Realtime connection $label',
      child: AnimatedContainer(
        duration: AuthMotion.fast,
        curve: AuthMotion.outCurve,
        key: const ValueKey<String>('connection-status-indicator'),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 7 : 9,
          vertical: compact ? 4 : 5,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: p.dark ? .16 : .11),
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: compact ? 12 : 13, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: monoStyle(
                size: compact ? 9 : 10,
                color: color,
                weight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Pills and chips ────────────────────────────────────────────────────────

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.status});
  final RequestStatus status;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);
    final colors = statusColors(status, p);
    final pillBorder = p.dark
        ? Border.all(color: colors.text.withValues(alpha: .28))
        : null;

    return AnimatedContainer(
      duration: AuthMotion.fast,
      curve: AuthMotion.outCurve,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(20),
        border: pillBorder,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration:
                BoxDecoration(color: colors.text, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            statusLabel(status),
            style: monoStyle(
                size: 11, color: colors.text, weight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

class PriorityPill extends StatelessWidget {
  const PriorityPill({super.key, required this.priority});
  final String priority;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);
    final colors = priorityColors(priority, p);
    final pillBorder = p.dark
        ? Border.all(color: colors.text.withValues(alpha: .28))
        : null;

    return AnimatedContainer(
      duration: AuthMotion.fast,
      curve: AuthMotion.outCurve,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(4),
        border: pillBorder,
      ),
      child: Text(
        priority.toUpperCase(),
        style:
            monoStyle(size: 10.5, color: colors.text, weight: FontWeight.w600),
      ),
    );
  }
}

/// Icon + name for one resource line, derived from the backend resource type.
class ResourceChip extends StatelessWidget {
  const ResourceChip({
    super.key,
    required this.name,
    required this.type,
    this.quantity,
    this.trailingText,
  });

  final String name;
  final String type;
  final int? quantity;
  final String? trailingText;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);
    final meta = resourceMetaFor(type.isEmpty ? name : type, p);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: meta.bg,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(meta.icon, size: 13, color: meta.color),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 1,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  quantity == null ? name : '$name × $quantity',
                  style: TextStyle(fontSize: 12.5, color: p.text),
                ),
                if (trailingText != null)
                  Text(
                    trailingText!,
                    style: TextStyle(
                      fontSize: 11,
                      color: p.textFaint,
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

class InfoChip extends StatelessWidget {
  const InfoChip({super.key, required this.label, required this.value});
  final String label, value;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
                fontSize: 9.5, color: p.textFaint, letterSpacing: .5),
          ),
          const SizedBox(height: 1),
          Text(
            value,
            style: TextStyle(fontSize: 12.5, color: p.text),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: p.dark ? p.textDim : p.textFaint,
        letterSpacing: .5,
      ),
    );
  }
}

// ── Header stats ───────────────────────────────────────────────────────────

class Stat extends StatelessWidget {
  const Stat({super.key, required this.label, required this.value, this.color});
  final String label;
  final int value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        AnimatedSwap(
          duration: AuthMotion.fast,
          offset: const Offset(0, 4),
          child: Text(
            '$value',
            key: ValueKey<int>(value),
            style: monoStyle(
              size: 18,
              color: color ?? p.text,
              weight: FontWeight.w600,
            ),
          ),
        ),
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 9.5,
            color: p.dark ? p.textDim : p.textFaint,
            letterSpacing: .6,
          ),
        ),
      ],
    );
  }
}

class MiniStat extends StatelessWidget {
  const MiniStat(
      {super.key, required this.label, required this.value, this.color});
  final String label;
  final int value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$value',
          style: monoStyle(
            size: 13,
            color: color ?? p.text,
            weight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            color: p.dark ? p.textDim : p.textFaint,
          ),
        ),
      ],
    );
  }
}

class Brand extends StatelessWidget {
  const Brand({super.key, this.subtitle});
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);

    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: p.teal,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 8),
        // The wordmark block must never widen this Row beyond the space the
        // parent allows (the fixed 208px desktop rail, or the remaining
        // app-bar width on mobile). A long "name · ROLE" subtitle therefore
        // ellipsizes instead of overflowing the layout.
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'ERAS',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: p.text,
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: p.dark ? p.textDim : p.textFaint,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Navigation ─────────────────────────────────────────────────────────────

class NavButton extends StatefulWidget {
  const NavButton({
    super.key,
    required this.item,
    required this.active,
    required this.onTap,
  });

  final NavItem item;
  final bool active;
  final VoidCallback onTap;

  @override
  State<NavButton> createState() => _NavButtonState();
}

class _NavButtonState extends State<NavButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);
    final active = widget.active;
    final fg = active ? p.teal : (_hovered ? p.text : p.textDim);
    final hoverBg = p.surface2.withValues(alpha: p.dark ? .72 : .65);
    final bg = active ? p.tealDim : (_hovered ? hoverBg : Colors.transparent);
    final leftColor =
        active ? p.teal : (_hovered ? p.border : Colors.transparent);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: PressableScale(
        scale: 0.99,
        child: InkWell(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: AuthMotion.fast,
            curve: AuthMotion.outCurve,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: bg,
              border: Border(
                left: BorderSide(
                  color: leftColor,
                  width: 3,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  widget.item.icon,
                  size: 17,
                  color: fg,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: AnimatedDefaultTextStyle(
                    duration: AuthMotion.fast,
                    curve: AuthMotion.outCurve,
                    style: TextStyle(
                      fontFamily: 'Arial',
                      fontSize: 13,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      color: fg,
                    ),
                    child: Text(
                      widget.item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class RefreshSpinButton extends StatefulWidget {
  const RefreshSpinButton({
    super.key,
    required this.onPressed,
    this.tooltip = 'Reload from database',
    this.iconSize = 18,
  });

  final VoidCallback onPressed;
  final String tooltip;
  final double iconSize;

  @override
  State<RefreshSpinButton> createState() => _RefreshSpinButtonState();
}

class _RefreshSpinButtonState extends State<RefreshSpinButton> {
  double _turns = 0;

  void _handleTap() {
    if (!AuthMotion.reducedMotion(context)) {
      setState(() => _turns += 1);
    }
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);
    final reduced = AuthMotion.reducedMotion(context);
    final spinDuration =
        reduced ? Duration.zero : const Duration(milliseconds: 420);

    return IconButton(
      tooltip: widget.tooltip,
      onPressed: _handleTap,
      icon: AnimatedRotation(
        turns: _turns,
        duration: spinDuration,
        curve: AuthMotion.outCurve,
        child: Icon(Icons.refresh, size: widget.iconSize, color: p.textDim),
      ),
    );
  }
}

class Rail extends StatelessWidget {
  const Rail({
    super.key,
    required this.items,
    required this.activeView,
    required this.onViewChanged,
    required this.clock,
    required this.roleLabel,
    required this.onRefresh,
    required this.onLogout,
  });

  final List<NavItem> items;
  final ConsoleView activeView;
  final ValueChanged<ConsoleView> onViewChanged;
  final String clock;
  final String roleLabel;
  final VoidCallback onRefresh;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);

    return AnimatedContainer(
      duration: AuthMotion.normal,
      curve: AuthMotion.outCurve,
      width: 208,
      decoration: BoxDecoration(
        color: p.sidebar,
        border: Border(right: BorderSide(color: p.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 18, 14, 14),
            child: Brand(subtitle: roleLabel),
          ),
          Divider(height: 1, color: p.border),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 8),
              children: items
                  .map(
                    (item) => NavButton(
                      item: item,
                      active: item.view == activeView,
                      onTap: () => onViewChanged(item.view),
                    ),
                  )
                  .toList(),
            ),
          ),
          Divider(height: 1, color: p.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    clock,
                    style: monoStyle(size: 12.5, color: p.textDim),
                  ),
                ),
                IconButton(
                  tooltip:
                      p.dark ? 'Switch to light mode' : 'Switch to dark mode',
                  onPressed: ThemeController.toggle,
                  visualDensity: VisualDensity.compact,
                  icon: AnimatedSwap(
                    duration: AuthMotion.fast,
                    child: Icon(
                      p.dark
                          ? Icons.light_mode_rounded
                          : Icons.dark_mode_rounded,
                      key: ValueKey<bool>(p.dark),
                      size: 17,
                      color: p.textDim,
                    ),
                  ),
                ),
                RefreshSpinButton(onPressed: onRefresh),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
            child: PressableScale(
              child: OutlinedButton.icon(
                onPressed: onLogout,
                icon: Icon(Icons.logout, size: 15, color: p.textDim),
                style: OutlinedButton.styleFrom(
                  backgroundColor: p.dark ? p.surface2 : Colors.transparent,
                  foregroundColor: p.textDim,
                  side: BorderSide(color: p.border),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
                label: Text(
                  'Sign out',
                  style: TextStyle(
                    fontSize: 12,
                    color: p.dark ? p.text : p.textDim,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class BottomNav extends StatelessWidget {
  const BottomNav({
    super.key,
    required this.items,
    required this.activeView,
    required this.onViewChanged,
  });

  final List<NavItem> items;
  final ConsoleView activeView;
  final ValueChanged<ConsoleView> onViewChanged;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);
    var index = items.indexWhere((item) => item.view == activeView);
    if (index < 0) index = 0;

    return NavigationBar(
      height: 62,
      backgroundColor: p.sidebar,
      surfaceTintColor: Colors.transparent,
      indicatorColor: p.tealDim,
      selectedIndex: index,
      onDestinationSelected: (i) => onViewChanged(items[i].view),
      destinations: items
          .map(
            (item) => NavigationDestination(
              icon: Icon(item.icon, size: 20, color: p.textDim),
              selectedIcon: Icon(item.icon, size: 20, color: p.teal),
              label: item.label,
            ),
          )
          .toList(),
    );
  }
}

class DesktopTopBar extends StatelessWidget {
  const DesktopTopBar({
    super.key,
    required this.title,
    required this.subtitle,
    required this.pending,
    required this.active,
    required this.completed,
    required this.loading,
    required this.connectionStatus,
  });

  final String title, subtitle;
  final int pending, active, completed;
  final bool loading;
  final RealtimeConnectionStatus connectionStatus;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);

    return AnimatedContainer(
      duration: AuthMotion.normal,
      curve: AuthMotion.outCurve,
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      decoration: BoxDecoration(
        color: p.header,
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // The heading shares the bar with the live counters, so
                    // it has to flex and ellipsize rather than overflow on
                    // narrow desktop windows.
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: p.text,
                        ),
                      ),
                    ),
                    if (loading) ...[
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: p.teal,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: p.dark ? p.textDim : p.textFaint,
                  ),
                ),
              ],
            ),
          ),
          ConnectionStatusIndicator(status: connectionStatus),
          const SizedBox(width: 22),
          Stat(label: 'pending', value: pending, color: p.amber),
          const SizedBox(width: 22),
          Stat(label: 'active', value: active, color: p.blue),
          const SizedBox(width: 22),
          Stat(label: 'closed', value: completed, color: p.teal),
        ],
      ),
    );
  }
}

class MobileAppBar extends StatelessWidget implements PreferredSizeWidget {
  const MobileAppBar({
    super.key,
    required this.clock,
    required this.pending,
    required this.active,
    required this.completed,
    required this.title,
    required this.onRefresh,
    required this.onLogout,
    required this.connectionStatus,
    this.topInset = 0,
  });

  final String clock;
  final int pending, active, completed;
  final String title;
  final RealtimeConnectionStatus connectionStatus;
  final VoidCallback onRefresh;
  final VoidCallback onLogout;
  final double topInset;

  @override
  Size get preferredSize => Size.fromHeight(topInset + 96);

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);

    return AnimatedContainer(
      duration: AuthMotion.normal,
      curve: AuthMotion.outCurve,
      color: p.header,
      // The Scaffold app-bar slot includes [preferredSize]. Keep the status
      // inset in that same budget instead of letting the Column overflow on
      // short Android viewports.
      padding: EdgeInsets.only(top: topInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: p.border)),
            ),
            child: Row(
              children: [
                const Expanded(child: Brand()),
                ConnectionStatusIndicator(
                  status: connectionStatus,
                  compact: true,
                ),
                const SizedBox(width: 7),
                Text(clock, style: monoStyle(size: 12, color: p.textFaint)),
                RefreshSpinButton(onPressed: onRefresh),
                IconButton(
                  onPressed: onLogout,
                  icon: Icon(Icons.logout, size: 17, color: p.textDim),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: p.text,
                    ),
                  ),
                ),
                MiniStat(label: 'pending', value: pending, color: p.amber),
                const SizedBox(width: 10),
                MiniStat(label: 'active', value: active, color: p.blue),
                const SizedBox(width: 10),
                MiniStat(label: 'closed', value: completed, color: p.teal),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
