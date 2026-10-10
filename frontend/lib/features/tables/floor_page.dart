import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../ui/shared.dart';
import '../../ui/records_page.dart';
import '../orders/data/order_draft.dart';
import '../orders/data/kot_tracker.dart';
import '../orders/order_workspace_page.dart';
import '../orders/online_platform_picker.dart';
import 'table_booking_dialog.dart';

class FloorPage extends StatefulWidget {
  final Session session;
  const FloorPage(this.session, {super.key});
  @override
  State<FloorPage> createState() => _FloorPageState();
}

class _FloorPageState extends State<FloorPage> {
  final search = TextEditingController(), scroll = ScrollController();
  Timer? debounce;
  Timer? bookingClock;
  Timer? refreshTimer;
  bool loading = false, reloadQueued = false;
  bool routeVisible = true, refreshDeferred = false;
  final cardCache = <String, (String, Widget)>{};
  List<Json> tables = [];
  Map<String, List<Json>>? bookings;
  Map<String, List<String>> mergedTables = {};
  Map<String, Json> tableOrders = {};
  Map<String, int> tablePendingKot = {};
  String? loadError;
  String? status;
  bool busy = false, more = true;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    widget.session.watch('tables').addListener(refresh);
    widget.session.watch('orders').addListener(refresh);
    widget.session.watch('table_bookings').addListener(refresh);
    bookingClock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && routeVisible) setState(() {});
    });
    load(reset: true);
    scroll.addListener(() {
      if (scroll.position.extentAfter < 300 && !busy && more) load();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeVisible = ModalRoute.of(context)?.isCurrent ?? true;
    if (routeVisible && refreshDeferred) {
      refreshDeferred = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) load(reset: true);
      });
    }
  }

  void refresh() {
    refreshTimer?.cancel();
    if (!routeVisible) {
      refreshDeferred = true;
      return;
    }
    refreshTimer = Timer(const Duration(milliseconds: 80), () {
      if (mounted) load(reset: true);
    });
  }

  @override
  void dispose() {
    widget.session.watch('tables').removeListener(refresh);
    widget.session.watch('orders').removeListener(refresh);
    widget.session.watch('table_bookings').removeListener(refresh);
    debounce?.cancel();
    bookingClock?.cancel();
    refreshTimer?.cancel();
    search.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> load({bool reset = false}) async {
    refreshTimer?.cancel();
    if (!routeVisible) {
      refreshDeferred = true;
      return;
    }
    if (loading) {
      if (reset) {
        ++generation;
        reloadQueued = true;
      }
      return;
    }
    loading = true;
    final gen = reset ? ++generation : generation;
    setState(() {
      busy = true;
      loadError = null;
    });
    try {
      final drafts = await widget.session.local!.drafts();
      final rawTables = await widget.session.local!.listAll('tables');
      final storedOrders = await widget.session.local!.getMany('orders', [
        for (final draft in drafts) '${draft['id']}',
        for (final table in rawTables) '${table['current_order_id'] ?? ''}',
      ]);
      final draftTables = <String, Json>{};
      for (final draft in drafts) {
        if (draft['order_type'] != 'dine_in' ||
            draft['status'] != 'open' ||
            maps(draft['items']).isEmpty ||
            '${draft['merged_into_order_id'] ?? ''}'.isNotEmpty) {
          continue;
        }
        final stored = storedOrders['${draft['id']}'];
        if (stored != null && stored['status'] != 'open') continue;
        draftTables['${draft['table_id']}'] = draft;
      }
      // A locally saved cart occupies its card before Save Order/KOT. This
      // display projection does not upload an unfinished order or alter tables.
      final available = rawTables
          .map((table) {
            final draft = draftTables['${table['id']}'];
            if (table['status'] == 'empty' && draft != null) {
              return <String, dynamic>{
                ...table,
                'status': 'occupied',
                'current_order_id': draft['id'],
              };
            }
            return table;
          })
          .where(
            (table) =>
                '${table['table_number']}'.toLowerCase().contains(
                  search.text.trim().toLowerCase(),
                ) &&
                (status == null || table['status'] == status),
          )
          .toList();
      final offset = reset ? 0 : tables.length;
      final result = available.skip(offset).take(60).toList();
      final nextTables = reset ? result : [...tables, ...result];
      final activeBookings = await widget.session.local!.bookingsForTables(
        nextTables.map((table) => table['id'].toString()).toList(),
      );
      final nextBookings = <String, List<Json>>{};
      for (final booking in activeBookings) {
        final id = booking['table_id'].toString();
        nextBookings.putIfAbsent(id, () => []).add(booking);
      }
      // Every merged card resolves the primary shared cart, including its
      // latest local draft. Items are stored once, never copied per table.
      final activeOrders = <String, Json>{...storedOrders};
      final nextMergedTables = <String, List<String>>{};
      final draftById = {for (final draft in drafts) '${draft['id']}': draft};
      activeOrders.addAll(draftById);
      final primaryIds = activeOrders.values
          .map((order) => '${order['merged_into_order_id'] ?? ''}')
          .where((id) => id.isNotEmpty && !activeOrders.containsKey(id))
          .toSet();
      activeOrders.addAll(
        await widget.session.local!.getMany('orders', primaryIds),
      );
      final metadata = await widget.session.local!.metaMany([
        for (final id in activeOrders.keys) ...[
          'kot_sent_quantities_v2_$id',
          'kot_sent_quantities_v1_$id',
        ],
      ]);
      final nextTableOrders = <String, Json>{};
      final nextPendingKot = <String, int>{};
      final pendingByOrder = <String, int>{};
      for (final table in nextTables) {
        var order =
            activeOrders['${table['current_order_id'] ?? ''}'] ??
            drafts
                .where(
                  (draft) =>
                      draft['table_id'] == table['id'] &&
                      draft['order_type'] == 'dine_in' &&
                      draft['status'] == 'open',
                )
                .firstOrNull;
        if (order == null) continue;
        final primaryId = '${order['merged_into_order_id'] ?? ''}';
        if (primaryId.isNotEmpty) {
          order = activeOrders[primaryId] ?? order;
        }
        nextTableOrders['${table['id']}'] = order;
        final orderId = '${order['id']}';
        if (!pendingByOrder.containsKey(orderId)) {
          final v2 = metadata['kot_sent_quantities_v2_$orderId'];
          final raw = v2 ?? metadata['kot_sent_quantities_v1_$orderId'];
          final sent = v2 == null
              ? KotTracker.readSent(order['_kot_sent_quantities'])
              : <String, int>{};
          if (raw != null) {
            try {
              final stored = KotTracker.readSent(jsonDecode(raw));
              for (final entry in stored.entries) {
                if (entry.value > (sent[entry.key] ?? 0)) {
                  sent[entry.key] = entry.value;
                }
              }
            } catch (_) {
              /* Line markers still work if older metadata is damaged. */
            }
          }
          pendingByOrder[orderId] = KotTracker.prepare(
            order,
            sent,
          ).items.fold<int>(0, (sum, row) => sum + number(row['quantity']));
        }
        nextPendingKot['${table['id']}'] = pendingByOrder[orderId]!;
        final joined = List<String>.from(
          order['merged_table_numbers'] ?? const <String>[],
        );
        if (joined.length > 1) {
          nextMergedTables['${table['id']}'] = joined;
        }
      }
      if (!mounted || gen != generation) return;
      setState(() {
        tables = nextTables;
        bookings = nextBookings;
        mergedTables = nextMergedTables;
        tableOrders = nextTableOrders;
        tablePendingKot = nextPendingKot;
        more = offset + result.length < available.length;
        final visibleIds = nextTables.map((table) => '${table['id']}').toSet();
        cardCache.removeWhere((id, _) => !visibleIds.contains(id));
        busy = false;
      });
    } catch (error) {
      if (mounted && gen == generation) {
        setState(() {
          loadError = '$error';
          busy = false;
        });
      }
    } finally {
      loading = false;
      if (mounted && reloadQueued) {
        reloadQueued = false;
        load(reset: true);
      }
    }
  }

  String tableStatus(dynamic value) => switch (value) {
    'empty' => 'Available',
    'occupied' => 'Order running',
    'bill_pending' => 'Payment pending',
    _ => '${value ?? 'Available'}',
  };

  String elapsed(Json order) {
    final started = indiaDateTime(order['created_at']);
    if (started == null) return '';
    final minutes = indiaNow().difference(started).inMinutes.clamp(0, 1000000);
    return minutes < 60 ? '${minutes}m' : '${minutes ~/ 60}h ${minutes % 60}m';
  }

  Future<void> select(Json table) async {
    final drafts = await widget.session.local!.drafts();
    // Online/takeaway drafts never belong to a dining table. Ignore any old
    // malformed demo draft that may have been created with a table id.
    // A joined party has one shared cart. Either table card must therefore
    // open the primary order, so adding an item from Table 2 is instantly
    // visible when Table 7 is opened and it is billed only once.
    final currentId = '${table['current_order_id'] ?? ''}'.trim();
    // The table's current order is authoritative after a merge. An older
    // draft belonging to this table must not reopen its former separate cart.
    Json? order = currentId.isEmpty
        ? null
        : drafts.where((d) => '${d['id']}' == currentId).firstOrNull ??
              await widget.session.local!.get('orders', currentId);
    if (order == null && currentId.isEmpty) {
      order = drafts
          .where(
            (d) =>
                d['table_id'] == table['id'] &&
                d['order_type'] == 'dine_in' &&
                d['status'] == 'open',
          )
          .firstOrNull;
    }
    final primaryId = '${order?['merged_into_order_id'] ?? ''}'.trim();
    if (primaryId.isNotEmpty) {
      order =
          drafts.where((draft) => '${draft['id']}' == primaryId).firstOrNull ??
          await widget.session.local!.readDraft(primaryId) ??
          await widget.session.local!.get('orders', primaryId) ??
          order;
    }
    if (order == null && table['current_order_id'] != null) {
      try {
        order = await widget.session.request(
          'GET',
          'orders/${table['current_order_id']}',
        );
      } catch (e) {
        if (mounted) message(context, e);
        return;
      }
    }
    order ??= newOrder(table: table);
    if (mounted) {
      await openPage(context, OrderWorkspacePage(widget.session, order));
    }
  }

  Future<void> startOnlineOrder() async {
    try {
      final platform = await pickOnlinePlatform(context, widget.session);
      if (platform == null || !mounted) return;
      final remember = platform.remove('_remember_platform')?.toString();
      if (remember != null) {
        await rememberOnlinePlatform(widget.session, remember);
      }
      if (!mounted) return;
      final order = newOrder(channel: 'online')..addAll(platform);
      await openPage(context, OrderWorkspacePage(widget.session, order));
    } catch (error) {
      if (mounted) message(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Floor overview'),
      actions: [
        if (widget.session.manager)
          IconButton(
            tooltip: 'Manage tables',
            onPressed: () =>
                openPage(context, RecordsPage(widget.session, 'tables')),
            icon: const Icon(Icons.tune),
          ),
      ],
    ),
    body: LayoutBuilder(
      builder: (context, box) => Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        onPressed: () => openPage(
                          context,
                          OrderWorkspacePage(widget.session, newOrder()),
                        ),
                        icon: const Icon(Icons.shopping_bag_outlined, size: 18),
                        label: const Text('Takeaway'),
                      ),
                      OutlinedButton.icon(
                        onPressed: startOnlineOrder,
                        icon: const Icon(Icons.delivery_dining, size: 18),
                        label: const Text('Online order'),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: TextField(
                    controller: search,
                    decoration: const InputDecoration(
                      hintText: 'Search tables',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (_) {
                      debounce?.cancel();
                      debounce = Timer(
                        const Duration(milliseconds: 180),
                        () => load(reset: true),
                      );
                    },
                  ),
                ),
                SizedBox(
                  height: 68,
                  child: ListView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final filter in <String?>[
                        null,
                        'empty',
                        'occupied',
                        'bill_pending',
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: ChoiceChip(
                            label: Text(
                              filter == null
                                  ? 'All tables'
                                  : tableStatus(filter),
                            ),
                            selected: status == filter,
                            onSelected: (_) {
                              setState(() => status = filter);
                              load(reset: true);
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                if (loadError != null)
                  MaterialBanner(
                    content: Text(loadError!),
                    actions: [
                      TextButton(
                        onPressed: () => load(reset: true),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                if (busy) const LinearProgressIndicator(),
                Expanded(
                  child: tables.isEmpty && !busy
                      ? EmptyState(
                          'Your floor starts here',
                          'Add your tables in settings. Each table will show whether it is available, occupied or awaiting a bill.',
                          icon: Icons.table_restaurant,
                          action: widget.session.manager
                              ? FilledButton(
                                  onPressed: () => openPage(
                                    context,
                                    RecordsPage(widget.session, 'tables'),
                                  ),
                                  child: const Text('Set up tables'),
                                )
                              : null,
                        )
                      : LayoutBuilder(
                          builder: (context, box) => GridView.builder(
                            controller: scroll,
                            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                            gridDelegate:
                                SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 240,
                                  // Keep the number at the top and allow larger text
                                  // to grow the compact cards without clipping.
                                  mainAxisExtent:
                                      212 *
                                      MediaQuery.textScalerOf(context).scale(1),
                                  crossAxisSpacing: 10,
                                  mainAxisSpacing: 10,
                                ),
                            itemCount: tables.length + (more ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (index == tables.length) {
                                return TextButton(
                                  onPressed: busy ? null : () => load(),
                                  child: Text(
                                    busy ? 'Loading…' : 'More tables',
                                  ),
                                );
                              }
                              final table = tables[index];
                              final order = tableOrders['${table['id']}'];
                              final pendingKot =
                                  tablePendingKot['${table['id']}'] ?? 0;
                              final joined =
                                  mergedTables['${table['id']}'] ??
                                  const <String>[];
                              final isJoined = joined.length > 1;
                              final statusColor = switch (table['status']) {
                                'occupied' => darkIndigo,
                                'bill_pending' => const Color(0xFFB45309),
                                _ => const Color(0xFF15803D),
                              };
                              final futureBookings =
                                  ((bookings ??
                                              const <
                                                String,
                                                List<Json>
                                              >{})[table['id'].toString()] ??
                                          <Json>[])
                                      .where((booking) {
                                        final start = indiaDateTime(
                                          booking['start_at'],
                                        );
                                        return start != null &&
                                            start.isAfter(indiaNow());
                                      })
                                      .toList();
                              final hasFutureBooking =
                                  futureBookings.isNotEmpty;
                              // A future reservation is visually distinct only while the
                              // table is free. Active service status always takes priority.
                              final cardColor = isJoined
                                  ? const Color(0xFF0F766E)
                                  : table['status'] == 'empty' &&
                                        hasFutureBooking
                                  ? const Color(0xFFD97706)
                                  : statusColor;
                              String bookingTime(Json booking) {
                                final start = indiaDateTime(
                                  booking['start_at'],
                                )!;
                                final end = indiaDateTime(booking['end_at'])!;
                                String clock(DateTime value) =>
                                    (value.hour % 12 == 0
                                            ? 12
                                            : value.hour % 12)
                                        .toString() +
                                    ':' +
                                    value.minute.toString().padLeft(2, '0') +
                                    (value.hour >= 12 ? 'p' : 'a');
                                return clock(start) + '-' + clock(end);
                              }

                              final tableId = '${table['id']}';
                              final signature = jsonEncode([
                                table,
                                order,
                                pendingKot,
                                joined,
                                futureBookings,
                                order == null ? '' : elapsed(order),
                                widget.session.manager,
                              ]);
                              final cached = cardCache[tableId];
                              if (cached != null && cached.$1 == signature) {
                                return cached.$2;
                              }
                              final card = GestureDetector(
                                key: ValueKey(tableId),
                                onSecondaryTap: widget.session.manager
                                    ? () => openTableBookingDialog(
                                        context,
                                        widget.session,
                                        table,
                                      )
                                    : null,
                                onLongPress: widget.session.manager
                                    ? () => openTableBookingDialog(
                                        context,
                                        widget.session,
                                        table,
                                      )
                                    : null,
                                child: Material(
                                  color: Colors.white,
                                  elevation: 1,
                                  shadowColor: const Color(0x0F111827),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                    side: BorderSide(
                                      color: cardColor.withValues(alpha: 0.24),
                                    ),
                                  ),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(16),
                                    onTap: () => select(table),
                                    child: Padding(
                                      padding: const EdgeInsets.all(10),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  '${table['table_number']}',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    color: ink,
                                                    fontSize: 24,
                                                    height: 1.15,
                                                    fontWeight: FontWeight.w800,
                                                    letterSpacing: -0.7,
                                                  ),
                                                ),
                                              ),
                                              if (widget.session.manager)
                                                IconButton(
                                                  tooltip: 'Advance booking',
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  padding: EdgeInsets.zero,
                                                  constraints:
                                                      const BoxConstraints(
                                                        minWidth: 28,
                                                        minHeight: 28,
                                                      ),
                                                  onPressed: () =>
                                                      openTableBookingDialog(
                                                        context,
                                                        widget.session,
                                                        table,
                                                      ),
                                                  icon: const Icon(
                                                    Icons
                                                        .event_available_outlined,
                                                    size: 17,
                                                    color: deepIndigo,
                                                  ),
                                                ),
                                            ],
                                          ),
                                          const SizedBox(height: 3),
                                          if (isJoined)
                                            Text(
                                              'Merged tables: ${joined.join(' + ')}',
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: Color(0xFF0F766E),
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            )
                                          else if (futureBookings.isEmpty)
                                            Text(
                                              table['section'],
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: Colors.black45,
                                                fontSize: 11,
                                              ),
                                            )
                                          else
                                            GestureDetector(
                                              onTap: () =>
                                                  openTableBookingDetails(
                                                    context,
                                                    futureBookings,
                                                    table['table_number']
                                                        .toString(),
                                                  ),
                                              child: Text(
                                                'Booking ' +
                                                    futureBookings
                                                        .take(2)
                                                        .map(bookingTime)
                                                        .join(' · '),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color:
                                                      table['status'] == 'empty'
                                                      ? const Color(0xFFD97706)
                                                      : deepIndigo,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ),
                                          const SizedBox(height: 7),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 7,
                                              vertical: 3,
                                            ),
                                            decoration: BoxDecoration(
                                              color: cardColor.withValues(
                                                alpha: 0.08,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              pendingKot > 0 &&
                                                      table['status'] !=
                                                          'bill_pending'
                                                  ? 'Order completion pending'
                                                  : tableStatus(
                                                      table['status'],
                                                    ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 10,
                                                height: 1.2,
                                                fontWeight: FontWeight.w700,
                                                color: cardColor,
                                              ),
                                            ),
                                          ),
                                          if (order != null &&
                                              table['status'] != 'empty') ...[
                                            const SizedBox(height: 5),
                                            Text(
                                              '${order['customer_name'] ?? ''}'
                                                      .trim()
                                                      .isEmpty
                                                  ? 'Guest'
                                                  : '${order['customer_name']}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 12,
                                              ),
                                            ),
                                            Text(
                                              'Items ${money(maps(order['items']).fold<int>(0, (sum, item) => sum + number(item['quantity']) * number(item['price_minor'])))}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 12,
                                              ),
                                            ),
                                            if (elapsed(order).isNotEmpty)
                                              Text(
                                                'Open ${elapsed(order)}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                  color: Colors.black54,
                                                ),
                                              ),
                                          ],
                                          const Spacer(),
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Container(
                                                  padding: pendingKot > 0
                                                      ? const EdgeInsets.symmetric(
                                                          horizontal: 5,
                                                          vertical: 1,
                                                        )
                                                      : EdgeInsets.zero,
                                                  decoration: BoxDecoration(
                                                    color: pendingKot > 0
                                                        ? const Color(
                                                            0xFFFFF7ED,
                                                          )
                                                        : Colors.transparent,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          5,
                                                        ),
                                                  ),
                                                  child: Text(
                                                    order != null &&
                                                            table['status'] !=
                                                                'empty'
                                                        ? pendingKot > 0
                                                              ? 'KOT pending: $pendingKot'
                                                              : 'KOT sent'
                                                        : '${table['capacity']} seats',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: 10,
                                                      fontWeight: pendingKot > 0
                                                          ? FontWeight.w800
                                                          : FontWeight.w500,
                                                      color: pendingKot > 0
                                                          ? const Color(
                                                              0xFFB45309,
                                                            )
                                                          : secondaryText,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              Icon(
                                                Icons.chevron_right,
                                                size: 15,
                                                color: cardColor,
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                              cardCache[tableId] = (signature, card);
                              return card;
                            },
                          ),
                        ),
                ),
              ],
            ),
          ),
          if (box.maxWidth >= 1000)
            const SizedBox(width: 360, child: _TicketPreview()),
        ],
      ),
    ),
  );
}

class _TicketPreview extends StatelessWidget {
  const _TicketPreview();

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(left: BorderSide(color: line)),
    ),
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 14, 14),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'CURRENT TICKET',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.black54,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              TextButton(onPressed: null, child: const Text('Clear Ticket')),
            ],
          ),
        ),
        const Divider(height: 1),
        const Padding(
          padding: EdgeInsets.all(18),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Takeaway / Free Bill',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            children: [
              Expanded(child: _TicketField(label: 'CLIENT NAME')),
              SizedBox(width: 10),
              Expanded(child: _TicketField(label: 'PHONE (OPTIONAL)')),
            ],
          ),
        ),
        const Expanded(
          child: EmptyState(
            'Ticket is empty',
            'Tap any table or dish to start an order.',
            icon: Icons.restaurant_menu_outlined,
          ),
        ),
      ],
    ),
  );
}

class _TicketField extends StatelessWidget {
  final String label;
  const _TicketField({required this.label});

  @override
  Widget build(BuildContext context) => TextField(
    decoration: InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
    ),
  );
}
