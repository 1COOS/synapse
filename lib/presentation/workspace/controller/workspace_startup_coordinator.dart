import 'dart:async';

import '../../../domain/vault/vault_resource.dart';
import '../../../infrastructure/config/synapse_settings.dart';
import '../../../infrastructure/config/vault_location_store.dart';
import '../../../infrastructure/vault/vault_backend.dart';
import '../state/note_save_coordinator.dart';
import '../state/split_workspace_controller.dart';
import '../state/workspace_mutation_barrier.dart';
import 'workspace_dependencies.dart';
import 'workspace_resource_coordinator.dart';
import 'workspace_runtime.dart';
import 'workspace_runtime_manager.dart';
import 'workspace_settings_dialog_model.dart';
import 'workspace_state.dart';

typedef RuntimeSnapshotInstaller =
    void Function(
      WorkspaceResourceSnapshot snapshot, {
      required String message,
    });

final class WorkspaceStartupCoordinator {
  WorkspaceStartupCoordinator({
    required this.dependencies,
    required this.runtimes,
    required this.resources,
    required this.saves,
    required this.mutations,
    required this.splits,
    required this.readState,
    required this.publishState,
    required this.setMessage,
    required this.replaceRuntimeSnapshot,
    required this.beginOperation,
    required this.replaceOperation,
    required this.endOperation,
    required this.isDisposed,
  });

  final WorkspaceDependencies dependencies;
  final WorkspaceRuntimeManager runtimes;
  final WorkspaceResourceCoordinator resources;
  final NoteSaveCoordinator saves;
  final WorkspaceMutationBarrier mutations;
  final SplitWorkspaceController splits;
  final WorkspaceState Function() readState;
  final void Function(WorkspaceState state) publishState;
  final void Function(String message) setMessage;
  final RuntimeSnapshotInstaller replaceRuntimeSnapshot;
  final bool Function(WorkspaceOperation operation) beginOperation;
  final void Function(WorkspaceOperation operation) replaceOperation;
  final void Function(WorkspaceOperation operation) endOperation;
  final bool Function() isDisposed;

  SynapseSettings _settings = SynapseSettings.defaults;
  SynapseSettings? _loadedSettingsBaseline;
  Future<void> _settingsPersistenceTail = Future<void>.value();
  Object? _startupToken;
  Future<SynapseSettings>? _startupSettingsFuture;
  Object? _startupSettingsError;

  SynapseSettings get settings => _settings;

  SynapseSettings get settingsForEditing =>
      _loadedSettingsBaseline ?? _settings;

  bool get hasLoadedSettingsBaseline => _loadedSettingsBaseline != null;

  NoteMode get preferredNoteMode =>
      _settings.preferences.defaultNoteMode == WorkspaceDefaultNoteMode.source
      ? NoteMode.source
      : NoteMode.reading;

  bool get hasUsableAiProvider =>
      dependencies.usesInjectedAiProvider ||
      _settings.providerConfig.isComplete;

  bool get semanticSearchEnabled => _semanticSearchEnabledFor(_settings);

  String get semanticSearchFallbackMessage {
    if (!_settings.preferences.semanticSearchEnabled) {
      return '语义搜索已关闭，仅使用全文搜索';
    }
    return '未配置 Embedding，仅使用全文搜索';
  }

  String modelConfigurationMessage() {
    if (dependencies.usesInjectedAiProvider) {
      return '';
    }
    final store = dependencies.resolvedSettingsStore();
    if (store != null && !store.supportsPersistence) {
      return store.unavailableMessage;
    }
    final config = _settings.providerConfig;
    if (config.isComplete) {
      if (config.hasEmbeddingConfig) {
        return '模型设置已保存';
      }
      return '模型设置已保存；未配置 Embedding，语义搜索关闭';
    }
    return '请先在设置中配置模型';
  }

  Future<SynapseSettings> beginSettingsLoad() {
    final load = _loadSettings();
    _startupSettingsFuture = load;
    return load;
  }

