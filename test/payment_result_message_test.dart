import 'dart:convert';

import 'package:dejavoo_restaurant/src/screens/pay_screen.dart';
import 'package:dejavoo_restaurant/src/services/dvpay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('payment_result matches the protocol shape exactly (golden)', () {
    final r = DvPayResult.fromMap({
      'kind': 'SUCCESS',
      'status': 'success',
      'statusCode': '00',
      'authCode': 'OK1234',
      'last4': '4242',
      'amount': '32.45',
      'resolvedRefId': 'RM9X41K2AB',
      'message': 'APPROVED',
      'cardType': 'VISA',
      'entryType': 'CONTACTLESS',
      'launched': 'RM9X41K2AB',
    });
    final msg = buildPaymentResult(
      intentId: 'RM9X41K2AB',
      checkId: 42,
      result: r,
      amountDue: 27.50,
      tip: 4.95,
      device: 'dejavoo-terminal',
    );
    expect(msg, {
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
        'last4': '4242',
      },
      'device': 'dejavoo-terminal',
    });
    // Wire-safe: encodes without loss.
    expect(jsonDecode(jsonEncode(msg)), msg);
  });

  test('approved result without an amount echo falls back to amount+tip', () {
    final r = DvPayResult.fromMap({
      'kind': 'SUCCESS',
      'status': 'success',
      'statusCode': '00',
      'authCode': 'OK1234',
      'last4': '4242',
      'amount': '', // DvPayLite omitted totalAmount; classifier ruled it match
      'resolvedRefId': 'R1',
      'launched': 'R1',
    });
    final msg = buildPaymentResult(
        intentId: 'R1',
        checkId: 7,
        result: r,
        amountDue: 27.50,
        tip: 4.95,
        device: 'd');
    expect(msg['amount'], '32.45');
  });

  test('failed result keeps an empty amount (nothing was approved)', () {
    final r = DvPayResult.fromMap({
      'kind': 'FAILED',
      'status': 'failed',
      'statusCode': '05',
      'message': 'DECLINED',
      'resolvedRefId': 'R1',
      'launched': 'R1',
    });
    final msg = buildPaymentResult(
        intentId: 'R1',
        checkId: 7,
        result: r,
        amountDue: 27.50,
        tip: 0,
        device: 'd');
    expect(msg['status'], 'failed');
    expect(msg['statusCode'], '05');
    expect(msg['amount'], '');
    expect(msg['tip'], 0);
    expect(msg['cardData'], {'cardType': '', 'entryType': '', 'last4': ''});
  });

  test('unmatched result is tagged with its TRUE owner refId', () {
    final r = DvPayResult.fromMap({
      'kind': 'UNMATCHED_RESULT',
      'status': 'unmatched_result',
      'statusCode': '00',
      'authCode': 'ZZ9',
      'last4': '1111',
      'amount': '15.00',
      'resolvedRefId': 'ROLDER00', // the one-behind sale this belongs to
      'launched': 'RCURRENT',
    });
    final msg = buildPaymentResult(
        intentId: 'RCURRENT',
        checkId: 9,
        result: r,
        amountDue: 27.50,
        tip: 0,
        device: 'd');
    expect(msg['intentId'], 'ROLDER00',
        reason: 'protocol: unmatched results carry their true owner refId');
    expect(msg['status'], 'unmatched_result');
    expect(msg['amount'], '15.00');
  });
}
