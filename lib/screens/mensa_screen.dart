import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_theme.dart' as tokens;
import '../services/mensa_service.dart';
import '../services/theme_service.dart';
import '../theme/tokens.dart';
import 'settings_screen.dart';

class MensaScreen extends StatefulWidget {
  const MensaScreen({super.key});

  @override
  State<MensaScreen> createState() => _MensaScreenState();
}

class _MensaScreenState extends State<MensaScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  static const _weekdays = [
    'Montag', 'Dienstag', 'Mittwoch', 'Donnerstag',
    'Freitag', 'Samstag', 'Sonntag',
  ];
  static const _months = [
    'Januar', 'Februar', 'März', 'April', 'Mai', 'Juni',
    'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember',
  ];

  DateTime _selectedDate = DateTime.now();
  List<MensaMeal> _meals = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchMeals();
  }

  Future<void> _fetchMeals() async {
    setState(() { _loading = true; _error = null; });
    try {
      final meals = await mensaService.fetchMeals(_selectedDate);
      if (mounted) setState(() { _meals = meals; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  void _changeDay(int delta) {
    setState(() => _selectedDate = _selectedDate.add(Duration(days: delta)));
    _fetchMeals();
  }

  String _formatDate(DateTime d) {
    final weekday = _weekdays[d.weekday - 1];
    final month   = _months[d.month - 1];
    return '$weekday, ${d.day}. $month';
  }

  Map<String, List<MensaMeal>> _groupByCategory(List<MensaMeal> meals) {
    final map = <String, List<MensaMeal>>{};
    for (final m in meals) {
      map.putIfAbsent(m.category, () => []).add(m);
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ValueListenableBuilder<AppColorScheme>(
      valueListenable: AppColorScheme.currentListenable,
      builder: (context, s, _) => AnimatedBuilder(
        animation: ThemeService.instance.glassEnabled,
        builder: (context, _) => _buildContent(s),
      ),
    );
  }

  Widget _buildContent(AppColorScheme s) {
    final view    = View.of(context);
    final statusH = view.viewPadding.top / view.devicePixelRatio;
    const dateNavH = 52.0;
    final headerH  = statusH + kToolbarHeight + dateNavH;

    final glass   = ThemeService.instance.glassEnabled.value;
    final glassBg = s.glassHeaderTint;

    final headerBody = Container(
      decoration: glass
          ? BoxDecoration(
              color: glassBg,
              border: const Border(
                bottom: BorderSide(color: AppGlass.dividerColor, width: 0.5),
              ),
            )
          : BoxDecoration(color: tokens.AppThemeTokens.backgroundColor),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: statusH),
          // Title row
          SizedBox(
            height: kToolbarHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  Expanded(
                    child: Center(
                      child: Text(
                        'Mensa',
                        style: AppTextStyles.navTitle(
                            color: tokens.AppThemeTokens.titleColor),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(CupertinoIcons.settings,
                        color: tokens.AppThemeTokens.navBarIcon),
                    onPressed: () => Navigator.push<void>(
                      context,
                      CupertinoPageRoute(
                          builder: (_) => const SettingsScreen()),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Date navigation row
          SizedBox(
            height: dateNavH,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(CupertinoIcons.chevron_left,
                        color: tokens.AppThemeTokens.navBarIcon, size: 18),
                    onPressed: () => _changeDay(-1),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        _formatDate(_selectedDate),
                        style: AppTextStyles.body(
                            color: tokens.AppThemeTokens.titleColor)
                            .copyWith(fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(CupertinoIcons.chevron_right,
                        color: tokens.AppThemeTokens.navBarIcon, size: 18),
                    onPressed: () => _changeDay(1),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    final header = glass
        ? ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(
                  sigmaX: AppGlass.headerBlur, sigmaY: AppGlass.headerBlur),
              child: headerBody,
            ),
          )
        : headerBody;

    Widget body;
    if (_loading) {
      body = Center(
        child: CircularProgressIndicator(color: s.accent),
      );
    } else if (_error != null) {
      body = _ErrorState(error: _error!, onRetry: _fetchMeals);
    } else if (_meals.isEmpty) {
      body = const _ClosedState();
    } else {
      final grouped = _groupByCategory(_meals);
      body = RefreshIndicator(
        color: s.accent,
        onRefresh: () {
          mensaService.clearCacheForDate(_selectedDate);
          return _fetchMeals();
        },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(padding: EdgeInsets.only(top: headerH)),
            for (final entry in grouped.entries) ...[
              SliverToBoxAdapter(child: _CategoryHeader(label: entry.key)),
              SliverList.builder(
                itemCount: entry.value.length,
                itemBuilder: (_, i) => _MealRow(meal: entry.value[i]),
              ),
            ],
            const SliverPadding(padding: EdgeInsets.only(bottom: 48)),
          ],
        ),
      );
    }

    if (_loading || _error != null || _meals.isEmpty) {
      return Stack(
        children: [
          Column(
            children: [SizedBox(height: headerH), Expanded(child: body)],
          ),
          Positioned(top: 0, left: 0, right: 0, child: header),
        ],
      );
    }

    return Stack(
      children: [
        body,
        Positioned(top: 0, left: 0, right: 0, child: header),
      ],
    );
  }
}

// ── Category header ───────────────────────────────────────────────────────────

class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        label.toUpperCase(),
        style: AppTextStyles.sectionLabel(
            color: tokens.AppThemeTokens.eventAccent),
      ),
    );
  }
}

// ── Meal row ──────────────────────────────────────────────────────────────────

class _MealRow extends StatelessWidget {
  const _MealRow({required this.meal});
  final MensaMeal meal;

  // Food-attribute semantic colors — mode-independent constants.
  static const Color _veganColor = Color(0xFF30D158); // matches AppColorScheme.success
  static const Color _vegColor   = Color(0xFF30D158);
  static const Color _porkColor  = Color(0xFFFF453A); // matches AppColorScheme.danger
  static const Color _beefColor  = Color(0xFF8B4513); // beef tag color, mode-independent

  Color _tagColor(String note) {
    final n = note.toLowerCase();
    if (n == 'vegan') return _veganColor;
    if (n == 'vegetarisch' || n == 'veggie') return _vegColor;
    if (n.contains('schwein') || n.contains('pork')) return _porkColor;
    if (n.contains('rind') || n.contains('beef')) return _beefColor;
    return tokens.AppThemeTokens.secondaryTextColor;
  }

  String _formatPrice(double? price) {
    if (price == null) return '';
    return '${price.toStringAsFixed(2).replaceAll('.', ',')} €';
  }

  @override
  Widget build(BuildContext context) {
    final priceStr    = _formatPrice(meal.priceStudents);
    final notesToShow = meal.notes.where((n) => n.isNotEmpty).toList();

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: tokens.AppThemeTokens.secondaryTextColor
                .withValues(alpha: 0.1),
            width: 0.5,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    meal.name,
                    style: AppTextStyles.body(
                            color: tokens.AppThemeTokens.titleColor)
                        .copyWith(height: 1.4),
                  ),
                  if (notesToShow.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: notesToShow
                          .map((n) => _NoteTag(label: n, color: _tagColor(n)))
                          .toList(),
                    ),
                  ],
                ],
              ),
            ),
            if (priceStr.isNotEmpty) ...[
              const SizedBox(width: 12),
              Text(
                priceStr,
                // Price uses SpaceGrotesk to match the numeric display style
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: tokens.AppThemeTokens.eventAccent,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Note tag ──────────────────────────────────────────────────────────────────

class _NoteTag extends StatelessWidget {
  const _NoteTag({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppRadius.tag),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 0.5),
      ),
      child: Text(
        label,
        style: AppTextStyles.tabBarLabel(color: color)
            .copyWith(letterSpacing: 0, fontWeight: FontWeight.w500),
      ),
    );
  }
}

