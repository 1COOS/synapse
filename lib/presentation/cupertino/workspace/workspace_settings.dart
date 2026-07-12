import 'package:flutter/cupertino.dart';

import '../../../domain/vault/vault_resource.dart';
import '../../../infrastructure/config/synapse_settings.dart';
import 'workspace_controls.dart';
import 'workspace_resources.dart';
import 'workspace_theme.dart';

typedef ProviderConfigTester = Future<String> Function(ProviderConfig config);

enum _SettingsSection {
  general('通用', CupertinoIcons.slider_horizontal_3),
  models('AI 模型', CupertinoIcons.sparkles),
  appearance('外观', CupertinoIcons.paintbrush),
  vault('仓库', CupertinoIcons.folder),
  search('搜索', CupertinoIcons.search),
  images('图片', CupertinoIcons.photo),
  about('关于', CupertinoIcons.info_circle);

  const _SettingsSection(this.label, this.icon);

  final String label;
  final IconData icon;
}

class WorkspaceSettingsSheet extends StatefulWidget {
  const WorkspaceSettingsSheet({
    super.key,
    required this.initialSettings,
    required this.currentVaultLabel,
    required this.canSave,
    required this.unavailableMessage,
    required this.onTestConfig,
  });

  final SynapseSettings initialSettings;
  final String currentVaultLabel;
  final bool canSave;
  final String unavailableMessage;
  final ProviderConfigTester onTestConfig;