  void startDirectoryStartup(Future<SynapseSettings> settingsLoad) {
    final startupToken = Object();
    _startupToken = startupToken;
    unawaited(_continueDirectoryStartup(startupToken, settingsLoad));
  }

  void installStartupRuntime() {
    if (dependencies.initialVault case final vault?) {
      _installRuntime(
        vault: vault,
        rootPath: null,
        label: dependencies.injectedVaultLabel,
      );
      return;
    }
    if (!dependencies.supportsDirectoryVault) {
      _installRuntime(
        vault: dependencies.createDefaultVault(),
        rootPath: null,
        label: dependencies.defaultVaultLabel,
      );
    }
  }

  Future<String> applyStartupSettings(
    Future<SynapseSettings> settingsLoad,
  ) async {
    var message = '';
    try {
      final loadedSettings = await settingsLoad;
      _loadedSettingsBaseline = loadedSettings;
      _startupSettingsError = null;
      final current = runtimes.current;
      if (current != null && loadedSettings != _settings) {
        WorkspaceRuntime? candidate;
        try {
          candidate = _createRuntime(
            vault: current.vault,
            rootPath: current.rootPath,
            label: current.label,
            settings: loadedSettings,
          );
          runtimes.install(candidate);
          candidate = null;
          _settings = loadedSettings;
          splits.updateDefaultMode(preferredNoteMode);
        } catch (_) {
          candidate?.dispose(
            reportCleanupError: dependencies.cleanupErrorReporter,
          );
        }
      } else {
        _settings = loadedSettings;
      }
    } catch (error) {
      _startupSettingsError = error;
      message = '设置读取失败：$error';
    }
    splits.updateDefaultMode(preferredNoteMode);
    return message;
  }

  Future<SynapseSettings?> awaitSettingsForEditing() async {
    final loaded = await _awaitStartupSettings();
    if (loaded == null) {
      return null;
    }
    _loadedSettingsBaseline ??= loaded;
    return settingsForEditing;
  }

  Future<WorkspaceSettingsDialogModel?> settingsDialogModel() async {
    final initialSettings = hasLoadedSettingsBaseline
        ? settingsForEditing
        : await awaitSettingsForEditing();
    if (initialSettings == null || isDisposed()) {
      return null;
    }
    final store =
        dependencies.resolvedSettingsStore() ??
        await dependencies.settingsStore();
    if (isDisposed()) {
      return null;
    }
    return WorkspaceSettingsDialogModel(
      initialSettings: initialSettings,
      canSave: store.supportsPersistence,
      unavailableMessage: store.unavailableMessage,
    );
  }

  Future<String> testProviderConfig(ProviderConfig config) async {
    if (isDisposed()) {
      throw StateError('Workspace controller is disposed.');
    }
    final result = await dependencies.testProviderConfig(config);
    if (isDisposed()) {
      throw StateError('Workspace controller is disposed.');
    }
    return result;
  }

