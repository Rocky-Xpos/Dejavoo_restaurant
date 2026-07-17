import 'package:flutter/material.dart';

/// Design tokens — mirrors the XPOS restaurant module.
class DColors {
  DColors._();
  static const Color bg = Color(0xFF14171E);
  static const Color surface = Color(0xFF1B1F27);
  static const Color surfaceAlt = Color(0xFF232936);
  static const Color border = Color(0xFF2A313D);
  static const Color primary = Color(0xFFFF6A1A);
  static const Color text = Color(0xFFF3F5F8);
  static const Color textMuted = Color(0xFF9AA4B4);
  static const Color textFaint = Color(0xFF69707E);
  static const Color success = Color(0xFF34C77B);
  static const Color danger = Color(0xFFEF4444);
  static const Color warning = Color(0xFFF59E0B);

  static Color tableStatus(String status) {
    switch (status) {
      case 'seated':
        return const Color(0xFF29B6D8);
      case 'ordered':
        return const Color(0xFFF08A3C);
      case 'check_drop':
        return const Color(0xFF84CC16);
      case 'needs_bus':
        return const Color(0xFFEC4899);
      default:
        return const Color(0xFF6B7280);
    }
  }
}

double _d(dynamic v) => (v as num?)?.toDouble() ?? 0.0;
int _i(dynamic v, [int fallback = 0]) => (v as num?)?.toInt() ?? fallback;

// ---------------------------------------------------------------- menu

class MenuCategoryM {
  final int id;
  final String name;
  final String color;
  const MenuCategoryM({required this.id, required this.name, required this.color});

  factory MenuCategoryM.fromJson(Map<String, dynamic> j) => MenuCategoryM(
      id: _i(j['id']), name: '${j['name'] ?? ''}', color: '${j['color'] ?? '#8B93A7'}');

  Color get colorValue {
    try {
      return Color(int.parse(color.replaceFirst('#', '0xFF')));
    } catch (_) {
      return DColors.textFaint;
    }
  }
}

class ModifierM {
  final int id;
  final String name;
  final double price;
  const ModifierM({required this.id, required this.name, required this.price});

  factory ModifierM.fromJson(Map<String, dynamic> j) =>
      ModifierM(id: _i(j['id']), name: '${j['name'] ?? ''}', price: _d(j['price']));
}

class ModGroupM {
  final int id;
  final String name;
  final int min;
  final int max;
  final List<ModifierM> modifiers;
  const ModGroupM(
      {required this.id,
      required this.name,
      required this.min,
      required this.max,
      required this.modifiers});

  factory ModGroupM.fromJson(Map<String, dynamic> j) => ModGroupM(
        id: _i(j['id']),
        name: '${j['name'] ?? ''}',
        min: _i(j['min']),
        max: _i(j['max'], 1),
        modifiers: [
          for (final m in (j['modifiers'] as List? ?? []))
            if (m is Map) ModifierM.fromJson(Map<String, dynamic>.from(m))
        ],
      );
}

class MenuItemM {
  final int id;
  final int categoryId;
  final String name;
  final String description;
  final double price;
  final List<String> badges;
  final String station;
  final List<int> groupIds;
  const MenuItemM({
    required this.id,
    required this.categoryId,
    required this.name,
    required this.description,
    required this.price,
    required this.badges,
    required this.station,
    required this.groupIds,
  });

  factory MenuItemM.fromJson(Map<String, dynamic> j) => MenuItemM(
        id: _i(j['id']),
        categoryId: _i(j['categoryId']),
        name: '${j['name'] ?? ''}',
        description: '${j['description'] ?? ''}',
        price: _d(j['price']),
        badges: [for (final b in (j['badges'] as List? ?? [])) '$b'],
        station: '${j['station'] ?? ''}',
        groupIds: [for (final g in (j['groups'] as List? ?? [])) _i(g)],
      );
}

class MenuData {
  final List<MenuCategoryM> categories;
  final List<MenuItemM> items;
  final Map<int, ModGroupM> groupsById;
  const MenuData({required this.categories, required this.items, required this.groupsById});