  @override
  State<WorkspaceSettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<WorkspaceSettingsSheet> {
  late final TextEditingController _baseUrlController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _chatModelController;
  late final TextEditingController _visionModelController;
  late final TextEditingController _embeddingModelController;
  late final TextEditingController _autoSaveDelayController;
  late final TextEditingController _pastedImageWidthController;
  late WorkspaceDefaultNoteMode _defaultNoteMode;
  late bool _semanticSearchEnabled;
  late WorkspaceAccentColor _accentColor;
  late int _noteFontSize;
  _SettingsSection _section = _SettingsSection.general;
  bool _testing = false;
  String _testMessage = '';

  @override
  void initState() {
    super.initState();
    final settings = widget.initialSettings;
    final config = settings.providerConfig;
    final preferences = settings.preferences;
    _baseUrlController = TextEditingController(text: config.baseUrl);
    _apiKeyController = TextEditingController(text: config.apiKey);
    _chatModelController = TextEditingController(text: config.chatModel);
    _visionModelController = TextEditingController(text: config.visionModel);
    _embeddingModelController = TextEditingController(
      text: config.embeddingModel,
    );
    _autoSaveDelayController = TextEditingController(
      text: preferences.autoSaveDelayMillis.toString(),
    );
    _pastedImageWidthController = TextEditingController(
      text: preferences.pastedImageWidth.toString(),
    );
    _defaultNoteMode = preferences.defaultNoteMode;
    _semanticSearchEnabled = preferences.semanticSearchEnabled;
    _accentColor = preferences.accentColor;
    _noteFontSize = preferences.noteFontSize;
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _chatModelController.dispose();
    _visionModelController.dispose();
    _embeddingModelController.dispose();
    _autoSaveDelayController.dispose();
    _pastedImageWidthController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return WorkspaceAppearanceScope(
      appearance: WorkspaceAppearance(
        accentColor: WorkspaceAppearance.accentColorFor(_accentColor),
        noteFontSize: _noteFontSize.toDouble(),
      ),
      child: Center(
        child: CupertinoPopupSurface(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 760,
              maxHeight: size.height * 0.86,
            ),
            child: Container(
              color: workspaceSurfaceColor,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(18, 16, 18, 12),
                    child: Text(
                      '设置',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (!widget.canSave && widget.unavailableMessage.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                      child: Text(
                        widget.unavailableMessage,
                        style: const TextStyle(
                          color: workspaceMutedColor,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  Flexible(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 164,
                          child: DecoratedBox(
                            decoration: const BoxDecoration(
                              color: workspaceSecondarySurfaceColor,
                              border: Border(
                                right: BorderSide(
                                  color: workspaceSoftLineColor,
                                ),
                              ),
                            ),
                            child: ListView(
                              padding: const EdgeInsets.all(10),
                              children: [
                                for (final section in _SettingsSection.values)
                                  _SettingsNavButton(
                                    key: Key('settings-nav-${section.name}'),
                                    section: section,
                                    selected: _section == section,
                                    onPressed: () =>
                                        setState(() => _section = section),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        Expanded(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(18),
                            child: _buildSection(),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(
                    height: 1,
                    child: ColoredBox(color: workspaceSoftLineColor),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const SizedBox(width: 18),
                      if (_section == _SettingsSection.models)
                        SecondaryButton(
                          label: '测试模型',
                          icon: CupertinoIcons.antenna_radiowaves_left_right,
                          busy: _testing,
                          onPressed: _testing ? null : _testConfig,
                        ),
                      const Spacer(),
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('取消'),
                      ),
                      PrimaryButton(
                        label: '保存设置',
                        icon: CupertinoIcons.tray_arrow_down,
                        onPressed: widget.canSave
                            ? () =>
                                  Navigator.of(context).pop(_currentSettings())
                            : null,
                      ),
                      const SizedBox(width: 18),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSection() {
    switch (_section) {
      case _SettingsSection.general:
        return _buildGeneralSection();
      case _SettingsSection.models:
        return _buildModelSection();
      case _SettingsSection.appearance:
        return _buildAppearanceSection();
      case _SettingsSection.vault:
        return _statusSection(
          title: '仓库',
          rows: [
            ('当前仓库', widget.currentVaultLabel),
            ('保存位置', widget.canSave ? '桌面端 settings.json' : 'H5 预览不保存'),
          ],
        );
      case _SettingsSection.search:
        return _statusSection(
          title: '搜索',
          rows: [
            ('语义搜索', _semanticSearchEnabled ? '开启' : '关闭'),
            (
              'Embedding Model',
              _embeddingModelController.text.trim().isEmpty
                  ? '未配置'
                  : _embeddingModelController.text.trim(),
            ),
          ],
        );
      case _SettingsSection.images:
        return _statusSection(
          title: '图片',
          rows: [('粘贴图片默认宽度', '${_pastedImageWidthController.text.trim()} px')],
        );
      case _SettingsSection.about:
        return _statusSection(
          title: '关于',
          rows: const [('产品', 'Synapse'), ('定位', '本地优先学习资料整理工作台')],
        );
    }
  }

  Widget _buildGeneralSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '通用',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 14),
        const Text(
          '打开笔记默认模式',
          style: TextStyle(color: workspaceMutedColor, fontSize: 12),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _PreferenceChoice(
              key: const Key('settings-default-mode-reading'),
              label: '阅读',
              selected: _defaultNoteMode == WorkspaceDefaultNoteMode.reading,
              onPressed: () => setState(
                () => _defaultNoteMode = WorkspaceDefaultNoteMode.reading,
              ),
            ),
            const SizedBox(width: 8),
            _PreferenceChoice(
              key: const Key('settings-default-mode-source'),
              label: '编辑',
              selected: _defaultNoteMode == WorkspaceDefaultNoteMode.source,
              onPressed: () => setState(
                () => _defaultNoteMode = WorkspaceDefaultNoteMode.source,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _settingsField(
          key: const Key('settings-auto-save-delay'),
          controller: _autoSaveDelayController,
          label: '自动保存延迟（毫秒）',
          placeholder: '1000',
        ),
        _settingsField(
          key: const Key('settings-pasted-image-width'),
          controller: _pastedImageWidthController,
          label: '粘贴图片默认宽度',
          placeholder: '480',
        ),
        Row(
          children: [
            const Expanded(
              child: Text(
                '语义搜索',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            CupertinoSwitch(
              key: const Key('settings-semantic-search-toggle'),
              value: _semanticSearchEnabled,
              onChanged: (value) =>
                  setState(() => _semanticSearchEnabled = value),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildModelSection() {
    final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'AI 模型',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 14),
        _settingsField(
          key: const Key('provider-base-url'),
          controller: _baseUrlController,
          label: 'Base URL',
          placeholder: 'https://api.openai.com/v1',
        ),
        _settingsField(
          key: const Key('provider-api-key'),
          controller: _apiKeyController,
          label: 'API Key',
          obscureText: true,
        ),
        _settingsField(
          key: const Key('provider-chat-model'),
          controller: _chatModelController,
          label: 'Chat Model',
        ),
        _settingsField(
          key: const Key('provider-vision-model'),
          controller: _visionModelController,
          label: 'Vision Model',
        ),
        _settingsField(
          key: const Key('provider-embedding-model'),
          controller: _embeddingModelController,
          label: 'Embedding Model',
          placeholder: '可选；留空时只使用全文搜索',
        ),
        if (_testMessage.isNotEmpty)
          Text(
            _testMessage,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _testMessage.startsWith('测试失败')
                  ? workspaceDangerColor
                  : accentColor,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }

  Widget _buildAppearanceSection() {
    final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '外观',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 14),
        const Text(
          '主题色',
          style: TextStyle(color: workspaceMutedColor, fontSize: 12),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final color in WorkspaceAccentColor.values)
              _AccentColorButton(
                key: Key('settings-accent-${color.name}'),
                label: color.label,
                color: WorkspaceAppearance.accentColorFor(color),
                selected: _accentColor == color,
                onPressed: () => setState(() => _accentColor = color),
              ),
          ],
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            const Expanded(
              child: Text(
                '笔记内容字号',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              '$_noteFontSize px',
              style: const TextStyle(color: workspaceMutedColor, fontSize: 13),
            ),
          ],
        ),
        CupertinoSlider(
          key: const Key('settings-note-font-size-slider'),
          min: WorkspacePreferences.minNoteFontSize.toDouble(),
          max: WorkspacePreferences.maxNoteFontSize.toDouble(),
          divisions:
              WorkspacePreferences.maxNoteFontSize -
              WorkspacePreferences.minNoteFontSize,
          value: _noteFontSize.toDouble(),
          activeColor: accentColor,
          onChanged: (value) => setState(() => _noteFontSize = value.round()),
        ),
      ],
    );
  }

  Widget _statusSection({
    required String title,
    required List<(String, String)> rows,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 14),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 116,
                  child: Text(
                    row.$1,
                    style: const TextStyle(
                      color: workspaceMutedColor,
                      fontSize: 12,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(row.$2, style: const TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  ProviderConfig _currentConfig() {
    return ProviderConfig(
      baseUrl: _baseUrlController.text.trim(),
      apiKey: _apiKeyController.text.trim(),
      chatModel: _chatModelController.text.trim(),
      visionModel: _visionModelController.text.trim(),
      embeddingModel: _embeddingModelController.text.trim(),
    );
  }

  SynapseSettings _currentSettings() {
    return widget.initialSettings.copyWith(
      providerConfig: _currentConfig(),
      preferences: WorkspacePreferences(
        defaultNoteMode: _defaultNoteMode,
        semanticSearchEnabled: _semanticSearchEnabled,
        pastedImageWidth:
            int.tryParse(_pastedImageWidthController.text.trim()) ??
            WorkspacePreferences.defaults.pastedImageWidth,
        autoSaveDelayMillis:
            int.tryParse(_autoSaveDelayController.text.trim()) ??
            WorkspacePreferences.defaults.autoSaveDelayMillis,
        accentColor: _accentColor,
        noteFontSize: _noteFontSize,
      ),
    );
  }

  Future<void> _testConfig() async {
    setState(() {
      _testing = true;
      _testMessage = '';
    });
    try {
      final message = await widget.onTestConfig(_currentConfig());
      if (!mounted) {
        return;
      }
      setState(() => _testMessage = message);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _testMessage = '测试失败：$error');
    } finally {
      if (mounted) {
        setState(() => _testing = false);
      }
    }
  }

  Widget _settingsField({
    required Key key,
    required TextEditingController controller,
    required String label,
    String? placeholder,
    bool obscureText = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: workspaceMutedColor,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 5),
          WorkspaceCupertinoField(
            key: key,
            controller: controller,
            placeholder: placeholder ?? label,
            obscureText: obscureText,
          ),
        ],
      ),
    );
  }
}

class _SettingsNavButton extends StatelessWidget {
  const _SettingsNavButton({
    super.key,
    required this.section,
    required this.selected,
    required this.onPressed,
  });

  final _SettingsSection section;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: CupertinoButton(
        minimumSize: const Size(34, 34),
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(7),
        onPressed: onPressed,
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected ? accentColor.withValues(alpha: 0.12) : null,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Icon(
                section.icon,
                size: 16,
                color: selected ? accentColor : workspaceMutedColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  section.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? accentColor : workspaceTextColor,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreferenceChoice extends StatelessWidget {
  const _PreferenceChoice({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
    return CupertinoButton(
      minimumSize: const Size(34, 34),
      padding: EdgeInsets.zero,
      borderRadius: BorderRadius.circular(7),
      onPressed: onPressed,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: selected ? accentColor : workspaceSecondarySurfaceColor,
          border: Border.all(
            color: selected ? accentColor : workspaceSoftLineColor,
          ),
          borderRadius: BorderRadius.circular(7),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: selected ? CupertinoColors.white : workspaceTextColor,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _AccentColorButton extends StatelessWidget {
  const _AccentColorButton({
    super.key,
    required this.label,
    required this.color,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '主题色$label',
      button: true,
      selected: selected,
      child: CupertinoButton(
        minimumSize: const Size.square(34),
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(17),
        onPressed: onPressed,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? workspaceTextColor : workspaceSoftLineColor,
              width: selected ? 2 : 1,
            ),
          ),
          child: selected
              ? const Icon(
                  CupertinoIcons.check_mark,
                  size: 17,
                  color: CupertinoColors.white,
                )
              : null,
        ),
      ),
    );
  }
}
