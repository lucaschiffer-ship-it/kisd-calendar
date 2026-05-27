import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_theme.dart' as tokens;
import '../services/theme_service.dart';
import '../theme/app_theme.dart';
import '../widgets/day_column.dart';
import '../widgets/multi_day_view.dart';

// ─── Enums ────────────────────────────────────────────────────────────────────

enum _NavLevel { year, month, day }

enum _DayViewMode { singleDay, multiDay, list }

// ─── Screen ───────────────────────────────────────────────────────────────────

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  static const _deMonths = [
    'Januar', 'Februar', 'März', 'April', 'Mai', 'Juni',
    'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember',
  ];

  _NavLevel _navLevel = _NavLevel.day;
  _DayViewMode _dayViewMode = _DayViewMode.multiDay;

  late final DateTime _today;
  late int _displayedYear;
  late DateTime _displayedMonth;
  late DateTime _selectedDate;

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    _today = DateTime(n.year, n.month, n.day);
    _displayedYear = _today.year;
    _displayedMonth = DateTime(_today.year, _today.month);
    _selectedDate = _today;
  }

  void _goBack() {
    setState(() {
      switch (_navLevel) {
        case _NavLevel.month:
          _navLevel = _NavLevel.year;
        case _NavLevel.day:
          _navLevel = _NavLevel.month;
        case _NavLevel.year:
          break;
      }
    });
  }

  void _drillToMonth(DateTime month) {
    setState(() {
      _displayedMonth = month;
      _navLevel = _NavLevel.month;
    });
  }

  void _drillToDay(DateTime day) {
    setState(() {
      _selectedDate = day;
      _navLevel = _NavLevel.day;
    });
  }

  String _scopeLabel() => switch (_navLevel) {
        _NavLevel.year => '$_displayedYear',
        _NavLevel.month => _deMonths[_displayedMonth.month - 1],
        _NavLevel.day =>
          '${_deMonths[_selectedDate.month - 1]} ${_selectedDate.day}',
      };

  String _backLabel() => switch (_navLevel) {
        _NavLevel.month => '$_displayedYear',
        _NavLevel.day => _deMonths[_displayedMonth.month - 1],
        _NavLevel.year => '',
      };

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AnimatedBuilder(
      animation: Listenable.merge([
        ThemeService.instance.currentColor,
        ThemeService.instance.currentStyle,
        ThemeService.instance.glassEnabled,
      ]),
      builder: (context, _) => Column(
        children: [
          _buildHeader(context),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  // ── Header ───────────────────────────────────────────────────────────────────

  Widget _buildHeader(BuildContext context) {
    final glass = ThemeService.instance.glassEnabled.value;
    final colorKey = ThemeService.instance.currentColor.value;
    final glassBg = colorKey == 'dark'
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.white.withValues(alpha: 0.50);

    final content = SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
        child: Row(
          children: [
            // Back button slot
            if (_navLevel != _NavLevel.year)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _goBack,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(CupertinoIcons.chevron_back,
                          color: AppColors.accent, size: 18),
                      const SizedBox(width: 2),
                      Text(
                        _backLabel(),
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w400,
                          color: AppColors.accent,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              const SizedBox(width: 44),

            // Scope label
            Expanded(
              child: Text(
                _scopeLabel(),
                textAlign: TextAlign.center,
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: tokens.AppThemeTokens.titleColor,
                  letterSpacing: -0.3,
                ),
              ),
            ),

            // View switcher (day level only)
            if (_navLevel == _NavLevel.day)
              _ViewSwitcher(
                current: _dayViewMode,
                onChanged: (m) => setState(() => _dayViewMode = m),
              )
            else
              const SizedBox(width: 44),
          ],
        ),
      ),
    );

    if (glass) {
      return ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            decoration: BoxDecoration(
              color: glassBg,
              border: const Border(
                bottom: BorderSide(color: Color(0x1AFFFFFF), width: 0.5),
              ),
            ),
            child: content,
          ),
        ),
      );
    }
    return Container(
      color: tokens.AppThemeTokens.backgroundColor,
      child: content,
    );
  }

  // ── Body ─────────────────────────────────────────────────────────────────────

  Widget _buildBody() => switch (_navLevel) {
        _NavLevel.year => _DrillPlaceholder(
            label: 'Year View (Phase 5)',
            hint: 'Tap to open current month',
            onTap: () => _drillToMonth(DateTime(_today.year, _today.month)),
          ),
        _NavLevel.month => _DrillPlaceholder(
            label: 'Month View (Phase 4)',
            hint: 'Tap to open today',
            onTap: () => _drillToDay(_today),
          ),
        _NavLevel.day => switch (_dayViewMode) {
            _DayViewMode.singleDay => DayColumn(day: _selectedDate),
            _DayViewMode.multiDay => const MultiDayView(),
            _DayViewMode.list => const _Placeholder(label: 'List View'),
          },
      };
}

// ─── View switcher dropdown ───────────────────────────────────────────────────

class _ViewSwitcher extends StatelessWidget {
  const _ViewSwitcher({required this.current, required this.onChanged});

  final _DayViewMode current;
  final ValueChanged<_DayViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      child: Center(
        child: PopupMenuButton<_DayViewMode>(
          onSelected: onChanged,
          icon: Icon(
            CupertinoIcons.calendar,
            size: 20,
            color: tokens.AppThemeTokens.secondaryTextColor,
          ),
          color: tokens.AppThemeTokens.cardBackground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
                color: tokens.AppThemeTokens.cardBorder, width: 0.5),
          ),
          itemBuilder: (_) => [
            _menuItem(_DayViewMode.singleDay, 'Single Day'),
            _menuItem(_DayViewMode.multiDay, 'Multi Day'),
            _menuItem(_DayViewMode.list, 'List'),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<_DayViewMode> _menuItem(_DayViewMode mode, String label) {
    final isActive = current == mode;
    return PopupMenuItem<_DayViewMode>(
      value: mode,
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: isActive
                ? Icon(Icons.check,
                    size: 16, color: AppColors.accent)
                : null,
          ),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 15,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
              color: tokens.AppThemeTokens.titleColor,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Placeholder widgets ──────────────────────────────────────────────────────

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 17,
          fontWeight: FontWeight.w500,
          color: tokens.AppThemeTokens.secondaryTextColor,
        ),
      ),
    );
  }
}

class _DrillPlaceholder extends StatelessWidget {
  const _DrillPlaceholder({
    required this.label,
    required this.hint,
    required this.onTap,
  });

  final String label;
  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 17,
                fontWeight: FontWeight.w500,
                color: tokens.AppThemeTokens.secondaryTextColor,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              hint,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: AppColors.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
