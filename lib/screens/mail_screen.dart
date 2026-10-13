import 'dart:async';
import 'dart:math' as math;

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/app_theme.dart' as tokens;
import '../services/mail_actions.dart';
import '../services/mail_display.dart';
import '../services/mail_previews.dart';
import '../services/mail_service.dart' show MailFolder;
import '../services/page_actions.dart';
import '../services/service_locator.dart';
import '../services/theme_service.dart';
import '../theme/tokens.dart';
import '../widgets/glass_pill.dart';
import '../widgets/header_date_row.dart';
import '../widgets/mail_route_layer.dart';
import '../widgets/mail_row.dart';
import '../widgets/morphing_glass_header.dart';
import '../widgets/page_floating_actions.dart';
import '../widgets/swipe_action_row.dart';
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
  /// just like the Mail tab icon right below the strip, so Unread is the
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

/// The folder headline below the header's search bar: its line, and the
/// padding below it to the header edge.
const double _kHeadlineH = 20.0;
const double _kHeadlineBottomH = 8.0;

class MailScreen extends StatefulWidget {
  const MailScreen({super.key, required this.actions, required this.header});

  final PageActionController actions;
  final PageHeaderHandle header;

  @override
  State<MailScreen> createState() => _MailScreenState();
}

class _MailScreenState extends State<MailScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  _MailFilter _filter = _MailFilter.all;
  bool _trashFetchTriggered = false;
  bool _sentFetchTriggered = false;
  bool _draftsFetchTriggered = false;
  bool _reloadDone = false;
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  /// Optimistic read flags, deletes and restores — shared with an open mail.
  late final MailActions _mailActions = MailActions(onFailure: _showToast);
  final _swipeGroup = SwipeGroup();

  /// The rows on screen, recomputed when the data, filter or search change —
  /// never in `build`.
  List<MimeMessage> _visible = const [];
  Map<String, int> _indexByKey = const {};

  /// Mails read while the Unread filter is on stay listed until it changes,
  /// as in Apple Mail — otherwise a row would vanish mid-swipe.
  final _keepInUnread = <String>{};

  String? _toast;
  Timer? _toastTimer;

  Widget? _header;
  Object? _headerKey;

  @override
  void initState() {
    super.initState();
    widget.actions.handler = _onReload;
    mailService.addListener(_onUpdate);
    _mailActions.addListener(_onUpdate);
    MailPreviews.instance.addListener(_onPreviews);
    _recompute();
    // Unconditional: `connect()` guards on its own flags, and it now clears
    // the previous account's state first. Gating here on `isConnected` meant a
    // still-live session from the signed-out account was never replaced.
    WidgetsBinding.instance.addPostFrameCallback((_) => mailService.connect());
  }

  @override
  void dispose() {
    mailService.removeListener(_onUpdate);
    _mailActions.removeListener(_onUpdate);
    _mailActions.dispose();
    MailPreviews.instance.removeListener(_onPreviews);
    _searchCtrl.dispose();
    _toastTimer?.cancel();
    super.dispose();
  }

  // Each folder is fetched the first time it's opened — the same guards the
  // old header chips ran inline.
  void _selectFilter(_MailFilter f) {
    _swipeGroup.closeAll();
    _keepInUnread.clear();
    setState(() {
      _filter = f;
      _recompute();
    });
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
  }

  void _onUpdate() {
    if (mounted) {
      setState(_recompute);
      _syncActionPhase();
    }
  }

  void _onPreviews() {
    if (mounted) setState(() {});
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

  void _showToast(String message) {
    if (!mounted) return;
    HapticFeedback.heavyImpact();
    _toastTimer?.cancel();
    setState(() => _toast = message);
    _toastTimer = Timer(const Duration(milliseconds: 2600), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  // The IMAP folder backing the currently selected filter tab.
  MailFolder get _currentFolder => switch (_filter) {
    _MailFilter.trash => MailFolder.trash,
    _MailFilter.sent => MailFolder.sent,
    _MailFilter.drafts => MailFolder.drafts,
    _ => MailFolder.inbox,
  };

  void _recompute() {
    final folder = _currentFolder;
    Iterable<MimeMessage> msgs = switch (_filter) {
      _MailFilter.trash => mailService.trashedMessages,
      _MailFilter.sent => mailService.sentMessages,
      _MailFilter.drafts => mailService.draftMessages,
      _ => mailService.messages,
    };
    msgs = msgs.where((m) => !_mailActions.isHidden(m, folder));
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      msgs = msgs.where((m) {
        final row = MailRowData.of(m, folder);
        return row.title.toLowerCase().contains(q) ||
            row.subject.toLowerCase().contains(q);
      });
    }
    if (_filter == _MailFilter.unread) {
      msgs = msgs.where(
        (m) =>
            !m.isSeen || _keepInUnread.contains(MailActions.keyOf(m, folder)),
      );
    }
    _visible = msgs.toList();
    if (folder == MailFolder.inbox) {
      MailPreviews.instance.fillMissing(
        mailService.messages,
        (m) => MailRowData.of(m, MailFolder.inbox).preview,
      );
    }
    _indexByKey = {
      for (var i = 0; i < _visible.length; i++)
        MailActions.keyOf(_visible[i], folder): i,
    };
  }

  // ── Actions ──────────────────────────────────────────────────────────────

  void _toggleSeen(MimeMessage msg) {
    final folder = _currentFolder;
    if (_filter == _MailFilter.unread) {
      _keepInUnread.add(MailActions.keyOf(msg, folder));
    }
    _mailActions.toggleSeen(msg, folder);
  }

  void _open(MimeMessage msg) {
    _swipeGroup.closeAll();
    final folder = _currentFolder;
    if (folder == MailFolder.drafts) {
      // A saved draft reopens in compose; its body loads there.
      openComposeSheet(
        context,
        draft: ComposeDraft(
          to: msg.to?.firstOrNull?.email ?? '',
          subject: msg.decodeSubject() ?? '',
          from: msg.from?.firstOrNull?.email,
        ),
        replacing: msg,
      );
      return;
    }
    if (_filter == _MailFilter.unread) {
      _keepInUnread.add(MailActions.keyOf(msg, folder));
    }
    // Read on open, as before — here rather than in the opened screen, so
    // the dot clears as the mail slides in and no build is interrupted.
    _mailActions.setSeen(msg, folder, true);
    MailRouteLayer.push(
      CupertinoPageRoute<void>(
        builder: (_) => EmailDetailScreen(
          message: msg,
          folder: folder,
          actions: _mailActions,
          onReply: (full) => openComposeSheet(context, draft: replyDraft(full)),
          onForward: (full) =>
              openComposeSheet(context, draft: forwardDraft(full)),
          onMailto: (uri) => openComposeSheet(context, draft: mailtoDraft(uri)),
        ),
      ),
    );
  }

  void openCompose() => openComposeSheet(context);

  Future<void> _refresh() => switch (_filter) {
    _MailFilter.trash => mailService.fetchTrash(),
    _MailFilter.sent => mailService.fetchSent(),
    _MailFilter.drafts => mailService.fetchDrafts(),
    _ => mailService.reloadInbox(),
  }.then((_) {});

  // ── Build ────────────────────────────────────────────────────────────────

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

  /// The list page's header with the folder's name in place of its filter
  /// tabs: the same date/clock row and search bar, at the list's sizes. Built
  /// only when the theme, the search state or the folder changes, not on every
  /// mail update.
  Widget _buildHeader(double statusH, double headerH) {
    final key = (
      AppColorScheme.current,
      ThemeService.instance.glassEnabled.value,
      _searchQuery.isEmpty,
      statusH,
      _filter,
    );
    final cached = _header;
    if (cached != null && key == _headerKey) return cached;
    _headerKey = key;

    const topGapH = kHeaderDateRowTopGap;
    const dateRowH = kHeaderDateRowH;
    const searchH = 36.0;
    // Above and below the search bar. On the list the filter tabs sit below
    // it; here the folder headline does.
    const searchGapH = 10.0;

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
      onChanged: (v) => setState(() {
        _searchQuery = v;
        _recompute();
      }),
      style: TextStyle(color: titleColor, fontSize: 14),
      decoration: InputDecoration(
        hintText: 'Search',
        hintStyle: TextStyle(
          color: secondaryColor.withValues(alpha: 0.45),
          fontSize: 14,
        ),
        filled: true,
        fillColor: secondaryColor.withValues(alpha: 0.05),
        prefixIcon: Icon(
          Icons.search,
          color: secondaryColor.withValues(alpha: 0.5),
          size: 17,
        ),
        suffixIcon: _searchQuery.isNotEmpty
            ? GestureDetector(
                onTap: () => setState(() {
                  _searchCtrl.clear();
                  _searchQuery = '';
                  _recompute();
                }),
                child: Icon(Icons.close, color: secondaryColor, size: 16),
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
            color: tokens.AppThemeTokens.accentColor,
            width: 1,
          ),
        ),
      ),
    );

    return _header = MorphingGlassHeader(
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
                bottom: 0,
                left: 0,
                right: 0,
                height: searchH,
                child: searchField,
              ),
            ],
          ),
        ),
      ],
      // The folder's name, the header's only piece of its own, so the one that
      // fades on a page switch. Left-aligned with the search bar.
      child: Padding(
        padding: EdgeInsets.only(
          top: statusH +
              topGapH +
              dateRowH +
              searchGapH +
              searchH +
              searchGapH,
          left: 20,
          right: 20,
        ),
        child: SizedBox(
          height: _kHeadlineH,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Semantics(
              header: true,
              child: Text(
                _filter.label,
                maxLines: 1,
                style: AppTextStyles.bodyLarge(color: titleColor)
                    .copyWith(fontWeight: FontWeight.w600, height: 1.2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    final s = AppColorScheme.current;
    final folder = _currentFolder;
    final isTrashTab = _filter == _MailFilter.trash;
    final loading = switch (_filter) {
      _MailFilter.trash => mailService.isFetchingTrash,
      _MailFilter.sent => mailService.isFetchingSent,
      _MailFilter.drafts => mailService.isFetchingDrafts,
      _ => mailService.isConnecting || mailService.isFetching,
    };
    final hasData = switch (_filter) {
      _MailFilter.trash => mailService.trashedMessages.isNotEmpty,
      _MailFilter.sent => mailService.sentMessages.isNotEmpty,
      _MailFilter.drafts => mailService.draftMessages.isNotEmpty,
      _ => mailService.messages.isNotEmpty,
    };
    final error = mailService.connectionError;

    final view = View.of(context);
    final statusH = view.viewPadding.top / view.devicePixelRatio;
    final headerH = statusH +
        kHeaderDateRowTopGap +
        kHeaderDateRowH +
        10.0 +
        36.0 +
        10.0 +
        _kHeadlineH +
        _kHeadlineBottomH;
    final header = _buildHeader(statusH, headerH);
    final styles = MailListStyles.of(s);

    Widget body;
    if (loading && !hasData) {
      body = Padding(
        padding: EdgeInsets.only(top: headerH),
        child: const Center(child: CupertinoActivityIndicator(radius: 12)),
      );
    } else if (!isTrashTab && error != null && !hasData) {
      body = Padding(
        padding: EdgeInsets.only(top: headerH),
        child: _ErrorView(error: error, onRetry: () => mailService.connect()),
      );
    } else {
      body = NotificationListener<ScrollStartNotification>(
        onNotification: (n) {
          // A user scroll closes an open swipe, as on iOS.
          if (n.dragDetails != null) _swipeGroup.closeAll();
          return false;
        },
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            CupertinoSliverRefreshControl(
              onRefresh: _refresh,
              // The control sits at the very top of the scroll view, under
              // the glass header; its spinner is drawn below the header.
              builder: (context, mode, pulled, trigger, extent) =>
                  Transform.translate(
                    offset: Offset(0, headerH),
                    child: CupertinoSliverRefreshControl.buildRefreshIndicator(
                      context,
                      mode,
                      pulled,
                      trigger,
                      extent,
                    ),
                  ),
            ),
            // The header's glass edge overhangs its height a little; the
            // first row starts just below it.
            SliverPadding(padding: EdgeInsets.only(top: headerH + 4)),
            if (!hasData)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyState(
                  title: 'No Mail',
                  subtitle: switch (_filter) {
                    _MailFilter.drafts => 'No drafts.',
                    _MailFilter.sent => 'No sent mail.',
                    _MailFilter.trash => 'Trash is empty.',
                    _ => 'Your inbox is empty.',
                  },
                  bottom: headerH,
                ),
              )
            else if (_visible.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyState(
                  title: _searchQuery.isNotEmpty ? 'No Results' : 'All Read',
                  subtitle: _searchQuery.isNotEmpty
                      ? 'No mail matches “$_searchQuery”.'
                      : 'No unread mail.',
                  bottom: headerH,
                ),
              )
            else
              SliverPadding(
                // Clearance for the floating bottom cluster the list scrolls
                // behind and the folder strip above it, so the last row ends
                // clear of them.
                padding: EdgeInsets.only(
                  bottom: bottomClusterHeight(context) +
                      kFloatingButtonSize +
                      16,
                ),
                sliver: SliverList.builder(
                  itemCount: _visible.length,
                  findChildIndexCallback: (key) =>
                      _indexByKey[(key as ValueKey<String>).value],
                  itemBuilder: (context, i) {
                    final msg = _visible[i];
                    final key = MailActions.keyOf(msg, folder);
                    final seen = _mailActions.isSeen(msg, folder);
                    return SwipeActionRow(
                      key: ValueKey(key),
                      group: _swipeGroup,
                      leading: SwipeAction(
                        icon: seen
                            ? CupertinoIcons.envelope_badge
                            : CupertinoIcons.envelope_open,
                        label: seen ? 'Unread' : 'Read',
                        color: s.accent,
                        onTriggered: () => _toggleSeen(msg),
                      ),
                      trailing: isTrashTab
                          ? SwipeAction(
                              icon: CupertinoIcons.tray_arrow_up,
                              label: 'Restore',
                              color: s.success,
                              destructive: true,
                              onTriggered: () => _mailActions.restore(msg),
                            )
                          : SwipeAction(
                              icon: CupertinoIcons.trash,
                              label: 'Delete',
                              color: s.danger,
                              destructive: true,
                              onTriggered: () =>
                                  _mailActions.delete(msg, folder),
                            ),
                      child: MailRow(
                        data: MailRowData.of(msg, folder),
                        preview: MailPreviews.instance.previewFor(msg),
                        unread: !seen,
                        styles: styles,
                        onTap: () => _open(msg),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(color: styles.background, child: body),
        ),
        Positioned(top: 0, left: 0, right: 0, child: header),

        // Rolled-back optimistic changes: a small pill above the cluster.
        Positioned(
          left: 0,
          right: 0,
          bottom: bottomClusterHeight(context) + kFloatingButtonSize + 20,
          child: IgnorePointer(
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: _toast == null
                    ? const SizedBox.shrink()
                    : GlassPill(
                        key: ValueKey(_toast),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          child: Text(
                            _toast!,
                            style: AppTextStyles.bodySmall(
                              color: tokens.AppThemeTokens.titleColor,
                            ).copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ),

        // ── Folders + compose ─────────────────────────────────────────────
        // Same material, size and baseline as the Spaces mini bar's square;
        // compose mirrors it on the right-hand side. Must stay last in this
        // Stack.
        PageFloatingActions(
          handle: widget.header,
          children: [
            _FilterCluster(
              active: _filter,
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

/// Width of each folder slot in the filter strip — the same nominal 48 as the
/// bottom bar's reload/settings slots (`_utilSlotW`).
const double _kStripSlotW = 48.0;

/// The cluster's usual gap, kept between the strip and the buttons either side.
const double _kStripGap = 8.0;

/// PageFloatingActions' side inset, which the Spaces square's `left: 12` and
/// compose share.
const double _kClusterSideInset = 12.0;

/// Folder order in the strip, left to right.
const _kStripFilters = [
  _MailFilter.all,
  _MailFilter.unread,
  _MailFilter.drafts,
  _MailFilter.sent,
  _MailFilter.trash,
];

/// The folder strip, centred, and compose in the bottom-right corner.
///
/// The active folder's icon is in accent, and the header names it.
class _FilterCluster extends StatefulWidget {
  const _FilterCluster({
    required this.active,
    required this.onSelect,
    required this.onCompose,
  });

  final _MailFilter active;
  final ValueChanged<_MailFilter> onSelect;
  final VoidCallback onCompose;

  @override
  State<_FilterCluster> createState() => _FilterClusterState();
}

class _FilterClusterState extends State<_FilterCluster> {
  /// The folder under the finger, if any — its icon shrinks a little.
  _MailFilter? _pressed;

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    final iconColor = tokens.AppThemeTokens.navBarIcon;

    // The cluster spans the screen between PageFloatingActions' insets.
    // HomeScreen paints the Spaces square *above* every page at `left: 12`, 50
    // wide, and compose mirrors it on the right, so the strip sits centred
    // between the two. Where they and the 8 gaps leave less than five full
    // slots (235 on a 375-pt iPhone, the narrowest one), the slots narrow.
    final clusterW = MediaQuery.sizeOf(context).width - 2 * _kClusterSideInset;
    final slotW = math.min(
      _kStripSlotW,
      (clusterW - 2 * (kFloatingButtonSize + _kStripGap)) /
          _kStripFilters.length,
    );
    final stripW = slotW * _kStripFilters.length;
    final stripLeft = (clusterW - stripW) / 2;

    return SizedBox(
      width: clusterW,
      height: kFloatingButtonSize,
      child: Stack(
        // Off-glass the pills cast a shadow past the cluster's bounds.
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: stripLeft,
            bottom: 0,
            width: stripW,
            height: kFloatingButtonSize,
            child: GlassPill(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final f in _kStripFilters)
                    _buildSlot(f, s: s, iconColor: iconColor),
                ],
              ),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
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
        ],
      ),
    );
  }

  Widget _buildSlot(
    _MailFilter f, {
    required AppColorScheme s,
    required Color iconColor,
  }) {
    // Expanded rather than a fixed width: the pill's hairline border takes a
    // little of the strip's inside.
    return Expanded(
      child: Semantics(
        container: true,
        button: true,
        selected: f == widget.active,
        label: f.label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = f),
          onTapUp: (_) {
            setState(() => _pressed = null);
            widget.onSelect(f);
          },
          onTapCancel: () => setState(() => _pressed = null),
          child: Center(
            child: AnimatedScale(
              scale: _pressed == f ? 0.85 : 1.0,
              duration: const Duration(milliseconds: 100),
              child: Icon(
                f.icon,
                color: f == widget.active ? s.accent : iconColor,
                size: 22 * f.iconScale,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.title,
    required this.subtitle,
    this.bottom = 0,
  });

  final String title;
  final String subtitle;

  /// Shifts the block up by the header's height, so it centres in the visible
  /// area rather than in the scroll extent below the header.
  final double bottom;

  @override
  Widget build(BuildContext context) {
    final secondary = tokens.AppThemeTokens.secondaryTextColor;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom + bottomClusterHeight(context)),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.tray, size: 44, color: secondary),
            const SizedBox(height: 14),
            Text(
              title,
              style: AppTextStyles.navTitle(
                color: tokens.AppThemeTokens.titleColor,
              ),
            ),
            const SizedBox(height: 4),
            Text(subtitle, style: AppTextStyles.body(color: secondary)),
          ],
        ),
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
    final secondary = tokens.AppThemeTokens.secondaryTextColor;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              CupertinoIcons.exclamationmark_circle,
              size: 44,
              color: secondary,
            ),
            const SizedBox(height: 14),
            Text(
              'Could not load mail',
              style: AppTextStyles.navTitle(
                color: tokens.AppThemeTokens.titleColor,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              error,
              style: AppTextStyles.bodySmall(color: secondary),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 20),
            CupertinoButton(
              color: s.accent,
              borderRadius: BorderRadius.circular(AppRadius.pill),
              padding: const EdgeInsets.symmetric(horizontal: 22),
              onPressed: onRetry,
              child: Text(
                'Try Again',
                style: AppTextStyles.bodyBold(color: s.onAccent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
