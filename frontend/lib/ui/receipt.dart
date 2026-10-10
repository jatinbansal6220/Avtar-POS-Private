import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../core/models.dart';
import '../core/session.dart';
import '../features/printing/printer_service.dart'
    if (dart.library.js_interop) '../features/printing/printer_service_web.dart';
import '../features/printing/print_job.dart';
import '../features/banks/qr_image.dart';
import '../features/banks/upi_qr.dart';
import '../features/billing/settlement_page.dart';

class ReceiptPage extends StatefulWidget {
  final Session session;
  final Json bill;
  final bool autoPrint;
  final int autoPrintCopies;
  final bool closeAfterConfirmedPrint;
  final bool previewOnly;
  final List<Json> qrOptions;
  final String? selectedQrBankId;
  const ReceiptPage(
    this.session,
    this.bill, {
    super.key,
    this.autoPrint = false,
    this.autoPrintCopies = 1,
    this.closeAfterConfirmedPrint = false,
    this.previewOnly = false,
    this.qrOptions = const <Json>[],
    this.selectedQrBankId,
  });
  @override
  State<ReceiptPage> createState() => _ReceiptPageState();
}

class _ReceiptPageState extends State<ReceiptPage> {
  String? _qrCacheKey;
  Uint8List? _qrCacheBytes;
  Uint8List? paymentQr(Json receipt) {
    final key = jsonEncode([
      receipt['qr_upi_id'],
      receipt['qr_bank_account_name'],
      upiReceiptAmount(receipt),
      receipt['bill_number'],
      receipt['qr_image_base64'],
    ]);
    if (key != _qrCacheKey) {
      _qrCacheBytes = receiptUpiQr(receipt);
      _qrCacheKey = key;
    }
    return _qrCacheBytes;
  }

