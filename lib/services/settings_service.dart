import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  static const _kShowKisdEvents = 'show_kisd_events';
  static const _kDisabledRecurring = 'disabled_recurring_events';

  final ValueNotifier<bool> showKisdEvents = ValueNotifier<bool>(true);
  final ValueNotifier<Set<String>> disabledRecurringEventIds =
      ValueNotifier<Set<String>>({});

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    showKisdEvents.value = prefs.getBool(_kShowKisdEvents) ?? true;
    final raw = prefs.getString(_kDisabledRecurring);
    if (raw != null) {
      final list = (json.decode(raw) as List).cast<String>();
      disabledRecurringEventIds.value = Set<String>.from(list);
    }
  }

  Future<void> setShowKisdEvents(bool value) async {
    showKisdEvents.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kShowKisdEvents, value);
  }

  Future<void> setDisabledRecurringEventIds(Set<String> ids) async {
    disabledRecurringEventIds.value = Set<String>.from(ids);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDisabledRecurring, json.encode(ids.toList()));
  }
}
