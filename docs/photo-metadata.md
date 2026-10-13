# Photo metadata (EXIF / GPS) in mail attachments

**Decision, 13 Oct 2026, revised the same day: a setting in Settings › Mail.**
iPhone photos and videos can carry the GPS location where they were taken,
plus camera, date and orientation. The user picks what goes:

| Photo metadata | Removes |
|---|---|
| **Don't strip** (default) | Nothing |
| **Strip GPS** | The location (EXIF and XMP GPS; for videos the QuickTime location and Apple's "for sharing" set) |
| **Strip all** | Everything except the orientation (and the colour profile, which is part of the image) |

**Applies to** is a list of checkmark rows, each switched on or off on its
own. It is dimmed and untappable while "Don't strip" is selected, and keeps
its choices.

| Row | Default | Covers |
|---|---|---|
| **Library photos** | on | Photo library JPEG, HEIC→JPEG, PNG |
| **Library videos** | on | Photo library videos |
| **Camera photos** | on | Take Photo. These are re-encoded from a `UIImage`, so there is probably nothing to strip; the row exists for completeness |
| **Images from Files** | off | Images picked in Files |
| **Videos from Files** | off | QuickTime / MPEG-4 videos picked in Files |

Scans and documents have no row: they carry no photo metadata.

**Forwards and reopened drafts are never stripped.** A forward's files aren't
the user's, and the sender chose what to send. A draft's files were already
stripped, under the setting of the time, when they were picked. So a photo
picked while "Don't strip" was on keeps its metadata in that draft.

Code: `lib/services/attachment_metadata.dart` (the enums and the defaults),
`stripSourceOf` in `compose_attachments.dart` (which row covers a pick; both
pinned by `test/attachment_metadata_test.dart`), `ThemeService.metadataStrip` /
`stripSources` (SharedPreferences `mail_metadata_strip`,
`mail_metadata_sources`), `ComposeAttachments._stripped`, and `stripMetadata`
in `ios/Runner/ComposeAttachmentsBridge.swift`.

## How it works

- **When:** right after a picker returns (`ComposeAttachments.pick`). Never
  at Send, so a draft saved to the server is already clean. A setting changed
  mid-compose applies to files picked after the change.
- **Fail closed:** a file that should be stripped but can't be is not
  attached (the picker's "couldn't be added" banner).
- **Lossless:**
  - JPEG and HEIC: `CGImageDestinationCopyImageSource` copies the compressed
    image untouched (decoded pixels verified identical).
  - PNG: that copy ignores PNG metadata options, so PNG is re-encoded, which
    is lossless.
  - Videos: passthrough `AVAssetExportSession`, never re-encoded. "Strip all"
    rebuilds the audio and video tracks in an `AVMutableComposition`, which
    drops file, track and timed metadata (faces, Live Photo info) and keeps
    the rotation.
- **Not stripped, sent as they are:** GIF, TIFF, RAW from Files, PDF and
  everything else; videos that are neither QuickTime nor MPEG-4.

Gotcha, verified 13 Oct 2026: `CopyImageSource` with only
`kCGImageMetadataShouldExcludeGPS` drops **all** metadata, orientation
included. It needs a `kCGImageDestinationMetadata` entry. GPS-only merges an
empty set; "all" replaces the set with one holding just `tiff:Orientation`.

## What each path sends with "Don't strip"

| Path | Metadata sent |
|---|---|
| Photo Library JPEG / PNG, **Actual Size** | **Full, including location.** The file is copied byte for byte |
| Photo Library HEIC → JPEG, **Actual Size** | **Full, including location.** `convertToJPEG` copies it via `CGImageDestinationAddImageFromSource` |
| **Small / Medium / Large** | **None** when the photo is larger than that size: a freshly encoded, scaled copy. A photo already that small is sent as the original, with its metadata |
| **Drafts** | **Full.** Drafts always store photos at Actual Size, on the TH Köln server |
| Take Photo | Essentially none: re-encoded from a `UIImage`. *Not verified: the camera has never run* |
| Scan Document | No photo metadata: the pages are redrawn into a PDF |
| Files from Files, forwarded attachments | Unchanged: whatever the file already carries (forwards stay unchanged under every setting) |
| Videos | Copied as the picker delivers them. iPhone `.MOV` originals carry the location; *not checked whether the picker's compatible copy keeps it* |

## Verified

Headless on macOS ImageIO/AVFoundation with real iPhone 12 files: a JPEG, a
PNG with GPS, a HEIC and two `.MOV`s, run with the same functions as the app.
*Not yet run on the simulator or an iPhone.*
