// enough_mail's FETCH parser can't read a *partial* body section, so its
// internals have to be reached to repair it. Pinned to enough_mail 2.1.x.
// ignore_for_file: implementation_imports

import 'package:enough_mail/enough_mail.dart';
import 'package:enough_mail/src/private/imap/command.dart';
import 'package:enough_mail/src/private/imap/fetch_parser.dart';
import 'package:enough_mail/src/private/imap/imap_response.dart';
import 'package:enough_mail/src/private/imap/response_parser.dart';

/// An [ImapClient] whose FETCH results keep the list's preview bytes.
///
/// The list fetches `BODY.PEEK[TEXT]<0.500>` — the first 500 bytes of each
/// body — and the server answers `BODY[TEXT]<0> {500}`. enough_mail splits
/// that into `BODY[TEXT]`, `0>` and the literal, takes `0>` as the body and
/// drops the real bytes as an "unexpected element", so no list preview ever
/// had any text. This client swaps in a parser that puts the bytes back.
///
/// Nothing else changes: the same commands go out, every other response is
/// parsed by enough_mail as before.
class PreviewFixImapClient extends ImapClient {
  PreviewFixImapClient({super.isLogEnabled});

  @override
  Future<T> sendCommand<T>(
    Command command,
    ResponseParser<T> parser, {
    bool returnCompleter = true,
  }) {
    final fetch = parser is FetchParser ? parser as FetchParser : null;
    if (fetch != null && fetch is! _PartialTextFetchParser) {
      return super.sendCommand<T>(
        command,
        _PartialTextFetchParser(isUidFetch: fetch.isUidFetch)
            as ResponseParser<T>,
        returnCompleter: returnCompleter,
      );
    }
    return super.sendCommand<T>(
      command,
      parser,
      returnCompleter: returnCompleter,
    );
  }
}

class _PartialTextFetchParser extends FetchParser {
  _PartialTextFetchParser({required super.isUidFetch});

  // The tokenizer swallows the `<` after `]`, so `<0>` arrives as `0>`.
  static final _origin = RegExp(r'^<?\d+>$');

  @override
  bool parseUntagged(
    ImapResponse imapResponse,
    Response<FetchImapResult>? response,
  ) {
    final handled = super.parseUntagged(imapResponse, response);
    final message = lastParsedMessage;
    if (message == null) return handled;
    for (final value in imapResponse.iterate().values) {
      if (value.value != 'FETCH') continue;
      final children = value.children ?? const <ImapValue>[];
      for (var i = 0; i + 2 < children.length; i++) {
        if (children[i].value != 'BODY[TEXT]') continue;
        final origin = children[i + 1].value;
        final data = children[i + 2].data;
        if (origin != null && _origin.hasMatch(origin) && data != null) {
          message.mimeData = BinaryMimeData(data, containsHeader: false);
        }
      }
    }
    return handled;
  }
}
