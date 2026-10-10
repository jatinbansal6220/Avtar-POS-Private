import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';

Future<Json?> openPurchaseEntryDialog(
  BuildContext context,
  Session session,
  Json item,
) async {
  final supplier = TextEditingController();
  final quantity = TextEditingController();
  final unit = TextEditingController(text: 'pcs');
  final price = TextEditingController();
  final date = TextEditingController(text: day(indiaNow()));
  final invoice = TextEditingController();
  final notes = TextEditingController();
  final banks = await session.local!.list('banks', limit: 100);
  if (!context.mounted) {
    for (final controller in [
      supplier,
      quantity,
      unit,
      price,
      date,
      invoice,
      notes,
    ]) {
      controller.dispose();
    }
    return null;
  }
  String mode = 'cash';
  String? bankId;
  String? error;
  bool saving = false;
  final result = await showDialog<Json>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) {
        Future<void> save() async {
          final qty = double.tryParse(quantity.text.trim());
          final unitPrice = double.tryParse(price.text.trim());
          if (supplier.text.trim().isEmpty ||
              qty == null ||
              qty <= 0 ||
              unit.text.trim().isEmpty ||
              unitPrice == null ||
              unitPrice < 0 ||
              DateTime.tryParse(date.text.trim()) == null) {
            setDialogState(
              () => error =
                  'Fill supplier, quantity, unit, price and a valid date.',
            );
            return;
          }
          setDialogState(() {
            saving = true;
            error = null;
          });
          try {
            final saved = await session.mutate('purchases', {
              'purchase_item_id': item['id'],
              'item_name': item['name'],
              'category': item['category_name'],
              'supplier_name': supplier.text.trim(),
              'quantity': qty,
              'unit': unit.text.trim(),
              'unit_price_minor': (unitPrice * 100).round(),
              'total_minor': (qty * unitPrice * 100).round(),
              'purchase_date': date.text.trim(),
              'payment_mode': mode,
              'bank_account_id': bankId,
              'invoice_number': invoice.text.trim().isEmpty
                  ? null
                  : invoice.text.trim(),
              'notes': notes.text.trim().isEmpty ? null : notes.text.trim(),
            });
            if (dialogContext.mounted) Navigator.pop(dialogContext, saved);
          } catch (exception) {
            if (dialogContext.mounted) {
              setDialogState(() {
                saving = false;
                error = exception.toString();
              });
            }
          }
        }

        return AlertDialog(
          title: Text('Purchase · ' + item['name'].toString()),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 500,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item['category_name'].toString(),
                    style: const TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: supplier,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Supplier'),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: quantity,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Quantity',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: unit,
                          decoration: const InputDecoration(labelText: 'Unit'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: price,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Price per unit (₹)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: date,
                          decoration: const InputDecoration(
                            labelText: 'Purchase date',
                            hintText: 'YYYY-MM-DD',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: mode,
                    decoration: const InputDecoration(
                      labelText: 'Paid through',
                    ),
                    items: const [
                      DropdownMenuItem(value: 'cash', child: Text('Cash')),
                      DropdownMenuItem(
                        value: 'bank_transfer',
                        child: Text('Bank transfer'),
                      ),
                      DropdownMenuItem(value: 'upi', child: Text('UPI')),
                      DropdownMenuItem(value: 'credit', child: Text('Credit')),
                    ],
                    onChanged: saving
                        ? null
                        : (value) => setDialogState(() => mode = value!),
                  ),
                  if (banks.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String?>(
                      value: bankId,
                      decoration: const InputDecoration(
                        labelText: 'Bank / cash account (optional)',
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('No account selected'),
                        ),
                        ...banks.map(
                          (bank) => DropdownMenuItem(
                            value: bank['id'].toString(),
                            child: Text(bank['account_name'].toString()),
                          ),
                        ),
                      ],
                      onChanged: saving
                          ? null
                          : (value) => setDialogState(() => bankId = value),
                    ),
                  ],
                  const SizedBox(height: 10),
                  TextField(
                    controller: invoice,
                    decoration: const InputDecoration(
                      labelText: 'Supplier invoice (optional)',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: notes,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Notes (optional)',
                    ),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        error!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: saving ? null : save,
              child: Text(saving ? 'Saving...' : 'Save purchase'),
            ),
          ],
        );
      },
    ),
  );
  // showDialog completes before its closing animation. Disposing the fields
  // immediately can make the still-mounted TextField read a dead controller.
  await Future<void>.delayed(const Duration(milliseconds: 350));
  for (final controller in [
    supplier,
    quantity,
    unit,
    price,
    date,
    invoice,
    notes,
  ]) {
    controller.dispose();
  }
  return result;
}
