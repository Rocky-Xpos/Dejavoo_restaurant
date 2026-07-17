import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../client.dart';
import '../models.dart';
import '../services/dvpay.dart';
import '../services/payment_outbox.dart';
import 'order_screen.dart';
import 'pay_screen.dart';

/// Home screen of the tableside app: live floor plan (pushed by the register),
/// tap a table to seat/resume, then take the order.
class FloorScreen extends StatefulWidget {
  const FloorScreen({super.key});

  @override
  State<FloorScreen> createState() => _FloorScreenState();
}

class _FloorScreenState extends State<FloorScreen> {
  final _client = OrderClient(deviceName: 'dejavoo-terminal');
  FloorData _floor = FloorData.empty;
  String _statusText = 'Starting…';
  bool _connected = false;
  int? _roomId;
  PaymentResultOutbox? _outbox;
  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    _subs.add(_client.floor.listen((f) => setState(() => _floor = f)));
    _subs.add(_client.status.listen((s) => setState(() => _statusText = s)));
    _subs.add(_client.connected.listen((c) => setState(() => _connected = c)));
    _subs.add(_client.collectRequests.listen(_onCollectRequest));
    _subs.add(_client.voidRequests.listen(_onVoidRequest));
    _startFromPrefs();
  }

  Future<void> _startFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    // Outbox before connect: a payment_result stored by a previous run is
    // re-delivered as soon as the register link comes up.
    _outbox = PaymentResultOutbox(prefs: prefs, client: _client)..start();
    await _client.start(manualHost: prefs.getString('manual_host'));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _outbox?.dispose();
    _client.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------- payments

  /// Register asked THIS terminal to collect a payment (verb 4): the client
  /// already acked, so just present the full-screen payment flow.
  Future<void> _onCollectRequest(Map<String, dynamic> intent) async {
    final outbox = _outbox;
    if (!mounted || outbox == null) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          PayScreen(client: _client, outbox: outbox, intent: intent),
    ));
    _client.requestFloor();
  }

  /// Register asked for a VOID (verb 5, manager PIN already validated
  /// register-side): run it against DvPayLite behind a brief blocking
  /// overlay and report the void_result.
  Future<void> _onVoidRequest(Map<String, dynamic> req) async {
    if (!mounted) return;
    _client.busy = true;
    BuildContext? overlayCtx;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        overlayCtx = dialogCtx;
        return const _VoidOverlay();
      },
    );
    try {
      final refId = '${req['refId'] ?? ''}';
      final amount = ((req['amount'] as num?) ?? 0).toDouble();
      final r = await DvPay.voidTxn(amount: amount, refId: refId);
      _client.send({
        'type': 'void_result',
        'intentId': req['intentId'],
        'checkId': req['checkId'],
        'refId': refId,
        'status': r.isApproved ? 'success' : 'failed',
        'statusCode': r.statusCode,
        'message': r.message,
        'device': _client.deviceName,
      });
    } finally {
      _client.busy = false;
      final ctx = overlayCtx;
      if (ctx != null && ctx.mounted) Navigator.of(ctx).pop();
      if (mounted) _client.requestFloor();
    }
  }

  Future<void> _collectForCheck(int checkId) async {
    final outbox = _outbox;
    if (outbox == null) return;
    final resp = await _client.paymentIntent(checkId);
    if (!mounted) return;
    if (resp['type'] != 'payment_intent_ok') {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: DColors.danger,
          content:
              Text('${resp['message'] ?? 'Could not start the payment'}')));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PayScreen(client: _client, outbox: outbox, intent: resp),
    ));
    _client.requestFloor();
  }

  Future<void> _openTable(TableM table) async {
    if (table.status == 'needs_bus') {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Table is paid — clear it from the register')));
      return;
    }
    // Occupied table with a live check: order more, or collect the payment.
    if (table.status != 'open' && table.checkId != null && _outbox != null) {
      final action = await _pickTableAction(table);
      if (action == null || !mounted) return;
      if (action == 'collect') {
        await _collectForCheck(table.checkId!);
        return;
      }
      // 'order' falls through to the normal resume flow.
    }
    if (!mounted) return;
    int guests = table.status == 'open' ? table.seats.clamp(1, 12) : table.guests;
    if (table.status == 'open') {
      final picked = await _pickGuests(table.label, guests);
      if (picked == null) return;
      guests = picked;
    }
    final resp = await _client.openCheck(tableId: table.id, guests: guests);
    if (!mounted) return;
    if (resp['type'] != 'check_opened') {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${resp['message'] ?? 'Could not open the check'}')));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => OrderScreen(
        client: _client,
        checkId: (resp['checkId'] as num).toInt(),
        tableLabel: table.label,
        guests: (resp['guests'] as num?)?.toInt() ?? guests,
        outbox: _outbox,
      ),
    ));
    _client.requestFloor();
  }

  Future<String?> _pickTableAction(TableM table) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: DColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
              child: Row(children: [
                Text('Table ${table.label} · ${table.guests} guests',
                    style: const TextStyle(
                        color: DColors.text,
                        fontSize: 16,
                        fontWeight: FontWeight.w700)),
                const Spacer(),
                if (table.total > 0)
                  Text('\$${table.total.toStringAsFixed(2)}',
                      style: const TextStyle(
                          color: DColors.textMuted,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
              ]),
            ),
            ListTile(
              leading:
                  const Icon(Icons.restaurant_menu, color: DColors.textMuted),
              title: const Text('Open order',
                  style: TextStyle(color: DColors.text, fontSize: 14)),
              onTap: () => Navigator.pop(context, 'order'),
            ),
            ListTile(
              leading:
                  const Icon(Icons.payments_outlined, color: DColors.success),
              title: const Text('Collect payment',
                  style: TextStyle(color: DColors.text, fontSize: 14)),
              onTap: () => Navigator.pop(context, 'collect'),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Future<void> _startTakeout() async {
    final resp = await _client.openCheck(guests: 1, orderType: 'takeout');
    if (!mounted) return;
    if (resp['type'] != 'check_opened') {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${resp['message'] ?? 'Could not start takeout'}')));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => OrderScreen(
        client: _client,
        checkId: (resp['checkId'] as num).toInt(),
        tableLabel: 'TAKEOUT',
        guests: 1,
        outbox: _outbox,
      ),
    ));
    _client.requestFloor();
  }

  Future<int?> _pickGuests(String label, int initial) {
    return showModalBottomSheet<int>(
      context: context,
      backgroundColor: DColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Seat Table $label — guests?',
                style: const TextStyle(
                    color: DColors.text, fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (var n = 1; n <= 12; n++)
                  GestureDetector(
                    onTap: () => Navigator.pop(context, n),
                    child: Container(
                      width: 52,
                      height: 52,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: n == initial ? DColors.primary : DColors.surfaceAlt,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text('$n',
                          style: TextStyle(
                              color: n == initial ? Colors.white : DColors.textMuted,
                              fontSize: 17,
                              fontWeight: FontWeight.w700)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rooms = _floor.rooms;
    final selectedRoom = _roomId != null && rooms.any((r) => r.id == _roomId)
        ? _roomId
        : (rooms.isNotEmpty ? rooms.first.id : null);
    final tables =
        _floor.tables.where((t) => selectedRoom == null || t.roomId == selectedRoom).toList();

    return Scaffold(
      backgroundColor: DColors.bg,
      floatingActionButton: _connected
          ? FloatingActionButton.extended(
              onPressed: _startTakeout,
              backgroundColor: DColors.surfaceAlt,
              foregroundColor: DColors.text,
              icon: const Icon(Icons.takeout_dining, size: 18),
              label: const Text('Takeout'),
            )
          : null,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                        color: DColors.primary, borderRadius: BorderRadius.circular(9)),
                    alignment: Alignment.center,
                    child: const Text('ƒ',
                        style: TextStyle(
                            color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('XPOS Tableside',
                            style: TextStyle(
                                color: DColors.text,
                                fontSize: 16,
                                fontWeight: FontWeight.w700)),
                        Text(_statusText,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: _connected ? DColors.textMuted : DColors.warning,
                                fontSize: 10)),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _showSettings,
                    icon: const Icon(Icons.settings_outlined,
                        color: DColors.textMuted, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (rooms.isNotEmpty)
                SizedBox(
                  height: 36,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final r in rooms)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: GestureDetector(
                            onTap: () => setState(() => _roomId = r.id),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 8),
                              decoration: BoxDecoration(
                                color:
                                    r.id == selectedRoom ? Colors.white : DColors.surface,
                                borderRadius: BorderRadius.circular(9),
                                border: Border.all(
                                    color: r.id == selectedRoom
                                        ? Colors.white
                                        : DColors.border),
                              ),
                              child: Text(r.name,
                                  style: TextStyle(
                                      color: r.id == selectedRoom
                                          ? const Color(0xFF14171E)
                                          : DColors.textMuted,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12)),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 10),
              Expanded(
                child: !_connected && _floor.tables.isEmpty
                    ? _disconnected()
                    : GridView.builder(
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 110,
                          mainAxisExtent: 86,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                        itemCount: tables.length,
                        itemBuilder: (_, i) => _tableTile(tables[i]),
                      ),
              ),
              _legend(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _disconnected() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_tethering, size: 40, color: DColors.textFaint),
          const SizedBox(height: 10),
          Text(_statusText,
              textAlign: TextAlign.center,
              style: const TextStyle(color: DColors.textMuted, fontSize: 13)),
          const SizedBox(height: 4),
          const Text('Connect this terminal to the restaurant Wi-Fi.\nThe register must be on.',
              textAlign: TextAlign.center,
              style: TextStyle(color: DColors.textFaint, fontSize: 11)),
          const SizedBox(height: 14),
          OutlinedButton(
            onPressed: _showSettings,
            style: OutlinedButton.styleFrom(
                foregroundColor: DColors.text,
                side: const BorderSide(color: DColors.border)),
            child: const Text('Enter register IP'),
          ),
        ],
      ),
    );
  }

  Future<void> _showSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final ctrl = TextEditingController(text: prefs.getString('manual_host') ?? '');
    if (!mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: DColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('Register connection',
            style: TextStyle(
                color: DColors.text, fontWeight: FontWeight.w700, fontSize: 16)),
        content: TextField(
          controller: ctrl,
          style: const TextStyle(color: DColors.text),
          decoration: InputDecoration(
            hintText: 'Auto-discover (leave empty)',
            hintStyle: const TextStyle(color: DColors.textFaint, fontSize: 13),
            filled: true,
            fillColor: DColors.surfaceAlt,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel', style: TextStyle(color: DColors.textMuted))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: DColors.primary, foregroundColor: Colors.white),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved == true) {
      final host = ctrl.text.trim();
      if (host.isEmpty) {
        await prefs.remove('manual_host');
      } else {
        await prefs.setString('manual_host', host);
      }
      await _client.stop();
      await _client.start(manualHost: host.isEmpty ? null : host);
    }
  }

  Widget _tableTile(TableM t) {
    final color = DColors.tableStatus(t.status);
    final open = t.status == 'open';
    return GestureDetector(
      onTap: () => _openTable(t),
      child: Container(
        decoration: BoxDecoration(
          color: color.withValues(alpha: open ? 0.06 : 0.15),
          borderRadius: BorderRadius.circular(t.shape == 'round' ? 43 : 13),
          border: Border.all(color: color.withValues(alpha: open ? 0.4 : 1), width: 2),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(t.label,
                style: const TextStyle(
                    color: DColors.text, fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(open ? '${t.seats} seats' : '${t.guests} guests',
                style: const TextStyle(color: DColors.textMuted, fontSize: 10)),
            if (!open && t.total > 0)
              Text('\$${t.total.toStringAsFixed(0)}',
                  style: const TextStyle(color: DColors.textFaint, fontSize: 10)),
          ],
        ),
      ),
    );
  }

  Widget _legend() {
    Widget dot(String label, String status) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                  color: DColors.tableStatus(status), shape: BoxShape.circle)),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(color: DColors.textFaint, fontSize: 10)),
        ]);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(spacing: 12, children: [
        dot('Open', 'open'),
        dot('Seated', 'seated'),
        dot('Ordered', 'ordered'),
        dot('Check', 'check_drop'),
        dot('Bus', 'needs_bus'),
      ]),
    );
  }
}

/// Brief blocking overlay while a register-initiated VOID runs on DvPayLite.
class _VoidOverlay extends StatelessWidget {
  const _VoidOverlay();

  @override
  Widget build(BuildContext context) {
    return const Dialog(
      backgroundColor: DColors.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(14))),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 24, vertical: 22),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                  strokeWidth: 2.5, color: DColors.primary)),
          SizedBox(width: 14),
          Text('Processing void…',
              style: TextStyle(
                  color: DColors.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}
