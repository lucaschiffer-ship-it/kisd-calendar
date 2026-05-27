import 'package:flutter/material.dart';

import '../models/kisd_event.dart';
import '../services/cache_service.dart';
import '../services/calendar_service.dart';
import '../services/settings_service.dart';

class RecurringEventsScreen extends StatefulWidget {
  const RecurringEventsScreen({super.key});

  @override
  State<RecurringEventsScreen> createState() => _RecurringEventsScreenState();
}

class _RecurringEventsScreenState extends State<RecurringEventsScreen> {
  List<KisdEvent> _events = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final raw = await CacheService().loadKisdEvents();
    final recurring = raw
        .map(KisdEvent.fromJson)
        .where((e) => e.isRecurring && e.title.isNotEmpty && e.title != 'View')
        .toList()
      ..sort((a, b) => a.title.compareTo(b.title));
    if (mounted) setState(() { _events = recurring; _loading = false; });
  }

  Future<void> _toggleAll(bool enable) async {
    final newDisabled = enable ? <String>{} : _events.map((e) => e.id).toSet();
    await SettingsService.instance.setDisabledRecurringEventIds(newDisabled);
    _syncCalendar();
    if (mounted) setState(() {});
  }

  Future<void> _toggleEvent(String id, bool enable) async {
    final current = Set<String>.from(
        SettingsService.instance.disabledRecurringEventIds.value);
    if (enable) {
      current.remove(id);
    } else {
      current.add(id);
    }
    await SettingsService.instance.setDisabledRecurringEventIds(current);
    _syncCalendar();
    if (mounted) setState(() {});
  }

  void _syncCalendar() async {
    final raw = await CacheService().loadKisdEvents();
    final events = raw.map(KisdEvent.fromJson).toList();
    CalendarService.instance.writeKisdEvents(events).ignore();
  }

  String _nextOccurrence(KisdEvent event) {
    var d = event.start;
    final now = DateTime.now();
    if (!d.isBefore(now)) return _fmtDate(d);
    // Approximate next weekly occurrence
    while (d.isBefore(now)) {
      d = d.add(const Duration(days: 7));
    }
    return _fmtDate(d);
  }

  static const _kMonths = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _fmtDate(DateTime d) =>
      '${_kMonths[d.month - 1]} ${d.day}, ${d.year}';

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: colorScheme.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Text(
          'Repeating Events',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurface,
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _events.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      'No recurring events found.\nEvents marked as recurring will appear here.',
                      style: TextStyle(
                        fontSize: 15,
                        color: colorScheme.onSurface.withAlpha(140),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ValueListenableBuilder<Set<String>>(
                  valueListenable:
                      SettingsService.instance.disabledRecurringEventIds,
                  builder: (context, disabled, _) {
                    final allEnabled = disabled.isEmpty;

                    return ListView(
                      children: [
                        // ── Toggle all ─────────────────────────────────────
                        const SizedBox(height: 24),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Text(
                            'ALL EVENTS',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface.withAlpha(100),
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              color: colorScheme.surfaceContainerHigh,
                              child: SwitchListTile(
                                title: const Text('Enable all repeating events',
                                    style: TextStyle(fontWeight: FontWeight.w500)),
                                value: allEnabled,
                                onChanged: _toggleAll,
                                activeThumbColor: colorScheme.primary,
                              ),
                            ),
                          ),
                        ),

                        // ── Per-event list ─────────────────────────────────
                        const SizedBox(height: 24),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Text(
                            'INDIVIDUAL EVENTS',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface.withAlpha(100),
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              color: colorScheme.surfaceContainerHigh,
                              child: Column(
                                children: [
                                  for (var i = 0; i < _events.length; i++) ...[
                                    if (i > 0)
                                      Divider(
                                        height: 1,
                                        thickness: 0.5,
                                        indent: 16,
                                        color: Colors.white.withAlpha(18),
                                      ),
                                    SwitchListTile(
                                      title: Text(
                                        _events[i].title,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w500,
                                          fontSize: 15,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: Text(
                                        'Next: ${_nextOccurrence(_events[i])}',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: colorScheme.onSurface
                                              .withAlpha(120),
                                        ),
                                      ),
                                      value: !disabled.contains(_events[i].id),
                                      onChanged: (v) =>
                                          _toggleEvent(_events[i].id, v),
                                      activeThumbColor: colorScheme.primary,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 40),
                      ],
                    );
                  },
                ),
    );
  }
}
