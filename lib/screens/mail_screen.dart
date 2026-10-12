import 'dart:ui' show lerpDouble;

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/app_theme.dart' as tokens;
import '../services/mail_service.dart' show MailFolder;
import '../services/page_actions.dart';
import '../services/service_locator.dart';
import '../services/theme_service.dart';
import '../theme/tokens.dart';
import '../widgets/glass_pill.dart';
import '../widgets/header_date_row.dart';
import '../widgets/morphing_glass_header.dart';
import '../widgets/page_floating_actions.dart';
import 'compose_screen.dart';
import 'email_detail_screen.dart';

enum _MailFilter { all, unread, drafts, sent, trash }

extension on _MailFilter {
  /// `all` reads "Inbox": it only ever shows the inbox, and Unread is a view of
  /// that same folder rather than a mailbox of its own.
  String get label => switch (this) {
        _MailFilter.all    => 'Inbox',
        _MailFilter.unread => 'Unread',
        _MailFilter.drafts => 'Drafts',
        _MailFilter.sent   => 'Sent',
        _MailFilter.trash  => 'Trash',
      };

  /// Apple Mail's glyphs, except Unread. Apple's envelope-with-dot looked
  /// just like the Mail tab icon right below the button, so Unread is the
  /// list's own unread dot instead. Drafts is a document, not a pencil, so it
  /// can't be mistaken for the compose button sitting right next to the strip.
  IconData get icon => switch (this) {
        _MailFilter.all    => CupertinoIcons.tray,
        _MailFilter.unread => CupertinoIcons.circle_fill,
        _MailFilter.drafts => CupertinoIcons.doc_text,
        _MailFilter.sent   => CupertinoIcons.paperplane,
        _MailFilter.trash  => CupertinoIcons.trash,
      };

  /// The unread dot is a solid disc: at full icon size it would outweigh the
  /// line glyphs around it, so it renders at half size.
  double get iconScale => this == _MailFilter.unread ? 0.5 : 1.0;
}

class MailScreen extends StatefulWidget {
  const MailScreen({super.key, required this.actions, required this.header});

  final PageActionController actions;
  final PageHeaderHandle header;

  @override
  State<MailScreen> createState() => _MailScreenState();
}

