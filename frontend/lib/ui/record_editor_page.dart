import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import '../core/models.dart';
import '../core/session.dart';
import 'shared.dart';
import '../features/registry.dart';
import 'editor_field.dart';
import '../features/shared/field_spec.dart';
import '../features/shared/field_validation.dart';
import '../features/banks/qr_image.dart';
import '../features/banks/upi_qr.dart';
import 'records_page.dart';

class RecordEditor extends StatefulWidget {
  final Session session;
  final String resource;
  final Json? row;
  final Json initial;
  final String? title;
  final Set<String> hiddenFields;
  final Map<String, String> fieldLabels;
  final bool showBankQrUpload;
  const RecordEditor(
    this.session,
    this.resource, {
    super.key,
    this.row,
    this.initial = const {},
    this.title,
    this.hiddenFields = const {},
    this.fieldLabels = const {},
    this.showBankQrUpload = true,
  });
  @override
  State<RecordEditor> createState() => _RecordEditorState();
}

class _RecordEditorState extends State<RecordEditor> {
  final form = GlobalKey<FormState>();
  final controllers = <String, TextEditingController>{};
  late Json value;
  List<Json> components = [];
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    value = clone(
      widget.row ??
          {
            'is_active': true,
            'is_veg': true,
            'is_tax_enabled': false,
            'is_default': false,
            'use_for_card': false,
            'capacity': 4,
            'printer_port': 9100,
            'printer_paper_width': '80mm',
            'tax_basis_points': 0,
            'default_discount_basis_points': 0,
            'timezone': 'Asia/Kolkata',
            'initial_balance_minor': 0,
            ...widget.initial,
          },
    );
    components = maps(value['items']);
    for (final field in specs[widget.resource] ?? <FieldSpec>[]) {
      if (field.options != null) value[field.key] ??= field.options!.first;
      if (field.kind == 'date') value[field.key] ??= day(indiaNow());
      final v = value[field.key];
      controllers[field.key] = TextEditingController(
        text: v == null
            ? ''
            : ['money', 'percent'].contains(field.kind)
            ? (number(v) / 100).toStringAsFixed(2)
            : '$v',
      );
    }
  }

  @override
  void dispose() {
    for (final c in controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    if (busy) return;
    for (final field in specs[widget.resource] ?? <FieldSpec>[]) {
      final invalid = validateField(
        field,
        controllers[field.key]?.text,
        value[field.key],
      );
      if (invalid != null) {
        form.currentState!.validate();
        setState(() => error = '${field.label}: $invalid');
        return;
      }
    }
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final payload = <String, dynamic>{
        if (widget.row != null) 'id': widget.row!['id'],
        if (widget.row != null) 'version': widget.row!['version'],
        // Local salary accounting starts when the staff profile was created.
        // Retain that timestamp through an edit; Laravel preserves its own
        // immutable created_at value when it receives this local snapshot.
        if (widget.row?['created_at'] != null)
          'created_at': widget.row!['created_at'],
      };
      for (final field in specs[widget.resource]!) {
        final text = controllers[field.key]!.text.trim();
        payload[field.key] = switch (field.kind) {
          'bool' => enabled(value[field.key]),
          'money' || 'percent' => ((double.tryParse(text) ?? 0) * 100).round(),
          'int' => int.tryParse(text),
          'decimal' => double.tryParse(text),
          'staff' || 'banks' => value[field.key],
          _ =>
            field.options != null
                ? value[field.key]
                : (text.isEmpty ? null : text),
        };
      }
      if (widget.resource == 'staff' &&
          (number(payload['monthly_salary_minor']) < 0 ||
              number(payload['monthly_salary_minor']) > 100000000)) {
        throw ArgumentError(
          'Monthly salary must be between ₹0 and ₹10,00,000.',
        );
      }
      if (widget.resource == 'payments' &&
          (number(payload['amount_minor']) < 1 ||
              number(payload['amount_minor']) > 100000000)) {
        throw ArgumentError(
          'Payment must be greater than ₹0 and at most ₹10,00,000.',
        );
      }
      if (widget.resource == 'combos') {
        payload['items'] = components
            .map(
              (c) => {
                'menu_item_id': c['menu_item_id'],
                'quantity': number(c['quantity']),
              },
            )
            .toList();
      }
      if (widget.resource == 'purchases') {
        payload['total_minor'] =
            ((double.tryParse(controllers['quantity']!.text.trim()) ?? 0) *
                    number(payload['unit_price_minor']))
                .round();
      }
      if (widget.resource == 'banks') {
        final isUpi = ['upi', 'upi_merchant'].contains(value['account_type']);
        final upiId = '${payload['account_number'] ?? ''}'.trim();
        final unchangedLegacyQr =
            widget.row != null &&
            '${widget.row!['account_number'] ?? ''}'.trim() == upiId &&
            qrImageBytes(value['qr_image_base64']) != null;
        if (isUpi &&
            !validUpiId(upiId) &&
            !unchangedLegacyQr &&
            (upiId.isNotEmpty ||
                qrImageBytes(value['qr_image_base64']) == null)) {
          throw const FormatException(
            'Enter a valid UPI ID, for example shop@bank.',
          );
        }
        payload['qr_image_base64'] = isUpi ? value['qr_image_base64'] : null;
        // A UPI QR and a card settlement account are separate ledgers. Keep
        // only the relevant default flag, even for a record first created by
        // an older app version.
        payload['is_default'] = false;
        payload['use_for_card'] = enabled(value['use_for_card']);
        if (!isUpi) {
          payload['is_default_qr'] = false;
        }
      }
      final result = await widget.session.mutate(widget.resource, payload);
      if (mounted) Navigator.pop(context, result);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> pickBankQrImage() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
      final bytes = result?.files.single.bytes;
      if (bytes == null) return;
      final compressed = compressQrImage(bytes);
      if (mounted) setState(() => value['qr_image_base64'] = compressed);
    } catch (exception) {
      if (mounted) setState(() => error = 'Could not use QR image: $exception');
    }
  }

  Future<void> remove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this record?'),
        content: const Text(
          'It will be removed from active lists. Existing bills retain their original information.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep record'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => busy = true);
    try {
      await widget.session.mutate(widget.resource, {
        'id': widget.row!['id'],
        'version': widget.row!['version'],
      }, delete: true);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.title ??
            '${widget.row == null ? 'Add' : 'Edit'} ${titles[widget.resource] ?? widget.resource}',
      ),
      actions: [
        if (widget.row != null &&
            [
              'tables',
              'menu_items',
              'combos',
              'staff',
              'banks',
              'purchases',
            ].contains(widget.resource))
          IconButton(
            tooltip: 'Delete',
            onPressed: busy ? null : remove,
            icon: const Icon(Icons.delete_outline),
          ),
      ],
    ),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780),
        child: Form(
          key: form,
          child: ListView(
            padding: EdgeInsets.all(widget.resource == 'purchases' ? 14 : 24),
            children: [
              if (widget.resource == 'staff')
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text(
                    'Qualification, degree and experience are saved on this device. Staff details, attendance and payments sync across devices.',
                  ),
                ),
              for (final f in specs[widget.resource] ?? <FieldSpec>[])
                if (!widget.hiddenFields.contains(f.key))
                  if (!(widget.resource == 'banks' &&
                      (![
                            'upi',
                            'upi_merchant',
                          ].contains(value['account_type']) &&
                          f.key == 'is_default_qr')))
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: widget.resource == 'purchases' ? 10 : 20,
                      ),
                      child: EditorField(
                        f: FieldSpec(
                          f.key,
                          widget.fieldLabels[f.key] ?? f.label,
                          kind: f.kind,
                          options: f.options,
                          required: f.required,
                        ),
                        session: widget.session,
                        value: value,
                        controllers: controllers,
                        busy: busy,
                        onChange: setState,
                      ),
                    ),
              if (widget.showBankQrUpload &&
                  widget.resource == 'banks' &&
                  ['upi', 'upi_merchant'].contains(value['account_type'])) ...[
                const SizedBox(height: 4),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Bill payment QR',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 5),
                        const Text(
                          'Enter the UPI ID above. Its QR is generated automatically on save; each bill QR includes the payment amount. Image upload is optional for older accounts.',
                          style: TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 12),
                        if (qrImageBytes(value['qr_image_base64'])
                            case final bytes?)
                          Center(
                            child: Container(
                              color: Colors.white,
                              padding: const EdgeInsets.all(8),
                              child: Image.memory(
                                bytes,
                                width: 148,
                                height: 148,
                              ),
                            ),
                          )
                        else
                          const Text(
                            'QR will be generated from the UPI ID when you save.',
                          ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: busy ? null : pickBankQrImage,
                              icon: const Icon(Icons.upload_file_outlined),
                              label: Text(
                                value['qr_image_base64'] == null
                                    ? 'Upload QR image'
                                    : 'Replace QR image',
                              ),
                            ),
                            if (value['qr_image_base64'] != null)
                              TextButton.icon(
                                onPressed: busy
                                    ? null
                                    : () => setState(
                                        () => value['qr_image_base64'] = null,
                                      ),
                                icon: const Icon(Icons.delete_outline),
                                label: const Text('Remove image'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (widget.resource == 'combos') ...[
                Text(
                  'Combo contents',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                for (final component in components)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      component['name'] ??
                          'Menu item ${component['menu_item_id']}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: () => setState(() {
                            if (number(component['quantity']) > 1) {
                              component['quantity'] =
                                  number(component['quantity']) - 1;
                            } else {
                              components.remove(component);
                            }
                          }),
                          icon: const Icon(Icons.remove),
                        ),
                        Text('${component['quantity']}'),
                        IconButton(
                          onPressed: () => setState(
                            () => component['quantity'] =
                                number(component['quantity']) + 1,
                          ),
                          icon: const Icon(Icons.add),
                        ),
                      ],
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final item = await openPage<Json>(
                      context,
                      RecordsPage(widget.session, 'menu_items', picker: true),
                    );
                    if (item != null) {
                      setState(() {
                        final existing = components.where(
                          (c) => c['menu_item_id'] == item['id'],
                        );
                        if (existing.isNotEmpty) {
                          existing.first['quantity'] =
                              number(existing.first['quantity']) + 1;
                        } else {
                          components.add({
                            'menu_item_id': item['id'],
                            'name': item['name'],
                            'quantity': 1,
                          });
                        }
                      });
                    }
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Add component'),
                ),
                const SizedBox(height: 24),
              ],
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: Text(
                    error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              FilledButton(
                onPressed: busy ? null : save,
                child: Text(busy ? 'Saving…' : 'Save changes'),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    ),
  );
}
