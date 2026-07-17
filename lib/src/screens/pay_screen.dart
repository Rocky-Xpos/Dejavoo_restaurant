import 'dart:async';

import 'package:flutter/material.dart';

import '../client.dart';
import '../models.dart';
import '../services/dvpay.dart';
import '../services/payment_outbox.dart';

/// Rounds to cents.
double round2(double v) => (v * 100).roundToDouble() / 100;

/// Tip for a whole-number percentage of [amountDue], rounded to cents.
double tipForPercent(double amountDue, int percent) =>
    round2(amountDue * percent / 100);

/// Value of the custom-tip keypad: the digits typed so far read as cents
/// ('450' -> 4.50, '7' -> 0.07, '' -> 0).
double keypadTip(String digits) => (int.tryParse(digits) ?? 0) / 100;

/// Builds the wire `payment_result` message (protocol verb 2) from a
/// DvPayLite outcome. [amountDue] and [tip] are what this launch asked
/// DvPayLite for.
///
/// intentId carries the result's TRUE owner — the classifier's
/// resolvedRefId, which equals the launched [intentId] except for unmatched
/// (one-behind) results. `amount` stays DvPayLite's approved-amount string;
/// when an approved result omitted the echo (the classifier already ruled it
/// matching) the launched amount+tip fills in so the register's
/// re-verification can still book it.
Map<String, dynamic> buildPaymentResult({
  required String intentId,
  required int checkId,
  required DvPayResult result,
  required double amountDue,
  required double tip,
  required String device,
}) {
  final owner = result.resolvedRefId.isNotEmpty ? result.resolvedRefId : intentId;
  final amount = result.amount.isNotEmpty
      ? result.amount
      : (result.status == 'success'
          ? round2(amountDue + tip).toStringAsFixed(2)
          : '');
  return {
    'type': 'payment_result',
    'intentId': owner,
    'checkId': checkId,
    'status': result.status,
    'statusCode': result.statusCode,
    'authCode': result.authCode,
    'amount': amount,
    'tip': tip,
    'message': result.message,
    'cardData': {
      'cardType': result.cardType,
      'entryType': result.entryType,
      'last4': result.last4,
    },
    'device': device,
  };
}

enum _Phase { pick, charging, recording, success, declined }

/// Full-screen payment collection for one intent: amount-due breakdown, tip
/// picker, DvPayLite SALE, then persist-then-send of the `payment_result`
/// and a green/red outcome screen driven by the register's ack.
class PayScreen extends StatefulWidget {
  final OrderClient client;
  final PaymentResultOutbox outbox;

  /// A payment_intent_ok / collect_payment payload: {intentId, checkId,
  /// checkNo, tableLabel, amountDue, subTotal, tax, total, alreadyPaid}.
  final Map<String, dynamic> intent;

  const PayScreen({
    super.key,
    required this.client,
    required this.outbox,
    required this.intent,
  });

  @override
  State<PayScreen> createState() => _PayScreenState();
}

class _PayScreenState extends State<PayScreen> {
  late Map<String, dynamic> _intent;
  _Phase _phase = _Phase.pick;

  /// 0 = none, 18/20/25 = percent presets, -1 = custom keypad amount.
  int _tipChoice = 0;
  String _customDigits = '';

  String _resultTitle = '';
  String _resultDetail = '';
  bool _offerStatusCheck = false;
  bool _checkingStatus = false;
  String _successDetail = '';
  String _successNote = '';

  /// True once the register recorded ANY result for this intentId — the verb
  /// is idempotent, so a fresh attempt then needs a fresh intent.
  bool _resultRecorded = false;
  Timer? _popTimer;

  String get _intentId => '${_intent['intentId'] ?? ''}';
  int get _checkId => ((_intent['checkId'] as num?) ?? 0).toInt();
  String get _tableLabel => '${_intent['tableLabel'] ?? ''}';
  String get _checkNo => '${_intent['checkNo'] ?? ''}';
  double _money(String key) => ((_intent[key] as num?) ?? 0).toDouble();
  double get _amountDue => _money('amountDue');

  double get _tip => _tipChoice == 0
      ? 0
      : _tipChoice == -1
          ? keypadTip(_customDigits)
          : tipForPercent(_amountDue, _tipChoice);

  double get _chargeTotal => round2(_amountDue + _tip);

