import 'package:flutter/material.dart';

import '../models/eras_models.dart';
import '../theme/app_theme.dart';

/// Per-resource allocation for one accepted emergency.
///
/// Every required resource is allocated independently: the responder picks
/// the quantity for a single resource at a time and the backend creates one
/// Allocation row inside a locked, serializable transaction.
class AllocationDialog extends StatefulWidget {
  const AllocationDialog({
    super.key,
    required this.requestId,
    required this.requestProvider,
    required this.inventoryProvider,
    required this.onAllocate,
    required this.onCancelAllocation,
    required this.onDispatchAllocation,
    required this.onMarkDelivered,
  });

  final int requestId;
  final EmergencyRequest? Function(int requestId) requestProvider;
  final List<BackendResponderResource> Function() inventoryProvider;

  final Future<bool> Function({
    required int requestId,
    required int resourceId,
    required int responderResourceId,
    required int quantity,
  })
  onAllocate;

  final Future<bool> Function(int allocationId) onCancelAllocation;
  final Future<void> Function(AllocationLine allocation) onDispatchAllocation;

  /// Responder-side fallback for DISPATCHED → DELIVERED when the requester
  /// never confirms receipt. The caller shows its own confirmation dialog
  /// and lets the backend lifecycle recompute availability.
  final Future<void> Function(AllocationLine allocation) onMarkDelivered;

  @override
  State<AllocationDialog> createState() => _AllocationDialogState();
}

class _AllocationDialogState extends State<AllocationDialog> {
  final Map<int, int> quantities = <int, int>{};
  bool busy = false;

  EmergencyRequest? get request => widget.requestProvider(widget.requestId);

  BackendResponderResource? inventoryFor(int resourceId) {
    return firstWhereOrNull(
      widget.inventoryProvider(),
      (item) => item.resourceId == resourceId,
    );
  }

  int quantityFor(RequiredResourceLine line, int maxQuantity) {
    final current = quantities[line.resourceId] ?? maxQuantity;
    if (current > maxQuantity) return maxQuantity;
    if (current < 1) return 1;
    return current;
  }

  Future<void> allocate(
    RequiredResourceLine line,
    BackendResponderResource inventory,
    int quantity,
  ) async {
    setState(() => busy = true);

    final ok = await widget.onAllocate(
      requestId: widget.requestId,
      resourceId: line.resourceId,
      responderResourceId: inventory.id,
      quantity: quantity,
    );

    if (!mounted) return;

    setState(() {
      busy = false;
      if (ok) quantities.remove(line.resourceId);
    });

    if (ok && request == null && mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> cancelAllocation(int allocationId) async {
    setState(() => busy = true);

    await widget.onCancelAllocation(allocationId);

    if (!mounted) return;

    setState(() => busy = false);

    if (request == null && mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> dispatchAllocation(AllocationLine allocation) async {
    setState(() => busy = true);
    await widget.onDispatchAllocation(allocation);
    if (!mounted) return;
    setState(() => busy = false);
  }

  Future<void> markDelivered(AllocationLine allocation) async {
    setState(() => busy = true);
    await widget.onMarkDelivered(allocation);
    if (!mounted) return;
    setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final current = request;

    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(
        current == null
            ? 'Allocation'
            : 'Allocate resources · ${current.displayId}',
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
      content: SizedBox(
        width: 520,
        child: current == null
            ? const Text(
                'This request is no longer available.',
                style: TextStyle(fontSize: 13, color: AppColors.textFaint),
              )
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${current.emergencyType} · ${current.location}',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.textDim,
                      ),
                    ),
                    const SizedBox(height: 14),
                    ...current.requiredResources.map(
                      (line) => _resourceRow(current, line),
                    ),
                    if (current.activeAllocations.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'ALLOCATIONS',
                        style: TextStyle(
                          fontSize: 10,
                          color: AppColors.textFaint,
                          letterSpacing: .6,
                        ),
                      ),
                      const SizedBox(height: 6),
                      ...current.activeAllocations.map(
                        (allocation) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '#${allocation.id} · ${allocation.resourceName} × '
                                  '${allocation.quantity} · ${allocation.status}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                              if (allocation.isReserved)
                                TextButton(
                                  onPressed: busy
                                      ? null
                                      : () => dispatchAllocation(allocation),
                                  style: TextButton.styleFrom(
                                    foregroundColor: AppColors.blue,
                                  ),
                                  child: const Text(
                                    'Dispatch',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                )
                              else if (allocation.isDispatched)
                                TextButton(
                                  onPressed: busy
                                      ? null
                                      : () => markDelivered(allocation),
                                  style: TextButton.styleFrom(
                                    foregroundColor: AppColors.teal,
                                  ),
                                  child: const Text(
                                    'Mark Delivered',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                )
                              else if (allocation.isDelivered)
                                const Text(
                                  'Delivered',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.teal,
                                  ),
                                ),
                              if (!allocation.isDelivered)
                                TextButton(
                                  onPressed: busy
                                      ? null
                                      : () => cancelAllocation(allocation.id),
                                  style: TextButton.styleFrom(
                                    foregroundColor: AppColors.red,
                                  ),
                                  child: const Text(
                                    'Cancel',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _resourceRow(EmergencyRequest current, RequiredResourceLine line) {
    final allocated = current.allocatedFor(line.resourceId);
    final remaining = current.remainingFor(line.resourceId);
    final inventory = inventoryFor(line.resourceId);

    final maxQuantity = inventory == null
        ? 0
        : (remaining < inventory.availableQuantity
              ? remaining
              : inventory.availableQuantity);

    final quantity = maxQuantity <= 0 ? 0 : quantityFor(line, maxQuantity);

    String? blockedReason;
    if (remaining <= 0) {
      blockedReason = 'Fully allocated';
    } else if (inventory == null) {
      blockedReason = 'You do not carry this resource';
    } else if (inventory.status != 'AVAILABLE') {
      blockedReason = 'Your inventory is ${inventory.status}';
    } else if (inventory.availableQuantity <= 0) {
      blockedReason = 'No units left in your inventory';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  line.resourceName,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                'required ${line.quantity} · allocated $allocated · left $remaining',
                style: monoStyle(size: 11, color: AppColors.textDim),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            inventory == null
                ? 'Your inventory: none'
                : 'Your inventory: ${inventory.availableQuantity}/${inventory.totalQuantity} (${inventory.status})',
            style: const TextStyle(fontSize: 11.5, color: AppColors.textFaint),
          ),
          const SizedBox(height: 8),
          if (blockedReason != null)
            Text(
              blockedReason,
              style: const TextStyle(fontSize: 12, color: AppColors.amber),
            )
          else
            Row(
              children: [
                IconButton(
                  onPressed: busy || quantity <= 1
                      ? null
                      : () => setState(
                          () => quantities[line.resourceId] = quantity - 1,
                        ),
                  icon: const Icon(Icons.remove, size: 16),
                ),
                Text(
                  '$quantity',
                  style: monoStyle(
                    size: 14,
                    color: AppColors.text,
                    weight: FontWeight.w600,
                  ),
                ),
                IconButton(
                  onPressed: busy || quantity >= maxQuantity
                      ? null
                      : () => setState(
                          () => quantities[line.resourceId] = quantity + 1,
                        ),
                  icon: const Icon(Icons.add, size: 16),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: busy || inventory == null || quantity <= 0
                      ? null
                      : () => allocate(line, inventory, quantity),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.blue,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  child: const Text(
                    'Allocate',
                    style: TextStyle(fontSize: 12.5),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
