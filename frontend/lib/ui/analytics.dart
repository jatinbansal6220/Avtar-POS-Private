import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/session.dart';
import '../features/analytics/local_reports.dart';
import '../features/analytics/closing_page.dart';
import '../features/analytics/analytics_chart.dart';
import '../features/analytics/analytics_series.dart';
import 'shared.dart';

class AnalyticsPage extends StatefulWidget {
  final Session session;
  const AnalyticsPage(this.session, {super.key});
  @override
  State<AnalyticsPage> createState() => _AnalyticsPageState();
}

class _AnalyticsPageState extends State<AnalyticsPage> {
  final from = TextEditingController(
        text: day(indiaNow().subtract(const Duration(days: 6))),
      ),
      to = TextEditingController(text: day(indiaNow()));
  Json? data;
  String? error;
  bool busy = false, authorized = false;
  int generation = 0;
  String preset = 'Last 7 days';
  List<Json> daily = [], hourly = [];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => verifyAccess());
  }

  Future<void> verifyAccess() async {
    if (!mounted || busy) return;
    var entered = '';
    final action = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Verify owner code'),
        content: TextField(
          onChanged: (value) => entered = value,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Invoice deletion/edit code',
            helperText: 'The same owner code protects Analytics.',
          ),
          onSubmitted: (value) {
            entered = value;
            Navigator.pop(dialogContext, true);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Open analytics'),
          ),
        ],
      ),
    );
    if (action != true) return;
    try {
      await widget.session.verifyInvoiceAccessCode(entered);
      if (!mounted) return;
      setState(() {
        authorized = true;
        error = null;
      });
      await load();
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    }
  }

  @override
  void dispose() {
    from.dispose();
    to.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (!mounted || !authorized) return;
    final request = ++generation;
    final start = from.text, end = to.text;
    setState(() {
      busy = true;
      error = null;
      data = null;
    });
    try {
      // Validate before querying; keep chart/date expansion bounded.
      dailyAnalyticsSeries(start, end, const []);
      final result = await LocalReports(widget.session.local!)
          .analytics(start, end);
      if (mounted && request == generation) {
        setState(() {
          data = result;
          daily = dailyAnalyticsSeries(start, end, maps(result['daily']));
          hourly = hourlyAnalyticsSeries(maps(result['hourly']));
          error = null;
        });
      }
    } catch (e) {
      if (mounted && request == generation) {
        setState(() => error = e.toString());
      }
    } finally {
      if (mounted && request == generation) setState(() => busy = false);
    }
  }

  void choosePreset(String value) {
    final now = indiaNow();
    final end = value == 'Yesterday'
        ? now.subtract(const Duration(days: 1))
        : now;
    final start = switch (value) {
      'Last 7 days' => now.subtract(const Duration(days: 6)),
      'Last 30 days' => now.subtract(const Duration(days: 29)),
      'This week' => now.subtract(Duration(days: now.weekday - 1)),
      'This month' => DateTime(now.year, now.month),
      _ => end,
    };
    setState(() {
      preset = value;
      from.text = day(start);
      to.text = day(end);
    });
    load();
  }

  Future<void> chooseRange() async {
    final range = await showDateRangePicker(
      context: context,
      initialDateRange: DateTimeRange(
        start: DateTime.parse(from.text),
        end: DateTime.parse(to.text),
      ),
      firstDate: DateTime(1900),
      lastDate: indiaNow(),
      helpText: 'Choose sales period · maximum 366 days',
    );
    if (range == null || !mounted) return;
    try {
      dailyAnalyticsSeries(day(range.start), day(range.end), const []);
    } catch (_) {
      message(context, 'Choose up to 366 days for this graph.');
      return;
    }
    setState(() {
      preset = 'Custom';
      from.text = day(range.start);
      to.text = day(range.end);
    });
    load();
  }

  void openDay(String date) {
    if (busy) return;
    setState(() {
      preset = 'Custom';
      from.text = date;
      to.text = date;
    });
    load();
  }

  Widget dailyDetails() => Card(
    elevation: 0,
    child: ExpansionTile(
      title: const Text('Day-by-day sales'),
      subtitle: Text('${daily.length} dates · including zero-sales days'),
      children: [
        SizedBox(
          height: daily.length < 5 ? daily.length * 76.0 : 350,
          child: ListView.builder(
            itemCount: daily.length,
            itemBuilder: (context, index) {
              final row = daily[daily.length - 1 - index];
              return ListTile(
                title: Text('${row['day']}'),
                subtitle: Text(
                  '${money(row['revenue_minor'])} · ${number(row['bills'])} bills',
                ),
                trailing: IconButton(
                  tooltip: 'View ${row['day']}',
                  onPressed: busy ? null : () => openDay('${row['day']}'),
                  icon: const Icon(Icons.arrow_forward),
                ),
              );
            },
          ),
        ),
      ],
    ),
  );

  Widget bars(String title, List<Json> rows, String label) {
    final max = rows.fold<int>(
      1,
      (max, r) =>
          number(r['revenue_minor']) > max ? number(r['revenue_minor']) : max,
    );
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 20),
          if (rows.isEmpty)
            const Text(
              'No finalized bills in this period.',
              style: TextStyle(color: Colors.black54),
            ),
          for (final row in rows.take(20))
            Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${row[label]}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (row['orders'] != null ||
                                row['quantity'] != null)
                              Text(
                                row['quantity'] != null
                                    ? '${number(row['quantity'])} sold'
                                    : '${number(row['orders'])} order${number(row['orders']) == 1 ? '' : 's'}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: secondaryText,
                                ),
                              ),
                          ],
                        ),
                      ),
                      Text(
                        money(row['revenue_minor']),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: number(row['revenue_minor']) / max,
                      minHeight: 8,
                      backgroundColor: canvas,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget section(String title, List<Json> rows, String label) {
    final max = rows.fold<int>(1, (highest, row) {
      final current = number(row['revenue_minor'] ?? row['discount_minor']);
      return current > highest ? current : highest;
    });
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 18),
          if (rows.isEmpty)
            const Text(
              'No data in this period.',
              style: TextStyle(color: Colors.black54),
            ),
          for (final row in rows.take(12))
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${row[label]}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (row['orders'] != null)
                              Text(
                                '${number(row['orders'])} order${number(row['orders']) == 1 ? '' : 's'}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: secondaryText,
                                ),
                              ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            money(
                              row['revenue_minor'] ?? row['discount_minor'],
                            ),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          if (row['discount_minor'] != null)
                            const Text(
                              'discount used',
                              style: TextStyle(
                                fontSize: 11,
                                color: secondaryText,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value:
                          number(
                            row['revenue_minor'] ?? row['discount_minor'],
                          ) /
                          max,
                      minHeight: 7,
                      backgroundColor: canvas,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String changeLabel() {
    final current = number(data!['summary']['revenue_minor']);
    final previous = number(data!['previous']['revenue_minor']);
    if (previous == 0) return current == 0 ? 'No change' : 'New sales';
    final percent = ((current - previous) * 100 / previous).toStringAsFixed(1);
    return '${current >= previous ? '+' : ''}$percent% vs prior period';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Business analytics'),
      actions: [
        TextButton(
          onPressed: authorized
              ? () => openPage(
                  context,
                  ClosingPage(widget.session, accessVerified: true),
                )
              : null,
          child: const Text('Day report'),
        ),
      ],
    ),
    body: !authorized
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_outline, size: 42, color: accent),
                  const SizedBox(height: 12),
                  const Text('Analytics is protected by the owner code.'),
                  if (error != null) ...[
                    const SizedBox(height: 10),
                    Text(error!, style: const TextStyle(color: Colors.red)),
                  ],
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed: verifyAccess,
                    child: const Text('Enter owner code'),
                  ),
                ],
              ),
            ),
          )
        : ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final label in [
                    'Today',
                    'Yesterday',
                    'Last 7 days',
                    'Last 30 days',
                    'This week',
                    'This month',
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: preset == label,
                      onSelected: busy ? null : (_) => choosePreset(label),
                    ),
                  OutlinedButton.icon(
                    onPressed: busy ? null : chooseRange,
                    icon: const Icon(Icons.date_range_outlined),
                    label: const Text('Choose dates'),
                  ),
                  IconButton(
                    tooltip: 'Refresh analytics',
                    onPressed: busy ? null : load,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                '${from.text} to ${to.text} · Asia/Kolkata',
                style: const TextStyle(color: secondaryText),
              ),
              const SizedBox(height: 16),
              if (busy) const LinearProgressIndicator(),
              if (error != null)
                Text(error!, style: const TextStyle(color: Colors.red)),
              if (data != null) ...[
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    Metric(
                      'Net sales',
                      money(data!['summary']['revenue_minor']),
                    ),
                    Metric('Bills', '${data!['summary']['bills']}'),
                    Metric(
                      'Average bill',
                      number(data!['summary']['bills']) == 0
                          ? money(0)
                          : money(
                              number(data!['summary']['revenue_minor']) ~/
                                  number(data!['summary']['bills']),
                            ),
                    ),
                    Metric('Tax', money(data!['summary']['tax_minor'])),
                    Metric(
                      'Discounts',
                      money(data!['summary']['discount_minor']),
                    ),
                    Metric('Sales trend', changeLabel()),
                    Metric(
                      'Average sales / day',
                      money(
                        daily.isEmpty
                            ? 0
                            : number(data!['summary']['revenue_minor']) ~/
                                  daily.length,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                AnalyticsChart(
                  title: 'Daily sales trend',
                  rows: daily,
                  onOpenDay: busy ? null : openDay,
                ),
                const SizedBox(height: 12),
                dailyDetails(),
                const SizedBox(height: 16),
                AnalyticsChart(
                  title: from.text == to.text
                      ? 'Hourly sales · ${from.text}'
                      : 'Hourly sales · selected period',
                  rows: hourly,
                  labelKey: 'hour',
                  hourly: true,
                ),
                for (final row in maps(
                  data!['hourly'],
                ).where((row) => row['hour'] == 'Unspecified'))
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      '${number(row['bills'])} older bills (${money(row['revenue_minor'])}) have no billing hour. They remain in sales totals but cannot be placed on the hourly chart.',
                    ),
                  ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    Metric(
                      'Top today',
                      '${data!['top_today']?['name'] ?? 'No sales'}',
                    ),
                    Metric(
                      'Least sold today',
                      '${data!['least_today']?['name'] ?? 'No menu items'}',
                    ),
                    Metric(
                      'Top this week',
                      '${data!['top_week']?['name'] ?? 'No sales'}',
                    ),
                    Metric(
                      'Purchase spend',
                      money(data!['purchase']['spend_minor']),
                    ),
                    Metric(
                      'Voided item value',
                      money(
                        maps(data!['voids']).fold<int>(
                          0,
                          (sum, row) => sum + number(row['revenue_minor']),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Text(
                  'Compare: ${data!['previous_from']} to ${data!['previous_to']}',
                  style: const TextStyle(color: secondaryText),
                ),
                const SizedBox(height: 16),
                section(
                  'Sales channel & online platforms',
                  maps(data!['channels']),
                  'channel',
                ),
                const SizedBox(height: 20),
                section(
                  'Payment mix · split orders can appear in both methods',
                  maps(data!['payments']),
                  'method',
                ),
                const SizedBox(height: 20),
                section(
                  'Discounts & minus amounts',
                  maps(data!['discounts']),
                  'type',
                ),
                const SizedBox(height: 20),
                section(
                  'Cashier performance',
                  maps(data!['cashiers']),
                  'cashier',
                ),
                const SizedBox(height: 20),
                bars('Table revenue', maps(data!['tables']), 'table_number'),
                const SizedBox(height: 20),
                bars(
                  'Item sales · before discount / tax',
                  maps(data!['items']),
                  'name',
                ),
              ],
            ],
          ),
  );
}
