import 'dart:async';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/session.dart';
import 'shared.dart';
import 'record_editor_page.dart';
import 'records_page.dart';
import '../features/staff/staff_salary.dart';

/// Payment history is primary; attendance loads only this employee/month.
class StaffPage extends StatefulWidget {
  final Session session;
  final Json staff;
  const StaffPage(this.session, this.staff, {super.key});
  @override
  State<StaffPage> createState() => _StaffPageState();
}

class _StaffPageState extends State<StaffPage> {
  late Json member;
  bool loading = true;
  bool reviewingMonth = false;
  bool removing = false;
  int loadRevision = 0;
  DateTime month = DateTime.utc(indiaNow().year, indiaNow().month);
  List<Json> attendance = [];
  String? error;
  int paymentRevision = 0;
  int totalPaid = 0;
  int attendanceCut = 0;
  List<Json> salaryCuts = [];
  bool checkedMonthlySummary = false;
  @override
  void initState() {
    super.initState();
    member = clone(widget.staff);
    for (final resource in [
      'staff',
      'payments',
      'attendance',
      'staff_salary_adjustments',
    ]) {
      widget.session.watch(resource).addListener(refreshData);
    }
    load();
  }

  void refreshData() {
    if (!mounted) return;
    setState(() => paymentRevision++);
    load();
  }

  @override
  void dispose() {
    for (final resource in [
      'staff',
      'payments',
      'attendance',
      'staff_salary_adjustments',
    ]) {
      widget.session.watch(resource).removeListener(refreshData);
    }
    super.dispose();
  }

