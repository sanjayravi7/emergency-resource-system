import 'package:flutter/material.dart';

import '../models/eras_models.dart';
import '../theme/app_theme.dart';

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
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: .8,
                      color: AppColors.text,
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
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textFaint,
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

class EmptyState extends StatelessWidget {
  const EmptyState(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Text(
            text,
            style: const TextStyle(fontSize: 13, color: AppColors.textFaint),
            textAlign: TextAlign.center,
          ),
        ),
      );
}

class LegendItem extends StatelessWidget {
  const LegendItem({super.key, required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(fontSize: 11.5, color: AppColors.textDim),
          ),
        ],
      );
}

// ── Pills and chips ────────────────────────────────────────────────────────

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.status});
  final RequestStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = statusColors(status);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(20),
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
    final colors = priorityColors(priority);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(4),
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
    final meta = resourceMetaFor(type.isEmpty ? name : type);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
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
          Text(
            quantity == null ? name : '$name × $quantity',
            style: const TextStyle(fontSize: 12.5, color: AppColors.text),
          ),
          if (trailingText != null) ...[
            const SizedBox(width: 6),
            Text(
              trailingText!,
              style: const TextStyle(fontSize: 11, color: AppColors.textFaint),
            ),
          ],
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
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
                fontSize: 9.5, color: AppColors.textFaint, letterSpacing: .5),
          ),
          const SizedBox(height: 1),
          Text(
            value,
            style: const TextStyle(fontSize: 12.5, color: AppColors.text),
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
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: const TextStyle(
            fontSize: 11, color: AppColors.textFaint, letterSpacing: .5),
      );
}

// ── Header stats ───────────────────────────────────────────────────────────

class Stat extends StatelessWidget {
  const Stat({super.key, required this.label, required this.value, this.color});
  final String label;
  final int value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '$value',
          style: monoStyle(
            size: 18,
            color: color ?? AppColors.text,
            weight: FontWeight.w600,
          ),
        ),
        Text(
          label.toUpperCase(),
          style: const TextStyle(
              fontSize: 9.5, color: AppColors.textFaint, letterSpacing: .6),
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$value',
          style: monoStyle(
            size: 13,
            color: color ?? AppColors.text,
            weight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(fontSize: 10.5, color: AppColors.textFaint),
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
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: AppColors.teal,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'ERAS',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.text,
              ),
            ),
            if (subtitle != null)
              Text(
                subtitle!,
                style:
                    const TextStyle(fontSize: 10, color: AppColors.textFaint),
              ),
          ],
        ),
      ],
    );
  }
}

// ── Navigation ─────────────────────────────────────────────────────────────

class NavButton extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: active ? AppColors.tealDim : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: active ? AppColors.teal : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(
              item.icon,
              size: 17,
              color: active ? AppColors.teal : AppColors.textDim,
            ),
            const SizedBox(width: 10),
            Text(
              item.label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                color: active ? AppColors.teal : AppColors.textDim,
              ),
            ),
          ],
        ),
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
    return Container(
      width: 208,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 18, 14, 14),
            child: Brand(subtitle: roleLabel),
          ),
          const Divider(height: 1, color: AppColors.border),
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
          const Divider(height: 1, color: AppColors.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    clock,
                    style:
                        monoStyle(size: 12.5, color: AppColors.textDim),
                  ),
                ),
                IconButton(
                  tooltip: 'Reload from database',
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh,
                      size: 18, color: AppColors.textDim),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
            child: OutlinedButton.icon(
              onPressed: onLogout,
              icon: const Icon(Icons.logout, size: 15),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textDim,
                side: const BorderSide(color: AppColors.border),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
              label: const Text('Sign out', style: TextStyle(fontSize: 12)),
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
    var index = items.indexWhere((item) => item.view == activeView);
    if (index < 0) index = 0;

    return NavigationBar(
      height: 62,
      backgroundColor: AppColors.surface,
      indicatorColor: AppColors.tealDim,
      selectedIndex: index,
      onDestinationSelected: (i) => onViewChanged(items[i].view),
      destinations: items
          .map(
            (item) => NavigationDestination(
              icon: Icon(item.icon, size: 20),
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
  });

  final String title, subtitle;
  final int pending, active, completed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppColors.text,
                      ),
                    ),
                    if (loading) ...[
                      const SizedBox(width: 10),
                      const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textFaint),
                ),
              ],
            ),
          ),
          Stat(label: 'pending', value: pending, color: AppColors.amber),
          const SizedBox(width: 22),
          Stat(label: 'active', value: active, color: AppColors.blue),
          const SizedBox(width: 22),
          Stat(label: 'closed', value: completed, color: AppColors.teal),
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
  });

  final String clock;
  final int pending, active, completed;
  final String title;
  final VoidCallback onRefresh;
  final VoidCallback onLogout;

  @override
  Size get preferredSize => const Size.fromHeight(96);

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              children: [
                const Expanded(child: Brand()),
                Text(clock,
                    style: monoStyle(size: 12, color: AppColors.textFaint)),
                IconButton(
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh,
                      size: 18, color: AppColors.textDim),
                ),
                IconButton(
                  onPressed: onLogout,
                  icon: const Icon(Icons.logout,
                      size: 17, color: AppColors.textDim),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.text,
                    ),
                  ),
                ),
                MiniStat(
                    label: 'pending', value: pending, color: AppColors.amber),
                const SizedBox(width: 10),
                MiniStat(label: 'active', value: active, color: AppColors.blue),
                const SizedBox(width: 10),
                MiniStat(
                    label: 'closed', value: completed, color: AppColors.teal),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
