import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_theme.dart';
import '../services/theme_service.dart';
import 'mini_month.dart';

// ─── Layout constants ─────────────────────────────────────────────────────────

const double _kYearLabelH  = 28.0;
const double _kRowGap       = 8.0;
const double _kYearPad      = 6.0;  // top + bottom per year section
const double _kHorizPad     = 14.0; // outer horizontal padding
const double _kColGap       = 8.0;  // gap between mini-month columns

// Total height of one year section (deterministic — 3×4 fixed grid).
const double kYearSectionH =
    _kYearPad +
    _kYearLabelH +
    4 * kMiniMonthHeight +  // 4 rows of mini-months
    3 * _kRowGap +          // 3 gaps between the rows
    _kYearPad;

// ─── YearView ─────────────────────────────────────────────────────────────────

class YearView extends StatefulWidget {
  const YearView({
    super.key,
    required this.today,
    required this.initialYear,
    required this.onMonthTapped,
    this.onYearChanged,
  });

  final DateTime today;
  final int initialYear;
  final void Function(DateTime month) onMonthTapped;
  final void Function(int year)? onYearChanged;

  @override
  State<YearView> createState() => _YearViewState();
}

class _YearViewState extends State<YearView> {
  // Show 5 years back and 5 years forward from today's year.
  late final int _startYear;
  static const int _totalYears = 11;

  late final ScrollController _scrollController;
  int _visibleYearIndex = -1;

  @override
  void initState() {
    super.initState();
    _startYear = widget.today.year - 5;
    final initialIndex =
        (widget.initialYear - _startYear).clamp(0, _totalYears - 1);
    final initialOffset = initialIndex * kYearSectionH;
    _scrollController =
        ScrollController(initialScrollOffset: initialOffset.clamp(0.0, double.infinity));
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final index =
        (_scrollController.offset / kYearSectionH).floor().clamp(0, _totalYears - 1);
    if (index != _visibleYearIndex) {
      _visibleYearIndex = index;
      widget.onYearChanged?.call(_startYear + index);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        ThemeService.instance.currentColor,
        ThemeService.instance.glassEnabled,
      ]),
      builder: (context, _) => ListView.builder(
        controller: _scrollController,
        itemCount: _totalYears,
        itemBuilder: (context, index) => _YearSection(
          year: _startYear + index,
          today: widget.today,
          onMonthTapped: widget.onMonthTapped,
        ),
      ),
    );
  }
}

// ─── Year section ─────────────────────────────────────────────────────────────

class _YearSection extends StatelessWidget {
  const _YearSection({
    required this.year,
    required this.today,
    required this.onMonthTapped,
  });

  final int year;
  final DateTime today;
  final void Function(DateTime month) onMonthTapped;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kYearSectionH,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: _kHorizPad, vertical: _kYearPad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Year label
            SizedBox(
              height: _kYearLabelH,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '$year',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppThemeTokens.titleColor,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
            ),
            // 4 rows × 3 months — explicit heights avoid Expanded/Padding conflicts
            for (int row = 0; row < 4; row++) ...[
              SizedBox(
                height: kMiniMonthHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: List.generate(3, (col) {
                    final monthIndex = row * 3 + col + 1; // 1–12
                    return Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                            right: col < 2 ? _kColGap : 0),
                        child: MiniMonth(
                          year: year,
                          month: monthIndex,
                          today: today,
                          onTap: () =>
                              onMonthTapped(DateTime(year, monthIndex)),
                        ),
                      ),
                    );
                  }),
                ),
              ),
              if (row < 3) const SizedBox(height: _kRowGap),
            ],
          ],
        ),
      ),
    );
  }
}
