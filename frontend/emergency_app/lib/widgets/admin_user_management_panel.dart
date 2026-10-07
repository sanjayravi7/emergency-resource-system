import 'package:flutter/material.dart';

import '../models/eras_models.dart';
import '../services/email_privacy.dart';
import '../theme/app_theme.dart';
import 'auth_motion.dart';
import 'common_widgets.dart';

const int adminUserMaxNameLength = 120;
const int adminUserMaxPhoneLength = 20;

/// ADMIN user directory and its compact profile cards.
///
/// Data and mutations stay owned by the dispatch console page, consistent
/// with the rest of the console. This widget is only the responsive presentation
/// layer; the server remains authoritative for every permission and delete
/// decision.
class AdminUserManagementPanel extends StatelessWidget {
  const AdminUserManagementPanel({
    super.key,
    required this.users,
    required this.loading,
    required this.busyUserIds,
    required this.currentUserId,
    required this.onRefresh,
    required this.onViewDetails,
    required this.onEdit,
    required this.onChangeActive,
    required this.onDelete,
  });

  final List<AdminUser> users;
  final bool loading;
  final Set<int> busyUserIds;
  final int? currentUserId;
  final VoidCallback onRefresh;
  final ValueChanged<AdminUser> onViewDetails;
  final ValueChanged<AdminUser> onEdit;
  final ValueChanged<AdminUser> onChangeActive;
  final ValueChanged<AdminUser> onDelete;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);

    return Panel(
      title: 'USER MANAGEMENT',
      hint: 'Profiles and operational history',
      trailing: IconButton(
        key: const Key('refresh-admin-users'),
        tooltip: 'Refresh users',
        onPressed: loading ? null : onRefresh,
        visualDensity: VisualDensity.compact,
        icon: Icon(Icons.refresh_rounded, size: 19, color: p.textDim),
      ),
      child: loading && users.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Center(child: CircularProgressIndicator(color: p.teal)),
            )
          : users.isEmpty
              ? const EmptyState('No users found.')
              : Column(
                  children: [
                    for (var index = 0; index < users.length; index++)
                      EntranceReveal(
                        delay: index < 6
                            ? Duration(milliseconds: 22 * index)
                            : Duration.zero,
                        offset: const Offset(0, 5),
                        child: _AdminUserCard(
                          user: users[index],
                          busy: busyUserIds.contains(users[index].id),
                          isOwnAccount: users[index].id == currentUserId,
                          onViewDetails: onViewDetails,
                          onEdit: onEdit,
                          onChangeActive: onChangeActive,
                          onDelete: onDelete,
                        ),
                      ),
                  ],
                ),
    );
  }
}

class _AdminUserCard extends StatelessWidget {
  const _AdminUserCard({
    required this.user,
    required this.busy,
    required this.isOwnAccount,
    required this.onViewDetails,
    required this.onEdit,
    required this.onChangeActive,
    required this.onDelete,
  });

