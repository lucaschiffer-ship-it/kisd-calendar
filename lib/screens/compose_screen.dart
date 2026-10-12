import 'dart:async' show unawaited;

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/mail_display.dart';
import '../services/mail_service.dart' show MailFolder;
import '../services/service_locator.dart';
import '../theme/tokens.dart';
import '../widgets/glass_pill.dart';

/// Opens the compose sheet: an iOS sheet on the root navigator, so the whole
/// app — an open mail included — scales back behind it.
///
/// [replacing] is a saved draft being reopened: it is removed once this one
/// is sent or saved again.
Future<void> openComposeSheet(
  BuildContext context, {
  ComposeDraft draft = const ComposeDraft(),
  MimeMessage? replacing,
}) {
  HapticFeedback.selectionClick();
  return Navigator.of(context, rootNavigator: true).push(
    _ComposeSheetRoute(
      builder: (_) => ComposeScreen(draft: draft, replacing: replacing),
    ),
  );
}

/// A sheet that can't be dragged away while it holds unsaved text — the ✕
/// button's Save / Delete choice is the way out then, so nothing typed is
/// lost to a stray swipe.
class _ComposeSheetRoute extends CupertinoSheetRoute<void> {
  _ComposeSheetRoute({required super.builder});

  bool Function()? canDrag;

  @override
  bool get enableDrag => canDrag?.call() ?? true;

  void refreshDrag() => changedInternalState();
}

class ComposeScreen extends StatefulWidget {
  const ComposeScreen({super.key, this.draft = const ComposeDraft(), this.replacing});

  final ComposeDraft draft;
  final MimeMessage? replacing;

  @override
  State<ComposeScreen> createState() => _ComposeScreenState();
}

enum _CloseChoice { delete, save }

class _ComposeScreenState extends State<ComposeScreen> {
  late final _fromCtrl = TextEditingController(text: widget.draft.from ?? '');
  late final _toCtrl = TextEditingController(text: widget.draft.to);
  late final _subjectCtrl = TextEditingController(text: widget.draft.subject);
  late final _bodyCtrl = TextEditingController(text: widget.draft.body);
  final _toFocus = FocusNode();
  final _bodyFocus = FocusNode();

  late String _initialBody = widget.draft.body;
  bool _sending = false;
  bool _saving = false;
  String? _error;
  bool _dirty = false;
  late String _shownTitle = widget.draft.subject.trim();
  late bool _shownCanSend = widget.draft.to.contains('@');
  _ComposeSheetRoute? _route;

  @override
  void initState() {
    super.initState();
    if (widget.draft.from == null) _prefillFrom();
    if (widget.replacing != null && widget.draft.body.isEmpty) _loadDraftBody();
    for (final c in [_toCtrl, _subjectCtrl, _bodyCtrl, _fromCtrl]) {
      c.addListener(_onChanged);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_route != null) return;
    final route = ModalRoute.of(context);
    if (route is _ComposeSheetRoute) {
      _route = route..canDrag = () => !_dirty;
    }
    // Focus once the sheet has arrived: the keyboard and the sheet sliding up
    // together is what made opening compose stutter.
    final animation = route?.animation;
    if (animation == null || animation.isCompleted) {
      _focusFirstField();
    } else {
      void listener(AnimationStatus status) {
        if (status == AnimationStatus.completed) {
          animation.removeStatusListener(listener);
          _focusFirstField();
        }
      }

      animation.addStatusListener(listener);
    }
  }

  void _focusFirstField() {
    if (!mounted) return;
    if (_toCtrl.text.trim().isEmpty) {
      _toFocus.requestFocus();
    } else {
      _bodyFocus.requestFocus();
      // Replies start above the quote.
      _bodyCtrl.selection = const TextSelection.collapsed(offset: 0);
    }
  }

  // The account address is not part of the login (only the Campus ID is), so
  // the sender identity is shown and editable like in any mail client. A
  // wrong sender is accepted by the TH relay and then dropped silently, so
  // it must never be an invisible guess.
  Future<void> _prefillFrom() async {
    final email = await mailService.accountEmail();
    if (mounted && email != null && _fromCtrl.text.isEmpty) {
      _fromCtrl.text = email;
    }
  }

