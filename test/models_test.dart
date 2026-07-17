import 'package:dejavoo_restaurant/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MenuData parses the order-channel snapshot', () {
    final menu = MenuData.fromJson({
      'type': 'menu',
      'categories': [
        {'id': 1, 'name': 'Starters', 'color': '#EC4899', 'station': 'Saute'}
      ],
      'items': [
        {
          'id': 10,
          'categoryId': 1,
          'name': 'Crispy Wings',
          'description': 'One dozen',
          'price': 15.0,
          'badges': ['🌶'],
          'station': 'Saute',
          'taxable': true,
          'groups': [5]
        }
      ],
      'groups': [
        {
          'id': 5,
          'name': 'Wing Flavor',
          'min': 1,
          'max': 1,
          'modifiers': [
            {'id': 51, 'name': 'Buffalo', 'price': 0},
            {'id': 52, 'name': 'Extra Sauce', 'price': 0.75},
          ]
        }
      ],
    });
    expect(menu.categories.single.name, 'Starters');
    final item = menu.items.single;
    expect(item.price, 15.0);
    final groups = menu.groupsForItem(item);
    expect(groups.single.name, 'Wing Flavor');
    expect(groups.single.min, 1);
    expect(groups.single.modifiers.length, 2);
    expect(groups.single.modifiers.last.price, 0.75);
  });

  test('FloorData parses tables with statuses and open checks', () {
    final floor = FloorData.fromJson({
      'rooms': [
        {'id': 1, 'name': 'Dining Room'}
      ],
      'tables': [
        {
          'id': 3,
          'roomId': 1,
          'label': '3',
          'seats': 4,
          'shape': 'square',
          'status': 'ordered',
          'guests': 3,
          'checkId': 42,
          'total': 77.30
        },
        {'id': 4, 'roomId': 1, 'label': '4', 'seats': 2, 'status': 'open', 'guests': 0}
      ],
    });
    expect(floor.tables.first.checkId, 42);
    expect(floor.tables.first.status, 'ordered');
    expect(floor.tables.last.checkId, isNull);
  });

  test('CartLine totals include modifiers and serialize for place_order', () {
    const item = MenuItemM(
        id: 7,
        categoryId: 1,
        name: 'Ribeye',
        description: '',
        price: 46.0,
        badges: [],
        station: 'Grill',
        groupIds: []);
    final line = CartLine(
      item: item,
      qty: 2,
      seat: 1,
      course: 2,
      modifiers: const [CartMod('Add Peppercorn Sauce', 4.0)],
      notes: 'Allergy: nuts',
    );
    expect(line.unitPrice, 50.0);
    expect(line.lineTotal, 100.0);
    final json = line.toOrderJson();
    expect(json['menuItemId'], 7);
    expect(json['qty'], 2);
    expect(json['course'], 2);
    expect((json['modifiers'] as List).single['price'], 4.0);
    expect(json['notes'], 'Allergy: nuts');
    expect(cartSubtotal([line]), 100.0);
  });
}
