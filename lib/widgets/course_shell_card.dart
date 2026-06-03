import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/app_theme.dart' as tokens;
import '../models/course_shell.dart';
import '../services/spaces_browser.dart';
import '../services/theme_service.dart';
import '../theme/app_theme.dart';

// ─── sizing constants used by both the page and the menu ─────────────────────
const double _kMenuWidth = 240.0;
const double _kItemHeight = 44.0;

// ─── shared formatting helpers ────────────────────────────────────────────────

String _formatMeetingTimes(List<MeetingTime> meetingTimes) =>
    meetingTimes
        .map((m) =>
            '${m.weekday.label.toUpperCase()}  '
            '${CourseShellCard.fmtTime(m.startTime)} – '
            '${CourseShellCard.fmtTime(m.endTime)}')
        .join('  ·  ');

// ─────────────────────────────────────────────────────────────────────────────

class CourseShellCard extends StatefulWidget {
  const CourseShellCard({
    super.key,
    required this.shell,
    required this.onEdit,
    required this.onDelete,
    this.onFavouriteChanged,
  });

  final CourseShell shell;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final void Function(bool isFavourite)? onFavouriteChanged;

  static String fmtTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  State<CourseShellCard> createState() => _CourseShellCardState();
}

class _CourseShellCardState extends State<CourseShellCard>
    with SingleTickerProviderStateMixin {
  late bool _liked;
  bool _pressing = false;
  bool _isExpanded = false;
  final GlobalKey _cardKey = GlobalKey();

  // Heart bounce animation
  late final AnimationController _heartCtrl;
  late final Animation<double> _heartScale;

  @override
  void initState() {
    super.initState();
    _liked = widget.shell.isFavourite;
    _heartCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
      reverseDuration: const Duration(milliseconds: 110),
    );
    _heartScale = Tween<double>(begin: 1.0, end: 1.40).animate(
      CurvedAnimation(parent: _heartCtrl, curve: Curves.easeOut),
    );
  }

  @override
  void didUpdateWidget(CourseShellCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shell.isFavourite != widget.shell.isFavourite) {
      _liked = widget.shell.isFavourite;
    }
  }

  @override
  void dispose() {
    _heartCtrl.dispose();
    super.dispose();
  }

  Future<void> _toggleLike() async {
    final next = !_liked;
    setState(() => _liked = next);
    _heartCtrl.forward(from: 0.0).then((_) => _heartCtrl.reverse());
    widget.onFavouriteChanged?.call(next);
  }

  String get _allMeetingsText => _formatMeetingTimes(widget.shell.meetingTimes);

  void _openPrimary() {
    if (widget.shell.links.isEmpty) return;
    SpacesBrowser.open(widget.shell.links.first.url);
  }

  // ignore: unused_element — kept for Stage 2 repurposing
  void _showContextMenu(BuildContext context, Offset tapPosition) {
    final shell = widget.shell;
    // Capture the card's context before the dialog opens so _showInfoSheet
    // can use it after the dialog is popped.
    final cardContext = context;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: '',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 230),
      pageBuilder: (ctx, anim, _) => _GlassMenuPage(
        shell: shell,
        tapPosition: tapPosition,
        anim: anim,
        onInfo: () {
          Navigator.of(ctx).pop();
          _showInfoSheet(cardContext);
        },
        onEdit: () {
          Navigator.of(ctx).pop();
          widget.onEdit();
        },
        onDelete: () {
          Navigator.of(ctx).pop();
          widget.onDelete();
        },
      ),
    );
  }

  Future<void> _openExpandedOverlay(
      BuildContext context, CourseShell shell) async {
    final renderBox =
        _cardKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final originRect =
        renderBox.localToGlobal(Offset.zero) & renderBox.size;

    HapticFeedback.mediumImpact();
    setState(() => _isExpanded = true);

    await Navigator.of(context).push(PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      barrierLabel: 'expanded card',
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: Duration.zero,
      transitionsBuilder:
          (context, animation, secondaryAnimation, child) => child,
      pageBuilder: (ctx, animation, secondaryAnimation) =>
          _ExpandedCardOverlay(
        shell: shell,
        originRect: originRect,
        animation: animation,
        onFavouriteChanged: widget.onFavouriteChanged,
      ),
    ));

    if (mounted) setState(() => _isExpanded = false);
  }

  void _showInfoSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppSpacing.cardRadius / 2)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: _InfoSheet(shell: widget.shell),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shell = widget.shell;

    return Visibility(
      visible: !_isExpanded,
      maintainSize: true,
      maintainAnimation: true,
      maintainState: true,
      child: AnimatedScale(
      key: _cardKey,
      scale: _pressing ? 0.97 : 1.0,
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOut,
      child: GestureDetector(
        onTap: _openPrimary,
        onTapDown: (_) => setState(() => _pressing = true),
        onTapUp: (_) => setState(() => _pressing = false),
        onTapCancel: () => setState(() => _pressing = false),
        onLongPressStart: (d) {
          setState(() => _pressing = false);
          _openExpandedOverlay(context, widget.shell);
        },
        child: ValueListenableBuilder<String>(
          valueListenable: ThemeService.instance.currentColor,
          builder: (context, _, _) => ValueListenableBuilder<String>(
            valueListenable: ThemeService.instance.currentStyle,
            builder: (context, style, _) => ValueListenableBuilder<bool>(
              valueListenable: ThemeService.instance.glassEnabled,
              builder: (context, glass, _) {
              final radius = style == 'vivid' ? 10.0 : 5.0;
              final body = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── 1. Title + heart ───────────────────────────────────────
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        shell.title,
                        style: AppTextStyle.cardTitle.copyWith(
                          fontSize: style == 'vivid' ? 27 : 23,
                          color: tokens.AppThemeTokens.titleColor,
                          fontWeight: style == 'vivid'
                              ? FontWeight.w700
                              : FontWeight.w400,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    GestureDetector(
                      onTap: _toggleLike,
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 14, top: 3),
                        child: ScaleTransition(
                          scale: _heartScale,
                          child: Icon(
                            _liked
                                ? CupertinoIcons.heart_fill
                                : CupertinoIcons.heart,
                            size: 22,
                            color: _liked
                                ? AppColors.heartActive
                                : tokens.AppThemeTokens.secondaryTextColor,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),

                // ── 2. Meeting times ───────────────────────────────────────
                if (shell.meetingTimes.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    _allMeetingsText,
                    style: AppTextStyle.body.copyWith(
                      color: tokens.AppThemeTokens.timesColor,
                    ),
                  ),
                ],

                // ── 3. Location ────────────────────────────────────────────
                if (shell.location != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        CupertinoIcons.location,
                        size: 10,
                        color: tokens.AppThemeTokens.locationColor,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        shell.location!.toUpperCase(),
                        style: AppTextStyle.label.copyWith(
                          color: tokens.AppThemeTokens.locationColor,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            );
            if (glass) {
              return tokens.AppThemeTokens.glassContainer(
                opacity: 0.08,
                blur: 15,
                borderRadius: BorderRadius.circular(radius),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                  child: body,
                ),
              );
            }
            return AppCard(
              color: tokens.AppThemeTokens.cardBackground,
              borderColor: tokens.AppThemeTokens.cardBorder,
              borderRadius: radius,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              child: body,
            );
            },
          ),
        ),
      ),
    ),
    ),
  );
  }
}

