import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/session.dart';
import '../features/shared/field_spec.dart';
import '../features/shared/field_validation.dart';
import 'records_page.dart';
import 'shared.dart';

class EditorField extends StatelessWidget {
  final FieldSpec f;
  final Session session;
  final Json value;
  final Map<String, TextEditingController> controllers;
  final bool busy;
  final void Function(VoidCallback) onChange;
  const EditorField({
    super.key,
    required this.f,
    required this.session,
    required this.value,
    required this.controllers,
    required this.busy,
    required this.onChange,
  });
  @override
  Widget build(BuildContext context) {
    if (f.kind == 'bool') {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(f.label),
        value: enabled(value[f.key]),
        onChanged: busy ? null : (v) => onChange(() => value[f.key] = v),
      );
    }
    if (f.options != null) {
      final options = [...f.options!];
      final current = '${value[f.key] ?? ''}';
      // Existing records created before a field was simplified must remain
      // editable; show their legacy value instead of failing the dropdown.
      if (current.isNotEmpty && !options.contains(current)) {
        options.add(current);
      }
      return DropdownButtonFormField<String>(
        initialValue: value[f.key],
        decoration: InputDecoration(labelText: f.label),
        items: options
            .map(
              (v) => DropdownMenuItem(
                value: v,
                child: Text(v.replaceAll('_', ' ')),
              ),
            )
            .toList(),
        onChanged: busy ? null : (v) => onChange(() => value[f.key] = v),
      );
    }
    if (['staff', 'banks'].contains(f.kind)) {
      return FormField<String>(
        validator: (_) => validateField(f, null, value[f.key]),
        builder: (state) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(f.label),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.search),
              label: Text(
                value['${f.key}_label'] ??
                    (value[f.key] != null
                        ? 'Selected · tap to change'
                        : 'Choose ${f.kind}'),
              ),
              onPressed: busy
                  ? null
                  : () async {
                      final selected = await openPage<Json>(
                        context,
                        RecordsPage(session, f.kind, picker: true),
                      );
                      if (selected != null) {
                        onChange(() {
                          value[f.key] = selected['id'];
                          value['${f.key}_label'] = recordTitle(
                            f.kind,
                            selected,
                          );
                        });
                      }
                    },
            ),
            if (!f.required && value[f.key] != null)
              TextButton(
                onPressed: busy
                    ? null
                    : () => onChange(() => value[f.key] = null),
                child: const Text('Clear selection'),
              ),
            if (state.hasError)
              Text(
                state.errorText!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      );
    }
    return TextFormField(
      controller: controllers[f.key],
      enabled: !busy,
      decoration: InputDecoration(
        labelText: f.label,
        hintText: f.kind == 'date' ? 'YYYY-MM-DD' : null,
      ),
      keyboardType: ['money', 'percent', 'int', 'decimal'].contains(f.kind)
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      validator: (text) => validateField(f, text, value[f.key]),
    );
  }
}
