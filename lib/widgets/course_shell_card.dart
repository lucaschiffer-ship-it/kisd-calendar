import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/course_shell.dart';
import '../services/spaces_browser.dart';

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
  // Shared across all card instances so getInstance() is called at most once.
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
          '${m.weekday.label} ${CourseShellCard.fmtTime(m.startTime)}–${CourseShellCard.fmtTime(m.endTime)}')
      .join(', ');

  void _openPrimary() {
    if (widget.shell.links.isEmpty) return;
    SpacesBrowser.open(widget.shell.links.first.url);
  }

  void _showModal(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      backgroundColor: isDark ? const Color(0xFF2C2C2E) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _ModalContent(
        shell: widget.shell,
        cs: cs,
        isDark: isDark,
        onEdit: () {
          Navigator.pop(ctx);
          widget.onEdit();
        },
        onDelete: () {
          Navigator.pop(ctx);
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
      onLongPress: () => _showModal(context),
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
            // ── Text content ──────────────────────────────────────────────
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
                        Icon(
                          CupertinoIcons.location,
                          size: 11,
                          color: cs.onSurface.withAlpha(120),
                        ),
                        const SizedBox(width: 3),
                        Text(
                          shell.location!,
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurface.withAlpha(140),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

            // ── Right column: heart + link indicator ──────────────────────
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
                      _liked ? CupertinoIcons.heart_fill : CupertinoIcons.heart,
                      size: 18,
                      color: _liked ? Colors.red.shade400 : cs.onSurface.withAlpha(90),
                    ),
                  ),
                ),
                if (shell.links.length > 1) ...[
                  const SizedBox(height: 6),
                  Icon(
                    CupertinoIcons.link,
                    size: 13,
                    color: cs.primary.withAlpha(160),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _ModalContent extends StatelessWidget {
  const _ModalContent({
    required this.shell,
    required this.cs,
    required this.isDark,
    required this.onEdit,
    required this.onDelete,
  });

  final CourseShell shell;
  final ColorScheme cs;
  final bool isDark;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          margin: const EdgeInsets.symmetric(vertical: 12),
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: cs.onSurface.withAlpha(60),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              shell.title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        if (shell.links.isNotEmpty) ...[
          Divider(height: 1, color: cs.onSurface.withAlpha(30)),
          ...shell.links.map(
            (link) => ListTile(
              leading: Icon(CupertinoIcons.link, size: 19, color: cs.primary),
              title: Text(link.label, style: const TextStyle(fontSize: 15)),
              subtitle: Text(
                link.url,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(130)),
              ),
              onTap: () {
                Navigator.pop(context);
                SpacesBrowser.open(link.url);
              },
            ),
          ),
        ],
        Divider(height: 1, color: cs.onSurface.withAlpha(30)),
        ListTile(
          leading: Icon(CupertinoIcons.pencil, size: 19, color: cs.onSurface),
          title: const Text('Edit shell', style: TextStyle(fontSize: 15)),
          onTap: onEdit,
        ),
        if (shell.isManual)
          ListTile(
            leading: Icon(CupertinoIcons.trash, size: 19, color: cs.error),
            title: Text('Delete', style: TextStyle(fontSize: 15, color: cs.error)),
            onTap: onDelete,
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}
