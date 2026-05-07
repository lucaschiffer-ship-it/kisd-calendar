import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/service_locator.dart';
import 'compose_screen.dart';
import 'email_detail_screen.dart';

class MailScreen extends StatefulWidget {
  const MailScreen({super.key});

  @override
  State<MailScreen> createState() => _MailScreenState();
}

class _MailScreenState extends State<MailScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    mailService.addListener(_onUpdate);
    if (!mailService.isConnected && !mailService.isConnecting) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => mailService.connect());
    }
  }

  @override
  void dispose() {
    mailService.removeListener(_onUpdate);
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  void _openCompose({MimeMessage? replyTo}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ComposeScreen(replyTo: replyTo),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final loading = mailService.isConnecting || mailService.isFetching;
    final hasMessages = mailService.messages.isNotEmpty;
    final error = mailService.connectionError;

    if (loading && !hasMessages) {
      return const _SkeletonList();
    }

    if (error != null && !hasMessages) {
      return _ErrorView(
        error: error,
        onRetry: () => mailService.connect(),
      );
    }

    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () => mailService.fetchInbox(),
          child: hasMessages
              ? ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: mailService.messages.length,
                  itemBuilder: (ctx, i) {
                    final msg = mailService.messages[i];
                    return _EmailCard(
                      key: ValueKey(msg.uid ?? msg.sequenceId),
                      message: msg,
                      onTap: () {
                        Navigator.push<void>(
                          context,
                          CupertinoPageRoute(
                            builder: (_) => EmailDetailScreen(
                              message: msg,
                              onReply: (m) => _openCompose(replyTo: m),
                            ),
                          ),
                        );
                      },
                      onDelete: () => mailService.deleteMessage(msg),
                    );
                  },
                )
              : const _EmptyState(),
        ),
        Positioned(
          bottom: 20,
          right: 20,
          child: FloatingActionButton(
            onPressed: () => _openCompose(),
            child: const Icon(Icons.edit_outlined),
          ),
        ),
      ],
    );
  }
}

// ── Email card ────────────────────────────────────────────────────────────────

class _EmailCard extends StatelessWidget {
  const _EmailCard({
    super.key,
    required this.message,
    required this.onTap,
    required this.onDelete,
  });

  final MimeMessage message;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isUnread = !message.isSeen;

    final fromEmail = message.fromEmail;
    final fromPersonal = message.from?.firstOrNull?.personalName;
    final senderName = (fromPersonal != null && fromPersonal.isNotEmpty)
        ? fromPersonal
        : fromEmail ?? 'Unknown';
    final subject = message.decodeSubject() ?? '(No subject)';
    final preview = _extractPreview(message);
    final dateStr = _formatDate(message.decodeDate());

    final avatarColor = _senderColor(senderName, cs);
    final initial = senderName.isNotEmpty ? senderName[0].toUpperCase() : '?';

    final bgColor = isUnread
        ? (isDark
            ? cs.primary.withAlpha(23)
            : cs.primary.withAlpha(13))
        : Colors.transparent;

    return Dismissible(
      key: ValueKey('dismiss_${message.uid}_${message.sequenceId}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        color: Colors.red,
        child: const Icon(Icons.delete_outline, color: Colors.white, size: 26),
      ),
      onDismissed: (_) => onDelete(),
      child: InkWell(
        onTap: onTap,
        child: Container(
          color: bgColor,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: avatarColor,
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            senderName,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: isUnread
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          dateStr,
                          style: TextStyle(
                            fontSize: 12,
                            color: isUnread
                                ? cs.primary
                                : cs.onSurface.withAlpha(127),
                            fontWeight: isUnread
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            subject,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: isUnread
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isUnread)
                          Container(
                            width: 9,
                            height: 9,
                            margin: const EdgeInsets.only(left: 6),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: cs.primary,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      preview,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withAlpha(127),
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

  Color _senderColor(String name, ColorScheme cs) {
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
      final h = date.hour.toString().padLeft(2, '0');
      final m = date.minute.toString().padLeft(2, '0');
      return '$h:$m';
    }
    if (date.year == now.year) {
      const mo = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      return '${date.day} ${mo[date.month - 1]}';
    }
    return '${date.day}/${date.month}/${date.year % 100}';
  }
}

// ── Skeleton loading list ─────────────────────────────────────────────────────

class _SkeletonList extends StatelessWidget {
  const _SkeletonList();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: EdgeInsets.zero,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 10,
      itemBuilder: (_, i) => const _SkeletonCard(),
    );
  }
}

class _SkeletonCard extends StatefulWidget {
  const _SkeletonCard();

  @override
  State<_SkeletonCard> createState() => _SkeletonCardState();
}

class _SkeletonCardState extends State<_SkeletonCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _opacity = Tween<double>(begin: 0.3, end: 0.7).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base =
        Theme.of(context).brightness == Brightness.dark
            ? Colors.white
            : Colors.black;
    return AnimatedBuilder(
      animation: _opacity,
      builder: (context, child) => Opacity(
        opacity: _opacity.value,
        child: _buildSkeleton(base),
      ),
    );
  }

  Widget _buildSkeleton(Color base) {
    Widget box(double w, double h, {double radius = 4}) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: base.withAlpha(31),
            borderRadius: BorderRadius.circular(radius),
          ),
        );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          box(44, 44, radius: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    box(120, 13),
                    const Spacer(),
                    box(32, 11),
                  ],
                ),
                const SizedBox(height: 8),
                box(200, 12),
                const SizedBox(height: 6),
                box(double.infinity, 11),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            CupertinoIcons.tray,
            size: 64,
            color: cs.onSurface.withAlpha(64),
          ),
          const SizedBox(height: 16),
          Text(
            'No messages',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: cs.onSurface.withAlpha(102),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Your inbox is empty.',
            style: TextStyle(
              fontSize: 14,
              color: cs.onSurface.withAlpha(77),
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
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              CupertinoIcons.exclamationmark_circle,
              size: 52,
              color: cs.error.withAlpha(179),
            ),
            const SizedBox(height: 16),
            const Text(
              'Could not load mail',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withAlpha(127),
              ),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
