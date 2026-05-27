import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_theme.dart';
import '../services/calendar_service.dart';
import '../services/theme_service.dart';

class DayColumn extends StatefulWidget {
  const DayColumn({
    super.key,
    required this.day,
    this.onEventTap,
  });

  final DateTime day;
  final void Function(DeviceCalendarEvent)? onEventTap;

  @override
  State<DayColumn> createState() => _DayColumnState();
}

class _DayColumnState extends State<DayColumn> {
  static const double _hourHeight = 60.0;
  static const double _labelWidth = 52.0;

  final _scrollController = ScrollController();
  List<DeviceCalendarEvent> _events = [];
  DateTime _now = DateTime.now();
  late Timer _timer;

  @override
  void initState() {
    super.initState();
    _loadEvents();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToFocus());
  }

  @override
  void didUpdateWidget(DayColumn old) {
    super.didUpdateWidget(old);
    if (old.day != widget.day) {
      setState(() => _events = []);
      _loadEvents();
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToFocus());
    }
  }

  @override
  void dispose() {
    _timer.cancel();
    _scrollController.dispose();
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
    if (!_scrollController.hasClients) return;
    final focusHour = _isToday ? _now.hour + _now.minute / 60.0 : 8.0;
    final viewportHeight = _scrollController.position.viewportDimension;
    final target = focusHour * _hourHeight - viewportHeight / 2;
    _scrollController.jumpTo(
      target.clamp(0.0, _scrollController.position.maxScrollExtent),
    );
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
        final totalHeight = _hourHeight * 24;
        final eventAreaWidth = constraints.maxWidth - _labelWidth;
        return SingleChildScrollView(
          controller: _scrollController,
          child: SizedBox(
            height: totalHeight,
            width: constraints.maxWidth,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                _buildGrid(),
                ..._buildEventCards(eventAreaWidth),
                if (_isToday) _buildTimeIndicator(constraints.maxWidth),
              ],
            ),
          ),
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
          height: _hourHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: _labelWidth,
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

  List<Widget> _buildEventCards(double eventAreaWidth) {
    return _events.map((event) {
      final startMin = event.start.hour * 60 + event.start.minute;
      final endMin = event.end.hour * 60 + event.end.minute;
      final durationMin = (endMin - startMin).clamp(15, 24 * 60).toDouble();
      final top = startMin / 60.0 * _hourHeight;
      final height = (durationMin / 60.0 * _hourHeight).clamp(20.0, _hourHeight * 24);

      return Positioned(
        top: top,
        left: _labelWidth + 2,
        width: eventAreaWidth - 4,
        height: height,
        child: _EventCard(
          event: event,
          onTap: widget.onEventTap != null ? () => widget.onEventTap!(event) : null,
        ),
      );
    }).toList();
  }

  Widget _buildTimeIndicator(double totalWidth) {
    final totalMinutes = _now.hour * 60 + _now.minute;
    final top = totalMinutes / 60.0 * _hourHeight;
    return Positioned(
      top: top - 4,
      left: 0,
      width: totalWidth,
      height: 8,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(width: _labelWidth - 4),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      event.title,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppThemeTokens.titleColor,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${_fmt(event.start)} – ${_fmt(event.end)}',
                      style: GoogleFonts.inter(
                        fontSize: 10,
                        color: AppThemeTokens.secondaryTextColor,
                      ),
                      maxLines: 1,
                    ),
                    if (event.location != null)
                      Text(
                        event.location!,
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          color: AppThemeTokens.locationColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
