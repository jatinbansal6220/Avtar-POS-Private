import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../features/printing/print_job.dart';
import '../../features/printing/printer_service.dart'
    if (dart.library.js_interop) '../../features/printing/printer_service_web.dart';
import 'online_platform_picker.dart';
import 'data/kot_tracker.dart';

/// Kitchen-only ticket. Price, tax, discount and payment details are excluded.
class KotPage extends StatefulWidget {
  final Session session;
  final Json order;
  const KotPage(this.session, this.order, {super.key});
  @override
  State<KotPage> createState() => _KotPageState();
}

class _KotPageState extends State<KotPage> {
  final boundary = GlobalKey();
  bool printing = false;
  bool loading = true;
  String? status;
  int width = 80;
  PrintJob? job;
  List<Json>? printingItems;
  List<Json> lastTicketItems = [];
  bool printingReprint = false;
  bool printingAdditional = false;
  String? storedSent;
  String? storedTicket;

  Map<String, int> sentQuantities = <String, int>{};

  String get _sentKey => 'kot_sent_quantities_v2_${widget.order['id']}';
  String get _legacySentKey => 'kot_sent_quantities_v1_${widget.order['id']}';
  String get _ticketKey => 'kot_last_ticket_v1_${widget.order['id']}';
  List<Json> get _newItems =>
      KotTracker.prepare(widget.order, sentQuantities).items;

  Future<void> _saveAcknowledgement(KotTicket ticket) async {
    final sent = jsonEncode(ticket.sent);
    final last = jsonEncode(ticket.items);
    await widget.session.local!.saveKotAcknowledgement(
      ticket.acknowledgedOrder,
      metadata: {_sentKey: sent, _ticketKey: last},
    );
    widget.order
      ..clear()
      ..addAll(ticket.acknowledgedOrder);
    storedSent = sent;
    storedTicket = last;
    sentQuantities = ticket.sent;
    lastTicketItems = ticket.items;
  }

  @override
  void initState() {
    super.initState();
    _loadKotState();
  }

  Future<void> _loadKotState() async {
    final local = widget.session.local!;
    final values = await Future.wait([
      local.list('settings', limit: 1),
      local.meta(_sentKey),
      local.meta(_legacySentKey),
      local.meta(_ticketKey),
    ]);
    final rows = values[0] as List<Json>;
    storedSent = values[1] as String?;
    storedTicket = values[3] as String?;
    final sent = <String, int>{};
    void readSent(dynamic encoded) {
      if (encoded is! Map) return;
      for (final entry in encoded.entries) {
        sent['${entry.key}'] = number(entry.value);
      }
    }

    // New builds retain this with the actual local order. It survives an
    // order reopen/save while still staying completely outside the API data.
    if (storedSent == null) readSent(widget.order['_kot_sent_quantities']);
    final stored = storedSent ?? values[2] as String?;
    if (stored != null) {
      try {
        final raw = Map<String, dynamic>.from(jsonDecode(stored) as Map);
        for (final entry in raw.entries) {
          final prior = sent[entry.key] ?? 0;
          sent[entry.key] = number(entry.value) > prior
              ? number(entry.value)
              : prior;
        }
      } catch (_) {
        // A damaged acknowledgement is safely replaced after a fresh KOT.
      }
    }
    if (storedTicket != null) {
      try {
        lastTicketItems = maps(jsonDecode(storedTicket!));
      } catch (_) {
        /* Keep normal delta printing available. */
      }
    }
    if (!mounted) return;
    setState(() {
      width = rows.isNotEmpty && rows.first['printer_paper_width'] == '58mm'
          ? 58
          : 80;
      sentQuantities = KotTracker.readSent(sent);
      loading = false;
    });
  }

  String get source => switch (widget.order['order_type']) {
    'dine_in' => 'TABLE ${widget.order['table_number']}',
    'online' => onlinePlatformLabel(widget.order),
    'pos' => 'MENU POS',
    _ => 'TAKEAWAY',
  };

