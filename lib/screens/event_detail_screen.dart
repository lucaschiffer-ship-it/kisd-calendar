import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_theme.dart';
import '../services/calendar_service.dart';
import '../services/theme_service.dart';

void showEventDetail(
    BuildContext context, DeviceCalendarEvent event, DateTime date) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    builder: (_) => _EventDetailSheet(event: event, date: date),
  );
}

class _EventDetailSheet extends StatelessWidget {
  const _EventDetailSheet({required this.event, required this.date});

  final DeviceCalendarEvent event;
  final DateTime date;

  static const _kWeekdays = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday',
    'Friday', 'Saturday', 'Sunday',
  ];
  static const _kMonths = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  String _fmtTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        ThemeService.instance.currentColor,
        ThemeService.instance.glassEnabled,
      ]),
      builder: (context, _) => _buildSheet(context),
    );
  }

  Widget _buildSheet(BuildContext context) {
    final glass = ThemeService.instance.glassEnabled.value;
    final colorKey = ThemeService.instance.currentColor.value;
    const radius = BorderRadius.vertical(top: Radius.circular(20));

    final weekday = _kWeekdays[date.weekday - 1];
    final month = _kMonths[date.month - 1];
    final dateLabel = '$weekday, $month ${date.day}';
    final timeLabel = '${_fmtTime(event.start)} – ${_fmtTime(event.end)}';

    final content = SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppThemeTokens.secondaryTextColor.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    event.title,
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: AppThemeTokens.titleColor,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: AppThemeTokens.secondaryTextColor.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.close,
                      size: 15,
                      color: AppThemeTokens.secondaryTextColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '$dateLabel · $timeLabel',
              style: GoogleFonts.inter(
                fontSize: 14,
                color: AppThemeTokens.secondaryTextColor,
              ),
            ),
            if (event.calendarName.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: event.calendarColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: event.calendarColor.withValues(alpha: 0.3),
                    width: 0.5,
                  ),
                ),
                child: Text(
                  event.calendarName.toUpperCase(),
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.9,
                    color: event.calendarColor,
                  ),
                ),
              ),
            ],
            if (event.location != null) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.location_on_outlined,
                    size: 15,
                    color: AppThemeTokens.locationColor,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      event.location!,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        color: AppThemeTokens.locationColor,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );

    if (glass) {
      final bg = colorKey == 'dark'
          ? Colors.black.withValues(alpha: 0.64)
          : Colors.white.withValues(alpha: 0.70);
      return ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            decoration: BoxDecoration(color: bg, borderRadius: radius),
            child: content,
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: AppThemeTokens.cardBackground,
        borderRadius: radius,
        border: Border.all(color: AppThemeTokens.cardBorder, width: 0.5),
      ),
      child: content,
    );
  }
}
