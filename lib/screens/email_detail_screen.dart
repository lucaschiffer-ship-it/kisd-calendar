import 'dart:async' show unawaited;

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/service_locator.dart';

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
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final msg = _full ?? widget.message;
    final fromEmail = msg.fromEmail ?? '';
    final fromPersonal = msg.from?.firstOrNull?.personalName;
    final senderName = (fromPersonal != null && fromPersonal.isNotEmpty)
        ? fromPersonal
        : fromEmail.isNotEmpty ? fromEmail : 'Unknown';
    final senderEmail = fromEmail;
    final subject = msg.decodeSubject() ?? '(No subject)';
    final date = msg.decodeDate();

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(CupertinoIcons.chevron_back),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(CupertinoIcons.delete),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  subject,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: _senderColor(senderName),
                      child: Text(
                        senderName.isNotEmpty
                            ? senderName[0].toUpperCase()
                            : '?',
                        style: const TextStyle(
                          color: Colors.white,
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
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            senderEmail,
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurface.withAlpha(127),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (date != null)
                      Text(
                        _formatFullDate(date),
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withAlpha(127),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _buildBody(msg, isDark, cs),
          ),
          _buildAttachments(msg, cs),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    widget.onReply(_full ?? widget.message);
                  },
                  icon: const Icon(Icons.reply),
                  label: const Text('Reply'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(MimeMessage msg, bool isDark, ColorScheme cs) {
    final html = msg.decodeTextHtmlPart();
    if (html != null && html.isNotEmpty) {
      return InAppWebView(
        initialData: InAppWebViewInitialData(
          data: _wrapHtml(html, isDark, cs),
          mimeType: 'text/html',
          encoding: 'utf-8',
          baseUrl: WebUri('about:blank'),
        ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: false,
          transparentBackground: true,
        ),
      );
    }
    final plain = msg.decodeTextPlainPart() ?? '';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: SelectableText(
        plain,
        style: TextStyle(fontSize: 14, height: 1.6, color: cs.onSurface),
      ),
    );
  }

  String _wrapHtml(String html, bool isDark, ColorScheme cs) {
    final bg = isDark ? '#1C1C1E' : '#FFFFFF';
    final fg = isDark ? '#EBEBF5' : '#1C1C1E';
    return '''<!DOCTYPE html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body { margin:16px; background:$bg; color:$fg;
         font-family:-apple-system,sans-serif; font-size:14px;
         line-height:1.6; word-break:break-word; }
  img  { max-width:100% !important; height:auto; }
  a    { color:#007AFF; }
  table{ max-width:100%; }
</style></head><body>$html</body></html>''';
  }

  Widget _buildAttachments(MimeMessage msg, ColorScheme cs) {
    final attachments = msg.findContentInfo(
      disposition: ContentDisposition.attachment,
    );
    if (attachments.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: attachments.map((info) {
          final name = info.fileName ?? 'attachment';
          return Chip(
            avatar: Icon(Icons.attach_file, size: 16, color: cs.primary),
            label: Text(name, style: const TextStyle(fontSize: 12)),
          );
        }).toList(),
      ),
    );
  }

  Color _senderColor(String name) {
    const palette = [
      Color(0xFF1A73E8), Color(0xFFD93025), Color(0xFF188038),
      Color(0xFFF29900), Color(0xFF9334E6), Color(0xFF00897B),
      Color(0xFFE52592), Color(0xFF3949AB),
    ];
    return palette[name.hashCode.abs() % palette.length];
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
