import 'dart:ui';

import 'package:flutter/material.dart';

import '../config/app_theme.dart' as tokens;
import '../services/page_actions.dart';
import '../services/theme_service.dart';
import '../theme/tokens.dart';

/// Signed shortest circular distance from the pager position [pos] to page
/// [index], matching the pager's slot math: 0 = centred, ±1 = a full page off.
double headerSlotDistance(int index, double pos, int pageCount) {
  var d = (index - pos) % pageCount;
  if (d > pageCount / 2) d -= pageCount;
  return d;
}

/// The page a header at signed distance [d] is morphing with: the neighbour
/// on the side the pager position sits. Null at rest.
int? headerPartner(int index, double d, int pageCount) {
  if (d == 0) return null;
  return (d > 0 ? index - 1 : index + 1) % pageCount;
}

/// Where a shared header element draws, and how opaque.
///
/// [partnerTop] is the partner page's top for the same tag, or null when the
/// partner doesn't share it (or the element itself isn't shareable right now).
/// Held elements stay fully opaque and glide between the two tops — standing
/// still when the tops match. Progress is |d|, the same fraction the surface
/// height morphs by, so a header and its partner compute the identical top at
/// every position and the owner handoff at |d| = 0.5 is invisible. Unheld
/// elements fade with the rest of the content.
({double top, double opacity}) sharedElementPlacement({
  required double d,
  required double ownTop,
  required double? partnerTop,
}) {
  if (partnerTop == null) {
    return (top: ownTop, opacity: (1 - 2 * d.abs()).clamp(0.0, 1.0).toDouble());
  }
  return (top: lerpDouble(ownTop, partnerTop, d.abs())!, opacity: 1.0);
}

/// A header element that neighbouring pages may also show, in the same spot.
///
/// Laid out by [MorphingGlassHeader] above the page's own header content, at
/// [top] (from the header's top edge), [height] tall, inset [horizontalInset]
/// on both sides. The page leaves the matching gap in its content.
class HeaderSharedElement {
  const HeaderSharedElement({
    required this.tag,
    required this.top,
    required this.height,
    required this.child,
    this.horizontalInset = 0,
    this.shareable = true,
  });

  /// Pages with the same tag show pixel-identical elements under it.
  final String tag;
  final double top;
  final double height;
  final double horizontalInset;

  /// False while this copy wouldn't look identical to its partner's (a typed
  /// search query, a half-collapsed bar) — it then fades like the content.
  final bool shareable;

  final Widget child;
}

/// The shared glass header surface for pager pages.
///
/// Lives inside each page (so header content keeps its page-local state), but
/// counter-translates against the pager slot's offset so it stays pinned on
/// screen while the page bodies slide. During a page switch the surface height
/// interpolates between the outgoing and incoming page's current heights, and
/// the content does a staggered cross-fade: outgoing content is gone by the
/// halfway point, incoming content appears after it.
///
/// [shared] elements are the exception. One whose tag the neighbouring page
/// also offers stays fully visible through the switch and glides between the
/// two pages' positions — so it simply stays put when both pages place it in
/// the same spot (the date row on Mensa, Mail and List; the search bar between
/// Mail and List). Everything else morphs as before; at the midpoint only the
/// bare glass and the held elements are visible.
///
/// Exactly one page (the one nearest the pager position) paints its surface at
/// any time; the neighbour's content opacity is provably 0 at the handoff
/// point, and both surfaces — held elements included, see
/// [sharedElementPlacement] — are pixel-identical there, so the swap is
/// invisible. HomeScreen paints the owner's slot last so this surface blurs
/// both sliding bodies.
///
/// The element structure never changes between owner/non-owner or rest/
/// transition — only [Offstage.offstage] and plain values vary — so content
/// state (text fields, scroll positions, GlobalKeys) survives transitions.
class MorphingGlassHeader extends StatelessWidget {
  const MorphingGlassHeader({
    super.key,
    required this.handle,
    required this.height,
    required this.child,
    this.shared = const [],
  });

  final PageHeaderHandle handle;