// ─── Glass context menu route ─────────────────────────────────────────────────

class _GlassMenuPage extends StatelessWidget {
  const _GlassMenuPage({
    required this.shell,
    required this.tapPosition,
    required this.anim,
    required this.onInfo,
    required this.onEdit,
    required this.onDelete,
  });

  final CourseShell shell;
  final Offset tapPosition;
  final Animation<double> anim;
  final VoidCallback onInfo;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Info + links + edit + (delete if manual)
    final itemCount =
        1 + shell.links.length + 1 + (shell.isManual ? 1 : 0);
    final estimatedH = itemCount * _kItemHeight + 16.0;

    // Vertical: flip above the tap if it would overflow the bottom
    final bool above =
        tapPosition.dy + estimatedH + 24 > screen.height - 80;
    double top = above
        ? tapPosition.dy - estimatedH - 12
        : tapPosition.dy + 12;

    // Horizontal: centre on tap, clamped to safe margins
    double left = tapPosition.dx - _kMenuWidth / 2;
    left = left.clamp(16.0, screen.width - _kMenuWidth - 16.0);
    top = top.clamp(80.0, screen.height - estimatedH - 60.0);

    final scaleOrigin =
        above ? Alignment.bottomCenter : Alignment.topCenter;

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          // ── Scrim — tapping it dismisses the menu ───────────────────────
          Positioned.fill(
            child: FadeTransition(
              opacity: anim,
              child: GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  color: Colors.black.withAlpha(isDark ? 90 : 55),
                ),
              ),
            ),
          ),

          // ── Floating glass menu ─────────────────────────────────────────
          Positioned(
            left: left,
            top: top,
            child: FadeTransition(
              opacity: anim,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.80, end: 1.0).animate(
                  CurvedAnimation(
                    parent: anim,
                    curve: Curves.easeOutBack,
                  ),
                ),
                alignment: scaleOrigin,
                child: _GlassMenu(
                  shell: shell,
                  isDark: isDark,
                  onInfo: onInfo,
                  onEdit: onEdit,
                  onDelete: onDelete,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _GlassMenu extends StatelessWidget {
  const _GlassMenu({
    required this.shell,
    required this.isDark,
    required this.onInfo,
    required this.onEdit,
    required this.onDelete,
  });

  final CourseShell shell;
  final bool isDark;
  final VoidCallback onInfo;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  static IconData _linkIcon(String url) =>
      url.contains('spaces.kisd.de')
          ? CupertinoIcons.rectangle_stack
          : CupertinoIcons.globe;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final fillColor = isDark
        ? Colors.black.withValues(alpha: 0.46)
        : Colors.white.withValues(alpha: 0.66);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.13)
        : Colors.black.withValues(alpha: 0.07);
    final divColor = isDark
        ? Colors.white.withValues(alpha: 0.09)
        : Colors.black.withValues(alpha: 0.09);

    // Build item list interleaved with dividers
    final rows = <Widget>[];

    void addItem(Widget item) {
      if (rows.isNotEmpty) {
        rows.add(_GlassDivider(color: divColor));
      }
      rows.add(item);
    }

    // Info — always first
    addItem(_GlassMenuItem(
      icon: CupertinoIcons.info_circle,
      label: 'Info',
      cs: cs,
      onTap: onInfo,
    ));

    for (final link in shell.links) {
      addItem(_GlassMenuItem(
        icon: _linkIcon(link.url),
        label: link.label,
        cs: cs,
        onTap: () {
          Navigator.of(context).pop();
          SpacesBrowser.open(link.url);
        },
      ));
    }

    addItem(_GlassMenuItem(
      icon: CupertinoIcons.pencil,
      label: 'Edit shell',
      cs: cs,
      onTap: onEdit,
    ));

    if (shell.isManual) {
      addItem(_GlassMenuItem(
        icon: CupertinoIcons.trash,
        label: 'Delete',
        cs: cs,
        isDestructive: true,
        onTap: onDelete,
      ));
    }

    return Container(
      width: _kMenuWidth,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: borderColor, width: 0.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.14),
            blurRadius: 28,
            spreadRadius: 0,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6.5),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(
            color: fillColor,
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: rows,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _GlassMenuItem extends StatelessWidget {
  const _GlassMenuItem({
    required this.icon,
    required this.label,
    required this.cs,
    required this.onTap,
    this.isDestructive = false,
  });

  final IconData icon;
  final String label;
  final ColorScheme cs;
  final VoidCallback onTap;
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    final color = isDestructive ? cs.error : cs.onSurface;
    return SizedBox(
      height: _kItemHeight,
      child: InkWell(
        onTap: onTap,
        splashColor: color.withAlpha(18),
        highlightColor: color.withAlpha(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(icon, size: 17, color: color.withAlpha(isDestructive ? 255 : 210)),
              const SizedBox(width: 13),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    color: color,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GlassDivider extends StatelessWidget {
  const _GlassDivider({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) =>
      Container(height: 0.5, color: color);
}

// ─── Info sheet ───────────────────────────────────────────────────────────────

class _InfoSheet extends StatelessWidget {
  const _InfoSheet({required this.shell});
  final CourseShell shell;

  static String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.'
      '${d.month.toString().padLeft(2, '0')}.'
      '${d.year}';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Center(
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 14),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textTertiary,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),

          // Title
          Text(shell.title, style: AppTextStyle.headline),

          // Description — collapsible
          if (shell.description.isNotEmpty) ...[
            const SizedBox(height: 8),
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 16),
                iconColor: AppColors.accent,
                collapsedIconColor: AppColors.textTertiary,
                title: Text('DESCRIPTION', style: AppTextStyle.label),
                children: [
                  Text(shell.description, style: AppTextStyle.body),
                ],
              ),
            ),
          ],

          // Schedule
          if (shell.meetingTimes.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('SCHEDULE', style: AppTextStyle.label),
            const SizedBox(height: 8),
            ...shell.meetingTimes.map((m) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '${m.weekday.label}  '
                    '${CourseShellCard.fmtTime(m.startTime)} – '
                    '${CourseShellCard.fmtTime(m.endTime)}',
                    style: AppTextStyle.body,
                  ),
                )),
          ],

          // Location
          if (shell.location != null) ...[
            const SizedBox(height: 24),
            Text('LOCATION', style: AppTextStyle.label),
            const SizedBox(height: 8),
            Text(shell.location!, style: AppTextStyle.body),
          ],

          // Period
          const SizedBox(height: 24),
          Text('PERIOD', style: AppTextStyle.label),
          const SizedBox(height: 8),
          Text(
            '${_fmtDate(shell.startDate)} – ${_fmtDate(shell.endDate)}',
            style: AppTextStyle.body,
          ),

          // Links
          if (shell.links.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('LINKS', style: AppTextStyle.label),
            const SizedBox(height: 8),
            ...shell.links.map((l) => GestureDetector(
                  onTap: () {
                    Navigator.pop(context);
                    SpacesBrowser.open(l.url);
                  },
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        Icon(
                          l.url.contains('spaces.kisd.de')
                              ? CupertinoIcons.rectangle_stack
                              : CupertinoIcons.globe,
                          size: 14,
                          color: AppColors.accent,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          l.label,
                          style: AppTextStyle.body
                              .copyWith(color: AppColors.accent),
                        ),
                      ],
                    ),
                  ),
                )),
          ],
        ],
      ),
    );
  }
}

