import 'dart:io';
import 'dart:math' show Random;

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'attachment_metadata.dart';
import 'mail_attachments.dart';
import 'theme_service.dart';

/// Compose's attachments: the files on disk, and the native pickers, camera,
/// scanner and Quick Look behind them (`ios/Runner/ComposeAttachmentsBridge.swift`).

enum AttachmentKind {
  /// A JPEG from the photo library or the camera — offered for scaling.
  photo,
  video,

  /// Anything else, sent byte for byte.
  file,
}

enum AttachmentSource { photoLibrary, camera, scanner, files }

/// The Settings › Mail row that covers a file of [mimeType] picked from
/// [source]; null for scans and documents, which have no row.
StripSource? stripSourceOf(AttachmentSource source, String mimeType) {
  final image = mimeType.startsWith('image/');
  final video = mimeType.startsWith('video/');
  return switch (source) {
    AttachmentSource.photoLibrary =>
      image
          ? StripSource.libraryPhotos
          : (video ? StripSource.libraryVideos : null),
    AttachmentSource.camera => image ? StripSource.cameraPhotos : null,
    AttachmentSource.files =>
      image
          ? StripSource.filesImages
          : (video ? StripSource.filesVideos : null),
    AttachmentSource.scanner => null,
  };
}

/// The photo sizes offered at Send, by long edge in pixels.
const kPhotoSizes = <String, int>{'Small': 640, 'Medium': 1280, 'Large': 2048};

/// One file in a compose sheet, stored in the sheet's session folder.
class ComposeAttachment {
  ComposeAttachment({
    required this.path,
    required this.name,
    required this.mimeType,
    required this.size,
    required this.kind,
    this.thumbPath,
  });

  final String path;
  final String name;
  final String mimeType;
  final int size;
  final AttachmentKind kind;

  /// A video's still frame; images show themselves.
  final String? thumbPath;

  bool get isPhoto => kind == AttachmentKind.photo;
  bool get isImage => mimeType.startsWith('image/');

  /// Scaled copies for the size choice, by long edge — started as soon as a
  /// photo is added, so Send rarely has to wait for them.
  final Map<int, Future<ScaledPhoto>> variants = {};
}

class ScaledPhoto {
  const ScaledPhoto(this.path, this.size);
  final String path;
  final int size;
}

class AttachmentPickResult {
  const AttachmentPickResult(this.items, this.failed);
  final List<ComposeAttachment> items;
  final int failed;
}

