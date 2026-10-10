import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../ui/shared.dart';
import '../billing/checkout_page.dart';
import '../menu/menu_panel.dart';
import 'data/order_controller.dart';
import 'data/order_draft.dart';
import 'order_details_page.dart';
import 'order_panel.dart';
import 'kot_page.dart';

class OrderWorkspacePage extends StatefulWidget {
  final Session session;
  final Json order;
  final bool embedded;
  const OrderWorkspacePage(
    this.session,
    this.order, {
    super.key,
    this.embedded = false,
  });
  @override
  State<OrderWorkspacePage> createState() => _OrderWorkspacePageState();
}

class _OrderWorkspacePageState extends State<OrderWorkspacePage> {
  late final controller = OrderController(widget.session, widget.order);
  bool showCart = false;
  bool openingAction = false;
  int activePosSlot = 1;
  int visiblePosSlots = 3;

  bool get isMenuPos => widget.order['order_type'] == 'pos';

  @override
  void initState() {
    super.initState();
    unawaited(_restoreSavedMenuPosOrder());
  }

  /// Menu POS has no table card to reopen. Keep its single saved cart visible
  /// after navigating away or reopening the app, until it is finally billed.
  Future<void> _restoreSavedMenuPosOrder() async {
    if (!isMenuPos) {
      return;
    }
    try {
      final saved = (await widget.session.local!.drafts())
          .where(
            (order) =>
                order['order_type'] == 'pos' && order['status'] == 'open',
          )
          .toList();
      final savedSlot = saved.fold<int>(1, (highest, order) {
        final slot = number(order['pos_slot']).clamp(1, 10).toInt();
        return slot > highest ? slot : highest;
      });
      if (!mounted) return;
      setState(() => visiblePosSlots = savedSlot > 3 ? savedSlot : 3);
      final firstSlot = saved.where((order) {
        // Orders saved before slots existed remain in Customer 1.
        final slot = number(order['pos_slot']);
        return slot == 0 || slot == activePosSlot;
      }).firstOrNull;
      controller.startFreshOrder(
        firstSlot ?? newOrder(channel: 'pos', posSlot: activePosSlot),
      );
    } catch (_) {
      // A POS remains usable with a fresh local cart if an old draft cannot
      // be read. The durable database error is shown on the next save.
      if (mounted) {
        controller.startFreshOrder(
          newOrder(channel: 'pos', posSlot: activePosSlot),
        );
      }
    }
  }

  Future<void> switchMenuPosSlot(int slot) async {
    if (!isMenuPos || slot == activePosSlot) return;
    try {
      // Each edit is first persisted as a local draft. Flushing before the
      // switch keeps customer carts separate without waiting for the server.
      await controller.flush();
      final saved = (await widget.session.local!.drafts())
          .where(
            (order) =>
                order['order_type'] == 'pos' &&
                order['status'] == 'open' &&
                number(order['pos_slot']) == slot,
          )
          .firstOrNull;
      if (!mounted) return;
      setState(() {
        activePosSlot = slot;
        showCart = false;
      });
      controller.startFreshOrder(
        saved ?? newOrder(channel: 'pos', posSlot: slot),
      );
    } catch (error) {
      if (mounted) message(context, error);
    }
  }