class _MailScreenState extends State<MailScreen>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  @override
  bool get wantKeepAlive => true;

  _MailFilter _filter = _MailFilter.all;
  bool _trashFetchTriggered = false;
  bool _sentFetchTriggered = false;
  bool _draftsFetchTriggered = false;
  bool _reloadDone = false;
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  late final AnimationController _filterMenuCtrl;
  late final Animation<double> _filterMenuAnim;
  bool _filterMenuOpen = false;

  @override
  void initState() {
    super.initState();
    _filterMenuCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _filterMenuAnim = CurvedAnimation(
      parent: _filterMenuCtrl,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    widget.header.controller.pagePos.addListener(_onPagePos);
    widget.actions.handler = _onReload;
    mailService.addListener(_onUpdate);
    // Unconditional: `connect()` guards on its own flags, and it now clears
    // the previous account's state first. Gating here on `isConnected` meant a
    // still-live session from the signed-out account was never replaced.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => mailService.connect(),
    );
  }

  @override
  void dispose() {
    mailService.removeListener(_onUpdate);
    widget.header.controller.pagePos.removeListener(_onPagePos);
    _filterMenuCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // The nav bar and the Spaces square can carry the user off this page, but
  // they live outside this Stack, so the scrim never sees those taps. Fold the
  // strip as soon as the pager leaves this page instead.
  void _onPagePos() {
    if (!_filterMenuOpen) return;
    final n = widget.header.controller.pageCount;
    // Signed shortest circular distance, matching PageFloatingActions.
    var d = (widget.header.index - widget.header.controller.pagePos.value) % n;
    if (d > n / 2) d -= n;
    if (d.abs() > 0.01) _closeFilterMenu();
  }

  void _openFilterMenu() {
    setState(() => _filterMenuOpen = true);
    _filterMenuCtrl.forward();
  }

  void _closeFilterMenu() {
    if (!_filterMenuOpen) return;
    setState(() => _filterMenuOpen = false);
    _filterMenuCtrl.reverse();
  }

  // Each folder is fetched the first time it's opened — the same guards the
  // old header chips ran inline.
  void _selectFilter(_MailFilter f) {
    setState(() => _filter = f);
    if (f == _MailFilter.drafts && !_draftsFetchTriggered) {
      _draftsFetchTriggered = true;
      mailService.fetchDrafts();
    } else if (f == _MailFilter.sent && !_sentFetchTriggered) {
      _sentFetchTriggered = true;
      mailService.fetchSent();
    } else if (f == _MailFilter.trash && !_trashFetchTriggered) {
      _trashFetchTriggered = true;
      mailService.fetchTrash();
    }
    _closeFilterMenu();
  }

  void _onUpdate() {
    if (mounted) {
      setState(() {});
      _syncActionPhase();
    }
  }

  // Mirrors the reload button's busy/done state into the bottom bar's slot.
  void _syncActionPhase() {
    widget.actions.phase.value = mailService.isFetching
        ? ActionPhase.busy
        : _reloadDone
            ? ActionPhase.done
            : ActionPhase.idle;
  }

  void _onReload() {
    if (mailService.isFetching) return;
    mailService.reloadInbox().then((_) {
      if (!mounted) return;
      setState(() => _reloadDone = true);
      _syncActionPhase();
      Future.delayed(const Duration(seconds: 1), () {
        if (!mounted) return;
        setState(() => _reloadDone = false);
        _syncActionPhase();
      });
    });
  }

  void openCompose({MimeMessage? replyTo}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ComposeScreen(replyTo: replyTo),
    );
  }

  // The IMAP folder backing the currently selected filter tab.
  MailFolder get _currentFolder => switch (_filter) {
        _MailFilter.trash  => MailFolder.trash,
        _MailFilter.sent   => MailFolder.sent,
        _MailFilter.drafts => MailFolder.drafts,
        _                  => MailFolder.inbox,
      };

  List<MimeMessage> get _filtered {
    var msgs = switch (_filter) {
      _MailFilter.trash  => mailService.trashedMessages.toList(),
      _MailFilter.sent   => mailService.sentMessages.toList(),
      _MailFilter.drafts => mailService.draftMessages.toList(),
      _                  => mailService.messages.toList(),
    };
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      msgs = msgs.where((m) {
        final from = (m.from?.firstOrNull?.personalName ?? m.fromEmail ?? '')
            .toLowerCase();
        final subject = (m.decodeSubject() ?? '').toLowerCase();
        return from.contains(q) || subject.contains(q);
      }).toList();
    }
    return switch (_filter) {
      _MailFilter.unread   => msgs.where((m) => !m.isSeen).toList(),
      _ => msgs,
    };
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AnimatedBuilder(
      animation: Listenable.merge([
        ThemeService.instance.currentColor,
        ThemeService.instance.glassEnabled,
        // The filter strip's clip follows the bottom cluster's shape, so this
        // page has to rebuild when "Rounded bars" flips.
        ThemeService.instance.roundedBars,
      ]),
      builder: (context, _) => _buildContent(),
    );
  }

  Widget _buildContent() {
    final s = AppColorScheme.current;
    final isTrashTab = _filter == _MailFilter.trash;
    final loading = switch (_filter) {
      _MailFilter.trash  => mailService.isFetchingTrash,
      _MailFilter.sent   => mailService.isFetchingSent,
      _MailFilter.drafts => mailService.isFetchingDrafts,
      _ => mailService.isConnecting || mailService.isFetching,
    };
    final hasData = switch (_filter) {
      _MailFilter.trash  => mailService.trashedMessages.isNotEmpty,
      _MailFilter.sent   => mailService.sentMessages.isNotEmpty,
      _MailFilter.drafts => mailService.draftMessages.isNotEmpty,
      _ => mailService.messages.isNotEmpty,
    };
    final error = mailService.connectionError;

    if (loading && !hasData) {
      return Center(
        child: CircularProgressIndicator(color: s.accent),
      );
    }
    if (!isTrashTab && error != null && !hasData) {
      return _ErrorView(error: error, onRetry: () => mailService.connect());
    }

    final filtered = _filtered;

    // The list page's header without its filter tabs: the same date/clock row
    // and search bar, at the list's sizes. No folder headline: the bottom
    // filter button's icon (accent off the inbox) says which folder is open.
    final view = View.of(context);
    final statusH = view.viewPadding.top / view.devicePixelRatio;
    const topGapH = kHeaderDateRowTopGap;
    const dateRowH = kHeaderDateRowH;
    const searchH = 36.0;
    // Above and below the search bar. On the list the filter tabs sit below
    // it; here the header edge does.
    const searchGapH = 10.0;
    final headerH =
        statusH + topGapH + dateRowH + searchGapH + searchH + searchGapH;

    final titleColor = tokens.AppThemeTokens.titleColor;
    final secondaryColor = tokens.AppThemeTokens.secondaryTextColor;
    final searchRadius = tokens.AppThemeTokens.cardBorderRadius;

    // Both pieces are shared elements: the date row with Mensa and the list,
    // the search bar with the list, so switching between those pages leaves
    // them in place (see MorphingGlassHeader). The search box matches the
    // list's: 10 of gap above a bottom-aligned 36 bar, so both report the
    // same top.
    final searchField = TextField(
      controller: _searchCtrl,
      onChanged: (v) => setState(() => _searchQuery = v),
      style: TextStyle(color: titleColor, fontSize: 14),
      decoration: InputDecoration(
        hintText: 'Search',
        hintStyle: TextStyle(
            color: secondaryColor.withValues(alpha: 0.45),
            fontSize: 14),
        filled: true,
        fillColor: secondaryColor.withValues(alpha: 0.05),
        prefixIcon: Icon(Icons.search,
            color: secondaryColor.withValues(alpha: 0.5), size: 17),
        suffixIcon: _searchQuery.isNotEmpty
            ? GestureDetector(
                onTap: () => setState(() {
                  _searchCtrl.clear();
                  _searchQuery = '';
                }),
                child: Icon(Icons.close,
                    color: secondaryColor, size: 16),
              )
            : null,
        contentPadding: EdgeInsets.zero,
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(searchRadius),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(searchRadius),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(searchRadius),
          borderSide: BorderSide(
              color: tokens.AppThemeTokens.accentColor, width: 1),
        ),
      ),
    );

    final header = MorphingGlassHeader(
      handle: widget.header,
      height: headerH,
      shared: [
        HeaderSharedElement(
          tag: 'date',
          top: statusH + topGapH,
          height: dateRowH,
          child: HeaderDateRow(titleColor: titleColor),
        ),
        HeaderSharedElement(
          tag: 'search',
          top: statusH + topGapH + dateRowH,
          height: searchGapH + searchH,
          horizontalInset: 20,
          // A typed query wouldn't match the list's field; fade it instead.
          shareable: _searchQuery.isEmpty,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                bottom: 0, left: 0, right: 0, height: searchH,
                child: searchField,
              ),
            ],
          ),
        ),
      ],
      // Nothing of its own left to fade — both pieces are shared.
      child: const SizedBox.shrink(),
    );

    return Stack(
      children: [
        RefreshIndicator(
          color: s.accent,
          onRefresh: () => switch (_filter) {
            _MailFilter.trash  => mailService.fetchTrash(),
            _MailFilter.sent   => mailService.fetchSent(),
            _MailFilter.drafts => mailService.fetchDrafts(),
            _ => mailService.reloadInbox(),
          },
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverPadding(padding: EdgeInsets.only(top: headerH)),
              if (!hasData)
                SliverFillRemaining(
                  child: _EmptyState(
                    subtitle: switch (_filter) {
                      _MailFilter.drafts => 'No drafts.',
                      _MailFilter.sent   => 'No sent mail.',
                      _MailFilter.trash  => 'Trash is empty.',
                      _ => 'Your inbox is empty.',
                    },
                  ),
                )
              else if (filtered.isEmpty)
                SliverFillRemaining(
                  child: Center(
                    child: Text(
                      'No emails match this filter.',
                      style: AppTextStyles.body(
                          color: tokens.AppThemeTokens.secondaryTextColor),
                    ),
                  ),
                )
              else
                SliverPadding(
                  // 48 of breathing room, plus clearance for the floating
                  // bottom cluster the list now scrolls behind.
                  padding: EdgeInsets.only(
                      bottom: 48 + bottomClusterHeight(context)),
                  sliver: SliverList.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox.shrink(),
                    itemBuilder: (ctx, i) {
                      final msg = filtered[i];
                      return _SwipeableEmailCard(
                        key: ValueKey(
                            'email_${msg.uid ?? msg.sequenceId ?? msg.hashCode}'),
                        message: msg,
                        onTap: () {
                          final folder = _currentFolder;
                          Navigator.push<void>(
                            context,
                            CupertinoPageRoute(
                              builder: (_) => EmailDetailScreen(
                                message: msg,
                                folder: folder,
                                onReply: (m) => openCompose(replyTo: m),
                              ),
                            ),
                          );
                        },
                        onDelete: () => mailService.deleteMessage(msg,
                            folder: _currentFolder),
                        isArchiveItem: isTrashTab,
                        onRestore: () => mailService.restoreFromTrash(msg),
                        onToggleRead: () {
                          if (msg.isSeen) {
                            mailService.markAsUnread(msg,
                                folder: _currentFolder);
                          } else {
                            mailService.markAsRead(msg,
                                folder: _currentFolder);
                          }
                        },
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
        Positioned(top: 0, left: 0, right: 0, child: header),

        // Folds the filter strip on a tap anywhere outside it. Has to sit
        // before PageFloatingActions: it's opaque while the strip is open and
        // would swallow the strip's own taps from above.
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !_filterMenuOpen,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closeFilterMenu,
              child: FadeTransition(
                opacity: _filterMenuAnim,
                child: const ColoredBox(color: Color(0x26000000)),
              ),
            ),
          ),
        ),

        // ── Compose + filter ──────────────────────────────────────────────
        // Same material, size and baseline as the Spaces mini bar's square,
        // mirrored to the right-hand side. Must stay last in this Stack.
        PageFloatingActions(
          handle: widget.header,
          children: [
            _FilterCluster(
              progress: _filterMenuAnim,
              active: _filter,
              open: _filterMenuOpen,
              onOpen: _openFilterMenu,
              onClose: _closeFilterMenu,
              onSelect: _selectFilter,
              onCompose: openCompose,
            ),
          ],
        ),
      ],
    );
  }
}