  static const empty = MenuData(categories: [], items: [], groupsById: {});

  factory MenuData.fromJson(Map<String, dynamic> j) => MenuData(
        categories: [
          for (final c in (j['categories'] as List? ?? []))
            if (c is Map) MenuCategoryM.fromJson(Map<String, dynamic>.from(c))
        ],
        items: [
          for (final i in (j['items'] as List? ?? []))
            if (i is Map) MenuItemM.fromJson(Map<String, dynamic>.from(i))
        ],
        groupsById: {
          for (final g in (j['groups'] as List? ?? []))
            if (g is Map) _i(g['id']): ModGroupM.fromJson(Map<String, dynamic>.from(g))
        },
      );

  List<ModGroupM> groupsForItem(MenuItemM item) =>
      [for (final id in item.groupIds) if (groupsById[id] != null) groupsById[id]!];
}

// ---------------------------------------------------------------- floor

class RoomM {
  final int id;
  final String name;
  const RoomM({required this.id, required this.name});

  factory RoomM.fromJson(Map<String, dynamic> j) =>
      RoomM(id: _i(j['id']), name: '${j['name'] ?? ''}');
}

class TableM {
  final int id;
  final int roomId;
  final String label;
  final int seats;
  final String shape;
  final String status;
  final int guests;
  final int? checkId;
  final double total;
  const TableM({
    required this.id,
    required this.roomId,
    required this.label,
    required this.seats,
    required this.shape,
    required this.status,
    required this.guests,
    required this.checkId,
    required this.total,
  });

  factory TableM.fromJson(Map<String, dynamic> j) => TableM(
        id: _i(j['id']),
        roomId: _i(j['roomId']),
        label: '${j['label'] ?? ''}',
        seats: _i(j['seats'], 4),
        shape: '${j['shape'] ?? 'square'}',
        status: '${j['status'] ?? 'open'}',
        guests: _i(j['guests']),
        checkId: j['checkId'] == null ? null : _i(j['checkId']),
        total: _d(j['total']),
      );
}

class FloorData {
  final List<RoomM> rooms;
  final List<TableM> tables;
  const FloorData({required this.rooms, required this.tables});

  static const empty = FloorData(rooms: [], tables: []);

  factory FloorData.fromJson(Map<String, dynamic> j) => FloorData(
        rooms: [
          for (final r in (j['rooms'] as List? ?? []))
            if (r is Map) RoomM.fromJson(Map<String, dynamic>.from(r))
        ],
        tables: [
          for (final t in (j['tables'] as List? ?? []))
            if (t is Map) TableM.fromJson(Map<String, dynamic>.from(t))
        ],
      );
}

// ----------------------------------------------------------------- cart

class CartMod {
  final String name;
  final double price;
  const CartMod(this.name, this.price);

  Map<String, dynamic> toJson() => {'name': name, 'price': price};
}

class CartLine {
  final MenuItemM item;
  int qty;
  int? seat;
  int course;
  final List<CartMod> modifiers;
  final String notes;
  CartLine({
    required this.item,
    this.qty = 1,
    this.seat,
    this.course = 1,
    this.modifiers = const [],
    this.notes = '',
  });

  double get unitPrice =>
      item.price + modifiers.fold<double>(0, (s, m) => s + m.price);

  double get lineTotal => ((unitPrice * qty) * 100).roundToDouble() / 100;

  Map<String, dynamic> toOrderJson() => {
        'menuItemId': item.id,
        'qty': qty,
        'seat': seat,
        'course': course,
        'modifiers': [for (final m in modifiers) m.toJson()],
        'notes': notes,
      };
}

double cartSubtotal(List<CartLine> lines) =>
    ((lines.fold<double>(0, (s, l) => s + l.lineTotal)) * 100).roundToDouble() / 100;
