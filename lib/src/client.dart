import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// LAN client for the XPOS register's order channel (WebSocket :7171, UDP
/// discovery :7172). Identifies as role 'order'; the register applies the
/// verbs to its offline-first database, fires the kitchen display and prints
/// station chits — this terminal never needs the internet.
class OrderClient {
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

  /// Latest snapshots, for screens that mount after they arrived.
  FloorData lastFloor = FloorData.empty;
  MenuData lastMenu = MenuData.empty;

  Stream<FloorData> get floor => _floor.stream;
  Stream<MenuData> get menu => _menu.stream;
  Stream<String> get status => _status.stream;
  Stream<bool> get connected => _connected.stream;
  bool get isConnected => _ws != null;

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
        case 'error':
          // An error answers whichever request is in flight.
          _complete('check_opened', map);
          _complete('order_placed', map);
        default:
          break;
      }
    } catch (_) {}
  }

  void _complete(String key, Map<String, dynamic> map) {
    final c = _pending.remove(key);
    if (c != null && !c.isCompleted) c.complete(map);
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
  Future<Map<String, dynamic>> placeOrder(
      {required int checkId, required List<CartLine> lines}) {
    return _request('order_placed', {
      'type': 'place_order',
      'checkId': checkId,
      'send': true,
      'items': [for (final l in lines) l.toOrderJson()],
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
  }
}
