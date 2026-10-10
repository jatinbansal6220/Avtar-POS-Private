import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../ui/record_editor_page.dart';
import '../../ui/shared.dart';
import '../../ui/staff.dart';
import 'staff_salary.dart';

class StaffDirectoryPage extends StatefulWidget {
  final Session session;
  const StaffDirectoryPage(this.session, {super.key});

  @override
  State<StaffDirectoryPage> createState() => _StaffDirectoryPageState();
}

class _StaffDirectoryPageState extends State<StaffDirectoryPage> {
  List<Json> staff = [];
  Map<String, int> paidByStaff = {};
  Map<String, int> attendanceCutByStaff = {};
  bool busy = true;
  String? error;
  String search = '';
  String scope = 'all';
  int loadRevision = 0;

  @override
  void initState() {
    super.initState();
    for (final resource in ['staff', 'payments', 'staff_salary_adjustments']) {
      widget.session.watch(resource).addListener(refreshData);
    }
    load();
  }

  void refreshData() {
    if (mounted) load();
  }

  @override
  void dispose() {
    for (final resource in ['staff', 'payments', 'staff_salary_adjustments']) {
      widget.session.watch(resource).removeListener(refreshData);
    }
    super.dispose();
  }

  Future<void> load() async {
    final revision = ++loadRevision;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final values = await Future.wait([
        widget.session.local!.listAll('staff'),
        widget.session.local!.paymentTotalsByStaff(),
        widget.session.local!.listAll('staff_salary_adjustments'),
      ]);
      final members = values[0] as List<Json>;
      final confirmedCuts = values[2] as List<Json>;
      if (mounted && revision == loadRevision) {
        setState(() {
          staff = members;
          paidByStaff = values[1] as Map<String, int>;
          attendanceCutByStaff = {
            for (final member in members)
              member['id'].toString(): confirmedCuts
                  .where(
                    (cut) =>
                        cut['staff_id'].toString() == member['id'].toString(),
                  )
                  .fold<int>(
                    0,
                    (total, cut) => total + number(cut['deduction_minor']),
                  ),
          };
          busy = false;
        });
      }
    } catch (exception) {
      if (mounted && revision == loadRevision) {
        setState(() {
          error = '$exception';
          busy = false;
        });
      }
    }
  }

  List<Json> get visibleStaff => staff.where((member) {
    final active = member['is_active'] == null || enabled(member['is_active']);
    if (scope == 'active' && !active || scope == 'inactive' && active) {
      return false;
    }
    return ['name', 'phone', 'role'].any(
      (field) => '${member[field] ?? ''}'.toLowerCase().contains(
        search.trim().toLowerCase(),
      ),
    );
  }).toList();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Staff Management'),
      actions: [
        IconButton(
          tooltip: 'Refresh staff',
          onPressed: busy ? null : load,
          icon: const Icon(Icons.refresh),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: FilledButton.icon(
            onPressed: !widget.session.manager
                ? null
                : () async {
                    await openPage(
                      context,
                      RecordEditor(widget.session, 'staff'),
                    );
                    if (mounted) load();
                  },
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add Staff'),
          ),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              TextField(
                decoration: const InputDecoration(
                  labelText: 'Search name, phone or role',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (value) => setState(() => search = value),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final filter in [
                    ('all', 'All staff'),
                    ('active', 'Active'),
                    ('inactive', 'Inactive'),
                  ])
                    ChoiceChip(
                      label: Text(filter.$2),
                      selected: scope == filter.$1,
                      onSelected: (_) => setState(() => scope = filter.$1),
                    ),
                  Text('${visibleStaff.length} staff'),
                ],
              ),
            ],
          ),
        ),
        if (error != null)
          MaterialBanner(
            content: Text(error!),
            actions: [TextButton(onPressed: load, child: const Text('Retry'))],
          ),
        Expanded(
          child: busy
              ? const Center(child: CircularProgressIndicator())
              : visibleStaff.isEmpty
              ? EmptyState(
                  staff.isEmpty ? 'No staff yet' : 'No matching staff',
                  staff.isEmpty
                      ? 'Add a staff member to start attendance and payment tracking.'
                      : 'Try another search or filter.',
                )
              : LayoutBuilder(
                  builder: (context, box) {
                    Widget buildCard(BuildContext context, int index) {
                      final member = visibleStaff[index];
                      return _StaffCard(
                        member,
                        paid: paidByStaff[member['id'].toString()] ?? 0,
                        attendanceCut:
                            attendanceCutByStaff[member['id'].toString()] ?? 0,
                        onOpen: () async {
                          try {
                            await openPage(
                              context,
                              StaffPage(widget.session, member),
                            );
                            if (context.mounted) load();
                          } catch (error) {
                            if (context.mounted) message(context, error);
                          }
                        },
                        onEdit: () async {
                          await openPage(
                            context,
                            RecordEditor(widget.session, 'staff', row: member),
                          );
                          if (mounted) load();
                        },
                      );
                    }

                    if (box.maxWidth < 600) {
                      return ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: visibleStaff.length,
                        itemBuilder: buildCard,
                      );
                    }
                    return GridView.builder(
                      padding: const EdgeInsets.all(28),
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: box.maxWidth > 1100 ? 390 : 520,
                        mainAxisExtent:
                            420 * MediaQuery.textScalerOf(context).scale(1),
                        crossAxisSpacing: 18,
                        mainAxisSpacing: 18,
                      ),
                      itemCount: visibleStaff.length,
                      itemBuilder: buildCard,
                    );
                  },
                ),
        ),
      ],
    ),
  );
}

