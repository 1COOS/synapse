import 'dart:async';

import '../../../domain/vault/vault_migration.dart';
import '../../../infrastructure/config/settings_store.dart';
import '../../../infrastructure/config/synapse_settings.dart';
import '../../../infrastructure/config/vault_access_gateway.dart';
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
      VaultMigrationRequirement? migrationRequirement,
    });
typedef WorkspacePostCommitFailureHandler =
    void Function(Object error, StackTrace stackTrace);

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
    required this.scheduleBackgroundSearchIndex,
    required this.postCommitFailure,
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
  final void Function() scheduleBackgroundSearchIndex;
  final WorkspacePostCommitFailureHandler postCommitFailure;
  final bool Function(WorkspaceOperation operation) beginOperation;
  final void Function(WorkspaceOperation operation) replaceOperation;
  final void Function(WorkspaceOperation operation) endOperation;
  final bool Function() isDisposed;

  SynapseSettings _settings = SynapseSettings.defaults;
  SynapseSettings? _loadedSettingsBaseline;
  Future<void> _settingsPersistenceTail = Future<void>.value();
  Object? _startupToken;
  Object? _vaultIntent;
  VaultAccessLease? _activeVaultLease;
  Future<SettingsLoadResult>? _startupSettingsFuture;
  Object? _startupSettingsError;

  SynapseSettings get settings => _settings;

  SynapseSettings get _settingsForEditing =>
      _loadedSettingsBaseline ?? _settings;

  bool get _hasLoadedSettingsBaseline => _loadedSettingsBaseline != null;

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

  Future<SettingsLoadResult> beginSettingsLoad() {
    final load = _loadSettings();
    _startupSettingsFuture = load;
    return load;
  }

  void startDirectoryStartup(Future<SettingsLoadResult> settingsLoad) {
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
    Future<SettingsLoadResult> settingsLoad,
  ) async {
    var message = '';
    try {
      final loadResult = await settingsLoad;
      final loadedSettings = loadResult.settings;
      message = loadResult.recoveryMessage;
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

  Future<SynapseSettings?> _awaitSettingsForEditing() async {
    final loaded = await _awaitStartupSettings();
    if (loaded == null) {
      return null;
    }
    if (_startupSettingsError == null) {
      _loadedSettingsBaseline ??= loaded;
      return _settingsForEditing;
    }
    return _settings;
  }

  Future<WorkspaceSettingsDialogModel?> settingsDialogModel() async {
    final initialSettings = _hasLoadedSettingsBaseline
        ? _settingsForEditing
        : await _awaitSettingsForEditing();
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
    _VaultAccessCandidate? candidateAccess;
    VaultAccessLease? previousLease;
    var runtimeCommitted = false;
    var leaseOwnershipCommitted = false;
    var postCommitFailed = false;
    try {
      candidateAccess = await _pickVaultAccess();
      if (candidateAccess == null) {
        return WorkspaceActionResult.cancelled;
      }
      final intent = Object();
      _vaultIntent = intent;
      _startupToken = null;
      await _invalidateEditorContextsAndWaitForMutations();
      if (!_isVaultIntentCurrent(intent)) {
        return WorkspaceActionResult.aborted;
      }
      final baseline = await _awaitStartupSettings();
      if (baseline == null || _startupSettingsError != null) {
        return WorkspaceActionResult.aborted;
      }
      if (!_isVaultIntentCurrent(intent)) {
        return WorkspaceActionResult.aborted;
      }
      final flush = await saves.flushAll();
      if (!_isVaultIntentCurrent(intent)) {
        return WorkspaceActionResult.aborted;
      }
      if (!flush.succeeded) {
        final error = flush.results.isEmpty ? '未知错误' : flush.results.last.error;
        setMessage('笔记保存失败：$error');
        return WorkspaceActionResult.aborted;
      }
      final location = candidateAccess.location;
      final nextSettings = baseline.copyWith(vaultLocation: location);
      candidate = _createRuntime(
        vault: dependencies.createVault(location.rootPath),
        rootPath: location.rootPath,
        label: dependencies.formatVaultLabel(location.rootPath),
        settings: nextSettings,
      );
      final prepared = await _prepareRuntime(candidate);
      if (!_isVaultIntentCurrent(intent)) {
        return WorkspaceActionResult.aborted;
      }
      await _persistSettings(nextSettings, preserveApiKey: true);
      if (!_isVaultIntentCurrent(intent)) {
        return WorkspaceActionResult.aborted;
      }
      _startupSettingsError = null;
      saves.resetAfterReload();
      mutations.resetAfterReload();
      previousLease = _activeVaultLease;
      runtimes.install(candidate);
      candidate = null;
      runtimeCommitted = true;
      if (isDisposed()) {
        previousLease = null;
      } else {
        _activeVaultLease = candidateAccess.lease;
        leaseOwnershipCommitted = true;
        candidateAccess = null;
      }
      _settings = nextSettings;
      _loadedSettingsBaseline = nextSettings;
      replaceRuntimeSnapshot(
        prepared.snapshot,
        message: prepared.migrationRequirement == null
            ? '仓库已打开'
            : '检测到旧版笔记标识，请确认迁移后继续编辑',
        migrationRequirement: prepared.migrationRequirement,
      );
      return WorkspaceActionResult.committed;
    } catch (error, stackTrace) {
      if (runtimeCommitted) {
        postCommitFailed = true;
        _reportPostCommitFailure(error, stackTrace);
        return WorkspaceActionResult.committed;
      }
      setMessage('仓库位置读取失败：$error');
      return WorkspaceActionResult.failed;
    } finally {
      candidate?.dispose(reportCleanupError: dependencies.cleanupErrorReporter);
      if (!leaseOwnershipCommitted) {
        await _releaseLease(candidateAccess?.lease);
      }
      if (runtimeCommitted) {
        await _releaseLease(previousLease, reportMessage: !postCommitFailed);
      }
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
      await _invalidateEditorContextsAndWaitForMutations();
      final current = runtimes.current;
      if (current != null) {
        candidate = _createRuntime(
          vault: current.vault,
          rootPath: current.rootPath,
          label: current.label,
          settings: settings,
        );
      }
      final apiKeyChanged =
          settings.providerConfig.apiKey.trim() !=
          _settingsForEditing.providerConfig.apiKey.trim();
      await _persistSettings(settings, preserveApiKey: !apiKeyChanged);
      if (candidate != null) {
        runtimes.install(candidate);
        candidate = null;
      }
      _settings = settings;
      _loadedSettingsBaseline = settings;
      _startupSettingsError = null;
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
      if (!currentState.requiresMigration) {
        scheduleBackgroundSearchIndex();
      }
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
    _vaultIntent = null;
    final activeLease = _activeVaultLease;
    _activeVaultLease = null;
    unawaited(_releaseLease(activeLease));
  }

  Future<SettingsLoadResult> _loadSettings() async {
    return (await dependencies.settingsStore()).loadResult();
  }

  Future<SynapseSettings?> _awaitStartupSettings() async {
    final future = _startupSettingsFuture;
    if (future == null) {
      return _loadedSettingsBaseline ?? _settings;
    }
    try {
      return (await future).settings;
    } catch (error) {
      _startupSettingsError = error;
      setMessage('设置读取失败：$error');
      return _loadedSettingsBaseline ?? _settings;
    }
  }

  Future<_VaultAccessCandidate?> _pickVaultAccess() async {
    try {
      if (dependencies.pickUsesVaultAccessGateway) {
        final lease = await dependencies.vaultAccessGateway!.pick();
        return lease == null
            ? null
            : _VaultAccessCandidate(location: lease.location, lease: lease);
      }
      final location = await dependencies.pickVaultLocation();
      return location == null
          ? null
          : _VaultAccessCandidate(location: location);
    } catch (error) {
      setMessage('仓库位置选择失败：$error');
      return null;
    }
  }

  Future<void> _continueDirectoryStartup(
    Object startupToken,
    Future<SettingsLoadResult> settingsLoad,
  ) async {
    WorkspaceRuntime? candidate;
    _VaultAccessCandidate? candidateAccess;
    VaultAccessLease? previousLease;
    var runtimeCommitted = false;
    var leaseOwnershipCommitted = false;
    var postCommitFailed = false;
    var settingsLoaded = false;
    try {
      final loadResult = await settingsLoad;
      final settings = loadResult.settings;
      final recoveryMessage = loadResult.recoveryMessage;
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
          readState().copyWith(
            settings: settings,
            message: _startupMessage(recoveryMessage, fallback: '请选择仓库位置'),
          ),
        );
        return;
      }
      candidateAccess = await _restoreVaultAccess(location);
      if (!_isStartupCurrent(startupToken)) {
        return;
      }
      final restored = candidateAccess.location;
      final store = await dependencies.settingsStore();
      if (!await store.vaultExists(restored)) {
        if (_isStartupCurrent(startupToken)) {
          publishState(
            readState().copyWith(
              settings: settings,
              message: _startupMessage(
                recoveryMessage,
                fallback: '仓库位置不可用：${restored.rootPath}',
              ),
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
      final prepared = await _prepareRuntime(candidate);
      if (!_isStartupCurrent(startupToken)) {
        candidate.dispose(
          reportCleanupError: dependencies.cleanupErrorReporter,
        );
        candidate = null;
        return;
      }
      final restoredSettings = settings.copyWith(vaultLocation: restored);
      await _persistSettings(restoredSettings, preserveApiKey: true);
      if (!_isStartupCurrent(startupToken)) {
        candidate.dispose(
          reportCleanupError: dependencies.cleanupErrorReporter,
        );
        candidate = null;
        return;
      }
      previousLease = _activeVaultLease;
      runtimes.install(candidate);
      candidate = null;
      runtimeCommitted = true;
      if (isDisposed()) {
        previousLease = null;
      } else {
        _activeVaultLease = candidateAccess.lease;
        leaseOwnershipCommitted = true;
        candidateAccess = null;
      }
      _settings = restoredSettings;
      _loadedSettingsBaseline = restoredSettings;
      replaceRuntimeSnapshot(
        prepared.snapshot,
        message: prepared.migrationRequirement == null
            ? _startupMessage(recoveryMessage, fallback: '仓库已打开')
            : _startupMessage(
                recoveryMessage,
                fallback: '检测到旧版笔记标识，请确认迁移后继续编辑',
              ),
        migrationRequirement: prepared.migrationRequirement,
      );
    } catch (error, stackTrace) {
      if (runtimeCommitted) {
        postCommitFailed = true;
        _reportPostCommitFailure(error, stackTrace);
        return;
      }
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
      if (!leaseOwnershipCommitted) {
        await _releaseLease(candidateAccess?.lease);
      }
      if (runtimeCommitted) {
        await _releaseLease(previousLease, reportMessage: !postCommitFailed);
      }
      if (_isStartupCurrent(startupToken)) {
        _startupToken = null;
      }
    }
  }

  Future<_PreparedRuntimeSnapshot> _prepareRuntime(
    WorkspaceRuntime runtime,
  ) async {
    final vault = runtime.vault;
    if (vault is VaultMigrationBackend) {
      final requirement = await (vault as VaultMigrationBackend)
          .inspectMigration();
      if (requirement != null) {
        return _PreparedRuntimeSnapshot(
          snapshot: WorkspaceResourceSnapshot(
            resources: requirement.previewResources,
            selectedResource: null,
            note: null,
            proposals: const [],
          ),
          migrationRequirement: requirement,
        );
      }
    }
    return _PreparedRuntimeSnapshot(
      snapshot: await resources.loadDetachedRuntime(runtime),
      migrationRequirement: null,
    );
  }

  bool _isStartupCurrent(Object token) {
    return !isDisposed() && identical(_startupToken, token);
  }

  bool _isVaultIntentCurrent(Object intent) {
    return !isDisposed() && identical(_vaultIntent, intent);
  }

  Future<_VaultAccessCandidate> _restoreVaultAccess(
    VaultLocation location,
  ) async {
    final bookmark = location.bookmarkBase64?.trim();
    if (dependencies.restoreUsesVaultAccessGateway &&
        bookmark != null &&
        bookmark.isNotEmpty) {
      final lease = await dependencies.vaultAccessGateway!.restore(location);
      return _VaultAccessCandidate(location: lease.location, lease: lease);
    }
    return _VaultAccessCandidate(
      location: await dependencies.restoreVaultAccess(location),
    );
  }

  Future<void> _releaseLease(
    VaultAccessLease? lease, {
    bool reportMessage = false,
  }) async {
    if (lease == null) {
      return;
    }
    final gateway = dependencies.vaultAccessGateway;
    if (gateway == null) {
      return;
    }
    try {
      await gateway.release(lease);
    } catch (error, stackTrace) {
      try {
        dependencies.cleanupErrorReporter(error, stackTrace);
      } catch (_) {
        // Cleanup reporting must not surface an unhandled Future error.
      }
      if (reportMessage && !isDisposed()) {
        setMessage('仓库已打开；旧仓库访问清理失败：$error');
      }
    }
  }

  void _reportPostCommitFailure(Object error, StackTrace stackTrace) {
    try {
      postCommitFailure(error, stackTrace);
    } catch (reportError, reportStackTrace) {
      try {
        dependencies.cleanupErrorReporter(reportError, reportStackTrace);
      } catch (_) {
        // Reporting failure cannot change committed runtime or lease ownership.
      }
    }
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

  Future<void> _persistSettings(
    SynapseSettings settings, {
    bool preserveApiKey = false,
  }) {
    final operation = _settingsPersistenceTail.catchError((Object _) {}).then((
      _,
    ) async {
      final store = await dependencies.settingsStore();
      if (preserveApiKey) {
        await store.savePreservingApiKey(settings);
      } else {
        await store.save(settings);
      }
    });
    _settingsPersistenceTail = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _invalidateEditorContextsAndWaitForMutations() async {
    runtimes.invalidateContextGeneration();
    await mutations.waitForIdle();
  }

  bool _semanticSearchEnabledFor(SynapseSettings settings) {
    return settings.preferences.semanticSearchEnabled &&
        (dependencies.usesInjectedAiProvider ||
            settings.providerConfig.hasEmbeddingConfig);
  }

  String _startupMessage(String recoveryMessage, {required String fallback}) {
    if (recoveryMessage.isEmpty) {
      return fallback;
    }
    if (fallback == '仓库已打开') {
      return recoveryMessage;
    }
    return '$recoveryMessage；$fallback';
  }
}

final class _PreparedRuntimeSnapshot {
  const _PreparedRuntimeSnapshot({
    required this.snapshot,
    required this.migrationRequirement,
  });

  final WorkspaceResourceSnapshot snapshot;
  final VaultMigrationRequirement? migrationRequirement;
}

final class _VaultAccessCandidate {
  const _VaultAccessCandidate({required this.location, this.lease});

  final VaultLocation location;
  final VaultAccessLease? lease;
}