  Widget menuPosSlots() => Container(
    width: double.infinity,
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 7),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: Text(
              'Saved customers',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
          for (var slot = 1; slot <= visiblePosSlots; slot++)
            Padding(
              padding: const EdgeInsets.only(right: 7),
              child: ChoiceChip(
                label: Text('$slot'),
                selected: activePosSlot == slot,
                onSelected: (_) => switchMenuPosSlot(slot),
              ),
            ),
          if (visiblePosSlots < 10)
            Tooltip(
              message: 'Add another saved customer order',
              child: IconButton.filledTonal(
                onPressed: () => setState(() => visiblePosSlots++),
                icon: const Icon(Icons.add, size: 18),
              ),
            ),
          const SizedBox(width: 8),
          Text(
            '$visiblePosSlots / 10',
            style: const TextStyle(fontSize: 11, color: Colors.black54),
          ),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> checkout() async {
    if (!widget.session.featureEnabled('invoices')) {
      message(context, 'Billing is disabled by the developer.');
      return;
    }
    if (openingAction) return;
    setState(() => openingAction = true);
    try {
      await controller.flush();
      if (controller.items.isEmpty) {
        throw ApiFailure(
          422,
          'Add at least one item before generating the bill.',
        );
      }
      if (!widget.session.cashier) {
        throw ApiFailure(403, 'A cashier or manager can settle this bill.');
      }
      if (mounted) {
        await openPage<bool>(
          context,
          CheckoutPage(widget.session, controller.order),
        );
      }
      final current = await widget.session.local!.get(
        'orders',
        controller.order['id'],
      );
      if (!mounted || current?['status'] != 'billed') return;
      if (controller.order['table_id'] != null || !widget.embedded) {
        Navigator.pop(context);
        return;
      }
      controller.startFreshOrder(
        newOrder(
          channel: isMenuPos ? 'pos' : 'takeaway',
          posSlot: isMenuPos ? activePosSlot : null,
        ),
      );
      setState(() => showCart = false);
    } catch (e) {
      if (mounted) message(context, e);
    } finally {
      if (mounted) setState(() => openingAction = false);
    }
  }

  Future<String?> askTableNumber(String title, String description) async {
    final number = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(description),
            const SizedBox(height: 14),
            TextField(
              controller: number,
              autofocus: true,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => Navigator.pop(dialogContext, number.text),
              decoration: const InputDecoration(
                labelText: 'Table number',
                hintText: 'For example: 1 or 01',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, number.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    number.dispose();
    return value?.trim();
  }

  /// An occupied table can be joined, but never by an accidental tap. The
  /// owner sees the active order first and must wait three seconds before the
  /// confirmation button becomes available.
  Future<bool> confirmOccupiedTableMerge(Json target) async {
    var secondsRemaining = 3;
    Timer? timer;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          timer ??= Timer.periodic(const Duration(seconds: 1), (active) {
            if (!dialogContext.mounted) {
              active.cancel();
              return;
            }
            setDialogState(() {
              secondsRemaining--;
              if (secondsRemaining <= 0) active.cancel();
            });
          });
          final joined = List<String>.from(
            target['joined_table_numbers'] ?? const <String>[],
          );
          final customer = '${target['customer_name'] ?? ''}'.trim();
          return AlertDialog(
            title: const Text('This table is already occupied'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Table ${target['table_number']} has an active order '
                  'with ${target['item_count']} item(s).',
                ),
                if (customer.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Customer: $customer'),
                ],
                if (joined.length > 1) ...[
                  const SizedBox(height: 8),
                  Text('Already joined: ${joined.join(' + ')}'),
                ],
                const SizedBox(height: 14),
                const Text(
                  'Both tables will stay visible as joined. You can later choose one merged bill or separate bills.',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: secondsRemaining > 0
                    ? null
                    : () => Navigator.pop(dialogContext, true),
                icon: const Icon(Icons.call_merge_outlined),
                label: Text(
                  secondsRemaining > 0
                      ? 'Merge (${secondsRemaining}s)'
                      : 'Yes, merge tables',
                ),
              ),
            ],
          );
        },
      ),
    );
    timer?.cancel();
    return accepted == true;
  }

  Future<void> markPending() async {
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Table actions'),
        content: const Text(
          'Choose what should happen with this table and its saved order.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton.icon(
            onPressed: () => Navigator.pop(dialogContext, 'merge'),
            icon: const Icon(Icons.call_merge_outlined),
            label: const Text('Merge table'),
          ),
          TextButton.icon(
            onPressed: () => Navigator.pop(dialogContext, 'move'),
            icon: const Icon(Icons.swap_horiz),
            label: const Text('Customer change table'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'pending'),
            child: const Text('Mark bill pending'),
          ),
        ],
      ),
    );
    if (action == null) return;
    try {
      if (action == 'pending') {
        await controller.markBillPending();
        if (mounted) message(context, 'Table marked bill pending.');
        return;
      }
      final tableNumber = await askTableNumber(
        action == 'move' ? 'Customer change table' : 'Merge table',
        action == 'move'
            ? 'All saved menu items will move to the new empty table.'
            : 'The selected table will join this table for one combined bill.',
      );
      if (tableNumber == null || tableNumber.isEmpty) return;
      if (action == 'move') {
        await controller.changeTable(tableNumber);
        if (mounted) {
          message(
            context,
            'Order moved to table ${controller.order['table_number']}.',
          );
          Navigator.pop(context);
        }
      } else {
        final target = await widget.session.previewDiningTableMerge(
          controller.order,
          tableNumber,
        );
        if (!mounted) return;
        final confirmed = target['is_empty'] == true
            ? true
            : await confirmOccupiedTableMerge(target);
        if (!mounted || !confirmed) return;
        await controller.mergeTable(tableNumber);
        if (mounted) {
          message(
            context,
            'Tables joined. One combined bill is ready at checkout.',
          );
          Navigator.pop(context);
        }
      }
    } catch (e) {
      if (mounted) message(context, e);
    }
  }

  Future<void> clearEmptyTable() async {
    final clear = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Release this table?'),
        content: const Text(
          'The order has no items. This will cancel the open order and release the table.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep occupied'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Release table'),
          ),
        ],
      ),
    );
    if (clear != true) return;
    try {
      await controller.clearEmptyDiningTable();
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) message(context, error);
    }
  }

  Future<void> openKot() async {
    if (!widget.session.featureEnabled('kot')) {
      message(context, 'Kitchen tickets are disabled by the developer.');
      return;
    }
    if (openingAction) return;
    setState(() => openingAction = true);
    try {
      if (controller.items.isEmpty) {
        throw ApiFailure(422, 'Add at least one item before preparing a KOT.');
      }
      await controller.flush();
      await controller.save();
      if (mounted) {
        await openPage(context, KotPage(widget.session, controller.order));
        await controller.refreshKotState();
      }
    } catch (error) {
      if (mounted) message(context, error);
    } finally {
      if (mounted) setState(() => openingAction = false);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final desktop = box.maxWidth >= 1000;
      final menu = MenuPanel(
        widget.session,
        onAdd: (item, combo) {
          if (!openingAction && !controller.saving) {
            try {
              controller.add(item, combo: combo);
            } catch (error) {
              message(context, error);
            }
          }
        },
      );
      final cart = OrderPanel(
        controller,
        checkout: checkout,
        kot: openKot,
        details: () => openPage(context, OrderDetailsPage(controller)),
        clearEmpty: clearEmptyTable,
        actionsBusy: openingAction,
        saved: () {
          if (controller.order['table_id'] != null &&
              Navigator.of(context).canPop()) {
            message(
              context,
              controller.kotPendingQuantity > 0
                  ? 'Order saved. Table remains open; kitchen KOT is pending.'
                  : 'Order saved. Table remains open for service.',
            );
            Navigator.pop(context);
          } else {
            message(
              context,
              'Order saved. Continue adding items or open payment when ready.',
            );
          }
        },
      );
      return Scaffold(
        appBar: AppBar(
          title: Text(
            isMenuPos
                ? 'Menu POS · Customer $activePosSlot'
                : controller.order['order_type'] == 'dine_in'
                ? desktop
                      ? 'Dine-in · Table ${controller.order['table_number']}'
                      : 'Table ${controller.order['table_number']}'
                : 'Order · ${controller.order['table_number']}',
          ),
          actions: [
            if (!desktop && !showCart)
              AnimatedBuilder(
                animation: controller,
                builder: (context, _) => IconButton(
                  tooltip: 'Undo last item change',
                  onPressed: !openingAction && controller.canUndo
                      ? controller.undo
                      : null,
                  icon: const Icon(Icons.undo),
                ),
              ),
            if (controller.order['order_type'] == 'dine_in')
              IconButton(
                tooltip: 'Mark bill pending',
                onPressed: markPending,
                icon: const Icon(Icons.pending_actions),
              ),
            if (!desktop)
              IconButton(
                tooltip: showCart ? 'Menu' : 'Order items',
                onPressed: () => setState(() => showCart = !showCart),
                icon: Icon(
                  showCart
                      ? Icons.restaurant_menu
                      : Icons.shopping_cart_outlined,
                ),
              ),
          ],
        ),
        body: Column(
          children: [
            if (isMenuPos) menuPosSlots(),
            if (controller.hasMergedTables)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                color: const Color(0xFFECFDF5),
                child: Text(
                  "Merged tables: ${List<String>.from(controller.order['merged_table_numbers'] ?? []).join(' + ')} · Shared order",
                  style: const TextStyle(
                    color: Color(0xFF0F766E),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            Expanded(
              child: desktop
                  ? Row(
                      children: [
                        Expanded(child: menu),
                        const VerticalDivider(width: 1),
                        SizedBox(width: 390, child: cart),
                      ],
                    )
                  : showCart
                  ? cart
                  : menu,
            ),
          ],
        ),
        bottomNavigationBar: !desktop && !showCart
            ? SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: AnimatedBuilder(
                    animation: controller,
                    builder: (context, _) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${controller.items.fold<int>(0, (sum, item) => sum + number(item['quantity']))} items · ${money(controller.subtotal)} · KOT pending ${controller.kotPendingQuantity}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () =>
                                    setState(() => showCart = true),
                                child: const Text('View order'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton(
                                onPressed:
                                    controller.items.isEmpty ||
                                        controller.saving ||
                                        openingAction
                                    ? null
                                    : openKot,
                                child: const Text('KOT'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton(
                                onPressed:
                                    controller.items.isEmpty ||
                                        controller.saving ||
                                        openingAction
                                    ? null
                                    : checkout,
                                child: const Text('Bill'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              )
            : null,
      );
    },
  );
}