  @override
  void initState() {
    super.initState();
    _intent = Map<String, dynamic>.from(widget.intent);
    // The whole time this screen is up a payment is being collected —
    // incoming collect/void pushes get collect_ack accepted:false 'busy'.
    widget.client.busy = true;
  }

  @override
  void dispose() {
    _popTimer?.cancel();
    widget.client.busy = false;
    super.dispose();
  }

  // ------------------------------------------------------------------ flow

  /// Transport-level codes: DvPayLite produced NO transaction result, so
  /// there is nothing to report to the register — offer STATUS reconcile.
  static const Set<String> _transportCodes = {
    'TIMEOUT', 'LAUNCH_FAILED', 'BUSY', 'NO_CHANNEL', 'NO_RESULT', 'BAD_ARGS',
  };

  bool _transportOnly(DvPayResult r) =>
      r.status == 'failed' && _transportCodes.contains(r.statusCode);

  Future<void> _charge() async {
    if (_phase != _Phase.pick) return;
    final tip = round2(_tip);
    setState(() => _phase = _Phase.charging);
    final r = await DvPay.sale(amount: _amountDue, tip: tip, refId: _intentId);
    if (!mounted) return;
    if (_transportOnly(r)) {
      _showDeclined(
        'Payment not completed',
        r.message.isNotEmpty ? r.message : 'DvPayLite gave no result',
        offerStatusCheck: true,
      );
      return;
    }
    await _reportResult(r, tip);
  }

  /// Sends the DvPayLite outcome to the register through the outbox
  /// (persist-then-send) and drives the outcome screens off the ack.
  Future<void> _reportResult(DvPayResult r, double tip) async {
    setState(() => _phase = _Phase.recording);
    final message = buildPaymentResult(
      intentId: _intentId,
      checkId: _checkId,
      result: r,
      amountDue: _amountDue,
      tip: tip,
      device: widget.client.deviceName,
    );
    final reply = await widget.outbox.send(message);
    if (!mounted) return;
    if (reply['type'] == 'payment_recorded') {
      _resultRecorded = true;
      if (reply['accepted'] == true) {
        _showSuccess(r);
      } else {
        _showDeclined(
          r.isApproved ? 'Approved but not recorded' : _declineTitle(r),
          'Register: ${reply['reason'] ?? 'refused'}'
          '${r.message.isNotEmpty ? ' - ${r.message}' : ''}',
          offerStatusCheck: false,
        );
      }
    } else if (r.isApproved) {
      // Approved but no ack (register unreachable). The outbox holds the
      // result and re-sends until it lands — the guest is done.
      _showSuccess(r,
          note: 'Register offline - approval saved, will sync automatically');
    } else {
      _showDeclined(_declineTitle(r), _declineDetail(r), offerStatusCheck: false);
    }
  }

  String _declineTitle(DvPayResult r) => switch (r.status) {
        'amount_mismatch' => 'Amount mismatch',
        'unmatched_result' => 'Unmatched result',
        _ => 'Payment declined',
      };

  String _declineDetail(DvPayResult r) {
    final detail = [
      if (r.statusCode.isNotEmpty) r.statusCode,
      if (r.message.isNotEmpty) r.message,
    ].join(' - ');
    return detail.isEmpty ? 'The card was not charged' : detail;
  }

