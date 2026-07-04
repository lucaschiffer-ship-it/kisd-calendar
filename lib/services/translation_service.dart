import 'dart:async';

import 'package:flutter/services.dart';

/// German→English translation via Apple's on-device Translation framework
/// (iOS 18+), bridged over a platform channel (`ios/Runner/TranslationBridge.swift`).
/// Always free and fully local — no text ever leaves the device.
class TranslationService {
  static const _channel = MethodChannel('kisd/translation');

  final Map<String, String> _cache = {};
  Future<void> _queue = Future<void>.value();
  bool? _supported;

  Future<bool> isSupported() async {
    if (_supported != null) return _supported!;
    try {
      _supported = await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on PlatformException {
      _supported = false;
    } on MissingPluginException {
      _supported = false;
    }
    return _supported!;
  }

  /// Translates [texts], returning results in the same order. Repeated
  /// strings are served from an in-memory cache; strings that fail to
  /// translate fall back to the original. Batches run one at a time because
  /// the native side drives a single translation session.
  Future<List<String>> translate(List<String> texts) {
    final run = _queue.then((_) => _translateBatch(texts));
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<List<String>> _translateBatch(List<String> texts) async {
    final missing = texts
        .where((t) => t.trim().isNotEmpty && !_cache.containsKey(t))
        .toSet()
        .toList();
    if (missing.isNotEmpty) {
      final translated = await _channel.invokeMethod<List<dynamic>>(
        'translateBatch',
        {'texts': missing, 'source': 'de', 'target': 'en'},
      );
      if (translated != null && translated.length == missing.length) {
        for (var i = 0; i < missing.length; i++) {
          final t = (translated[i] as String?)?.trim() ?? '';
          if (t.isNotEmpty) _cache[missing[i]] = t;
        }
      }
    }
    return texts.map((t) => _cache[t] ?? t).toList();
  }
}

final translationService = TranslationService();
