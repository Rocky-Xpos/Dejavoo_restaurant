import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// The slice of [OrderClient] the payment-result outbox depends on — kept
/// small so tests can substitute a fake.
abstract class PaymentTransport {
  bool get isConnected;
  Stream<bool> get connected;
  Future<Map<String, dynamic>> sendPaymentResult(Map<String, dynamic> result);
  Future<Map<String, dynamic>> paymentStatus(String intentId);
}

/// LAN client for the XPOS register's order channel (WebSocket :7171, UDP
/// discovery :7172). Identifies as role 'order'; the register applies the
/// verbs to its offline-first database, fires the kitchen display and prints
/// station chits — this terminal never needs the internet.
class OrderClient implements PaymentTransport {
  static const int wsPort = 7171;
  static const int udpPort = 7172;
  static const String beaconPrefix = 'XPOS_KDS_HOST:';

  final String deviceName;
  OrderClient({this.deviceName = 'dejavoo-terminal'});

  WebSocket? _ws;
  RawDatagramSocket? _udp;
  Timer? _retry;
  bool _disposed = false;
  String? _manualHost;
  String? _lastHost;
  int _lastPort = wsPort;

  final _floor = StreamController<FloorData>.broadcast();
  final _menu = StreamController<MenuData>.broadcast();
  final _status = StreamController<String>.broadcast();
  final _connected = StreamController<bool>.broadcast();
  final _collect = StreamController<Map<String, dynamic>>.broadcast();
  final _voids = StreamController<Map<String, dynamic>>.broadcast();

  /// Latest snapshots, for screens that mount after they arrived.
  FloorData lastFloor = FloorData.empty;
  MenuData lastMenu = MenuData.empty;

  /// True while the payment UI has a payment in flight on this terminal.
  /// Maintained by the UI; incoming collect_payment / void_payment pushes are
  /// refused (collect_ack accepted:false reason 'busy') while set.
  bool busy = false;

  Stream<FloorData> get floor => _floor.stream;
  Stream<MenuData> get menu => _menu.stream;
  Stream<String> get status => _status.stream;
  @override
  Stream<bool> get connected => _connected.stream;
  @override
  bool get isConnected => _ws != null;

  /// Register-initiated `collect_payment` pushes (already collect_ack'd).
  Stream<Map<String, dynamic>> get collectRequests => _collect.stream;

  /// Register-initiated `void_payment` pushes (already collect_ack'd). The
  /// listener runs the DvPayLite VOID and sends back a `void_result`.
  Stream<Map<String, dynamic>> get voidRequests => _voids.stream;

  final Map<String, Completer<Map<String, dynamic>>> _pending = {};

