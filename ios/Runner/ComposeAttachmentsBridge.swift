import AVFoundation
import Flutter
import ImageIO
import PhotosUI
import QuickLook
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// Compose's attachment sources and Quick Look, on Apple's own controllers.
///
/// The photo library goes through `PHPickerViewController`, which runs out of
/// process and hands over only what the user taps — so there is no photo
/// permission prompt. The camera and the document scanner need the camera
/// permission (`NSCameraUsageDescription`).
///
/// Every picking call takes the compose session's `dir` and returns
/// `{items: [{path, name, mimeType, size, kind, thumbPath?}], failed: n}`.
/// `kind` is `photo` (a JPEG from the library or camera — offered for
/// scaling at Send), `video`, or `file` (sent untouched). Each file lands in
/// its own UUID folder so the original name survives without collisions.
/// Pickers copy files with their metadata; Dart then asks `stripMetadata` to
/// clean them as Settings › Mail says (`lib/services/attachment_metadata.dart`).
@available(iOS 14.0, *)
final class ComposeAttachmentsBridge: NSObject {
  static let shared = ComposeAttachmentsBridge()
  static let channelName = "kisd/compose_attachments"

  private var channel: FlutterMethodChannel?
  // The one picker in flight: a second tap while a picker is up is refused.
  private var pendingResult: FlutterResult?
  private var pendingDir: URL?
  private var previewURLs: [URL] = []
  private let work = DispatchQueue(label: "kisd.compose-attachments", qos: .userInitiated)

  func register(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "ComposeAttachmentsBridge") else { return }
    let channel = FlutterMethodChannel(
      name: Self.channelName, binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    self.channel = channel
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "capabilities":
      result([
        "camera": UIImagePickerController.isSourceTypeAvailable(.camera),
        "scanner": VNDocumentCameraViewController.isSupported,
      ])
    case "pickPhotos", "takePhoto", "scanDocument", "pickFiles":
      guard pendingResult == nil else {
        result(FlutterError(code: "busy", message: "A picker is already open", details: nil))
        return
      }
      guard let dirPath = args["dir"] as? String else {
        result(FlutterError(code: "bad_args", message: "Expected {dir}", details: nil))
        return
      }
      let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      pendingResult = result
      pendingDir = dir
      switch call.method {
      case "pickPhotos": presentPhotoPicker()
      case "takePhoto": withCameraAccess { self.presentCamera() }
      case "scanDocument": withCameraAccess { self.presentScanner() }
      default: presentFilePicker()
      }
    case "preview":
      guard let paths = args["paths"] as? [String], !paths.isEmpty else {
        result(FlutterError(code: "bad_args", message: "Expected {paths, index}", details: nil))
        return
      }
      presentPreview(paths: paths, index: args["index"] as? Int ?? 0)
      result(nil)
    case "scaleImage":
      guard let path = args["path"] as? String,
            let out = args["out"] as? String,
            let maxPixel = args["maxPixel"] as? Int else {
        result(FlutterError(code: "bad_args", message: "Expected {path, out, maxPixel}", details: nil))
        return
      }
      work.async {
        let scaled = Self.scaleImage(
          at: URL(fileURLWithPath: path), to: URL(fileURLWithPath: out), maxPixel: maxPixel)
        DispatchQueue.main.async {
          if let scaled {
            result(scaled)
          } else {
            result(FlutterError(code: "scale_failed", message: "Couldn't scale \(path)", details: nil))
          }
        }
      }
    case "stripMetadata":
      guard let path = args["path"] as? String,
            let mode = args["mode"] as? String, mode == "gps" || mode == "all" else {
        result(FlutterError(code: "bad_args", message: "Expected {path, mode: gps|all}", details: nil))
        return
      }
      let url = URL(fileURLWithPath: path)
      work.async {
        Self.stripMetadata(at: url, all: mode == "all") { outcome in
          DispatchQueue.main.async {
            switch outcome {
            case .stripped: result(Self.fileSize(url))
            case .unsupported: result(nil)
            case .failed:
              result(FlutterError(code: "strip_failed", message: "Couldn't strip \(path)", details: nil))
            }
          }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Presenting

  private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = scenes.flatMap { $0.windows }
    var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  private func present(_ controller: UIViewController) {
    guard let top = topViewController() else {
      fail(code: "no_window", message: "Nothing to present the picker on")
      return
    }
    top.present(controller, animated: true)
  }

  /// Ends the call in flight with what was picked.
  private func finish(items: [[String: Any]], failed: Int = 0) {
    let result = pendingResult
    pendingResult = nil
    pendingDir = nil
    result?(["items": items, "failed": failed])
  }

  private func fail(code: String, message: String) {
    let result = pendingResult
    pendingResult = nil
    pendingDir = nil
    result?(FlutterError(code: code, message: message, details: nil))
  }

  /// Tells compose how many placeholder tiles to show while files load.
  private func announceLoading(_ count: Int) {
    channel?.invokeMethod("loading", arguments: count)
  }

  private func withCameraAccess(_ present: @escaping () -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      present()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async {
          if granted {
            present()
          } else {
            self.fail(code: "camera_denied", message: "Camera access was not allowed")
          }
        }
      }
    default:
      fail(code: "camera_denied", message: "Camera access is turned off")
    }
  }

  // MARK: - Files on disk

  /// A fresh `<dir>/<uuid>/<name>`.
  private static func destination(in dir: URL, name: String) -> URL {
    let folder = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let clean = name.replacingOccurrences(of: "/", with: "-")
    return folder.appendingPathComponent(clean.isEmpty ? "Attachment" : clean)
  }

  private static func fileSize(_ url: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
  }

  private static func mimeType(for url: URL) -> String {
    UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
  }

  private static func item(_ url: URL, kind: String, thumb: URL? = nil) -> [String: Any] {
    var item: [String: Any] = [
      "path": url.path,
      "name": url.lastPathComponent,
      "mimeType": mimeType(for: url),
      "size": fileSize(url),
      "kind": kind,
    ]
    if let thumb { item["thumbPath"] = thumb.path }
    return item
  }

  private static func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
    return formatter.string(from: Date())
  }