  void _showSuccess(DvPayResult r, {String note = ''}) {
    _popTimer?.cancel();
    setState(() {
      _phase = _Phase.success;
      _successDetail = [
        if (r.cardType.isNotEmpty) r.cardType,
        if (r.last4.isNotEmpty) '**** ${r.last4}',
        if (r.authCode.isNotEmpty) 'auth ${r.authCode}',
      ].join('   ');
      _successNote = note;
    });
    _popTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) Navigator.of(context).pop();
    });
  }

  void _showDeclined(String title, String detail,
      {required bool offerStatusCheck}) {
    setState(() {
      _phase = _Phase.declined;
      _resultTitle = title;
      _resultDetail = detail;
      _offerStatusCheck = offerStatusCheck;
    });
  }

  /// STATUS reconcile by refId (= intentId): if DvPayLite proves the sale
  /// was approved after all, synthesize the same payment_result and deliver
  /// it through the outbox.
  Future<void> _checkStatus() async {
    if (_checkingStatus) return;
    setState(() => _checkingStatus = true);
    final r = await DvPay.status(refId: _intentId);
    if (!mounted) return;
    setState(() => _checkingStatus = false);
    if (r.isApproved) {
      await _reportResult(r, round2(_tip));
    } else {
      setState(() {
        _resultDetail = r.message.isNotEmpty
            ? 'Status check: ${r.message}'
            : 'Status check: no approved transaction found for this payment';
      });
    }
  }

  Future<void> _tryAgain() async {
    if (!_resultRecorded) {
      // Nothing was recorded — retry the SAME attempt, same intentId
      // (protocol: retries of one attempt must reuse the intentId).
      setState(() => _phase = _Phase.pick);
      return;
    }
    // The register already judged this intentId (idempotent verb) — a fresh
    // attempt needs a fresh intent for the same check.
    final resp = await widget.client.paymentIntent(_checkId);
    if (!mounted) return;
    if (resp['type'] != 'payment_intent_ok') {
      setState(() => _resultDetail =
          '${resp['message'] ?? 'Could not start a new payment attempt'}');
      return;
    }
    setState(() {
      _intent = Map<String, dynamic>.from(resp);
      _resultRecorded = false;
      _tipChoice = 0;
      _customDigits = '';
      _phase = _Phase.pick;
    });
  }

  // -------------------------------------------------------------------- ui

  @override
  Widget build(BuildContext context) {
    final body = switch (_phase) {
      _Phase.pick => _pickBody(),
      _Phase.charging => _progressBody('Follow the prompts on the card reader',
          'Charging \$${_chargeTotal.toStringAsFixed(2)}'),
      _Phase.recording => _progressBody('Recording payment on the register…', ''),
      _Phase.success => _successBody(),
      _Phase.declined => _declinedBody(),
    };
    return PopScope(
      canPop: _phase == _Phase.pick || _phase == _Phase.declined,
      child: Scaffold(
        backgroundColor: switch (_phase) {
          _Phase.success => const Color(0xFF128A50),
          _Phase.declined => const Color(0xFF8F1D1D),
          _ => DColors.bg,
        },
        body: SafeArea(child: body),
      ),
    );
  }

  Widget _pickBody() {
    final tip = _tip;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back, color: DColors.textMuted),
            ),
            Expanded(
              child: Text(
                _tableLabel.isEmpty || _tableLabel == 'TAKEOUT'
                    ? 'Collect payment'
                    : 'Collect payment · Table $_tableLabel',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: DColors.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w700),
              ),
            ),
            if (_checkNo.isNotEmpty)
              Text('#$_checkNo',
                  style:
                      const TextStyle(color: DColors.textFaint, fontSize: 12)),
          ]),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: DColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: DColors.border),
            ),
            child: Column(children: [
              _amountRow('Subtotal', _money('subTotal')),
              _amountRow('Tax', _money('tax')),
              _amountRow('Total', _money('total')),
              if (_money('alreadyPaid') > 0)
                _amountRow('Already paid', -_money('alreadyPaid')),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Divider(color: DColors.border, height: 1),
              ),
              Row(children: [
                const Text('Amount due',
                    style: TextStyle(
                        color: DColors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w700)),
                const Spacer(),
                Text('\$${_amountDue.toStringAsFixed(2)}',
                    style: const TextStyle(
                        color: DColors.primary,
                        fontSize: 24,
                        fontWeight: FontWeight.w800)),
              ]),
            ]),
          ),
          const SizedBox(height: 18),
          const Text('TIP',
              style: TextStyle(
                  color: DColors.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _tipChip(0, 'None', null),
            for (final p in const [18, 20, 25])
              _tipChip(p, '$p%', tipForPercent(_amountDue, p)),
            _tipChip(-1, 'Custom',
                _tipChoice == -1 ? keypadTip(_customDigits) : null),
          ]),
          const Spacer(),
          if (tip > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                const Text('Tip',
                    style: TextStyle(color: DColors.textMuted, fontSize: 13)),
                const Spacer(),
                Text('\$${tip.toStringAsFixed(2)}',
                    style: const TextStyle(
                        color: DColors.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ]),
            ),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _amountDue > 0 ? _charge : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: DColors.primary,
                disabledBackgroundColor: DColors.surfaceAlt,
                foregroundColor: Colors.white,
                disabledForegroundColor: DColors.textFaint,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: Text('Charge \$${_chargeTotal.toStringAsFixed(2)}',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _amountRow(String label, double v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Text(label,
            style: const TextStyle(color: DColors.textMuted, fontSize: 13)),
        const Spacer(),
        Text('${v < 0 ? '-' : ''}\$${v.abs().toStringAsFixed(2)}',
            style: const TextStyle(color: DColors.text, fontSize: 13)),
      ]),
    );
  }

  Widget _tipChip(int choice, String label, double? amount) {
    final selected = _tipChoice == choice;
    return GestureDetector(
      onTap: () async {
        if (choice == -1) {
          final digits = await _showTipKeypad();
          if (digits == null || !mounted) return;
          setState(() {
            _tipChoice = -1;
            _customDigits = digits;
          });
        } else {
          setState(() => _tipChoice = choice);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? DColors.primary : DColors.surfaceAlt,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(label,
              style: TextStyle(
                  color: selected ? Colors.white : DColors.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w700)),
          if (amount != null)
            Text('\$${amount.toStringAsFixed(2)}',
                style: TextStyle(
                    color: selected ? Colors.white70 : DColors.textFaint,
                    fontSize: 10)),
        ]),
      ),
    );
  }

  Future<String?> _showTipKeypad() {
    var digits = _tipChoice == -1 ? _customDigits : '';
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: DColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          void tap(String k) {
            setSheet(() {
              if (k == '<') {
                if (digits.isNotEmpty) {
                  digits = digits.substring(0, digits.length - 1);
                }
              } else if (digits.length < 7) {
                digits = digits + k;
              }
            });
          }

          Widget key(String k, {IconData? icon, Color? color, VoidCallback? onTap}) {
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Material(
                  color: color ?? DColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: onTap ?? () => tap(k),
                    child: SizedBox(
                      height: 52,
                      child: Center(
                        child: icon != null
                            ? Icon(icon,
                                color: color != null ? Colors.white : DColors.text,
                                size: 20)
                            : Text(k,
                                style: const TextStyle(
                                    color: DColors.text,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }

          return Padding(
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('CUSTOM TIP',
                  style: TextStyle(
                      color: DColors.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5)),
              const SizedBox(height: 6),
              Text('\$${keypadTip(digits).toStringAsFixed(2)}',
                  style: const TextStyle(
                      color: DColors.text,
                      fontSize: 28,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              Row(children: [key('1'), key('2'), key('3')]),
              Row(children: [key('4'), key('5'), key('6')]),
              Row(children: [key('7'), key('8'), key('9')]),
              Row(children: [
                key('<', icon: Icons.backspace_outlined),
                key('0'),
                key('done',
                    icon: Icons.check,
                    color: DColors.primary,
                    onTap: () => Navigator.pop(context, digits)),
              ]),
            ]),
          );
        },
      ),
    );
  }

  Widget _progressBody(String title, String subtitle) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(
              width: 42,
              height: 42,
              child: CircularProgressIndicator(
                  strokeWidth: 3, color: DColors.primary)),
          const SizedBox(height: 18),
          Text(title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: DColors.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w600)),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(subtitle,
                style:
                    const TextStyle(color: DColors.textMuted, fontSize: 13)),
          ],
        ]),
      ),
    );
  }

  Widget _successBody() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.check_circle, color: Colors.white, size: 72),
          const SizedBox(height: 14),
          Text('\$${_chargeTotal.toStringAsFixed(2)}',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 34,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text('Payment approved',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700)),
          if (_successDetail.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_successDetail,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
          if (_successNote.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(_successNote,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 11)),
          ],
          const SizedBox(height: 20),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ]),
      ),
    );
  }

  Widget _declinedBody() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, color: Colors.white, size: 64),
          const SizedBox(height: 14),
          Text(_resultTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(_resultDetail,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 22),
          if (_offerStatusCheck)
            SizedBox(
              width: 220,
              child: ElevatedButton.icon(
                onPressed: _checkingStatus ? null : _checkStatus,
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF8F1D1D)),
                icon: _checkingStatus
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.search, size: 16),
                label: Text(_checkingStatus ? 'Checking…' : 'Check status'),
              ),
            ),
          const SizedBox(height: 8),
          SizedBox(
            width: 220,
            child: OutlinedButton(
              onPressed: _tryAgain,
              style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white54)),
              child: const Text('Try again'),
            ),
          ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child:
                const Text('Close', style: TextStyle(color: Colors.white70)),
          ),
        ]),
      ),
    );
  }
}
