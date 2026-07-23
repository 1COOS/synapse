import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText, VerticalDivider;
import 'package:flutter/services.dart';

import '../../../application/settings/synapse_settings.dart';
import '../../workspace/controller/workspace_settings_dialog_model.dart';
import '../../workspace/controller/workspace_state.dart';
import 'workspace_controls.dart';
import 'workspace_theme.dart';

part 'workspace_settings_draft_controller.dart';
part 'workspace_settings_sections.dart';

typedef ModelCapabilityTester =
    Future<String> Function(ProviderConfig config, ModelCapability capability);
typedef WorkspaceSettingsSaver =
    Future<WorkspaceSettingsSaveResult> Function(SynapseSettings settings);
typedef WorkspaceVaultSwitcher = Future<WorkspaceActionResult> Function();

enum _SettingsSection {
  general('通用', CupertinoIcons.slider_horizontal_3),
  models('AI 模型', CupertinoIcons.sparkles),
  search('搜索', CupertinoIcons.search),
  appearance('外观', CupertinoIcons.paintbrush),
  vault('仓库', CupertinoIcons.folder),
  about('关于', CupertinoIcons.info_circle);

  const _SettingsSection(this.label, this.icon);

  final String label;
  final IconData icon;
}

enum _VaultDirtyDecision { saveAndContinue, discardAndContinue, cancel }

class WorkspaceSettingsSheet extends StatefulWidget {
  const WorkspaceSettingsSheet({
    super.key,
    required this.model,
    required this.onSave,
    required this.onTestCapability,
    required this.onChooseVault,
    required this.onRevealVault,
  });

  final WorkspaceSettingsDialogModel model;
  final WorkspaceSettingsSaver onSave;
  final ModelCapabilityTester onTestCapability;
  final WorkspaceVaultSwitcher onChooseVault;
  final Future<void> Function() onRevealVault;

