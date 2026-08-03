import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_theme.dart';
import '../models/app_event.dart';
import '../screens/store_event_sheets.dart';
import '../services/event_store.dart';
import 'day_column.dart';

// ─── Controller ───────────────────────────────────────────────────────────────

/// Bridge between the DayColumns (where gestures originate) and the
/// [EventEditLayer] (which owns the drag geometry and renders the draft block).
class EventEditController extends ChangeNotifier {
  EventEditLayerDelegate? delegate;

  String? _activeKey;

  /// Key of the occurrence currently held by the edit layer — DayColumn hides
  /// this occurrence so only the draft block is visible.
  String? get activeKey => _activeKey;

  void setActiveKey(String? key) {
    if (_activeKey == key) return;
    _activeKey = key;
    notifyListeners();
  }

  void pickup(StoreOccurrence occ, Offset globalPos) =>
      delegate?.pickup(occ, globalPos);
  void pickupMove(Offset globalPos) => delegate?.pickupMove(globalPos);
  void pickupEnd() => delegate?.pickupEnd();
  void pickupCancel() => delegate?.pickupCancel();
  void requestCreate(DateTime day, Offset globalPos) =>
      delegate?.requestCreate(day, globalPos);
}

abstract class EventEditLayerDelegate {
  void pickup(StoreOccurrence occ, Offset globalPos);
  void pickupMove(Offset globalPos);
  void pickupEnd();
  void pickupCancel();
  void requestCreate(DateTime day, Offset globalPos);
}

// ─── Layer ────────────────────────────────────────────────────────────────────

enum _Phase { idle, held, moving, resizingTop, resizingBottom, createDragging }

/// Sits inside the timeline stack (same coordinate space as the five DayColumn
/// slots). Ignores pointers while idle so all existing gestures pass through.
class EventEditLayer extends StatefulWidget {
  const EventEditLayer({
    super.key,
    required this.controller,
    required this.days,
    required this.slotLefts,
    required this.slotWidth,
    required this.scrollController,
    required this.headerInset,
  });

  final EventEditController controller;
  final List<DateTime> days;
  final List<double> slotLefts;
  final double slotWidth;
  final ScrollController scrollController;

  /// Height of the pinned header chrome overlaying the top of the viewport —
  /// the auto-scroll top zone starts below it.
  final double headerInset;

  @override
  State<EventEditLayer> createState() => _EventEditLayerState();
}

