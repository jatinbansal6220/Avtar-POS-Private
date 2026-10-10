import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../ui/shared.dart';
import 'purchase_forms.dart';
import 'data/purchase_math.dart';

class PurchaseBillEditor extends StatefulWidget {
  final Session session;
  final Json? bill;
  const PurchaseBillEditor(this.session, {super.key, this.bill});
  @override
  State<PurchaseBillEditor> createState() => _PurchaseBillEditorState();
}

class _PurchaseBillEditorState extends State<PurchaseBillEditor> {
  List<Json> items = [], suppliers = [], banks = [];
  late Json draft;
  bool busy = true, saving = false, dirty = false;
  String? error;
  int paymentRevision = 0;
  @override
  void initState() {
    super.initState();
    draft = clone(
      widget.bill ??
          {
            'id': Session.uuid.v4(),
            'name': 'Purchase',
            'status': 'draft',
            'purchase_date': day(indiaNow()),
            'due_date': null,
            'invoice_number': '',
            'lines': <Json>[],
            'freight_minor': 0,
            'paid_minor': 0,
            'payment_mode': 'cash',
            'note': '',
          },
    );
    load();
  }

  Future<void> load() async {
    try {
      final values = await Future.wait(
        [
          'purchase_items',
          'purchase_suppliers',
          'banks',
        ].map(widget.session.local!.listAll),
      );
      if (mounted) {
        setState(() {
          items = values[0].where((i) => enabled(i['is_active'])).toList();
          suppliers = values[1]
              .where(
                (s) =>
                    enabled(s['is_active']) || s['id'] == draft['supplier_id'],
              )
              .toList();
          banks = values[2];
          if (draft['supplier_id'] == null && suppliers.length == 1) {
            draft['supplier_id'] = suppliers.single['id'];
          }
          busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          busy = false;
        });
      }
    }
  }

  Future<void> addLine({Json? line}) async {
    final value = await editPurchaseLine(context, items, line: line);
    if (value != null && mounted) {
      setState(() {
        final lines = maps(draft['lines']);
        final index = lines.indexWhere((l) => l['id'] == value['id']);
        if (index < 0) {
          lines.add(value);
        } else {
          lines[index] = value;
        }
        draft['lines'] = lines;
        dirty = true;
      });
    }
  }

