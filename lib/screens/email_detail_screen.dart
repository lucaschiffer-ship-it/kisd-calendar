import 'dart:async' show unawaited;

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../config/app_theme.dart' as tokens;
import '../services/service_locator.dart';
import '../services/spaces_browser.dart';
import '../services/theme_service.dart';
import '../theme/tokens.dart';

class EmailDetailScreen extends StatefulWidget {
  const EmailDetailScreen({
    super.key,
    required this.message,
    required this.onReply,
  });

  final MimeMessage message;
  final void Function(MimeMessage) onReply;

  @override
  State<EmailDetailScreen> createState() => _EmailDetailScreenState();
}

class _EmailDetailScreenState extends State<EmailDetailScreen> {
  MimeMessage? _full;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    unawaited(mailService.markAsRead(widget.message));
    final uid = widget.message.uid;
    if (uid != null) {
      final full = await mailService.fetchFullMessage(uid);
      if (mounted) setState(() { _full = full; _loading = false; });
    } else {
      if (mounted) setState(() { _full = widget.message; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeService.instance.currentColor,
      builder: (context, _) => _buildScreen(context),
    );
  }

  Widget _buildScreen(BuildContext context) {
    final s   = AppColorScheme.current;
    final msg = _full ?? widget.message;

    final fromPersonal = msg.from?.firstOrNull?.personalName;
    final fromEmail    = msg.fromEmail ?? '';
    final senderName   = (fromPersonal != null && fromPersonal.isNotEmpty)
        ? fromPersonal
        : fromEmail.isNotEmpty ? fromEmail : 'Unknown';
    final subject = msg.decodeSubject() ?? '(No subject)';
    final date    = msg.decodeDate();
    final initial = senderName.isNotEmpty ? senderName[0].toUpperCase() : '?';

    return Scaffold(
      backgroundColor: tokens.AppThemeTokens.backgroundColor,
      appBar: AppBar(
        backgroundColor: tokens.AppThemeTokens.backgroundColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: Icon(CupertinoIcons.chevron_back,
              color: tokens.AppThemeTokens.navBarIcon),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: Icon(CupertinoIcons.delete,
                color: tokens.AppThemeTokens.secondaryTextColor),
            onPressed: () {
              mailService.deleteMessage(widget.message);
              Navigator.pop(context);
            },
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  subject,
                  style: AppTextStyles.contentHeading(
                      color: tokens.AppThemeTokens.titleColor),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: AppAvatarPalette.forName(senderName),
                      child: Text(
                        initial,
                        style: const TextStyle(
                          color: Colors.white, // on avatar color — intentionally white
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            senderName,
                            style: AppTextStyles.senderName(
                              color: tokens.AppThemeTokens.titleColor,
                            ).copyWith(fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            fromEmail,
                            style: AppTextStyles.caption(
                                color: tokens.AppThemeTokens.secondaryTextColor),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    if (date != null)
                      Text(
                        _formatFullDate(date),
                        style: AppTextStyles.caption(
                            color: tokens.AppThemeTokens.secondaryTextColor),
                      ),
                  ],
                ),
              ],
            ),
          ),
          Divider(height: 1, color: tokens.AppThemeTokens.dividerColor),

          // ── Body ────────────────────────────────────────────────────────
          Expanded(
            child: _loading
                ? Center(
                    child: CircularProgressIndicator(color: s.accent),
                  )
                : _buildBody(msg),
          ),

          // ── Attachments ─────────────────────────────────────────────────
          _buildAttachments(msg, s),

          // ── Action bar ──────────────────────────────────────────────────
          _buildActions(msg, s),
        ],
      ),
    );
  }

  Widget _buildBody(MimeMessage msg) {
    final html = msg.decodeTextHtmlPart();
    if (html != null && html.isNotEmpty) {
      return InAppWebView(
        initialData: InAppWebViewInitialData(
          data: _wrapHtml(html),
          mimeType: 'text/html',
          encoding: 'utf-8',
          baseUrl: WebUri('about:blank'),
        ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: false,
          transparentBackground: true,
        ),
        shouldOverrideUrlLoading: (controller, action) async {
          final url = action.request.url;
          if (url != null &&
              (url.scheme == 'http' || url.scheme == 'https')) {
            if (context.mounted) {
              final nav = Navigator.of(context);
              final msg = _full ?? widget.message;
              final onReply = widget.onReply;
              nav.pop();
              SpacesBrowser.open(
                url.toString(),
                onClose: () => nav.push(CupertinoPageRoute<void>(
                  builder: (_) => EmailDetailScreen(
                    message: msg,
                    onReply: onReply,
                  ),
                )),
              );
            }
            return NavigationActionPolicy.CANCEL;
          }
          return NavigationActionPolicy.ALLOW;
        },
      );
    }
    final plain = msg.decodeTextPlainPart() ?? '';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: SelectableText(
        plain,
        style: AppTextStyles.body(color: tokens.AppThemeTokens.titleColor)
            .copyWith(height: 1.6),
      ),
    );
  }

  // Builds HTML wrapper CSS from scheme tokens so the body adapts to the theme.
  String _wrapHtml(String html) {
    final s = AppColorScheme.current;
    final bg     = _hex(s.background);
    final fg     = _hex(s.textPrimary);
    final accent = _hex(s.accent);
    return '''<!DOCTYPE html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body { margin:16px; background:$bg; color:$fg;
         font-family:-apple-system,sans-serif; font-size:14px;
         line-height:1.6; word-break:break-word; }
  img  { max-width:100% !important; height:auto; }
  a    { color:$accent; }
  table{ max-width:100%; }
</style></head><body>$html</body></html>''';
  }

  static String _hex(Color c) {
    final v = c.toARGB32();
    return '#${v.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
  }

  Widget _buildAttachments(MimeMessage msg, AppColorScheme s) {
    final attachments =
        msg.findContentInfo(disposition: ContentDisposition.attachment);
    if (attachments.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: attachments.map((info) {
          final name = info.fileName ?? 'attachment';
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: tokens.AppThemeTokens.cardBackground,
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(
                  color: tokens.AppThemeTokens.cardBorder, width: 0.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.attach_file, size: 14, color: s.accent),
                const SizedBox(width: 4),
                Text(
                  name,
                  style: AppTextStyles.caption(
                      color: tokens.AppThemeTokens.titleColor),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildActions(MimeMessage msg, AppColorScheme s) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 12),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
                color: tokens.AppThemeTokens.dividerColor, width: 0.5),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _ActionBtn(
              icon: CupertinoIcons.reply,
              label: 'Reply',
              onTap: () {
                Navigator.pop(context);
                widget.onReply(_full ?? widget.message);
              },
            ),
            _ActionBtn(
              icon: CupertinoIcons.reply_all,
              label: 'Reply All',
              onTap: () {
                Navigator.pop(context);
                widget.onReply(_full ?? widget.message);
              },
            ),
            _ActionBtn(
              icon: CupertinoIcons.arrowshape_turn_up_right,
              label: 'Forward',
              onTap: () {
                Navigator.pop(context);
                widget.onReply(_full ?? widget.message);
              },
            ),
            _ActionBtn(
              icon: CupertinoIcons.delete,
              label: 'Delete',
              color: s.danger,
              onTap: () {
                mailService.deleteMessage(widget.message);
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  String _formatFullDate(DateTime date) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    final h = date.hour.toString().padLeft(2, '0');
    final m = date.minute.toString().padLeft(2, '0');
    return '${date.day} ${months[date.month - 1]} ${date.year}, $h:$m';
  }
}

// ── Action button ─────────────────────────────────────────────────────────────

class _ActionBtn extends StatelessWidget {
  const _ActionBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? tokens.AppThemeTokens.titleColor;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: c, size: 22),
            const SizedBox(height: 4),
            Text(
              label,
              style: AppTextStyles.timestamp(color: c)
                  .copyWith(fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}
