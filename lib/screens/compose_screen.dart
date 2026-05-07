import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/material.dart';

import '../services/service_locator.dart';

class ComposeScreen extends StatefulWidget {
  const ComposeScreen({super.key, this.replyTo});

  /// Non-null when replying to an existing message.
  final MimeMessage? replyTo;

  @override
  State<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends State<ComposeScreen> {
  late final TextEditingController _toCtrl;
  late final TextEditingController _subjectCtrl;
  late final TextEditingController _bodyCtrl;
  bool _sending = false;
  String? _sendError;

  @override
  void initState() {
    super.initState();
    final reply = widget.replyTo;
    if (reply != null) {
      final senders = reply.decodeSender();
      final toEmail =
          senders.isNotEmpty ? senders.first.email : '';
      final originalSubject = reply.decodeSubject() ?? '';
      final re = originalSubject.toLowerCase().startsWith('re:')
          ? originalSubject
          : 'Re: $originalSubject';
      final originalPlain = reply.decodeTextPlainPart() ?? '';
      final quoted = originalPlain.isEmpty
          ? ''
          : '\n\n---\n$originalPlain';
      _toCtrl = TextEditingController(text: toEmail);
      _subjectCtrl = TextEditingController(text: re);
      _bodyCtrl = TextEditingController(text: quoted);
    } else {
      _toCtrl = TextEditingController();
      _subjectCtrl = TextEditingController();
      _bodyCtrl = TextEditingController();
    }
  }

  @override
  void dispose() {
    _toCtrl.dispose();
    _subjectCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final to = _toCtrl.text.trim();
    if (!to.contains('@')) {
      setState(() => _sendError = 'Invalid email address.');
      return;
    }
    setState(() { _sending = true; _sendError = null; });
    try {
      await mailService.sendEmail(
        to,
        _subjectCtrl.text.trim(),
        _bodyCtrl.text,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() { _sending = false; _sendError = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF1C1C1E) : Colors.white;

    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.98,
      expand: false,
      builder: (_, scrollCtrl) => Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          children: [
            // Drag handle
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 4),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: cs.onSurface.withAlpha(50),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Toolbar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  TextButton(
                    onPressed: _sending ? null : () => Navigator.pop(context),
                    child: Text(
                      'Discard',
                      style: TextStyle(color: cs.error),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    widget.replyTo != null ? 'Reply' : 'New Message',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                  const Spacer(),
                  _sending
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : TextButton(
                          onPressed: _send,
                          child: Text(
                            'Send',
                            style: TextStyle(
                              color: cs.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Fields
            Expanded(
              child: SingleChildScrollView(
                controller: scrollCtrl,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.only(bottom: 24),
                child: Column(
                  children: [
                    if (_sendError != null)
                      Container(
                        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: cs.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _sendError!,
                          style: TextStyle(
                            color: cs.onErrorContainer,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    _ComposeField(
                      label: 'To',
                      controller: _toCtrl,
                      keyboardType: TextInputType.emailAddress,
                      autofocus: widget.replyTo == null,
                    ),
                    const _Divider(),
                    _ComposeField(
                      label: 'Subject',
                      controller: _subjectCtrl,
                    ),
                    const _Divider(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: TextField(
                        controller: _bodyCtrl,
                        maxLines: null,
                        autofocus: widget.replyTo != null,
                        decoration: const InputDecoration(
                          hintText: 'Compose email...',
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                        ),
                        style: const TextStyle(fontSize: 15, height: 1.5),
                        keyboardType: TextInputType.multiline,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComposeField extends StatelessWidget {
  const _ComposeField({
    required this.label,
    required this.controller,
    this.keyboardType,
    this.autofocus = false,
  });

  final String label;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Text(
              label,
              style: TextStyle(
                color: cs.onSurface.withAlpha(120),
                fontSize: 15,
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: keyboardType,
              autofocus: autofocus,
              decoration: const InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
              style: const TextStyle(fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      indent: 16,
      endIndent: 0,
      color: Theme.of(context).colorScheme.onSurface.withAlpha(30),
    );
  }
}