  Future<void> save(String status) async {
    if (saving) return;
    try {
      final bill = purchaseTotals({
        ...draft,
        'status': status,
        'name': '${draft['invoice_number'] ?? ''}'.trim().isEmpty
            ? 'Purchase ${draft['purchase_date']}'
            : 'Invoice ${draft['invoice_number']}',
        'paid_minor': status == 'received' ? number(draft['paid_minor']) : 0,
      });
      if (status == 'received') {
        final yes = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Receive and post purchase?'),
            content: Text(
              '${maps(bill['lines']).length} items · ${money(bill['total_minor'])}\nStock will increase and this purchase becomes permanent. Corrections use a return.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Back'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Receive purchase'),
              ),
            ],
          ),
        );
        if (yes != true) return;
      }
      if (!mounted) return;
      setState(() {
        saving = true;
        error = null;
      });
      final saved = await widget.session.savePurchaseBill(bill);
      if (mounted) {
        setState(() {
          dirty = false;
          saving = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context, saved);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '$e';
        });
      }
    }
  }

  Future<bool> leave() async {
    if (saving) return false;
    if (!dirty) return true;
    return await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Leave this purchase?'),
            content: const Text(
              'Save a draft to keep your work, or discard the unsaved changes.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Keep editing'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Discard changes'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Widget field(String key, String label, {bool amount = false}) =>
      TextFormField(
        key: ValueKey(
          key == 'paid_minor'
              ? '$key-${draft['payment_mode']}-$paymentRevision'
              : key,
        ),
        initialValue: amount
            ? (number(draft[key]) / 100).toStringAsFixed(2)
            : '${draft[key] ?? ''}',
        enabled: !saving,
        decoration: InputDecoration(labelText: label),
        keyboardType: amount
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text,
        onChanged: (v) {
          dirty = true;
          if (amount) {
            try {
              draft[key] = purchaseDecimal(v);
              error = null;
            } catch (e) {
              draft[key] = -1;
              error = '$e';
            }
          } else {
            draft[key] = v.trim().isEmpty ? null : v.trim();
          }
          setState(() {});
        },
      );
  Widget dateField(String key, String label, {bool optional = false}) =>
      TextFormField(
        key: ValueKey('$key-${draft[key]}'),
        initialValue: '${draft[key] ?? ''}',
        readOnly: true,
        enabled: !saving,
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: optional && draft[key] != null
              ? IconButton(
                  tooltip: 'Clear due date',
                  onPressed: saving
                      ? null
                      : () => setState(() {
                          draft[key] = null;
                          dirty = true;
                        }),
                  icon: const Icon(Icons.clear),
                )
              : const Icon(Icons.calendar_month_outlined),
        ),
        onTap: () async {
          final chosen = await showDatePicker(
            context: context,
            initialDate: DateTime.tryParse('${draft[key]}') ?? indiaNow(),
            firstDate: DateTime(1900),
            lastDate: DateTime(9999),
          );
          if (chosen != null && mounted) {
            setState(() {
              draft[key] = day(chosen);
              dirty = true;
            });
          }
        },
      );

  void setPayment(int amount) => setState(() {
    draft['paid_minor'] = amount;
    if (amount > 0 && draft['payment_mode'] == 'credit') {
      draft['payment_mode'] = 'cash';
    }
    paymentRevision++;
    dirty = true;
  });

  @override
  Widget build(BuildContext context) {
    Json? total;
    try {
      total = purchaseTotals(draft);
    } catch (_) {}
    return PopScope(
      canPop: !dirty && !saving,
      onPopInvokedWithResult: (didPop, result) async {
        if (!didPop && await leave() && mounted) {
          setState(() => dirty = false);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.pop(context);
          });
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.bill == null ? 'New purchase' : 'Edit purchase'),
        ),
        body: busy
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  const Text(
                    '1. Choose supplier',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    key: ValueKey(draft['supplier_id']),
                    initialValue: draft['supplier_id'] as String?,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Supplier'),
                    items: suppliers
                        .map(
                          (s) => DropdownMenuItem(
                            value: '${s['id']}',
                            child: Text('${s['name']}'),
                          ),
                        )
                        .toList(),
                    onChanged: saving
                        ? null
                        : (v) => setState(() {
                            draft['supplier_id'] = v;
                            dirty = true;
                          }),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: saving
                          ? null
                          : () async {
                              final supplier = await editPurchaseSupplier(
                                context,
                                widget.session,
                              );
                              if (supplier != null) {
                                await load();
                                if (mounted) {
                                  setState(() {
                                    draft['supplier_id'] = supplier['id'];
                                    dirty = true;
                                  });
                                }
                              }
                            },
                      icon: const Icon(Icons.person_add_alt),
                      label: const Text('Create supplier'),
                    ),
                  ),
                  Wrap(
                    spacing: 14,
                    runSpacing: 14,
                    children: [
                      SizedBox(
                        width: 260,
                        child: field(
                          'invoice_number',
                          'Supplier invoice / PO reference',
                        ),
                      ),
                      SizedBox(
                        width: 210,
                        child: dateField('purchase_date', 'Purchase date'),
                      ),
                      SizedBox(
                        width: 210,
                        child: dateField(
                          'due_date',
                          'Payment due date (optional)',
                          optional: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '2. Add purchased items',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: saving ? null : () => addLine(),
                        icon: const Icon(Icons.add),
                        label: const Text('Add item'),
                      ),
                    ],
                  ),
                  if (maps(draft['lines']).isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Tap Add item, choose the material, then enter quantity and rate.',
                      ),
                    ),
                  for (final line in maps(draft['lines']))
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${line['item_name']}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Edit item',
                                  onPressed: saving
                                      ? null
                                      : () => addLine(line: line),
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                                IconButton(
                                  tooltip: 'Remove unsaved item',
                                  onPressed: saving
                                      ? null
                                      : () => setState(() {
                                          draft['lines'] = maps(draft['lines'])
                                              .where(
                                                (l) => l['id'] != line['id'],
                                              )
                                              .toList();
                                          dirty = true;
                                        }),
                                  icon: const Icon(Icons.close),
                                ),
                              ],
                            ),
                            Text(
                              '${purchaseQty(line['quantity_milli'])} ${line['unit']} × ${money(line['unit_price_minor'])}  · GST ${number(line['tax_basis_points']) / 100}%  · Discount ${money(line['discount_minor'])}',
                            ),
                            Text(
                              money(line['total_minor']),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                color: accent,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 14),
                  const Text(
                    '3. Payment',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: saving || total == null
                            ? null
                            : () => setPayment(number(total!['total_minor'])),
                        child: const Text('Pay full amount'),
                      ),
                      TextButton(
                        onPressed: saving ? null : () => setPayment(0),
                        child: const Text('Pay later / udhaar'),
                      ),
                    ],
                  ),
                  const Text(
                    'For partial payment, enter the amount paid below.',
                    style: TextStyle(color: secondaryText),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 14,
                    runSpacing: 14,
                    children: [
                      SizedBox(
                        width: 240,
                        child: field(
                          'freight_minor',
                          'Freight / other charge (no GST)',
                          amount: true,
                        ),
                      ),
                      SizedBox(
                        width: 240,
                        child: field(
                          'paid_minor',
                          'Paid now (on receipt only)',
                          amount: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    key: ValueKey('payment-mode-${draft['payment_mode']}'),
                    initialValue: '${draft['payment_mode']}',
                    decoration: const InputDecoration(
                      labelText: 'Payment method',
                    ),
                    items: const ['cash', 'upi', 'bank_transfer', 'credit']
                        .map(
                          (m) => DropdownMenuItem(
                            value: m,
                            child: Text(
                              m == 'credit'
                                  ? 'Credit / udhaar'
                                  : m.replaceAll('_', ' ').toUpperCase(),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: saving
                        ? null
                        : (v) => setState(() {
                            draft['payment_mode'] = v;
                            if (v == 'credit') draft['paid_minor'] = 0;
                            dirty = true;
                          }),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: draft['bank_account_id'] as String?,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Payment account (optional)',
                    ),
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('No account selected'),
                      ),
                      ...banks.map(
                        (b) => DropdownMenuItem(
                          value: '${b['id']}',
                          child: Text('${b['account_name']}'),
                        ),
                      ),
                    ],
                    onChanged: saving
                        ? null
                        : (v) => setState(() {
                            draft['bank_account_id'] = v;
                            dirty = true;
                          }),
                  ),
                  const SizedBox(height: 14),
                  field('note', 'Purchase notes'),
                  const SizedBox(height: 20),
                  if (total != null)
                    Card(
                      color: lightIndigo,
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Wrap(
                          spacing: 28,
                          runSpacing: 12,
                          children: [
                            Text('Subtotal ${money(total['subtotal_minor'])}'),
                            Text('Discount ${money(total['discount_minor'])}'),
                            Text('GST ${money(total['tax_minor'])}'),
                            Text('Paid now ${money(draft['paid_minor'])}'),
                            Text(
                              'Remaining ${money((number(total['total_minor']) - number(draft['paid_minor'])).clamp(0, number(total['total_minor'])))}',
                            ),
                            Text(
                              'Total ${money(total['total_minor'])}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 20,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        error!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  const Text(
                    'Receive & save: items arrived, stock is added. Save draft: finish later. Save purchase order: delivery is still pending.',
                    style: TextStyle(color: secondaryText),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Saves on this device first. Sync continues in the background.',
                    style: TextStyle(color: secondaryText),
                  ),
                  const SizedBox(height: 100),
                ],
              ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                if (widget.bill?['status'] != 'ordered')
                  OutlinedButton(
                    onPressed: saving ? null : () => save('draft'),
                    child: const Text('Save draft'),
                  ),
                OutlinedButton(
                  onPressed: saving ? null : () => save('ordered'),
                  child: const Text('Save purchase order'),
                ),
                FilledButton.icon(
                  onPressed: saving ? null : () => save('received'),
                  icon: const Icon(Icons.inventory_outlined),
                  label: Text(saving ? 'Saving...' : 'Receive & save'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
