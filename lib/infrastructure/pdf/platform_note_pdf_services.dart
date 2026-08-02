import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:printing/printing.dart';

import '../../application/exports/note_pdf_export.dart';

final class PrintingNotePdfPreviewRasterizer
    implements NotePdfPreviewRasterizer {
  const PrintingNotePdfPreviewRasterizer();

  @override
  Future<NotePdfPreviewPage> rasterPage(
    Uint8List pdfBytes,
    int pageIndex, {
    double dpi = 96,
  }) async {
    if (pageIndex < 0) {
      throw RangeError.index(pageIndex, const <int>[]);
    }
    final page = await Printing.raster(
      pdfBytes,
      pages: [pageIndex],
      dpi: dpi,
    ).first;
    return NotePdfPreviewPage(
      pageIndex: pageIndex,
      width: page.width,
      height: page.height,
      pngBytes: await page.toPng(),
    );
  }
}

final class PlatformNotePdfFileSaver implements NotePdfFileSaver {
  const PlatformNotePdfFileSaver();

  @override
  Future<NotePdfSaveOutcome> save(
    Uint8List pdfBytes, {
    required String suggestedName,
  }) async {
    final filename = safePdfFilename(suggestedName);
    final location = await getSaveLocation(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'PDF',
          extensions: ['pdf'],
          mimeTypes: ['application/pdf'],
          uniformTypeIdentifiers: ['com.adobe.pdf'],
        ),
      ],
      suggestedName: filename,
      confirmButtonText: '保存',
      canCreateDirectories: true,
    );
    if (location == null) {
      return NotePdfSaveOutcome.cancelled;
    }
    final target = location.path.toLowerCase().endsWith('.pdf')
        ? location.path
        : '${location.path}.pdf';
    await XFile.fromData(
      pdfBytes,
      mimeType: 'application/pdf',
      name: filename,
    ).saveTo(target);
    return NotePdfSaveOutcome.saved;
  }
}

String safePdfFilename(String value) {
  var sanitized = value
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .trim()
      .replaceAll(RegExp(r'[ .]+$'), '');
  if (sanitized.toLowerCase().endsWith('.pdf')) {
    sanitized = sanitized.substring(0, sanitized.length - 4);
  }
  if (sanitized.isEmpty || sanitized == '.' || sanitized == '..') {
    sanitized = '未命名';
  }
  return '$sanitized.pdf';
}
