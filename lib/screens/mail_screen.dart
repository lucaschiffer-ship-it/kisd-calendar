import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../config/app_theme.dart' as tokens;
import '../services/service_locator.dart';
import '../services/theme_service.dart';
import '../theme/app_theme.dart';
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

    return ValueListenableBuilder<String>(
      valueListenable: ThemeService.instance.currentColor,
      builder: (ctx, _, _) => ValueListenableBuilder<String>(
        valueListenable: ThemeService.instance.currentStyle,
        builder: (ctx, _, _) {
          if (loading && !hasMessages) return const _SkeletonList();
          if (error != null && !hasMessages) {
            return _ErrorView(
              error: error,
              onRetry: () => mailService.connect(),
            );
          }
          return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () => mailService.reloadInbox(),
          child: hasMessages
              ? ListView.separated(
                  padding: const EdgeInsets.all(AppSpacing.screenPadding),
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: mailService.messages.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: AppSpacing.cardGap),
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
                    );
                  },
                )
              : LayoutBuilder(
                  builder: (ctx, constraints) => SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: SizedBox(
                      height: constraints.maxHeight,
                      child: const _EmptyState(),
                    ),
                  ),
                ),
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
        },
      ),
    );
  }
}

// ── Email card ────────────────────────────────────────────────────────────────

class _EmailCard extends StatelessWidget {
  const _EmailCard({
    super.key,
    required this.message,
    required this.onTap,
  });

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
    final avatarColor = _senderColor(senderName);
    final initial = senderName.isNotEmpty ? senderName[0].toUpperCase() : '?';

    return AppCard(
      borderColor: isUnread
          ? AppColors.accent.withValues(alpha: 0.45)
          : null,
      borderWidth: isUnread ? 1.0 : 0.5,
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          highlightColor: AppColors.accent.withValues(alpha: 0.06),
          splashColor: AppColors.accent.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: avatarColor,
                    child: Text(
                      initial,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                senderName,
                                style: isUnread
                                    ? AppTextStyle.headlineBold.copyWith(color: tokens.AppThemeTokens.titleColor)
                                    : AppTextStyle.headline.copyWith(color: tokens.AppThemeTokens.titleColor),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              dateStr,
                              style: AppTextStyle.label.copyWith(
                                color: isUnread
                                    ? AppColors.accent
                                    : AppColors.textTertiary,
                                fontWeight: isUnread
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                subject,
                                style: isUnread
                                    ? AppTextStyle.bodyBold.copyWith(color: tokens.AppThemeTokens.titleColor)
                                    : AppTextStyle.body.copyWith(color: tokens.AppThemeTokens.secondaryTextColor),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isUnread)
                              Container(
                                width: 7,
                                height: 7,
                                margin: const EdgeInsets.only(left: 8),
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: AppColors.accent,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          preview,
                          style: AppTextStyle.label.copyWith(color: tokens.AppThemeTokens.secondaryTextColor),
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
      return plain
          .replaceAll(RegExp(r'^\d+>\s*'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
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
    return ListView.separated(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 6,
      separatorBuilder: (context, index) =>
          const SizedBox(height: AppSpacing.cardGap),
      itemBuilder: (context, index) => const _SkeletonCard(),
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
    Widget box(double w, double h, {double radius = 6}) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: base.withAlpha(22),
            borderRadius: BorderRadius.circular(radius),
          ),
        );

    return AppCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          box(40, 40, radius: 20),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    box(110, 13),
                    const Spacer(),
                    box(30, 11),
                  ],
                ),
                const SizedBox(height: 9),
                box(180, 12),
                const SizedBox(height: 7),
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
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(CupertinoIcons.tray, size: 56, color: tokens.AppThemeTokens.secondaryTextColor),
          const SizedBox(height: 16),
          Text('No messages',
              style: AppTextStyle.headline.copyWith(fontSize: 17, color: tokens.AppThemeTokens.titleColor)),
          const SizedBox(height: 6),
          Text('Your inbox is empty.', style: AppTextStyle.body.copyWith(color: tokens.AppThemeTokens.secondaryTextColor)),
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
