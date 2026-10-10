import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../ui/shared.dart';
import 'data/order_controller.dart';
import 'item_editor_page.dart';
import 'online_platform_picker.dart';

class OrderPanel extends StatelessWidget {
  final OrderController controller;
  final VoidCallback checkout, details, kot;
  final VoidCallback? saved, clearEmpty;
  final bool actionsBusy;
  const OrderPanel(
    this.controller, {
    super.key,
    required this.checkout,
    required this.kot,
    required this.details,
    this.saved,
    this.clearEmpty,
    this.actionsBusy = false,
  });
  Future<void> editItem(BuildContext context, int index) async {
    final tableCleared = await openPage<bool>(
      context,
      ItemEditorPage(controller, index),
    );
    // The order workspace belongs to a released table. Return straight to the
    // floor so it refreshes to its new empty status.
    if (tableCleared == true && context.mounted) Navigator.of(context).pop();
  }

  Future<bool> confirmTableRelease(BuildContext context) async {
    final answer = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.table_restaurant_outlined),
        title: const Text('Last item removed'),
        content: const Text(
          'This is the final item on this table. Do you want to mark the table as empty?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep occupied'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Mark table empty'),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  Future<void> reduceItem(BuildContext context, int index) async {
    final item = controller.items[index];
    final finalDiningItem =
        number(item['quantity']) == 1 && controller.lastDiningItem;
    final clearTable = finalDiningItem && await confirmTableRelease(context);
    controller.quantity(index, -1);
    await controller.flush();
    if (clearTable) {
      await controller.clearEmptyDiningTable();
      if (context.mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([controller, controller.session]),
    builder: (context, _) => Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          controller.order['order_type'] == 'dine_in'
                              ? 'Table ${controller.order['table_number']}'
                              : '${controller.order['table_number']}',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 5),
                        Text(
                          switch (controller.order['order_type']) {
                            'dine_in' => 'DINE-IN ORDER',
                            'pos' => 'COUNTER ORDER',
                            'online' => 'ONLINE ORDER',
                            _ => 'TAKEAWAY ORDER',
                          },
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.black54,
                            letterSpacing: 1,
                          ),
                        ),
                        if (controller.order['order_type'] == 'online')
                          Text(
                            onlinePlatformLabel(controller.order),
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.black54,
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Undo last item change',
                    onPressed:
                        !actionsBusy &&
                            controller.session.featureEnabled('order_edit') &&
                            controller.canUndo
                        ? controller.undo
                        : null,
                    icon: const Icon(Icons.undo),
                  ),
                  IconButton(
                    tooltip: 'Order notes',
                    onPressed:
                        actionsBusy ||
                            controller.saving ||
                            !controller.session.featureEnabled('order_edit')
                        ? null
                        : details,
                    icon: const Icon(Icons.edit_note),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _CustomerFields(
                controller,
                key: ValueKey(controller.order['id']),
                enabled:
                    !actionsBusy &&
                    !controller.saving &&
                    controller.session.featureEnabled('order_edit'),
              ),
            ],
          ),
        ),
        const Divider(),
        Expanded(
          child: controller.items.isEmpty
              ? const EmptyState(
                  'Start this order',
                  'Tap a menu item to add it.',
                  icon: Icons.receipt_long_outlined,
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: controller.items.length,
                  separatorBuilder: (_, _) => const Divider(),
                  itemBuilder: (context, index) {
                    final item = controller.items[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item['item_name'],
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 5),
                          Row(
                            children: [
                              IconButton.filledTonal(
                                tooltip: 'Reduce quantity',
                                onPressed:
                                    actionsBusy ||
                                        controller.saving ||
                                        !controller.session.featureEnabled(
                                          'order_edit',
                                        )
                                    ? null
                                    : () async {
                                        try {
                                          await reduceItem(context, index);
                                        } catch (error) {
                                          if (context.mounted) {
                                            message(context, error);
                                          }
                                        }
                                      },
                                icon: const Icon(Icons.remove, size: 17),
                              ),
                              SizedBox(
                                width: 36,
                                child: Text(
                                  '${item['quantity']}',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              IconButton.filledTonal(
                                tooltip: 'Increase quantity',
                                onPressed:
                                    actionsBusy ||
                                        controller.saving ||
                                        !controller.session.featureEnabled(
                                          'order_edit',
                                        )
                                    ? null
                                    : () {
                                        try {
                                          controller.quantity(index, 1);
                                        } catch (error) {
                                          message(context, error);
                                        }
                                      },
                                icon: const Icon(Icons.add, size: 17),
                              ),
                              const Spacer(),
                              IconButton(
                                tooltip: 'Item note, discount or cancellation',
                                onPressed:
                                    actionsBusy ||
                                        controller.saving ||
                                        !controller.session.featureEnabled(
                                          'order_edit',
                                        )
                                    ? null
                                    : () => editItem(context, index),
                                icon: const Icon(Icons.edit_note),
                              ),
                              Text(
                                money(
                                  number(item['quantity']) *
                                      number(item['price_minor']),
                                ),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: line)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (controller.saving || actionsBusy) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
              ],
              if (controller.persistenceError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    controller.persistenceError!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              Wrap(
                spacing: 12,
                runSpacing: 6,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        controller.persistenceError != null
                            ? Icons.error_outline
                            : controller.draftSaving
                            ? Icons.sync
                            : Icons.check_circle_outline,
                        size: 15,
                        color: controller.persistenceError != null
                            ? Colors.red
                            : controller.draftSaving
                            ? deepIndigo
                            : const Color(0xFF15803D),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        controller.persistenceError != null
                            ? 'Save needs attention'
                            : controller.draftSaving
                            ? 'Saving on device…'
                            : controller.draftSaved
                            ? 'Saved on device'
                            : 'Ready for items',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                  Text(
                    controller.kotPendingQuantity > 0
                        ? 'KOT pending: ${controller.kotPendingQuantity} item(s)'
                        : controller.items.isEmpty
                        ? 'No items yet'
                        : 'KOT up to date',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: controller.kotPendingQuantity > 0
                          ? const Color(0xFFB45309)
                          : const Color(0xFF15803D),
                    ),
                  ),
                  if (controller.session.queued > 0)
                    Text(
                      'Sync pending: ${controller.session.queued}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: secondaryText,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Subtotal',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    money(controller.subtotal),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Changes save automatically. KOT prints new items only.',
                style: TextStyle(fontSize: 11, color: secondaryText),
              ),
              const SizedBox(height: 12),
              if (controller.items.isEmpty &&
                  controller.order['order_type'] == 'dine_in')
                OutlinedButton.icon(
                  onPressed: actionsBusy || controller.saving
                      ? null
                      : clearEmpty,
                  icon: const Icon(Icons.table_restaurant_outlined, size: 18),
                  label: const Text('Release table'),
                ),
              if ([
                'dine_in',
                'pos',
              ].contains(controller.order['order_type'])) ...[
                OutlinedButton.icon(
                  onPressed:
                      actionsBusy ||
                          controller.saving ||
                          controller.items.isEmpty
                      ? null
                      : () async {
                          if (actionsBusy || controller.saving) return;
                          FocusScope.of(context).unfocus();
                          try {
                            await controller.save();
                            if (context.mounted) saved?.call();
                          } catch (error) {
                            if (context.mounted) message(context, error);
                          }
                        },
                  icon: Icon(
                    controller.saving
                        ? Icons.hourglass_top
                        : Icons.save_outlined,
                    size: 18,
                  ),
                  label: Text(
                    controller.saving
                        ? 'Saving order…'
                        : controller.order['order_type'] == 'dine_in' &&
                              saved != null
                        ? 'Save & close'
                        : 'Save order',
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed:
                          actionsBusy ||
                              controller.saving ||
                              controller.items.isEmpty ||
                              !controller.session.featureEnabled('kot')
                          ? null
                          : kot,
                      icon: const Icon(Icons.soup_kitchen_outlined, size: 18),
                      label: const Text('KOT'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed:
                          actionsBusy ||
                              controller.saving ||
                              controller.items.isEmpty ||
                              !controller.session.cashier ||
                              !controller.session.featureEnabled('invoices')
                          ? null
                          : checkout,
                      child: const Text(
                        'Bill / payment',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _CustomerFields extends StatefulWidget {
  final OrderController controller;
  final bool enabled;
  const _CustomerFields(this.controller, {super.key, this.enabled = true});
  @override
  State<_CustomerFields> createState() => _CustomerFieldsState();
}

class _CustomerFieldsState extends State<_CustomerFields> {
  late final name = TextEditingController(
    text: widget.controller.order['customer_name'] ?? '',
  );
  late final phone = TextEditingController(
    text: widget.controller.order['customer_phone'] ?? '',
  );
  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: TextField(
          enabled: widget.enabled,
          controller: name,
          onChanged: (value) => widget.controller.text('customer_name', value),
          decoration: const InputDecoration(
            labelText: 'Customer name',
            labelStyle: TextStyle(fontSize: 12),
            isDense: true,
          ),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: TextField(
          enabled: widget.enabled,
          controller: phone,
          keyboardType: TextInputType.phone,
          onChanged: (value) => widget.controller.text('customer_phone', value),
          decoration: const InputDecoration(
            labelText: 'Mobile number',
            labelStyle: TextStyle(fontSize: 12),
            isDense: true,
          ),
        ),
      ),
    ],
  );
}