  final AdminUser user;
  final bool busy;
  final bool isOwnAccount;
  final ValueChanged<AdminUser> onViewDetails;
  final ValueChanged<AdminUser> onEdit;
  final ValueChanged<AdminUser> onChangeActive;
  final ValueChanged<AdminUser> onDelete;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);
    final responderColor = user.responderStatus == null
        ? p.textFaint
        : responderStatusColor(user.responderStatus!, p);
    final email = displayEmailForOthers(
      user.email,
      fallback: 'Email unavailable',
    );

    return LayoutBuilder(
      builder: (_, constraints) {
        final stackActions = constraints.maxWidth < 650;
        final identity = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: p.tealDim,
                borderRadius: BorderRadius.circular(10),
              ),
              child:
                  Icon(Icons.person_outline_rounded, color: p.teal, size: 21),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 3,
                    children: [
                      Text(
                        user.name,
                        key: Key('admin-user-name-${user.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: p.text,
                        ),
                      ),
                      Text(
                        'ID ${user.id}',
                        style: monoStyle(size: 10.5, color: p.textFaint),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    email,
                    key: Key('admin-user-email-${user.id}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: p.textDim),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _UserBadge(
                        label: user.role,
                        color: p.blue,
                        background: p.blueDim,
                      ),
                      _UserBadge(
                        label: user.isActive ? 'ACTIVE' : 'DEACTIVATED',
                        color: user.isActive ? p.teal : p.red,
                        background: user.isActive ? p.tealDim : p.redDim,
                      ),
                      if (user.role == 'RESPONDER')
                        _UserBadge(
                          label: user.responderStatus?.toUpperCase() ?? '—',
                          color: responderColor,
                          background: p.surface2,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.history_rounded, size: 14, color: p.textFaint),
                      const SizedBox(width: 5),
                      Text(
                        '${user.history.total} historical '
                        '${user.history.total == 1 ? 'record' : 'records'}',
                        key: Key('admin-user-history-count-${user.id}'),
                        style: TextStyle(fontSize: 11.5, color: p.textDim),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );

        final actions = Wrap(
          alignment: stackActions ? WrapAlignment.end : WrapAlignment.start,
          spacing: 2,
          runSpacing: 0,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            IconButton(
              key: Key('details-admin-user-${user.id}'),
              tooltip: 'View account details',
              onPressed: busy ? null : () => onViewDetails(user),
              visualDensity: VisualDensity.compact,
              icon:
                  Icon(Icons.info_outline_rounded, size: 18, color: p.textDim),
            ),
            TextButton.icon(
              key: Key('edit-admin-user-${user.id}'),
              onPressed: busy ? null : () => onEdit(user),
              style: TextButton.styleFrom(
                foregroundColor: p.textDim,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              icon: const Icon(Icons.edit_outlined, size: 15),
              label: const Text('Edit'),
            ),
            OutlinedButton.icon(
              key: Key('toggle-admin-user-${user.id}'),
              onPressed: busy || (user.isActive && isOwnAccount)
                  ? null
                  : () => onChangeActive(user),
              style: OutlinedButton.styleFrom(
                foregroundColor: user.isActive ? p.amber : p.teal,
                side: BorderSide(
                  color:
                      (user.isActive ? p.amber : p.teal).withValues(alpha: .5),
                ),
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 9),
              ),
              icon: busy
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: user.isActive ? p.amber : p.teal,
                      ),
                    )
                  : Icon(
                      user.isActive
                          ? Icons.pause_circle_outline_rounded
                          : Icons.play_circle_outline_rounded,
                      size: 16,
                    ),
              label: Text(user.isActive ? 'Deactivate' : 'Activate'),
            ),
            if (user.history.deletable && !isOwnAccount)
              PopupMenuButton<String>(
                key: Key('more-admin-user-${user.id}'),
                tooltip: 'More account actions',
                enabled: !busy,
                onSelected: (action) {
                  if (action == 'delete') onDelete(user);
                },
                itemBuilder: (_) => <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                    key: Key('delete-admin-user-${user.id}'),
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline_rounded,
                            size: 17, color: p.red),
                        const SizedBox(width: 9),
                        Text('Delete', style: TextStyle(color: p.red)),
                      ],
                    ),
                  ),
                ],
                icon: Icon(Icons.more_horiz_rounded, color: p.textDim),
              ),
          ],
        );

        return Container(
          key: Key('admin-user-card-${user.id}'),
          margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: p.dark ? p.surface2.withValues(alpha: .35) : p.surface,
            border: Border.all(color: p.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: stackActions
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    identity,
                    const SizedBox(height: 8),
                    actions,
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: identity),
                    const SizedBox(width: 8),
                    actions,
                  ],
                ),
        );
      },
    );
  }
}

class _UserBadge extends StatelessWidget {
  const _UserBadge({
    required this.label,
    required this.color,
    required this.background,
  });

  final String label;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: p.dark ? background.withValues(alpha: .55) : background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: monoStyle(size: 9, color: color, weight: FontWeight.w700),
      ),
    );
  }
}

enum AdminUserDetailsAction { edit, changeActive }

/// Account detail dialog with the six authoritative history counts.
/// Delete is intentionally absent here: account removal is a secondary action
/// only on a history-free row, never the normal details workflow.
class AdminUserDetailsDialog extends StatelessWidget {
  const AdminUserDetailsDialog({
    super.key,
    required this.user,
    required this.canChangeActive,
  });

