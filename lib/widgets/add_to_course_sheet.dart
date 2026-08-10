import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/course_shell.dart';
import '../services/course_link_attach.dart';
import '../services/service_locator.dart';
import '../theme/tokens.dart';

/// "Add this page to a course", shown over the Spaces browser.
///
/// Lives inside the browser sheet's `Stack` so it rides the sheet's transform
/// and dies with it, exactly like the "Reconnecting…" overlay.
///
/// Deliberately **not** a glass surface. `AppThemeTokens.glassContainer` and
/// every other `BackdropFilter` sample Flutter-drawn pixels only, and the page
/// behind this card is a platform view — a blur here would sample nothing and
/// render as flat grey. A dim scrim plus a solid card is the honest version of
/// the same read.
class AddToCourseSheet extends StatefulWidget {
  const AddToCourseSheet({
    super.key,
    required this.url,
    required this.pageTitle,
    required this.onClose,
  });

  final String url;
  final String? pageTitle;
  final VoidCallback onClose;

  @override
  State<AddToCourseSheet> createState() => _AddToCourseSheetState();
}

class _AddToCourseSheetState extends State<AddToCourseSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..forward();

  List<CourseShell> _favourites = [];
  bool _loading = true;
  String? _busyId;
  String? _doneMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    List<CourseShell> shells = [];
    try {
      shells = await scraperService.loadCached();
    } catch (e) {
      print('[add-to-course] cache load: $e');
    }
    if (!mounted) return;
    setState(() {
      _favourites = shells.where((s) => s.isFavourite).toList()
        ..sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
      _loading = false;
    });
  }

  Future<void> _dismiss() async {
    await _anim.reverse();
    widget.onClose();
  }

  Future<void> _attach(CourseShell shell) async {
    if (_busyId != null) return;
    if (courseHasLink(shell, widget.url)) {
      HapticFeedback.selectionClick();
      setState(() => _doneMessage = 'Already on ${shell.title}');
      return;
    }
    setState(() => _busyId = shell.id);
    await attachLink(shell, widget.url, widget.pageTitle);
    HapticFeedback.mediumImpact();
    if (!mounted) return;
    setState(() => _doneMessage = 'Added to ${shell.title}');
    await Future<void>.delayed(const Duration(milliseconds: 550));
    if (mounted) await _dismiss();
  }

  Future<void> _createNew() async {
    if (_busyId != null) return;
    setState(() => _busyId = '__new__');
    final shell = await createCourseFrom(widget.url, widget.pageTitle);
    HapticFeedback.mediumImpact();
    if (!mounted) return;
    setState(() => _doneMessage = 'Created ${shell.title}');
    await Future<void>.delayed(const Duration(milliseconds: 550));
    if (mounted) await _dismiss();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    final curve = CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic);

    return AnimatedBuilder(
      animation: curve,
      builder: (context, _) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: _dismiss,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  color: Colors.black.withValues(alpha: 0.55 * curve.value),
                ),
              ),
            ),
            Center(
              child: Opacity(
                opacity: curve.value,
                child: Transform.scale(
                  scale: 0.94 + 0.06 * curve.value,
                  child: _card(s),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _card(AppColorScheme s) {
    final media = MediaQuery.of(context);
    return Container(
      margin: EdgeInsets.symmetric(
        horizontal: 24,
        vertical: media.padding.vertical + 60,
      ),
      constraints: const BoxConstraints(maxWidth: 420, maxHeight: 460),
      decoration: BoxDecoration(
        color: s.surfaceElevated,
        borderRadius: BorderRadius.circular(AppRadius.sheet),
        border: Border.all(color: s.cardBorder, width: 0.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 30,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(s),
          Flexible(child: _body(s)),
          _footer(s),
        ],
      ),
    );
  }

  Widget _header(AppColorScheme s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _doneMessage ?? 'Add to course',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.contentHeading(color: _doneMessage != null ? s.accent : s.textPrimary),
          ),
          const SizedBox(height: 4),
          Text(
            titleFor(widget.url, widget.pageTitle),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.bodySmall(color: s.textTertiary),
          ),
        ],
      ),
    );
  }

  Widget _body(AppColorScheme s) {
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 36),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: s.accent),
          ),
        ),
      );
    }
    if (_favourites.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Text(
          'No liked courses yet. Create a new one below.',
          style: AppTextStyles.body(color: s.textSecondary),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      shrinkWrap: true,
      itemCount: _favourites.length,
      itemBuilder: (context, i) => _row(s, _favourites[i]),
    );
  }

  Widget _row(AppColorScheme s, CourseShell shell) {
    final already = courseHasLink(shell, widget.url);
    final busy = _busyId == shell.id;
    return InkWell(
      onTap: () => _attach(shell),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: s.divider, width: 0.5)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                shell.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.body(color: already ? s.textTertiary : s.textPrimary),
              ),
            ),
            const SizedBox(width: 12),
            if (busy)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: s.accent,
                ),
              )
            else if (already)
              Icon(CupertinoIcons.checkmark_alt, size: 16, color: s.accent),
          ],
        ),
      ),
    );
  }

  Widget _footer(AppColorScheme s) {
    final busy = _busyId == '__new__';
    return InkWell(
      onTap: _createNew,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        decoration: BoxDecoration(
          color: s.accent.withValues(alpha: 0.12),
          border: Border(top: BorderSide(color: s.divider, width: 0.5)),
        ),
        child: Row(
          children: [
            Icon(CupertinoIcons.add, size: 17, color: s.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'New course from this page',
                style: AppTextStyles.body(color: s.accent),
              ),
            ),
            if (busy)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: s.accent,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
