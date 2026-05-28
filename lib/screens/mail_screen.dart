import 'dart:ui';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_theme.dart' as tokens;
import '../services/service_locator.dart';
import '../services/theme_service.dart';
import 'compose_screen.dart';
import 'email_detail_screen.dart';
import 'settings_screen.dart';

enum _MailFilter { all, unread, flagged, archived }

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
  bool _archiveFetchTriggered = false;
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

  List<MimeMessage> get _filtered {
    var msgs = _filter == _MailFilter.archived
        ? mailService.archivedMessages.toList()
        : mailService.messages.toList();
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
      _MailFilter.unread => msgs.where((m) => !m.isSeen).toList(),
      _MailFilter.flagged => msgs.where((m) => m.isFlagged).toList(),
      _MailFilter.archived => msgs,
      _MailFilter.all => msgs,
    };
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AnimatedBuilder(
      animation: Listenable.merge([
        ThemeService.instance.currentColor,
        ThemeService.instance.currentStyle,
        ThemeService.instance.glassEnabled,
      ]),
      builder: (context, _) => _buildContent(),
    );
  }

  Widget _buildContent() {
    final isArchiveTab = _filter == _MailFilter.archived;
    final loading = isArchiveTab
        ? mailService.isFetchingArchive
        : (mailService.isConnecting || mailService.isFetching);
    final hasData = isArchiveTab
        ? mailService.archivedMessages.isNotEmpty
        : mailService.messages.isNotEmpty;
    final error = mailService.connectionError;

    if (loading && !hasData) {
      return Center(
        child: CircularProgressIndicator(color: const Color(0xFFEB5A01)),
      );
    }
    if (!isArchiveTab && error != null && !hasData) {
      return _ErrorView(error: error, onRetry: () => mailService.connect());
    }

    final filtered = _filtered;
    final radius = tokens.AppThemeTokens.cardBorderRadius;

    // ── Header metrics ────────────────────────────────────────────────────
    // View.of(context).viewPadding is the raw FlutterView device inset —
    // the Scaffold zeroes both MediaQuery.padding.top AND
    // MediaQuery.viewPadding.top when extendBodyBehindAppBar:true, so
    // MediaQuery is useless here. View is never modified by any widget.
    final view = View.of(context);
    final statusH = view.viewPadding.top / view.devicePixelRatio;
    const filterH = 110.0; // search bar + chips
    final headerH = statusH + kToolbarHeight + filterH;

    final glass = ThemeService.instance.glassEnabled.value;
    final glassBg = ThemeService.instance.currentColor.value == 'dark'
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.white.withValues(alpha: 0.50);
    final searchBorder = BorderSide(
      color: glass
          ? Colors.white.withValues(alpha: 0.25)
          : tokens.AppThemeTokens.cardBorder,
      width: 0.5,
    );

    // ── Single glass container: title row + search + chips ────────────────
    final headerBody = Container(
      padding: EdgeInsets.only(bottom: 12),
      decoration: glass
          ? BoxDecoration(
              color: glassBg,
              border: const Border(
                bottom: BorderSide(color: Color(0x1AFFFFFF), width: 0.5),
              ),
            )
          : BoxDecoration(color: tokens.AppThemeTokens.backgroundColor),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Notch / status-bar inset — raw device height, not Scaffold-inflated
          SizedBox(height: statusH),
          // ── Title row ────────────────────────────────────────────────────
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
                        ? const Icon(Icons.check, color: Color(0xFF30D158))
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
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: tokens.AppThemeTokens.titleColor,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.edit_outlined,
                      color: tokens.AppThemeTokens.navBarIcon,
                    ),
                    onPressed: openCompose,
                  ),
                  IconButton(
                    icon: Icon(
                      CupertinoIcons.settings,
                      color: tokens.AppThemeTokens.navBarIcon,
                    ),
                    onPressed: () => Navigator.push<void>(
                      context,
                      CupertinoPageRoute(
                        builder: (_) => const SettingsScreen(),
                      ),
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
                    style: TextStyle(
                      color: tokens.AppThemeTokens.titleColor,
                      fontSize: 15,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Search mail...',
                      hintStyle: TextStyle(
                        color: tokens.AppThemeTokens.secondaryTextColor,
                        fontSize: 15,
                      ),
                      filled: true,
                      fillColor: glass
                          ? Colors.white.withValues(alpha: 0.12)
                          : tokens.AppThemeTokens.cardBackground,
                      prefixIcon: Icon(
                        Icons.search,
                        color: tokens.AppThemeTokens.secondaryTextColor,
                        size: 20,
                      ),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? GestureDetector(
                              onTap: () => setState(() {
                                _searchCtrl.clear();
                                _searchQuery = '';
                              }),
                              child: Icon(
                                Icons.close,
                                color: tokens.AppThemeTokens.secondaryTextColor,
                                size: 18,
                              ),
                            )
                          : null,
                      contentPadding: EdgeInsets.zero,
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(radius),
                        borderSide: searchBorder,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(radius),
                        borderSide: searchBorder,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(radius),
                        borderSide: const BorderSide(
                          color: Color(0xFFEB5A01),
                          width: 1,
                        ),
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
                        label: 'Flagged',
                        selected: _filter == _MailFilter.flagged,
                        onTap: () =>
                            setState(() => _filter = _MailFilter.flagged),
                        radius: radius,
                        glass: glass,
                      ),
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: 'Archived',
                        selected: _filter == _MailFilter.archived,
                        onTap: () {
                          setState(() => _filter = _MailFilter.archived);
                          if (!_archiveFetchTriggered) {
                            _archiveFetchTriggered = true;
                            mailService.fetchArchive();
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
      ), // Column
    );

    final header = glass
        ? ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: headerBody,
            ),
          )
        : headerBody;

    // ── Stack: list fills full screen, glass header floats on top ────────
    return Stack(
      children: [
        RefreshIndicator(
          color: const Color(0xFFEB5A01),
          onRefresh: () => _filter == _MailFilter.archived
              ? mailService.fetchArchive()
              : mailService.reloadInbox(),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              // Push list content below the combined glass header
              SliverPadding(padding: EdgeInsets.only(top: headerH)),
              if (!hasData)
                const SliverFillRemaining(child: _EmptyState())
              else if (filtered.isEmpty)
                SliverFillRemaining(
                  child: Center(
                    child: Text(
                      'No emails match this filter.',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        color: tokens.AppThemeTokens.secondaryTextColor,
                      ),
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
                          'email_${msg.uid ?? msg.sequenceId ?? msg.hashCode}',
                        ),
                        message: msg,
                        onTap: () => Navigator.push<void>(
                          context,
                          CupertinoPageRoute(
                            builder: (_) => EmailDetailScreen(
                              message: msg,
                              onReply: (m) => openCompose(replyTo: m),
                            ),
                          ),
                        ),
                        onDelete: () => mailService.deleteMessage(msg),
                        isArchiveItem: isArchiveTab,
                        onRestore: () => mailService.restoreMessage(msg),
                        onToggleRead: () {
                          if (msg.isSeen) {
                            mailService.markAsUnread(msg);
                          } else {
                            mailService.markAsRead(msg);
                          }
                        },
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
        // Glass header overlays the top of the list
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
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final double radius;
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final Color bg, border;
    if (glass) {
      bg = selected
          ? const Color(0xFFEB5A01).withValues(alpha: 0.65)
          : Colors.white.withValues(alpha: 0.10);
      border = selected
          ? const Color(0xFFEB5A01).withValues(alpha: 0.80)
          : Colors.white.withValues(alpha: 0.20);
    } else {
      bg = selected
          ? const Color(0xFFEB5A01)
          : tokens.AppThemeTokens.cardBackground;
      border = selected
          ? const Color(0xFFEB5A01)
          : tokens.AppThemeTokens.cardBorder;
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
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected
                ? Colors.white
                : tokens.AppThemeTokens.secondaryTextColor,
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
    final isUnread = !message.isSeen;

    return Dismissible(
      key: ValueKey(
        'dismiss_${message.uid ?? message.sequenceId ?? message.hashCode}',
      ),
      direction: DismissDirection.horizontal,
      dismissThresholds: const {
        DismissDirection.endToStart: 0.4,
        DismissDirection.startToEnd: 0.4,
      },
      // Right-swipe: toggle read/unread (orange)
      background: Container(
        color: const Color(0xFFEB5A01),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isUnread ? CupertinoIcons.envelope_open : CupertinoIcons.envelope,
              color: Colors.white,
              size: 22,
            ),
            const SizedBox(height: 4),
            Text(
              isUnread ? 'Read' : 'Unread',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      // Left-swipe: Delete (inbox) or Restore (archive)
      secondaryBackground: Container(
        color: isArchiveItem
            ? const Color(0xFF30D158) // green = restore
            : const Color(0xFFFF3B30), // red   = delete
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isArchiveItem
                  ? Icons.move_to_inbox_outlined
                  : CupertinoIcons.delete,
              color: Colors.white,
              size: 22,
            ),
            const SizedBox(height: 4),
            Text(
              isArchiveItem ? 'Restore' : 'Delete',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
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
        // Toggle read state — card snaps back, stays in list
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
        highlightColor: const Color(0xFFEB5A01).withValues(alpha: 0.06),
        splashColor: const Color(0xFFEB5A01).withValues(alpha: 0.04),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: tokens.AppThemeTokens.secondaryTextColor.withValues(
                  alpha: 0.1,
                ),
                width: 0.5,
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Unread dot column (fixed width so avatar stays aligned)
                SizedBox(
                  width: 12,
                  child: isUnread
                      ? Padding(
                          padding: const EdgeInsets.only(top: 15),
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(0xFFEB5A01),
                            ),
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 4),
                // Avatar
                CircleAvatar(
                  radius: 20,
                  backgroundColor: _senderColor(senderName),
                  child: Text(
                    initial,
                    style: const TextStyle(
                      color: Colors.white,
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
                      // Sender row + timestamp
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Expanded(
                            child: Text(
                              senderName,
                              style: GoogleFonts.spaceGrotesk(
                                fontSize: 14,
                                fontWeight: isUnread
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: tokens.AppThemeTokens.titleColor,
                                letterSpacing: -0.2,
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
                                Icon(
                                  Icons.attach_file,
                                  size: 12,
                                  color:
                                      tokens.AppThemeTokens.secondaryTextColor,
                                ),
                                const SizedBox(width: 2),
                              ],
                              Text(
                                dateStr,
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  fontWeight: isUnread
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: isUnread
                                      ? const Color(0xFFEB5A01)
                                      : tokens
                                            .AppThemeTokens
                                            .secondaryTextColor,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      // Subject
                      Text(
                        subject,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: isUnread
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: tokens.AppThemeTokens.titleColor.withValues(
                            alpha: 0.85,
                          ),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      // Preview
                      Text(
                        preview,
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          color: tokens.AppThemeTokens.secondaryTextColor,
                          height: 1.4,
                        ),
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
    if (plain != null && plain.isNotEmpty) {
      return plain.replaceAll(RegExp(r'\s+'), ' ').trim();
    }
    final html = msg.decodeTextHtmlPart();
    if (html != null && html.isNotEmpty) {
      return html
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }
    return '';
  }

  Color _senderColor(String name) {
    const palette = [
      Color(0xFF1A73E8),
      Color(0xFFD93025),
      Color(0xFF188038),
      Color(0xFFF29900),
      Color(0xFF9334E6),
      Color(0xFF00897B),
      Color(0xFFE52592),
      Color(0xFF3949AB),
    ];
    return palette[name.hashCode.abs() % palette.length];
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
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${mo[date.month - 1]} ${date.day}';
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            CupertinoIcons.tray,
            size: 52,
            color: tokens.AppThemeTokens.secondaryTextColor,
          ),
          const SizedBox(height: 16),
          Text(
            'No emails',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: tokens.AppThemeTokens.titleColor,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Your inbox is empty.',
            style: GoogleFonts.inter(
              fontSize: 14,
              color: tokens.AppThemeTokens.secondaryTextColor,
            ),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              CupertinoIcons.exclamationmark_circle,
              size: 52,
              color: tokens.AppThemeTokens.secondaryTextColor,
            ),
            const SizedBox(height: 16),
            Text(
              'Could not load mail',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: tokens.AppThemeTokens.titleColor,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: tokens.AppThemeTokens.secondaryTextColor,
              ),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onRetry,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFEB5A01),
                foregroundColor: Colors.white,
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
