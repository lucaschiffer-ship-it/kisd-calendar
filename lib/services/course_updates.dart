import 'package:flutter/foundation.dart';

/// Broadcast for course-cache writes made from outside [ListScreen].
///
/// `ListScreen` owns the only in-memory `_shells` list and rewrites the *whole*
/// cache array whenever the user hearts, edits or deletes a course. Anything
/// else that writes the cache — today, attaching a link from the Spaces browser
/// — would therefore be silently clobbered by the next heart tap, because that
/// write rebuilds the array from a `_shells` that never learned about it.
///
/// Bumping this makes `ListScreen` reload from the cache. Only out-of-band
/// writers bump it; `ListScreen`'s own writes deliberately do not, so there is
/// no reload loop.
///
/// Mirrors `EventStore.instance.revision` and `CalendarService.writeRevision`.
class CourseUpdates {
  CourseUpdates._();

  static final CourseUpdates instance = CourseUpdates._();

  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  void bump() => revision.value++;
}
