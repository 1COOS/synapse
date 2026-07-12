import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/config/provider_config_store.dart';
import 'package:synapse/infrastructure/config/settings_store.dart';
import 'package:synapse/infrastructure/config/synapse_settings.dart';
import 'package:synapse/infrastructure/config/vault_location_store.dart';
import 'package:synapse/infrastructure/input/image_input_service.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';

const tinyPng = <int>[
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  1,
  8,
  6,
  0,
  0,
  0,
  31,
  21,
  196,
  137,
  0,
  0,
  0,
  10,
  73,
  68,
  65,
  84,
  120,
  156,
  99,
  0,
  1,
  0,
  0,
  5,
  0,
  1,
  13,
  10,
  45,
  180,
  0,
  0,
  0,
  0,
  73,
  69,
  78,
  68,
  174,
  66,
  96,
  130,
];

class FakeVaultLocationStore implements VaultLocationStore {
  FakeVaultLocationStore({
    this.loadedLocation,
    Set<String> existingPaths = const {},
  }) : existingPaths = {...existingPaths};

  VaultLocation? loadedLocation;
  final Set<String> existingPaths;
  final savedLocations = <VaultLocation>[];
  int loadCalls = 0;

  @override
  Future<VaultLocation?> load() async {
    loadCalls += 1;
    return loadedLocation;
  }

  @override
  Future<void> save(VaultLocation location) async {
    savedLocations.add(location);
    loadedLocation = location;
    existingPaths.add(location.rootPath);
  }

  @override
  Future<bool> exists(VaultLocation location) async {
    return existingPaths.contains(location.rootPath);
  }
}

class FakeSettingsStore implements SettingsStore {
  FakeSettingsStore({
    SynapseSettings initialSettings = SynapseSettings.defaults,
  }) : currentSettings = initialSettings;

  SynapseSettings currentSettings;
  final savedSettings = <SynapseSettings>[];

  @override
  bool get supportsPersistence => true;

  @override
  String get unavailableMessage => '';

  @override
  Future<SynapseSettings> load() async {
    return currentSettings;
  }

  @override
  Future<void> save(SynapseSettings settings) async {
    currentSettings = settings;
    savedSettings.add(settings);
  }

  @override
  Future<bool> vaultExists(VaultLocation location) async {
    return true;
  }
}

class CountingUpdateVaultBackend extends MemoryVaultBackend {
  CountingUpdateVaultBackend({super.seedExampleData});

  int updateCalls = 0;
  String? lastSavedMarkdown;

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) {
    updateCalls += 1;
    lastSavedMarkdown = markdown;
    return super.updateMarkdown(noteId: noteId, markdown: markdown);
  }
}

class FailingUpdateVaultBackend extends CountingUpdateVaultBackend {
  FailingUpdateVaultBackend({super.seedExampleData});

  bool failUpdates = false;

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) {
    if (failUpdates) {
      throw StateError('save failed');
    }
    return super.updateMarkdown(noteId: noteId, markdown: markdown);
  }
}

class RecordingUpdateVaultBackend extends MemoryVaultBackend {
  RecordingUpdateVaultBackend({
    required this.events,
    this.failingNoteId,
    super.seedExampleData,
  });

  final List<String> events;
  final String? failingNoteId;

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) {
    events.add('save:$noteId');
    if (noteId == failingNoteId) {
      throw StateError('save failed for $noteId');
    }
    return super.updateMarkdown(noteId: noteId, markdown: markdown);
  }
}

class DelayedUpdateVaultBackend extends MemoryVaultBackend {
  DelayedUpdateVaultBackend({super.seedExampleData});

  final updateStarted = Completer<void>();
  final _updateRelease = Completer<void>();
  final Map<String, VaultNoteContent> _synchronousReads = {};

  Future<void> makeReadSynchronous(String noteId) async {
    _synchronousReads[noteId] = await super.readNote(noteId);
  }

  void completeUpdate() {
    _updateRelease.complete();
  }

  @override
  Future<VaultNoteContent> readNote(String noteId) {
    final synchronous = _synchronousReads[noteId];
    if (synchronous != null) {
      return SynchronousFuture<VaultNoteContent>(synchronous);
    }
    return super.readNote(noteId);
  }

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) async {
    updateStarted.complete();
    await _updateRelease.future;
    return super.updateMarkdown(noteId: noteId, markdown: markdown);
  }
}

class GatedCloseVaultBackend extends MemoryVaultBackend {
  GatedCloseVaultBackend({
    required this.blockedNoteId,
    this.failingNoteId,
    super.seedExampleData,
  });

  final String blockedNoteId;
  final String? failingNoteId;
  final blockedUpdateStarted = Completer<void>();
  final _blockedUpdateRelease = Completer<void>();
  final List<String> updatedNoteIds = <String>[];

