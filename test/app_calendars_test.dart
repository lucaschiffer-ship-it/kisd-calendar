import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/services/app_calendars.dart';

const icloud = CalendarSourceInfo(id: 'ic', title: 'iCloud', type: 'calDAV');
const gmail = CalendarSourceInfo(
  id: 'gm',
  title: 'luca@gmail.com',
  type: 'calDAV',
  isDefault: true,
);
const local = CalendarSourceInfo(id: 'lo', title: 'Default', type: 'local');
const subscribed = CalendarSourceInfo(
  id: 'su',
  title: 'Subscribed Calendars',
  type: 'subscribed',
);
const birthdays = CalendarSourceInfo(
  id: 'bd',
  title: 'Other',
  type: 'birthdays',
);

List<String> ids(List<CalendarSourceInfo> s) => [for (final x in s) x.id];

void main() {
  group('calendarSourceOrder', () {
    test('Gmail default on an iCloud phone: iCloud is tried after Gmail '
        '(5 Nov 2026: device_calendar only tried Gmail, which refuses)', () {
      expect(ids(calendarSourceOrder([icloud, gmail, subscribed, birthdays])), [
        'gm',
        'ic',
      ]);
    });

    test('default in iCloud: iCloud once, as before', () {
      const icloudDefault = CalendarSourceInfo(
        id: 'ic',
        title: 'iCloud',
        type: 'calDAV',
        isDefault: true,
      );
      expect(ids(calendarSourceOrder([gmail.copyNotDefault, icloudDefault])), [
        'ic',
      ]);
    });

    test('"On My iPhone" first when iOS offers it, as device_calendar did', () {
      expect(ids(calendarSourceOrder([icloud, gmail, local])), [
        'lo',
        'gm',
        'ic',
      ]);
    });

    test('an Exchange default is still tried before iCloud', () {
      const exchange = CalendarSourceInfo(
        id: 'ex',
        title: 'TH Köln',
        type: 'exchange',
        isDefault: true,
      );
      expect(ids(calendarSourceOrder([icloud, exchange])), ['ex', 'ic']);
    });

    test('never a read-only source, even as the default', () {
      const subscribedDefault = CalendarSourceInfo(
        id: 'su',
        title: 'Subscribed',
        type: 'subscribed',
        isDefault: true,
      );
      expect(ids(calendarSourceOrder([subscribedDefault, birthdays, icloud])), [
        'ic',
      ]);
    });

    test('no other account is ever added on its own', () {
      // A second Google account that isn't the default stays untouched.
      const other = CalendarSourceInfo(
        id: 'g2',
        title: 'work@gmail.com',
        type: 'calDAV',
      );
      expect(ids(calendarSourceOrder([other, gmail])), ['gm']);
      expect(calendarSourceOrder(const []), isEmpty);
    });
  });

  test('CalendarSourceInfo.fromMap reads the native listing', () {
    final s = CalendarSourceInfo.fromMap({
      'id': 'x',
      'title': 'iCloud',
      'type': 'calDAV',
      'isDefault': true,
    });
    expect(s.isICloud, isTrue);
    expect(s.isDefault, isTrue);
    final bare = CalendarSourceInfo.fromMap({'id': 'y'});
    expect(bare.type, 'unknown');
    expect(bare.isDefault, isFalse);
  });
}

extension on CalendarSourceInfo {
  CalendarSourceInfo get copyNotDefault =>
      CalendarSourceInfo(id: id, title: title, type: type);
}
