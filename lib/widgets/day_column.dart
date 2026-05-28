import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_theme.dart';
import '../services/calendar_service.dart';
import '../services/theme_service.dart';

// ─── Overlap layout helpers ───────────────────────────────────────────────────

class _EvtItem {
  _EvtItem({required this.event, required this.startMin, required this.endMin});
  final DeviceCalendarEvent event;
  final int startMin;
  final int endMin;
}

bool _overlaps(_EvtItem a, _EvtItem b) =>
    a.startMin < b.endMin && b.startMin < a.endMin;

// ─── Widget ───────────────────────────────────────────────────────────────────

class DayColumn extends StatefulWidget {
  const DayColumn({
    super.key,
    required this.day,
    this.onEventTap,
    this.showHourLabels = true,
    this.embedded = false,
    this.topInset = 0,
  });

  final DateTime day;

  /// Called with the tapped event and the day it belongs to.
  final void Function(DeviceCalendarEvent, DateTime)? onEventTap;
  final bool showHourLabels;

  /// When true, omits the internal SingleChildScrollView — the parent owns scrolling.
  final bool embedded;

  /// Height in logical pixels covered by the glass header overlay. Used to
  /// position 8:00 at the first visible row below the header on initial load.
  final double topInset;

  static const double hourHeight = 50.0;
  static const double labelWidth = 52.0;

  @override
  State<DayColumn> createState() => _DayColumnState();
}

class _DayColumnState extends State<DayColumn> {
  ScrollController? _scrollController;
  List<DeviceCalendarEvent> _events = [];
  DateTime _now = DateTime.now();
  late Timer _timer;

