import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/course_shell.dart';
import '../services/spaces_browser.dart';
import '../theme/app_theme.dart';

// ─── sizing constants used by both the page and the menu ─────────────────────
const double _kMenuWidth = 240.0;
const double _kItemHeight = 44.0;

// ─────────────────────────────────────────────────────────────────────────────

class CourseShellCard extends StatefulWidget {
  const CourseShellCard({
    super.key,
    required this.shell,
    required this.onEdit,
    required this.onDelete,
  });

  final CourseShell shell;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  static String fmtTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  State<CourseShellCard> createState() => _CourseShellCardState();
}

class _CourseShellCardState extends State<CourseShellCard>
    with SingleTickerProviderStateMixin {
  static SharedPreferences? _prefs;
  late bool _liked;
  bool _pressing = false;

  // Heart bounce animation
  late final AnimationController _heartCtrl;
  late final Animation<double> _heartScale;

  static String _key(String id) => 'shell_liked_$id';

  @override
  void initState() {
    super.initState();
    _liked = widget.shell.isLiked;
    _loadLiked();
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
  void dispose() {
    _heartCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadLiked() async {
    _prefs ??= await SharedPreferences.getInstance();
    final saved = _prefs!.getBool(_key(widget.shell.id));
    if (saved != null && saved != _liked && mounted) {
      setState(() => _liked = saved);
    }
  }

  Future<void> _toggleLike() async {
    final next = !_liked;
    setState(() => _liked = next);
    // Bounce: scale up then back
    _heartCtrl.forward(from: 0.0).then((_) => _heartCtrl.reverse());
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setBool(_key(widget.shell.id), next);
  }

  // "TUE  13:00 – 16:00  ·  THU  13:00 – 16:00"
  String get _allMeetingsText => widget.shell.meetingTimes
      .map((m) =>
          '${m.weekday.label.toUpperCase()}  '
          '${CourseShellCard.fmtTime(m.startTime)} – '
          '${CourseShellCard.fmtTime(m.endTime)}')
      .join('  ·  ');

  void _openPrimary() {
    if (widget.shell.links.isEmpty) return;
    SpacesBrowser.open(widget.shell.links.first.url);
  }

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

  void _showInfoSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppSpacing.cardRadius)),
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

    return AnimatedScale(
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
          _showContextMenu(context, d.globalPosition);
        },
        child: AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── 1. Title + heart ─────────────────────────────────────────
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      shell.title,
                      style: AppTextStyle.cardTitle.copyWith(fontSize: 29),
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
                              : AppColors.textTertiary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              // ── 2. Meeting times ─────────────────────────────────────────
              if (shell.meetingTimes.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(_allMeetingsText,
                    style: AppTextStyle.body.copyWith(color: AppColors.accent)),
              ],

              // ── 3. Location ──────────────────────────────────────────────
              if (shell.location != null) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(CupertinoIcons.location,
                        size: 10, color: AppColors.textTertiary),
                    const SizedBox(width: 4),
                    Text(
                      shell.location!.toUpperCase(),
                      style: AppTextStyle.label,
                    ),
                  ],
                ),
              ],

              // ── 4. Link indicator bottom-right ───────────────────────────
              if (shell.links.length > 1) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: Icon(
                    CupertinoIcons.link,
                    size: 12,
                    color: AppColors.accent.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ],
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
        ? Colors.black.withValues(alpha: 0.58)
        : Colors.white.withValues(alpha: 0.82);
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
        borderRadius: BorderRadius.circular(14),
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
        borderRadius: BorderRadius.circular(13.5),
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
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Title
          Text(shell.title, style: AppTextStyle.headline),

          // Description
          if (shell.description.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(shell.description, style: AppTextStyle.body),
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