class _StaffCard extends StatelessWidget {
  final Json member;
  final int paid, attendanceCut;
  final VoidCallback onOpen, onEdit;
  const _StaffCard(
    this.member, {
    required this.paid,
    required this.attendanceCut,
    required this.onOpen,
    required this.onEdit,
  });

  int get salaryAccrued =>
      (staffSalaryAccrued(member) - attendanceCut).clamp(0, 1 << 62).toInt();

  @override
  Widget build(BuildContext context) {
    // Compact Android spacing while allowing salary rows enough height.
    final isAndroid = Theme.of(context).platform == TargetPlatform.android;
    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: isAndroid
              ? const EdgeInsets.symmetric(horizontal: 16, vertical: 6)
              : const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${member['name']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Flexible(child: StatusPill('${member['role'] ?? 'staff'}')),
                ],
              ),
              SizedBox(height: isAndroid ? 4 : 8),
              Text(
                '${member['phone'] ?? ''}',
                style: const TextStyle(color: Colors.black54),
              ),
              if (member['is_active'] != null && !enabled(member['is_active']))
                const Text('Inactive', style: TextStyle(color: Colors.orange)),
              SizedBox(height: isAndroid ? 4 : 18),
              Container(
                padding: isAndroid
                    ? const EdgeInsets.symmetric(horizontal: 10, vertical: 6)
                    : const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: canvas,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  children: [
                    _Line(
                      'Monthly salary',
                      money(member['monthly_salary_minor']),
                    ),
                    SizedBox(height: isAndroid ? 3 : 8),
                    _Line('Salary after attendance cut', money(salaryAccrued)),
                    SizedBox(height: isAndroid ? 3 : 8),
                    _Line('Total paid (all time)', money(paid)),
                    SizedBox(height: isAndroid ? 3 : 8),
                    _Line(
                      salaryAccrued - paid < 0
                          ? 'Advance paid'
                          : 'Salary balance',
                      money((salaryAccrued - paid).abs()),
                      negative: salaryAccrued - paid < 0,
                    ),
                    SizedBox(height: isAndroid ? 3 : 8),
                    _Line('Joining date', '${member['joining_date'] ?? '—'}'),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: onOpen,
                      child: const Text('View profile'),
                    ),
                  ),
                  IconButton(
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  final String label, value;
  final bool negative;
  const _Line(this.label, this.value, {this.negative = false});
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(label, style: const TextStyle(color: Colors.black54)),
      ),
      Flexible(
        child: Text(
          value,
          textAlign: TextAlign.end,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: negative ? Colors.red : null,
          ),
        ),
      ),
    ],
  );
}
