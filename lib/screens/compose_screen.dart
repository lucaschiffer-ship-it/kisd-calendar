import 'dart:async' show unawaited;
import 'dart:io' show File;

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/compose_attachments.dart';
import '../services/mail_attachments.dart';
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

  // ── Attachments ──
  final List<ComposeAttachment> _attachments = [];
  // What the sheet opened with (a forward's or a reopened draft's files):
  // only a change from this makes the sheet dirty.
  List<ComposeAttachment> _baseline = const [];
  // Placeholder tiles while a picker's files are copied or converted.
  int _loading = 0;
  Future<String>? _session;
  int? _sizeLimit;
  bool _sizeLimitAsked = false;
  // A reopened draft or a forward is still bringing its files in. Send waits
  // and Save Draft awaits [_prepared] — otherwise the old draft could be
  // replaced by one without its attachments.
  bool _preparing = false;
  Future<void>? _prepared;
  // The reopened draft never fully loaded (offline): its old copy is kept
  // after send/save instead of discarded, as it may hold what never arrived.
  bool _draftLoadFailed = false;
  // Scaling photos / reading files between tapping Send and the upload.
  bool _preparingSend = false;
  bool _menuOpen = false;
  ({bool camera, bool scanner})? _caps;
  final _clipLink = LayerLink();

  @override
  void initState() {
    super.initState();
    if (widget.draft.from == null) _prefillFrom();
    if (widget.replacing != null) {
      _preparing = true;
      _prepared = _loadDraftBody();
    } else if (widget.draft.attachments.isNotEmpty) {
      _preparing = true;
      _prepared = _restoreAttachments(widget.draft.attachments).whenComplete(
        () {
          if (mounted) setState(() => _preparing = false);
        },
      );
    }
    for (final c in [_toCtrl, _subjectCtrl, _bodyCtrl, _fromCtrl]) {
      c.addListener(_onChanged);
    }
    ComposeAttachments.onLoading = _onLoading;
    ComposeAttachments.capabilities().then((caps) {
      if (mounted) setState(() => _caps = caps);
    });
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
  // body — and its attachments — as soon as the full message is in.
  Future<void> _loadDraftBody() async {
    try {
      final uid = widget.replacing?.uid;
      if (uid == null) {
        _draftLoadFailed = true;
        return;
      }
      final full = await mailService.fetchFullMessage(
        uid,
        folder: MailFolder.drafts,
      );
      if (!mounted) return;
      if (full == null) {
        _draftLoadFailed = true;
        return;
      }
      final loaded = draftFromMessage(full);
      if (_bodyCtrl.text.isEmpty) {
        _initialBody = loaded.body;
        _bodyCtrl.text = loaded.body;
      }
      if (_fromCtrl.text.isEmpty && loaded.from != null) {
        _fromCtrl.text = loaded.from!;
      }
      await _restoreAttachments(attachmentsOf(full));
    } catch (_) {
      _draftLoadFailed = true;
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<String> _sessionDir() => _session ??= ComposeAttachments.newSession();

  /// A forward's or a reopened draft's files, written to disk so they behave
  /// like picked ones. They become the baseline: untouched, they don't make
  /// the sheet dirty.
  Future<void> _restoreAttachments(List<MailAttachmentData> files) async {
    if (files.isEmpty) return;
    final restored = <ComposeAttachment>[];
    try {
      final dir = await _sessionDir();
      for (final f in files) {
        restored.add(await ComposeAttachments.fromData(f, dir));
      }
    } catch (_) {
      // A file that couldn't be written must not cost the original draft.
      _draftLoadFailed = true;
    }
    if (!mounted) return;
    setState(() {
      _attachments.insertAll(0, restored);
      _baseline = List.of(restored);
    });
    restored.forEach(_startVariants);
    _ensureSizeLimit();
    _syncDirty();
  }

  void _onLoading(int count) {
    if (mounted) setState(() => _loading = count);
  }

  /// Scaled copies for the size choice, made in the background right away.
  void _startVariants(ComposeAttachment a) {
    if (!a.isPhoto) return;
    for (final px in kPhotoSizes.values) {
      a.variants[px] = ComposeAttachments.scale(a, px)..ignore();
    }
  }

  /// The server's size limit, asked once there is something to weigh.
  void _ensureSizeLimit() {
    if (_sizeLimit != null || _sizeLimitAsked || _attachments.isEmpty) return;
    _sizeLimitAsked = true;
    mailService.smtpSizeLimit().then((limit) {
      if (!mounted) return;
      if (limit == null) {
        _sizeLimitAsked = false; // offline: ask again with the next file
      } else {
        setState(() => _sizeLimit = limit);
      }
    });
  }

  void _toggleMenu() {
    HapticFeedback.selectionClick();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _menuOpen = !_menuOpen);
  }

  Future<void> _pick(AttachmentSource source) async {
    setState(() => _menuOpen = false);
    try {
      final result = await ComposeAttachments.pick(source, await _sessionDir());
      if (!mounted) return;
      setState(() {
        _loading = 0;
        _attachments.addAll(result.items);
        if (result.failed > 0) {
          _error = result.failed == 1
              ? "One item couldn't be added."
              : "${result.failed} items couldn't be added.";
        }
      });
      if (result.items.isNotEmpty) HapticFeedback.selectionClick();
      result.items.forEach(_startVariants);
      _ensureSizeLimit();
      _syncDirty();
    } on AttachmentException catch (e) {
      if (mounted) {
        setState(() {
          _loading = 0;
          _error = e.message;
        });
      }
    }
  }

  void _remove(ComposeAttachment a) {
    HapticFeedback.selectionClick();
    setState(() => _attachments.remove(a));
    _syncDirty();
  }

  void _preview(ComposeAttachment a) {
    ComposeAttachments.preview([
      for (final x in _attachments) x.path,
    ], _attachments.indexOf(a));
  }

  void _onChanged() {
    _syncDirty();
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

  void _syncDirty() {
    final dirty =
        _toCtrl.text != widget.draft.to ||
        _subjectCtrl.text != widget.draft.subject ||
        _bodyCtrl.text != _initialBody ||
        !listEquals(_attachments, _baseline);
    if (dirty != _dirty) {
      // Rebuilt for PopScope; the route re-reads enableDrag.
      setState(() => _dirty = dirty);
      _route?.refreshDrag();
    }
  }

  @override
  void dispose() {
    if (ComposeAttachments.onLoading == _onLoading) {
      ComposeAttachments.onLoading = null;
    }
    // The sheet's copies go with it — a sent or saved mail has its own.
    _session?.then(ComposeAttachments.deleteSession);
    for (final c in [_fromCtrl, _toCtrl, _subjectCtrl, _bodyCtrl]) {
      c.dispose();
    }
    _toFocus.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  bool get _busy => _sending || _saving || _preparingSend;

  bool get _canSend => !_busy && !_preparing && _shownCanSend;

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
    var files = const <MailAttachmentData>[];
    if (_attachments.isNotEmpty) {
      final outgoing = await _outgoingAttachments();
      if (outgoing == null || !mounted) return;
      files = outgoing;
    }
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
        attachments: files,
      );
      final replacing = widget.replacing;
      if (replacing != null && !_draftLoadFailed) {
        unawaited(mailService.discardDraft(replacing));
      }
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

  /// The files as they go out: photos at the size picked in the size sheet,
  /// everything else byte for byte. Null when cancelled or too big — the
  /// banner then says why.
  Future<List<MailAttachmentData>?> _outgoingAttachments() async {
    final current = List.of(_attachments);
    final photos = current.where((a) => a.isPhoto).toList();
    final others = current.where((a) => !a.isPhoto).toList();
    final body = _bodyCtrl.text.length;
    final limit = _sizeLimit;
    setState(() {
      _preparingSend = true;
      _error = null;
    });
    try {
      var chosen = <ComposeAttachment, ScaledPhoto>{};
      if (photos.isNotEmpty) {
        // Real totals per size, so the sheet's numbers are what goes out.
        final options = <String, Map<ComposeAttachment, ScaledPhoto>>{};
        for (final size in kPhotoSizes.entries) {
          options[size.key] = {
            for (final p in photos) p: await _scaled(p, size.value),
          };
        }
        options['Actual Size'] = {
          for (final p in photos) p: ScaledPhoto(p.path, p.size),
        };
        if (!mounted) return null;
        final pick = await _askPhotoSize(options, others, body, limit);
        if (pick == null || !mounted) return null;
        chosen = options[pick]!;
      }
      final sizes = [
        for (final a in others) a.size,
        for (final v in chosen.values) v.size,
      ];
      if (exceedsMailLimit(body, sizes, limit)) {
        setState(
          () => _error = mailTooBigMessage(
            sizes.fold(0, (a, b) => a + b),
            attachmentAllowance(limit!, bodyLength: body, count: sizes.length),
          ),
        );
        return null;
      }
      return [
        for (final a in current)
          MailAttachmentData(
            name: a.name,
            mimeType: a.mimeType,
            bytes: await File(chosen[a]?.path ?? a.path).readAsBytes(),
            isPhoto: a.isPhoto,
          ),
      ];
    } catch (e) {
      if (mounted) {
        setState(
          () => _error =
              "Couldn't read an attachment. Remove it "
              'and add it again.',
        );
      }
      return null;
    } finally {
      if (mounted) setState(() => _preparingSend = false);
    }
  }

  /// [photo] at [maxPixel]; the original when scaling failed.
  Future<ScaledPhoto> _scaled(ComposeAttachment photo, int maxPixel) async {
    try {
      return await (photo.variants[maxPixel] ??= ComposeAttachments.scale(
        photo,
        maxPixel,
      ));
    } catch (_) {
      return ScaledPhoto(photo.path, photo.size);
    }
  }

  /// Apple Mail's size question, with the real total for each choice.
  Future<String?> _askPhotoSize(
    Map<String, Map<ComposeAttachment, ScaledPhoto>> options,
    List<ComposeAttachment> others,
    int bodyLength,
    int? limit,
  ) {
    List<int> sizesFor(String option) => [
      for (final a in others) a.size,
      for (final v in options[option]!.values) v.size,
    ];
    int totalFor(String option) => sizesFor(option).fold(0, (a, b) => a + b);
    return showCupertinoModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(
          'This message is ${byteSizeLabel(totalFor('Actual Size'))}.',
        ),
        message: const Text('Scale photos to reduce it:'),
        actions: [
          for (final option in options.keys)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, option),
              child: Text(
                '$option (${byteSizeLabel(totalFor(option))})'
                '${exceedsMailLimit(bodyLength, sizesFor(option), limit) ? ' — too big' : ''}',
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
      ),
    );
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
        // A reopened draft's files must be in before its old copy goes.
        try {
          await _prepared;
        } catch (_) {}
        // Drafts keep photos at actual size; the size question is for Send.
        final List<MailAttachmentData> files;
        try {
          files = [
            for (final a in List.of(_attachments))
              MailAttachmentData(
                name: a.name,
                mimeType: a.mimeType,
                bytes: await File(a.path).readAsBytes(),
                isPhoto: a.isPhoto,
              ),
          ];
        } catch (_) {
          if (mounted) {
            setState(() {
              _saving = false;
              _error = "Couldn't read an attachment. Remove it and add it "
                  'again.';
            });
          }
          return;
        }
        if (!mounted) return;
        final ok = await mailService.saveDraft(
          from: _fromCtrl.text,
          to: _toCtrl.text,
          subject: _subjectCtrl.text.trim(),
          body: _bodyCtrl.text,
          attachments: files,
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
        if (replacing != null && !_draftLoadFailed) {
          unawaited(mailService.discardDraft(replacing));
        }
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
        child: Stack(
          children: [
            Column(
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
                        onTap: _busy ? null : _close,
                        child: Icon(CupertinoIcons.xmark,
                            size: 19, color: s.navBarIcon),
                      ),
                      const Spacer(),
                      CompositedTransformTarget(
                        link: _clipLink,
                        child: _CircleButton(
                          label: 'Add Attachment',
                          onTap: _busy ? null : _toggleMenu,
                          child: Icon(CupertinoIcons.paperclip,
                              size: 20, color: s.navBarIcon),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _SendButton(
                        enabled: _canSend,
                        busy: _busy,
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
                        if (_attachments.isNotEmpty || _loading > 0) ...[
                          _attachmentList(),
                          divider(),
                        ],
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
            // The paperclip's menu: a tap anywhere else closes it.
            if (_menuOpen)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _menuOpen = false),
                ),
              ),
            CompositedTransformFollower(
              link: _clipLink,
              targetAnchor: Alignment.bottomRight,
              followerAnchor: Alignment.topRight,
              offset: const Offset(0, 8),
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: _menuOpen ? 1 : 0),
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                builder: (context, t, menu) => t == 0
                    ? const SizedBox.shrink()
                    : IgnorePointer(
                        ignoring: !_menuOpen,
                        child: Opacity(
                          opacity: t,
                          child: Transform.scale(
                            scale: 0.85 + 0.15 * t,
                            alignment: Alignment.topRight,
                            child: menu,
                          ),
                        ),
                      ),
                child: _AttachMenu(
                  camera: _caps?.camera ?? false,
                  scanner: _caps?.scanner ?? false,
                  onPick: _pick,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Tiles under the subject — above the body, so the keyboard never hides
  /// them — and the running total, red once it's more than the server takes.
  Widget _attachmentList() {
    final s = AppColorScheme.current;
    final total = _attachments.fold(0, (sum, a) => sum + a.size);
    final limit = _sizeLimit;
    final over = exceedsMailLimit(
      _bodyCtrl.text.length,
      _attachments.map((a) => a.size),
      limit,
    );
    final count = _attachments.length;
    var summary =
        '$count attachment${count == 1 ? '' : 's'} · ${byteSizeLabel(total)}';
    if (over) {
      final allowance = attachmentAllowance(
        limit!,
        bodyLength: _bodyCtrl.text.length,
        count: count,
      );
      summary += ' — over the ${byteSizeLabel(allowance)} limit';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final a in _attachments)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _AttachmentTile(
                attachment: a,
                onTap: () => _preview(a),
                onRemove: _busy ? null : () => _remove(a),
              ),
            ),
          for (var i = 0; i < _loading; i++)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: _AttachmentTile(),
            ),
          if (count > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
              child: Text(
                summary,
                style: AppTextStyles.bodySmall(
                  color: over ? s.danger : s.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The paperclip's pull-down: one row per source, in the app's glass.
class _AttachMenu extends StatelessWidget {
  const _AttachMenu({
    required this.camera,
    required this.scanner,
    required this.onPick,
  });

  final bool camera;
  final bool scanner;
  final ValueChanged<AttachmentSource> onPick;

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    Widget divider() => SizedBox(
      height: 0.5,
      child: ColoredBox(color: s.textPrimary.withValues(alpha: 0.12)),
    );
    return SizedBox(
      width: 250,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 30,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: GlassPill(
          radius: 18,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _MenuRow(
                  label: 'Photo Library',
                  icon: CupertinoIcons.photo_on_rectangle,
                  onTap: () => onPick(AttachmentSource.photoLibrary),
                ),
                divider(),
                _MenuRow(
                  label: 'Take Photo',
                  icon: CupertinoIcons.camera,
                  onTap: camera ? () => onPick(AttachmentSource.camera) : null,
                ),
                divider(),
                _MenuRow(
                  label: 'Scan Document',
                  icon: CupertinoIcons.doc_text_viewfinder,
                  onTap: scanner
                      ? () => onPick(AttachmentSource.scanner)
                      : null,
                ),
                divider(),
                _MenuRow(
                  label: 'Attach File',
                  icon: CupertinoIcons.folder,
                  onTap: () => onPick(AttachmentSource.files),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A menu row that highlights while pressed, like iOS's. Greyed out and
/// inert without [onTap] (e.g. no camera on this device).
class _MenuRow extends StatefulWidget {
  const _MenuRow({required this.label, required this.icon, this.onTap});

  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _pressed = false;

  void _setPressed(bool pressed) {
    if (pressed != _pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    final enabled = widget.onTap != null;
    final color = enabled ? s.textPrimary : s.textTertiary;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _setPressed(true) : null,
        onTapUp: enabled ? (_) => _setPressed(false) : null,
        onTapCancel: enabled ? () => _setPressed(false) : null,
        onTap: widget.onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                widget.onTap!();
              },
        child: ColoredBox(
          color: _pressed
              ? s.textPrimary.withValues(alpha: 0.08)
              : Colors.transparent,
          child: SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.label,
                      style: GoogleFonts.inter(fontSize: 16, color: color),
                    ),
                  ),
                  Icon(widget.icon, size: 20, color: color),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One attachment, styled like the message view's tiles: a thumbnail or a
/// type badge, the name and size, and × to remove. Without an attachment
/// it's the placeholder shown while a picked file is still on its way.
class _AttachmentTile extends StatelessWidget {
  const _AttachmentTile({this.attachment, this.onTap, this.onRemove});

  final ComposeAttachment? attachment;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    final dark = s == AppColorScheme.dark;
    final a = attachment;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        decoration: BoxDecoration(
          color: dark ? s.surface : const Color(0xFFF2F2F2),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 38,
              child: a == null
                  ? const Center(child: CupertinoActivityIndicator())
                  : _AttachmentThumb(attachment: a),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    a?.name ?? 'Adding…',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                      color: a == null ? s.textSecondary : s.textPrimary,
                    ),
                  ),
                  if (a != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        byteSizeLabel(a.size),
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          height: 1.3,
                          color: s.textSecondary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (a != null)
              Semantics(
                button: true,
                label: 'Remove ${a.name}',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onRemove,
                  child: SizedBox.square(
                    dimension: 40,
                    child: Icon(
                      CupertinoIcons.xmark_circle_fill,
                      size: 22,
                      color: s.textTertiary,
                    ),
                  ),
                ),
              )
            else
              const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

/// A picture's own thumbnail, a video's still frame with a play mark, or
/// the extension badge the message view uses.
class _AttachmentThumb extends StatelessWidget {
  const _AttachmentThumb({required this.attachment});

  final ComposeAttachment attachment;

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    final a = attachment;
    final picture = a.thumbPath ?? (a.isImage ? a.path : null);
    final badge = DecoratedBox(
      decoration: BoxDecoration(
        color: s.accent.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Center(
        child: Text(
          _extension(a.name),
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
            color: s.accent,
          ),
        ),
      ),
    );
    if (picture == null) return badge;
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.file(
            File(picture),
            fit: BoxFit.cover,
            cacheWidth: 120,
            errorBuilder: (_, _, _) => badge,
          ),
          if (a.kind == AttachmentKind.video)
            const Center(
              child: Icon(
                CupertinoIcons.play_fill,
                size: 16,
                color: Colors.white,
              ),
            ),
        ],
      ),
    );
  }

  // Same as the message view's badge: the extension, at most four letters.
  static String _extension(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 && dot < name.length - 1
        ? name.substring(dot + 1).toUpperCase()
        : 'FILE';
    return ext.length > 4 ? ext.substring(0, 4) : ext;
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