  Future<WorkspaceActionResult> chooseVault() async {
    final currentOperation = readState().activeOperation;
    if (currentOperation != null &&
        currentOperation != WorkspaceOperation.editorCommand) {
      return WorkspaceActionResult.busy;
    }
    final ownsOperation =
        currentOperation == null ||
        currentOperation == WorkspaceOperation.editorCommand;
    if (currentOperation == WorkspaceOperation.editorCommand) {
      replaceOperation(WorkspaceOperation.vaultSwitch);
    } else if (ownsOperation) {
      beginOperation(WorkspaceOperation.vaultSwitch);
    }
    WorkspaceRuntime? candidate;
    try {
      final location = await _pickVaultLocation();
      if (location == null) {
        return WorkspaceActionResult.cancelled;
      }
      final baseline = await _awaitStartupSettings();
      if (baseline == null) {
        return WorkspaceActionResult.aborted;
      }
      _startupToken = null;
      final flush = await saves.flushAll();
      if (!flush.succeeded) {
        final error = flush.results.isEmpty ? '未知错误' : flush.results.last.error;
        setMessage('笔记保存失败：$error');
        return WorkspaceActionResult.aborted;
      }
      final nextSettings = baseline.copyWith(vaultLocation: location);
      candidate = _createRuntime(
        vault: dependencies.createVault(location.rootPath),
        rootPath: location.rootPath,
        label: dependencies.formatVaultLabel(location.rootPath),
        settings: nextSettings,
      );
      final snapshot = await resources.loadDetachedRuntime(candidate);
      await _persistSettings(nextSettings);
      saves.resetAfterReload();
      mutations.resetAfterReload();
      runtimes.install(candidate);
      candidate = null;
      _settings = nextSettings;
      _loadedSettingsBaseline = nextSettings;
      replaceRuntimeSnapshot(snapshot, message: '仓库已打开');
      return WorkspaceActionResult.committed;
    } catch (error) {
      candidate?.dispose(reportCleanupError: dependencies.cleanupErrorReporter);
      setMessage('仓库位置读取失败：$error');
      return WorkspaceActionResult.failed;
    } finally {
      if (ownsOperation) {
        endOperation(WorkspaceOperation.vaultSwitch);
      }
    }
  }

  Future<WorkspaceActionResult> updateSettings(SynapseSettings settings) async {
    final currentOperation = readState().activeOperation;
    if (currentOperation != null &&
        currentOperation != WorkspaceOperation.editorCommand) {
      return WorkspaceActionResult.busy;
    }
    final ownsOperation =
        currentOperation == null ||
        currentOperation == WorkspaceOperation.editorCommand;
    if (currentOperation == WorkspaceOperation.editorCommand) {
      replaceOperation(WorkspaceOperation.settings);
    } else if (ownsOperation) {
      beginOperation(WorkspaceOperation.settings);
    }
    _startupToken = null;
    WorkspaceRuntime? candidate;
    try {
      final current = runtimes.current;
      if (current != null) {
        candidate = _createRuntime(
          vault: current.vault,
          rootPath: current.rootPath,
          label: current.label,
          settings: settings,
        );
      }
      await _persistSettings(settings);
      if (candidate != null) {
        runtimes.install(candidate);
        candidate = null;
      }
      _settings = settings;
      _loadedSettingsBaseline = settings;
      splits.updateDefaultMode(preferredNoteMode);
      final currentState = readState();
      publishState(
        currentState.copyWith(
          settings: settings,
          splitRoot: splits.root,
          focusedPaneId: splits.focusedPaneId,
          message: modelConfigurationMessage(),
        ),
      );
      return WorkspaceActionResult.committed;
    } catch (error) {
      candidate?.dispose(reportCleanupError: dependencies.cleanupErrorReporter);
      setMessage('设置保存失败：$error');
      return WorkspaceActionResult.failed;
    } finally {
      if (ownsOperation) {
        endOperation(WorkspaceOperation.settings);
      }
    }
  }

  void dispose() {
    _startupToken = null;
  }

  Future<SynapseSettings> _loadSettings() async {
    return (await dependencies.settingsStore()).load();
  }

  Future<SynapseSettings?> _awaitStartupSettings() async {
    final future = _startupSettingsFuture;
    if (future == null) {
      return _startupSettingsError == null
          ? _loadedSettingsBaseline ?? _settings
          : null;
    }
    try {
      return await future;
    } catch (error) {
      _startupSettingsError = error;
      setMessage('设置读取失败：$error');
      return null;
    }
  }

  Future<VaultLocation?> _pickVaultLocation() async {
    try {
      return await dependencies.pickVaultLocation();
    } catch (error) {
      setMessage('仓库位置选择失败：$error');
      return null;
    }
  }