  // A reopened draft opens with what the list knows (To, Subject) and gets its
  // body as soon as the full message is in.
  Future<void> _loadDraftBody() async {
    final uid = widget.replacing?.uid;
    if (uid == null) return;
    final full = await mailService.fetchFullMessage(uid, folder: MailFolder.drafts);
    if (!mounted || full == null) return;
    final loaded = draftFromMessage(full);
    if (_bodyCtrl.text.isEmpty) {
      _initialBody = loaded.body;
      _bodyCtrl.text = loaded.body;
    }
    if (_fromCtrl.text.isEmpty && loaded.from != null) _fromCtrl.text = loaded.from!;
  }

  void _onChanged() {
    final dirty = _toCtrl.text != widget.draft.to ||
        _subjectCtrl.text != widget.draft.subject ||
        _bodyCtrl.text != _initialBody;
    if (dirty != _dirty) {
      // Rebuilt for PopScope; the route re-reads enableDrag.
      setState(() => _dirty = dirty);
      _route?.refreshDrag();
    }
    // Only the Send button and the title follow the fields — rebuilding the
    // whole sheet on every keystroke would be wasted work while typing.
    final title = _subjectCtrl.text.trim();
    final canSend = _toCtrl.text.contains('@');
    if (title != _shownTitle || canSend != _shownCanSend) {
      setState(() {
        _shownTitle = title;
        _shownCanSend = canSend;
      });
    }
  }

