import 'package:dejavoo_restaurant/src/services/dvpay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DvPayResult parses the full native map', () {
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
    expect(r.kind, 'SUCCESS');
    expect(r.status, 'success');
    expect(r.statusCode, '00');
    expect(r.authCode, 'OK1234');
    expect(r.last4, '4242');
    expect(r.amount, '32.45');
    expect(r.resolvedRefId, 'RM9X41K2AB');
    expect(r.message, 'APPROVED');
    expect(r.cardType, 'VISA');
    expect(r.entryType, 'CONTACTLESS');
    expect(r.launched, 'RM9X41K2AB');
    expect(r.isApproved, isTrue);
  });

  test('DvPayResult tolerates missing keys (empty strings, not approved)', () {
    final r = DvPayResult.fromMap({'status': 'failed'});
    expect(r.status, 'failed');
    expect(r.statusCode, '');
    expect(r.authCode, '');
    expect(r.last4, '');
    expect(r.amount, '');
    expect(r.message, '');
    expect(r.isApproved, isFalse);
  });

  test('only status success counts as approved', () {
    for (final status in [
      'amount_mismatch',
      'unmatched_result',
      'failed',
      'not_found'
    ]) {
      final r = DvPayResult.fromMap({'status': status, 'statusCode': '00'});
      expect(r.isApproved, isFalse, reason: status);
    }
    expect(DvPayResult.fromMap({'status': 'success'}).isApproved, isTrue);
  });

  test('DvPayResult.local is never approved and echoes the refId', () {
    final r = DvPayResult.local(
        status: 'failed',
        statusCode: 'TIMEOUT',
        message: 'no result',
        refId: 'R123');
    expect(r.isApproved, isFalse);
    expect(r.kind, 'FAILED');
    expect(r.statusCode, 'TIMEOUT');
    expect(r.launched, 'R123');
    expect(r.resolvedRefId, 'R123');
  });
}