/// A picker, the camera or Quick Look couldn't run; [message] is for the
/// compose error banner.
class AttachmentException implements Exception {
  const AttachmentException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ComposeAttachments {
  ComposeAttachments._();

  static const _channel = MethodChannel('kisd/compose_attachments');

  /// Called with the number of files about to arrive, once a picker closes
  /// and while they are copied or converted — compose shows that many
  /// placeholder tiles. One compose sheet exists at a time.
  static void Function(int count)? onLoading;

  static bool _handlerSet = false;

  static void _ensureHandler() {
    if (_handlerSet) return;
    _handlerSet = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'loading') onLoading?.call(call.arguments as int);
    });
  }

  /// A fresh folder for one compose sheet. Deleted with [deleteSession].
  static Future<String> newSession() async {
    final base = await getApplicationCacheDirectory();
    final id =
        '${DateTime.now().microsecondsSinceEpoch}-'
        '${Random().nextInt(1 << 32)}';
    final dir = Directory('${base.path}/compose_attachments/$id');
    await dir.create(recursive: true);
    return dir.path;
  }

  static Future<void> deleteSession(String dir) async {
    try {
      await Directory(dir).delete(recursive: true);
    } catch (_) {}
  }

  /// Which sources this device has: the simulator, for one, has no camera.
  static Future<({bool camera, bool scanner})> capabilities() async {
    try {
      final caps = await _channel.invokeMapMethod<String, bool>('capabilities');
      return (
        camera: caps?['camera'] ?? false,
        scanner: caps?['scanner'] ?? false,
      );
    } catch (_) {
      return (camera: false, scanner: false);
    }
  }

  static Future<AttachmentPickResult> pick(
    AttachmentSource source,
    String dir,
  ) async {
    _ensureHandler();
    final method = switch (source) {
      AttachmentSource.photoLibrary => 'pickPhotos',
      AttachmentSource.camera => 'takePhoto',
      AttachmentSource.scanner => 'scanDocument',
      AttachmentSource.files => 'pickFiles',
    };
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(method, {
        'dir': dir,
      });
      final items = <ComposeAttachment>[];
      var failed = (result?['failed'] as int?) ?? 0;
      for (final raw in (result?['items'] as List?) ?? const []) {
        final picked = _attachment(Map<String, dynamic>.from(raw as Map));
        try {
          items.add(await _stripped(picked, source));
        } catch (_) {
          failed++; // never attached with the metadata it should have lost
        }
      }
      return AttachmentPickResult(items, failed);
    } on PlatformException catch (e) {
      throw AttachmentException(switch (e.code) {
        'camera_denied' =>
          'Camera access is off. Allow it in Settings › '
              'KISD Calendar › Camera.',
        'busy' => 'A picker is already open.',
        _ => e.message ?? "Couldn't add the attachment.",
      });
    } on MissingPluginException {
      throw const AttachmentException('Attachments need iOS 14 or later.');
    }
  }

  static ComposeAttachment _attachment(Map<String, dynamic> m) =>
      ComposeAttachment(
        path: m['path'] as String,
        name: m['name'] as String,
        mimeType: m['mimeType'] as String,
        size: m['size'] as int,
        kind: switch (m['kind']) {
          'photo' => AttachmentKind.photo,
          'video' => AttachmentKind.video,
          _ => AttachmentKind.file,
        },
        thumbPath: m['thumbPath'] as String?,
      );

  /// [a] with its metadata stripped in place as Settings › Mail says, or [a]
  /// itself when the setting leaves it alone. Throws when a file that should
  /// be cleaned couldn't be.
  static Future<ComposeAttachment> _stripped(
    ComposeAttachment a,
    AttachmentSource source,
  ) async {
    final mode = ThemeService.instance.metadataStrip.value;
    final row = stripSourceOf(source, a.mimeType);
    if (mode == MetadataStrip.keep ||
        row == null ||
        !ThemeService.instance.stripSources.value.contains(row)) {
      return a;
    }
    final size = await _channel.invokeMethod<int>('stripMetadata', {
      'path': a.path,
      'mode': mode.name,
    });
    // Null: a type with nothing to strip (GIF, …), sent as it is.
    if (size == null) return a;
    return ComposeAttachment(
      path: a.path,
      name: a.name,
      mimeType: a.mimeType,
      size: size,
      kind: a.kind,
      thumbPath: a.thumbPath,
    );
  }

  /// Quick Look over all [paths], opened at [index].
  static Future<void> preview(List<String> paths, int index) async {
    try {
      await _channel.invokeMethod('preview', {'paths': paths, 'index': index});
    } catch (_) {}
  }

  /// [photo] at most [maxPixel] on its long edge. A photo already that small
  /// comes back as itself.
  static Future<ScaledPhoto> scale(
    ComposeAttachment photo,
    int maxPixel,
  ) async {
    final dir = File(photo.path).parent.path;
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'scaleImage',
      {
        'path': photo.path,
        'out': '$dir/.scaled-$maxPixel.jpg',
        'maxPixel': maxPixel,
      },
    );
    return ScaledPhoto(result!['path'] as String, result['size'] as int);
  }

  /// A forwarded or restored file, written into the session folder so it can
  /// be previewed, scaled and re-read like a picked one. Never stripped (see
  /// `attachment_metadata.dart`).
  static Future<ComposeAttachment> fromData(
    MailAttachmentData data,
    String dir,
  ) async {
    final folder = Directory(
      '$dir/${DateTime.now().microsecondsSinceEpoch}-'
      '${Random().nextInt(1 << 32)}',
    );
    await folder.create(recursive: true);
    final safeName = data.name.replaceAll('/', '-').trim();
    final file = File(
      '${folder.path}/${safeName.isEmpty ? 'Attachment' : safeName}',
    );
    await file.writeAsBytes(data.bytes, flush: true);
    return ComposeAttachment(
      path: file.path,
      name: data.name,
      mimeType: data.mimeType,
      size: data.bytes.length,
      kind: data.isPhoto ? AttachmentKind.photo : AttachmentKind.file,
    );
  }
}
