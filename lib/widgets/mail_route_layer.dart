import 'package:flutter/material.dart';

/// The navigator an opened mail is pushed on.
final GlobalKey<NavigatorState> mailNavigatorKey = GlobalKey<NavigatorState>(
  debugLabel: 'mail',
);

/// A route stack of its own for the mail page's screens, layered inside
/// HomeScreen **between the pages and the Spaces browser sheet**.
///
/// On the root navigator an opened mail covered HomeScreen's whole Stack —
/// the browser sheet included — so a link tapped in a mail opened the browser
/// *underneath* it, and the old screen had to pop itself first and re-push
/// on close. Here the browser always paints above an open mail, so the mail
/// simply stays where it is.
///
/// The base route is empty and the layer ignores pointers while it is the
/// only one, so taps fall straight through to the app below. Only the mail
/// page pushes here (explicitly, via [push]); Settings, course sheets and
/// every other route stay on the root navigator, unchanged.
class MailRouteLayer extends StatefulWidget {
  const MailRouteLayer({super.key});

  /// Animation of the route pushed directly over the empty base — what
  /// [MailRouteParallax] moves the page behind it with. Null while no mail
  /// is open (and once its pop animation has finished).
  static final ValueNotifier<Animation<double>?> routeAnimation =
      ValueNotifier<Animation<double>?>(null);

  static final ValueNotifier<int> _depth = ValueNotifier<int>(1);

  static Future<T?> push<T>(Route<T> route) =>
      mailNavigatorKey.currentState!.push(route);

  @override
  State<MailRouteLayer> createState() => _MailRouteLayerState();
}

class _MailRouteLayerState extends State<MailRouteLayer> {
  late final _observer = _LayerObserver();

  @override
  void initState() {
    super.initState();
    // The notifiers are static, and a previous HomeScreen (before a sign-out)
    // may have been torn down with a mail open, without any pop observed.
    // After the frame: resetting them mid-build would rebuild a sibling.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      MailRouteLayer._depth.value = 1;
      MailRouteLayer.routeAnimation.value = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: MailRouteLayer._depth,
      builder: (context, depth, child) =>
          IgnorePointer(ignoring: depth <= 1, child: child),
      child: Navigator(
        key: mailNavigatorKey,
        observers: [_observer],
        onGenerateInitialRoutes: (_, _) => [
          PageRouteBuilder<void>(
            opaque: false,
            pageBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _LayerObserver extends NavigatorObserver {
  void _track(Route<dynamic> route) {
    if (route is! ModalRoute) return;
    final animation = route.animation;
    if (animation == null) return;
    MailRouteLayer.routeAnimation.value = animation;
    void listener(AnimationStatus status) {
      if (status == AnimationStatus.dismissed) {
        animation.removeStatusListener(listener);
        if (MailRouteLayer.routeAnimation.value == animation) {
          MailRouteLayer.routeAnimation.value = null;
        }
      }
    }

    animation.addStatusListener(listener);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute == null) return; // the base route itself
    MailRouteLayer._depth.value++;
    if (previousRoute.isFirst) _track(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    MailRouteLayer._depth.value--;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    MailRouteLayer._depth.value--;
  }
}

/// Moves the page behind an opening mail the way iOS moves the page behind a
/// push: a third of the way left, slightly dimmed, tracking the back-swipe 1:1.
///
/// The child's structure never changes with the animation (the dim is only
/// appended), so HomeScreen's pages keep their state. While a mail fully
/// covers it, tickers below are paused.
class MailRouteParallax extends StatelessWidget {
  const MailRouteParallax({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Animation<double>?>(
      valueListenable: MailRouteLayer.routeAnimation,
      builder: (context, animation, child) => AnimatedBuilder(
        animation: animation ?? kAlwaysDismissedAnimation,
        child: child,
        builder: (context, child) {
          final raw = animation?.value ?? 0.0;
          final gesture =
              mailNavigatorKey.currentState?.userGestureInProgress ?? false;
          // The same curves CupertinoPageRoute gives the route below a push.
          final t = gesture || animation == null
              ? raw
              : (animation.status == AnimationStatus.reverse
                        ? Curves.easeInToLinear
                        : Curves.linearToEaseOut)
                    .transform(raw);
          final covering = animation?.status == AnimationStatus.completed;
          final width = MediaQuery.sizeOf(context).width;
          return TickerMode(
            enabled: !covering,
            child: Transform.translate(
              offset: Offset(-width / 3 * t, 0),
              child: Stack(
                children: [
                  child!,
                  if (t > 0)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ColoredBox(
                          color: Colors.black.withValues(alpha: 0.12 * t),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
      child: child,
    );
  }
}
