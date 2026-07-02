import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:pasteboard/pasteboard.dart';

class ImportedImage {
  const ImportedImage({
    required this.filename,
    required this.mimeType,
    required this.bytes,
  });

  final String filename;
  final String mimeType;
  final List<int> bytes;
}

abstract class ImageInputService {
  Future<ImportedImage?> pickImage();

  Future<ImportedImage?> pasteImage();
}

class PlatformImageInputService implements ImageInputService {
  const PlatformImageInputService();

  @override
  Future<ImportedImage?> pickImage() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Images', extensions: ['png', 'jpg', 'jpeg', 'webp']),
      ],
    );
    if (file == null) {
      return null;
    }
    return ImportedImage(
      filename: file.name,
      mimeType: file.mimeType ?? _mimeTypeForName(file.name),
      bytes: await file.readAsBytes(),
    );
  }

  @override
  Future<ImportedImage?> pasteImage() async {
    final bytes = await Pasteboard.image;
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    return ImportedImage(
      filename: 'clipboard-${DateTime.now().millisecondsSinceEpoch}.png',
      mimeType: 'image/png',
      bytes: Uint8List.fromList(bytes),
    );
  }

  String _mimeTypeForName(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    return 'image/png';
  }
}
