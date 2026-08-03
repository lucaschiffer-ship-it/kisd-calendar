import 'package:flutter/foundation.dart';

/// Visual state of the bottom bar's action (reload) slot.
enum ActionPhase { idle, busy, done }

/// Bridge between a page and the bottom bar's fixed action slot.
///
/// Owned by HomeScreen (one per page); each screen registers its action via
/// [handler] and mirrors its private busy/done state into [phase]. Mensa uses
/// [toggleActive] to reflect the translate toggle instead of a reload phase.
class PageActionController {
  final ValueNotifier<ActionPhase> phase = ValueNotifier(ActionPhase.idle);
  final ValueNotifier<bool> toggleActive = ValueNotifier(false);
  VoidCallback? handler;

  void trigger() {
    if (phase.value == ActionPhase.busy) return;
    handler?.call();
  }

  void dispose() {
    phase.dispose();
    toggleActive.dispose();
  }
}

/// Shares the pager's continuous position and each page's current header
/// height, so every header can pin itself on screen and morph between the
/// outgoing and incoming page's heights during a page switch.
///
/// Owned by HomeScreen; each screen gets a [PageHeaderHandle] alongside its
/// [PageActionController].
class HeaderPagerController {
  HeaderPagerController({required this.pagePos, this.pageCount = 4});

  /// HomeScreen's live pager position (page i centered at value i, mod count).
  final ValueListenable<double> pagePos;
  final int pageCount;

  /// Latest header height per page, written from each header's build.
  /// Plain doubles, never notified: writes happen during build, and every
  /// read already occurs inside a [pagePos]-driven rebuild.
  late final List<double> heights = List.filled(pageCount, 0.0);
}

/// One page's view onto the [HeaderPagerController].
class PageHeaderHandle {
  PageHeaderHandle(this.index, this.controller);

  final int index;
  final HeaderPagerController controller;

  void reportHeight(double h) => controller.heights[index] = h;
}