// ── Filter cluster ────────────────────────────────────────────────────────────

/// Width of each folder slot in the open filter strip — the same nominal 48 as
/// the bottom bar's reload/settings slots (`_utilSlotW`).
const double _kStripSlotW = 48.0;

/// Open width of the filter strip: five folder slots, plus the corner slot,
/// which keeps the closed button's full 50 so its glyph never moves.
///
/// Has to stay clear of the Spaces square, which HomeScreen paints *above*
/// every page at `left: 12`, 50 wide. That leaves the strip W − 82 (12 + 50, an
/// 8 gap, and the 12 right inset): 293 on a 375-pt iPhone, the narrowest one.
/// Another slot, or a wider one, stops fitting there.
const double _kStripW = kFloatingButtonSize + 5 * _kStripSlotW;

/// Compose sits one button plus the cluster's usual 8 gap in from the corner.
const double _kComposeRight = kFloatingButtonSize + 8;

/// Folder order in the strip, left to right.
const _kStripFilters = [
  _MailFilter.all,
  _MailFilter.unread,
  _MailFilter.drafts,
  _MailFilter.sent,
  _MailFilter.trash,
];

/// Compose and the filter button, bottom-right.
///
/// Closed, the filter button shows the active folder's icon, in accent on any
/// folder but the inbox. Tapped, it widens leftwards into a strip of
/// folder icons over the compose button, with ✕ in the corner it started from.
/// A caption above the strip names the active folder, or whichever icon is
/// under the finger, so holding an icon reads its name and sliding off cancels.
class _FilterCluster extends StatefulWidget {
  const _FilterCluster({
    required this.progress,
    required this.active,
    required this.open,
    required this.onOpen,
    required this.onClose,
    required this.onSelect,
    required this.onCompose,
  });