  final AdminUser user;
  final bool canChangeActive;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);
    final history = user.history;
    final email = displayEmailForOthers(
      user.email,
      fallback: 'Email unavailable',
    );

    return AlertDialog(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            user.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'ID ${user.id} · $email',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: p.textDim),
          ),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Operational history',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: .5,
                  color: p.text,
                ),
              ),
              const SizedBox(height: 8),
              _HistoryCountRow(
                label: 'Emergencies requested',
                count: history.requests,
              ),
              _HistoryCountRow(
                label: 'Emergencies accepted',
                count: history.acceptedRequests,
              ),
              _HistoryCountRow(
                label: 'Assignments',
                count: history.responderAssignments,
              ),
              _HistoryCountRow(
                label: 'Allocations',
                count: history.allocations,
              ),
              _HistoryCountRow(
                label: 'Inventory',
                count: history.responderResources,
              ),
              _HistoryCountRow(
                label: 'Help types',
                count: history.responderHelpTypes,
              ),
              const SizedBox(height: 10),
              if (history.total > 0)
                Container(
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: p.amberDim,
                    border: Border.all(color: p.amber.withValues(alpha: .35)),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.lock_outline_rounded,
                          size: 17, color: p.amber),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Preserve account — historical ERAS data is linked to this user.',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.35,
                            color: p.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else
                Text(
                  'No ERAS operational history is linked to this user.',
                  style: TextStyle(fontSize: 12, color: p.textDim),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: Key('details-edit-admin-user-${user.id}'),
          onPressed: () =>
              Navigator.of(context).pop(AdminUserDetailsAction.edit),
          style: TextButton.styleFrom(foregroundColor: p.textDim),
          child: const Text('Edit name'),
        ),
        if (canChangeActive)
          TextButton(
            key: Key('details-toggle-admin-user-${user.id}'),
            onPressed: () =>
                Navigator.of(context).pop(AdminUserDetailsAction.changeActive),
            style: TextButton.styleFrom(
              foregroundColor: user.isActive ? p.amber : p.teal,
            ),
            child: Text(user.isActive ? 'Deactivate' : 'Activate'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(foregroundColor: p.textDim),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _HistoryCountRow extends StatelessWidget {
  const _HistoryCountRow({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 12.5, color: p.textDim),
            ),
          ),
          Text(
            '$count',
            style:
                monoStyle(size: 12.5, color: p.text, weight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class AdminUserEditValues {
  const AdminUserEditValues({required this.name, required this.phone});

  final String name;
  final String phone;
}

/// Name and phone editor. Only those two editable profile fields are exposed.
class AdminUserEditDialog extends StatefulWidget {
  const AdminUserEditDialog({super.key, required this.user});

  final AdminUser user;

  @override
  State<AdminUserEditDialog> createState() => _AdminUserEditDialogState();
}

class _AdminUserEditDialogState extends State<AdminUserEditDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _phoneController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.user.name);
    _phoneController = TextEditingController(text: widget.user.phone ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(
      AdminUserEditValues(
        name: _nameController.text.trim(),
        phone: _phoneController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);

    return AlertDialog(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      title: Text(
        'Edit user · ID ${widget.user.id}',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: p.text,
        ),
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  key: const Key('admin-user-name-field'),
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  maxLength: adminUserMaxNameLength,
                  buildCounter: (
                    context, {
                    required currentLength,
                    required isFocused,
                    maxLength,
                  }) =>
                      null,
                  decoration: const InputDecoration(labelText: 'Full name'),
                  validator: (value) {
                    final name = value?.trim() ?? '';
                    if (name.isEmpty) return 'Full name is required';
                    if (name.length > adminUserMaxNameLength) {
                      return 'Name must be $adminUserMaxNameLength characters or fewer';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('admin-user-phone-field'),
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.done,
                  maxLength: adminUserMaxPhoneLength,
                  buildCounter: (
                    context, {
                    required currentLength,
                    required isFocused,
                    maxLength,
                  }) =>
                      null,
                  decoration: const InputDecoration(labelText: 'Phone'),
                  validator: (value) {
                    if ((value?.trim().length ?? 0) > adminUserMaxPhoneLength) {
                      return 'Phone must be $adminUserMaxPhoneLength characters or fewer';
                    }
                    return null;
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('cancel-admin-user-edit-button'),
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(foregroundColor: p.textDim),
          child: const Text('Cancel'),
        ),
        PressableScale(
          child: FilledButton(
            key: const Key('save-admin-user-button'),
            onPressed: _save,
            style: FilledButton.styleFrom(
              backgroundColor: p.teal,
              foregroundColor: Colors.white,
            ),
            child: const Text('Save'),
          ),
        ),
      ],
    );
  }
}
