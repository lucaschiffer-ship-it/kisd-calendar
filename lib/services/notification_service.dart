import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// What a notification tap should open. Serialised as the plugin's payload:
/// `{"type": "course" | "mail", "id": "..."}`.
class NotificationPayload {
  final String type;
  final String id;

  const NotificationPayload({required this.type, required this.id});

  String encode() => jsonEncode({'type': type, 'id': id});

  static NotificationPayload? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final type = j['type'] as String?;
      final id = j['id'] as String?;
      if (type == null || id == null) return null;
      return NotificationPayload(type: type, id: id);
    } catch (_) {
      return null;
    }
  }
}

/// Generic local-notification layer: plugin setup, permission, scheduling and
/// tap routing. Knows nothing about courses or mail — feature schedulers own
/// their content and an ID range below.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  // Reserved ID ranges. A feature only ever cancels inside its own range.
  static const int courseIdMin = 100000;
  static const int courseIdMax = 499999;
  static const int mailIdMin = 500000;

  /// KISD times are Cologne local time, whatever zone the phone is in.
  static tz.Location get berlin => tz.getLocation('Europe/Berlin');

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  final _handlers = <String, void Function(String id)>{};
  // Taps that arrived before their screen registered a handler — cold start
  // from a notification lands here.
  final _pending = <NotificationPayload>[];

  static const _details = NotificationDetails(
    iOS: DarwinNotificationDetails(
      presentAlert: true,
      presentBanner: true,
      presentList: true,
      presentSound: true,
      presentBadge: true,
    ),
  );

  Future<void> init() async {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    await _plugin.initialize(
      const InitializationSettings(
        // Permission is asked on first need (first like), not at launch.
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestSoundPermission: false,
          requestBadgePermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (r) => _dispatch(r.payload),
    );
    _initialized = true;

    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      _dispatch(launch!.notificationResponse?.payload);
    }
  }

  /// Shows the iOS prompt the first time; afterwards returns the stored
  /// decision without prompting again.
  Future<bool> requestPermission() async {
    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    final granted = await ios?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );
    return granted ?? false;
  }

  /// Whether iOS currently lets this app post notifications.
  Future<bool> permissionGranted() async {
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    final opts = await ios?.checkPermissions();
    return opts?.isEnabled ?? false;
  }

  Future<void> schedule(
    int id,
    String title,
    String body,
    DateTime when,
    NotificationPayload payload,
  ) async {
    final at = when is tz.TZDateTime ? when : tz.TZDateTime.from(when, berlin);
    await _plugin.zonedSchedule(
      id,
      title,
      body,
      at,
      _details,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: payload.encode(),
    );
  }

  Future<void> show(
    int id,
    String title,
    String body,
    NotificationPayload payload,
  ) => _plugin.show(id, title, body, _details, payload: payload.encode());

  Future<void> cancel(int id) => _plugin.cancel(id);

  /// Cancels every pending notification whose id is in [min, max].
  Future<void> cancelRange(int min, int max) async {
    final pending = await _plugin.pendingNotificationRequests();
    for (final p in pending) {
      if (p.id >= min && p.id <= max) await _plugin.cancel(p.id);
    }
  }

  Future<int> pendingCount() async =>
      (await _plugin.pendingNotificationRequests()).length;

  // ── Tap routing ────────────────────────────────────────────────────────────

  void registerTapHandler(String type, void Function(String id) handler) {
    _handlers[type] = handler;
    final ready = _pending.where((p) => p.type == type).toList();
    _pending.removeWhere((p) => p.type == type);
    for (final p in ready) {
      handler(p.id);
    }
  }

  void unregisterTapHandler(String type) => _handlers.remove(type);

  void _dispatch(String? raw) {
    final payload = NotificationPayload.decode(raw);
    if (payload == null) return;
    switch (payload.type) {
      case 'course':
        final h = _handlers['course'];
        h != null ? h(payload.id) : _pending.add(payload);
      case 'mail':
        // TODO: route to the mail thread once mail notifications exist.
        if (kDebugMode) {
          debugPrint('[notif] mail tap ${payload.id} — not routed yet');
        }
      default:
        if (kDebugMode) {
          debugPrint('[notif] unknown payload type ${payload.type}');
        }
    }
  }
}
