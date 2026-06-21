import 'package:flutter_test/flutter_test.dart';
import 'package:fuzzy/fuzzy.dart';

List<String> search(List<String> titles, String q) {
  final fuse = Fuzzy<String>(
    titles,
    options: FuzzyOptions(
      keys: [WeightedKey(name: 'title', getter: (s) => s, weight: 1.0)],
      threshold: 0.35,
      tokenize: true,
      matchAllTokens: true,
      findAllMatches: true,
    ),
  );
  return fuse.search(q).map((m) => m.item).toList();
}

void main() {
  final titles = [
    'Design Theory and Research',
    'Interface Design Basics',
    'Typography II',
    'Service Design Studio',
    'Photography Workshop',
  ];

  test('typos still match', () {
    for (final q in ['desgin', 'typografy', 'fotography', 'servce design']) {
      final r = search(titles, q);
      expect(r, isNotEmpty, reason: 'expected matches for "$q"');
    }
  });

  test('garbage does not match everything', () {
    final r = search(titles, 'qqqqxxxx');
    expect(r, isEmpty);
  });
}
