import 'dart:ui';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/app_theme.dart' as tokens;
import '../services/mail_service.dart' show MailFolder;
import '../services/service_locator.dart';
import '../services/theme_service.dart';
import '../theme/tokens.dart';
import 'compose_screen.dart';
import 'email_detail_screen.dart';
import 'settings_screen.dart';

enum _MailFilter { all, unread, drafts, sent, trash }

class MailScreen extends StatefulWidget {
  const MailScreen({super.key});

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

  @override
  void initState() {
    super.initState();
    mailService.addListener(_onUpdate);
    if (!mailService.isConnected && !mailService.isConnecting) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => mailService.connect(),
      );
    }
  }

  @override
  void dispose() {
    mailService.removeListener(_onUpdate);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  void _onReload() {
    if (mailService.isFetching) return;
    mailService.reloadInbox().then((_) {
      if (!mounted) return;
      setState(() => _reloadDone = true);
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) setState(() => _reloadDone = false);
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
    final radius = tokens.AppThemeTokens.cardBorderRadius;

    final view = View.of(context);
    final statusH = view.viewPadding.top / view.devicePixelRatio;
    const filterH = 110.0;
    final headerH = statusH + kToolbarHeight + filterH;

    final glass   = ThemeService.instance.glassEnabled.value;
    final glassBg = s.glassHeaderTint;
    final searchBorder = BorderSide(
      color: glass
          ? Colors.white.withValues(alpha: AppGlass.borderAlpha)
          : tokens.AppThemeTokens.cardBorder,
      width: 0.5,
    );

    final headerBody = Container(
      padding: const EdgeInsets.only(bottom: 12),
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
          // ── Title row ──────────────────────────────────────────────────────
          SizedBox(
            height: kToolbarHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: mailService.isFetching
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: tokens.AppThemeTokens.navBarIcon,
                            ),
                          )
                        : _reloadDone
                            ? Icon(Icons.check, color: s.success)
                            : Icon(
                                CupertinoIcons.arrow_clockwise,
                                color: tokens.AppThemeTokens.navBarIcon,
                              ),
                    onPressed: mailService.isFetching ? null : _onReload,
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        'Mail',
                        style: AppTextStyles.navTitle(
                            color: tokens.AppThemeTokens.titleColor),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.edit_outlined,
                        color: tokens.AppThemeTokens.navBarIcon),
                    onPressed: openCompose,
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

          // ── Search + filter chips ─────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 44,
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (v) => setState(() => _searchQuery = v),
                    style: AppTextStyles.bodyLarge(
                        color: tokens.AppThemeTokens.titleColor),
                    decoration: InputDecoration(
                      hintText: 'Search mail...',
                      hintStyle: AppTextStyles.bodyLarge(
                          color: tokens.AppThemeTokens.secondaryTextColor),
                      filled: true,
                      fillColor: glass
                          ? Colors.white.withValues(alpha: AppGlass.fillAlpha)
                          : tokens.AppThemeTokens.cardBackground,
                      prefixIcon: Icon(Icons.search,
                          color: tokens.AppThemeTokens.secondaryTextColor,
                          size: 20),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? GestureDetector(
                              onTap: () => setState(() {
                                _searchCtrl.clear();
                                _searchQuery = '';
                              }),
                              child: Icon(Icons.close,
                                  color:
                                      tokens.AppThemeTokens.secondaryTextColor,
                                  size: 18),
                            )
                          : null,
                      contentPadding: EdgeInsets.zero,
                      isDense: true,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(radius),
                          borderSide: searchBorder),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(radius),
                          borderSide: searchBorder),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(radius),
                        borderSide: BorderSide(color: s.accent, width: 1),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _FilterChip(
                        label: 'All',
                        selected: _filter == _MailFilter.all,
                        onTap: () => setState(() => _filter = _MailFilter.all),
                        radius: radius,
                        glass: glass,
                      ),
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: 'Unread',
                        selected: _filter == _MailFilter.unread,
                        onTap: () =>
                            setState(() => _filter = _MailFilter.unread),
                        radius: radius,
                        glass: glass,
                      ),
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: 'Drafts',
                        selected: _filter == _MailFilter.drafts,
                        onTap: () {
                          setState(() => _filter = _MailFilter.drafts);
                          if (!_draftsFetchTriggered) {
                            _draftsFetchTriggered = true;
                            mailService.fetchDrafts();
                          }
                        },
                        radius: radius,
                        glass: glass,
                      ),
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: 'Sent',
                        selected: _filter == _MailFilter.sent,
                        onTap: () {
                          setState(() => _filter = _MailFilter.sent);
                          if (!_sentFetchTriggered) {
                            _sentFetchTriggered = true;
                            mailService.fetchSent();
                          }
                        },
                        radius: radius,
                        glass: glass,
                      ),
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: '',
                        icon: Icons.delete_outline,
                        selected: _filter == _MailFilter.trash,
                        onTap: () {
                          setState(() => _filter = _MailFilter.trash);
                          if (!_trashFetchTriggered) {
                            _trashFetchTriggered = true;
                            mailService.fetchTrash();
                          }
                        },
                        radius: radius,
                        glass: glass,
                      ),
                    ],
                  ),
                ),
              ],
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
                  padding: const EdgeInsets.only(bottom: 48),
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
      ],
    );
  }
}

// ── Filter chip ───────────────────────────────────────────────────────────────

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.radius,
    this.glass = false,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final double radius;
  final bool glass;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    final Color bg, border;
    if (glass) {
      bg = selected
          ? s.accent.withValues(alpha: 0.65)
          : Colors.white.withValues(alpha: 0.10); // TODO glass refinement
      border = selected
          ? s.accent.withValues(alpha: 0.80)
          : Colors.white.withValues(alpha: 0.20); // TODO glass refinement
    } else {
      bg     = selected ? s.accent : tokens.AppThemeTokens.cardBackground;
      border = selected ? s.accent : tokens.AppThemeTokens.cardBorder;
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: border, width: 0.5),
        ),
        alignment: Alignment.center,
        child: icon != null
            ? Icon(
                icon,
                size: 18,
                color: selected
                    ? Colors.white
                    : tokens.AppThemeTokens.secondaryTextColor,
              )
            : Text(
                label,
                style: AppTextStyles.bodySmall(
                  color: selected
                      ? Colors.white // on accent — white correct in both modes
                      : tokens.AppThemeTokens.secondaryTextColor,
                ).copyWith(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400),
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
