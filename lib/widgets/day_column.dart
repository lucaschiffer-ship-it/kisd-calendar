import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_theme.dart';
import '../models/app_event.dart';
import '../screens/store_event_sheets.dart';
import '../services/calendar_service.dart';
import '../services/event_store.dart';
import '../services/theme_service.dart';
import 'event_edit_layer.dart';

// ─── Overlap layout helpers ───────────────────────────────────────────────────

class _EvtItem {
  _EvtItem({
    this.event,
    this.occ,
    required this.startMin,
    required this.endMin,
  });
  final DeviceCalendarEvent? event; // device-calendar event …
  final StoreOccurrence? occ; //       … or interactive app-store occurrence
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
    this.editController,
    this.hourHeight = defaultHourHeight,
  });

  final DateTime day;

  /// Called with the tapped event and the day it belongs to.
  final void Function(DeviceCalendarEvent, DateTime)? onEventTap;
  final bool showHourLabels;

  /// When set, app-store occurrences render as interactive blocks: tap for the
  /// detail sheet, 400 ms long-press to pick up (move/resize via the edit
  /// layer), and long-press on empty space creates a draft event.
  final EventEditController? editController;

  /// When true, omits the internal SingleChildScrollView — the parent owns scrolling.
  final bool embedded;

  /// Height in logical pixels covered by the glass header overlay. Used to
  /// position 8:00 at the first visible row below the header on initial load.
  final double topInset;

  /// Height of one hour — live, the timeline pinch-zooms it.
  final double hourHeight;

  // Apple Calendar's day view, measured on the iOS 26.4 simulator: 50 pt per
  // hour by default, pinch-zoomable from ~35.5 to 90 with a hard stop at both
  // ends (no rubber band).
  static const double defaultHourHeight = 50.0;
  static const double minHourHeight = 35.5;
  static const double maxHourHeight = 90.0;
  static const double labelWidth = 52.0;

  @override
  State<DayColumn> createState() => _DayColumnState();
}

