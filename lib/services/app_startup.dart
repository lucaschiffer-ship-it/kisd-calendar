import 'account_teardown.dart';
import 'course_reminder_scheduler.dart';
import 'mail_notifier.dart';
import 'service_locator.dart';
import 'theme_service.dart';

/// What a launch reads back from storage before the first frame. Sign-out
/// runs it again right after wiping the device, so every setting is back at
/// its default — the app is in its just-installed state without a restart.
Future<void> loadStoredState() async {
  await ThemeService.instance.init();
  await CourseReminderScheduler.loadPrefs();
  await MailNotifier.loadPrefs();
  await loginService.initialize();
  await AccountTeardown.adoptExistingOwner();
}
