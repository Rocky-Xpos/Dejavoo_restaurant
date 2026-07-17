import 'package:dejavoo_restaurant/src/screens/pay_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('preset tip percentages compute on amountDue, rounded to cents', () {
    expect(tipForPercent(27.50, 18), 4.95);
    expect(tipForPercent(27.50, 20), 5.50);
    expect(tipForPercent(27.50, 25), 6.88); // 6.875 rounds half up
    expect(tipForPercent(19.99, 20), 4.00); // 3.998 -> 4.00
    expect(tipForPercent(33.33, 20), 6.67); // 6.666 -> 6.67
    expect(tipForPercent(10.05, 18), 1.81); // 1.809 -> 1.81
    expect(tipForPercent(0, 25), 0);
  });

  test('float noise cannot leak into tip cents', () {
    // 0.1 + 0.2 style artifacts stay two-decimal after rounding.
    expect(round2(0.1 + 0.2), 0.3);
    expect(round2(27.50 + 4.95), 32.45);
    for (var cents = 1; cents <= 2000; cents++) {
      final due = cents / 100;
      final tip = tipForPercent(due, 18);
      expect((tip * 100).roundToDouble() / 100, tip,
          reason: 'tip for \$$due is not a whole cent amount');
    }
  });

  test('custom keypad digits read as cents', () {
    expect(keypadTip(''), 0);
    expect(keypadTip('5'), 0.05);
    expect(keypadTip('50'), 0.50);
    expect(keypadTip('450'), 4.50);
    expect(keypadTip('1234'), 12.34);
    expect(keypadTip('007'), 0.07); // leading zeros are harmless
    expect(keypadTip('x'), 0); // non-digits never crash the sheet
  });
}
