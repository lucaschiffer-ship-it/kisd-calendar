import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

// ─── Pinch maths ──────────────────────────────────────────────────────────────
//
// Pure, so test/timeline_zoom_test.dart can pin them without a widget tree.
// Coordinates: `focalY` is in the scroll viewport, `contentTop` is the scroll
// padding above 00:00, minutes count from the start of the day.

/// Finger spreads below this are treated as this. Flutter's own verticalScale
/// divides by the starting vertical spread, which is ~0 when the fingers land
/// side by side — the first millimetre of movement then reads as a 10× zoom.
const double kPinchSpanFloor = 48.0;

/// Zoom factor between two vertical finger spreads.
double pinchScale(double startSpan, double span) =>
    math.max(span, kPinchSpanFloor) / math.max(startSpan, kPinchSpanFloor);

/// The minute of the day at viewport y [focalY] (may lie outside 0–1440 when
/// the fingers are in the padding above 00:00 or below 24:00).
double minuteAt({
  required double offset,
  required double focalY,
  required double contentTop,
  required double hourHeight,
}) => (offset + focalY - contentTop) / hourHeight * 60.0;

/// Largest scroll offset for a timeline of [hourHeight].
double timelineMaxOffset({
  required double hourHeight,
  required double contentTop,
  required double contentBottom,
  required double viewport,
}) => math.max(0.0, contentTop + 24 * hourHeight + contentBottom - viewport);

/// The scroll offset that keeps [anchorMinutes] at viewport y [focalY].
double anchoredOffset({
  required double anchorMinutes,
  required double hourHeight,
  required double focalY,
  required double contentTop,
  required double maxOffset,
}) => (contentTop + anchorMinutes / 60.0 * hourHeight - focalY).clamp(
  0.0,
  math.max(0.0, maxOffset),
);

// ─── Widget ───────────────────────────────────────────────────────────────────

/// Vertical pinch-to-zoom for the day timeline, wrapped around its scroll view.
///
/// The minute under the fingers stays under the fingers: each frame writes the
/// new [hourHeight] and the matching scroll offset together, so content and
/// offset never disagree for a frame. The hour height hard-stops at
/// [minHourHeight] / [maxHourHeight], like Apple Calendar.
class TimelineZoom extends StatefulWidget {
  const TimelineZoom({
    super.key,
    required this.hourHeight,
    required this.controller,
    required this.contentTop,
    required this.contentBottom,
    required this.minHourHeight,
    required this.maxHourHeight,
    this.canStart,
    this.onZoomEnd,
    required this.child,
  });

  final ValueNotifier<double> hourHeight;

  /// The wrapped scroll view's controller. Its viewport must start at this
  /// widget's top edge.
  final ScrollController controller;

  /// Scroll padding above 00:00 and below 24:00.
  final double contentTop;
  final double contentBottom;

  final double minHourHeight;
  final double maxHourHeight;

  /// Asked when a pinch starts; false ignores the whole gesture.
  final bool Function()? canStart;

  /// The hour height a pinch settled on, once all fingers are up.
  final ValueChanged<double>? onZoomEnd;

  final Widget child;

  @override
  State<TimelineZoom> createState() => _TimelineZoomState();
}

class _TimelineZoomState extends State<TimelineZoom> {
  // Each finger's y in this widget's box, for the vertical spread and the
  // focal point. The Listener sees every event before the recognizer's
  // callbacks run, so the two always agree.
  final _pointerY = <int, double>{};

  bool _pinching = false;
  bool _oneFinger = false;
  double _startHourHeight = 0;
  double _baseHourHeight = 0;
  double _startSpan = 0;
  double _anchorMinutes = 0;

  double get _span {
    if (_pointerY.length < 2) return 0;
    final ys = _pointerY.values;
    return ys.reduce(math.max) - ys.reduce(math.min);
  }

  void _track(PointerEvent e) => _pointerY[e.pointer] = e.localPosition.dy;

  void _untrack(PointerEvent e) {
    _pointerY.remove(e.pointer);
    // The recognizer only reports the end of a gesture that moved since its
    // last finger change, so two fingers lifting without moving in between
    // never reach _onEnd. Finish here, after the recognizer has had its turn
    // at this event (it may still end the gesture itself, with a velocity).
    if (_pointerY.isEmpty && _pinching) {
      scheduleMicrotask(() {
        if (_pinching) _finish(Velocity.zero);
      });
    }
  }

