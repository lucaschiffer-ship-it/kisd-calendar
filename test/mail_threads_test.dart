import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/services/mail_threads.dart';

ThreadCandidate _c(
  String key, {
  String? id,
  List<String> parents = const [],
  String subject = 'Projektwoche',
  String from = 'anna@th-koeln.de',
  Set<String> to = const {'luca@smail.th-koeln.de'},
  int day = 1,
}) => ThreadCandidate(
  key: key,
  messageId: id,
  parents: parents,
  subject: threadSubject(subject),
  replyPrefix: hasReplyPrefix(subject),
  from: from,
  addresses: {from, ...to},
  date: DateTime(2026, 10, day),
);

const _me = 'luca@smail.th-koeln.de';
const _anna = 'anna@th-koeln.de';

void main() {
  group('Message-IDs', () {
    test('are read from header values in order', () {
      expect(messageIdsIn('<a@x> <b@y>\r\n\t<c@z>'), [
        '<a@x>',
        '<b@y>',
        '<c@z>',
      ]);
      expect(messageIdsIn(null), isEmpty);
      expect(messageIdsIn('no ids here'), isEmpty);
    });

    test('a reply references the chain with the original last', () {
      final original = MimeMessage.parseFromText(
        'Message-ID: <3@x>\r\nIn-Reply-To: <2@x>\r\n'
        'References: <1@x> <2@x>\r\nSubject: Re: Hi\r\n\r\nbody',
      );
      expect(replyReferences(original), ['<1@x>', '<2@x>', '<3@x>']);
    });

    test('without References, In-Reply-To starts the chain', () {
      final original = MimeMessage.parseFromText(
        'Message-ID: <3@x>\r\nIn-Reply-To: <2@x>\r\nSubject: Re: Hi\r\n\r\nb',
      );
      expect(replyReferences(original), ['<2@x>', '<3@x>']);
    });

    test('a long chain keeps its root and the newest ids', () {
      final ids = [for (var i = 0; i < 20; i++) '<$i@x>'];
      final original = MimeMessage.parseFromText(
        'Message-ID: <own@x>\r\nReferences: ${ids.join(' ')}\r\n\r\nb',
      );
      final refs = replyReferences(original);
      expect(refs.length, 10);
      expect(refs.first, '<0@x>');
      expect(refs.last, '<own@x>');
    });

    test('reply headers survive rendering a plain text mail', () {
      final message = MessageBuilder.buildSimpleTextMessage(
        MailAddress(null, _me),
        [MailAddress(null, _anna)],
        'Danke!',
        subject: 'Re: Projektwoche',
      );
      final refs = [
        for (var i = 0; i < 8; i++) '<message-$i@mail.th-koeln.de>',
      ];
      applyReplyHeaders(message, inReplyTo: refs.last, references: refs);
      final parsed = MimeMessage.parseFromText(message.renderMessage());
      expect(messageIdsIn(parsed.getHeaderValue('in-reply-to')), [refs.last]);
      expect(messageIdsIn(parsed.getHeaderValue('references')), refs);
      expect(parsed.decodeTextPlainPart()?.trim(), 'Danke!');
    });

    test('no reply headers on a new mail', () {
      final message = MessageBuilder.buildSimpleTextMessage(
        MailAddress(null, _me),
        [MailAddress(null, _anna)],
        'Hallo',
        subject: 'Frage',
      );
      applyReplyHeaders(message, inReplyTo: null);
      expect(message.getHeaderValue('in-reply-to'), isNull);
      expect(message.getHeaderValue('references'), isNull);
    });
  });

  group('subjects', () {
    test('reply, forward and list prefixes are ignored', () {
      expect(threadSubject('AW: Re: [KISD] WG:  Projektwoche'), 'projektwoche');
      expect(threadSubject('Re[2]: Projektwoche'), 'projektwoche');
      expect(threadSubject(null), '');
      expect(hasReplyPrefix('AW: x'), isTrue);
      expect(hasReplyPrefix('[KISD] Re: x'), isTrue);
      expect(hasReplyPrefix('Read me'), isFalse);
      expect(hasForwardPrefix('WG: x'), isTrue);
      expect(hasForwardPrefix('Fwd: x'), isTrue);
      expect(hasForwardPrefix('Re: x'), isFalse);
    });

    test('the subject search uses its longest ASCII stretch', () {
      expect(
        subjectSearchText('AW: Prüfungsanmeldung Wintersemester'),
        'fungsanmeldung Wintersemester',
      );
      expect(subjectSearchText('Re: Hi'), isNull);
      expect(subjectSearchText(null), isNull);
    });

    test('search criteria chain ORs and quote their strings', () {
      final criteria = threadSearchCriteria(
        messageId: '<2@x>',
        parentIds: const ['<1@x>'],
        subjectText: 'Say "hi"',
      );
      expect(
        criteria,
        'OR HEADER Message-ID "<2@x>" '
        'OR HEADER Message-ID "<1@x>" '
        'OR HEADER References "<2@x>" '
        'OR HEADER References "<1@x>" '
        'OR HEADER In-Reply-To "<2@x>" '
        r'SUBJECT "Say \"hi\""',
      );
      expect(
        threadSearchCriteria(
          messageId: '<2@x>',
          parentIds: const [],
          subjectText: 'Projektwoche',
          headers: false,
        ),
        'SUBJECT "Projektwoche"',
      );
      expect(
        threadSearchCriteria(
          messageId: null,
          parentIds: const [],
          subjectText: null,
        ),
        isNull,
      );
    });
  });

  group('conversationOf', () {
    final root = _c('inbox:1', id: '<1@x>', day: 1);
    final myReply = _c(
      'sent:7',
      id: '<2@x>',
      parents: const ['<1@x>'],
      subject: 'Re: Projektwoche',
      from: _me,
      to: const {_anna},
      day: 2,
    );
    final answer = _c(
      'inbox:3',
      id: '<3@x>',
      parents: const ['<1@x>', '<2@x>'],
      subject: 'AW: Projektwoche',
      day: 3,
    );

    test('reply headers link ancestors and later replies, oldest first', () {
      expect(
        conversationOf(answer, [root, myReply, answer]).map((c) => c.key),
        ['inbox:1', 'sent:7', 'inbox:3'],
      );
      expect(conversationOf(root, [answer, myReply]).map((c) => c.key), [
        'inbox:1',
        'sent:7',
        'inbox:3',
      ]);
    });

    test('a reply sent without headers joins on subject and people', () {
      final headerless = _c(
        'sent:9',
        id: '<9@x>',
        subject: 'Re: Projektwoche',
        from: _me,
        to: const {_anna},
        day: 2,
      );
      expect(conversationOf(root, [headerless]).map((c) => c.key), [
        'inbox:1',
        'sent:9',
      ]);
    });

    test('the same subject from someone else stays apart', () {
      final other = _c(
        'inbox:5',
        id: '<5@x>',
        subject: 'Re: Projektwoche',
        from: 'bob@th-koeln.de',
        day: 2,
      );
      expect(conversationOf(root, [other]).map((c) => c.key), ['inbox:1']);
    });

    test('my reply to someone else on the same subject stays apart', () {
      final toCarl = _c(
        'sent:6',
        id: '<6@x>',
        subject: 'Re: Projektwoche',
        from: _me,
        to: const {'carl@th-koeln.de'},
        day: 2,
      );
      expect(conversationOf(root, [toCarl]).map((c) => c.key), ['inbox:1']);
    });

    test('an earlier exchange under the same subject stays apart', () {
      final saturday = _c(
        'inbox:0',
        id: '<0@x>',
        subject: 'Re: Projektwoche',
        from: _me,
        to: const {_anna},
        day: 1,
      );
      final original = _c('inbox:10', id: '<10@x>', day: 4);
      final reply = _c(
        'inbox:11',
        id: '<11@x>',
        parents: const ['<10@x>'],
        subject: 'AW: Projektwoche',
        day: 5,
      );
      expect(
        conversationOf(reply, [saturday, original]).map((c) => c.key),
        ['inbox:10', 'inbox:11'],
      );
    });

    test('the start of the conversation is found even when it joins late', () {
      // The real "Reply test": replies 1 and 3 sent from this app before it
      // set reply headers, 2 and 4 from Gmail, plus an earlier exchange
      // under the same subject three days before.
      const gmail = 'luca.schiffer@googlemail.com';
      final saturday = _c(
        'sent:16',
        id: '<16@x>',
        subject: 'Re: reply test',
        from: _me,
        to: const {gmail},
        day: 10,
      );
      final n1 = _c(
        'sent:21',
        id: '<21@x>',
        subject: 'Reply test',
        from: _me,
        to: const {gmail},
        day: 13,
      );
      final n2 = _c(
        'inbox:2338',
        id: '<2338@x>',
        parents: const ['<21@x>'],
        subject: 'Re: Reply test',
        from: gmail,
        to: const {_me},
        day: 13,
      );
      final n3 = _c(
        'sent:22',
        id: '<22@x>',
        subject: 'Re: Reply test',
        from: _me,
        to: const {gmail},
        day: 13,
      );
      final n4 = _c(
        'inbox:2339',
        id: '<2339@x>',
        parents: const ['<22@x>'],
        subject: 'Re: Reply test',
        from: gmail,
        to: const {_me},
        day: 13,
      );
      expect(
        conversationOf(n4, [n2, saturday, n1, n3]).map((c) => c.key).toSet(),
        {'sent:21', 'inbox:2338', 'sent:22', 'inbox:2339'},
      );
    });

    test('two separate mails with one subject stay apart', () {
      final again = _c('inbox:8', id: '<8@x>', day: 20);
      expect(conversationOf(root, [again]).map((c) => c.key), ['inbox:1']);
    });

    test('a reply in a different chain stays apart despite its subject', () {
      final elsewhere = _c(
        'inbox:4',
        id: '<4@x>',
        parents: const ['<other@x>'],
        subject: 'AW: Projektwoche',
        day: 4,
      );
      expect(
        conversationOf(answer, [root, myReply, elsewhere]).map((c) => c.key),
        ['inbox:1', 'sent:7', 'inbox:3'],
      );
    });

    test('a candidate is built from envelope and References', () {
      final m = MimeMessage.parseFromText(
        'Message-ID: <3@x>\r\nIn-Reply-To: <2@x>\r\n'
        'References: <1@x> <2@x>\r\nFrom: Anna <Anna@TH-Koeln.de>\r\n'
        'To: luca@smail.th-koeln.de\r\nCc: bob@th-koeln.de\r\n'
        'Subject: AW: Projektwoche\r\n'
        'Date: Tue, 13 Oct 2026 10:00:00 +0200\r\n\r\nbody',
      );
      final c = ThreadCandidate.of(m, 'inbox:3');
      expect(c.messageId, '<3@x>');
      expect(c.parents, ['<2@x>', '<1@x>']);
      expect(c.subject, 'projektwoche');
      expect(c.replyPrefix, isTrue);
      expect(c.from, 'anna@th-koeln.de');
      expect(c.addresses, {
        'anna@th-koeln.de',
        'luca@smail.th-koeln.de',
        'bob@th-koeln.de',
      });
    });
  });
}
