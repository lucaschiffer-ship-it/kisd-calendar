import 'package:flutter/material.dart';

import '../services/page_actions.dart';

/// Side of a square floating button, and the height of every pill in the bottom
/// cluster — the nav pills, the Spaces mini bar's collapsed square, and the
/// page-specific floating buttons.
const double kFloatingButtonSize = 50.0;

/// Height of the home indicator's glyph zone, measured from the screen bottom.
///
/// The safe-area inset iOS reports (34) is generous padding for *content*; the
/// indicator itself only occupies roughly the bottom 13. The pills clear the
/// glyph rather than the whole inset, which is what puts them right down at the
/// bottom edge instead of floating well above it.
const double _kHomeIndicatorZone = 12.0;

/// Gap between the pills and the home indicator glyph.
///
/// Halfway between hugging the glyph (4) and the full safe-area inset iOS
/// suggests for content, which works out to 26 above the same zone.
const double _kBottomBreathingRoom = 15.0;

/// Breathing room between the pills and the bottom of the screen.
///
/// Tuning knob for how low the bottom cluster rides: raise
/// [_kBottomBreathingRoom] to lift the whole cluster (pills, Spaces mini bar and
/// the floating page buttons all follow).
///
/// Read from [View], not MediaQuery, for the same reason every screen computes
/// its status-bar height that way: Scaffold hands its body a MediaQuery with
/// the bottom padding stripped (because a bottomNavigationBar exists), so a
/// page asking MediaQuery gets 0 while HomeScreen — outside the Scaffold —
/// gets the real inset. The pills and the page buttons have to agree, and going
/// through View makes them agree by construction rather than by comment.
double bottomClusterInset(BuildContext context) {
  final view = View.of(context);
  final safeArea = view.viewPadding.bottom / view.devicePixelRatio;
  // No home indicator (older iPhones report 0) — just keep off the hard edge.
  if (safeArea <= 0) return 12.0;
  return _kHomeIndicatorZone + _kBottomBreathingRoom;
}

/// Total height the floating bottom cluster occupies, measured from the bottom
/// of the screen.
///
/// The single definition everything anchors to: the bottom bar's own padding,
/// the Spaces mini bar that stacks above it, and the floating page buttons. The
/// Scaffold runs with `extendBody: true`, so page content passes *behind* the
/// cluster and nothing in the layout reserves this space — which is exactly why
/// it has to be computed the same way everywhere.
double bottomClusterHeight(BuildContext context) =>
    kFloatingButtonSize + bottomClusterInset(context);

/// The page-specific floating buttons that sit above the bottom cluster, on the
/// right-hand side opposite the Spaces mini bar.
///
/// The mirror image of [MorphingGlassHeader]: it lives *inside* its page (so the
/// buttons keep direct access to page state — no bridge through
/// [PageActionController]) but counter-translates against the pager slot's
/// offset, so it stays pinned on screen while the page body slides underneath.
/// On top of that it always slides out to — and in from — the *right* edge,
/// whichever direction the swipe came from, driven continuously by the pager
/// position so the travel lasts exactly as long as the swipe.
///
/// The counter-translate paints outside the page's own bounds, which works for
/// the same reason it works in the header: a [Transform] is a paint-time offset,
/// so the page's Stack never sees visual overflow and never installs a clip.
/// What does clip is HomeScreen's body Stack — at the screen edge, which is
/// exactly where the fly-out should disappear.
///
/// Content cross-fades on the same staggered curve the header uses (gone by
/// |d| = 0.5). That is load-bearing, not decoration: Mail↔Mensa and
/// Mensa↔Calendar are adjacent pages that both own right-hand buttons, and the
/// outgoing and incoming column sit at the *same* offset at the swipe midpoint.
/// The fade guarantees both are invisible where they cross.
///
/// Returns a [Positioned], so it must be a direct child of a page's [Stack] —
/// and should be the last one, so it paints above the page's other layers.
class PageFloatingActions extends StatelessWidget {
  const PageFloatingActions({
    super.key,
    required this.handle,
    required this.children,
    this.axis = Axis.vertical,
  });

  final PageHeaderHandle handle;

  /// Anchored to the bottom-right corner of the cluster, so the **last** child
  /// always holds the corner and never moves when an earlier one appears or
  /// disappears. Vertically that means the last child takes the bottom slot
  /// level with the Spaces mini bar; horizontally it takes the rightmost slot.
  final List<Widget> children;

  /// How [children] are laid out relative to each other — stacked above one
  /// another, or in a row reading right-to-left from the corner.
  final Axis axis;

  /// How far the buttons travel off the right edge over a full page swipe.
  ///
  /// Tied to the cross-fade above: at |d| = 0.5 they have moved half of this,
  /// which clears the edge for a 50-wide button but not for something wide like
  /// a row of labelled pills — which is fine only because opacity is already 0
  /// there. Anyone who softens that fade has to raise this number too.
  static const double _kFlyDistance = 200.0;

  /// Matches the Spaces mini bar's `left: 12` and the bottom bar's `sidePad`.
  static const double _kSideInset = 12.0;

  /// Gap between the bottom child and the top of the bottom cluster — the same
  /// 8 the Spaces mini bar uses, so the two land on one line.
  ///
  /// `Scaffold.extendBody` is true, so the page body runs to the bottom of the
  /// screen and reserves nothing for the bar: the full cluster height has to be
  /// added here explicitly.
  static const double _kBottomGap = 8.0;

  /// Gap between adjacent buttons.
  static const double _kGap = 8.0;

  @override
  Widget build(BuildContext context) {
    final horizontal = axis == Axis.horizontal;
    final laidOut = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        laidOut.add(horizontal
            ? const SizedBox(width: _kGap)
            : const SizedBox(height: _kGap));
      }
      laidOut.add(children[i]);
    }

    return Positioned(
      right: _kSideInset,
      bottom: bottomClusterHeight(context) + _kBottomGap,
      child: ValueListenableBuilder<double>(
        valueListenable: handle.controller.pagePos,
        builder: (context, pos, child) {
          final n = handle.controller.pageCount;
          // Signed shortest circular distance, matching the pager's slot math.
          var d = (handle.index - pos) % n;
          if (d > n / 2) d -= n;
          final t = d.abs().clamp(0.0, 1.0).toDouble();
          final opacity = (1 - 2 * t).clamp(0.0, 1.0).toDouble();

          return Offstage(
            // Keeps the subtree's state (button press flags) alive.
            offstage: opacity <= 0,
            child: Transform.translate(
              // -d * width pins the column to the screen; the second term is
              // the fly-out, always towards the right edge.
              offset: Offset(
                -d * MediaQuery.sizeOf(context).width + t * _kFlyDistance,
                0,
              ),
              // Only the settled page's buttons are tappable — mid-swipe the
              // column is somewhere between here and off-screen.
              child: IgnorePointer(
                ignoring: t > 0.02,
                child: Opacity(opacity: opacity, child: child),
              ),
            ),
          );
        },
        child: horizontal
            ? Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: laidOut,
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: laidOut,
              ),
      ),
    );
  }
}
