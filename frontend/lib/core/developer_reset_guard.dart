import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

// Stored as a SHA-256 digest rather than the usable code. This is an
// additional owner/developer recovery check for reset actions only; it does
// not change normal unlock, Analytics, edit, or invoice-delete flows.
const _developerResetCodeHash =
    '50fd15bf9034a10f0052350ce9a64b96efe9a66bd9153b1a445a2e1a30cda407';

bool _matchesDeveloperResetCode(String value) =>
    sha256.convert(utf8.encode(value.trim())).toString() ==
    _developerResetCodeHash;

Future<bool> requireDeveloperResetCode(BuildContext context) async {
  final code = TextEditingController();
  var invalid = false;
  final allowed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        scrollable: true,
        title: const Text('Developer verification'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: code,
              autofocus: true,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Developer code for reset pass',
                errorText: invalid ? 'Developer code is incorrect.' : null,
              ),
              onSubmitted: (_) {
                if (_matchesDeveloperResetCode(code.text)) {
                  Navigator.pop(dialogContext, true);
                } else {
                  setDialogState(() => invalid = true);
                }
              },
            ),
            const SizedBox(height: 10),
            const Text(
              'If you do not know the code, contact the developer.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () {
              if (_matchesDeveloperResetCode(code.text)) {
                Navigator.pop(dialogContext, true);
              } else {
                setDialogState(() => invalid = true);
              }
            },
            child: const Text('Verify code'),
          ),
        ],
      ),
    ),
  );
  code.dispose();
  return allowed == true;
}