class _DayColumnState extends State<DayColumn> {
  ScrollController? _scrollController;
  List<DeviceCalendarEvent> _events = [];
  List<StoreOccurrence> _occs = [];
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
    CalendarService.instance.writeRevision.addListener(_onWriteRevisionChanged);
    EventStore.instance.revision.addListener(_onStoreChanged);
    widget.editController?.addListener(_onEditControllerChanged);
    if (EventStore.instance.isLoaded) {
      _occs = EventStore.instance.occurrencesForDay(widget.day);
    }
    EventStore.instance.ensureLoaded().then((_) {
      if (mounted) _loadOccs();
    });
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
    if (old.editController != widget.editController) {
      old.editController?.removeListener(_onEditControllerChanged);
      widget.editController?.addListener(_onEditControllerChanged);
    }
    if (old.day != widget.day) {
      // Show cached events immediately while the async refresh runs.
      setState(() =>
          _events = CalendarService.instance.getCachedEvents(widget.day) ?? []);
      _loadEvents();
      _loadOccs();
      if (!widget.embedded) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToFocus());
      }
    }
  }

  @override
  void dispose() {
    CalendarService.instance.writeRevision.removeListener(_onWriteRevisionChanged);
    EventStore.instance.revision.removeListener(_onStoreChanged);
    widget.editController?.removeListener(_onEditControllerChanged);
    _timer.cancel();
    _scrollController?.dispose();
    super.dispose();
  }

  void _onWriteRevisionChanged() => _loadEvents();

  void _onStoreChanged() => _loadOccs();

  // Active-key changes hide/reveal the occurrence held by the edit layer.
  void _onEditControllerChanged() {
    if (mounted) setState(() {});
  }

  void _loadOccs() {
    if (!mounted || !EventStore.instance.isLoaded) return;
    setState(() => _occs = EventStore.instance.occurrencesForDay(widget.day));
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
    final target = (kStartHour * widget.hourHeight - widget.topInset)
        .clamp(0.0, _scrollController!.position.maxScrollExtent);
    _scrollController!.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        ThemeService.instance.currentColor,
        ThemeService.instance.glassEnabled,
      ]),
      builder: (context, _) => _buildContent(),
    );
  }

  Widget _buildContent() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalHeight = widget.hourHeight * 24;
        final leftOffset = widget.showHourLabels ? DayColumn.labelWidth : 0.0;
        final eventAreaWidth = constraints.maxWidth - leftOffset;

        final stack = SizedBox(
          height: totalHeight,
          width: constraints.maxWidth,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              _buildCreateAwareGrid(),
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
                  color: AppThemeTokens.dividerColor,
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

  /// Grid, plus (when interactive) a 400 ms long-press on empty space that
  /// spawns a create draft and keeps dragging it until release. Event cards
  /// sit above the grid in the stack, so this only fires on empty slots.
  Widget _buildCreateAwareGrid() {
    final ctrl = widget.editController;
    if (ctrl == null) return _buildGrid();
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
          () => LongPressGestureRecognizer(
              duration: const Duration(milliseconds: 400)),
          (g) {
            g.onLongPressStart =
                (d) => ctrl.requestCreate(widget.day, d.globalPosition);
            g.onLongPressMoveUpdate =
                (d) => ctrl.pickupMove(d.globalPosition);
            g.onLongPressEnd = (_) => ctrl.pickupEnd();
            g.onLongPressCancel = ctrl.pickupCancel;
          },
        ),
      },
      child: _buildGrid(),
    );
  }

  // One painter instead of 24 bordered rows: a pinch changes the hour height
  // every frame, and repainting lines is far cheaper than relaying out rows.
  Widget _buildGrid() {
    final leftOffset = widget.showHourLabels ? DayColumn.labelWidth : 0.0;
    final grid = SizedBox.expand(
      child: CustomPaint(
        painter: _HourGridPainter(
          hourHeight: widget.hourHeight,
          left: leftOffset,
          color: AppThemeTokens.dividerColor,
        ),
      ),
    );
    if (!widget.showHourLabels) return grid;
    final labelStyle = GoogleFonts.inter(
      fontSize: 11,
      fontWeight: FontWeight.w400,
      color: AppThemeTokens.secondaryTextColor,
    );
    return Stack(
      children: [
        grid,
        for (var hour = 0; hour < 24; hour++)
          Positioned(
            top: hour * widget.hourHeight + 3,
            left: 0,
            width: DayColumn.labelWidth,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                '${hour.toString().padLeft(2, '0')}:00',
                textAlign: TextAlign.right,
                style: labelStyle,
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _buildEventCards(double eventAreaWidth, double leftOffset) {
    // Device events, minus the mirrored "KISD" calendar — those events are
    // app-store projections and render as interactive store blocks instead.
    final deviceItems = _events
        .where((e) => !e.allDay && e.calendarName != 'KISD')
        .map((e) {
      final startMin = e.start.hour * 60 + e.start.minute;
      // An end before the start means the event crosses midnight
      // (e.g. 16:30 – 00:00) — render it to the end of this day.
      var rawEnd = e.end.hour * 60 + e.end.minute;
      if (rawEnd < startMin) rawEnd = 24 * 60;
      final endMin = rawEnd.clamp(startMin + 15, 24 * 60);
      return _EvtItem(event: e, startMin: startMin, endMin: endMin);
    });

    // App-store occurrences; the one held by the edit layer renders invisibly
    // (it must stay in the tree — removing it would dispose its long-press
    // recognizer mid-gesture and kill the drag).
    final activeKey = widget.editController?.activeKey;
    final occItems = _occs.map((o) {
      final startMin = o.start.hour * 60 + o.start.minute;
      // Same midnight-crossing handling as device events above.
      var rawEnd = o.end.hour * 60 + o.end.minute;
      if (rawEnd < startMin) rawEnd = 24 * 60;
      final endMin = rawEnd.clamp(startMin + 15, 24 * 60);
      return _EvtItem(occ: o, startMin: startMin, endMin: endMin);
    });

    final items = [...deviceItems, ...occItems]
      ..sort((a, b) => a.startMin.compareTo(b.startMin));
    if (items.isEmpty) return const [];

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
      final top = item.startMin / 60.0 * widget.hourHeight;
      final height = ((item.endMin - item.startMin) / 60.0 * widget.hourHeight)
          .clamp(20.0, widget.hourHeight * 24);

      final occ = item.occ;
      final hidden = occ != null && occ.key == activeKey;
      widgets.add(Positioned(
        key: occ != null ? ValueKey('occ-${occ.key}') : null,
        top: top,
        left: left,
        width: laneWidth,
        height: height,
        child: occ != null
            ? Opacity(
                opacity: hidden ? 0 : 1,
                child: IgnorePointer(
                  ignoring: hidden,
                  child: _StoreEventCard(
                      occ: occ, controller: widget.editController),
                ),
              )
            : _EventCard(
                event: item.event!,
                onTap: widget.onEventTap != null
                    ? () => widget.onEventTap!(item.event!, widget.day)
                    : null,
              ),
      ));
    }
    return widgets;
  }

  Widget _buildTimeIndicator(double totalWidth, double leftOffset) {
    final totalMinutes = _now.hour * 60 + _now.minute;
    final top = totalMinutes / 60.0 * widget.hourHeight;
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

// ─── Hour grid ────────────────────────────────────────────────────────────────

/// The hour lines, 00:00 through the closing 24:00 line (Apple draws one too).
class _HourGridPainter extends CustomPainter {
  _HourGridPainter({
    required this.hourHeight,
    required this.left,
    required this.color,
  });

  final double hourHeight;
  final double left;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.5;
    for (var hour = 0; hour <= 24; hour++) {
      // Inside the box: the top line hangs below 0, the closing one sits
      // above the bottom edge (the timeline clips the columns there).
      final y = hour < 24 ? hour * hourHeight + 0.25 : size.height - 0.25;
      canvas.drawLine(Offset(left, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_HourGridPainter old) =>
      old.hourHeight != hourHeight || old.left != left || old.color != color;
}

// ─── Card text ────────────────────────────────────────────────────────────────

/// A card's title, time and location lines. The time and location lines fade
/// in over the [_kLineFade] pt below the heights they used to appear at (30,
/// 44) instead of switching on there, so a card growing under a pinch reveals
/// them rather than popping them in on one frame. Fully shown from those
/// heights on, as before; a card resting inside the band shows the line faint.
const double _kLineFade = 10.0;

Widget _cardText({
  required String title,
  required String time,
  String? location,
}) {
  return LayoutBuilder(
    builder: (context, constraints) {
      final h = constraints.maxHeight.isFinite ? constraints.maxHeight : 999.0;
      // 0 → 1 across the fade band ending at [full].
      double fade(double full) =>
          ((h - (full - _kLineFade)) / _kLineFade).clamp(0.0, 1.0);
      final timeAlpha = fade(30);
      final locationAlpha =
          location != null && location.isNotEmpty ? fade(44) : 0.0;
      final secondary = AppThemeTokens.secondaryTextColor;
      final locationColor = AppThemeTokens.locationColor;
      // Unbounded height: a half-revealed line is cut by the card's clip
      // instead of overflowing the column.
      return OverflowBox(
        alignment: Alignment.topLeft,
        minHeight: 0,
        maxHeight: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (h >= 12)
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppThemeTokens.titleColor,
                ),
              ),
            // Alpha on the colour, not an Opacity widget: no layer per card.
            if (timeAlpha > 0)
              Text(
                time,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 10,
                  color: secondary.withValues(alpha: secondary.a * timeAlpha),
                ),
              ),
            if (locationAlpha > 0)
              Text(
                location!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 10,
                  color: locationColor.withValues(
                      alpha: locationColor.a * locationAlpha),
                ),
              ),
          ],
        ),
      );
    },
  );
}

