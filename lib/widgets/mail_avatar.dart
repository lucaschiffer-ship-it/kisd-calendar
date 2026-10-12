import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/mail_display.dart' show avatarInitial;
import '../theme/tokens.dart';

/// A sender's soft avatar colours: a muted tint of their palette colour behind
/// an initial in the full colour. Shared by the list rows and the message
/// header (which renders it in HTML), so both read the same.
class MailAvatarColors {
  const MailAvatarColors(this.background, this.foreground);

  final Color background;
  final Color foreground;

  static final _cache = <(String, bool), MailAvatarColors>{};

  static MailAvatarColors of(String name, {required bool dark}) =>
      _cache[(name, dark)] ??= _compute(name, dark);

  static MailAvatarColors _compute(String name, bool dark) {
    final base = AppAvatarPalette.forName(name);
    final surface = dark ? Colors.black : Colors.white;
    return dark
        ? MailAvatarColors(
            Color.alphaBlend(base.withValues(alpha: 0.24), surface),
            // Lifted so the darker palette colours (indigo, navy) still read
            // on the tint against black.
            Color.lerp(base, Colors.white, 0.38)!,
          )
        : MailAvatarColors(
            Color.alphaBlend(base.withValues(alpha: 0.15), surface),
            Color.lerp(base, Colors.black, 0.08)!,
          );
  }
}

class MailAvatar extends StatelessWidget {
  const MailAvatar({
    super.key,
    required this.name,
    required this.dark,
    this.size = 44,
  });

  final String name;
  final bool dark;
  final double size;

  // Built once per size — rows rebuild on every mail update.
  static final _styles = <double, TextStyle>{};
  static TextStyle _initialStyle(double size) =>
      _styles[size] ??= GoogleFonts.spaceGrotesk(
        fontSize: size * 0.43,
        fontWeight: FontWeight.w600,
        height: 1,
      );

  @override
  Widget build(BuildContext context) {
    final colors = MailAvatarColors.of(name, dark: dark);
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.background,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Text(
            avatarInitial(name),
            style: _initialStyle(size).copyWith(color: colors.foreground),
          ),
        ),
      ),
    );
  }
}
