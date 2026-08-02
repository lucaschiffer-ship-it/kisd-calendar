import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_theme.dart';
import '../models/app_event.dart';
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
  void requestCreate(DateTime day, double dy) =>
      delegate?.requestCreate(day, dy);
}

abstract class EventEditLayerDelegate {
  void pickup(StoreOccurrence occ, Offset globalPos);
  void pickupMove(Offset globalPos);
  void pickupEnd();
  void pickupCancel();
  void requestCreate(DateTime day, double dy);
}

// ─── Layer ────────────────────────────────────────────────────────────────────

enum _Phase { idle, held, moving, resizingTop, resizingBottom, creating }

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

  // Create mode
  DateTime? _createStart, _createEnd;
  final _createTitleCtrl = TextEditingController();
  final _createFocus = FocusNode();

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
    _createTitleCtrl.dispose();
    _createFocus.dispose();
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
    if (_phase == _Phase.creating) _commitCreate();
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
      _lastGlobal = globalPos;
    });
    widget.controller.setActiveKey(occ.key);
    _log('drag start "${occ.event.title}" '
        '${occ.start.toIso8601String()} – ${_fmt(occ.end)}');
  }

  @override
  void pickupMove(Offset globalPos) {
    if (_editing == null) return;
    _lastGlobal = globalPos;
    if (_phase == _Phase.held) setState(() => _phase = _Phase.moving);
    _updateMoveFromGlobal();
    _updateAutoScroll();
  }

  @override
  void pickupEnd() {
    if (_editing == null) return;
    _ticker.stop();
    if (!_movedInGesture) {
      // Long-press released in place: stay in edit mode so the resize handles
      // are usable. Tap elsewhere exits.
      setState(() => _phase = _Phase.held);
      return;
    }
    _commitDrop();
  }

  @override
  void pickupCancel() {
    if (_editing == null) return;
    _ticker.stop();
    setState(() {
      _draftStart = _origStart;
      _draftEnd = _origEnd;
      _phase = _Phase.held;
    });
  }

  void _updateMoveFromGlobal() {
    final g = _lastGlobal;
    final editing = _editing;
    if (g == null || editing == null) return;
    final local = _toLocal(g);
    if (local == null) return;

    final durationMin = _draftEnd!.difference(_draftStart!).inMinutes;
    final day = widget.days[_dayIndexForX(local.dx)];
    final rawTopMin = (local.dy - _grabDy) / DayColumn.hourHeight * 60.0;
    final startMin =
        _snap15(rawTopMin).clamp(0, 24 * 60 - durationMin);

    final newStart = _dayAt(day, startMin);
    if (newStart != _draftStart) {
      setState(() {
        _draftStart = newStart;
        _draftEnd = newStart.add(Duration(minutes: durationMin));
        if (newStart != _origStart) _movedInGesture = true;
      });
    }
  }

  // ── Resize ──────────────────────────────────────────────────────────────────

  void _onResizeUpdate(bool top, Offset globalPos) {
    final local = _toLocal(globalPos);
    if (local == null || _draftStart == null || _draftEnd == null) return;
    _lastGlobal = globalPos;
    final min = _snap15(local.dy / DayColumn.hourHeight * 60.0);
    setState(() {
      if (top) {
        final endMin = _minutesOf(_draftEnd!);
        final clamped = min.clamp(0, endMin - _kMinDurationMin);
        _draftStart = _dayAt(_draftStart!, clamped);
      } else {
        final startMin = _minutesOf(_draftStart!);
        final clamped = min.clamp(startMin + _kMinDurationMin, 24 * 60);
        _draftEnd = _dayAt(_draftStart!, clamped);
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
      setState(() => _phase = _Phase.held);
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
      EventStore.instance.moveSingle(occ.event, newStart, newEnd);
      _exitEditMode();
      return;
    }

    setState(() => _phase = _Phase.held);
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
      _movedInGesture = false;
    });
    widget.controller.setActiveKey(null);
  }

  // ── Create ──────────────────────────────────────────────────────────────────

  @override
  void requestCreate(DateTime day, double dy) {
    if (_phase == _Phase.creating) {
      _commitCreate();
      return;
    }
    if (_editing != null) {
      _exitEditMode();
      return;
    }
    HapticFeedback.lightImpact();
    final startMin =
        _snap15(dy / DayColumn.hourHeight * 60.0).clamp(0, 24 * 60 - 60);
    setState(() {
      _phase = _Phase.creating;
      _createStart = _dayAt(day, startMin);
      _createEnd = _dayAt(day, startMin + 60);
      _createTitleCtrl.clear();
    });
    _log('create draft at ${_createStart!.toIso8601String()}');
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _createFocus.requestFocus());
  }

  void _commitCreate() {
    final title = _createTitleCtrl.text.trim();
    final start = _createStart;
    final end = _createEnd;
    setState(() {
      _phase = _Phase.idle;
      _createStart = _createEnd = null;
    });
    _createFocus.unfocus();
    if (title.isEmpty || start == null || end == null) return; // discard silently
    HapticFeedback.lightImpact();
    EventStore.instance.addManualEvent(title: title, start: start, end: end);
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
    if (_phase == _Phase.moving) {
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
              // Tap-away catcher: exits edit mode / commits or discards the
              // create draft. Tap-only so scrolling and day swipes pass through.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    if (_phase == _Phase.creating) {
                      _commitCreate();
                    } else if (_phase == _Phase.held) {
                      _exitEditMode();
                    }
                  },
                ),
              ),
            if (_editing != null && _draftStart != null) _buildDraftBlock(),
            if (_phase == _Phase.creating && _createStart != null)
              _buildCreateBlock(),
          ],
        ),
      ),
    );
  }

  Widget _buildDraftBlock() {
    final occ = _editing!;
    final color = occ.collection.color;
    final dayIdx = widget.days.indexWhere((d) =>
        d.year == _draftStart!.year &&
        d.month == _draftStart!.month &&
        d.day == _draftStart!.day);
    if (dayIdx < 0) return const SizedBox.shrink();

    final top = _minutesOf(_draftStart!) / 60.0 * DayColumn.hourHeight;
    final height = (_draftEnd!.difference(_draftStart!).inMinutes / 60.0 *
            DayColumn.hourHeight)
        .clamp(20.0, DayColumn.hourHeight * 24);
    final dragging = _phase == _Phase.moving ||
        _phase == _Phase.resizingTop ||
        _phase == _Phase.resizingBottom;

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
                    title: occ.event.title,
                    timeLabel: '${_fmt(_draftStart!)} – ${_fmt(_draftEnd!)}',
                  ),
                ),
              ),
              _buildHandle(top: true, color: color),
              _buildHandle(top: false, color: color),
            ],
          ),
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
    Widget? titleWidget,
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
                  titleWidget ??
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

  Widget _buildCreateBlock() {
    final dayIdx = widget.days.indexWhere((d) =>
        d.year == _createStart!.year &&
        d.month == _createStart!.month &&
        d.day == _createStart!.day);
    if (dayIdx < 0) return const SizedBox.shrink();
    const color = Color(0xFFEB5A01);

    final top = _minutesOf(_createStart!) / 60.0 * DayColumn.hourHeight;
    final height =
        _createEnd!.difference(_createStart!).inMinutes / 60.0 *
            DayColumn.hourHeight;

    return Positioned(
      left: widget.slotLefts[dayIdx] + 2,
      width: widget.slotWidth - 4,
      top: top,
      height: height,
      child: _blockChrome(
        color: color,
        title: '',
        timeLabel: '${_fmt(_createStart!)} – ${_fmt(_createEnd!)}',
        titleWidget: TextField(
          controller: _createTitleCtrl,
          focusNode: _createFocus,
          autofocus: true,
          maxLines: 1,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _commitCreate(),
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppThemeTokens.titleColor,
          ),
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.zero,
            hintText: 'New event',
            hintStyle: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppThemeTokens.secondaryTextColor,
            ),
          ),
        ),
      ),
    );
  }
}