  /// Pins the minute at viewport y [focalY] under the fingers, and measures
  /// the zoom from the hour height and finger spread as they are now.
  void _anchorAt(double focalY) {
    _baseHourHeight = widget.hourHeight.value;
    _startSpan = _span;
    _anchorMinutes = minuteAt(
      offset: widget.controller.offset,
      focalY: focalY,
      contentTop: widget.contentTop,
      hourHeight: _baseHourHeight,
    );
  }

  void _onStart(ScaleStartDetails d) {
    // Mid-pinch restarts (after a finger change) were re-anchored in _onEnd,
    // where the fingers hadn't moved yet; this one already has.
    if (_pinching) return;
    if (d.pointerCount < 2 || !widget.controller.hasClients) return;
    if (!(widget.canStart?.call() ?? true)) return;
    _pinching = true;
    _startHourHeight = widget.hourHeight.value;
    _anchorAt(d.localFocalPoint.dy);
  }

  void _onUpdate(ScaleUpdateDetails d) {
    if (!_pinching || !widget.controller.hasClients) return;
    final scale = pinchScale(_startSpan, _span);
    final raw = _baseHourHeight * scale;
    final h = raw.clamp(widget.minHourHeight, widget.maxHourHeight);
    // At a limit, rebase so pinching back responds at once instead of first
    // crossing back over the distance spread past the limit.
    if (h != raw) _baseHourHeight = h / scale;
    _oneFinger = d.pointerCount < 2;

    final pos = widget.controller.position;
    final offset = anchoredOffset(
      anchorMinutes: _anchorMinutes,
      hourHeight: h,
      focalY: d.localFocalPoint.dy,
      contentTop: widget.contentTop,
      maxOffset: timelineMaxOffset(
        hourHeight: h,
        contentTop: widget.contentTop,
        contentBottom: widget.contentBottom,
        viewport: pos.viewportDimension,
      ),
    );
    widget.hourHeight.value = h;
    if (offset != pos.pixels) widget.controller.jumpTo(offset);
  }

  void _onEnd(ScaleEndDetails d) {
    if (!_pinching) return;
    if (d.pointerCount > 0) {
      // A finger lifted or landed: the recognizer restarts once the fingers
      // move. Re-anchor now, so that first move isn't lost.
      final ys = _pointerY.values;
      if (ys.isNotEmpty) _anchorAt(ys.reduce((a, b) => a + b) / ys.length);
      _oneFinger = d.pointerCount < 2;
      return;
    }
    _finish(d.velocity);
  }

  void _finish(Velocity velocity) {
    _pinching = false;
    final pos = widget.controller.hasClients
        ? widget.controller.position
        : null;
    // Let a one-finger pan that ends the gesture fling like a normal scroll.
    final vy = velocity.pixelsPerSecond.dy;
    if (_oneFinger && vy != 0 && pos is ScrollPositionWithSingleContext) {
      pos.goBallistic(-vy);
    }
    if (widget.hourHeight.value != _startHourHeight) {
      widget.onZoomEnd?.call(widget.hourHeight.value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _track,
      onPointerMove: _track,
      onPointerUp: _untrack,
      onPointerCancel: _untrack,
      child: RawGestureDetector(
        gestures: {
          _TwoFingerScaleGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                _TwoFingerScaleGestureRecognizer
              >(
                () => _TwoFingerScaleGestureRecognizer(debugOwner: this),
                (g) => g
                  ..onStart = _onStart
                  ..onUpdate = _onUpdate
                  ..onEnd = _onEnd,
              ),
        },
        child: widget.child,
      ),
    );
  }
}

/// A scale recognizer that wins the arena the moment a second finger lands.
///
/// Stock scale only wins once the fingers have moved, so two fingers resting
/// on the board lost to the 400 ms long-press that creates or picks up an
/// event. One finger still loses to the scroll view's drag (18 pt slop vs the
/// scale's 36 pt pan slop), so scrolling and day swipes are untouched. A finger
/// added to a scroll or a pickup already in progress arrives alone (the first
/// pointer is someone else's) and never reaches two.
class _TwoFingerScaleGestureRecognizer extends ScaleGestureRecognizer {
  _TwoFingerScaleGestureRecognizer({super.debugOwner})
    : super(dragStartBehavior: DragStartBehavior.start);

  @override
  void handleEvent(PointerEvent event) {
    super.handleEvent(event);
    // After super, so the new pointer is counted and onStart sees both.
    if (event is PointerDownEvent && pointerCount >= 2) {
      resolve(GestureDisposition.accepted);
    }
  }
}