  @override
  void dispose() {
    for (final c in [_fromCtrl, _toCtrl, _subjectCtrl, _bodyCtrl]) {
      c.dispose();
    }
    _toFocus.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  bool get _canSend => !_sending && !_saving && _shownCanSend;

  Future<void> _send() async {
    final from = _fromCtrl.text.trim();
    final to = _toCtrl.text.trim();
    if (!from.contains('@')) {
      setState(() => _error =
          'Enter your TH Köln address in the From field — you can see it in '
          'webmail under Sent.');
      return;
    }
    if (!to.contains('@')) {
      setState(() => _error = 'Invalid email address.');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await mailService.sendEmail(
        to,
        _subjectCtrl.text.trim(),
        _bodyCtrl.text,
        from: from,
      );
      final replacing = widget.replacing;
      if (replacing != null) unawaited(mailService.discardDraft(replacing));
      HapticFeedback.mediumImpact();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  Future<void> _close() async {
    // Nothing changed (an untouched reply, or a reopened draft left as it
    // was): just close.
    if (!_dirty) {
      Navigator.pop(context);
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final choice = await showCupertinoModalPopup<_CloseChoice>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, _CloseChoice.delete),
            child: const Text('Delete Draft'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, _CloseChoice.save),
            child: const Text('Save Draft'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    final replacing = widget.replacing;
    switch (choice) {
      case _CloseChoice.delete:
        if (replacing != null) unawaited(mailService.discardDraft(replacing));
        Navigator.pop(context);
      case _CloseChoice.save:
        setState(() {
          _saving = true;
          _error = null;
        });
        final ok = await mailService.saveDraft(
          from: _fromCtrl.text,
          to: _toCtrl.text,
          subject: _subjectCtrl.text.trim(),
          body: _bodyCtrl.text,
        );
        if (!mounted) return;
        if (!ok) {
          // The text stays right here — never lost to a failed save.
          setState(() {
            _saving = false;
            _error = "Couldn't save the draft. Check your connection and "
                'try again.';
          });
          return;
        }
        // Only once the new copy is safely stored.
        if (replacing != null) unawaited(mailService.discardDraft(replacing));
        Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    final dark = s == AppColorScheme.dark;
    final sheet = dark ? s.surfaceElevated : s.surface;
    final label = GoogleFonts.inter(fontSize: 16, color: s.textSecondary, height: 1.3);
    final value = GoogleFonts.inter(fontSize: 16, color: s.textPrimary, height: 1.3);
    final subject = _shownTitle;

    Widget divider() => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: SizedBox(
            height: 0.5,
            child: ColoredBox(color: s.textPrimary.withValues(alpha: 0.12)),
          ),
        );

    Widget field(
      String name,
      TextEditingController controller, {
      FocusNode? focus,
      TextInputType? keyboard,
      String? hint,
      bool sentences = false,
    }) =>
        SizedBox(
          height: 50,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Text('$name:', style: label),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: controller,
                    focusNode: focus,
                    keyboardType: keyboard,
                    autocorrect: sentences,
                    enableSuggestions: sentences,
                    textCapitalization: sentences
                        ? TextCapitalization.sentences
                        : TextCapitalization.none,
                    textInputAction: TextInputAction.next,
                    style: value,
                    cursorColor: s.accent,
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: hint,
                      hintStyle: value.copyWith(color: s.textTertiary),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Material(
        color: sheet,
        child: Column(
          children: [
            const SizedBox(height: 6),
            Container(
              width: 36,
              height: 5,
              decoration: BoxDecoration(
                color: s.textTertiary.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Row(
                children: [
                  _CircleButton(
                    label: 'Close',
                    onTap: (_sending || _saving) ? null : _close,
                    child: Icon(CupertinoIcons.xmark,
                        size: 19, color: s.navBarIcon),
                  ),
                  const Spacer(),
                  _SendButton(
                    enabled: _canSend,
                    busy: _sending || _saving,
                    onTap: _send,
                  ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                child: Text(
                  subject.isEmpty ? 'New Message' : subject,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.8,
                    height: 1.1,
                    color: s.textPrimary,
                  ),
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              child: _error == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: s.danger.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          _error!,
                          style: AppTextStyles.bodySmall(color: s.danger),
                        ),
                      ),
                    ),
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(
                    bottom: MediaQuery.viewInsetsOf(context).bottom),
                child: ListView(
                  padding: const EdgeInsets.only(top: 4, bottom: 40),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.manual,
                  children: [
                    field('To', _toCtrl,
                        focus: _toFocus, keyboard: TextInputType.emailAddress),
                    divider(),
                    field('From', _fromCtrl,
                        keyboard: TextInputType.emailAddress,
                        hint: 'your.name@smail.th-koeln.de'),
                    divider(),
                    field('Subject', _subjectCtrl, sentences: true),
                    divider(),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _bodyFocus.requestFocus(),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 320),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                          child: TextField(
                            controller: _bodyCtrl,
                            focusNode: _bodyFocus,
                            maxLines: null,
                            keyboardType: TextInputType.multiline,
                            textCapitalization: TextCapitalization.sentences,
                            cursorColor: s.accent,
                            style: value.copyWith(height: 1.45),
                            decoration: const InputDecoration(
                              isCollapsed: true,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                            ),
                          ),
                        ),
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

/// A 44 pt round button in the bottom cluster's glass material.
class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.label, required this.child, this.onTap});

  final String label;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox.square(
            dimension: 44,
            child: GlassPill(radius: 22, child: Center(child: child)),
          ),
        ),
      );
}

/// ↑ in a circle: accent-filled once there is someone to send to.
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.enabled,
    required this.busy,
    required this.onTap,
  });

  final bool enabled;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    if (busy) {
      return const SizedBox.square(
        dimension: 44,
        child: Center(child: CupertinoActivityIndicator()),
      );
    }
    final arrow = Icon(
      CupertinoIcons.arrow_up,
      size: 21,
      color: enabled ? s.onAccent : s.textTertiary,
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: 'Send',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: enabled
              ? DecoratedBox(
                  key: const ValueKey('on'),
                  decoration:
                      BoxDecoration(color: s.accent, shape: BoxShape.circle),
                  child: SizedBox.square(
                      dimension: 44, child: Center(child: arrow)),
                )
              : SizedBox.square(
                  key: const ValueKey('off'),
                  dimension: 44,
                  child: GlassPill(radius: 22, child: Center(child: arrow)),
                ),
        ),
      ),
    );
  }
}