  @override
  void initState() {
    super.initState();
    if (!widget.embedded) {
      _scrollController = ScrollController();
    }
    // Seed from cache synchronously so the first frame shows events rather than blank.
    _events = CalendarService.instance.getCachedEvents(widget.day) ?? [];
    _loadEvents();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    if (!widget.embedded) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToFocus());
    }
  }

  @override
  void didUpdateWidget(DayColumn old) {
    super.didUpdateWidget(old);
    if (old.day != widget.day) {
      // Show cached events immediately while the async refresh runs.
      setState(() =>
          _events = CalendarService.instance.getCachedEvents(widget.day) ?? []);
      _loadEvents();
      if (!widget.embedded) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToFocus());
      }
    }
  }

  @override
  void dispose() {
    _timer.cancel();
    _scrollController?.dispose();
    super.dispose();
  }

  Future<void> _loadEvents() async {
    final events = await CalendarService.instance.getEventsForDay(widget.day);
    if (mounted) setState(() => _events = events);
  }

  bool get _isToday {
    return widget.day.year == _now.year &&
        widget.day.month == _now.month &&
        widget.day.day == _now.day;
  }

  void _scrollToFocus() {
    if (_scrollController == null || !_scrollController!.hasClients) return;
    // Position 8:00 at the first pixel visible below the glass header.
    const kStartHour = 8.0;
    final target = (kStartHour * DayColumn.hourHeight - widget.topInset)
        .clamp(0.0, _scrollController!.position.maxScrollExtent);
    _scrollController!.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        ThemeService.instance.currentColor,
        ThemeService.instance.currentStyle,
        ThemeService.instance.glassEnabled,
      ]),
      builder: (context, _) => _buildContent(),
    );
  }

  Widget _buildContent() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalHeight = DayColumn.hourHeight * 24;
        final leftOffset = widget.showHourLabels ? DayColumn.labelWidth : 0.0;
        final eventAreaWidth = constraints.maxWidth - leftOffset;

        final stack = SizedBox(
          height: totalHeight,
          width: constraints.maxWidth,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              _buildGrid(),
              ..._buildEventCards(eventAreaWidth, leftOffset),
              if (_isToday) _buildTimeIndicator(constraints.maxWidth, leftOffset),
            ],
          ),
        );

        if (widget.embedded) {
          return DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                right: BorderSide(
                  color: AppThemeTokens.cardBorder,
                  width: 0.5,
                ),
              ),
            ),
            child: stack,
          );
        }

        return SingleChildScrollView(
          controller: _scrollController,
          child: stack,
        );
      },
    );
  }

  Widget _buildGrid() {
    final dividerColor = AppThemeTokens.cardBorder;
    final labelStyle = GoogleFonts.inter(
      fontSize: 11,
      fontWeight: FontWeight.w400,
      color: AppThemeTokens.secondaryTextColor,
    );
    return Column(
      children: List.generate(24, (hour) {
        return SizedBox(
          height: DayColumn.hourHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.showHourLabels)
                SizedBox(
                  width: DayColumn.labelWidth,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 3, right: 8),
                    child: Text(
                      '${hour.toString().padLeft(2, '0')}:00',
                      textAlign: TextAlign.right,
                      style: labelStyle,
                    ),
                  ),
                ),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(color: dividerColor, width: 0.5),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }

  List<Widget> _buildEventCards(double eventAreaWidth, double leftOffset) {
    if (_events.isEmpty) return const [];

    final items = _events.map((e) {
      final startMin = e.start.hour * 60 + e.start.minute;
      final endMin = (e.end.hour * 60 + e.end.minute).clamp(startMin + 15, 24 * 60);
      return _EvtItem(event: e, startMin: startMin, endMin: endMin);
    }).toList()
      ..sort((a, b) => a.startMin.compareTo(b.startMin));

    final n = items.length;

    // Apple-style layout: only split events into side-by-side columns when their
    // header regions conflict (both time-overlap AND start within kHeaderMin of
    // each other). Events starting far apart are layered full-width, later on top.
    const kHeaderMin = 45; // minutes ≈ rendered height of one event header

    bool needsSplit(int i, int j) =>
        _overlaps(items[i], items[j]) &&
        (items[i].startMin - items[j].startMin).abs() < kHeaderMin;

    // Connected components of the header-conflict graph → each component shares columns.
    final compOf = List.filled(n, -1);
    final comps = <List<int>>[];
    for (int i = 0; i < n; i++) {
      if (compOf[i] != -1) continue;
      final cId = comps.length;
      final comp = <int>[];
      comps.add(comp);
      final stack = [i];
      while (stack.isNotEmpty) {
        final cur = stack.removeLast();
        if (compOf[cur] != -1) continue;
        compOf[cur] = cId;
        comp.add(cur);
        for (int j = 0; j < n; j++) {
          if (compOf[j] == -1 && needsSplit(cur, j)) stack.add(j);
        }
      }
    }

    // Greedy lane assignment within each component.
    const gap = 1.5;
    final lane = List.filled(n, 0);
    final lanesPerComp = List.filled(comps.length, 1);

    for (int ci = 0; ci < comps.length; ci++) {
      final comp = comps[ci]
        ..sort((a, b) => items[a].startMin.compareTo(items[b].startMin));
      final laneEnd = <int>[];
      for (final idx in comp) {
        int l = laneEnd.indexWhere((e) => e <= items[idx].startMin);
        if (l == -1) l = laneEnd.length;
        if (l == laneEnd.length) {
          laneEnd.add(items[idx].startMin + kHeaderMin);
        } else {
          laneEnd[l] = items[idx].startMin + kHeaderMin;
        }
        lane[idx] = l;
      }
      lanesPerComp[ci] = laneEnd.length;
    }

    // Layering indent: full-width events that time-overlap an earlier full-width
    // event are offset to the right so the event beneath stays partially visible.
    const kLayerIndent = 28.0;
    final layerDepth = List.filled(n, 0);
    for (int idx = 0; idx < n; idx++) {
      if (lanesPerComp[compOf[idx]] != 1) continue;
      int depth = 0;
      for (int j = 0; j < idx; j++) {
        if (lanesPerComp[compOf[j]] == 1 && _overlaps(items[idx], items[j])) {
          final d = layerDepth[j] + 1;
          if (d > depth) depth = d;
        }
      }
      layerDepth[idx] = depth;
    }

    // Build positioned widgets — sorted by start time so later events render on top.
    final widgets = <Widget>[];
    for (int idx = 0; idx < n; idx++) {
      final item = items[idx];
      final totalLanes = lanesPerComp[compOf[idx]];
      final indent = totalLanes == 1 ? layerDepth[idx] * kLayerIndent : 0.0;
      final laneWidth = totalLanes == 1
          ? eventAreaWidth - 4 - indent
          : (eventAreaWidth - 4 - gap * (totalLanes - 1)) / totalLanes;
      final left = leftOffset + 2 + indent +
          (totalLanes == 1 ? 0.0 : lane[idx] * (laneWidth + gap));
      final top = item.startMin / 60.0 * DayColumn.hourHeight;
      final height = ((item.endMin - item.startMin) / 60.0 * DayColumn.hourHeight)
          .clamp(20.0, DayColumn.hourHeight * 24);

      widgets.add(Positioned(
        top: top,
        left: left,
        width: laneWidth,
        height: height,
        child: _EventCard(
          event: item.event,
          onTap: widget.onEventTap != null
              ? () => widget.onEventTap!(item.event, widget.day)
              : null,
        ),
      ));
    }
    return widgets;
  }

  Widget _buildTimeIndicator(double totalWidth, double leftOffset) {
    final totalMinutes = _now.hour * 60 + _now.minute;
    final top = totalMinutes / 60.0 * DayColumn.hourHeight;
    return Positioned(
      top: top - 4,
      left: 0,
      width: totalWidth,
      height: 8,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(width: (leftOffset - 4).clamp(0.0, double.infinity)),
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: Color(0xFFFF453A),
              shape: BoxShape.circle,
            ),
          ),
          Expanded(
            child: Container(
              height: 1.5,
              color: const Color(0xFFFF453A),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Event card ───────────────────────────────────────────────────────────────

class _EventCard extends StatelessWidget {
  const _EventCard({required this.event, this.onTap});

  final DeviceCalendarEvent event;
  final VoidCallback? onTap;

  String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppThemeTokens.cardBorderRadius);
    final eventColor = event.calendarColor;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: eventColor.withValues(alpha: 0.12),
          borderRadius: radius,
          border: Border.all(
            color: eventColor.withValues(alpha: 0.35),
            width: 0.5,
          ),
        ),
        clipBehavior: Clip.hardEdge,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 3,
              decoration: BoxDecoration(
                color: eventColor,
                borderRadius: BorderRadius.only(
                  topLeft: radius.topLeft,
                  bottomLeft: radius.bottomLeft,
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final h = constraints.maxHeight.isFinite
                        ? constraints.maxHeight
                        : 999.0;
                    final showTitle = h >= 12;
                    final showTime = h >= 30;
                    final showLocation = h >= 44 && event.location != null;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (showTitle)
                          Text(
                            event.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppThemeTokens.titleColor,
                            ),
                          ),
                        if (showTime)
                          Text(
                            '${_fmt(event.start)} – ${_fmt(event.end)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              color: AppThemeTokens.secondaryTextColor,
                            ),
                          ),
                        if (showLocation)
                          Text(
                            event.location!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              color: AppThemeTokens.locationColor,
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
