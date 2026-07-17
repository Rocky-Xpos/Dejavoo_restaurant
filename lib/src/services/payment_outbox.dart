import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../client.dart';

/// Persist-then-send delivery of `payment_result` messages to the register.
///
/// An approval can never be lost: the outgoing message is stored in
/// SharedPreferences BEFORE it is sent and only cleared once the register
/// acks it with `payment_recorded`. On reconnect (or app restart) with a
/// stored, unacked result the outbox first asks `payment_status`; if the
/// register says recorded/rejected the stored copy is cleared, and on
/// pending/unknown (or no answer) the stored result is re-sent — repeatedly,
/// until acked.
///
/// Depends only on [PaymentTransport] (+ [SharedPreferences]) so it is
/// unit-testable with fakes.
class PaymentResultOutbox {
  static const String prefsKey = 'pending_payment_result';

  final SharedPreferences prefs;
  final PaymentTransport client;

  /// How often [start] retries a stored result while connected.
  final Duration retryInterval;

  StreamSubscription<bool>? _connSub;
  Timer? _retryTimer;
  bool _recovering = false;

  PaymentResultOutbox({
    required this.prefs,
    required this.client,
    this.retryInterval = const Duration(seconds: 20),
  });

  /// True when a payment_result is stored and still unacked.
  bool get hasPending => prefs.getString(prefsKey) != null;

  /// Wires recovery to the client lifecycle: run once now (app start) and on
  /// every reconnect, plus a slow retry tick while something is pending.
  void start() {
    _connSub = client.connected.listen((up) {
      if (up) recover();
    });
    _retryTimer = Timer.periodic(retryInterval, (_) {
      if (hasPending && client.isConnected) recover();
    });
    if (client.isConnected) recover();
  }

  /// Persists [result] BEFORE sending, sends it, and clears the stored copy
  /// only when the register replies `payment_recorded` (accepted or not —
  /// the register has judged it either way). Returns the register's reply
  /// (an {'type':'error'} map when unreachable — the stored copy is kept and
  /// recovery takes over).
  Future<Map<String, dynamic>> send(Map<String, dynamic> result) async {
    await prefs.setString(prefsKey, jsonEncode(result));
    final reply = await client.sendPaymentResult(result);
    if (reply['type'] == 'payment_recorded') {
      await prefs.remove(prefsKey);
    }
    return reply;
  }

  /// "Did my result land?" — asks the register before re-sending, so a
  /// Wi-Fi drop between approval and ack never double-reports or loses a
  /// payment. Safe to call at any time; no-ops when nothing is stored.
  Future<void> recover() async {
    if (_recovering) return;
    _recovering = true;
    try {
      final raw = prefs.getString(prefsKey);
      if (raw == null) return;
      Map<String, dynamic> stored;
      try {
        stored = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      } catch (_) {
        await prefs.remove(prefsKey); // unreadable — nothing we can re-send
        return;
      }
      final intentId = '${stored['intentId'] ?? ''}';
      if (intentId.isEmpty) {
        await prefs.remove(prefsKey);
        return;
      }
      final status = await client.paymentStatus(intentId);
      final state = status['type'] == 'payment_status_result'
          ? '${status['state'] ?? 'unknown'}'
          : 'unknown';
      if (state == 'recorded' || state == 'rejected') {
        // The register already has it — done.
        await prefs.remove(prefsKey);
        return;
      }
      // pending / unknown / register unreachable: re-send. The stored copy
      // survives until a payment_recorded ack clears it.
      final reply = await client.sendPaymentResult(stored);
      if (reply['type'] == 'payment_recorded') {
        await prefs.remove(prefsKey);
      }
    } finally {
      _recovering = false;
    }
  }

  void dispose() {
    _connSub?.cancel();
    _retryTimer?.cancel();
  }
}
