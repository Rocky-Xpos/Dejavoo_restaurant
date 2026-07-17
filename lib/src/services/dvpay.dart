import 'dart:async';

import 'package:flutter/services.dart';

/// Outcome of one DvPayLite transaction, relayed by the native side of the
/// `xpos/dvpay` MethodChannel (MainActivity.kt + the ported
/// ResultClassifier.kt). All fields come across as strings — amounts stay the
/// decimal strings DvPayLite echoed, never re-parsed doubles.
class DvPayResult {
  /// ResultClassifier kind: SUCCESS | UNMATCHED_RESULT | AMOUNT_MISMATCH |
  /// FAILED.
  final String kind;

  /// success | amount_mismatch | unmatched_result | failed | not_found.
  final String status;

  /// DvPayLite respCode ('00' = approved) or a transport-level code
  /// (LAUNCH_FAILED, TIMEOUT, BUSY, NO_CHANNEL, ...).
  final String statusCode;
  final String authCode;
  final String last4;

  /// Approved amount as the decimal string DvPayLite echoed (may be empty —
  /// the classifier does not treat an absent echo as a mismatch).
  final String amount;

  /// The refId this result actually belongs to. Equals [launched] except for
  /// unmatched (one-behind) results, where it names the TRUE owner.
  final String resolvedRefId;
  final String message;
  final String cardType;
  final String entryType;

  /// The refId this launch was started with.
  final String launched;

  const DvPayResult({
    required this.kind,
    required this.status,
    required this.statusCode,
    required this.authCode,
    required this.last4,
    required this.amount,
    required this.resolvedRefId,
    required this.message,
    required this.cardType,
    required this.entryType,
    required this.launched,
  });

  /// Approved, matched to this launch, amount verified.
  bool get isApproved => status == 'success';

  factory DvPayResult.fromMap(Map<Object?, Object?> map) {
    String s(String key) => '${map[key] ?? ''}';
    return DvPayResult(
      kind: s('kind'),
      status: s('status'),
      statusCode: s('statusCode'),
      authCode: s('authCode'),
      last4: s('last4'),
      amount: s('amount'),
      resolvedRefId: s('resolvedRefId'),
      message: s('message'),
      cardType: s('cardType'),
      entryType: s('entryType'),
      launched: s('launched'),
    );
  }

  /// A result manufactured on the Dart side when the native call itself
  /// failed (timeout, BUSY, missing channel) — never a proven approval.
  factory DvPayResult.local({
    required String status,
    required String statusCode,
    required String message,
    required String refId,
  }) {
    return DvPayResult(
      kind: 'FAILED',
      status: status,
      statusCode: statusCode,
      authCode: '',
      last4: '',
      amount: '',
      resolvedRefId: refId,
      message: message,
      cardType: '',
      entryType: '',
      launched: refId,
    );
  }
}

/// Dart face of the `xpos/dvpay` MethodChannel. The native side serializes
/// launches (one transaction in flight at a time) — a second call while busy
/// surfaces here as a failed result with statusCode 'BUSY'.
class DvPay {
  DvPay._();

  static const MethodChannel channel = MethodChannel('xpos/dvpay');

  /// Protocol budget waiting for DvPayLite; afterwards the flow surfaces
  /// "verify on terminal" and offers the STATUS reconcile by refId.
  static const Duration budget = Duration(seconds: 90);

  /// SALE of [amount] (+[tip] when > 0), refId = the payment intentId.
  static Future<DvPayResult> sale(
      {required double amount, double tip = 0, required String refId}) {
    return _invoke('sale', {'amount': amount, 'tip': tip, 'refId': refId},
        refId, failStatus: 'failed');
  }

  /// VOID of a prior sale by its original refId (= intentId).
  static Future<DvPayResult> voidTxn(
      {required double amount, required String refId}) {
    return _invoke(
        'voidTxn', {'amount': amount, 'refId': refId}, refId,
        failStatus: 'failed');
  }

  /// Read-only STATUS reconcile: 'success' only on the triple gate
  /// (respCode 00 + authCode + last4), otherwise 'not_found'.
  static Future<DvPayResult> status({required String refId}) {
    return _invoke('status', {'refId': refId}, refId, failStatus: 'not_found');
  }

  static Future<DvPayResult> _invoke(
    String method,
    Map<String, dynamic> args,
    String refId, {
    required String failStatus,
  }) async {
    try {
      final res =
          await channel.invokeMethod<dynamic>(method, args).timeout(budget);
      if (res is Map) return DvPayResult.fromMap(res);
      return DvPayResult.local(
          status: failStatus,
          statusCode: 'NO_RESULT',
          message: 'DvPayLite returned no result',
          refId: refId);
    } on TimeoutException {
      return DvPayResult.local(
          status: failStatus,
          statusCode: 'TIMEOUT',
          message:
              'No result from DvPayLite in ${budget.inSeconds}s - verify on the terminal',
          refId: refId);
    } on PlatformException catch (e) {
      return DvPayResult.local(
          status: failStatus,
          statusCode: e.code,
          message: e.message ?? 'DvPayLite error',
          refId: refId);
    } on MissingPluginException {
      return DvPayResult.local(
          status: failStatus,
          statusCode: 'NO_CHANNEL',
          message: 'Payment channel unavailable on this device',
          refId: refId);
    }
  }
}
