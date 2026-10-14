part of 'session.dart';

extension SessionApi on Session {
  Future<Json> request(
    String method,
    String path, {
    Json? body,
    String? key,
  }) async {
    if (demoMode) {
      return _offlineResponse(method, path, body);
    }
    final accountIdentity = '$base/${user?['id']}';
    final req = http.Request(method, Uri.parse('$base/$path'));
    req.headers.addAll({
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      'Idempotency-Key': ?key,
    });
    if (body != null) req.body = jsonEncode(body);
    final response = await http.Response.fromStream(
      await client.send(req).timeout(const Duration(seconds: 12)),
    ).timeout(const Duration(seconds: 12));
    Json data;
    try {
      data = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    } catch (_) {
      // InfinityFree's free tier may return its browser-only aes.js challenge
      // instead of JSON. The configured API URL is valid in that case, but a
      // native Flutter client cannot complete the JavaScript-only challenge.
      final isBrowserOnlyChallenge =
          response.body.contains('/aes.js') ||
          response.body.contains('This site requires Javascript to work');
      throw ApiFailure(
        response.statusCode,
        isBrowserOnlyChallenge
            ? 'The current server blocks desktop/mobile API requests. Move the API to an API-capable host, then try again.'
            : 'The server returned an invalid response. Check the API address.',
      );
    }
    // A valid JSON response (including a validation error) proves that this
    // terminal can reach the live API. Do not leave the whole POS labelled
    // Offline merely because a later background refresh is slow.
    if (accountIdentity != '$base/${user?['id']}') {
      throw ApiFailure(409, 'Account changed. Please retry this action.');
    }
    if (!online || syncError != null) {
      online = true;
      syncError = null;
      changed();
    }
    if (response.statusCode >= 400) {
      final errors = data['errors'];
      final message = errors is Map && errors.isNotEmpty
          ? (errors.values.first as List).first.toString()
          : data['message']?.toString() ??
                'Request failed (${response.statusCode}).';
      throw ApiFailure(response.statusCode, message);
    }
    return data;
  }

  Future<Json> _offlineResponse(String method, String path, Json? body) async {
    if (path == 'sync/cursor') return {'cursor': 0};
    if (path.startsWith('updates')) {
      return {'changes': <Json>[], 'next_cursor': 0, 'has_more': false};
    }
    final uri = Uri.parse(path);
    if (method == 'GET') {
      if (uri.path == 'analytics')
        return LocalReports(local!).analytics(
          uri.queryParameters['from'] ?? day(indiaNow()),
          uri.queryParameters['to'] ?? day(indiaNow()),
        );
      final parts = uri.pathSegments;
      if (parts.length == 2)
        return await local!.get(parts.first, parts.last) ?? {};
      final rows = await local!.list(
        parts.first,
        query: uri.queryParameters['q'] ?? '',
        filters: uri.queryParameters,
        limit: int.tryParse(uri.queryParameters['limit'] ?? '') ?? 100,
      );
      return {'data': rows, 'next_cursor': null};
    }
    // Demo mode has no fake server acknowledgments. Mutations use the same
    // durable local services as real mode; sync simply remains disabled.
    throw ApiFailure(405, 'Use the local save service for demo changes.');
  }
}