// ─── Expanded card overlay ────────────────────────────────────────────────────

class _ExpandedCardOverlay extends StatefulWidget {
  const _ExpandedCardOverlay({
    required this.shell,
    required this.originRect,
    required this.animation,
    this.onFavouriteChanged,
  });

  final CourseShell shell;
  final Rect originRect;
  final Animation<double> animation;
  final void Function(bool isFavourite)? onFavouriteChanged;

  @override
  State<_ExpandedCardOverlay> createState() => _ExpandedCardOverlayState();
}

class _ExpandedCardOverlayState extends State<_ExpandedCardOverlay>
    with TickerProviderStateMixin {
  // ── Heart ────────────────────────────────────────────────────────────────────
  late bool _liked;
  late final AnimationController _heartCtrl;
  late final Animation<double> _heartScale;

  // ── Morph curve (Stage 3) ─────────────────────────────────────────────────
  late final CurvedAnimation _curved;

  // ── Drag-to-dismiss (Stage 3.5) ──────────────────────────────────────────
  double _dragProgress = 0.0;
  bool _isDragging = false;
  double _dragDistance = 0.0;
  late final AnimationController _snapBackCtrl;
  late final AnimationController _closeController;
  double _closeStartProgress = 0.0;

  // ── Description expand (Stage 2) ─────────────────────────────────────────
  bool _descriptionExpanded = false;

  @override
  void initState() {
    super.initState();
    _liked = widget.shell.isFavourite;

    _heartCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
      reverseDuration: const Duration(milliseconds: 110),
    );
    _heartScale = Tween<double>(begin: 1.0, end: 1.40).animate(
      CurvedAnimation(parent: _heartCtrl, curve: Curves.easeOut),
    );

    _curved = CurvedAnimation(
      parent: widget.animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    _snapBackCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    // Drive _dragProgress from snap-back controller so setState propagates.
    _snapBackCtrl.addListener(() {
      if (mounted) setState(() => _dragProgress = _snapBackCtrl.value);
    });

    _closeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _closeController.addListener(() {
      setState(() {
        _dragProgress = (_closeStartProgress +
                (1.0 - _closeStartProgress) *
                    Curves.easeIn.transform(_closeController.value))
            .clamp(0.0, 1.0);
      });
    });
    _closeController.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    _heartCtrl.dispose();
    _curved.dispose();
    _snapBackCtrl.dispose();
    _closeController.dispose();
    super.dispose();
  }

  void _toggleLike() {
    final next = !_liked;
    setState(() => _liked = next);
    _heartCtrl.forward(from: 0.0).then((_) => _heartCtrl.reverse());
    widget.onFavouriteChanged?.call(next);
  }

  void _onDragStart(DragStartDetails _) {
    setState(() {
      _isDragging = true;
      _dragDistance = 0.0;
    });
  }

  void _onDragUpdate(DragUpdateDetails d) {
    final screenHeight = MediaQuery.of(context).size.height;
    setState(() {
      _dragDistance =
          (_dragDistance + d.delta.dy).clamp(0.0, double.infinity);
      _dragProgress =
          (_dragDistance / (screenHeight * 0.35)).clamp(0.0, 1.0);
    });
  }

  void _onDragEnd(DragEndDetails d) {
    if (_dragProgress > 0.35 || d.velocity.pixelsPerSecond.dy > 800) {
      _closeStartProgress = _dragProgress;
      _closeController.forward(from: 0);
    } else {
      _snapBack();
    }
  }

  void _onDragCancel() => _snapBack();

  void _snapBack() {
    _snapBackCtrl.value = _dragProgress;
    _snapBackCtrl.animateTo(0.0, curve: Curves.easeOut).then((_) {
      if (mounted) {
        setState(() {
          _isDragging = false;
          _dragDistance = 0.0;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final style = ThemeService.instance.currentStyle.value;
    final radius = style == 'vivid' ? 10.0 : 5.0;
    final shell = widget.shell;

    final expandedW = size.width * 0.9;
    final expandedH = size.height * 0.6;
    final expandedRect = Rect.fromLTWH(
      (size.width - expandedW) / 2,
      (size.height - expandedH) / 2,
      expandedW,
      expandedH,
    );

    return AnimatedBuilder(
      animation: widget.animation,
      builder: (ctx, _) {
        final double t = _isDragging
            ? (1.0 - _dragProgress).clamp(0.0, 1.0)
            : _curved.value;

        final lerpedRect =
            Rect.lerp(widget.originRect, expandedRect, t)!;
        final lerpedPadding = EdgeInsets.lerp(
          const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          const EdgeInsets.all(24),
          t,
        )!;
        final newContentOpacity = ((t - 0.5) / 0.5).clamp(0.0, 1.0);
        final titleMaxLines = (lerpDouble(2, 99, t) ?? 2.0).round();
        final glass = ThemeService.instance.glassEnabled.value;
        final colorKey = ThemeService.instance.currentColor.value;

        return Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              // ── Backdrop ─────────────────────────────────────────────────
              Positioned.fill(
                child: Container(
                  color: Colors.black.withValues(alpha: (glass ? 0.0 : 0.35) * t),
                ),
              ),

              // ── Morphing card ─────────────────────────────────────────────
              Positioned.fromRect(
                rect: lerpedRect,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                      onVerticalDragStart: _onDragStart,
                      onVerticalDragUpdate: _onDragUpdate,
                      onVerticalDragEnd: _onDragEnd,
                      onVerticalDragCancel: _onDragCancel,
                      child: Container(
                        decoration: BoxDecoration(
                          color: glass
                              ? Colors.transparent
                              : tokens.AppThemeTokens.cardBackground,
                          border: glass
                              ? null
                              : Border.all(
                                  color: tokens.AppThemeTokens.cardBorder),
                          borderRadius: BorderRadius.circular(radius),
                          boxShadow: glass
                              ? [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.22),
                                    blurRadius: 32,
                                    spreadRadius: 0,
                                    offset: const Offset(0, 8),
                                  ),
                                ]
                              : null,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(radius),
                          clipBehavior: Clip.hardEdge,
                          child: Stack(
                            children: [
                              if (glass) ...[
                                Positioned.fill(
                                  child: BackdropFilter(
                                    filter: ImageFilter.blur(
                                        sigmaX: 24, sigmaY: 24),
                                    child: const SizedBox.expand(),
                                  ),
                                ),
                                Positioned.fill(
                                  child: Container(
                                    color: colorKey == 'dark'
                                        ? Colors.white.withValues(alpha: 0.10)
                                        : colorKey == 'pastel'
                                            ? Colors.white
                                                .withValues(alpha: 0.40)
                                            : Colors.white
                                                .withValues(alpha: 0.35),
                                  ),
                                ),
                                Positioned.fill(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: Colors.white
                                            .withValues(alpha: 0.28),
                                        width: 0.5,
                                      ),
                                      borderRadius:
                                          BorderRadius.circular(radius),
                                    ),
                                    child: const SizedBox.expand(),
                                  ),
                                ),
                              ],
                              SingleChildScrollView(
                                physics: const NeverScrollableScrollPhysics(),
                                clipBehavior: Clip.none,
                            child: Padding(
                            padding: lerpedPadding,
                            child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // ── 1. Title + heart ─────────────────────────────
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: AnimatedSize(
                                    duration:
                                        const Duration(milliseconds: 100),
                                    alignment: Alignment.topLeft,
                                    child: Text(
                                      shell.title,
                                      maxLines: titleMaxLines,
                                      overflow: titleMaxLines < 10
                                          ? TextOverflow.ellipsis
                                          : TextOverflow.visible,
                                      style: AppTextStyle.cardTitle.copyWith(
                                        fontSize:
                                            style == 'vivid' ? 27 : 23,
                                        color:
                                            tokens.AppThemeTokens.titleColor,
                                        fontWeight: style == 'vivid'
                                            ? FontWeight.w700
                                            : FontWeight.w400,
                                      ),
                                    ),
                                  ),
                                ),
                                GestureDetector(
                                  onTap: _toggleLike,
                                  behavior: HitTestBehavior.opaque,
                                  child: Padding(
                                    padding: const EdgeInsets.only(
                                        left: 14, top: 3),
                                    child: ScaleTransition(
                                      scale: _heartScale,
                                      child: Icon(
                                        _liked
                                            ? CupertinoIcons.heart_fill
                                            : CupertinoIcons.heart,
                                        size: 22,
                                        color: _liked
                                            ? AppColors.heartActive
                                            : tokens.AppThemeTokens
                                                .secondaryTextColor,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            // ── 2. Schedule ───────────────────────────────────
                            if (shell.meetingTimes.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Text(
                                _formatMeetingTimes(shell.meetingTimes),
                                style: AppTextStyle.body.copyWith(
                                  color: tokens.AppThemeTokens.timesColor,
                                ),
                              ),
                            ],

                            // ── 3. Location ───────────────────────────────────
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Icon(
                                  CupertinoIcons.location,
                                  size: 10,
                                  color:
                                      tokens.AppThemeTokens.locationColor,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  shell.location?.toUpperCase() ??
                                      'SEE DESCRIPTION',
                                  style: AppTextStyle.label.copyWith(
                                    color:
                                        tokens.AppThemeTokens.locationColor,
                                  ),
                                ),
                              ],
                            ),

                            // ── 4–6. New content (fades in over second half) ──
                            IgnorePointer(
                              ignoring: t < 0.95,
                              child: Opacity(
                                opacity: newContentOpacity,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // Description
                                    if (shell.description
                                        .trim()
                                        .isNotEmpty) ...[
                                      const SizedBox(height: 12),
                                      Text(
                                        'DESCRIPTION',
                                        style: AppTextStyle.label.copyWith(
                                          color: tokens.AppThemeTokens
                                              .secondaryTextColor,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      AnimatedSize(
                                        duration: const Duration(
                                            milliseconds: 200),
                                        curve: Curves.easeInOut,
                                        alignment: Alignment.topCenter,
                                        child: Text(
                                          shell.description,
                                          maxLines: _descriptionExpanded
                                              ? null
                                              : 3,
                                          overflow: _descriptionExpanded
                                              ? TextOverflow.visible
                                              : TextOverflow.ellipsis,
                                          style: AppTextStyle.body.copyWith(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w400,
                                            color: tokens
                                                .AppThemeTokens.titleColor,
                                          ),
                                        ),
                                      ),
                                      if (shell.description.length >
                                          180) ...[
                                        const SizedBox(height: 6),
                                        GestureDetector(
                                          onTap: () => setState(() =>
                                              _descriptionExpanded =
                                                  !_descriptionExpanded),
                                          child: Text(
                                            _descriptionExpanded
                                                ? 'Show less'
                                                : 'Show more',
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w400,
                                              color: tokens.AppThemeTokens
                                                  .secondaryTextColor,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],

                                    // Links
                                    if (shell.links.isNotEmpty) ...[
                                      const SizedBox(height: 12),
                                      Text(
                                        'LINKS',
                                        style: AppTextStyle.label.copyWith(
                                          color: tokens.AppThemeTokens
                                              .secondaryTextColor,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      ...shell.links.map((l) {
                                        final display = l.label.isNotEmpty
                                            ? l.label
                                            : Uri.tryParse(l.url)?.host ??
                                                l.url;
                                        return Padding(
                                          padding: const EdgeInsets.only(
                                              bottom: 12),
                                          child: GestureDetector(
                                            onTap: () {
                                              Navigator.pop(context);
                                              SpacesBrowser.open(l.url);
                                            },
                                            child: Row(
                                              children: [
                                                Icon(
                                                  l.url.contains(
                                                          'spaces.kisd.de')
                                                      ? CupertinoIcons
                                                          .rectangle_stack
                                                      : CupertinoIcons
                                                          .globe,
                                                  size: 14,
                                                  color: AppColors.accent,
                                                ),
                                                const SizedBox(width: 8),
                                                Expanded(
                                                  child: Text(
                                                    display,
                                                    style: AppTextStyle.body
                                                        .copyWith(
                                                      color: AppColors.accent,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      }),
                                    ],

                                    // Edit button
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: TextButton(
                                        onPressed: () {
                                          // TODO Stage 4: in-place editing.
                                        },
                                        style: TextButton.styleFrom(
                                          padding: EdgeInsets.zero,
                                          minimumSize: Size.zero,
                                          tapTargetSize: MaterialTapTargetSize
                                              .shrinkWrap,
                                        ),
                                        child: Text(
                                          'Edit',
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w400,
                                            color: tokens.AppThemeTokens
                                                .secondaryTextColor,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      ),
                            ],
                          ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
