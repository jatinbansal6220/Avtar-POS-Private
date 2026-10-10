import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../ui/shared.dart';
import 'data/purchase_math.dart';

Future<Json?> editPurchaseSupplier(
  BuildContext context,
  Session session, {
  Json? supplier,
}) async {
  final value = <String, dynamic>{'is_active': true, ...?supplier};
  String? error;
  bool saving = false;
  return showDialog<Json>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (dialog, refresh) => AlertDialog(
        title: Text(supplier == null ? 'Add supplier' : 'Edit supplier'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final field in [
                  ('name', 'Supplier name'),
                  ('phone', 'Phone'),
                  ('gstin', 'GSTIN (optional)'),
                  ('address', 'Address'),
                  ('note', 'Notes'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextFormField(
                      initialValue: '${value[field.$1] ?? ''}',
                      onChanged: (text) => value[field.$1] = text.trim(),
                      decoration: InputDecoration(labelText: field.$2),
                      maxLines: field.$1 == 'address' ? 2 : 1,
                    ),
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Available for new purchases'),
                  value: enabled(value['is_active']),
                  onChanged: saving
                      ? null
                      : (v) => refresh(() => value['is_active'] = v),
                ),
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.red)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: saving
                ? null
                : () async {
                    refresh(() => saving = true);
                    try {
                      if ('${value['name'] ?? ''}'.isEmpty) {
                        throw ApiFailure(422, 'Enter supplier name.');
                      }
                      final gst = '${value['gstin'] ?? ''}'.toUpperCase();
                      if (gst.isNotEmpty &&
                          !RegExp(r'^\d{2}[A-Z]{5}\d{4}[A-Z][A-Z0-9]Z[A-Z0-9]$')
                              .hasMatch(gst)) {
                        throw ApiFailure(
                          422,
                          'Enter a valid 15-character GSTIN.',
                        );
                      }
                      value['gstin'] = gst;
                      final existing = await session.local!.listAll(
                        'purchase_suppliers',
                      );
                      if (existing.any(
                        (s) =>
                            s['id'] != value['id'] &&
                            '${s['name']}'.toLowerCase() ==
                                '${value['name']}'.toLowerCase(),
                      )) {
                        throw ApiFailure(422, 'Supplier already exists.');
                      }
                      final saved = await session.mutate(
                        'purchase_suppliers',
                        value,
                      );
                      if (dialog.mounted) Navigator.pop(dialog, saved);
                    } catch (e) {
                      if (dialog.mounted) {
                        refresh(() {
                          error = '$e';
                          saving = false;
                        });
                      }
                    }
                  },
            child: Text(saving ? 'Saving...' : 'Save supplier'),
          ),
        ],
      ),
    ),
  );
}

Future<Json?> editPurchaseLine(
  BuildContext context,
  List<Json> items, {
  Json? line,
}) async {
  if (items.isEmpty) {
    message(context, 'Create purchase items from Items & categories first.');
    return null;
  }
  Json selected =
      items.where((i) => i['id'] == line?['purchase_item_id']).firstOrNull ??
      items.first;
  var qty = line == null ? '1' : purchaseQty(line['quantity_milli']);
  var price = (number(line?['unit_price_minor']) / 100).toStringAsFixed(2);
  var unit = '${line?['unit'] ?? 'kg'}';
  var discount = (number(line?['discount_minor']) / 100).toStringAsFixed(2);
  var tax = number(line?['tax_basis_points']);
  String? error;
  return showDialog<Json>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (dialog, refresh) => AlertDialog(
        title: Text(line == null ? 'Add purchase item' : 'Edit purchase item'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: '${selected['id']}',
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Item'),
                  items: items
                      .map(
                        (i) => DropdownMenuItem(
                          value: '${i['id']}',
                          child: Text(
                            '${i['name']}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (id) =>
                      selected = items.firstWhere((i) => i['id'] == id),
                ),
                const SizedBox(height: 12),
                for (final field in [
                  ('Quantity', qty),
                  ('Unit (kg, L, pcs)', unit),
                  ('Price per unit (₹)', price),
                  ('Item discount (₹)', discount),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextFormField(
                      initialValue: field.$2,
                      keyboardType: field.$1.startsWith('Unit')
                          ? TextInputType.text
                          : const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                      decoration: InputDecoration(labelText: field.$1),
                      onChanged: (v) {
                        switch (field.$1) {
                          case 'Quantity':
                            qty = v;
                          case 'Unit (kg, L, pcs)':
                            unit = v;
                          case 'Price per unit (₹)':
                            price = v;
                          default:
                            discount = v;
                        }
                      },
                    ),
                  ),
                DropdownButtonFormField<int>(
                  initialValue: tax,
                  decoration: const InputDecoration(labelText: 'Purchase GST'),
                  items: const [0, 500, 1200, 1800, 2800]
                      .map(
                        (r) => DropdownMenuItem(
                          value: r,
                          child: Text('${r / 100}%'),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => tax = v ?? 0,
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
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              try {
                final value = <String, dynamic>{
                  'id': line?['id'] ?? Session.uuid.v4(),
                  'purchase_item_id': selected['id'],
                  'item_name': selected['name'],
                  'unit': unit.trim(),
                  'quantity_milli': purchaseDecimal(qty, scale: 1000),
                  'unit_price_minor': purchaseDecimal(price),
                  'discount_minor': purchaseDecimal(discount),
                  'tax_basis_points': tax,
                };
                final computed = purchaseTotals({
                  'lines': [value],
                  'freight_minor': 0,
                });
                Navigator.pop(dialog, maps(computed['lines']).single);
              } catch (e) {
                refresh(() => error = '$e');
              }
            },
            child: const Text('Add to purchase'),
          ),
        ],
      ),
    ),
  );
}
