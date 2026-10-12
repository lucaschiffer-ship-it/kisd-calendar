import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/mail_display.dart';
import '../theme/tokens.dart';
import 'mail_avatar.dart';

/// Text styles and colours for the mail list, built once per colour scheme.
///
/// `GoogleFonts.*` resolves a font variant on every call; inside a row build
/// that ran for every visible row on every mail update.
class MailListStyles {
  MailListStyles._(AppColorScheme s)
    : dark = s == AppColorScheme.dark,
      background = s.background,
      dot = s.accent,
      separator = s.textPrimary.withValues(alpha: 0.12),
      chevron = s.textTertiary,
      highlight = s.textPrimary.withValues(alpha: 0.08),
      sender = GoogleFonts.spaceGrotesk(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        height: 1.25,
        color: s.textPrimary,
      ),
      subject = GoogleFonts.inter(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 1.3,
        color: s.textPrimary,
      ),
      preview = GoogleFonts.inter(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 1.3,
        color: s.textSecondary,
      ),
      date = GoogleFonts.inter(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 1.25,
        color: s.textSecondary,
      );

  static final _cache = <AppColorScheme, MailListStyles>{};
  static MailListStyles of(AppColorScheme s) =>
      _cache[s] ??= MailListStyles._(s);

  final bool dark;
  final Color background;
  final Color dot;
  final Color separator;
  final Color chevron;
  final Color highlight;
  final TextStyle sender;
  final TextStyle subject;
  final TextStyle preview;
  final TextStyle date;
}

/// Row metrics, after Apple Mail's inbox (in points).
abstract final class MailRowMetrics {
  static const double padTop = 11;
  static const double padBottom = 12;
  static const double dotZone = 28; // left inset + unread-dot column
  static const double avatar = 44;
  static const double avatarGap = 12;
  static const double textStart = dotZone + avatar + avatarGap; // 84
  static const double padRight = 16;
}

/// One mail in the list: unread dot, soft avatar, sender + date, subject, and
/// a two-line preview. Always the same height, like Apple's, so a short
/// preview leaves its second line empty instead of shrinking the row.
class MailRow extends StatefulWidget {
  const MailRow({
    super.key,
    required this.data,
    this.preview,
    required this.unread,
    required this.styles,
    required this.onTap,
  });

  final MailRowData data;

  /// Overrides [data]'s preview — the offline copy's, when the list fetch's
  /// own window held no text.
  final String? preview;
  final bool unread;
  final MailListStyles styles;
  final VoidCallback onTap;

  @override
  State<MailRow> createState() => _MailRowState();
}

class _MailRowState extends State<MailRow> {
  bool _pressed = false;
  Timer? _release;

  @override
  void dispose() {
    _release?.cancel();
    super.dispose();
  }

  // onTapDown only fires once the tap has beaten the list's scroll and the
  // row's swipe in the gesture arena (or after kPressTimeout), so a scroll
  // never flashes the highlight — the same delay iOS uses.
  void _down(TapDownDetails _) {
    _release?.cancel();
    setState(() => _pressed = true);
  }

  void _up(TapUpDetails _) {
    widget.onTap();
    // Held through the start of the push, then faded.
    _release?.cancel();
    _release = Timer(const Duration(milliseconds: 260), () {
      if (mounted) setState(() => _pressed = false);
    });
  }

  void _cancel() {
    _release?.cancel();
    setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.styles;
    final d = widget.data;
    final scaler = MediaQuery.textScalerOf(context);
    double lines(TextStyle t, int n) =>
        scaler.scale(t.fontSize!) * t.height! * n;

    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(
            d.title,
            style: st.sender,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        if (d.hasAttachment) ...[
          Icon(CupertinoIcons.paperclip, size: 14, color: st.chevron),
          const SizedBox(width: 4),
        ],
        Text(listDateLabel(d.date), style: st.date, maxLines: 1),
        const SizedBox(width: 4),
        Icon(CupertinoIcons.chevron_forward, size: 14, color: st.chevron),
      ],
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _down,
      onTapUp: _up,
      onTapCancel: _cancel,
      child: AnimatedContainer(
        duration: Duration(milliseconds: _pressed ? 0 : 220),
        color: _pressed
            ? Color.alphaBlend(st.highlight, st.background)
            : st.background,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.only(
                top: MailRowMetrics.padTop,
                bottom: MailRowMetrics.padBottom,
                right: MailRowMetrics.padRight,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: MailRowMetrics.dotZone,
                    height: lines(st.sender, 1),
                    child: widget.unread
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: st.dot,
                                  shape: BoxShape.circle,
                                ),
                                child: const SizedBox.square(dimension: 9),
                              ),
                            ),
                          )
                        : null,
                  ),
                  MailAvatar(name: d.title, dark: st.dark),
                  const SizedBox(width: MailRowMetrics.avatarGap),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(height: lines(st.sender, 1), child: header),
                        const SizedBox(height: 1),
                        SizedBox(
                          height: lines(st.subject, 1),
                          child: Text(
                            d.subject,
                            style: st.subject,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        SizedBox(
                          height: lines(st.preview, 2),
                          child: Text(
                            widget.preview ?? d.preview,
                            style: st.preview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Hairline from the text column to the right inset, as Apple's.
            Positioned(
              left: MailRowMetrics.textStart,
              right: 0,
              bottom: 0,
              child: SizedBox(
                height: 0.5,
                child: ColoredBox(color: st.separator),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
