/// Settings › Mail: what compose strips from attachments, and from which.
/// Pinned by `test/attachment_metadata_test.dart`.
///
/// Stripping runs natively when a file is picked for a mail
/// (`stripMetadata` in `ios/Runner/ComposeAttachmentsBridge.swift`), so a
/// draft saved to the server is already clean. Files that come with a mail —
/// a forward's, a reopened draft's — are never stripped: a forward's aren't
/// ours, and a draft's were stripped when they were picked.
library;

enum MetadataStrip {
  /// Sent as they are, location included.
  keep,

  /// The location only.
  gps,

  /// Everything but the orientation.
  all,
}

/// The kinds of picked file Settings › Mail lists, each switched on or off on
/// its own. Scans and documents aren't listed: they carry no photo metadata.
enum StripSource {
  libraryPhotos,
  libraryVideos,
  cameraPhotos,
  filesImages,
  filesVideos,
}

/// Until the user changes them: their own photos and videos.
const kDefaultStripSources = <StripSource>{
  StripSource.libraryPhotos,
  StripSource.libraryVideos,
  StripSource.cameraPhotos,
};