  final boundary = GlobalKey();
  bool busy = false;
  String? status;
  int width = 80;
  PrintJob? printJob;
  String? selectedQrBankId;
  late Json activeBill;
  @override
  void initState() {
    super.initState();
    activeBill = widget.bill;
    selectedQrBankId = widget.selectedQrBankId;
    widget.session.local!.list('settings').then((rows) {
      if (mounted && rows.isNotEmpty) {
        setState(
          () => width = rows.first['printer_paper_width'] == '58mm' ? 58 : 80,
        );
      }
    });
    if (widget.autoPrint && !widget.previewOnly) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => printBill(copies: widget.autoPrintCopies),
      );
    }
  }

  Future<void> printBill({int copies = 1}) async {
    if (widget.previewOnly) return;
    if (busy) return;
    copies = copies.clamp(1, 2);
    printJob = PrintJob();
    setState(() {
      busy = true;
    });
    try {
      widget.session.requireFeature('printing');
      final settings = (await widget.session.local!.list('settings'))
          .firstOrNull;
      if (settings == null) throw ApiFailure(422, 'No printer settings found.');
      if (!mounted) return;
      final qrBytes = paymentQr(receiptData());
      if (qrBytes != null) {
        Object? qrError;
        await precacheImage(
          MemoryImage(qrBytes),
          context,
          onError: (error, stack) => qrError = error,
        );
        if (qrError != null) {
          throw ApiFailure(
            422,
            'Could not prepare the payment QR for printing. Retry the print.',
          );
        }
      }
      if (!mounted) return;
      await WidgetsBinding.instance.endOfFrame;
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final bitmap = await render.toImage(pixelRatio: 2);
      final png = await bitmap.toByteData(format: ui.ImageByteFormat.png);
      bitmap.dispose();
      printJob!.check();
      final bytes = png!.buffer.asUint8List();
      for (var copy = 0; copy < copies; copy++) {
        printJob!.check();
        await PrinterService().receipt(settings, bytes, job: printJob);
      }
      if (mounted) {
        setState(
          () => status = kIsWeb
              ? '${copies == 2 ? 'Two browser print dialogs requested.' : 'Browser print dialog requested.'} Use the dialog to print, save a PDF, or cancel. The bill remains saved.'
              : '${copies == 2 ? 'Two receipt copies queued to printer.' : 'Receipt queued to printer.'} Confirm the paper output before continuing.',
        );
      }
      if (mounted && widget.closeAfterConfirmedPrint && !kIsWeb) {
        final confirmed = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: Text(
              copies == 2
                  ? 'Did both receipts print?'
                  : 'Did the receipt print?',
            ),
            content: Text(
              copies == 2
                  ? 'The printer accepted two ESC/POS jobs. Check that both paper copies physically printed before confirming.'
                  : 'The printer accepted the ESC/POS job. Check that the paper has physically printed before confirming.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Not yet'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(copies == 2 ? 'Yes, both printed' : 'Yes, printed'),
              ),
            ],
          ),
        );
        if (confirmed == true && mounted) Navigator.of(context).pop(true);
      }
    } on PrintCancelled {
      if (mounted) setState(() => status = 'Printing cancelled');
    } catch (e) {
      if (mounted) {
        setState(
          () => status =
              'Print not confirmed: $e. The bill is saved; you can retry printing.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    if (busy) unawaited(printJob?.cancel());
    super.dispose();
  }

  Json receiptData() {
    final raw = activeBill['receipt'];
    final result = raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{
            'restaurant': {
              'restaurant_name': 'Avtar Cooks',
              'tagline': 'Food that feels like home',
            },
            'bill_number': activeBill['bill_number'] ?? 'Invoice',
            'table_number': activeBill['table_number'] ?? 'Takeaway',
            'generated_at':
                activeBill['generated_at'] ?? activeBill['date'] ?? '',
            'items': maps(activeBill['items']),
            'table_sections': maps(activeBill['table_sections']),
            'subtotal_minor':
                activeBill['subtotal_minor'] ?? activeBill['total_minor'] ?? 0,
            'discount_minor': activeBill['discount_minor'] ?? 0,
            'tax_minor': activeBill['tax_minor'] ?? 0,
            'additional_amount_minor':
                activeBill['additional_amount_minor'] ?? 0,
            'additional_charges': maps(activeBill['additional_charges']),
            'total_minor': activeBill['total_minor'] ?? 0,
            'tax_basis_points': activeBill['tax_basis_points'] ?? 0,
            'discount_basis_points': activeBill['discount_basis_points'] ?? 0,
            'payment_method': activeBill['payment_method'] ?? 'cash',
            'payments': maps(activeBill['payments']),
            'bank_account_name': activeBill['bank_account_name'],
            'qr_bank_account_id': activeBill['qr_bank_account_id'],
            'qr_bank_account_name': activeBill['qr_bank_account_name'],
            'qr_upi_id': activeBill['qr_upi_id'],
            'qr_image_base64': activeBill['qr_image_base64'],
            'cashier_name': activeBill['cashier_name'] ?? 'Cashier',
          };
    // A few older/server-normalized receipts do not carry generated_at inside
    // the embedded receipt object. Every billing channel still has the parent
    // bill timestamp, so retain it for a reliable printed date and time.
    result['generated_at'] ??=
        activeBill['generated_at'] ??
        activeBill['client_generated_at'] ??
        activeBill['created_at'] ??
        activeBill['date'] ??
        '';
    final chosen = widget.qrOptions
        .where((bank) => '${bank['id']}' == selectedQrBankId)
        .firstOrNull;
    if (chosen != null) {
      result['qr_bank_account_id'] = chosen['id'];
      result['qr_bank_account_name'] = chosen['account_name'];
      result['qr_upi_id'] = chosen['account_number'];
      result['qr_image_base64'] = chosen['qr_image_base64'];
    }
    return result;
  }

  Future<void> editSettlement() async {
    if (widget.previewOnly || busy || !widget.session.manager) return;
    final code = TextEditingController();
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Verify invoice code'),
        content: TextField(
          controller: code,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Invoice deletion/edit code',
            helperText: 'The same code used before deleting an invoice.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'verify'),
            child: const Text('Verify & edit'),
          ),
        ],
      ),
    );
    final enteredCode = code.text;
    code.dispose();
    if (action != 'verify') return;
    String proof;
    try {
      proof = await widget.session.verifyInvoiceAccessCode(enteredCode);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
      return;
    }
    if (!mounted) return;
    final result = await Navigator.of(context).push<dynamic>(
      MaterialPageRoute(
        builder: (_) => SettlementPage(
          widget.session,
          activeBill,
          invoiceAccessCodeHash: proof,
        ),
      ),
    );
    if (result is Map && result['bill'] is Map && mounted) {
      setState(
        () => activeBill = Map<String, dynamic>.from(result['bill'] as Map),
      );
      final copies = number(result['printCopies']);
      if (copies > 0) await printBill(copies: copies);
    }
  }

  Future<void> changeQr() async {
    var pendingSelection = selectedQrBankId;
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Choose bill QR'),
          content: SizedBox(
            width: 360,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final bank in widget.qrOptions)
                  Builder(
                    builder: (_) {
                      final account = '${bank['account_number'] ?? ''}'.trim();
                      final accountLabel = account.isEmpty
                          ? 'QR ID: ${bank['id']}'
                          : account.length > 4
                          ? 'A/c: ••••${account.substring(account.length - 4)}'
                          : 'A/c: $account';
                      final isSelected = '${bank['id']}' == pendingSelection;
                      return ListTile(
                        selected: isSelected,
                        leading: qrImageBytes(bank['qr_image_base64']) == null
                            ? const Icon(Icons.qr_code_2_outlined)
                            : Image.memory(
                                qrImageBytes(bank['qr_image_base64'])!,
                                width: 42,
                                height: 42,
                              ),
                        title: Text('${bank['account_name']}'),
                        subtitle: Text(
                          '${bank['bank_name'] ?? 'Payment account'} · $accountLabel',
                        ),
                        trailing: Icon(
                          isSelected
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          color: isSelected ? Colors.green : null,
                        ),
                        onTap: () => setDialogState(
                          () => pendingSelection = '${bank['id']}',
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: pendingSelection == null
                  ? null
                  : () => Navigator.pop(dialogContext, pendingSelection),
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
    if (selected != null && mounted) {
      setState(() => selectedQrBankId = selected);
    }
  }

  String dateTimeLabel(dynamic raw) {
    final value = indiaDateTime(raw);
    if (value == null) return raw?.toString() ?? '';
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    return '${value.day} ${months[value.month - 1]} ${value.year}, $hour:${value.minute.toString().padLeft(2, '0')} ${value.hour >= 12 ? 'PM' : 'AM'}';
  }

  /// The ID retains its date for audit and offline-sync safety. On the printed
  /// receipt the cashier sees the clear daily counter: 001, 002, and so on.
  String dailyBillNumber(Json receipt) {
    final billNumber = '${receipt['bill_number'] ?? ''}'.trim();
    final sequence = billNumber.split('-').last.trim();
    return RegExp(r'^\d+$').hasMatch(sequence) ? sequence : billNumber;
  }

  @override
  Widget build(BuildContext context) {
    final receipt = receiptData();
    final restaurant = receipt['restaurant'] as Map;
    final itemsByTable = <String, List<Json>>{};
    final savedSections = maps(receipt['table_sections']);
    if (savedSections.isNotEmpty) {
      // The billing transaction stores receipt sections explicitly. Do not
      // infer ownership from an item name: two tables may both order the same
      // dish and still require separate lines/subtotals.
      for (final section in savedSections) {
        final table = '${section['table_number'] ?? 'Order'}';
        itemsByTable[table] = maps(section['items']);
      }
    } else {
      for (final item in maps(receipt['items'])) {
        final source =
            '${item['source_table_number'] ?? receipt['table_number'] ?? 'Order'}';
        itemsByTable.putIfAbsent(source, () => []).add(item);
      }
    }
    final mergedTables = List<String>.from(
      receipt['merged_table_numbers'] ?? const <String>[],
    );
    final tableLabel = mergedTables.isEmpty
        ? '${receipt['table_number'] ?? 'Takeaway'}'
        : mergedTables.join(' + ');
    Widget total(String label, dynamic value, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
              ),
            ),
          ),
          Text(
            money(value),
            style: TextStyle(
              fontSize: bold ? 21 : 14,
              fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(
          leading: const BackButton(),
          title: Text('Receipt · ${receipt['bill_number']}'),
          actions: [
            if (!widget.previewOnly && widget.session.manager)
              IconButton(
                tooltip: 'Edit settlement',
                onPressed: busy ? null : editSettlement,
                icon: const Icon(Icons.edit_outlined),
              ),
            if (!widget.previewOnly)
              IconButton(
                tooltip: 'Double print',
                onPressed: busy ? null : () => printBill(copies: 2),
                icon: const Icon(Icons.print_outlined),
              ),
            if (widget.previewOnly && widget.qrOptions.isNotEmpty)
              IconButton(
                tooltip: 'Change QR',
                onPressed: changeQr,
                icon: const Icon(Icons.qr_code_2_outlined),
              ),
            if (!kIsWeb && busy)
              IconButton(
                tooltip: 'Cancel print',
                onPressed: () async {
                  await printJob?.cancel();
                  if (mounted) setState(() => status = 'Printing cancelled');
                },
                icon: const Icon(Icons.cancel_outlined),
              ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: kIsWeb
                      ? width * 96 / 25.4
                      : width == 58
                      ? 290
                      : 380,
                ),
                child: RepaintBoundary(
                  key: boundary,
                  child: Container(
                    color: Colors.white,
                    padding: EdgeInsets.all(kIsWeb ? 12 : 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(
                          height: 66,
                          child: Image(
                            image: AssetImage(
                              'assets/images/avtar_cooks_receipt_logo.png',
                            ),
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.high,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'AVTAR COOKS',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.1,
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.only(top: 2),
                          child: Text(
                            'VAISHNU DHABA',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.8,
                            ),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.only(top: 4),
                          child: Text(
                            'Good Food  •  Happy Mood',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              fontStyle: FontStyle.italic,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        for (final key in [
                          'restaurant_address',
                          'restaurant_phone',
                          'gstin',
                          'fssai_lic',
                        ])
                          if (restaurant[key] != null &&
                              '${restaurant[key]}'.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 5),
                              child: Text(
                                '${key == 'gstin'
                                    ? 'GSTIN: '
                                    : key == 'fssai_lic'
                                    ? 'FSSAI: '
                                    : ''}${restaurant[key]}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                        const SizedBox(height: 14),
                        const Divider(),
                        const SizedBox(height: 8),
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          spacing: 12,
                          runSpacing: 4,
                          children: [
                            Text(
                              'BILL NO. ${dailyBillNumber(receipt)}',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              tableLabel,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Container(
                          margin: const EdgeInsets.only(top: 2),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF3F4F6),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'DATE & TIME: ${dateTimeLabel(receipt['generated_at'])} IST',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.15,
                            ),
                          ),
                        ),
                        if (receipt['order_type'] == 'online')
                          Text(
                            'Online order: ${receipt['online_platform_name'] ?? receipt['online_platform'] ?? 'Online order'}',
                            style: const TextStyle(fontSize: 11),
                          ),
                        if ('${receipt['customer_name'] ?? ''}'
                            .trim()
                            .isNotEmpty)
                          Text(
                            'Customer: ${receipt['customer_name']}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        if ('${receipt['customer_phone'] ?? ''}'
                            .trim()
                            .isNotEmpty)
                          Text(
                            'Mobile: ${receipt['customer_phone']}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        if (maps(receipt['settlement_edits']).isNotEmpty) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'SETTLEMENT EDIT HISTORY',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          for (final edit in maps(receipt['settlement_edits']))
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(
                                '${dateTimeLabel(edit['edited_at'])} - ${edit['edited_by'] ?? 'Owner'}: ${edit['remark'] ?? ''}',
                                style: const TextStyle(fontSize: 10),
                              ),
                            ),
                        ],
                        const SizedBox(height: 12),
                        const Divider(),
                        Container(
                          color: Colors.black,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          child: const Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'ITEM',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 42,
                                child: Text(
                                  'QTY',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 62,
                                child: Text(
                                  'AMOUNT',
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        for (final section in itemsByTable.entries) ...[
                          if (itemsByTable.length > 1)
                            Container(
                              margin: const EdgeInsets.only(top: 8, bottom: 2),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 5,
                              ),
                              color: const Color(0xFFF1F3F5),
                              child: Text(
                                'TABLE ${section.key}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          for (final item in section.value)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Text(
                                      item['item_name'],
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 42,
                                    child: Text(
                                      '${item['quantity']}',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 62,
                                    child: Text(
                                      money(
                                        number(item['quantity']) *
                                            number(item['price_minor']),
                                      ),
                                      textAlign: TextAlign.right,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (itemsByTable.length > 1)
                            total(
                              'Table ${section.key} subtotal',
                              section.value.fold<int>(
                                0,
                                (sum, item) =>
                                    sum +
                                    number(item['quantity']) *
                                        number(item['price_minor']),
                              ),
                              bold: true,
                            ),
                        ],
                        const Divider(),
                        const SizedBox(height: 10),
                        total('Subtotal', receipt['subtotal_minor']),
                        total('Discounts', -number(receipt['discount_minor'])),
                        if (number(receipt['tax_basis_points']) > 0)
                          total(
                            'GST (${number(receipt['tax_basis_points']) / 100}%)',
                            receipt['tax_minor'],
                          ),
                        for (final charge in maps(
                          receipt['additional_charges'],
                        ))
                          total(
                            charge['note']?.toString().trim().isNotEmpty == true
                                ? 'Additional - ${charge['note']}'
                                : 'Additional amount',
                            charge['amount_minor'],
                          ),
                        if (maps(receipt['additional_charges']).isEmpty &&
                            number(receipt['additional_amount_minor']) > 0)
                          total(
                            'Additional amount',
                            receipt['additional_amount_minor'],
                          ),
                        const SizedBox(height: 8),
                        total('TOTAL', receipt['total_minor'], bold: true),
                        for (final payment in maps(receipt['payments']))
                          total(
                            '${payment['method']}'.toUpperCase(),
                            payment['amount_minor'],
                          ),
                        if (receipt['split_amounts'] is List)
                          for (final part
                              in (receipt['split_amounts'] as List)
                                  .asMap()
                                  .entries)
                            total('Bill part ${part.key + 1}', part.value),
                        const SizedBox(height: 12),
                        const Divider(),
                        const SizedBox(height: 12),
                        Text(
                          receipt['payment_method'] == 'complimentary'
                              ? 'CHARGES NOT APPLICABLE - ${receipt['cashier_name']}'
                              : 'Paid by ${receipt['payment_method']} - ${receipt['cashier_name']}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 11),
                        ),
                        if ('${receipt['settlement_remark'] ?? ''}'
                            .trim()
                            .isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              'Settlement remark: ${receipt['settlement_remark']}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 10),
                            ),
                          ),
                        if (paymentQr(receipt) case final qrBytes?) ...[
                          const SizedBox(height: 14),
                          const Divider(),
                          const SizedBox(height: 10),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: width == 58 ? 110 : 128,
                                child: Column(
                                  children: [
                                    Container(
                                      color: Colors.white,
                                      padding: const EdgeInsets.all(6),
                                      child: Image.memory(
                                        qrBytes,
                                        width: width == 58 ? 96 : 112,
                                        height: width == 58 ? 96 : 112,
                                        filterQuality: FilterQuality.none,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    const Text(
                                      'SCAN TO PAY',
                                      style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  children: [
                                    const Text(
                                      'Thank you for dining with us',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    const Text(
                                      'TASTE - QUALITY - ALWAYS',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 8,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    const Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceAround,
                                      children: [
                                        Icon(
                                          Icons.restaurant_outlined,
                                          size: 17,
                                        ),
                                        Icon(Icons.eco_outlined, size: 17),
                                        Icon(Icons.favorite_border, size: 17),
                                        Icon(
                                          Icons
                                              .sentiment_satisfied_alt_outlined,
                                          size: 17,
                                        ),
                                      ],
                                    ),
                                    if ('${receipt['qr_upi_id'] ?? ''}'
                                        .trim()
                                        .isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 6),
                                        child: Text(
                                          '${receipt['qr_bank_account_name'] ?? ''}\nUPI ID: ${receipt['qr_upi_id']}${upiReceiptAmount(receipt) > 0 ? '\nPay ${money(upiReceiptAmount(receipt))}' : ''}',
                                          textAlign: TextAlign.center,
                                          maxLines: 4,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 8),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 14),
                        Text(
                          '${restaurant['tagline'] ?? 'Thank you for dining with us.'}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'For special booking / arrangements',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Text(
                          '7973301141  |  7814494224',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Powered by ZELOVIX',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6,
                            color: Colors.black54,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'For software enquiry contact 95307-76295',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 8, color: Colors.black),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 22),
            if (status != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(status!, textAlign: TextAlign.center),
                ),
              ),
            Center(
              child: FilledButton.icon(
                onPressed: widget.previewOnly
                    ? () => Navigator.of(context).pop(selectedQrBankId)
                    : busy
                    ? null
                    : printBill,
                icon: Icon(
                  widget.previewOnly
                      ? Icons.check_circle_outline
                      : Icons.print_outlined,
                ),
                label: Text(
                  widget.previewOnly
                      ? 'Use this QR'
                      : busy
                      ? 'Preparing…'
                      : kIsWeb
                      ? 'Print / preview receipt'
                      : 'Print receipt',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