  void releaseBlockedUpdate() {
    if (!_blockedUpdateRelease.isCompleted) {
      _blockedUpdateRelease.complete();
    }
  }

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) async {
    updatedNoteIds.add(noteId);
    if (noteId == blockedNoteId && !_blockedUpdateRelease.isCompleted) {
      if (!blockedUpdateStarted.isCompleted) {
        blockedUpdateStarted.complete();
      }
      await _blockedUpdateRelease.future;
    }
    if (noteId == failingNoteId) {
      throw StateError('save failed for $noteId');
    }
    return super.updateMarkdown(noteId: noteId, markdown: markdown);
  }
}

class TitleSaveStructuralRaceVaultBackend extends MemoryVaultBackend {
  TitleSaveStructuralRaceVaultBackend({super.seedExampleData});

  final folderRenameStarted = Completer<void>();
  final titleRenameCompleted = Completer<void>();
  final _folderRenameRelease = Completer<void>();

  void releaseFolderRename() {
    if (!_folderRenameRelease.isCompleted) {
      _folderRenameRelease.complete();
    }
  }

  @override
  Future<VaultNote> renameNote({
    required String noteId,
    required String title,
  }) async {
    final renamed = await super.renameNote(noteId: noteId, title: title);
    if (noteId == 'Alpha.md' && !titleRenameCompleted.isCompleted) {
      titleRenameCompleted.complete();
    }
    return renamed;
  }

  @override
  Future<VaultResourceNode> renameFolder({
    required String folderPath,
    required String title,
  }) async {
    if (!folderRenameStarted.isCompleted) {
      folderRenameStarted.complete();
    }
    await _folderRenameRelease.future;
    return super.renameFolder(folderPath: folderPath, title: title);
  }
}

class DelayedDeleteNoteVaultBackend extends MemoryVaultBackend {
  DelayedDeleteNoteVaultBackend({super.seedExampleData});

  final deleteStarted = Completer<void>();
  final _deleteRelease = Completer<void>();
  final List<String> updatedNoteIds = <String>[];

  void completeDelete() {
    if (!_deleteRelease.isCompleted) {
      _deleteRelease.complete();
    }
  }

  @override
  Future<void> deleteNote(String noteId) async {
    if (!deleteStarted.isCompleted) {
      deleteStarted.complete();
    }
    await _deleteRelease.future;
    return super.deleteNote(noteId);
  }

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) async {
    updatedNoteIds.add(noteId);
    return super.updateMarkdown(noteId: noteId, markdown: markdown);
  }
}

class DelayedRenameFolderVaultBackend extends MemoryVaultBackend {
  DelayedRenameFolderVaultBackend({super.seedExampleData});

  final renameStarted = Completer<void>();
  final _renameRelease = Completer<void>();

  void completeRename() {
    if (!_renameRelease.isCompleted) {
      _renameRelease.complete();
    }
  }

  @override
  Future<VaultResourceNode> renameFolder({
    required String folderPath,
    required String title,
  }) async {
    if (!renameStarted.isCompleted) {
      renameStarted.complete();
    }
    await _renameRelease.future;
    return super.renameFolder(folderPath: folderPath, title: title);
  }
}

class DelayedMoveNoteVaultBackend extends MemoryVaultBackend {
  DelayedMoveNoteVaultBackend({super.seedExampleData});

  final moveStarted = Completer<void>();
  final _moveRelease = Completer<void>();

  void completeMove() {
    if (!_moveRelease.isCompleted) {
      _moveRelease.complete();
    }
  }

  @override
  Future<VaultNote> moveNote({
    required String noteId,
    required String parentPath,
  }) async {
    if (!moveStarted.isCompleted) {
      moveStarted.complete();
    }
    await _moveRelease.future;
    return super.moveNote(noteId: noteId, parentPath: parentPath);
  }
}

class ListingFailureVaultBackend extends MemoryVaultBackend {
  ListingFailureVaultBackend({super.seedExampleData});

  @override
  Future<List<VaultResourceNode>> listResources() {
    throw const FileSystemException(
      'Directory listing failed',
      '/vault/locked',
    );
  }
}

class FakeImageInputService implements ImageInputService {
  FakeImageInputService({this.pickedImage, this.pastedImage});

  final ImportedImage? pickedImage;
  final ImportedImage? pastedImage;
  int pickCalls = 0;
  int pasteCalls = 0;

  @override
  Future<ImportedImage?> pickImage() async {
    pickCalls += 1;
    return pickedImage;
  }

  @override
  Future<bool> canPasteImage() async {
    return pastedImage != null;
  }

  @override
  Future<ImportedImage?> pasteImage() async {
    pasteCalls += 1;
    return pastedImage;
  }
}

class FakeProviderConfigStore implements ProviderConfigStore {
  FakeProviderConfigStore();

  ProviderConfig? savedConfig;

  @override
  bool get supportsSecureApiKey => true;

  @override
  String get unavailableMessage => '';

  @override
  Future<ProviderConfig?> load() async {
    return null;
  }

  @override
  Future<void> save(ProviderConfig config) async {
    savedConfig = config;
  }
}
