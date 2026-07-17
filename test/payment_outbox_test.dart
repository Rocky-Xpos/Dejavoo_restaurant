import 'dart:async';
import 'dart:convert';

import 'package:dejavoo_restaurant/src/client.dart';
import 'package:dejavoo_restaurant/src/services/payment_outbox.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fake register link: scripted replies, records every call, and snapshots
/// whether the outbox had persisted the result at the moment it was sent.
class FakeTransport implements PaymentTransport {
  final SharedPreferences prefs;
  FakeTransport(this.prefs);

  final connectedCtrl = StreamController<bool>.broadcast();
  bool connectedNow = true;

  Map<String, dynamic> sendReply = {
    'type': 'payment_recorded',
    'accepted': true,
  };
  Map<String, dynamic> statusReply = {
    'type': 'payment_status_result',
    'state': 'pending',
  };

  final sentResults = <Map<String, dynamic>>[];
  final persistedWhenSent = <bool>[];
  final statusQueries = <String>[];

  @override
  bool get isConnected => connectedNow;

  @override
  Stream<bool> get connected => connectedCtrl.stream;

  @override
  Future<Map<String, dynamic>> sendPaymentResult(
      Map<String, dynamic> result) async {
    sentResults.add(result);
    persistedWhenSent
        .add(prefs.getString(PaymentResultOutbox.prefsKey) != null);
    return sendReply;
  }

  @override
  Future<Map<String, dynamic>> paymentStatus(String intentId) async {
    statusQueries.add(intentId);
    return statusReply;
  }
}

Map<String, dynamic> sampleResult() => {
      'type': 'payment_result',
      'intentId': 'RM9X41K2AB',
      'checkId': 42,
      'status': 'success',
      'statusCode': '00',
      'authCode': 'OK1234',
      'amount': '32.45',
      'tip': 4.95,
      'message': 'APPROVED',
      'cardData': {
        'cardType': 'VISA',
        'entryType': 'CONTACTLESS',
        'last4': '4242'
      },
      'device': 'dejavoo-terminal',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(PaymentResultOutbox, FakeTransport, SharedPreferences)> rig(
      {Map<String, Object>? initial}) async {
    SharedPreferences.setMockInitialValues(initial ?? {});
    final prefs = await SharedPreferences.getInstance();
    final client = FakeTransport(prefs);
    final outbox = PaymentResultOutbox(prefs: prefs, client: client);
    return (outbox, client, prefs);
  }

  test('send persists BEFORE sending and clears on payment_recorded', () async {
    final (outbox, client, prefs) = await rig();
    final reply = await outbox.send(sampleResult());
    expect(client.sentResults, [sampleResult()]);
    expect(client.persistedWhenSent, [true],
        reason: 'the result must be on disk before it goes on the wire');
    expect(reply['type'], 'payment_recorded');
    expect(prefs.getString(PaymentResultOutbox.prefsKey), isNull,
        reason: 'the ack clears the stored copy');
    expect(outbox.hasPending, isFalse);
  });

  test('send keeps the stored copy when the register does not ack', () async {
    final (outbox, client, prefs) = await rig();
    client.sendReply = {'type': 'error', 'message': 'Disconnected'};
    final reply = await outbox.send(sampleResult());
    expect(reply['type'], 'error');
    expect(prefs.getString(PaymentResultOutbox.prefsKey),
        jsonEncode(sampleResult()),
        reason: 'no ack, no clear — recovery re-sends it later');
    expect(outbox.hasPending, isTrue);
  });

  test('recover clears without re-sending when state is recorded', () async {
    final (outbox, client, prefs) = await rig(initial: {
      PaymentResultOutbox.prefsKey: jsonEncode(sampleResult()),
    });
    client.statusReply = {
      'type': 'payment_status_result',
      'state': 'recorded',
      'intentId': 'RM9X41K2AB',
    };
    await outbox.recover();
    expect(client.statusQueries, ['RM9X41K2AB']);
    expect(client.sentResults, isEmpty,
        reason: 'already recorded — re-sending would be noise');
    expect(prefs.getString(PaymentResultOutbox.prefsKey), isNull);
  });

  test('recover clears without re-sending when state is rejected', () async {
    final (outbox, client, prefs) = await rig(initial: {
      PaymentResultOutbox.prefsKey: jsonEncode(sampleResult()),
    });
    client.statusReply = {
      'type': 'payment_status_result',
      'state': 'rejected',
    };
    await outbox.recover();
    expect(client.sentResults, isEmpty);
    expect(prefs.getString(PaymentResultOutbox.prefsKey), isNull);
  });

  test('recover re-sends on pending and clears once acked', () async {
    final (outbox, client, prefs) = await rig(initial: {
      PaymentResultOutbox.prefsKey: jsonEncode(sampleResult()),
    });
    client.statusReply = {
      'type': 'payment_status_result',
      'state': 'pending',
    };
    await outbox.recover();
    expect(client.statusQueries, ['RM9X41K2AB']);
    expect(client.sentResults, [sampleResult()],
        reason: 'pending means the register never saw the result');
    expect(prefs.getString(PaymentResultOutbox.prefsKey), isNull);
  });

  test('recover re-sends on unknown state', () async {
    final (outbox, client, _) = await rig(initial: {
      PaymentResultOutbox.prefsKey: jsonEncode(sampleResult()),
    });
    client.statusReply = {
      'type': 'payment_status_result',
      'state': 'unknown',
    };
    await outbox.recover();
    expect(client.sentResults, [sampleResult()]);
  });

  test('recover treats a status timeout/error as unknown and re-sends;'
      ' stored copy survives an unacked re-send', () async {
    final (outbox, client, prefs) = await rig(initial: {
      PaymentResultOutbox.prefsKey: jsonEncode(sampleResult()),
    });
    client.statusReply = {'type': 'error', 'message': 'timed out'};
    client.sendReply = {'type': 'error', 'message': 'still offline'};
    await outbox.recover();
    expect(client.sentResults, [sampleResult()]);
    expect(prefs.getString(PaymentResultOutbox.prefsKey),
        jsonEncode(sampleResult()),
        reason: 'still unacked — must survive for the next attempt');

    // Next recover, register back: acked and cleared.
    client.statusReply = {
      'type': 'payment_status_result',
      'state': 'pending',
    };
    client.sendReply = {'type': 'payment_recorded', 'accepted': true};
    await outbox.recover();
    expect(client.sentResults.length, 2);
    expect(prefs.getString(PaymentResultOutbox.prefsKey), isNull);
  });

  test('recover is a no-op when nothing is stored', () async {
    final (outbox, client, _) = await rig();
    await outbox.recover();
    expect(client.statusQueries, isEmpty);
    expect(client.sentResults, isEmpty);
  });

  test('recover drops an unreadable stored blob instead of looping', () async {
    final (outbox, client, prefs) = await rig(initial: {
      PaymentResultOutbox.prefsKey: 'not json{',
    });
    await outbox.recover();
    expect(client.statusQueries, isEmpty);
    expect(client.sentResults, isEmpty);
    expect(prefs.getString(PaymentResultOutbox.prefsKey), isNull);
  });
}
