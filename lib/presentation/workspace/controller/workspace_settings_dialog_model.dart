import '../../../application/settings/synapse_settings.dart';
import '../../../infrastructure/config/settings_store.dart';

enum WorkspaceSettingsSaveStatus { committed, busy, failed }

final class WorkspaceSettingsSaveResult {
  const WorkspaceSettingsSaveResult({
    required this.status,
    required this.message,
    this.didWrite = false,
  });

  const WorkspaceSettingsSaveResult.committed({
    this.message = '设置已保存',
    this.didWrite = true,
  }) : status = WorkspaceSettingsSaveStatus.committed;

  const WorkspaceSettingsSaveResult.busy({this.message = '正在执行其他操作，请稍后重试。'})
    : status = WorkspaceSettingsSaveStatus.busy,
      didWrite = false;

  const WorkspaceSettingsSaveResult.failed({required this.message})
    : status = WorkspaceSettingsSaveStatus.failed,
      didWrite = false;

  final WorkspaceSettingsSaveStatus status;
  final String message;
  final bool didWrite;

  bool get committed => status == WorkspaceSettingsSaveStatus.committed;
}

final class WorkspaceSettingsDialogModel {
  const WorkspaceSettingsDialogModel({
    required this.initialSettings,
    required this.canEdit,
    required this.canChooseVault,
    required this.canRevealVault,
    required this.isWebPreview,
    required this.usesInjectedAiProvider,
    required this.vaultRootPath,
    required this.applicationMetadata,
    required this.storageInfo,
    required this.unavailableMessage,
  });

  final SynapseSettings initialSettings;
  final bool canEdit;
  final bool canChooseVault;
  final bool canRevealVault;
  final bool isWebPreview;
  final bool usesInjectedAiProvider;
  final String? vaultRootPath;
  final ApplicationMetadata applicationMetadata;
  final SettingsStorageInfo storageInfo;
  final String unavailableMessage;

  bool get canSave => canEdit;
}
