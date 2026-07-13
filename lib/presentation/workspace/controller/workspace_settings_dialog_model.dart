import '../../../infrastructure/config/synapse_settings.dart';

final class WorkspaceSettingsDialogModel {
  const WorkspaceSettingsDialogModel({
    required this.initialSettings,
    required this.canSave,
    required this.unavailableMessage,
  });

  final SynapseSettings initialSettings;
  final bool canSave;
  final String unavailableMessage;
}