  Future<void> load() async {
    final revision = ++loadRevision;
    final selectedMonth = month;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final values = await Future.wait([
        widget.session.local!.list(
          'attendance',
          filters: {
            'staff_id': member['id'],
            'from': day(selectedMonth),
            'to': day(DateTime(selectedMonth.year, selectedMonth.month + 1, 0)),
          },
          limit: 100,
        ),
        widget.session.local!.paymentTotalsByStaff(),
        widget.session.local!.listAll(
          'staff_salary_adjustments',
          filters: {'staff_id': member['id']},
        ),
        widget.session.local!.get('staff', '${member['id']}'),
      ]);
      final rows = values[0] as List<Json>;
      final paid = values[1] as Map<String, int>;
      final confirmedCuts = values[2] as List<Json>;
      if (mounted && revision == loadRevision) {
        setState(() {
          member = (values[3] as Json?) ?? member;
          attendance = rows;
          totalPaid = paid[member['id'].toString()] ?? 0;
          salaryCuts = confirmedCuts;
          attendanceCut = confirmedCuts.fold<int>(
            0,
            (total, cut) => total + number(cut['deduction_minor']),
          );
          error = null;
          loading = false;
        });
        if (!checkedMonthlySummary) {
          checkedMonthlySummary = true;
          unawaited(showCompletedMonthSummary());
        }
      }
    } catch (e) {
      if (mounted && revision == loadRevision) {
        setState(() {
          error = '$e';
          loading = false;
        });
      }
    }
  }

  String monthLabel(DateTime value) {
    const names = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${names[value.month - 1]} ${value.year}';
  }

  /// Each employee gets their own completed-month proposal. It is not a
  /// deduction until the owner explicitly confirms it; the confirmed record
  /// itself prevents a second popup for that staff/month on every device.
  Future<void> showCompletedMonthSummary({DateTime? selectedMonth}) async {
    if (reviewingMonth || !widget.session.manager) return;
    setState(() => reviewingMonth = true);
    try {
      final now = indiaNow();
      final completed = selectedMonth ?? DateTime(now.year, now.month - 1);
      if (!completed.isBefore(DateTime(now.year, now.month))) return;
      final monthEnd = DateTime(completed.year, completed.month + 1, 0);
      final profileStarted = indiaDateTime(member['created_at']);
      if (profileStarted != null &&
          day(profileStarted).compareTo(day(monthEnd)) > 0) {
        return;
      }
      final confirmed = await widget.session.local!.listAll(
        'staff_salary_adjustments',
        filters: {'staff_id': member['id']},
      );
      final monthStart = day(completed);
      if (confirmed.any((cut) => cut['month_start'] == monthStart)) {
        if (mounted && selectedMonth != null) {
          message(context, 'This month has already been reviewed.');
        }
        return;
      }
      final rows = await widget.session.local!.list(
        'attendance',
        filters: {
          'staff_id': member['id'],
          'from': day(completed),
          'to': day(monthEnd),
        },
        limit: 100,
      );
      final applicableRows = rows
          .where(
            (row) =>
                profileStarted == null ||
                '${row['date']}'.compareTo(day(profileStarted)) >= 0,
          )
          .toList();
      final absent = applicableRows
          .where((row) => row['status'] == 'absent')
          .length;
      final halfDays = applicableRows
          .where((row) => row['status'] == 'half_day')
          .length;
      final leave = applicableRows
          .where((row) => row['status'] == 'leave')
          .length;
      final salaryCut = attendanceSalaryDeductionForMonth(
        member,
        applicableRows,
        completed,
      );
      if (!mounted) return;
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${member['name']} · ${monthLabel(completed)}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Completed-month attendance summary'),
                const SizedBox(height: 14),
                Text('Absent: $absent day${absent == 1 ? '' : 's'}'),
                Text('Half day: $halfDays'),
                Text('Leave: $leave day${leave == 1 ? '' : 's'}'),
                const SizedBox(height: 10),
                Text(
                  'Salary cut for this month: ${money(salaryCut)}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Yes, apply cut'),
            ),
          ],
        ),
      );
      if (approved != true || !mounted) return;
      try {
        await widget.session.mutate('staff_salary_adjustments', {
          'staff_id': member['id'],
          'month_start': monthStart,
          'absent_days': absent,
          'half_days': halfDays,
          'deduction_minor': salaryCut,
          'reason': 'Attendance: $absent absent day(s), $halfDays half day(s)',
        });
        await load();
      } catch (e) {
        if (mounted) setState(() => error = '$e');
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => reviewingMonth = false);
    }
  }

  int get grossSalaryAccrued => staffSalaryAccrued(member);
  int get salaryAccrued =>
      (grossSalaryAccrued - attendanceCut).clamp(0, 1 << 62).toInt();

  Widget overview() {
    final balance = salaryAccrued - totalPaid;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Staff account',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            Text('Joining date: ${member['joining_date'] ?? '—'}'),
            const SizedBox(height: 4),
            Text('Monthly salary: ${money(member['monthly_salary_minor'])}'),
            const SizedBox(height: 4),
            Text('Salary accrued (all time): ${money(grossSalaryAccrued)}'),
            const SizedBox(height: 4),
            Text('Attendance cut: ${money(attendanceCut)}'),
            const SizedBox(height: 4),
            Text('Final salary: ${money(salaryAccrued)}'),
            const SizedBox(height: 4),
            Text('Paid all time: ${money(totalPaid)}'),
            const SizedBox(height: 4),
            Text(
              balance < 0
                  ? 'Advance paid: ${money(-balance)}'
                  : 'Salary balance: ${money(balance)}',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: balance < 0 ? Colors.red : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget salaryCutHistory() {
    final entries = [...salaryCuts]
      ..sort((a, b) => '${b['month_start']}'.compareTo('${a['month_start']}'));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Confirmed attendance cuts',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            if (entries.isEmpty)
              const Text('No attendance cut has been approved yet.'),
            for (final cut in entries)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${cut['month_start']} · ${cut['reason']}'),
                trailing: Text(
                  '-${money(cut['deduction_minor'])}',
                  style: const TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> removeStaff() async {
    if (removing || !widget.session.manager) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${member['name']}?'),
        content: const Text(
          'The staff profile will be removed from active lists. Existing payment and attendance records remain in audit history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove staff'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    setState(() => removing = true);
    try {
      await widget.session.mutate('staff', {
        'id': member['id'],
        'version': member['version'],
      }, delete: true);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => removing = false);
    }
  }

  Future<void> addPayment() async {
    await openPage(
      context,
      RecordEditor(
        widget.session,
        'payments',
        initial: {'staff_id': member['id'], 'staff_id_label': member['name']},
        hiddenFields: const {'staff_id'},
      ),
    );
    if (mounted) {
      setState(() => paymentRevision++);
      await load();
    }
  }

  Widget calendar() => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: Text('Attendance ${monthLabel(month)}')),
              IconButton(
                onPressed: () {
                  month = DateTime(month.year, month.month - 1);
                  load();
                },
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton(
                onPressed: () {
                  month = DateTime(month.year, month.month + 1);
                  load();
                },
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          if (loading) const LinearProgressIndicator(),
          if (month.isBefore(DateTime(indiaNow().year, indiaNow().month)))
            TextButton(
              onPressed: loading || reviewingMonth
                  ? null
                  : () => showCompletedMonthSummary(selectedMonth: month),
              child: Text(
                reviewingMonth
                    ? 'Reviewing…'
                    : 'Review this month’s salary cut',
              ),
            ),
          Row(
            children: [
              for (final label in ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
                Expanded(child: Center(child: Text(label))),
            ],
          ),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisExtent: 48,
            ),
            itemCount:
                DateTime(month.year, month.month + 1, 0).day +
                month.weekday -
                1,
            itemBuilder: (context, index) {
              final number = index - month.weekday + 2;
              if (number < 1) return const SizedBox.shrink();
              final date = day(DateTime(month.year, month.month, number));
              final existing = attendance
                  .where((row) => row['date'] == date)
                  .firstOrNull;
              return InkWell(
                onTap: loading || !widget.session.manager
                    ? null
                    : () async {
                        await openPage(
                          context,
                          RecordEditor(
                            widget.session,
                            'attendance',
                            row: existing,
                            initial: {
                              'staff_id': member['id'],
                              'staff_id_label': member['name'],
                              'date': date,
                            },
                            hiddenFields: const {'staff_id', 'date'},
                          ),
                        );
                        if (mounted) await load();
                      },
                child: Container(
                  margin: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: existing == null ? canvas : lightIndigo,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('$number'),
                      Text(
                        existing == null
                            ? '—'
                            : '${existing['status']}'
                                  .substring(0, 1)
                                  .toUpperCase(),
                        style: const TextStyle(fontSize: 10),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const Text(
            'P Present · A Absent · H Half day · L Leave',
            style: TextStyle(fontSize: 10),
          ),
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('${member['name']}'),
      actions: [
        IconButton(
          tooltip: 'Edit staff',
          onPressed: removing || !widget.session.manager
              ? null
              : () async {
                  final result = await openPage<Json>(
                    context,
                    RecordEditor(widget.session, 'staff', row: member),
                  );
                  if (!mounted) return;
                  if (result == null) {
                    final saved = await widget.session.local!.get(
                      'staff',
                      '${member['id']}',
                    );
                    if (!mounted) return;
                    if (saved == null) {
                      Navigator.pop(this.context, true);
                      return;
                    }
                  }
                  if (result != null) setState(() => member = result);
                  await load();
                },
          icon: const Icon(Icons.edit_outlined),
        ),
        IconButton(
          tooltip: 'Remove staff',
          onPressed: removing || !widget.session.manager ? null : removeStaff,
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    ),
    body: Column(
      children: [
        if (error != null)
          MaterialBanner(
            content: Text(error!),
            actions: [TextButton(onPressed: load, child: const Text('Retry'))],
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              final payments = RecordsPage(
                widget.session,
                'payments',
                key: ValueKey(paymentRevision),
                filters: {'staff_id': member['id']},
              );
              return box.maxWidth >= 850
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: payments),
                        SizedBox(
                          width: 340,
                          child: SingleChildScrollView(
                            child: Column(
                              children: [
                                overview(),
                                const SizedBox(height: 10),
                                salaryCutHistory(),
                                const SizedBox(height: 10),
                                calendar(),
                              ],
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView(
                      children: [
                        ExpansionTile(
                          title: const Text('Staff account & attendance'),
                          children: [
                            overview(),
                            salaryCutHistory(),
                            calendar(),
                          ],
                        ),
                        SizedBox(height: 500, child: payments),
                      ],
                    );
            },
          ),
        ),
      ],
    ),
    floatingActionButton: widget.session.manager
        ? FloatingActionButton.extended(
            onPressed: removing ? null : addPayment,
            icon: const Icon(Icons.payments_outlined),
            label: const Text('Record payment'),
          )
        : null,
  );
}