  /// The page's current header height, computed live by the page. Content is
  /// laid out at its natural height and clipped at the morphing surface
  /// height.
  final double height;

  /// Header content only — no background, no blur.
  final Widget child;

  /// Elements that may be held in place across a page switch; see the class
  /// doc. Always pass the same list shape — toggle [HeaderSharedElement.shareable]
  /// rather than adding and removing entries, so their state survives.
  final List<HeaderSharedElement> shared;

  @override
  Widget build(BuildContext context) {
    // Plain writes, never notify — safe during build.
    handle.reportHeight(height);
    handle.reportShared({
      for (final e in shared)
        if (e.shareable) e.tag: e.top,
    });
    return ValueListenableBuilder<double>(
      valueListenable: handle.controller.pagePos,
      builder: (context, pos, _) {
        final n = handle.controller.pageCount;
        final d = headerSlotDistance(handle.index, pos, n);
        final owner = handle.index == pos.round() % n;
        // Staggered cross-fade: gone by |d| = 0.5, so at most one page's
        // content is ever visible (adjacent |d| values sum to 1).
        final opacity = (1 - 2 * d.abs()).clamp(0.0, 1.0).toDouble();
        final partner = headerPartner(handle.index, d, n);

        double surfaceH;
        if (d == 0) {
          surfaceH = height;
        } else {
          // Lerp between the two pages the position currently sits between;
          // floor/ceil mod n handles the circular wrap seam.
          final heights = handle.controller.heights;
          final iA = pos.floor() % n;
          final iB = (iA + 1) % n;
          surfaceH = lerpDouble(heights[iA], heights[iB], pos - pos.floorToDouble())!;
        }

        final glass = ThemeService.instance.glassEnabled.value;
        final tint = glass
            ? AppColorScheme.current.glassHeaderTint
            : tokens.AppThemeTokens.backgroundColor;

        // No bottom border: the blur's own edge is the boundary.
        //
        // Two boxes rather than one so the overhang can sit outside the content
        // clip and outside hit testing — see [AppGlass.headerOverhang].
        final surface = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: tint,
              child: SizedBox(
                height: surfaceH,
                width: double.infinity,
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    // No height: content keeps its natural height, top-aligned,
                    // clipped at surfaceH while the surface morphs.
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: Opacity(opacity: opacity, child: child),
                    ),
                    for (final e in shared) _buildShared(e, d, partner),
                  ],
                ),
              ),
            ),
            IgnorePointer(
              child: Container(color: tint, height: AppGlass.headerOverhang),
            ),
          ],
        );

        // One clip, one filter, and a hard bottom edge — no hairline, no fade.
        //
        // A fade below the header can't be built out of thinner blurred bands:
        // a BackdropFilter's input is bounded by its clip, so a 5px band sees
        // only its own 5px and degenerates into a flat smear of whatever sits
        // inside it. Stacked, those read as hard-edged rectangles, brighter
        // than the header above them.
        //
        // ClipRect sits inside the Transform so the blur samples the pinned
        // screen rect, not the sliding slot rect.
        final body = glass
            ? ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: AppGlass.headerBlur,
                    sigmaY: AppGlass.headerBlur,
                  ),
                  child: surface,
                ),
              )
            : surface;

        return Offstage(
          offstage: !owner,
          child: Transform.translate(
            offset: Offset(-d * MediaQuery.sizeOf(context).width, 0),
            child: body,
          ),
        );
      },
    );
  }

  // Same Positioned → Opacity shape whether held or not, so the element's
  // state survives a switch.
  Widget _buildShared(HeaderSharedElement e, double d, int? partner) {
    final partnerTop = partner == null || !e.shareable
        ? null
        : handle.controller.sharedTops[partner][e.tag];
    final p = sharedElementPlacement(d: d, ownTop: e.top, partnerTop: partnerTop);
    return Positioned(
      top: p.top,
      left: e.horizontalInset,
      right: e.horizontalInset,
      height: e.height,
      child: Opacity(opacity: p.opacity, child: e.child),
    );
  }
}
