import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../ui/shared.dart';

String chartDate(String value) {
  final date = DateTime.tryParse(value);
  return date == null
      ? value
      : '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}';
}

class AnalyticsChart extends StatefulWidget {
  final String title, labelKey;
  final List<Json> rows;
  final bool hourly;
  final ValueChanged<String>? onOpenDay;
  const AnalyticsChart({
    super.key,
    required this.title,
    required this.rows,
    this.labelKey = 'day',
    this.hourly = false,
    this.onOpenDay,
  });
  @override
  State<AnalyticsChart> createState() => _AnalyticsChartState();
}

class _AnalyticsChartState extends State<AnalyticsChart> {
  bool bills = false, bars = false;
  int? selected;
  @override
  void didUpdateWidget(covariant AnalyticsChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rows != widget.rows) selected = null;
  }

  void select(double x, double width) {
    if (widget.rows.isEmpty) return;
    final fraction = ((x - 54) / math.max(1, width - 70)).clamp(0.0, 1.0);
    final index = (fraction * (widget.rows.length - 1)).round();
    if (index != selected) setState(() => selected = index);
  }

  @override
  Widget build(BuildContext context) {
    final index = selected ?? math.max(0, widget.rows.length - 1);
    final row = widget.rows.isEmpty ? <String, dynamic>{} : widget.rows[index];
    final title = '${row[widget.labelKey] ?? ''}';
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              widget.hourly
                  ? 'Sales by billing hour · Asia/Kolkata'
                  : 'Every calendar day is included. Tap or hover to inspect.',
              style: const TextStyle(color: secondaryText),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Sales'),
                  selected: !bills,
                  onSelected: (_) => setState(() => bills = false),
                ),
                ChoiceChip(
                  label: const Text('Bill count'),
                  selected: bills,
                  onSelected: (_) => setState(() => bills = true),
                ),
                ChoiceChip(
                  label: const Text('Line'),
                  selected: !bars,
                  onSelected: (_) => setState(() => bars = false),
                ),
                ChoiceChip(
                  label: const Text('Bars'),
                  selected: bars,
                  onSelected: (_) => setState(() => bars = true),
                ),
              ],
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) => Semantics(
                label:
                    '${widget.title}. ${widget.rows.length} points. Selected $title: ${money(row['revenue_minor'])}, ${number(row['bills'])} bills.',
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  onHover: (event) =>
                      select(event.localPosition.dx, constraints.maxWidth),
                  child: GestureDetector(
                    onTapDown: (event) =>
                        select(event.localPosition.dx, constraints.maxWidth),
                    onHorizontalDragUpdate: (event) =>
                        select(event.localPosition.dx, constraints.maxWidth),
                    child: CustomPaint(
                      key: ValueKey('${widget.title}-plot'),
                      size: Size(constraints.maxWidth, 240),
                      painter: _ChartPainter(
                        widget.rows,
                        widget.labelKey,
                        bills,
                        bars,
                        index,
                        widget.hourly,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (widget.rows.every((r) => number(r['bills']) == 0))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  widget.hourly
                      ? 'No bills with a known billing hour in this period.'
                      : 'No finalized bills in this period. Open orders are not counted.',
                ),
              ),
            const SizedBox(height: 10),
            DecoratedBox(
              decoration: BoxDecoration(
                color: lightIndigo,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 18,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text('Sales ${money(row['revenue_minor'])}'),
                    Text('${number(row['bills'])} bills'),
                    Text(
                      'Average ${money(number(row['bills']) == 0 ? 0 : number(row['revenue_minor']) ~/ number(row['bills']))}',
                    ),
                    if (widget.onOpenDay != null && title.isNotEmpty)
                      TextButton(
                        onPressed: () => widget.onOpenDay!(title),
                        child: const Text('View this day'),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              key: ValueKey(
                '${widget.title}-$index-${widget.rows.length}-$title',
              ),
              initialValue: widget.rows.isEmpty ? null : index,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: widget.hourly ? 'Inspect hour' : 'Inspect date',
              ),
              items: [
                for (var i = 0; i < widget.rows.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(
                      '${widget.rows[i][widget.labelKey]} · ${money(widget.rows[i]['revenue_minor'])}',
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => selected = value);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  final List<Json> rows;
  final String labelKey;
  final bool bills, bars, hourly;
  final int selected;
  _ChartPainter(
    this.rows,
    this.labelKey,
    this.bills,
    this.bars,
    this.selected,
    this.hourly,
  );

  void label(Canvas canvas, String text, Offset at, {bool centered = false}) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(color: secondaryText, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at - Offset(centered ? painter.width / 2 : 0, 0));
  }

  String axis(double value) {
    final amount = bills ? value : value / 100;
    final text = amount >= 100000
        ? '${(amount / 100000).toStringAsFixed(1)}L'
        : amount >= 1000
        ? '${(amount / 1000).toStringAsFixed(1)}k'
        : amount.toStringAsFixed(0);
    return bills ? text : '₹$text';
  }

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(54, 8, size.width - 16, size.height - 30);
    if (plot.width <= 0 || rows.isEmpty) return;
    final values = rows
        .map((r) => number(r[bills ? 'bills' : 'revenue_minor']).toDouble())
        .toList();
    final peak = values.fold<double>(0, math.max);
    final top = peak == 0
        ? (bills ? 4.0 : 40000.0)
        : (bills ? math.max(4.0, (peak / 4).ceil() * 4.0) : peak * 1.15);
    final grid = Paint()
      ..color = const Color(0xFFE7EAF0)
      ..strokeWidth = 1;
    for (var tick = 0; tick <= 4; tick++) {
      final y = plot.bottom - plot.height * tick / 4;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      label(canvas, axis(top * tick / 4), Offset(0, y - 6));
    }
    final points = [
      for (var i = 0; i < rows.length; i++)
        Offset(
          rows.length == 1
              ? plot.center.dx
              : plot.left + plot.width * i / (rows.length - 1),
          plot.bottom - plot.height * values[i] / top,
        ),
    ];
    if (bars) {
      final width = math.min(28.0, plot.width / rows.length * 0.6);
      for (var i = 0; i < points.length; i++) {
        final rect = Rect.fromLTRB(
          points[i].dx - width / 2,
          points[i].dy,
          points[i].dx + width / 2,
          plot.bottom,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(3)),
          Paint()
            ..color = i == selected ? accent : accent.withValues(alpha: 0.55),
        );
      }
    } else {
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      final area = Path.from(path)
        ..lineTo(points.last.dx, plot.bottom)
        ..lineTo(points.first.dx, plot.bottom)
        ..close();
      canvas.drawPath(
        area,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x334F46E5), Color(0x034F46E5)],
          ).createShader(plot),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
      if (points.length <= 31) {
        for (final point in points) {
          canvas.drawCircle(point, 2.5, Paint()..color = accent);
        }
      }
    }
    final current = points[selected.clamp(0, points.length - 1)];
    canvas.drawLine(
      Offset(current.dx, plot.top),
      Offset(current.dx, plot.bottom),
      Paint()..color = accent.withValues(alpha: 0.22),
    );
    canvas.drawCircle(current, 5, Paint()..color = accent);
    canvas.drawCircle(current, 2.5, Paint()..color = Colors.white);
    final tickCount = math.min(
      rows.length,
      math.max(2, (plot.width / 65).floor()),
    );
    for (var tick = 0; tick < tickCount; tick++) {
      final index = tickCount == 1
          ? 0
          : (tick * (rows.length - 1) / (tickCount - 1)).round();
      final text = '${rows[index][labelKey]}';
      label(
        canvas,
        hourly ? text : chartDate(text),
        Offset(points[index].dx, plot.bottom + 10),
        centered: true,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter oldDelegate) =>
      oldDelegate.rows != rows ||
      oldDelegate.bills != bills ||
      oldDelegate.bars != bars ||
      oldDelegate.selected != selected;
}