class _EventEditLayerState extends State<EventEditLayer>
    with SingleTickerProviderStateMixin
    implements EventEditLayerDelegate {
  static const double _kAutoScrollZone = 60.0;
  static const double _kAutoScrollStep = 8.0;
  static const int _kMinDurationMin = 15;

  final _boxKey = GlobalKey();

  _Phase _phase = _Phase.idle;
  StoreOccurrence? _editing;
  DateTime? _draftStart, _draftEnd;
  DateTime? _origStart, _origEnd;
  double _grabDy = 0;
  Offset? _lastGlobal;
  bool _movedInGesture = false;

  // Continuous (unsnapped) pixel positions while a drag is live — the block
  // follows the finger fluidly, while _draftStart/_draftEnd hold the snapped
  // times used for the labels and the commit. Cleared on release so the block
  // settles onto the 15-min grid with a short animation.
  double? _liveTopPx;
  double? _liveEdgePx;

  /// True during the short post-release settle animation, so the handles
  /// don't flash before the draft is swapped for the real card.
  bool _settling = false;

  late final Ticker _ticker;

  static void _log(String msg) => debugPrint('[CAL] $msg');

  @override
  void initState() {
    super.initState();
    widget.controller.delegate = this;
    _ticker = createTicker(_onAutoScrollTick);
  }

  @override
  void didUpdateWidget(EventEditLayer old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      if (old.controller.delegate == this) old.controller.delegate = null;
      widget.controller.delegate = this;
    }
  }

  @override
  void dispose() {
    if (widget.controller.delegate == this) widget.controller.delegate = null;
    _ticker.dispose();
    super.dispose();
  }

  // ── Geometry helpers ────────────────────────────────────────────────────────

  Offset? _toLocal(Offset global) {
    final box = _boxKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.globalToLocal(global);
  }

  int _dayIndexForX(double dx) =>
      (((dx - widget.slotLefts[0]) / widget.slotWidth).floor())
          .clamp(0, widget.days.length - 1);

  static int _snap15(double minutes) => ((minutes / 15).round() * 15);

  static DateTime _dayAt(DateTime day, int minutes) =>
      DateTime(day.year, day.month, day.day, minutes ~/ 60, minutes % 60);

  static int _minutesOf(DateTime d) => d.hour * 60 + d.minute;

  static String _fmt(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  // ── Delegate: pickup / move / drop ──────────────────────────────────────────

  @override
  void pickup(StoreOccurrence occ, Offset globalPos) {
    if (_phase == _Phase.createDragging) return;
    final local = _toLocal(globalPos);
    if (local == null) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _phase = _Phase.held;
      _editing = occ;
      _draftStart = occ.start;
      _draftEnd = occ.end;
      _origStart = occ.start;
      _origEnd = occ.end;
      _grabDy = local.dy - _minutesOf(occ.start) / 60.0 * DayColumn.hourHeight;
      _movedInGesture = false;
      _settling = false;
      _lastGlobal = globalPos;
    });
    widget.controller.setActiveKey(occ.key);
    _log('drag start "${occ.event.title}" '
        '${occ.start.toIso8601String()} – ${_fmt(occ.end)}');
  }

  @override
  void pickupMove(Offset globalPos) {
    if (_editing == null && _phase != _Phase.createDragging) return;
    _lastGlobal = globalPos;
    if (_phase == _Phase.held) setState(() => _phase = _Phase.moving);
    _updateMoveFromGlobal();
    _updateAutoScroll();
  }

  @override
  void pickupEnd() {
    if (_phase == _Phase.createDragging) {
      _ticker.stop();
      _commitCreateDrop();
      return;
    }
    if (_editing == null) return;
    _ticker.stop();
    if (!_movedInGesture) {
      // Long-press released in place: stay in edit mode so the resize handles
      // are usable. Tap elsewhere exits.
      setState(() {
        _phase = _Phase.held;
        _liveTopPx = _liveEdgePx = null;
      });
      return;
    }
    _commitDrop();
  }

  @override
  void pickupCancel() {
    if (_phase == _Phase.createDragging) {
      // Gesture lost (arena / system interruption) — discard, no event.
      _ticker.stop();
      setState(() {
        _phase = _Phase.idle;
        _draftStart = _draftEnd = null;
        _liveTopPx = _liveEdgePx = null;
      });
      return;
    }
    if (_editing == null) return;
    _ticker.stop();
    setState(() {
      _draftStart = _origStart;
      _draftEnd = _origEnd;
      _phase = _Phase.held;
      _liveTopPx = _liveEdgePx = null;
    });
  }

  void _updateMoveFromGlobal() {
    final g = _lastGlobal;
    if (g == null || _draftStart == null) return;
    final local = _toLocal(g);
    if (local == null) return;

    final durationMin = _draftEnd!.difference(_draftStart!).inMinutes;
    final heightPx = durationMin / 60.0 * DayColumn.hourHeight;
    final day = widget.days[_dayIndexForX(local.dx)];
    final rawTopPx = (local.dy - _grabDy)
        .clamp(0.0, DayColumn.hourHeight * 24 - heightPx);
    final startMin = _snap15(rawTopPx / DayColumn.hourHeight * 60.0)
        .clamp(0, 24 * 60 - durationMin);

    final newStart = _dayAt(day, startMin);
    setState(() {
      _liveTopPx = rawTopPx;
      if (newStart != _draftStart) {
        // Tick per 15-min step, like Apple Calendar.
        HapticFeedback.selectionClick();
        _draftStart = newStart;
        _draftEnd = newStart.add(Duration(minutes: durationMin));
        if (_origStart != null && newStart != _origStart) {
          _movedInGesture = true;
        }
      }
    });
  }

  // ── Resize ──────────────────────────────────────────────────────────────────

  void _onResizeUpdate(bool top, Offset globalPos) {
    final local = _toLocal(globalPos);
    if (local == null || _draftStart == null || _draftEnd == null) return;
    _lastGlobal = globalPos;
    final minPx = _kMinDurationMin / 60.0 * DayColumn.hourHeight;
    final min = _snap15(local.dy / DayColumn.hourHeight * 60.0);
    setState(() {
      if (top) {
        final endMin = _minutesOf(_draftEnd!);
        final endPx = _minutesOf(_draftStart!) / 60.0 * DayColumn.hourHeight +
            _draftEnd!.difference(_draftStart!).inMinutes /
                60.0 *
                DayColumn.hourHeight;
        _liveEdgePx = local.dy.clamp(0.0, endPx - minPx);
        final snapped = _dayAt(_draftStart!,
            min.clamp(0, endMin - _kMinDurationMin));
        if (snapped != _draftStart) {
          HapticFeedback.selectionClick();
          _draftStart = snapped;
        }
      } else {
        final startMin = _minutesOf(_draftStart!);
        final startPx = startMin / 60.0 * DayColumn.hourHeight;
        _liveEdgePx =
            local.dy.clamp(startPx + minPx, DayColumn.hourHeight * 24);
        final snapped = _dayAt(_draftStart!,
            min.clamp(startMin + _kMinDurationMin, 24 * 60));
        if (snapped != _draftEnd) {
          HapticFeedback.selectionClick();
          _draftEnd = snapped;
        }
      }
      if (_draftStart != _origStart || _draftEnd != _origEnd) {
        _movedInGesture = true;
      }
    });
    _updateAutoScroll();
  }

  void _onResizeEnd() {
    _ticker.stop();
    if (_editing == null) return;
    if (_draftStart == _origStart && _draftEnd == _origEnd) {
      setState(() {
        _phase = _Phase.held;
        _liveTopPx = _liveEdgePx = null;
      });
      return;
    }
    _movedInGesture = true;
    _commitDrop();
  }

  // ── Drop / persist ──────────────────────────────────────────────────────────

  Future<void> _commitDrop() async {
    final occ = _editing!;
    final newStart = _draftStart!;
    final newEnd = _draftEnd!;
    HapticFeedback.lightImpact();
    _log('drag end "${occ.event.title}": '
        '${occ.start.toIso8601String()}–${_fmt(occ.end)} → '
        '${newStart.toIso8601String()}–${_fmt(newEnd)}');

    if (!occ.event.isRecurring) {
      // Let the block settle onto the snapped slot before it is swapped for
      // the real card.
      setState(() {
        _phase = _Phase.held;
        _settling = true;
        _liveTopPx = _liveEdgePx = null;
      });
      await Future.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      _settling = false;
      EventStore.instance.moveSingle(occ.event, newStart, newEnd);
      // Only exit if nothing else grabbed the layer during the settle.
      if (identical(_editing, occ)) _exitEditMode();
      return;
    }

    setState(() {
      _phase = _Phase.held;
      _liveTopPx = _liveEdgePx = null;
    });
    final choice = await showCupertinoModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text('“${occ.event.title}” repeats weekly'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'this'),
            child: const Text('This event only'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'future'),
            child: const Text('All future events'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(ctx, 'cancel'),
          child: const Text('Cancel'),
        ),
      ),
    );
    if (!mounted) return;
    _log('recurrence choice: ${choice ?? 'dismissed'}');

    switch (choice) {
      case 'this':
        EventStore.instance
            .overrideOccurrence(occ.event, occ.occurrenceDate, newStart, newEnd);
        _exitEditMode();
      case 'future':
        EventStore.instance
            .splitSeries(occ.event, occ.occurrenceDate, newStart, newEnd);
        _exitEditMode();
      default:
        // Animate back to the original slot, stay in edit mode.
        setState(() {
          _draftStart = _origStart;
          _draftEnd = _origEnd;
          _phase = _Phase.held;
          _movedInGesture = false;
        });
    }
  }

  void _exitEditMode() {
    _ticker.stop();
    setState(() {
      _phase = _Phase.idle;
      _editing = null;
      _draftStart = _draftEnd = _origStart = _origEnd = null;
      _liveTopPx = _liveEdgePx = null;
      _movedInGesture = false;
      _settling = false;
    });
    widget.controller.setActiveKey(null);
  }

  // ── Create ──────────────────────────────────────────────────────────────────

  @override
  void requestCreate(DateTime day, Offset globalPos) {
    if (_phase == _Phase.createDragging) return;
    if (_editing != null) {
      _exitEditMode();
      return;
    }
    final local = _toLocal(globalPos);
    if (local == null) return;
    HapticFeedback.mediumImpact();
    final startMin = _snap15(local.dy / DayColumn.hourHeight * 60.0)
        .clamp(0, 24 * 60 - 60);
    setState(() {
      _phase = _Phase.createDragging;
      _draftStart = _dayAt(day, startMin);
      _draftEnd = _dayAt(day, startMin + 60);
      _origStart = _origEnd = null;
      _grabDy = local.dy - startMin / 60.0 * DayColumn.hourHeight;
      _movedInGesture = false;
      _lastGlobal = globalPos;
    });
    _log('create draft at ${_draftStart!.toIso8601String()}');
  }

  Future<void> _commitCreateDrop() async {
    final start = _draftStart!;
    final end = _draftEnd!;
    HapticFeedback.lightImpact();
    _log('create drop ${start.toIso8601String()} – ${_fmt(end)}');
    // Settle onto the snapped slot before the real card + sheet appear.
    setState(() {
      _phase = _Phase.held;
      _liveTopPx = _liveEdgePx = null;
    });
    await Future.delayed(const Duration(milliseconds: 200));
    if (!mounted) return;
    final evt = EventStore.instance
        .addManualEvent(title: 'New Event', start: start, end: end);
    // Only clear the draft if nothing else grabbed the layer during the settle.
    if (_phase == _Phase.held && _editing == null) {
      setState(() {
        _phase = _Phase.idle;
        _draftStart = _draftEnd = null;
        _movedInGesture = false;
      });
    }
    final col = EventStore.instance.collectionById(evt.collectionId);
    if (col == null) return;
    await showStoreEventSheet(
      context,
      StoreOccurrence(
        event: evt,
        collection: col,
        occurrenceDate: DateTime(start.year, start.month, start.day),
        start: start,
        end: end,
      ),
      isNew: true,
    );
  }

  // ── Auto-scroll near viewport edges ────────────────────────────────────────

  void _updateAutoScroll() {
    final needed = _autoScrollDirection() != 0;
    if (needed && !_ticker.isActive) {
      _ticker.start();
    } else if (!needed && _ticker.isActive) {
      _ticker.stop();
    }
  }

  int _autoScrollDirection() {
    final g = _lastGlobal;
    if (g == null || !widget.scrollController.hasClients) return 0;
    final local = _toLocal(g);
    if (local == null) return 0;
    final pos = widget.scrollController.position;
    final viewportY = local.dy - pos.pixels;
    if (viewportY < widget.headerInset + _kAutoScrollZone) return -1;
    if (viewportY > pos.viewportDimension - _kAutoScrollZone) return 1;
    return 0;
  }

  void _onAutoScrollTick(Duration _) {
    if (_phase != _Phase.moving &&
        _phase != _Phase.createDragging &&
        _phase != _Phase.resizingTop &&
        _phase != _Phase.resizingBottom) {
      _ticker.stop();
      return;
    }
    final dir = _autoScrollDirection();
    if (dir == 0 || !widget.scrollController.hasClients) return;
    final pos = widget.scrollController.position;
    final target = (pos.pixels + dir * _kAutoScrollStep)
        .clamp(0.0, pos.maxScrollExtent);
    if (target == pos.pixels) return;
    widget.scrollController.jumpTo(target);
    // Content moved under the stationary finger — recompute the draft.
    if (_phase == _Phase.moving || _phase == _Phase.createDragging) {
      _updateMoveFromGlobal();
    } else if (_lastGlobal != null) {
      _onResizeUpdate(_phase == _Phase.resizingTop, _lastGlobal!);
    }
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final idle = _phase == _Phase.idle;
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: idle,
        child: Stack(
          key: _boxKey,
          clipBehavior: Clip.none,
          children: [
            if (!idle)
              // Tap-away catcher: exits edit mode. Tap-only so scrolling and
              // day swipes pass through.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    if (_phase == _Phase.held) _exitEditMode();
                  },
                ),
              ),
            if (_draftStart != null) _buildDraftBlock(),
          ],
        ),
      ),
    );
  }

  Widget _buildDraftBlock() {
    final occ = _editing;
    final color = occ?.collection.color ??
        EventStore.instance
            .collectionById(EventStore.kEventsCollectionId)
            ?.color ??
        const Color(0xFFEB5A01);
    final dayIdx = widget.days.indexWhere((d) =>
        d.year == _draftStart!.year &&
        d.month == _draftStart!.month &&
        d.day == _draftStart!.day);
    if (dayIdx < 0) return const SizedBox.shrink();

    final snapTop = _minutesOf(_draftStart!) / 60.0 * DayColumn.hourHeight;
    final snapHeight = (_draftEnd!.difference(_draftStart!).inMinutes / 60.0 *
            DayColumn.hourHeight)
        .clamp(20.0, DayColumn.hourHeight * 24);
    final dragging = _phase == _Phase.moving ||
        _phase == _Phase.createDragging ||
        _phase == _Phase.resizingTop ||
        _phase == _Phase.resizingBottom;

    // While a drag is live the block follows the finger continuously; the
    // snapped position is only rendered once the finger lifts (settle).
    double top = snapTop;
    double height = snapHeight;
    if ((_phase == _Phase.moving || _phase == _Phase.createDragging) &&
        _liveTopPx != null) {
      top = _liveTopPx!;
    } else if (_phase == _Phase.resizingTop && _liveEdgePx != null) {
      final bottomPx = snapTop + snapHeight;
      top = _liveEdgePx!;
      height = (bottomPx - top).clamp(12.0, DayColumn.hourHeight * 24);
    } else if (_phase == _Phase.resizingBottom && _liveEdgePx != null) {
      height = (_liveEdgePx! - snapTop).clamp(12.0, DayColumn.hourHeight * 24);
    }

    final showStartChip = _phase == _Phase.moving ||
        _phase == _Phase.createDragging ||
        _phase == _Phase.resizingTop;
    final showEndChip = _phase == _Phase.moving ||
        _phase == _Phase.createDragging ||
        _phase == _Phase.resizingBottom;
    final showHandles = occ != null &&
        !_settling &&
        (_phase == _Phase.held ||
            _phase == _Phase.resizingTop ||
            _phase == _Phase.resizingBottom);

    return AnimatedPositioned(
      duration: Duration(milliseconds: dragging ? 0 : 180),
      curve: Curves.easeOut,
      left: widget.slotLefts[dayIdx] + 2,
      width: widget.slotWidth - 4,
      top: top,
      height: height,
      child: Transform.scale(
        scale: 1.02,
        child: Opacity(
          opacity: 0.9,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Body: pan to move again while in edit mode.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (d) {
                    final local = _toLocal(d.globalPosition);
                    if (local == null) return;
                    setState(() {
                      _phase = _Phase.moving;
                      _grabDy = local.dy -
                          _minutesOf(_draftStart!) /
                              60.0 *
                              DayColumn.hourHeight;
                    });
                    _lastGlobal = d.globalPosition;
                  },
                  onPanUpdate: (d) => pickupMove(d.globalPosition),
                  onPanEnd: (_) => pickupEnd(),
                  child: _blockChrome(
                    color: color,
                    title: occ?.event.title ?? 'New Event',
                    timeLabel: '${_fmt(_draftStart!)} – ${_fmt(_draftEnd!)}',
                  ),
                ),
              ),
              if (showHandles) ...[
                _buildHandle(top: true, color: color),
                _buildHandle(top: false, color: color),
              ],
              // Live minute read-outs riding the block edges while dragging.
              if (showStartChip)
                Positioned(
                  top: -22,
                  left: 0,
                  child: _timeChip(_fmt(_draftStart!), color),
                ),
              if (showEndChip)
                Positioned(
                  bottom: -22,
                  right: 0,
                  child: _timeChip(_fmt(_draftEnd!), color),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _timeChip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 4),
        ],
      ),
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }

  /// 24 pt-tall invisible strip straddling the block edge, with a small
  /// visible grab pill in the middle.
  Widget _buildHandle({required bool top, required Color color}) {
    return Positioned(
      left: 0,
      right: 0,
      top: top ? -12 : null,
      bottom: top ? null : -12,
      height: 24,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: (d) {
          setState(() =>
              _phase = top ? _Phase.resizingTop : _Phase.resizingBottom);
          _lastGlobal = d.globalPosition;
        },
        onVerticalDragUpdate: (d) => _onResizeUpdate(top, d.globalPosition),
        onVerticalDragEnd: (_) => _onResizeEnd(),
        child: Center(
          child: Container(
            width: 28,
            height: 8,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: color, width: 2),
              boxShadow: const [
                BoxShadow(color: Color(0x33000000), blurRadius: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _blockChrome({
    required Color color,
    required String title,
    required String timeLabel,
  }) {
    final radius = BorderRadius.circular(AppThemeTokens.cardBorderRadius);
    return Container(
      decoration: BoxDecoration(
        color: Color.alphaBlend(
            color.withValues(alpha: 0.25), AppThemeTokens.backgroundColor),
        borderRadius: radius,
        border: Border.all(color: color, width: 1),
        boxShadow: const [
          BoxShadow(
            color: Color(0x40000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.hardEdge,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(width: 3, color: color),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppThemeTokens.titleColor,
                    ),
                  ),
                  Text(
                    timeLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      color: AppThemeTokens.secondaryTextColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
