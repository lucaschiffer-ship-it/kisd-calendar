import 'dart:io';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/compose_attachments.dart';
import '../services/mail_actions.dart';
import '../services/mail_display.dart';
import '../services/mail_html.dart';
import '../services/mail_service.dart' show MailFolder, ThreadMessage;
import '../services/mail_threads.dart' show hasForwardPrefix;
import '../services/service_locator.dart';
import '../services/spaces_browser.dart';
import '../services/theme_service.dart';
import '../theme/tokens.dart';
import '../widgets/glass_pill.dart';
import '../widgets/mail_avatar.dart';
import '../widgets/page_floating_actions.dart';

/// One mail, Apple Mail–style: the header and the body are one web document,
/// so the header scrolls away *with* the mail; it shows sender, time and the
/// first recipient, and expands to the full details when tapped. Back and the
/// actions float at the bottom in the app's glass pills.
///
/// When the mail is part of a conversation, the page shows the whole
/// conversation instead: its mails oldest first as cards, the opened one
/// unfolded, each reply's quoted history behind a "•••" toggle. Back and the
/// actions still act on the opened mail.
///
/// Lives on the mail route layer (see `MailRouteLayer`), below the Spaces
/// browser sheet — so a link opens the browser over this screen, and closing
/// the browser comes straight back here.
class EmailDetailScreen extends StatefulWidget {
  const EmailDetailScreen({
    super.key,
    required this.message,
    required this.folder,
    required this.actions,
    required this.onReply,
    required this.onForward,
    required this.onMailto,
  });

  final MimeMessage message;

  /// IMAP folder the message lives in — UIDs are only valid per folder.
  final MailFolder folder;

  /// The list's optimistic state: read flags, delete and restore all go
  /// through it, so the list is already up to date when this screen pops.
  /// (Opening marks the mail read — the list does that before the push, since
  /// notifying it from this screen's build would rebuild it mid-frame.)
  final MailActions actions;

  final void Function(MimeMessage full) onReply;
  final void Function(MimeMessage full) onForward;
  final void Function(Uri mailto) onMailto;

  @override
  State<EmailDetailScreen> createState() => _EmailDetailScreenState();
}

class _EmailDetailScreenState extends State<EmailDetailScreen> {
  /// How long opening waits for the conversation lookup before showing the
  /// mail on its own. A slower lookup still finishes and is remembered, so
  /// the next open shows the conversation at once.
  static const _threadWait = Duration(seconds: 3);

  MimeMessage? _full;

  /// The conversation on screen, oldest first — null when the mail is shown
  /// on its own.
  List<ThreadMessage>? _thread;
  String? _document;
  bool _loadFailed = false;
  bool _routeSettled = false;
  bool _webVisible = false;
  bool _started = false;

  // Each mail's attachments on disk for Quick Look, one per tile (null where
  // a part couldn't be decoded) — written on the first tap, deleted on close.
  final _attachmentFiles = <MimeMessage, Future<List<String?>>>{};
  final _attachmentDirs = <Directory>[];

