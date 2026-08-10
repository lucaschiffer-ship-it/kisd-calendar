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
/// render as flat grey. So this takes the shape every other sheet in the app
/// already falls back to with glass switched off: a solid `surfaceElevated`
/// panel, hairline border, handle pill.
///
/// **The scrim is native** (`NativeSpacesBrowserState.setModalDim`). A
/// full-screen Flutter layer animating over a `UiKitView` forces the platform
/// view to be recomposited every frame, which is what made this sheet feel
/// heavy next to the chrome that launches it. Everything here is therefore
/// bottom-anchored and small, and the open is a `SlideTransition` over a
/// subtree that is built once — see [build].
class AddToCourseSheet extends StatefulWidget {
  const AddToCourseSheet({
    super.key,
    required this.url,
    required this.pageTitle,
    required this.onClose,
    this.initialCourses,
  });

  final String url;
  final String? pageTitle;
  final VoidCallback onClose;

  /// Cache contents already warmed by `HomeScreen`, raw and unfiltered. When
  /// present the first frame paints real rows; [_load] is only the cold path.
  final List<CourseShell>? initialCourses;

  @override
  State<AddToCourseSheet> createState() => _AddToCourseSheetState();
}

class _AddToCourseSheetState extends State<AddToCourseSheet>
    with SingleTickerProviderStateMixin {
  // 300 ms easeOutCubic: the duration `_sheetAnim` and the native chrome's
  // animator both use, so the dim, the chrome and this sheet read as one move.
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  )..forward();

  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 1),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));

  List<CourseShell> _favourites = const [];
  bool _loading = true;
  String? _busyId;
  String? _doneMessage;

  @override
  void initState() {
    super.initState();
    final warm = widget.initialCourses;
    if (warm != null) {
      _favourites = _pick(warm);
      _loading = false;
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  /// The one place the favourite filter and ordering live, so a warm snapshot
  /// and a cold load cannot drift apart.
  static List<CourseShell> _pick(List<CourseShell> shells) =>
      shells.where((s) => s.isFavourite).toList()
        ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

  Future<void> _load() async {
    List<CourseShell> shells = const [];
    try {
      shells = await scraperService.loadCached();
    } catch (e) {
      debugPrint('[add-to-course] cache load: $e');
    }
    if (!mounted) return;
    setState(() {
      _favourites = _pick(shells);
      _loading = false;
    });
  }

  Future<void> _dismiss() async {
    await _anim.reverse();
    widget.onClose();
  }

  /// Confirms first, writes second.
  ///
  /// The write is a `SharedPreferences` round-trip that effectively cannot
  /// fail, and the calendar resync it used to wait on is now detached — so
  /// holding the haptic and the label until it returns bought nothing but a
  /// tap that felt like it hung.
  Future<void> _confirm(String message, Future<void> Function() write) async {
    HapticFeedback.mediumImpact();
    setState(() => _doneMessage = message);
    await Future.wait([
      write(),
      Future<void>.delayed(const Duration(milliseconds: 350)),
    ]);
    if (mounted) await _dismiss();
  }

  Future<void> _attach(CourseShell shell) async {
    if (_busyId != null) return;
    if (courseHasLink(shell, widget.url)) {
      HapticFeedback.selectionClick();
      setState(() => _doneMessage = 'Already on ${shell.title}');
      return;
    }
    setState(() => _busyId = shell.id);
    await _confirm(
      'Added to ${shell.title}',
      () => attachLink(shell, widget.url, widget.pageTitle),
    );
  }

  Future<void> _createNew() async {
    if (_busyId != null) return;
    setState(() => _busyId = '__new__');
    // The title is derived exactly as `createCourseFrom` derives it, so the
    // confirmation can be shown before the shell exists.
    await _confirm(
      'Created ${titleFor(widget.url, widget.pageTitle)}',
      () => createCourseFrom(widget.url, widget.pageTitle),
    );
  }

  @override
  Widget build(BuildContext context) {
    // No scrim here: the dim is a UIKit view behind this one, because a
    // full-screen Flutter layer over the webview costs a platform-view
    // recomposite per frame. The only thing that moves is this panel.
    //
    // `SlideTransition` wraps a subtree built *outside* the animation, so the
    // `shrinkWrap` list below lays out once per state change instead of once
    // per frame.
    return ValueListenableBuilder<AppColorScheme>(
      valueListenable: AppColorScheme.currentListenable,
      builder: (context, s, _) => Align(
        alignment: Alignment.bottomCenter,
        child: SlideTransition(position: _slide, child: _panel(s)),
      ),
    );
  }

  Widget _panel(AppColorScheme s) {
    return Container(
      // Full-bleed and bottom-anchored, like every other sheet in the app.
      // Capped so a long favourites list scrolls inside the panel rather than
      // growing it over the page — `shrinkWrap` has no bound of its own.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.6,
      ),
      decoration: BoxDecoration(
        color: s.surfaceElevated,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
        border: Border(top: BorderSide(color: s.cardBorder, width: 0.5)),
        boxShadow: const [AppGlass.cardShadow],
      ),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(s),
            Flexible(child: _body(s)),
            _footer(s),
          ],
        ),
      ),
    );
  }

  Widget _header(AppColorScheme s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: s.textSecondary.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(AppRadius.handle),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            _doneMessage ?? 'Add to course',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.contentHeading(
                color: _doneMessage != null ? s.accent : s.textPrimary),
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