// ── Closed state ──────────────────────────────────────────────────────────────

class _ClosedState extends StatelessWidget {
  const _ClosedState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.restaurant,
              size: 52, color: tokens.AppThemeTokens.secondaryTextColor),
          const SizedBox(height: 16),
          // Empty-state heading: SpaceGrotesk 18 w600, not in canonical scale
          Text(
            'Mensa geschlossen',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: tokens.AppThemeTokens.secondaryTextColor,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Error state ───────────────────────────────────────────────────────────────

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(CupertinoIcons.exclamationmark_circle,
                size: 52, color: tokens.AppThemeTokens.secondaryTextColor),
            const SizedBox(height: 16),
            // Empty-state heading: SpaceGrotesk 18 w600, not in canonical scale
            Text(
              'Menüplan nicht verfügbar',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: tokens.AppThemeTokens.titleColor,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style: AppTextStyles.bodySmall(
                  color: tokens.AppThemeTokens.secondaryTextColor),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onRetry,
              style: FilledButton.styleFrom(
                backgroundColor: s.accent,
                foregroundColor: Colors.white, // on accent — intentionally white
                shape: const StadiumBorder(),
              ),
              icon: const Icon(Icons.refresh),
              label: const Text('Erneut versuchen'),
            ),
          ],
        ),
      ),
    );
  }
}
