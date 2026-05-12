import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/course_shell.dart';
import '../services/spaces_browser.dart';

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

class _CourseShellCardState extends State<CourseShellCard> {
  static SharedPreferences? _prefs;
  late bool _liked;

  static String _key(String id) => 'shell_liked_$id';

  @override
  void initState() {
    super.initState();
    _liked = widget.shell.isLiked;
    _loadLiked();
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
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setBool(_key(widget.shell.id), next);
  }

  String get _timesText => widget.shell.meetingTimes
      .map((m) =>
          '${m.weekday.label} ${CourseShellCard.fmtTime(m.startTime)}'
          '–${CourseShellCard.fmtTime(m.endTime)}')
      .join(', ');

  void _openPrimary() {
    if (widget.shell.links.isEmpty) return;
    SpacesBrowser.open(widget.shell.links.first.url);
  }

  void _showContextMenu(BuildContext context, Offset tapPosition) {
    final shell = widget.shell;
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final shell = widget.shell;

    return GestureDetector(
      onTap: _openPrimary,
      onLongPressStart: (d) => _showContextMenu(context, d.globalPosition),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2C2C2E) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDark ? const Color(0xFF38383A) : const Color(0xFFE5E5EA),
            width: 0.5,
          ),
          boxShadow: isDark
              ? null
              : [
                  BoxShadow(
                    color: Colors.black.withAlpha(15),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Text content ────────────────────────────────────────────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    shell.title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _timesText,
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurface.withAlpha(180),
                    ),
                  ),
                  if (shell.location != null) ...[
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(CupertinoIcons.location,
                            size: 11, color: cs.onSurface.withAlpha(120)),
                        const SizedBox(width: 3),
                        Text(
                          shell.location!,
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurface.withAlpha(140)),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

            // ── Right column: heart + link indicator ────────────────────────
            const SizedBox(width: 10),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: _toggleLike,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(
                      _liked
                          ? CupertinoIcons.heart_fill
                          : CupertinoIcons.heart,
                      size: 18,
                      color: _liked
                          ? Colors.red.shade400
                          : cs.onSurface.withAlpha(90),
                    ),
                  ),
                ),
                if (shell.links.length > 1) ...[
                  const SizedBox(height: 6),
                  Icon(CupertinoIcons.link,
                      size: 13, color: cs.primary.withAlpha(160)),
                ],
              ],
            ),
          ],
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
    required this.onEdit,
    required this.onDelete,
  });

  final CourseShell shell;
  final Offset tapPosition;
  final Animation<double> anim;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Estimate height: items + 0.5-px dividers + 8 px top + 8 px bottom pad
    final itemCount =
        shell.links.length + 1 + (shell.isManual ? 1 : 0);
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
    required this.onEdit,
    required this.onDelete,
  });

  final CourseShell shell;
  final bool isDark;
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