  Future<void> start({String? manualHost}) async {
    _disposed = false;
    _manualHost =
        (manualHost != null && manualHost.trim().isNotEmpty) ? manualHost.trim() : null;
    if (_manualHost != null) {
      final parts = _manualHost!.split(':');
      unawaited(_connect(
          parts[0], parts.length > 1 ? int.tryParse(parts[1]) ?? wsPort : wsPort));
      return;
    }
    _status.add('Searching for the register…');
    try {
      _udp?.close();
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, udpPort);
      _udp!.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = _udp!.receive();
        if (dg == null) return;
        final msg = utf8.decode(dg.data, allowMalformed: true);
        if (!msg.startsWith(beaconPrefix)) return;
        final hostPort = msg.substring(beaconPrefix.length).split(':');
        if (hostPort.isNotEmpty && !isConnected) {
          _connect(hostPort[0],
              hostPort.length > 1 ? int.tryParse(hostPort[1]) ?? wsPort : wsPort);
        }
      });
    } catch (e) {
      _status.add('Discovery failed ($e) — enter the register IP.');
    }
  }

  Future<void> _connect(String host, int port) async {
    if (_disposed || isConnected) return;
    _lastHost = host;
    _lastPort = port;
    _status.add('Connecting to $host…');
    try {
      final ws =
          await WebSocket.connect('ws://$host:$port').timeout(const Duration(seconds: 6));
      _ws = ws;
      ws.add(jsonEncode({'v': 1, 'type': 'hello', 'role': 'order', 'device': deviceName}));
      _status.add('Connected to $host');
      _connected.add(true);
      ws.listen(_onMessage, onDone: _onDisconnected, onError: (_) => _onDisconnected());
      // Prime snapshots.
      send({'type': 'menu_request'});
      send({'type': 'floor_request'});
    } catch (e) {
      _status.add('Could not reach $host ($e)');
      _scheduleRetry();
    }
  }

  void _onMessage(dynamic message) {
    try {
      final data = jsonDecode(message as String);
      if (data is! Map) return;
      final map = Map<String, dynamic>.from(data);
      switch (map['type']) {
        case 'menu':
          lastMenu = MenuData.fromJson(map);
          _menu.add(lastMenu);
        case 'floor':
          lastFloor = FloorData.fromJson(map);
          _floor.add(lastFloor);
        case 'check_opened':
          _complete('check_opened', map);
        case 'order_placed':
          _complete('order_placed', map);
        case 'payment_intent_ok':
          _complete('payment_intent_ok', map);
        case 'payment_recorded':
          _complete('payment_recorded', map);
        case 'payment_status_result':
          _complete('payment_status_result', map);
        case 'collect_payment':
          _ackAndForward(map, _collect);
        case 'void_payment':
          _ackAndForward(map, _voids);
        case 'error':
          // An error answers whichever request is in flight.
          _complete('check_opened', map);
          _complete('order_placed', map);
          _complete('payment_intent_ok', map);
          _complete('payment_recorded', map);
          _complete('payment_status_result', map);
        default:
          break;
      }
    } catch (_) {}
  }

  void _complete(String key, Map<String, dynamic> map) {
    final c = _pending.remove(key);
    if (c != null && !c.isCompleted) c.complete(map);
  }

  /// Acks a register push IMMEDIATELY (protocol verbs 4/5) and forwards it to
  /// the UI stream unless a payment is already in flight on this terminal.
  void _ackAndForward(
      Map<String, dynamic> map, StreamController<Map<String, dynamic>> out) {
    final accepted = !busy;
    send({
      'type': 'collect_ack',
      'intentId': map['intentId'],
      'accepted': accepted,
      if (!accepted) 'reason': 'busy',
    });
    if (accepted) out.add(map);
  }

  void _onDisconnected() {
    _ws = null;
    _connected.add(false);
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.complete({'type': 'error', 'message': 'Disconnected from the register'});
      }
    }
    _pending.clear();
    if (_disposed) return;
    _status.add('Disconnected — retrying…');
    _scheduleRetry();
  }

  void _scheduleRetry() {
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 5), () {
      if (_disposed || isConnected) return;
      if (_lastHost != null) _connect(_lastHost!, _lastPort);
    });
  }

  void send(Map<String, dynamic> message) {
    try {
      _ws?.add(jsonEncode(message));
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _request(
      String replyType, Map<String, dynamic> message) async {
    if (!isConnected) {
      return {'type': 'error', 'message': 'Not connected to the register'};
    }
    final completer = Completer<Map<String, dynamic>>();
    _pending[replyType] = completer;
    send(message);
    return completer.future.timeout(const Duration(seconds: 12), onTimeout: () {
      _pending.remove(replyType);
      return {'type': 'error', 'message': 'The register did not respond'};
    });
  }

  /// Opens (or resumes) a check. Response: check_opened{checkId, existing}.
  Future<Map<String, dynamic>> openCheck(
      {int? tableId, required int guests, String orderType = 'dine_in'}) {
    return _request('check_opened', {
      'type': 'open_check',
      'tableId': tableId,
      'guests': guests,
      'orderType': orderType,
      'device': deviceName,
    });
  }

  /// Places a batch of cart lines on a check and fires the kitchen.
  ///
  /// [orderToken] must stay the SAME across retries of one send attempt — the
  /// register uses it to make the verb idempotent (a retry after a timeout
  /// can never double-add the items).
  Future<Map<String, dynamic>> placeOrder(
      {required int checkId, required List<CartLine> lines, String? orderToken}) {
    return _request('order_placed', {
      'type': 'place_order',
      'checkId': checkId,
      'send': true,
      'orderToken': ?orderToken,
      'items': [for (final l in lines) l.toOrderJson()],
    });
  }

  /// Asks the register to open a payment attempt for [checkId].
  /// Response: payment_intent_ok{intentId, checkId, checkNo, tableLabel,
  /// amountDue, subTotal, tax, total, alreadyPaid}.
  Future<Map<String, dynamic>> paymentIntent(int checkId) {
    return _request('payment_intent_ok', {
      'type': 'payment_intent',
      'checkId': checkId,
      'device': deviceName,
    });
  }

  /// Sends a fully-built `payment_result` message (see PayScreen /
  /// PaymentResultOutbox — persist-then-send lives there, not here).
  /// Response: payment_recorded{intentId, checkId, accepted, reason?,
  /// checkStatus, balanceDue}.
  @override
  Future<Map<String, dynamic>> sendPaymentResult(Map<String, dynamic> result) {
    return _request('payment_recorded', result);
  }

  /// "Did my result land?" — asked before re-sending a stored result or
  /// firing a DvPayLite STATUS. Response: payment_status_result{intentId,
  /// state: pending|recorded|rejected|unknown, checkId?}.
  @override
  Future<Map<String, dynamic>> paymentStatus(String intentId) {
    return _request('payment_status_result', {
      'type': 'payment_status',
      'intentId': intentId,
    });
  }

  void requestFloor() => send({'type': 'floor_request'});
  void requestMenu() => send({'type': 'menu_request'});

  Future<void> stop() async {
    _disposed = true;
    _retry?.cancel();
    _udp?.close();
    _udp = null;
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;
  }

  void dispose() {
    stop();
    _floor.close();
    _menu.close();
    _status.close();
    _connected.close();
    _collect.close();
    _voids.close();
  }
}
