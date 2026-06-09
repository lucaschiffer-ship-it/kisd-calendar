import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/material.dart';

import '../services/service_locator.dart';
import '../theme/tokens.dart';

class ComposeScreen extends StatefulWidget {
  const ComposeScreen({super.key, this.replyTo});

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
      final toEmail = senders.isNotEmpty ? senders.first.email : '';
      final originalSubject = reply.decodeSubject() ?? '';
      final re = originalSubject.toLowerCase().startsWith('re:')
          ? originalSubject
          : 'Re: $originalSubject';
      final originalPlain = reply.decodeTextPlainPart() ?? '';
      final quoted = originalPlain.isEmpty ? '' : '\n\n---\n$originalPlain';
      _toCtrl      = TextEditingController(text: toEmail);
      _subjectCtrl = TextEditingController(text: re);
      _bodyCtrl    = TextEditingController(text: quoted);
    } else {
      _toCtrl      = TextEditingController();
      _subjectCtrl = TextEditingController();
      _bodyCtrl    = TextEditingController();
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
    final s = AppColorScheme.current;

    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize:     0.5,
      maxChildSize:     0.98,
      expand: false,
      builder: (_, scrollCtrl) => Container(
        decoration: BoxDecoration(
          color: s.background,
          borderRadius: BorderRadius.vertical(
              top: Radius.circular(AppRadius.sheet)),
        ),
        child: Column(
          children: [
            // Drag handle
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 4),
              width:  36,
              height: 4,
              decoration: BoxDecoration(
                color:         s.textTertiary,
                borderRadius:  BorderRadius.circular(AppRadius.handle),
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
                      style: AppTextStyles.bodyLarge(color: s.danger)
                          .copyWith(fontWeight: FontWeight.w500),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        widget.replyTo != null ? 'Reply' : 'New Message',
                        style: AppTextStyles.bodyLarge(color: s.textPrimary)
                            .copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
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
                            style: AppTextStyles.bodyLarge(color: s.accent)
                                .copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                ],
              ),
            ),
            const _Divider(),
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
                        margin:  const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: s.danger.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(AppRadius.chip),
                        ),
                        child: Text(
                          _sendError!,
                          style: AppTextStyles.bodySmall(color: s.danger),
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
                        maxLines:   null,
                        autofocus:  widget.replyTo != null,
                        decoration: const InputDecoration(
                          hintText:       'Compose email...',
                          border:         InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                        ),
                        style: AppTextStyles.bodyLarge(
                            color: AppColorScheme.current.textPrimary),
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
    final s = AppColorScheme.current;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Text(
              label,
              style: AppTextStyles.bodyLarge(color: s.textSecondary),
            ),
          ),
          Expanded(
            child: TextField(
              controller:   controller,
              keyboardType: keyboardType,
              autofocus:    autofocus,
              decoration: const InputDecoration(
                border:         InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
              style: AppTextStyles.bodyLarge(color: AppColorScheme.current.textPrimary),
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
  Widget build(BuildContext context) => Divider(
        height: 1,
        indent: 16,
        endIndent: 0,
        color: AppColorScheme.current.divider,
      );
}
