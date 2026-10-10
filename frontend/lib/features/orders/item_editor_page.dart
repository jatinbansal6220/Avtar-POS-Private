import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../billing/billing_calculator.dart';
import 'data/order_controller.dart';

/// Full-screen item note/discount editor, including accountable cancellation.
class ItemEditorPage extends StatefulWidget {
  final OrderController controller;
  final int index;
  const ItemEditorPage(this.controller, this.index, {super.key});
  @override
  State<ItemEditorPage> createState() => _ItemEditorPageState();
}

class _ItemEditorPageState extends State<ItemEditorPage> {
  late final item = widget.controller.items[widget.index];
  late final notes = TextEditingController(text: '${item['notes'] ?? ''}');
  late final discount = TextEditingController(
    text: (number(item['discount_value']) / 100).toStringAsFixed(2),
  );
  final reason = TextEditingController();
  late String type = '${item['discount_type'] ?? 'percent'}';
  String? error;
  @override
  void dispose() {
    notes.dispose();
    discount.dispose();
    reason.dispose();
    super.dispose();
  }

  Future<bool> confirmTableRelease() async {
    final answer = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.table_restaurant_outlined),
        title: const Text('Last item removed'),
        content: const Text(
          'This is the final item on this table. Do you want to mark the table as empty? Choosing Keep occupied lets you add another item later.',
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

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('${item['item_name']}')),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextField(
              controller: notes,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Item note',
                hintText: 'Less spicy, no onion…',
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: type,
              decoration: const InputDecoration(labelText: 'Item discount'),
              items: const [
                DropdownMenuItem(value: 'percent', child: Text('Percentage')),
                DropdownMenuItem(
                  value: 'fixed',
                  child: Text('Fixed amount for this line'),
                ),
              ],
              onChanged: (value) => setState(() => type = value!),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: discount,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: type == 'percent'
                    ? 'Discount (%)'
                    : 'Discount amount',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () async {
                try {
                  final input = double.tryParse(discount.text);
                  if (input == null)
                    throw ApiFailure(422, 'Enter a valid discount.');
                  final value = (input * 100).round();
                  BillingCalculator.discount(
                    number(item['quantity']) * number(item['price_minor']),
                    type,
                    value,
                  );
                  widget.controller.editItem(
                    widget.index,
                    notes: notes.text,
                    discountType: type,
                    discountValue: value,
                  );
                  await widget.controller.flush();
                  if (context.mounted) Navigator.pop(context);
                } catch (e) {
                  setState(() => error = '$e');
                }
              },
              child: const Text('Save item'),
            ),
            const Divider(height: 40),
            TextField(
              controller: reason,
              decoration: const InputDecoration(
                labelText: 'Reason for cancelling this item',
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () async {
                try {
                  if (reason.text.trim().isEmpty)
                    throw ApiFailure(422, 'A cancellation reason is required.');
                  final clearTable = widget.controller.lastDiningItem
                      ? await confirmTableRelease()
                      : false;
                  if (clearTable && !widget.controller.session.manager) {
                    throw ApiFailure(
                      403,
                      'Only an owner or manager can mark this table empty.',
                    );
                  }
                  widget.controller.voidItem(widget.index, reason.text);
                  await widget.controller.flush();
                  if (clearTable)
                    await widget.controller.clearEmptyDiningTable();
                  if (context.mounted) Navigator.pop(context, clearTable);
                } catch (e) {
                  if (mounted) setState(() => error = '$e');
                }
              },
              child: const Text('Void item with reason'),
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
          ],
        ),
      ),
    ),
  );
}
