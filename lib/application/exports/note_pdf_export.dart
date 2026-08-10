import 'dart:typed_data';

const synapsePageBreakMarker = '<!-- synapse:page-break -->';

enum NotePdfOrientation { portrait, landscape }

enum NotePdfMarginPreset {
  compact(10),
  standard(15),
  wide(20);

  const NotePdfMarginPreset(this.millimeters);

  final double millimeters;
}

enum NotePdfExportWarningCode {
  missingImage,
  unreadableImage,
  tableFallback,
  narrowTable,
}

enum NotePdfPageBoundaryKind { automatic, manual }

final class NotePdfPageBoundary {
  const NotePdfPageBoundary({
    required this.pageIndex,
    required this.sourceOffset,
    required this.kind,
  });

  /// Zero-based index of the page that starts at [sourceOffset].
  final int pageIndex;

  /// UTF-16 offset in [NotePdfExportSnapshot.markdown] for the first visible
  /// source content rendered on this page.
  final int sourceOffset;
  final NotePdfPageBoundaryKind kind;
}

final class NotePdfExportWarning {
  const NotePdfExportWarning({required this.code, required this.message});

  final NotePdfExportWarningCode code;
  final String message;
}

final class NotePdfExportAsset {
  NotePdfExportAsset({
    required this.source,
    required this.title,
    required this.mimeType,
    required Uint8List? bytes,
  }) : bytes = bytes == null ? null : Uint8List.fromList(bytes);

  final String source;
  final String title;
  final String mimeType;
  final Uint8List? bytes;
}

final class NotePdfExportSnapshot {
  NotePdfExportSnapshot({
    required this.noteId,
    required this.title,
    required this.markdown,
    required List<NotePdfExportAsset> assets,
  }) : assets = List<NotePdfExportAsset>.unmodifiable(assets);

  final String noteId;
  final String title;
  final String markdown;
  final List<NotePdfExportAsset> assets;
}

final class NotePdfExportOptions {
  const NotePdfExportOptions({
    this.orientation = NotePdfOrientation.portrait,
    this.marginPreset = NotePdfMarginPreset.standard,
    this.footerEnabled = true,
  });

  final NotePdfOrientation orientation;
  final NotePdfMarginPreset marginPreset;
  final bool footerEnabled;

  NotePdfExportOptions copyWith({
    NotePdfOrientation? orientation,
    NotePdfMarginPreset? marginPreset,
    bool? footerEnabled,
  }) => NotePdfExportOptions(
    orientation: orientation ?? this.orientation,
    marginPreset: marginPreset ?? this.marginPreset,
    footerEnabled: footerEnabled ?? this.footerEnabled,
  );

  @override
  bool operator ==(Object other) =>
      other is NotePdfExportOptions &&
      other.orientation == orientation &&
      other.marginPreset == marginPreset &&
      other.footerEnabled == footerEnabled;

  @override
  int get hashCode => Object.hash(orientation, marginPreset, footerEnabled);
}

final class NotePdfBuildResult {
  NotePdfBuildResult({
    required Uint8List bytes,
    required this.pageCount,
    required List<NotePdfExportWarning> warnings,
    List<NotePdfPageBoundary> boundaries = const [],
  }) : bytes = Uint8List.fromList(bytes),
       warnings = List<NotePdfExportWarning>.unmodifiable(warnings),
       boundaries = List<NotePdfPageBoundary>.unmodifiable(boundaries);

  final Uint8List bytes;
  final int pageCount;
  final List<NotePdfExportWarning> warnings;
  final List<NotePdfPageBoundary> boundaries;
}

abstract interface class NotePdfExporter {
  Future<NotePdfBuildResult> build(
    NotePdfExportSnapshot snapshot,
    NotePdfExportOptions options,
  );
}

final class NotePdfPreviewPage {
  NotePdfPreviewPage({
    required this.pageIndex,
    required this.width,
    required this.height,
    required Uint8List pngBytes,
  }) : pngBytes = Uint8List.fromList(pngBytes);

  final int pageIndex;
  final int width;
  final int height;
  final Uint8List pngBytes;
}

abstract interface class NotePdfPreviewRasterizer {
  Future<NotePdfPreviewPage> rasterPage(
    Uint8List pdfBytes,
    int pageIndex, {
    double dpi = 96,
  });
}

enum NotePdfSaveOutcome { saved, cancelled }

abstract interface class NotePdfFileSaver {
  Future<NotePdfSaveOutcome> save(
    Uint8List pdfBytes, {
    required String suggestedName,
  });
}
