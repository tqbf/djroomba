import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  /// The exported `.djroomba` library-snapshot type. Mirrors the
  /// `UTExportedTypeDeclarations` entry in `Info.plist` (same identifier,
  /// `djroomba` filename extension, conforms to `public.data`). Declared
  /// `exportedAs` because this app owns/defines the type.
  static let djroombaSnapshot = UTType(exportedAs: "org.sockpuppet.djroomba.snapshot")
}

// MARK: - SnapshotDocument

/// The minimal document `.fileExporter` writes for an export. It carries
/// the **already-built** compressed container bytes: the expensive work
/// (`VACUUM INTO` + read + zlib) is done off-main by
/// `SnapshotService.prepareExport()` *before* the exporter is presented,
/// so SwiftUI's write path here is a trivial byte copy and never blocks a
/// background `fileWrapper` on heavy work (swiftui-pro: keep document
/// serialization cheap; do the work before presenting).
struct SnapshotDocument: FileDocument {

  // MARK: Lifecycle

  init(data: Data) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    guard let bytes = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    data = bytes
  }

  // MARK: Internal

  // Exported only; reading is required by the protocol but unused (import
  // reads the URL itself via `.fileImporter` so it can decompress +
  // migrate before touching the live store).
  static let readableContentTypes = [UTType.djroombaSnapshot]
  static let writableContentTypes = [UTType.djroombaSnapshot]

  var data: Data

  func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
