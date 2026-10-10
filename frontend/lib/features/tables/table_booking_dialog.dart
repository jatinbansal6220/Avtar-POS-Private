import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';

Future<void> openTableBookingDialog(
  BuildContext context,
  Session session,
  Json table,
) async {
  final now = indiaNow();
  DateTime start = DateTime.utc(now.year, now.month, now.day, now.hour + 1);
  DateTime end = start.add(const Duration(hours: 1));
  final name = TextEditingController();
  final phone = TextEditingController();
  String? error;
  bool saving = false;

  Future<DateTime?> choose(BuildContext dialogContext, DateTime value) async {
    final date = await showDatePicker(
      context: dialogContext,
      initialDate: value,
      firstDate: DateTime.utc(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !dialogContext.mounted) return null;
    final time = await showTimePicker(
      context: dialogContext,
      initialTime: TimeOfDay.fromDateTime(value),
    );
    if (time == null) return null;
    return DateTime.utc(date.year, date.month, date.day, time.hour, time.minute);
  }

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) {
        String label(DateTime value) {
          final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
          return value.day.toString().padLeft(2, '0') +
              '/' +
              value.month.toString().padLeft(2, '0') +
              '/' +
              value.year.toString() +
              '  ' +
              hour.toString() +
              ':' +
              value.minute.toString().padLeft(2, '0') +
              (value.hour >= 12 ? ' PM' : ' AM');
        }

        Future<void> save() async {
          if (!end.isAfter(start)) {
            setDialogState(() => error = 'End time must be after start time.');
            return;
          }
          if (start.isBefore(now)) {
            setDialogState(() => error = 'Choose a future booking time.');
            return;
          }
          setDialogState(() {
            saving = true;
            error = null;
          });
          final clash = await session.local!.bookingConflict(
            table['id'].toString(),
            start,
            end,
          );
          if (clash != null) {
            final guest = (clash['customer_name'] ?? 'another customer')
                .toString();
            setDialogState(() {
              saving = false;
              error =
                  'This table is already booked for this time by ' +
                  guest +
                  '.';
            });
            return;
          }
          try {
            await session.mutate('table_bookings', {
              'table_id': table['id'],
              'table_number': table['table_number'],
              'start_at': indiaTimestamp(start),
              'end_at': indiaTimestamp(end),
              'customer_name': name.text.trim().isEmpty
                  ? null
                  : name.text.trim(),
              'customer_phone': phone.text.trim().isEmpty
                  ? null
                  : phone.text.trim(),
            });
            if (dialogContext.mounted) Navigator.pop(dialogContext);
          } catch (exception) {
            if (dialogContext.mounted)
              setDialogState(() {
                saving = false;
                error = exception.toString();
              });
          }
        }

        return AlertDialog(
          title: Text('Book table ' + table['table_number'].toString()),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Booking starts'),
                    subtitle: Text(label(start)),
                    trailing: const Icon(Icons.schedule),
                    onTap: saving
                        ? null
                        : () async {
                            final chosen = await choose(dialogContext, start);
                            if (chosen != null)
                              setDialogState(() => start = chosen);
                          },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Booking ends'),
                    subtitle: Text(label(end)),
                    trailing: const Icon(Icons.schedule),
                    onTap: saving
                        ? null
                        : () async {
                            final chosen = await choose(dialogContext, end);
                            if (chosen != null)
                              setDialogState(() => end = chosen);
                          },
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: name,
                    enabled: !saving,
                    decoration: const InputDecoration(
                      labelText: 'Customer name (optional)',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: phone,
                    enabled: !saving,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Mobile number (optional)',
                    ),
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
              onPressed: saving ? null : () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: saving ? null : save,
              child: Text(saving ? 'Saving...' : 'Save booking'),
            ),
          ],
        );
      },
    ),
  );
  // Wait for the dialog exit animation before releasing its TextFields.
  await Future<void>.delayed(const Duration(milliseconds: 350));
  name.dispose();
  phone.dispose();
}

Future<void> openTableBookingDetails(
  BuildContext context,
  List<Json> bookings,
  String tableNumber,
) async {
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Bookings · Table ' + tableNumber),
      content: SizedBox(
        width: 380,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: bookings.length,
          itemBuilder: (context, index) {
            final booking = bookings[index];
            final start = indiaDateTime(booking['start_at']);
            final end = indiaDateTime(booking['end_at']);
            String clock(DateTime? value) => value == null
                ? ''
                : (value.hour % 12 == 0 ? 12 : value.hour % 12).toString() +
                      ':' +
                      value.minute.toString().padLeft(2, '0') +
                      (value.hour >= 12 ? ' PM' : ' AM');
            return ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                clock(start) + ' – ' + clock(end),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                (booking['customer_name'] ?? 'No customer name').toString() +
                    (booking['customer_phone'] == null
                        ? ''
                        : ' · ' + booking['customer_phone'].toString()),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
