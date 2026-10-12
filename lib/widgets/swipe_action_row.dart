import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

/// One side's action of a [SwipeActionRow].
class SwipeAction {
  const SwipeAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTriggered,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTriggered;

  /// The row leaves the list: it slides out and collapses, and only *then*
  /// does [onTriggered] run — so the list removing it causes no jump.
  final bool destructive;
}

/// Keeps at most one [SwipeActionRow] open, and closes it on demand (the list
/// calls [closeAll] when a scroll starts).
class SwipeGroup {
  _SwipeActionRowState? _open;

  void closeAll() {
    _open?._close();
    _open = null;
  }

  void _opened(_SwipeActionRowState row) {
    if (_open != row) _open?._close();
    _open = row;
  }

  void _closed(_SwipeActionRowState row) {
    if (_open == row) _open = null;
  }
}

/// iOS Mail's swipe: a short swipe snaps open and rests on the action button;
/// a long one — past [commitFraction] of the width, marked by a haptic tick —
/// performs the action on release. A fast fling performs it too.
///
/// The content only ever moves by a paint-time translate, and the action
/// background exists only while the row is displaced, so a resting row costs
/// nothing extra.
class SwipeActionRow extends StatefulWidget {
  const SwipeActionRow({
    super.key,
    required this.group,
    required this.child,
    this.leading,
    this.trailing,
  });

  final SwipeGroup group;
  final Widget child;

  /// Revealed by swiping right.
  final SwipeAction? leading;

  /// Revealed by swiping left.
  final SwipeAction? trailing;

  /// Width of the revealed button when the row rests open.
  static const double revealWidth = 80;
  static const double commitFraction = 0.55;

  @override
  State<SwipeActionRow> createState() => _SwipeActionRowState();
}