  Future<void> printKot({bool reprint = false}) async {
    if (printing || loading) return;
    final ticket = KotTracker.prepare(widget.order, sentQuantities);
    final ticketItems = reprint ? lastTicketItems : ticket.items;
    if (ticketItems.isEmpty) return;
    final originalOrder = clone(widget.order);
    final originalSent = Map<String, int>.from(sentQuantities);
    final originalTicket = lastTicketItems;
    final originalStoredSent = storedSent;
    final originalStoredTicket = storedTicket;
    setState(() {
      printing = true;
      status = null;
      // Render the immutable delta snapshot even after its acknowledgement is
      // saved below. Otherwise a rebuild could render the full cart instead.
      printingItems = ticketItems;
      printingReprint = reprint;
      printingAdditional = sentQuantities.values.any((value) => value > 0);
    });
    job = PrintJob();
    var acknowledged = false;
    try {
      widget.session.requireFeature('kot');
      widget.session.requireFeature('printing');
      // The Windows spooler can accept and physically print RAW bytes before
      // its helper process reports back. Persist first, so an accepted ticket
      // is never repeated merely because that final confirmation is delayed.
      if (!reprint) {
        await _saveAcknowledgement(ticket);
        acknowledged = true;
      }
      final settings =
          (await widget.session.local!.list(
            'settings',
            limit: 1,
          )).firstOrNull ??
          <String, dynamic>{'printer_paper_width': '80mm'};
      await WidgetsBinding.instance.endOfFrame;
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 2);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      job!.check();
      await PrinterService().receipt(
        settings,
        png!.buffer.asUint8List(),
        job: job,
      );
      if (mounted) {
        setState(() {
          status = kIsWeb
              ? 'Browser print dialog requested. The KOT stays open for review.'
              : reprint
              ? 'Last KOT reprinted. New items remain pending.'
              : 'KOT sent. Only newly added items will print next time.';
        });
      }
    } on PrintCancelled {
      if (acknowledged) {
        await widget.session.local!.saveKotAcknowledgement(
          originalOrder,
          metadata: {
            _sentKey: originalStoredSent,
            _ticketKey: originalStoredTicket,
          },
        );
        widget.order
          ..clear()
          ..addAll(originalOrder);
        sentQuantities = originalSent;
        lastTicketItems = originalTicket;
        storedSent = originalStoredSent;
        storedTicket = originalStoredTicket;
      }
      if (mounted) setState(() => status = 'KOT printing cancelled.');
    } catch (error) {
      if (mounted) {
        setState(
          () => status = reprint
              ? 'Reprint failed: $error. New items remain pending.'
              : acknowledged
              ? 'KOT was saved for the kitchen. Printer confirmation failed: $error. Check the printer queue before sending it again.'
              : 'KOT was not prepared: $error',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          printing = false;
          printingItems = null;
        });
      }
    }
  }

  @override
  void dispose() {
    if (printing) unawaited(job?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = printingItems ?? _newItems;
    final restaurant =
        '${widget.session.user?['restaurant_name'] ?? 'Avtar POS'}';
    final ticketNo = '${widget.order['id']}'
        .replaceAll('-', '')
        .substring(0, 6)
        .toUpperCase();
    return PopScope(
      canPop: !printing,
      child: Scaffold(
        appBar: AppBar(
          leading: const BackButton(),
          title: const Text('Kitchen order ticket'),
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
                        Text(
                          restaurant,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          printingItems != null && printingReprint
                              ? 'REPRINT KOT'
                              : (printingItems != null
                                    ? printingAdditional
                                    : sentQuantities.values.any(
                                        (value) => value > 0,
                                      ))
                              ? 'ADDITIONAL KOT'
                              : 'KITCHEN ORDER TICKET',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Divider(),
                        Text(
                          source,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          'KOT #$ticketNo',
                          style: const TextStyle(fontSize: 12),
                        ),
                        Text(
                          indiaTimestamp(),
                          style: const TextStyle(fontSize: 12),
                        ),
                        if ('${widget.order['customer_name'] ?? ''}'
                            .trim()
                            .isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              'Customer: ${widget.order['customer_name']}',
                            ),
                          ),
                        const Divider(height: 28),
                        const Text(
                          'ITEM                                      QTY',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (loading)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 20),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (items.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 20),
                            child: Text(
                              'No new items for KOT. Add an item or increase quantity first.',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          )
                        else
                          for (final item in items)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 7),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${item['item_name']}',
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        if ('${item['notes'] ?? ''}'
                                            .trim()
                                            .isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 3,
                                            ),
                                            child: Text(
                                              'Note: ${item['notes']}',
                                              style: const TextStyle(
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Text(
                                    '${number(item['quantity'])}',
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        if ('${widget.order['notes'] ?? ''}'
                            .trim()
                            .isNotEmpty) ...[
                          const Divider(height: 28),
                          const Text(
                            'ORDER NOTE',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text('${widget.order['notes']}'),
                        ],
                        const Divider(height: 28),
                        const Text(
                          'No payment details on this kitchen ticket.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 22),
            if (status != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(status!, textAlign: TextAlign.center),
              ),
            Center(
              child: FilledButton.icon(
                onPressed: printing || loading || items.isEmpty
                    ? null
                    : printKot,
                icon: const Icon(Icons.print_outlined),
                label: Text(
                  printing
                      ? 'Preparing KOT…'
                      : kIsWeb
                      ? 'Print / preview new KOT'
                      : 'Print new KOT',
                ),
              ),
            ),
            if (lastTicketItems.isNotEmpty) ...[
              const SizedBox(height: 10),
              Center(
                child: OutlinedButton.icon(
                  onPressed: printing || loading
                      ? null
                      : () => printKot(reprint: true),
                  icon: const Icon(Icons.print_outlined),
                  label: const Text('Reprint last KOT'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
