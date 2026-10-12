import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/widgets/morphing_glass_header.dart';

/// Pins the maths behind shared header elements (the date row and search bar
/// that stay put when switching between pages that both show them).
///
/// Only one page's header paints at a time; the owner flips at |d| = 0.5. A
/// held element only looks still if the outgoing and incoming headers put it
/// at the same top at every pager position, which these tests check across the
/// whole pager, the Calendar↔Mensa wrap seam included.
const _n = 4; // Mensa, Mail, List, Calendar

/// Placement of tag [tag] on page [page] at pager position [pos], given every
/// page's shared tops — what MorphingGlassHeader computes per frame.
({double top, double opacity})? _place(
  List<Map<String, double>> tops,
  int page,
  double pos,
  String tag,
) {
  final own = tops[page][tag];
  if (own == null) return null;
  final d = headerSlotDistance(page, pos, _n);
  final partner = headerPartner(page, d, _n);
  return sharedElementPlacement(
    d: d,
    ownTop: own,
    partnerTop: partner == null ? null : tops[partner][tag],
  );
}

void main() {
  // Mensa and Mail and List share 'date' at the same top; Mail and List share
  // 'search' at different tops (the list has today's events above its bar).
  final tops = <Map<String, double>>[
    {'date': 60}, // Mensa
    {'date': 60, 'search': 112}, // Mail
    {'date': 60, 'search': 250}, // List
    {}, // Calendar
  ];

  test('partner is the neighbour on the side the position sits', () {
    expect(headerPartner(1, headerSlotDistance(1, 1.3, _n), _n), 2);
    expect(headerPartner(1, headerSlotDistance(1, 0.7, _n), _n), 0);
    expect(headerPartner(1, headerSlotDistance(1, 1.0, _n), _n), isNull);
    // Across the wrap seam: Mensa (0) and Calendar (3) are neighbours.
    expect(headerPartner(0, headerSlotDistance(0, 3.6, _n), _n), 3);
    expect(headerPartner(3, headerSlotDistance(3, 3.6, _n), _n), 0);
  });

  test('a held element is opaque and identical in both headers', () {
    for (var i = 0; i < _n; i++) {
      final next = (i + 1) % _n;
      for (var f = 0.0; f <= 1.0; f += 0.05) {
        final pos = i + f;
        for (final tag in ['date', 'search']) {
          final a = _place(tops, i, pos, tag);
          final b = _place(tops, next, pos, tag);
          if (a == null || b == null) continue;
          expect(a.opacity, 1.0, reason: '$tag on $i at $pos');
          expect(b.opacity, 1.0, reason: '$tag on $next at $pos');
          expect(a.top, closeTo(b.top, 1e-9), reason: '$tag at $pos');
        }
      }
    }
  });

  test('the date row stands still between pages that share it', () {
    for (final pos in [0.2, 0.5, 0.8, 1.2, 1.5, 1.8]) {
      expect(_place(tops, 1, pos, 'date')!.top, 60);
    }
  });

  test('a shared element at different tops glides between them', () {
    // Mail (1) → List (2): a quarter of the way, a quarter of the distance.
    expect(
      _place(tops, 1, 1.25, 'search')!.top,
      closeTo(112 + 0.25 * 138, 1e-9),
    );
    expect(
      _place(tops, 2, 1.25, 'search')!.top,
      closeTo(112 + 0.25 * 138, 1e-9),
    );
  });

  test('an unshared element fades with the content', () {
    // Mensa's date row towards Calendar, which has none: 1 − 2|d|.
    final p = _place(tops, 0, 3.8, 'date')!;
    expect(p.top, 60);
    expect(p.opacity, closeTo(1 - 2 * 0.2, 1e-9));
    // Mail's search towards Mensa, which has none.
    final q = _place(tops, 1, 0.75, 'search')!;
    expect(q.top, 112);
    expect(q.opacity, closeTo(0.5, 1e-9));
    // Gone by the handoff.
    expect(_place(tops, 1, 0.5, 'search')!.opacity, 0.0);
  });

  test('at rest every element sits at its own top, fully opaque', () {
    final p = _place(tops, 2, 2.0, 'search')!;
    expect(p.top, 250);
    expect(p.opacity, 1.0);
  });
}