class _SwipeActionRowState extends State<SwipeActionRow>
    with TickerProviderStateMixin {
  late final AnimationController _offset = AnimationController.unbounded(
    vsync: this,
  );
  late final AnimationController _collapse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );
  late final AnimationController _bump = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  double _width = 0;
  bool _armed = false;
  bool _committing = false;

  static final _snap = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 520,
    ratio: 0.86,
  );
  static final _settle = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 520,
    ratio: 1.0,
  );

  bool get _isOpen => _offset.value.abs() > 0.5;

  // Built once: the background rebuilds every frame of a swipe.
  static final _labelStyle = GoogleFonts.inter(
    color: Colors.white, // on the action colour
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
  );

  @override
  void dispose() {
    widget.group._closed(this);
    _offset.dispose();
    _collapse.dispose();
    _bump.dispose();
    super.dispose();
  }

  double get _commitDistance => _width * SwipeActionRow.commitFraction;

  SwipeAction? _actionFor(double dx) =>
      dx > 0 ? widget.leading : (dx < 0 ? widget.trailing : null);

  void _onDragStart(DragStartDetails _) {
    if (_committing) return;
    widget.group._opened(this);
    _offset.stop();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_committing) return;
    var next = _offset.value + d.delta.dx;
    if (next > 0 && widget.leading == null) next = 0;
    if (next < 0 && widget.trailing == null) next = 0;
    // Past the full width the row resists instead of leaving the screen.
    final limit = _width * 0.94;
    if (next.abs() > limit) {
      final over = next.abs() - limit;
      next = next.sign * (limit + over * 0.2);
    }
    _offset.value = next;
    final armed = next.abs() >= _commitDistance;
    if (armed != _armed) {
      _armed = armed;
      if (armed) {
        HapticFeedback.mediumImpact();
        _bump.forward(from: 0);
      } else {
        HapticFeedback.selectionClick();
      }
    }
  }

  void _onDragEnd(DragEndDetails d) {
    if (_committing) return;
    final dx = _offset.value;
    final v = d.primaryVelocity ?? 0;
    final action = _actionFor(dx);
    if (action == null) {
      _animateTo(0, v, _settle);
      return;
    }
    final towards = v.sign == dx.sign;
    final fling =
        towards && v.abs() > 2000 && dx.abs() > SwipeActionRow.revealWidth;
    if (_armed || fling) {
      _commit(action, dx.sign, v);
    } else if ((dx.abs() > SwipeActionRow.revealWidth / 2 &&
            !(v.abs() > 300 && !towards)) ||
        (towards && v.abs() > 300)) {
      _animateTo(dx.sign * SwipeActionRow.revealWidth, v, _snap);
    } else {
      _animateTo(0, v, _settle);
    }
    _armed = false;
  }

  void _animateTo(double target, double velocity, SpringDescription spring) {
    if (target == 0) widget.group._closed(this);
    _offset.animateWith(
      SpringSimulation(spring, _offset.value, target, velocity),
    );
  }

  void _close() {
    if (!mounted || _committing) return;
    _animateTo(0, 0, _settle);
  }

  Future<void> _commit(SwipeAction action, double side, double velocity) async {
    _committing = true;
    widget.group._closed(this);
    if (action.destructive) {
      await _offset.animateTo(
        side * _width,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
      if (!mounted) return;
      await _collapse.forward();
      if (!mounted) return;
      action.onTriggered();
    } else {
      action.onTriggered();
      HapticFeedback.lightImpact();
      await _offset.animateWith(
        SpringSimulation(_settle, _offset.value, 0, velocity),
      );
      if (mounted) _committing = false;
    }
  }

  void _tapAction(SwipeAction action) {
    HapticFeedback.mediumImpact();
    _commit(action, _offset.value.sign, 0);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _width = constraints.maxWidth;
        final content = RepaintBoundary(child: widget.child);
        return SizeTransition(
          sizeFactor: ReverseAnimation(
            CurvedAnimation(parent: _collapse, curve: Curves.easeInOutCubic),
          ),
          axisAlignment: -1,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: _onDragStart,
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            child: AnimatedBuilder(
              animation: _offset,
              child: content,
              builder: (context, child) {
                final dx = _offset.value;
                final action = _actionFor(dx);
                return Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    if (action != null)
                      Positioned.fill(child: _buildBackground(action, dx)),
                    Transform.translate(
                      offset: Offset(dx, 0),
                      // While open, a tap on the content just closes the
                      // row. The structure stays the same either way, so the
                      // content is never re-parented mid-swipe.
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _isOpen ? _close : null,
                        child: AbsorbPointer(absorbing: _isOpen, child: child),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildBackground(SwipeAction action, double dx) {
    final extent = dx.abs();
    final leading = dx > 0;
    const reveal = SwipeActionRow.revealWidth;
    // The button sits in the outermost `reveal` px until the row has moved
    // that far, then rides along with the content's edge.
    final center = extent <= reveal ? reveal / 2 : extent - reveal / 2;
    final opacity = ((extent - 12) / (reveal * 0.6)).clamp(0.0, 1.0);

    final button = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _tapAction(action),
      child: SizedBox(
        width: reveal,
        child: Opacity(
          opacity: opacity,
          child: AnimatedBuilder(
            animation: _bump,
            builder: (context, child) => Transform.scale(
              scale:
                  1 +
                  0.14 *
                      Curves.easeOut.transform(
                        _bump.value < 0.5
                            ? _bump.value * 2
                            : (1 - _bump.value) * 2,
                      ),
              child: child,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(action.icon, color: Colors.white, size: 22),
                const SizedBox(height: 4),
                Text(action.label, maxLines: 1, style: _labelStyle),
              ],
            ),
          ),
        ),
      ),
    );

    return ColoredBox(
      color: action.color,
      child: Stack(
        children: [
          Positioned(
            top: 0,
            bottom: 0,
            left: leading ? center - reveal / 2 : null,
            right: leading ? null : center - reveal / 2,
            child: button,
          ),
        ],
      ),
    );
  }
}