  /// `IMG_2041` + the loaded file's own extension.
  private static func baseName(_ suggested: String?, fallback: String) -> String {
    guard let suggested, !suggested.isEmpty else { return fallback }
    return (suggested as NSString).deletingPathExtension
  }

  // MARK: - Photo library

  private func presentPhotoPicker() {
    // No `photoLibrary:` — the picker then hands over files only, which needs
    // no library permission at all.
    var config = PHPickerConfiguration()
    config.filter = .any(of: [.images, .videos])
    config.selectionLimit = 0
    // HEIC → JPEG and HEVC → H.264 where the recipient might not decode them.
    config.preferredAssetRepresentationMode = .compatible
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    present(picker)
  }

  /// Loads one picked library item into `dir`. Images that aren't JPEG, PNG
  /// or GIF (HEIC, RAW, …) are converted to JPEG with their metadata kept.
  private static func load(
    _ provider: NSItemProvider, into dir: URL, completion: @escaping ([String: Any]?) -> Void
  ) {
    let base = baseName(provider.suggestedName, fallback: "Photo \(timestamp())")
    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
      provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
        // The file is deleted once this handler returns: copy it now.
        guard let url else { return completion(nil) }
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .jpeg) == true {
          let dest = destination(in: dir, name: "\(base).jpg")
          guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else {
            return completion(nil)
          }
          completion(item(dest, kind: "photo"))
        } else if type?.conforms(to: .png) == true || type?.conforms(to: .gif) == true {
          let dest = destination(in: dir, name: "\(base).\(url.pathExtension.lowercased())")
          guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else {
            return completion(nil)
          }
          completion(item(dest, kind: "file"))
        } else {
          let dest = destination(in: dir, name: "\(base).jpg")
          guard convertToJPEG(url, to: dest) else { return completion(nil) }
          completion(item(dest, kind: "photo"))
        }
      }
    } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
      provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
        guard let url else { return completion(nil) }
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        let dest = destination(in: dir, name: "\(base).\(ext)")
        guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else {
          return completion(nil)
        }
        videoThumbnail(dest) { thumb in completion(item(dest, kind: "video", thumb: thumb)) }
      }
    } else {
      completion(nil)
    }
  }

  private static func convertToJPEG(_ source: URL, to dest: URL) -> Bool {
    guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
          let out = CGImageDestinationCreateWithURL(
            dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { return false }
    // Copies the metadata (orientation, date, location — kept, like Apple Mail).
    CGImageDestinationAddImageFromSource(
      out, src, 0, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    return CGImageDestinationFinalize(out)
  }

  private static func videoThumbnail(_ video: URL, completion: @escaping (URL?) -> Void) {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 240, height: 240)
    generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) {
      _, image, _, _, _ in
      guard let image else { return completion(nil) }
      let thumb = video.deletingLastPathComponent().appendingPathComponent(".thumb.jpg")
      guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.7),
            (try? data.write(to: thumb)) != nil
      else { return completion(nil) }
      completion(thumb)
    }
  }

  // MARK: - Camera

  private func presentCamera() {
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
      fail(code: "unavailable", message: "This device has no camera")
      return
    }
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.mediaTypes = [UTType.image.identifier]
    picker.delegate = self
    present(picker)
  }

  // MARK: - Document scanner

  private func presentScanner() {
    guard VNDocumentCameraViewController.isSupported else {
      fail(code: "unavailable", message: "Document scanning isn't supported here")
      return
    }
    let scanner = VNDocumentCameraViewController()
    scanner.delegate = self
    present(scanner)
  }

  /// All pages in one PDF, each page JPEG-compressed and at most 2000 px on
  /// the long edge — sharp enough to read, small enough to mail.
  private static func writePDF(_ scan: VNDocumentCameraScan, to dest: URL) -> Bool {
    let pageWidth: CGFloat = 595 // A4 width in points
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    var pages: [(UIImage, CGRect)] = []
    for index in 0..<scan.pageCount {
      let page = scan.imageOfPage(at: index)
      let scale = min(1, 2000 / max(page.size.width, page.size.height))
      let size = CGSize(width: page.size.width * scale, height: page.size.height * scale)
      let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        page.draw(in: CGRect(origin: .zero, size: size))
      }
      guard let jpeg = resized.jpegData(compressionQuality: 0.7),
            let compressed = UIImage(data: jpeg) else { continue }
      let height = pageWidth * size.height / max(size.width, 1)
      pages.append((compressed, CGRect(x: 0, y: 0, width: pageWidth, height: height)))
    }
    guard let first = pages.first else { return false }
    let renderer = UIGraphicsPDFRenderer(bounds: first.1)
    do {
      try renderer.writePDF(to: dest) { context in
        for (image, bounds) in pages {
          context.beginPage(withBounds: bounds, pageInfo: [:])
          image.draw(in: bounds)
        }
      }
      return true
    } catch {
      return false
    }
  }

  // MARK: - Files

  private func presentFilePicker() {
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
    picker.allowsMultipleSelection = true
    picker.delegate = self
    present(picker)
  }

  // MARK: - Quick Look

  private func presentPreview(paths: [String], index: Int) {
    previewURLs = paths.map { URL(fileURLWithPath: $0) }
    let preview = QLPreviewController()
    preview.dataSource = self
    preview.currentPreviewItemIndex = min(max(index, 0), paths.count - 1)
    guard let top = topViewController() else { return }
    top.present(preview, animated: true)
  }

  // MARK: - Scaling

  /// The image at most [maxPixel] on its long edge as JPEG, orientation
  /// baked in. Never upscales: a picture already that small comes back as is.
  private static func scaleImage(at source: URL, to dest: URL, maxPixel: Int) -> [String: Any]? {
    guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
    let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
    if width > 0, height > 0, max(width, height) <= maxPixel {
      return ["path": source.path, "size": fileSize(source)]
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary),
          let out = CGImageDestinationCreateWithURL(
            dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    try? FileManager.default.createDirectory(
      at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    CGImageDestinationAddImage(
      out, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    guard CGImageDestinationFinalize(out) else { return nil }
    return ["path": dest.path, "size": fileSize(dest)]
  }

  // MARK: - Metadata

  private enum StripOutcome { case stripped, unsupported, failed }

  /// Strips the file at [url] in place (Settings › Mail): only its location,
  /// or with [all] everything but the orientation. Images keep every pixel —
  /// JPEG and HEIC are copied without re-compressing, PNG is re-encoded, which
  /// is lossless. Videos are remuxed, never re-encoded. Anything else (GIF,
  /// TIFF, PDF, …) is `unsupported` and goes out as it is.
  private static func stripMetadata(
    at url: URL, all: Bool, completion: @escaping (StripOutcome) -> Void
  ) {
    let temp = url.deletingLastPathComponent()
      .appendingPathComponent(".stripped-\(url.lastPathComponent)")
    try? FileManager.default.removeItem(at: temp)
    let done = { (ok: Bool) in
      if ok, (try? FileManager.default.replaceItemAt(url, withItemAt: temp)) != nil {
        completion(.stripped)
      } else {
        try? FileManager.default.removeItem(at: temp)
        completion(.failed)
      }
    }
    if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .movie) {
      let fileType: AVFileType? =
        type.conforms(to: .quickTimeMovie) ? .mov : type.conforms(to: .mpeg4Movie) ? .mp4 : nil
      guard let fileType else { return completion(.unsupported) }
      stripVideo(url, to: temp, as: fileType, all: all, completion: done)
      return
    }
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let srcType = CGImageSourceGetType(src),
          let type = UTType(srcType as String),
          [.jpeg, .heic, .heif, .png].contains(where: { type.conforms(to: $0) })
    else { return completion(.unsupported) }
    done(stripImage(src, type: srcType, to: temp, all: all))
  }

  private static func stripImage(
    _ src: CGImageSource, type: CFString, to dest: URL, all: Bool
  ) -> Bool {
    guard let out = CGImageDestinationCreateWithURL(dest as CFURL, type, 1, nil) else {
      return false
    }
    let orientation = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])?[
      kCGImagePropertyOrientation]
    if UTType(type as String)?.conforms(to: .png) == true {
      // The copy below ignores PNG's metadata options: re-encode instead.
      if all {
        guard let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return false }
        var props: [CFString: Any] = [:]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(out, image, props as CFDictionary)
      } else {
        CGImageDestinationAddImageFromSource(
          out, src, 0, [kCGImagePropertyGPSDictionary: kCFNull!] as CFDictionary)
      }
      return CGImageDestinationFinalize(out)
    }
    // JPEG and HEIC: the compressed image is copied as is. Without a metadata
    // entry the copy drops *all* metadata, orientation included — so GPS-only
    // merges an empty set minus GPS, and "all" replaces the set with one that
    // holds just the orientation.
    let options: [CFString: Any]
    if all {
      let meta = CGImageMetadataCreateMutable()
      if let orientation {
        CGImageMetadataSetValueMatchingImageProperty(
          meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation,
          orientation as CFTypeRef)
      }
      options = [
        kCGImageDestinationMetadata: meta,
        kCGImageDestinationMergeMetadata: false,
        kCGImageMetadataShouldExcludeXMP: true,
      ]
    } else {
      options = [
        kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
        kCGImageDestinationMergeMetadata: true,
        kCGImageMetadataShouldExcludeGPS: true,
      ]
    }
    // Finalises the destination itself.
    return CGImageDestinationCopyImageSource(out, src, options as CFDictionary, nil)
  }

  private static func stripVideo(
    _ source: URL, to dest: URL, as fileType: AVFileType, all: Bool,
    completion: @escaping (Bool) -> Void
  ) {
    let asset = AVURLAsset(url: source)
    var exported: AVAsset = asset
    if all {
      // Picture and sound only, rebuilt in a composition: no file or track
      // metadata, and no timed metadata (faces, Live Photo info) comes along.
      let composition = AVMutableComposition()
      for track in asset.tracks where track.mediaType == .video || track.mediaType == .audio {
        guard let copy = composition.addMutableTrack(
                withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid),
              (try? copy.insertTimeRange(track.timeRange, of: track, at: track.timeRange.start))
                != nil
        else { return completion(false) }
        copy.preferredTransform = track.preferredTransform
      }
      exported = composition
    }
    guard let session = AVAssetExportSession(
            asset: exported, presetName: AVAssetExportPresetPassthrough)
    else { return completion(false) }
    session.outputURL = dest
    session.outputFileType = fileType
    if !all {
      session.metadata = asset.metadata.filter { item in
        let id = item.identifier?.rawValue.lowercased() ?? ""
        return !(id.contains("location") || id.contains("iso6709") || id.contains("%a9xyz"))
      }
      session.metadataItemFilter = .forSharing()
    }
    session.exportAsynchronously { completion(session.status == .completed) }
  }
}