  static final _fontBytes = <String, Uint8List>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // The web view is created only once the push has finished: creating a
    // platform view mid-slide is what used to drop frames on open.
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.isCompleted) {
      _routeSettled = true;
    } else {
      void listener(AnimationStatus status) {
        if (status == AnimationStatus.completed) {
          animation.removeStatusListener(listener);
          if (mounted) setState(() => _routeSettled = true);
        }
      }

      animation.addStatusListener(listener);
    }
    _load();
  }

  @override
  void dispose() {
    for (final dir in _attachmentDirs) {
      dir.delete(recursive: true).ignore();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final uid = widget.message.uid;
    final full = uid != null
        ? await mailService.fetchFullMessage(uid, folder: widget.folder)
        : widget.message;
    if (!mounted) return;
    // Offline the lookup could only fail — after waiting out a connect — so
    // a mail from the offline copy opens at once, as before.
    final found =
        full != null &&
            widget.folder != MailFolder.drafts &&
            mailService.isConnected
        ? await mailService
              .fetchThread(full, widget.folder)
              .timeout(_threadWait, onTimeout: () => null)
        : null;
    if (!mounted) return;
    final thread = found != null && found.length > 1 ? found : null;
    // Off the UI thread: parsing a big newsletter would drop frames. A
    // top-level function and plain data, so nothing else is copied across.
    final document = thread != null
        ? await compute(buildThreadDocument, _threadSpec(thread, full!))
        : await compute(
            buildMailDocument,
            _spec(full ?? widget.message, loaded: full != null),
          );
    if (!mounted) return;
    setState(() {
      _full = full;
      _thread = thread;
      _loadFailed = full == null;
      _document = document;
    });
  }

  // ── Document ──────────────────────────────────────────────────────────────

  static String _css(Color c) {
    final v = c.toARGB32();
    final a = (v >> 24) & 0xFF;
    final r = (v >> 16) & 0xFF, g = (v >> 8) & 0xFF, b = v & 0xFF;
    if (a == 0xFF) {
      return '#${(v & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
    }
    return 'rgba($r,$g,$b,${(a / 255).toStringAsFixed(3)})';
  }

  bool get _dark => ThemeService.instance.currentColor.value != 'light';

  Color get _readingBackground =>
      _dark ? AppColorScheme.current.background : Colors.white;

  MailHtmlColors _htmlColors() {
    final s = AppColorScheme.current;
    final dark = _dark;
    return MailHtmlColors(
      dark: dark,
      background: _css(_readingBackground),
      text: _css(s.textPrimary),
      secondary: _css(s.textSecondary),
      tertiary: _css(s.textTertiary),
      divider: dark ? 'rgba(255,255,255,0.12)' : 'rgba(0,0,0,0.12)',
      accent: _css(s.accent),
      surface: dark ? _css(s.surface) : '#F2F2F2',
    );
  }

  ThreadDocumentSpec _threadSpec(
    List<ThreadMessage> thread,
    MimeMessage opened,
  ) {
    final statusH = ScreenInsets.of(context).top;
    // A mail left on the server is envelope-only: its subject and date are
    // in the envelope, not in headers.
    final first = thread.first.message;
    final subject = first.envelope?.subject?.trim();
    return ThreadDocumentSpec(
      colors: _htmlColors(),
      subject: subject == null || subject.isEmpty ? subjectOf(first) : subject,
      // The opened mail and the newest are unfolded.
      entries: [
        for (final t in thread)
          _entrySpec(
            t,
            open: identical(t.message, opened) || identical(t, thread.last),
          ),
      ],
      viewportWidth: MediaQuery.sizeOf(context).width,
      topPadding: statusH + 6,
      bottomPadding: bottomClusterHeight(context) + 36,
    );
  }

  ThreadEntrySpec _entrySpec(ThreadMessage t, {required bool open}) {
    final msg = t.message;
    final name = senderName(msg);
    final avatar = MailAvatarColors.of(name, dark: _dark);
    final date = (msg.envelope?.date ?? msg.decodeDate())?.toLocal();
    final to = (msg.to ?? const <MailAddress>[]).map(addressLabel).toList();
    final cc = (msg.cc ?? const <MailAddress>[]).map(addressLabel).toList();

    String? html;
    String? plain;
    if (t.downloaded) {
      try {
        html = msg.decodeTextHtmlPart();
      } catch (_) {}
      if (html == null || html.trim().isEmpty) {
        html = null;
        plain = messageBodyText(msg);
      }
    }
    final size = msg.size;

    return ThreadEntrySpec(
      senderName: name,
      senderEmail: senderEmail(msg),
      avatarInitial: avatarInitial(name),
      avatarTint: _css(avatar.background),
      avatarText: _css(avatar.foreground),
      time: listDateLabel(date),
      toSummary: to.isEmpty
          ? 'Undisclosed recipients'
          : (to.length == 1 ? to.first : '${to.first}, +${to.length - 1}'),
      to: to,
      cc: cc,
      fullDate: date == null ? null : fullDateLabel(date),
      html: html,
      plain: plain,
      attachments: t.downloaded ? _attachments(msg) : const [],
      open: open,
      foldQuotes: !hasForwardPrefix(msg.decodeSubject()),
      unavailable: t.downloaded
          ? null
          : size != null
          ? "This message wasn't downloaded here "
                '(${byteSizeLabel(size)}). Open it from the list.'
          : "This message couldn't be downloaded.",
    );
  }

  MailDocumentSpec _spec(MimeMessage msg, {required bool loaded}) {
    final dark = _dark;
    final statusH = ScreenInsets.of(context).top;
    final name = senderName(msg);
    final avatar = MailAvatarColors.of(name, dark: dark);
    final date = msg.decodeDate()?.toLocal();
    final to = (msg.to ?? const <MailAddress>[]).map(addressLabel).toList();
    final cc = (msg.cc ?? const <MailAddress>[]).map(addressLabel).toList();

    String? html;
    String? plain;
    if (loaded) {
      try {
        html = msg.decodeTextHtmlPart();
      } catch (_) {}
      if (html == null || html.trim().isEmpty) {
        html = null;
        plain = messageBodyText(msg);
      }
    } else {
      plain = "This message couldn't be downloaded. Check your connection "
          'and open it again.';
    }

    return MailDocumentSpec(
      colors: _htmlColors(),
      senderName: name,
      senderEmail: senderEmail(msg),
      avatarInitial: avatarInitial(name),
      avatarTint: _css(avatar.background),
      avatarText: _css(avatar.foreground),
      time: listDateLabel(date),
      toSummary: to.isEmpty
          ? 'Undisclosed recipients'
          : (to.length == 1 ? to.first : '${to.first}, +${to.length - 1}'),
      to: to,
      cc: cc,
      fullDate: date == null ? null : fullDateLabel(date),
      subject: subjectOf(msg),
      html: html,
      plain: plain,
      attachments: loaded ? _attachments(msg) : const [],
      viewportWidth: MediaQuery.sizeOf(context).width,
      topPadding: statusH + 6,
      bottomPadding: bottomClusterHeight(context) + 36,
    );
  }

  List<MailAttachmentTile> _attachments(MimeMessage msg) {
    try {
      return msg
          .findContentInfo(disposition: ContentDisposition.attachment)
          .map((info) {
        var size = info.size;
        if (size == null) {
          final data = msg.getPart(info.fetchId)?.mimeData;
          if (data != null) {
            final base64 = msg
                    .getPart(info.fetchId)
                    ?.getHeaderValue('content-transfer-encoding')
                    ?.toLowerCase()
                    .contains('base64') ??
                false;
            size = base64 ? (data.size * 0.74).round() : data.size;
          }
        }
        return MailAttachmentTile(
          name: info.fileName ?? 'Attachment',
          size: size == null ? '' : byteSizeLabel(size),
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  // ── Web view callbacks ────────────────────────────────────────────────────

  Future<CustomSchemeResponse?> _resource(
    InAppWebViewController controller,
    WebResourceRequest request,
  ) async {
    final url = request.url;
    try {
      if (url.scheme == kMailScheme && url.path.startsWith('/fonts/')) {
        final file = url.path.substring('/fonts/'.length);
        if (!kMailFontFiles.contains(file)) return null;
        final bytes = _fontBytes[file] ??=
            (await rootBundle.load('google_fonts/$file')).buffer.asUint8List();
        return CustomSchemeResponse(data: bytes, contentType: 'font/ttf');
      }
      if (url.scheme == 'cid') {
        final part = _partWithContentId(
            Uri.decodeComponent(url.toString().substring('cid:'.length)));
        final bytes = part?.decodeContentBinary();
        if (part == null || bytes == null) return null;
        return CustomSchemeResponse(
          data: bytes,
          contentType: part.mediaType.text,
        );
      }
    } catch (_) {}
    return null;
  }

  MimePart? _partWithContentId(String cid) {
    final want = cid.trim().replaceAll(RegExp(r'^<|>$'), '').toLowerCase();
    // In a conversation, any of its mails — Content-IDs are unique.
    final messages = [
      ...?_thread?.where((t) => t.downloaded).map((t) => t.message),
      if (_thread == null) ?_full,
    ];
    for (final message in messages) {
      for (final part in message.allPartsFlat) {
        final id = part
            .getHeaderValue('content-id')
            ?.trim()
            .replaceAll(RegExp(r'^<|>$'), '')
            .toLowerCase();
        if (id == want) return part;
      }
    }
    return null;
  }

  Future<NavigationActionPolicy> _navigate(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final url = action.request.url;
    if (url == null) return NavigationActionPolicy.ALLOW;
    final scheme = url.scheme.toLowerCase();

    // An attachment tile.
    final attachment = attachmentIndexOf(url);
    final inThread = threadAttachmentOf(url);
    if (attachment != null || inThread != null) {
      final thread = _thread;
      final message = inThread == null
          ? _full
          : (thread != null && inThread.entry < thread.length
                ? thread[inThread.entry].message
                : null);
      if (message != null &&
          action.isForMainFrame &&
          action.navigationType == NavigationType.LINK_ACTIVATED) {
        HapticFeedback.selectionClick();
        _openAttachment(message, inThread?.index ?? attachment!);
      }
      return NavigationActionPolicy.CANCEL;
    }
    // The document itself (and its in-page #anchors) — nothing else under the
    // document's own scheme is a real page.
    if (scheme == kMailScheme) {
      return (url.path.isEmpty || url.path == '/')
          ? NavigationActionPolicy.ALLOW
          : NavigationActionPolicy.CANCEL;
    }
    if (scheme == 'about' || scheme == 'x-apple-data-detectors') {
      return NavigationActionPolicy.ALLOW;
    }
    // Only a link the user tapped in the mail itself goes anywhere. Frames,
    // redirects and form posts never open the browser on their own.
    if (!action.isForMainFrame ||
        action.navigationType != NavigationType.LINK_ACTIVATED) {
      return NavigationActionPolicy.CANCEL;
    }
    if (scheme == 'http' || scheme == 'https') {
      HapticFeedback.selectionClick();
      SpacesBrowser.open(url.toString());
    } else if (scheme == 'mailto') {
      widget.onMailto(Uri.parse(url.toString()));
    } else {
      final uri = Uri.tryParse(url.toString());
      if (uri != null) {
        launchUrl(uri, mode: LaunchMode.externalApplication).ignore();
      }
    }
    return NavigationActionPolicy.CANCEL;
  }

  // ── Attachments ───────────────────────────────────────────────────────────

  /// Quick Look over all of [message]'s attachments, opened at tile [index],
  /// so the others are a swipe away.
  Future<void> _openAttachment(MimeMessage message, int index) async {
    try {
      final files = await (_attachmentFiles[message] ??=
          _writeAttachments(message));
      final path = index < files.length ? files[index] : null;
      if (path == null || !mounted) return;
      final paths = files.nonNulls.toList();
      await ComposeAttachments.preview(paths, paths.indexOf(path));
    } catch (_) {}
  }

  /// Each attachment in its own folder, so two files of the same name
  /// don't collide. In the same order as the tiles (`_attachments`).
  Future<List<String?>> _writeAttachments(MimeMessage message) async {
    final base = await getTemporaryDirectory();
    final dir = Directory(
      '${base.path}/mail_attachments/${DateTime.now().microsecondsSinceEpoch}',
    );
    _attachmentDirs.add(dir);
    final files = <String?>[];
    final infos =
        message.findContentInfo(disposition: ContentDisposition.attachment);
    for (final (i, info) in infos.indexed) {
      try {
        final bytes = message.getPart(info.fetchId)?.decodeContentBinary();
        if (bytes == null) {
          files.add(null);
          continue;
        }
        final folder =
            await Directory('${dir.path}/$i').create(recursive: true);
        final name = (info.fileName ?? '').replaceAll('/', '-').trim();
        final file =
            File('${folder.path}/${name.isEmpty ? 'Attachment' : name}');
        await file.writeAsBytes(bytes, flush: true);
        files.add(file.path);
      } catch (_) {
        files.add(null); // one unreadable part must not cost the others
      }
    }
    // Closed while writing: dispose already ran, so clean up here.
    if (!mounted) dir.delete(recursive: true).ignore();
    return files;
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  bool get _inTrash => widget.folder == MailFolder.trash;

  void _deleteOrRestore() {
    HapticFeedback.mediumImpact();
    Navigator.pop(context);
    if (_inTrash) {
      widget.actions.restore(widget.message);
    } else {
      widget.actions.delete(widget.message, widget.folder);
    }
  }

  void _toggleSeen() {
    HapticFeedback.selectionClick();
    widget.actions.toggleSeen(widget.message, widget.folder);
  }

  MimeMessage get _forCompose => _full ?? widget.message;

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    final bg = _readingBackground;
    final statusH = ScreenInsets.of(context).top;
    final document = _document;
    final showWeb = document != null && _routeSettled;

    // Material, not a bare ColoredBox: it gives the Flutter header its text
    // defaults (no debug underline) while the web view loads.
    return Material(
      color: bg,
      child: Stack(
        children: [
          if (showWeb)
            Positioned.fill(
              child: AnimatedOpacity(
                opacity: _webVisible ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: _webView(document, bg),
              ),
            ),
          // Until the web view has painted: the same header, in Flutter.
          Positioned.fill(
            child: IgnorePointer(
              ignoring: _webVisible,
              child: AnimatedOpacity(
                opacity: _webVisible ? 0 : 1,
                duration: const Duration(milliseconds: 180),
                child: _Placeholder(
                  message: widget.message,
                  dark: _dark,
                  top: statusH + 6,
                ),
              ),
            ),
          ),
          // Status bar: solid under the clock, then the mail fades in.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: statusH + 22,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [bg, bg, bg.withValues(alpha: 0)],
                    stops: [0, (statusH - 6) / (statusH + 22), 1],
                  ),
                ),
              ),
            ),
          ),
          // Behind the bottom cluster. Glass blurs the mail, but a dark-mode
          // pill over a white newsletter would still be white on white.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: bottomClusterHeight(context) + 56,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      bg.withValues(alpha: 0),
                      bg.withValues(alpha: 0.72),
                      bg.withValues(alpha: 0.9),
                    ],
                    stops: const [0, 0.55, 1],
                  ),
                ),
              ),
            ),
          ),
          if (_loadFailed)
            Positioned(
              left: 0,
              right: 0,
              bottom: bottomClusterHeight(context) + 20,
              child: Center(
                child: CupertinoButton(
                  onPressed: () {
                    setState(() {
                      _loadFailed = false;
                      _document = null;
                      _webVisible = false;
                    });
                    _load();
                  },
                  child: Text('Try again',
                      style: AppTextStyles.bodyBold(color: s.accent)),
                ),
              ),
            ),
          Positioned(
            left: 12,
            bottom: bottomClusterInset(context),
            height: kFloatingButtonSize,
            child: _buildBottomCluster(s),
          ),
        ],
      ),
    );
  }

  Widget _webView(String document, Color bg) {
    return InAppWebView(
      initialData: InAppWebViewInitialData(
        data: document,
        mimeType: 'text/html',
        encoding: 'utf-8',
        baseUrl: WebUri(kMailBaseUrl),
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: false,
        transparentBackground: true,
        useShouldOverrideUrlLoading: true,
        resourceCustomSchemes: const [kMailScheme, 'cid'],
        contentInsetAdjustmentBehavior:
            ScrollViewContentInsetAdjustmentBehavior.NEVER,
        underPageBackgroundColor: bg,
        allowsLinkPreview: false,
        // No cookies or storage from a mail's tracking pixels outlive it.
        incognito: true,
        dataDetectorTypes: const [
          DataDetectorTypes.PHONE_NUMBER,
          DataDetectorTypes.LINK,
        ],
      ),
      onLoadResourceWithCustomScheme: _resource,
      shouldOverrideUrlLoading: _navigate,
      onLoadStop: (_, _) {
        if (mounted && !_webVisible) setState(() => _webVisible = true);
      },
    );
  }

  Widget _buildBottomCluster(AppColorScheme s) {
    final icon = s.navBarIcon;
    final radius = ThemeService.instance.roundedBars.value
        ? kFloatingButtonSize / 2
        : AppRadius.chip;

    Widget slot({
      required IconData glyph,
      required String label,
      required VoidCallback? onTap,
      Color? color,
    }) =>
        Semantics(
          button: true,
          label: label,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: SizedBox(
              width: 54,
              child: Center(
                child: Icon(
                  glyph,
                  size: 22,
                  color: onTap == null ? s.textTertiary : (color ?? icon),
                ),
              ),
            ),
          ),
        );

    final loaded = _full != null;
    return Row(
      children: [
        Semantics(
          button: true,
          label: 'Back',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.maybePop(context),
            child: SizedBox.square(
              dimension: kFloatingButtonSize,
              child: GlassPill(
                radius: radius,
                child: Center(
                  child: Icon(CupertinoIcons.chevron_back, color: icon, size: 22),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        GlassPill(
          radius: radius,
          child: ListenableBuilder(
            listenable: widget.actions,
            builder: (context, _) {
              final seen = widget.actions.isSeen(widget.message, widget.folder);
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(width: 4),
                  slot(
                    glyph: _inTrash
                        ? CupertinoIcons.tray_arrow_up
                        : CupertinoIcons.trash,
                    label: _inTrash ? 'Restore' : 'Delete',
                    onTap: _deleteOrRestore,
                  ),
                  slot(
                    glyph: seen
                        ? CupertinoIcons.envelope_badge
                        : CupertinoIcons.envelope_open,
                    label: seen ? 'Mark as unread' : 'Mark as read',
                    onTap: _toggleSeen,
                  ),
                  slot(
                    glyph: CupertinoIcons.reply,
                    label: 'Reply',
                    onTap: loaded ? () => widget.onReply(_forCompose) : null,
                  ),
                  slot(
                    glyph: CupertinoIcons.arrowshape_turn_up_right,
                    label: 'Forward',
                    onTap: loaded ? () => widget.onForward(_forCompose) : null,
                  ),
                  const SizedBox(width: 4),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// The collapsed header drawn in Flutter with the document's fonts and
/// metrics, shown until the web view has painted the real one.
class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.message,
    required this.dark,
    required this.top,
  });

  final MimeMessage message;
  final bool dark;
  final double top;

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    final name = senderName(message);
    final to = message.to ?? const <MailAddress>[];
    final toSummary = to.isEmpty
        ? 'Undisclosed recipients'
        : (to.length == 1
            ? addressLabel(to.first)
            : '${addressLabel(to.first)}, +${to.length - 1}');
    final inter = GoogleFonts.inter(
        fontSize: 15, height: 1.35, color: s.textSecondary);

    return Padding(
      padding: EdgeInsets.fromLTRB(20, top + 8, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MailAvatar(name: name, dark: dark),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 1),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.spaceGrotesk(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.2,
                              height: 1.3,
                              color: s.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          listDateLabel(message.decodeDate()?.toLocal()),
                          style: inter.copyWith(height: 1.3),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text.rich(
                      TextSpan(children: [
                        TextSpan(
                          text: 'To: ',
                          style: inter.copyWith(color: s.textPrimary),
                        ),
                        TextSpan(text: toSummary),
                      ]),
                      style: inter,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 0.5,
            width: double.infinity,
            child: ColoredBox(
              color: (dark ? Colors.white : Colors.black)
                  .withValues(alpha: 0.12),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            subjectOf(message),
            style: GoogleFonts.spaceGrotesk(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
              height: 1.22,
              color: s.textPrimary,
            ),
          ),
          const SizedBox(height: 40),
          const Center(child: CupertinoActivityIndicator()),
        ],
      ),
    );
  }
}
