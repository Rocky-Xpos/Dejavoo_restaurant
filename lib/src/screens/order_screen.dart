import 'package:flutter/material.dart';

import '../client.dart';
import '../models.dart';

/// Tableside ordering: category chips + item list, modifier sheet, cart, and
/// Send — which places the whole batch on the register (KDS + chits fire
/// there) in one round trip.
class OrderScreen extends StatefulWidget {
  final OrderClient client;
  final int checkId;
  final String tableLabel;
  final int guests;
  const OrderScreen({
    super.key,
    required this.client,
    required this.checkId,
    required this.tableLabel,
    required this.guests,
  });

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  int? _categoryId;
  String _search = '';
  final List<CartLine> _cart = [];
  bool _sending = false;

  MenuData get _menu => widget.client.lastMenu;

  Future<void> _addItem(MenuItemM item) async {
    final groups = _menu.groupsForItem(item);
    if (groups.isEmpty) {
      setState(() => _cart.add(CartLine(item: item)));
      return;
    }
    final line = await _showModifierSheet(item, groups);
    if (line != null) setState(() => _cart.add(line));
  }

  Future<CartLine?> _showModifierSheet(MenuItemM item, List<ModGroupM> groups) {
    int qty = 1;
    int? seat;
    int course = 1;
    final notes = TextEditingController();
    final selected = <int, Set<int>>{};

    return showModalBottomSheet<CartLine>(
      context: context,
      isScrollControlled: true,
      backgroundColor: DColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          bool valid() {
            for (final g in groups) {
              if ((selected[g.id]?.length ?? 0) < g.min) return false;
            }
            return true;
          }

          double unit = item.price;
          for (final g in groups) {
            for (final m in g.modifiers) {
              if (selected[g.id]?.contains(m.id) ?? false) unit += m.price;
            }
          }

          void toggle(ModGroupM g, ModifierM m) {
            setSheet(() {
              final set = selected.putIfAbsent(g.id, () => <int>{});
              if (set.contains(m.id)) {
                set.remove(m.id);
              } else if (g.max == 1) {
                set
                  ..clear()
                  ..add(m.id);
              } else if (set.length < g.max) {
                set.add(m.id);
              }
            });
          }

          Widget chip(String label, bool sel, VoidCallback onTap) => GestureDetector(
                onTap: onTap,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: sel ? DColors.primary : DColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(label,
                      style: TextStyle(
                          color: sel ? Colors.white : DColors.text,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ),
              );

          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
            child: DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.85,
              maxChildSize: 0.95,
              builder: (context, scroll) => Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(item.name,
                              style: const TextStyle(
                                  color: DColors.text,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700)),
                        ),
                        Text('\$${unit.toStringAsFixed(2)}',
                            style: const TextStyle(
                                color: DColors.primary,
                                fontSize: 17,
                                fontWeight: FontWeight.w800)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: ListView(
                        controller: scroll,
                        children: [
                          for (final g in groups) ...[
                            Row(children: [
                              Text(g.name.toUpperCase(),
                                  style: const TextStyle(
                                      color: DColors.textMuted,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.5)),
                              const SizedBox(width: 6),
                              Text(
                                  g.min > 0
                                      ? 'required${g.max > 1 ? ' · up to ${g.max}' : ''}'
                                      : 'optional${g.max > 1 ? ' · up to ${g.max}' : ''}',
                                  style: TextStyle(
                                      color: g.min > 0 &&
                                              (selected[g.id]?.isEmpty ?? true)
                                          ? DColors.primary
                                          : DColors.textFaint,
                                      fontSize: 10)),
                            ]),
                            const SizedBox(height: 7),
                            Wrap(
                              spacing: 7,
                              runSpacing: 7,
                              children: [
                                for (final m in g.modifiers)
                                  chip(
                                      m.price != 0
                                          ? '${m.name} +\$${m.price.toStringAsFixed(2)}'
                                          : m.name,
                                      selected[g.id]?.contains(m.id) ?? false,
                                      () => toggle(g, m)),
                              ],
                            ),
                            const SizedBox(height: 14),
                          ],
                          const Text('SEAT',
                              style: TextStyle(
                                  color: DColors.textMuted,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(height: 7),
                          Wrap(spacing: 7, runSpacing: 7, children: [
                            chip('Table', seat == null, () => setSheet(() => seat = null)),
                            for (var s = 1; s <= widget.guests; s++)
                              chip('$s', seat == s, () => setSheet(() => seat = s)),
                          ]),
                          const SizedBox(height: 14),
                          const Text('COURSE',
                              style: TextStyle(
                                  color: DColors.textMuted,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(height: 7),
                          Wrap(spacing: 7, children: [
                            for (var c = 1; c <= 4; c++)
                              chip('$c', course == c, () => setSheet(() => course = c)),
                          ]),
                          const SizedBox(height: 14),
                          TextField(
                            controller: notes,
                            style: const TextStyle(color: DColors.text, fontSize: 13),
                            decoration: InputDecoration(
                              hintText: 'Notes / allergies',
                              hintStyle:
                                  const TextStyle(color: DColors.textFaint, fontSize: 12),
                              filled: true,
                              fillColor: DColors.surfaceAlt,
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide.none),
                            ),
                          ),
                          const SizedBox(height: 10),
                        ],
                      ),
                    ),
                    Row(
                      children: [
                        Container(
                          decoration: BoxDecoration(
                              color: DColors.surfaceAlt,
                              borderRadius: BorderRadius.circular(10)),
                          child: Row(children: [
                            IconButton(
                                onPressed: () =>
                                    setSheet(() => qty = (qty - 1).clamp(1, 99)),
                                icon: const Icon(Icons.remove,
                                    color: DColors.textMuted, size: 18)),
                            Text('$qty',
                                style: const TextStyle(
                                    color: DColors.text, fontWeight: FontWeight.w700)),
                            IconButton(
                                onPressed: () =>
                                    setSheet(() => qty = (qty + 1).clamp(1, 99)),
                                icon: const Icon(Icons.add,
                                    color: DColors.textMuted, size: 18)),
                          ]),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: valid()
                                ? () {
                                    final mods = <CartMod>[];
                                    for (final g in groups) {
                                      for (final m in g.modifiers) {
                                        if (selected[g.id]?.contains(m.id) ?? false) {
                                          mods.add(CartMod(m.name, m.price));
                                        }
                                      }
                                    }
                                    Navigator.pop(
                                        context,
                                        CartLine(
                                          item: item,
                                          qty: qty,
                                          seat: seat,
                                          course: course,
                                          modifiers: mods,
                                          notes: notes.text.trim(),
                                        ));
                                  }
                                : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: DColors.primary,
                              disabledBackgroundColor: DColors.surfaceAlt,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                            ),
                            child: Text(
                                'Add $qty · \$${(unit * qty).toStringAsFixed(2)}',
                                style: const TextStyle(fontWeight: FontWeight.w700)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _send() async {
    if (_cart.isEmpty || _sending) return;
    setState(() => _sending = true);
    final resp =
        await widget.client.placeOrder(checkId: widget.checkId, lines: _cart);
    if (!mounted) return;
    setState(() => _sending = false);
    if (resp['type'] == 'order_placed') {
      final printErrors = (resp['printErrors'] as List? ?? []);
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: DColors.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: Row(children: const [
            Icon(Icons.check_circle, color: DColors.success),
            SizedBox(width: 8),
            Text('Sent to kitchen',
                style: TextStyle(
                    color: DColors.text, fontWeight: FontWeight.w700, fontSize: 16)),
          ]),
          content: Text(
            '${resp['added']} item(s) on ${resp['tickets']} ticket(s).\n'
            'Check total: \$${((resp['total'] as num?) ?? 0).toStringAsFixed(2)}'
            '${printErrors.isNotEmpty ? '\n\nChit printing: ${printErrors.join('; ')}' : ''}',
            style: const TextStyle(color: DColors.textMuted, fontSize: 13),
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                  backgroundColor: DColors.primary, foregroundColor: Colors.white),
              child: const Text('Done'),
            ),
          ],
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: DColors.danger,
          content: Text('${resp['message'] ?? 'Order failed'}')));
    }
  }

  void _showCart() {
    showModalBottomSheet(
      context: context,
      backgroundColor: DColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Order — ${_cart.length} line(s)',
                  style: const TextStyle(
                      color: DColors.text, fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final l in _cart)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${l.qty}×',
                                style: const TextStyle(
                                    color: DColors.primary, fontWeight: FontWeight.w700)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(l.item.name,
                                      style: const TextStyle(
                                          color: DColors.text,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13)),
                                  Text(
                                      [
                                        for (final m in l.modifiers) m.name,
                                        if (l.seat != null) 'Seat ${l.seat}',
                                        'C${l.course}',
                                        if (l.notes.isNotEmpty) l.notes,
                                      ].join(' · '),
                                      style: const TextStyle(
                                          color: DColors.textMuted, fontSize: 11)),
                                ],
                              ),
                            ),
                            Text('\$${l.lineTotal.toStringAsFixed(2)}',
                                style: const TextStyle(
                                    color: DColors.text, fontWeight: FontWeight.w700)),
                            IconButton(
                              onPressed: () {
                                setSheet(() => _cart.remove(l));
                                setState(() {});
                                if (_cart.isEmpty) Navigator.pop(context);
                              },
                              icon: const Icon(Icons.delete_outline,
                                  size: 17, color: DColors.textFaint),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final categories = _menu.categories;
    final items = _menu.items.where((i) {
      if (_categoryId != null && i.categoryId != _categoryId) return false;
      if (_search.isNotEmpty && !i.name.toLowerCase().contains(_search.toLowerCase())) {
        return false;
      }
      return true;
    }).toList();
    final subtotal = cartSubtotal(_cart);

    return Scaffold(
      backgroundColor: DColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 8, 14, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back, color: DColors.textMuted),
                  ),
                  Expanded(
                    child: Text(
                        widget.tableLabel == 'TAKEOUT'
                            ? 'Takeout order'
                            : 'Table ${widget.tableLabel} · ${widget.guests} guests',
                        style: const TextStyle(
                            color: DColors.text,
                            fontSize: 16,
                            fontWeight: FontWeight.w700)),
                  ),
                  IconButton(
                    onPressed: widget.client.requestMenu,
                    tooltip: 'Refresh menu',
                    icon: const Icon(Icons.refresh, color: DColors.textFaint, size: 19),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
              child: TextField(
                onChanged: (v) => setState(() => _search = v),
                style: const TextStyle(color: DColors.text, fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search menu…',
                  hintStyle: const TextStyle(color: DColors.textFaint, fontSize: 13),
                  prefixIcon: const Icon(Icons.search, color: DColors.textFaint, size: 18),
                  filled: true,
                  fillColor: DColors.surface,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: DColors.border)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: DColors.border)),
                ),
              ),
            ),
            SizedBox(
              height: 34,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                children: [
                  _catChip(null, 'All', null),
                  for (final c in categories) _catChip(c.id, c.name, c.colorValue),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: items.isEmpty
                  ? Center(
                      child: Text(
                          _menu.items.isEmpty
                              ? 'Waiting for the menu from the register…'
                              : 'No items match',
                          style:
                              const TextStyle(color: DColors.textFaint, fontSize: 13)))
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      itemCount: items.length,
                      separatorBuilder: (context, index) =>
                          const Divider(color: DColors.border, height: 1),
                      itemBuilder: (_, i) => _itemRow(items[i]),
                    ),
            ),
            _bottomBar(subtotal),
          ],
        ),
      ),
    );
  }

  Widget _catChip(int? id, String name, Color? dot) {
    final selected = _categoryId == id;
    return Padding(
      padding: const EdgeInsets.only(right: 7),
      child: GestureDetector(
        onTap: () => setState(() => _categoryId = id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? Colors.white : DColors.surface,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: selected ? Colors.white : DColors.border),
          ),
          child: Row(children: [
            if (dot != null) ...[
              Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
              const SizedBox(width: 5),
            ],
            Text(name,
                style: TextStyle(
                    color: selected ? const Color(0xFF14171E) : DColors.textMuted,
                    fontWeight: FontWeight.w600,
                    fontSize: 11)),
          ]),
        ),
      ),
    );
  }

  Widget _itemRow(MenuItemM item) {
    return InkWell(
      onTap: () => _addItem(item),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(item.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: DColors.text,
                              fontWeight: FontWeight.w600,
                              fontSize: 14)),
                    ),
                    for (final b in item.badges)
                      Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Text(b, style: const TextStyle(fontSize: 10))),
                  ]),
                  if (item.description.isNotEmpty)
                    Text(item.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(color: DColors.textMuted, fontSize: 11)),
                ],
              ),
            ),
            Text('\$${item.price.toStringAsFixed(2)}',
                style: const TextStyle(
                    color: DColors.text, fontWeight: FontWeight.w700, fontSize: 14)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.all(5),
              decoration:
                  const BoxDecoration(color: DColors.primary, shape: BoxShape.circle),
              child: const Icon(Icons.add, size: 13, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(double subtotal) {
    final count = _cart.fold<int>(0, (s, l) => s + l.qty);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: DColors.border))),
      child: Row(
        children: [
          GestureDetector(
            onTap: _cart.isEmpty ? null : _showCart,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: DColors.surfaceAlt,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                const Icon(Icons.shopping_basket_outlined,
                    size: 17, color: DColors.textMuted),
                const SizedBox(width: 6),
                Text('$count',
                    style: const TextStyle(
                        color: DColors.text, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _cart.isEmpty || _sending ? null : _send,
              style: ElevatedButton.styleFrom(
                backgroundColor: DColors.primary,
                disabledBackgroundColor: DColors.surfaceAlt,
                foregroundColor: Colors.white,
                disabledForegroundColor: DColors.textFaint,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape:
                    RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: _sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.local_fire_department, size: 17),
              label: Text(_sending
                  ? 'Sending…'
                  : 'Send to Kitchen · \$${subtotal.toStringAsFixed(2)}'),
            ),
          ),
        ],
      ),
    );
  }
}