  Future<void> _continueDirectoryStartup(
    Object startupToken,
    Future<SynapseSettings> settingsLoad,
  ) async {
    WorkspaceRuntime? candidate;
    var settingsLoaded = false;
    try {
      final settings = await settingsLoad;
      settingsLoaded = true;
      if (!_isStartupCurrent(startupToken)) {
        return;
      }
      _settings = settings;
      _loadedSettingsBaseline = settings;
      _startupSettingsError = null;
      await Future<void>.delayed(Duration.zero);
      if (!_isStartupCurrent(startupToken)) {
        return;
      }
      final location = settings.vaultLocation;
      if (location == null) {
        publishState(
          readState().copyWith(settings: settings, message: '请选择仓库位置'),
        );
        return;
      }
      final restored = await dependencies.restoreVaultAccess(location);
      if (!_isStartupCurrent(startupToken)) {
        return;
      }
      final store = await dependencies.settingsStore();
      if (!await store.vaultExists(restored)) {
        if (_isStartupCurrent(startupToken)) {
          publishState(
            readState().copyWith(
              settings: settings,
              message: '仓库位置不可用：${restored.rootPath}',
            ),
          );
        }
        return;
      }
      candidate = _createRuntime(
        vault: dependencies.createVault(restored.rootPath),
        rootPath: restored.rootPath,
        label: dependencies.formatVaultLabel(restored.rootPath),
        settings: settings,
      );
      final snapshot = await resources.loadDetachedRuntime(candidate);
      if (!_isStartupCurrent(startupToken)) {
        candidate.dispose(
          reportCleanupError: dependencies.cleanupErrorReporter,
        );
        candidate = null;
        return;
      }
      final restoredSettings = settings.copyWith(vaultLocation: restored);
      await _persistSettings(restoredSettings);
      if (!_isStartupCurrent(startupToken)) {
        candidate.dispose(
          reportCleanupError: dependencies.cleanupErrorReporter,
        );
        candidate = null;
        return;
      }
      runtimes.install(candidate);
      candidate = null;
      _settings = restoredSettings;
      _loadedSettingsBaseline = restoredSettings;
      replaceRuntimeSnapshot(snapshot, message: '仓库已打开');
    } catch (error) {
      await Future<void>.delayed(Duration.zero);
      candidate?.dispose(reportCleanupError: dependencies.cleanupErrorReporter);
      if (_isStartupCurrent(startupToken)) {
        if (!settingsLoaded) {
          _startupSettingsError = error;
        }
        final prefix = settingsLoaded ? '仓库位置读取失败' : '设置读取失败';
        setMessage('$prefix：$error');
      }
    } finally {
      if (_isStartupCurrent(startupToken)) {
        _startupToken = null;
      }
    }
  }

  bool _isStartupCurrent(Object token) {
    return !isDisposed() && identical(_startupToken, token);
  }

  void _installRuntime({
    required VaultBackend vault,
    required String? rootPath,
    required String label,
  }) {
    runtimes.install(
      _createRuntime(
        vault: vault,
        rootPath: rootPath,
        label: label,
        settings: _settings,
      ),
    );
  }

  WorkspaceRuntime _createRuntime({
    required VaultBackend vault,
    required String? rootPath,
    required String label,
    required SynapseSettings settings,
  }) {
    return dependencies.createRuntime(
      vault: vault,
      aiProvider: dependencies.createAiProvider(settings.providerConfig),
      semanticSearchEnabled: _semanticSearchEnabledFor(settings),
      rootPath: rootPath,
      label: label,
    );
  }

  Future<void> _persistSettings(SynapseSettings settings) {
    final operation = _settingsPersistenceTail.catchError((Object _) {}).then((
      _,
    ) async {
      final store = await dependencies.settingsStore();
      await store.save(settings);
    });
    _settingsPersistenceTail = operation.catchError((Object _) {});
    return operation;
  }

  bool _semanticSearchEnabledFor(SynapseSettings settings) {
    return settings.preferences.semanticSearchEnabled &&
        (dependencies.usesInjectedAiProvider ||
            settings.providerConfig.hasEmbeddingConfig);
  }
}
