import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/services/attachment_metadata.dart';
import 'package:kisd_calendar/services/compose_attachments.dart';

void main() {
  test('Defaults cover the user\'s own photos and videos, not Files', () {
    expect(kDefaultStripSources, {
      StripSource.libraryPhotos,
      StripSource.libraryVideos,
      StripSource.cameraPhotos,
    });
  });

  test('Library picks: photos and videos are separate rows', () {
    const source = AttachmentSource.photoLibrary;
    expect(stripSourceOf(source, 'image/jpeg'), StripSource.libraryPhotos);
    // Library PNGs carry GPS too (iPhone exports do).
    expect(stripSourceOf(source, 'image/png'), StripSource.libraryPhotos);
    expect(stripSourceOf(source, 'video/quicktime'), StripSource.libraryVideos);
  });

  test('Camera photos have their own row', () {
    expect(
      stripSourceOf(AttachmentSource.camera, 'image/jpeg'),
      StripSource.cameraPhotos,
    );
  });

  test('Files: images and videos are separate rows', () {
    const source = AttachmentSource.files;
    expect(stripSourceOf(source, 'image/heic'), StripSource.filesImages);
    expect(stripSourceOf(source, 'video/mp4'), StripSource.filesVideos);
  });

  test('Scans and documents have no row', () {
    expect(stripSourceOf(AttachmentSource.scanner, 'application/pdf'), isNull);
    for (final mime in [
      'application/pdf',
      'application/octet-stream',
      'audio/mpeg',
      'text/plain',
    ]) {
      expect(stripSourceOf(AttachmentSource.files, mime), isNull, reason: mime);
      expect(
        stripSourceOf(AttachmentSource.photoLibrary, mime),
        isNull,
        reason: mime,
      );
    }
  });
}