// MARK: - PHPickerViewControllerDelegate

@available(iOS 14.0, *)
extension ComposeAttachmentsBridge: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let dir = pendingDir, !results.isEmpty else {
      finish(items: [])
      return
    }
    announceLoading(results.count)
    // Loaded in parallel, returned in the order they were picked.
    var loaded = [[String: Any]?](repeating: nil, count: results.count)
    let group = DispatchGroup()
    for (index, result) in results.enumerated() {
      group.enter()
      Self.load(result.itemProvider, into: dir) { item in
        self.work.async {
          loaded[index] = item
          group.leave()
        }
      }
    }
    group.notify(queue: .main) {
      let items = loaded.compactMap { $0 }
      self.finish(items: items, failed: results.count - items.count)
    }
  }
}

// MARK: - UIImagePickerControllerDelegate

@available(iOS 14.0, *)
extension ComposeAttachmentsBridge: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    picker.dismiss(animated: true)
    guard let dir = pendingDir, let image = info[.originalImage] as? UIImage else {
      finish(items: [], failed: 1)
      return
    }
    announceLoading(1)
    work.async {
      let dest = Self.destination(in: dir, name: "Photo \(Self.timestamp()).jpg")
      let ok = (try? image.jpegData(compressionQuality: 0.9)?.write(to: dest)) != nil
      DispatchQueue.main.async {
        if ok {
          self.finish(items: [Self.item(dest, kind: "photo")])
        } else {
          self.finish(items: [], failed: 1)
        }
      }
    }
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
    finish(items: [])
  }
}