// ─── Store event card (interactive app-store occurrence) ─────────────────────

class _StoreEventCard extends StatelessWidget {
  const _StoreEventCard({required this.occ, this.controller});

  final StoreOccurrence occ;
  final EventEditController? controller;

  String _fmt(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final ctrl = controller;
    final radius = BorderRadius.circular(AppThemeTokens.cardBorderRadius);
    final color = occ.collection.color;

    final card = Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: radius,
        border: Border.all(
          color: color.withValues(alpha: 0.35),
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
              color: color,
              borderRadius: BorderRadius.only(
                topLeft: radius.topLeft,
                bottomLeft: radius.bottomLeft,
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
              child: _cardText(
                title: occ.event.title,
                time: '${_fmt(occ.start)} – ${_fmt(occ.end)}',
                location: occ.event.location,
              ),
            ),
          ),
        ],
      ),
    );

    if (ctrl == null) {
      return GestureDetector(
        onTap: () => showStoreEventSheet(context, occ),
        child: card,
      );
    }

    // Tap → event sheet; 400 ms long-press → pick up. The recognizer keeps
    // ownership of the pointer, so the drag may cross day columns freely.
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
          () => TapGestureRecognizer(),
          (g) => g.onTap = () => showStoreEventSheet(context, occ),
        ),
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
          () => LongPressGestureRecognizer(
              duration: const Duration(milliseconds: 400)),
          (g) {
            g.onLongPressStart = (d) => ctrl.pickup(occ, d.globalPosition);
            g.onLongPressMoveUpdate = (d) => ctrl.pickupMove(d.globalPosition);
            g.onLongPressEnd = (_) => ctrl.pickupEnd();
            g.onLongPressCancel = ctrl.pickupCancel;
          },
        ),
      },
      child: card,
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
                child: _cardText(
                  title: event.title,
                  time: '${_fmt(event.start)} – ${_fmt(event.end)}',
                  location: event.location,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