  @override
  State<WorkspaceSettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<WorkspaceSettingsSheet> {
  late final _SettingsDraftController _draft;
  final ScrollController _contentScrollController = ScrollController();
  _SettingsSection _section = _SettingsSection.general;

  @override
  void initState() {
    super.initState();
    _draft = _SettingsDraftController(
      initialSettings: widget.model.initialSettings,
      canEdit: widget.model.canEdit,
      usesInjectedAiProvider: widget.model.usesInjectedAiProvider,
    );
  }

  @override
  void dispose() {
    _contentScrollController.dispose();
    _draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _draft,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final width = (size.width - 24).clamp(320.0, 820.0);
          final height = (size.height - 24).clamp(320.0, 690.0);
          final narrow = width < 620;
          return WorkspaceAppearanceScope(
            appearance: WorkspaceAppearance(
              accentColor: WorkspaceAppearance.accentColorFor(
                _draft.accentColor,
              ),
              noteFontSize: _draft.noteFontSize.toDouble(),
            ),
            child: CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () {
                  unawaited(_saveAndMaybeClose(closeOnSuccess: true));
                },
                const SingleActivator(
                  LogicalKeyboardKey.keyS,
                  control: true,
                ): () {
                  unawaited(_saveAndMaybeClose(closeOnSuccess: true));
                },
                const SingleActivator(LogicalKeyboardKey.escape): () {
                  unawaited(_requestClose());
                },
              },
              child: Focus(
                autofocus: true,
                child: Center(
                  child: CupertinoPopupSurface(
                    child: SizedBox(
                      width: width,
                      height: height,
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          color: workspaceSurfaceColor,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildHeader(),
                            if (widget.model.isWebPreview)
                              _buildReadOnlyBanner(),
                            if (narrow) _buildTopNavigation(),
                            Expanded(
                              child: narrow
                                  ? _buildContent()
                                  : Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        _buildSideNavigation(),
                                        const VerticalDivider(
                                          width: 1,
                                          thickness: 1,
                                          color: workspaceSoftLineColor,
                                        ),
                                        Expanded(child: _buildContent()),
                                      ],
                                    ),
                            ),
                            _buildFooter(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 10, 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: workspaceSoftLineColor)),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              '设置',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
          ),
          CupertinoButton(
            key: const Key('settings-close'),
            minimumSize: const Size(32, 32),
            padding: EdgeInsets.zero,
            onPressed: _draft.isSaving ? null : _requestClose,
            child: const Icon(CupertinoIcons.xmark, size: 17),
          ),
        ],
      ),
    );
  }

  Widget _buildReadOnlyBanner() {
    return Container(
      key: const Key('settings-web-read-only-banner'),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      color: CupertinoColors.systemYellow.withValues(alpha: 0.16),
      child: const Row(
        children: [
          Icon(CupertinoIcons.info_circle, size: 16),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '桌面端配置、Web 仅预览',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSideNavigation() {
    return Container(
      width: 164,
      color: workspaceSecondarySurfaceColor,
      padding: const EdgeInsets.all(12),
      child: ListView(
        primary: false,
        children: [
          for (final section in _SettingsSection.values)
            _SettingsNavButton(
              key: Key('settings-nav-${section.name}'),
              section: section,
              selected: section == _section,
              onPressed: () => setState(() => _section = section),
            ),
        ],
      ),
    );
  }

  Widget _buildTopNavigation() {
    return Container(
      key: const Key('settings-top-navigation'),
      height: 48,
      decoration: const BoxDecoration(
        color: workspaceSecondarySurfaceColor,
        border: Border(bottom: BorderSide(color: workspaceSoftLineColor)),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        scrollDirection: Axis.horizontal,
        itemCount: _SettingsSection.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final section = _SettingsSection.values[index];
          return _SettingsTopButton(
            key: Key('settings-nav-${section.name}'),
            section: section,
            selected: section == _section,
            onPressed: () => setState(() => _section = section),
          );
        },
      ),
    );
  }

  Widget _buildContent() {
    return SingleChildScrollView(
      controller: _contentScrollController,
      primary: false,
      key: const Key('settings-content-scroll'),
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_draft.operationMessage.isNotEmpty)
            _SettingsMessageBox(
              message: _draft.operationMessage,
              isError: _draft.operationFailed,
            ),
          _SettingsSectionContent(
            section: _section,
            draft: _draft,
            model: widget.model,
            enabled: widget.model.canEdit && !_draft.isSaving,
            onTestCapability: _testCapability,
            onClearApiKey: _confirmClearApiKey,
            onChooseVault: _chooseVault,
            onRevealVault: _revealVault,
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      key: const Key('settings-footer'),
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
      decoration: const BoxDecoration(
        color: workspaceSecondarySurfaceColor,
        border: Border(top: BorderSide(color: workspaceSoftLineColor)),
      ),
      child: Row(
        children: [
          if (_draft.isSaving) ...[
            const CupertinoActivityIndicator(radius: 8),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                '正在保存设置…',
                style: TextStyle(color: workspaceMutedColor, fontSize: 13),
              ),
            ),
          ] else
            const Spacer(),
          CupertinoButton(
            key: const Key('settings-cancel'),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            onPressed: _draft.isSaving ? null : _requestClose,
            child: const Text('取消'),
          ),
          const SizedBox(width: 8),
          PrimaryButton(
            label: '保存设置',
            icon: CupertinoIcons.check_mark,
            onPressed: _draft.canSave
                ? () => _saveAndMaybeClose(closeOnSuccess: true)
                : null,
          ),
        ],
      ),
    );
  }

  Future<bool> _saveAndMaybeClose({required bool closeOnSuccess}) async {
    final settings = _draft.currentSettings;
    if (!_draft.canSave || settings == null) {
      return false;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    _draft.beginSaving();
    WorkspaceSettingsSaveResult result;
    try {
      result = await widget.onSave(settings);
    } catch (error) {
      result = WorkspaceSettingsSaveResult.failed(message: '设置保存失败：$error');
    }
    if (!mounted) {
      return false;
    }
    if (result.committed) {
      if (closeOnSuccess) {
        await _closeDialog();
      } else {
        _draft.markSaved(settings, message: result.message);
      }
      return true;
    }
    _draft.finishSavingWithError(result.message);
    return false;
  }

  Future<void> _testCapability(ModelCapability capability) async {
    await _draft.testCapability(capability, widget.onTestCapability);
  }

  Future<void> _confirmClearApiKey() async {
    if (!_draft.canEdit || _draft.isSaving) {
      return;
    }
    final confirmed =
        await showCupertinoDialog<bool>(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: const Text('清除 API Key？'),
            content: const Text('保存设置后将从系统安全存储中清除 API Key，此操作需要明确确认。'),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              CupertinoDialogAction(
                isDestructiveAction: true,
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认清除'),
              ),
            ],
          ),
        ) ??
        false;
    if (confirmed && mounted) {
      _draft.clearApiKey();
    }
  }

  Future<void> _chooseVault() async {
    if (!widget.model.canChooseVault || _draft.isSaving) {
      return;
    }
    if (_draft.isDirty) {
      final decision = await showCupertinoModalPopup<_VaultDirtyDecision>(
        context: context,
        builder: (context) => CupertinoActionSheet(
          title: const Text('设置尚未保存'),
          message: const Text('更换仓库前，请选择如何处理当前草稿。'),
          actions: [
            CupertinoActionSheetAction(
              key: const Key('vault-switch-save-continue'),
              onPressed: () =>
                  Navigator.pop(context, _VaultDirtyDecision.saveAndContinue),
              child: const Text('保存并继续'),
            ),
            CupertinoActionSheetAction(
              key: const Key('vault-switch-discard-continue'),
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(
                context,
                _VaultDirtyDecision.discardAndContinue,
              ),
              child: const Text('放弃更改并继续'),
            ),
          ],
          cancelButton: CupertinoActionSheetAction(
            key: const Key('vault-switch-cancel'),
            onPressed: () => Navigator.pop(context, _VaultDirtyDecision.cancel),
            child: const Text('取消'),
          ),
        ),
      );
      if (!mounted ||
          decision == null ||
          decision == _VaultDirtyDecision.cancel) {
        return;
      }
      if (decision == _VaultDirtyDecision.saveAndContinue) {
        final saved = await _saveAndMaybeClose(closeOnSuccess: false);
        if (!saved || !mounted) {
          return;
        }
      } else {
        _draft.discardChanges();
      }
    }

    final result = await widget.onChooseVault();
    if (!mounted) {
      return;
    }
    switch (result) {
      case WorkspaceActionResult.committed:
        await _closeDialog();
      case WorkspaceActionResult.cancelled:
        break;
      case WorkspaceActionResult.busy:
        _draft.setOperationError('当前有其他操作正在进行，暂时无法更换仓库。');
      case WorkspaceActionResult.aborted:
        _draft.setOperationError('仓库切换已中止，当前仓库保持不变。');
      case WorkspaceActionResult.failed:
        _draft.setOperationError('仓库切换失败，当前仓库保持不变。');
    }
  }

  Future<void> _revealVault() async {
    if (!widget.model.canRevealVault || _draft.isSaving) {
      return;
    }
    try {
      await widget.onRevealVault();
      if (mounted) {
        _draft.setOperationMessage('已请求 Finder 显示当前仓库。');
      }
    } catch (error) {
      if (mounted) {
        _draft.setOperationError('在 Finder 中显示失败：$error');
      }
    }
  }

  Future<void> _requestClose() async {
    if (_draft.isSaving) {
      return;
    }
    if (!_draft.isDirty || !widget.model.canEdit) {
      await _closeDialog();
      return;
    }
    final discard =
        await showCupertinoDialog<bool>(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: const Text('放弃未保存的设置？'),
            content: const Text('关闭后，本次修改不会影响工作区。'),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('继续编辑'),
              ),
              CupertinoDialogAction(
                key: const Key('settings-confirm-discard'),
                isDestructiveAction: true,
                onPressed: () => Navigator.pop(context, true),
                child: const Text('放弃更改'),
              ),
            ],
          ),
        ) ??
        false;
    if (discard && mounted) {
      await _closeDialog();
    }
  }

  Future<void> _closeDialog() async {
    if (!mounted) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(true);
  }
}
