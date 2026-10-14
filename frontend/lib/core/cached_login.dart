import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

// Offline account verification is separate from the optional local app lock.
// Store only a salted, deliberately slow verifier after successful API login.
const cachedLoginRounds = 120000;

List<int> deriveLoginVerifier(Map<String, Object> input) {
  final password = input['password'] as String;
  final salt = input['salt'] as List<int>;
  final rounds = input['rounds'] as int;
  final hmac = Hmac(sha256, utf8.encode(password));
  var block = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
  final result = Uint8List.fromList(block);
  for (var round = 1; round < rounds; round++) {
    block = hmac.convert(block).bytes;
    for (var index = 0; index < result.length; index++) {
      result[index] ^= block[index];
    }
  }
  return result;
}

Future<String> createCachedLogin(String password) async {
  final random = Random.secure();
  final salt = List<int>.generate(16, (_) => random.nextInt(256));
  final verifier = await compute(deriveLoginVerifier, <String, Object>{
    'password': password,
    'salt': salt,
    'rounds': cachedLoginRounds,
  });
  return jsonEncode({
    'version': 1,
    'rounds': cachedLoginRounds,
    'expires_at': DateTime.now()
        .toUtc()
        .add(const Duration(days: 30))
        .toIso8601String(),
    'salt': base64Encode(salt),
    'verifier': base64Encode(verifier),
  });
}

Future<bool> verifyCachedLogin(String encoded, String password) async {
  try {
    final record = jsonDecode(encoded) as Map<String, dynamic>;
    if (record['version'] != 1 || record['rounds'] != cachedLoginRounds) {
      return false;
    }
    final expires = DateTime.tryParse('${record['expires_at'] ?? ''}');
    if (expires == null || !DateTime.now().toUtc().isBefore(expires)) {
      return false;
    }
    final salt = base64Decode(record['salt'] as String);
    final expected = base64Decode(record['verifier'] as String);
    if (salt.length != 16 || expected.length != 32) return false;
    final actual = await compute(deriveLoginVerifier, <String, Object>{
      'password': password,
      'salt': salt,
      'rounds': cachedLoginRounds,
    });
    var difference = 0;
    for (var index = 0; index < expected.length; index++) {
      difference |= expected[index] ^ actual[index];
    }
    return difference == 0;
  } catch (_) {
    return false;
  }
}