  /// 0 = closed button, 1 = fully open strip.
  final Animation<double> progress;
  final _MailFilter active;
  final bool open;
  final VoidCallback onOpen;
  final VoidCallback onClose;
  final ValueChanged<_MailFilter> onSelect;
  final VoidCallback onCompose;

  @override
  State<_FilterCluster> createState() => _FilterClusterState();
}

class _FilterClusterState extends State<_FilterCluster> {
  /// The folder under the finger, if any — the caption follows it.
  _MailFilter? _pressed;

  @override
  void didUpdateWidget(covariant _FilterCluster oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.open) _pressed = null;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.progress,
    builder: (context, _) => _buildCluster(widget.progress.value),
  );

  Widget _buildCluster(double t) {
    final s = AppColorScheme.current;
    final iconColor = tokens.AppThemeTokens.navBarIcon;
    final pillW = lerpDouble(kFloatingButtonSize, _kStripW, t)!;

    // Gone before the strip's edge is most of the way across it — the glass
    // is translucent, so compose would otherwise show through.
    final composeOpacity = (1 - (pillW - kFloatingButtonSize) / 30)
        .clamp(0.0, 1.0)
        .toDouble();

    final caption = _pressed ?? widget.active;
    final captionX =
        _kStripFilters.indexOf(caption) * _kStripSlotW + _kStripSlotW / 2;
    final captionOpacity = ((t - 0.75) / 0.25).clamp(0.0, 1.0).toDouble();

    final strip = ClipRRect(
      borderRadius: BorderRadius.circular(GlassPill.defaultRadius()),
      // Laid out at full width from the start and revealed by the pill's
      // growing edge, so nothing reflows mid-morph.
      child: OverflowBox(
        alignment: Alignment.centerRight,
        minWidth: _kStripW,
        maxWidth: _kStripW,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < _kStripFilters.length; i++)
              _buildSlot(
                _kStripFilters[i],
                // Each icon fades in as the edge sweeps across its slot, so
                // they arrive right-to-left and leave in reverse.
                reveal:
                    ((pillW -
                                kFloatingButtonSize -
                                (_kStripFilters.length - 1 - i) *
                                    _kStripSlotW) /
                            _kStripSlotW)
                        .clamp(0.0, 1.0)
                        .toDouble(),
                s: s,
                iconColor: iconColor,
              ),
            _buildCorner(t, s, iconColor),
          ],
        ),
      ),
    );

    return SizedBox(
      width: _kStripW,
      height: kFloatingButtonSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            right: _kComposeRight,
            bottom: 0,
            child: IgnorePointer(
              ignoring: t > 0,
              child: Opacity(
                opacity: composeOpacity,
                child: Semantics(
                  container: true,
                  button: true,
                  label: 'New mail',
                  child: GestureDetector(
                    onTap: widget.onCompose,
                    child: GlassPill(
                      child: SizedBox(
                        width: kFloatingButtonSize,
                        height: kFloatingButtonSize,
                        child: Icon(
                          Icons.edit_outlined,
                          color: iconColor,
                          size: 24,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            width: pillW,
            height: kFloatingButtonSize,
            child: GlassPill(child: strip),
          ),
          if (t > 0)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOutCubic,
              left: captionX,
              bottom: kFloatingButtonSize + 8,
              // A visual echo of the slot labels below — VoiceOver already
              // reads those, so it shouldn't read this one twice.
              child: ExcludeSemantics(
                child: IgnorePointer(
                  child: Opacity(
                    opacity: captionOpacity,
                    child: FractionalTranslation(
                      translation: const Offset(-0.5, 0),
                      child: GlassPill(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 5,
                          ),
                          child: Text(
                            caption.label,
                            style: AppTextStyles.bodySmall(
                              color: caption == widget.active
                                  ? s.accent
                                  : tokens.AppThemeTokens.titleColor,
                            ).copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSlot(
    _MailFilter f, {
    required double reveal,
    required AppColorScheme s,
    required Color iconColor,
  }) {
    return SizedBox(
      width: _kStripSlotW,
      // The clip only hides the slots while the strip is closed — they stay
      // in the tree, so VoiceOver has to be told to skip them.
      child: ExcludeSemantics(
        excluding: !widget.open,
        child: Semantics(
          container: true,
          button: true,
          selected: f == widget.active,
          label: f.label,
          child: IgnorePointer(
            ignoring: !widget.open,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) => setState(() => _pressed = f),
              onTapUp: (_) {
                setState(() => _pressed = null);
                widget.onSelect(f);
              },
              onTapCancel: () => setState(() => _pressed = null),
              child: Center(
                child: Opacity(
                  opacity: reveal,
                  child: AnimatedScale(
                    scale: _pressed == f ? 0.85 : 1.0,
                    duration: const Duration(milliseconds: 100),
                    child: Transform.scale(
                      scale: 0.7 + 0.3 * reveal,
                      child: Icon(
                        f.icon,
                        color: f == widget.active ? s.accent : iconColor,
                        size: 22 * f.iconScale,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The closed button's glyph cross-fading into the strip's ✕.
  Widget _buildCorner(double t, AppColorScheme s, Color iconColor) {
    final active = widget.active;
    return SizedBox(
      width: kFloatingButtonSize,
      child: Semantics(
        container: true,
        button: true,
        label: widget.open ? 'Close folders' : 'Folders',
        value: widget.open ? null : active.label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.open ? widget.onClose : widget.onOpen,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: (1 - 2 * t).clamp(0.0, 1.0).toDouble(),
                child: Icon(
                  active.icon,
                  // Neutral on the inbox, the default view; accent anywhere
                  // else, as a reminder that the list is not the inbox.
                  color: active == _MailFilter.all ? iconColor : s.accent,
                  size: 24 * active.iconScale,
                ),
              ),
              Opacity(
                opacity: (2 * t - 1).clamp(0.0, 1.0).toDouble(),
                child: Icon(CupertinoIcons.xmark, color: iconColor, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Swipeable wrapper ─────────────────────────────────────────────────────────

class _SwipeableEmailCard extends StatelessWidget {
  const _SwipeableEmailCard({
    super.key,
    required this.message,
    required this.onTap,
    required this.onDelete,
    required this.onToggleRead,
    this.isArchiveItem = false,
    this.onRestore,
  });

  final MimeMessage message;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onToggleRead;
  final bool isArchiveItem;
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    final isUnread = !message.isSeen;

    // Swipe action label style — 11sp w600 on colored surfaces
    final swipeLabel = AppTextStyles.caption(color: Colors.white)
        .copyWith(fontWeight: FontWeight.w600, fontSize: 11);

    return Dismissible(
      key: ValueKey(
          'dismiss_${message.uid ?? message.sequenceId ?? message.hashCode}'),
      direction: DismissDirection.horizontal,
      dismissThresholds: const {
        DismissDirection.endToStart: 0.4,
        DismissDirection.startToEnd: 0.4,
      },
      // Right-swipe: toggle read/unread (accent orange)
      background: Container(
        color: s.accent,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isUnread ? CupertinoIcons.envelope_open : CupertinoIcons.envelope,
              color: Colors.white, // on accent — intentionally white
              size: 22,
            ),
            const SizedBox(height: 4),
            Text(isUnread ? 'Read' : 'Unread', style: swipeLabel),
          ],
        ),
      ),
      // Left-swipe: delete (danger) or restore (success)
      secondaryBackground: Container(
        color: isArchiveItem ? s.success : s.danger,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isArchiveItem
                  ? Icons.move_to_inbox_outlined
                  : CupertinoIcons.delete,
              color: Colors.white, // on success/danger — intentionally white
              size: 22,
            ),
            const SizedBox(height: 4),
            Text(isArchiveItem ? 'Restore' : 'Delete', style: swipeLabel),
          ],
        ),
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.endToStart) {
          HapticFeedback.mediumImpact();
          if (isArchiveItem) {
            onRestore?.call();
          } else {
            onDelete();
          }
          return true;
        }
        onToggleRead();
        return false;
      },
      child: _EmailCard(message: message, onTap: onTap),
    );
  }
}

// ── Email card ────────────────────────────────────────────────────────────────

class _EmailCard extends StatelessWidget {
  const _EmailCard({required this.message, required this.onTap});

  final MimeMessage message;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    final isUnread = !message.isSeen;

    final fromPersonal = message.from?.firstOrNull?.personalName;
    final senderName = (fromPersonal != null && fromPersonal.isNotEmpty)
        ? fromPersonal
        : message.fromEmail ?? 'Unknown';
    final subject = message.decodeSubject() ?? '(No subject)';
    final preview = _extractPreview(message);
    final dateStr = _formatDate(message.decodeDate());
    final initial = senderName.isNotEmpty ? senderName[0].toUpperCase() : '?';
    final hasAttachments = message
        .findContentInfo(disposition: ContentDisposition.attachment)
        .isNotEmpty;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        highlightColor: s.accent.withValues(alpha: 0.06),
        splashColor:    s.accent.withValues(alpha: 0.04),
        child: DecoratedBox(
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
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Unread dot
                SizedBox(
                  width: 12,
                  child: isUnread
                      ? Padding(
                          padding: const EdgeInsets.only(top: 15),
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: s.accent,
                            ),
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 4),
                // Avatar
                CircleAvatar(
                  radius: 20,
                  backgroundColor: AppAvatarPalette.forName(senderName),
                  child: Text(
                    initial,
                    style: const TextStyle(
                      color: Colors.white, // on avatar color — intentionally white
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Text content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Expanded(
                            child: Text(
                              senderName,
                              style: AppTextStyles.senderName(
                                color: tokens.AppThemeTokens.titleColor,
                                unread: isUnread,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (hasAttachments) ...[
                                Icon(Icons.attach_file,
                                    size: 12,
                                    color: tokens.AppThemeTokens
                                        .secondaryTextColor),
                                const SizedBox(width: 2),
                              ],
                              Text(
                                dateStr,
                                style: AppTextStyles.timestamp(
                                  color: isUnread
                                      ? s.accent
                                      : tokens.AppThemeTokens.secondaryTextColor,
                                  unread: isUnread,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subject,
                        style: AppTextStyles.bodySmall(
                          color: tokens.AppThemeTokens.titleColor
                              .withValues(alpha: 0.85),
                        ).copyWith(
                          fontWeight:
                              isUnread ? FontWeight.w600 : FontWeight.w400,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        preview,
                        style: AppTextStyles.caption(
                          color: tokens.AppThemeTokens.secondaryTextColor,
                        ).copyWith(height: 1.4),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _extractPreview(MimeMessage msg) {
    final plain = msg.decodeTextPlainPart();
    if (plain != null) {
      final t = plain.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (t.length > 3) return t;
    }
    final html = msg.decodeTextHtmlPart();
    if (html != null) {
      final t = html
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (t.length > 3) return t;
    }
    return '';
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(date.year, date.month, date.day);

    if (msgDay == today) {
      return '${date.hour.toString().padLeft(2, '0')}:'
          '${date.minute.toString().padLeft(2, '0')}';
    }

    final weekStart = today.subtract(Duration(days: today.weekday - 1));
    if (!msgDay.isBefore(weekStart)) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[date.weekday - 1];
    }

    const mo = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${mo[date.month - 1]} ${date.day}';
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({this.subtitle = 'Your inbox is empty.'});

  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(CupertinoIcons.tray,
              size: 52, color: tokens.AppThemeTokens.secondaryTextColor),
          const SizedBox(height: 16),
          Text(
            'No emails',
            style: AppTextStyles.navTitle(color: tokens.AppThemeTokens.titleColor)
                .copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: AppTextStyles.body(
                color: tokens.AppThemeTokens.secondaryTextColor),
          ),
        ],
      ),
    );
  }
}

// ── Error view ────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

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
            Text(
              'Could not load mail',
              style: AppTextStyles.navTitle(
                      color: tokens.AppThemeTokens.titleColor)
                  .copyWith(fontWeight: FontWeight.w600),
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
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