// MARK: - VNDocumentCameraViewControllerDelegate

@available(iOS 14.0, *)
extension ComposeAttachmentsBridge: VNDocumentCameraViewControllerDelegate {
  func documentCameraViewController(
    _ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan
  ) {
    controller.dismiss(animated: true)
    guard let dir = pendingDir, scan.pageCount > 0 else {
      finish(items: [])
      return
    }
    announceLoading(1)
    work.async {
      let dest = Self.destination(in: dir, name: "Scan \(Self.timestamp()).pdf")
      let ok = Self.writePDF(scan, to: dest)
      DispatchQueue.main.async {
        if ok {
          self.finish(items: [Self.item(dest, kind: "file")])
        } else {
          self.finish(items: [], failed: 1)
        }
      }
    }
  }

  func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
    controller.dismiss(animated: true)
    finish(items: [])
  }

  func documentCameraViewController(
    _ controller: VNDocumentCameraViewController, didFailWithError error: Error
  ) {
    controller.dismiss(animated: true)
    fail(code: "scan_failed", message: error.localizedDescription)
  }
}

// MARK: - UIDocumentPickerDelegate

@available(iOS 14.0, *)
extension ComposeAttachmentsBridge: UIDocumentPickerDelegate {
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let dir = pendingDir, !urls.isEmpty else {
      finish(items: [])
      return
    }
    announceLoading(urls.count)
    work.async {
      var items: [[String: Any]] = []
      for url in urls {
        // `asCopy` already gave us our own copy: move it into the session.
        let dest = Self.destination(in: dir, name: url.lastPathComponent)
        if (try? FileManager.default.moveItem(at: url, to: dest)) != nil
          || (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
          items.append(Self.item(dest, kind: "file"))
        }
      }
      DispatchQueue.main.async { self.finish(items: items, failed: urls.count - items.count) }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(items: [])
  }
}

// MARK: - QLPreviewControllerDataSource

@available(iOS 14.0, *)
extension ComposeAttachmentsBridge: QLPreviewControllerDataSource {
  func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewURLs.count }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
    previewURLs[index] as NSURL
  }
}
