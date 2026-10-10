part of 'session.dart';

extension SessionControls on Session {
  String orderFeature(Json order) => switch (order['order_type']) {
    'dine_in' => 'tables',
    'online' => 'online_orders',
    'takeaway' => 'takeaway',
    _ => 'pos',
  };
  void requireOrderAccess(Json order) {
    requireFeature(orderFeature(order));
  }

  void validateControlledPayment(Json payment) {
    final method = '${payment['payment_method'] ?? 'cash'}';
    if (method == 'mixed') requireFeature('mixed_payment');
    final tenders = [
      method,
      ...maps(payment['payments'])
          .where((row) => number(row['amount_minor']) > 0)
          .map((row) => '${row['method']}'),
    ];
    if (tenders.contains('upi')) requireFeature('upi');
    if (tenders.any((method) => ['card', 'online'].contains(method))) {
      requireFeature('card');
    }
    if (number(payment['discount_value']) > 0 ||
        number(payment['discount_basis_points']) > 0) {
      requireFeature('discounts');
    }
  }

  String get _controlCacheKey => 'feature_policy_v1_${base}_${user?['id']}';
  String get _demoControlKey => 'demo_controls_v1_${user?['id']}';

  Json _demoControlSnapshot() {
    final cached = Session.prefs.getString(_demoControlKey);
    if (cached != null) {
      try {
        final parsed = jsonDecode(cached) as Json;
        if (validPolicy(parsed['policy']) && parsed['revision'] is int) {
          return parsed;
        }
      } catch (_) {}
    }
    return {
      'scope': 'global',
      'revision': 0,
      'policy': {
        'app_enabled': true,
        'message': 'Local demo access is paused by the developer.',
        'features': {for (final key in developerFeatures.keys) key: true},
      },
    };
  }

  Future<Json> unlockDeveloper(String password) async {
    if (!demoMode) {
      return request('POST', 'developer/unlock', body: {'password': password});
    }
    const expected = String.fromEnvironment('DEMO_DEVELOPER_PASSWORD_HASH');
    if (expected.isEmpty || token != 'demo-token' || user == null) {
      throw ApiFailure(503, 'Developer access is not configured for this demo.');
    }
    if (sha256.convert(utf8.encode(password)).toString() != expected) {
      throw ApiFailure(403, 'Developer password is incorrect.');
    }
    demoDeveloperGrant = Session.uuid.v4();
    demoDeveloperGrantExpires = DateTime.now().add(const Duration(minutes: 10));
    demoDeveloperIdentity = '$token|${user!['id']}';
    return {'developer_token': demoDeveloperGrant};
  }

  Future<void> startControlPolicy() async {
    controlTimer?.cancel();
    controlPolicy = {};
    updater.setPolicyEnabled(true);
    if (demoMode) {
      if (user != null) {
        controlPolicy = Map<String, dynamic>.from(_demoControlSnapshot()['policy']);
      }
      return;
    }
    if (user == null) return;
    try {
      final cached = Session.prefs.getString(_controlCacheKey);
      if (cached != null) {
        final parsed = jsonDecode(cached);
        if (validPolicy(parsed)) {
          controlPolicy = Map<String, dynamic>.from(parsed as Map);
        }
      }
    } catch (_) {
      /* An invalid cache never changes business data. */
    }
    updater.setPolicyEnabled(policyAllows('updates'));
    unawaited(refreshControlPolicy());
    controlTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(refreshControlPolicy());
    });
  }

  Future<void> refreshControlPolicy() async {
    if (demoMode && user != null) {
      controlPolicy = Map<String, dynamic>.from(_demoControlSnapshot()['policy']);
      dataChanged(['control_policy']);
      changed();
      return;
    }
    if (demoMode || user == null || token.isEmpty || _controlFetching) return;
    _controlFetching = true;
    final identity = '$base|$token|${user?['id']}';
    try {
      final result = await request('GET', 'control-policy');
      if (identity != '$base|$token|${user?['id']}') return;
      final policy = result['policy'];
      if (!validPolicy(policy)) {
        throw const FormatException('Invalid feature policy.');
      }
      final previousSync = policyAllows('sync');
      final next = Map<String, dynamic>.from(policy);
      final didChange = jsonEncode(controlPolicy) != jsonEncode(next);
      controlPolicy = next;
      updater.setPolicyEnabled(policyAllows('updates'));
      // Only operational booleans/message are cached. Passwords and developer
      // grants never go to preferences, SQLite, logs or the outbox.
      await Session.prefs.setString(_controlCacheKey, jsonEncode(next));
      if (didChange) {
        dataChanged(['control_policy']);
        changed();
      }
      if (!previousSync && policyAllows('sync')) requestImmediateSync();
    } catch (_) {
      // Retain the last accepted policy offline and with older API versions.
    } finally {
      _controlFetching = false;
    }
  }

  Future<Json> developerRequest(
    String method,
    String path, {
    required String grant,
    Json? body,
  }) async {
    if (demoMode) {
      if (grant != demoDeveloperGrant || demoDeveloperGrantExpires == null ||
          !DateTime.now().isBefore(demoDeveloperGrantExpires!) ||
          demoDeveloperIdentity != '$token|${user?['id']}' || token != 'demo-token') {
        throw ApiFailure(403, 'Developer access expired. Verify again.');
      }
      final snapshot = _demoControlSnapshot();
      if (method == 'GET' && path == 'developer/controls') {
        return {'global': snapshot, 'tenants': <Json>[]};
      }
      if (method == 'PUT' && path == 'developer/controls/global') {
        if (body?['revision'] != snapshot['revision']) {
          throw ApiFailure(409, 'Controls changed. Reload before saving.');
        }
        if (!validPolicy(body?['policy']) ||
            !(body!['policy']['features'] as Map).keys.every(developerFeatures.containsKey)) {
          throw ApiFailure(422, 'Invalid developer controls.');
        }
        final next = {'scope': 'global', 'revision': (snapshot['revision'] as int) + 1,
          'policy': clone(body['policy'] as Json)};
        await Session.prefs.setString(_demoControlKey, jsonEncode(next));
        return {'revision': next['revision']};
      }
      throw ApiFailure(404, 'This demo only controls this local browser.');
    }
    final req = http.Request(method, Uri.parse('$base/$path'));
    req.headers.addAll({
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
      'X-Developer-Token': grant,
    });
    if (body != null) req.body = jsonEncode(body);
    final response = await http.Response.fromStream(
      await client.send(req).timeout(const Duration(seconds: 12)),
    ).timeout(const Duration(seconds: 12));
    Json result;
    try {
      result = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    } catch (_) {
      throw ApiFailure(
        response.statusCode,
        'Developer controls are not available on this server.',
      );
    }
    if (response.statusCode >= 400) {
      throw ApiFailure(
        response.statusCode,
        '${result['message'] ?? 'Developer request failed.'}',
      );
    }
    return result;
  }
}
