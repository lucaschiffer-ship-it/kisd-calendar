import 'dart:convert';
import 'package:http/http.dart' as http;

class MensaMeal {
  final String name;
  final String category;
  final List<String> notes;
  final double? priceStudents;
  final double? priceEmployees;

  const MensaMeal({
    required this.name,
    required this.category,
    required this.notes,
    this.priceStudents,
    this.priceEmployees,
  });

  factory MensaMeal.fromJson(Map<String, dynamic> json) {
    final prices = json['prices'] as Map<String, dynamic>? ?? {};
    return MensaMeal(
      name: json['name'] as String? ?? '',
      category: json['category'] as String? ?? '',
      notes: (json['notes'] as List<dynamic>? ?? []).cast<String>(),
      priceStudents: (prices['students'] as num?)?.toDouble(),
      priceEmployees: (prices['employees'] as num?)?.toDouble(),
    );
  }
}

class MensaService {
  static const _canteenId = 383;
  static const _baseUrl = 'https://openmensa.org/api/v2/canteens/$_canteenId/days';

  final Map<String, List<MensaMeal>> _cache = {};

  void clearCacheForDate(DateTime date) {
    final key = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    _cache.remove(key);
  }

  Future<List<MensaMeal>> fetchMeals(DateTime date) async {
    final key = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    if (_cache.containsKey(key)) return _cache[key]!;

    final uri = Uri.parse('$_baseUrl/$key/meals');
    final response = await http.get(uri);
    if (response.statusCode == 404) {
      _cache[key] = [];
      return [];
    }
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final list = jsonDecode(response.body) as List<dynamic>;
    final meals = list.map((e) => MensaMeal.fromJson(e as Map<String, dynamic>)).toList();
    _cache[key] = meals;
    return meals;
  }
}

final mensaService = MensaService();
