part of 'workspace_settings.dart';

final class _SettingsSectionContent extends StatelessWidget {
  const _SettingsSectionContent({
    required this.section,
    required this.draft,
    required this.model,
    required this.enabled,
    required this.onTestCapability,
    required this.onClearApiKey,
    required this.onChooseVault,
    required this.onRevealVault,
  });

  final _SettingsSection section;
  final _SettingsDraftController draft;
  final WorkspaceSettingsDialogModel model;
  final bool enabled;
  final Future<void> Function(ModelCapability capability) onTestCapability;
  final Future<void> Function() onClearApiKey;
  final Future<void> Function() onChooseVault;
  final Future<void> Function() onRevealVault;

  @override
  Widget build(BuildContext context) => switch (section) {
    _SettingsSection.general => _GeneralSettingsSection(
      draft: draft,
      enabled: enabled,
    ),
    _SettingsSection.models => _ModelSettingsSection(
      draft: draft,
      enabled: enabled,
      onTestCapability: onTestCapability,
      onClearApiKey: onClearApiKey,
    ),
    _SettingsSection.search => _SearchSettingsSection(
      draft: draft,
      enabled: enabled,
      onTestCapability: onTestCapability,
    ),
    _SettingsSection.appearance => _AppearanceSettingsSection(
      draft: draft,
      enabled: enabled,
    ),
    _SettingsSection.vault => _VaultSettingsSection(
      model: model,
      enabled: enabled,
      onChooseVault: onChooseVault,
      onRevealVault: onRevealVault,
    ),
    _SettingsSection.about => _AboutSettingsSection(model: model, draft: draft),
  };
}

final class _GeneralSettingsSection extends StatelessWidget {
  const _GeneralSettingsSection({required this.draft, required this.enabled});

  final _SettingsDraftController draft;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SettingsSectionTitle(
          title: '通用',
          subtitle: '控制新打开笔记的默认行为和编辑器保存节奏。',
        ),
        const _SettingsLabel('默认笔记模式'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _PreferenceChoice(
              key: const Key('settings-default-mode-reading'),
              label: '阅读',
              selected:
                  draft.defaultNoteMode == WorkspaceDefaultNoteMode.reading,
              onPressed: enabled
                  ? () => draft.setDefaultNoteMode(
                      WorkspaceDefaultNoteMode.reading,
                    )
                  : null,
            ),
            _PreferenceChoice(
              key: const Key('settings-default-mode-source'),
              label: '源码',
              selected:
                  draft.defaultNoteMode == WorkspaceDefaultNoteMode.source,
              onPressed: enabled
                  ? () => draft.setDefaultNoteMode(
                      WorkspaceDefaultNoteMode.source,
                    )
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 20),
        _SettingsField(
          key: const Key('settings-auto-save-delay'),
          controller: draft.autoSaveDelayController,
          label: '自动保存延迟（ms）',
          placeholder: '250–10000',
          enabled: enabled,
          keyboardType: TextInputType.number,
          error: draft.autoSaveDelayError,
        ),
        _SettingsField(
          key: const Key('settings-pasted-image-width'),
          controller: draft.pastedImageWidthController,
          label: '粘贴图片宽度（px）',
          placeholder: '120–2400',
          enabled: enabled,
          keyboardType: TextInputType.number,
          error: draft.pastedImageWidthError,
        ),
      ],
    );
  }
}

final class _ModelSettingsSection extends StatelessWidget {
  const _ModelSettingsSection({
    required this.draft,
    required this.enabled,
    required this.onTestCapability,
    required this.onClearApiKey,
  });

  final _SettingsDraftController draft;
  final bool enabled;
  final Future<void> Function(ModelCapability capability) onTestCapability;
  final Future<void> Function() onClearApiKey;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SettingsSectionTitle(
          title: 'AI 模型',
          subtitle: '配置 OpenAI 兼容的文本与视觉模型。',
        ),
        _SettingsField(
          key: const Key('provider-base-url'),
          controller: draft.baseUrlController,
          label: 'Base URL',
          placeholder: 'https://api.example.com/v1',
          enabled: enabled,
          error: draft.baseUrlError,
        ),
        _SettingsField(
          key: const Key('provider-api-key'),
          controller: draft.apiKeyController,
          label: 'API Key',
          placeholder: 'sk-…',
          enabled: enabled,
          obscureText: !draft.apiKeyVisible,
          error: draft.apiKeyError,
          suffix: CupertinoButton(
            key: const Key('provider-api-key-visibility'),
            minimumSize: const Size(34, 34),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            onPressed: enabled ? draft.toggleApiKeyVisibility : null,
            child: Icon(
              draft.apiKeyVisible
                  ? CupertinoIcons.eye_slash
                  : CupertinoIcons.eye,
              size: 17,
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: CupertinoButton(
            key: const Key('provider-api-key-clear'),
            padding: const EdgeInsets.fromLTRB(10, 0, 0, 10),
            onPressed: enabled && draft.apiKeyController.text.isNotEmpty
                ? onClearApiKey
                : null,
            child: const Text(
              '清除 API Key',
              style: TextStyle(color: CupertinoColors.systemRed),
            ),
          ),
        ),
        _SettingsField(
          key: const Key('provider-chat-model'),
          controller: draft.chatModelController,
          label: 'Chat Model',
          placeholder: 'gpt-4.1-mini',
          enabled: enabled,
        ),
        _CapabilityTestRow(
          capability: ModelCapability.chat,
          label: '测试 Chat',
          draft: draft,
          enabled: enabled,
          onPressed: onTestCapability,
        ),
        const SizedBox(height: 14),
        _SettingsField(
          key: const Key('provider-vision-model'),
          controller: draft.visionModelController,
          label: 'Vision Model',
          placeholder: 'gpt-4.1-mini',
          enabled: enabled,
        ),
        _CapabilityTestRow(
          capability: ModelCapability.vision,
          label: '测试 Vision',
          draft: draft,
          enabled: enabled,
          onPressed: onTestCapability,
        ),
        const SizedBox(height: 14),
        const _InfoText('模型测试会发送真实请求，可能产生 Provider 费用。测试不会保存当前草稿。'),
        if (draft.aiAvailabilityMessage.isNotEmpty) ...[
          const SizedBox(height: 10),
          _WarningText(draft.aiAvailabilityMessage),
        ],
      ],
    );
  }
}

final class _SearchSettingsSection extends StatelessWidget {
  const _SearchSettingsSection({
    required this.draft,
    required this.enabled,
    required this.onTestCapability,
  });

  final _SettingsDraftController draft;
  final bool enabled;
  final Future<void> Function(ModelCapability capability) onTestCapability;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SettingsSectionTitle(
          title: '搜索',
          subtitle: '全文搜索始终可用；语义搜索需要完整 Provider 与 Embedding 配置。',
        ),
        _SettingsToggleRow(
          key: const Key('settings-semantic-search-toggle'),
          title: '语义搜索',
          subtitle: '关闭后不会调用 Embedding，只使用全文搜索。',
          value: draft.semanticSearchEnabled,
          enabled: enabled,
          onChanged: draft.setSemanticSearchEnabled,
        ),
        const SizedBox(height: 18),
        _SettingsField(
          key: const Key('provider-embedding-model'),
          controller: draft.embeddingModelController,
          label: 'Embedding Model',
          placeholder: 'text-embedding-3-small',
          enabled: enabled,
        ),
        _CapabilityTestRow(
          capability: ModelCapability.embedding,
          label: '测试 Embedding',
          draft: draft,
          enabled: enabled,
          onPressed: onTestCapability,
        ),
        const SizedBox(height: 18),
        _StatusCard(
          title: '实际生效状态',
          value: draft.semanticSearchEffective
              ? '已生效，将使用语义搜索'
              : draft.semanticSearchEnabled
              ? '未生效，仅使用全文搜索'
              : '已关闭，仅使用全文搜索',
          active: draft.semanticSearchEffective,
        ),
        const SizedBox(height: 12),
        const _InfoText('Embedding 测试会发送固定短文本的真实请求，并校验返回向量非空且数值有限。'),
      ],
    );
  }
}

final class _AppearanceSettingsSection extends StatelessWidget {
  const _AppearanceSettingsSection({
    required this.draft,
    required this.enabled,
  });

  final _SettingsDraftController draft;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final accent = WorkspaceAppearanceScope.of(context).accentColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SettingsSectionTitle(
          title: '外观',
          subtitle: '修改会在当前弹窗内即时预览；取消后不会影响工作区。',
        ),
        const _SettingsLabel('主题色'),
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
                selected: draft.accentColor == color,
                onPressed: enabled ? () => draft.setAccentColor(color) : null,
              ),
          ],
        ),
        const SizedBox(height: 22),
        Row(
          children: [
            const Expanded(
              child: Text(
                '笔记内容字号',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              '${draft.noteFontSize} px',
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
          value: draft.noteFontSize.toDouble(),
          activeColor: accent,
          onChanged: enabled
              ? (value) => draft.setNoteFontSize(value.round())
              : null,
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: workspaceSecondarySurfaceColor,
            border: Border.all(color: workspaceSoftLineColor),
            borderRadius: workspaceBorderRadius,
          ),
          child: Text(
            '即时预览：学习笔记正文与主题强调色',
            style: TextStyle(
              color: accent,
              fontSize: draft.noteFontSize.toDouble(),
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}

final class _VaultSettingsSection extends StatelessWidget {
  const _VaultSettingsSection({
    required this.model,
    required this.enabled,
    required this.onChooseVault,
    required this.onRevealVault,
  });

  final WorkspaceSettingsDialogModel model;
  final bool enabled;
  final Future<void> Function() onChooseVault;
  final Future<void> Function() onRevealVault;

  @override
  Widget build(BuildContext context) {
    final path = model.vaultRootPath?.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SettingsSectionTitle(
          title: '仓库',
          subtitle: '仓库切换是独立事务，不会混入普通设置保存。',
        ),
        const _SettingsLabel('当前仓库完整路径'),
        const SizedBox(height: 8),
        Container(
          key: const Key('settings-vault-path'),
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: workspaceSecondarySurfaceColor,
            border: Border.all(color: workspaceSoftLineColor),
            borderRadius: workspaceBorderRadius,
          ),
          child: SelectableText(
            path == null || path.isEmpty ? '尚未选择仓库' : path,
            style: const TextStyle(fontSize: 13, height: 1.4),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            SecondaryButton(
              label: '更换仓库',
              icon: CupertinoIcons.folder_open,
              onPressed: enabled && model.canChooseVault ? onChooseVault : null,
            ),
            SecondaryButton(
              label: '在 Finder 中显示',
              icon: CupertinoIcons.arrow_up_right_square,
              onPressed: enabled && model.canRevealVault ? onRevealVault : null,
            ),
          ],
        ),
        if (!model.canRevealVault) ...[
          const SizedBox(height: 12),
          const _InfoText('Finder 定位仅在 macOS 且仓库路径有效时可用。'),
        ],
      ],
    );
  }
}

final class _AboutSettingsSection extends StatelessWidget {
  const _AboutSettingsSection({required this.model, required this.draft});

  final WorkspaceSettingsDialogModel model;
  final _SettingsDraftController draft;

  @override
  Widget build(BuildContext context) {
    final metadata = model.applicationMetadata;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SettingsSectionTitle(
          title: '关于',
          subtitle: '以下信息来自应用包和非敏感设置元数据，不会主动读写或探测 Keychain。',
        ),
        _SettingsStatusRows(
          rows: [
            ('版本', metadata.version),
            ('构建号', metadata.buildNumber),
            ('平台模式', metadata.platformMode),
            ('settings.json', model.storageInfo.settingsLocation),
            (
              'API Key',
              draft.apiKeyController.text.trim().isEmpty ? '未配置' : '已配置',
            ),
            ('安全存储', model.storageInfo.apiKeyStorage),
          ],
        ),
        const SizedBox(height: 14),
        const _WarningText(
          'Keychain fail-closed：只有替换或明确清除 API Key 时才访问系统安全存储；安全存储失败时拒绝保存，不会回退为明文。',
        ),
      ],
    );
  }
}

final class _CapabilityTestRow extends StatelessWidget {
  const _CapabilityTestRow({
    required this.capability,
    required this.label,
    required this.draft,
    required this.enabled,
    required this.onPressed,
  });

  final ModelCapability capability;
  final String label;
  final _SettingsDraftController draft;
  final bool enabled;
  final Future<void> Function(ModelCapability capability) onPressed;

  @override
  Widget build(BuildContext context) {
    final result = draft.testResult(capability);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SecondaryButton(
          label: label,
          icon: CupertinoIcons.bolt,
          busy: result.status == _SettingsModelTestStatus.running,
          onPressed:
              enabled && result.status != _SettingsModelTestStatus.running
              ? () => onPressed(capability)
              : null,
        ),
        if (result.message.isNotEmpty) ...[
          const SizedBox(height: 8),
          SelectableText(
            result.message,
            key: Key('settings-test-${capability.name}-result'),
            style: TextStyle(
              color: result.status == _SettingsModelTestStatus.failed
                  ? CupertinoColors.systemRed
                  : CupertinoColors.systemGreen,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ],
    );
  }
}

final class _SettingsField extends StatelessWidget {
  const _SettingsField({
    super.key,
    required this.controller,
    required this.label,
    required this.placeholder,
    required this.enabled,
    this.obscureText = false,
    this.keyboardType,
    this.error,
    this.suffix,
  });

  final TextEditingController controller;
  final String label;
  final String placeholder;
  final bool enabled;
  final bool obscureText;
  final TextInputType? keyboardType;
  final String? error;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SettingsLabel(label),
          const SizedBox(height: 5),
          WorkspaceCupertinoField(
            controller: controller,
            placeholder: placeholder,
            enabled: enabled,
            obscureText: obscureText,
            keyboardType: keyboardType,
            suffix: suffix,
            hasError: error != null,
          ),
          if (error case final message?) ...[
            const SizedBox(height: 5),
            Text(
              message,
              style: const TextStyle(
                color: CupertinoColors.systemRed,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

final class _SettingsToggleRow extends StatelessWidget {
  const _SettingsToggleRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: const TextStyle(
                  color: workspaceMutedColor,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        CupertinoSwitch(value: value, onChanged: enabled ? onChanged : null),
      ],
    );
  }
}

final class _SettingsNavButton extends StatelessWidget {
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
    final accent = WorkspaceAppearanceScope.of(context).accentColor;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: CupertinoButton(
        minimumSize: const Size(36, 36),
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected ? accent.withValues(alpha: 0.12) : null,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Icon(
                section.icon,
                size: 16,
                color: selected ? accent : workspaceMutedColor,
              ),
              const SizedBox(width: 8),
              Text(
                section.label,
                style: TextStyle(
                  color: selected ? accent : workspaceTextColor,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _SettingsTopButton extends StatelessWidget {
  const _SettingsTopButton({
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
    final accent = WorkspaceAppearanceScope.of(context).accentColor;
    return CupertinoButton(
      minimumSize: const Size(34, 34),
      padding: const EdgeInsets.symmetric(horizontal: 11),
      color: selected ? accent.withValues(alpha: 0.14) : null,
      borderRadius: BorderRadius.circular(7),
      onPressed: onPressed,
      child: Text(
        section.label,
        style: TextStyle(
          color: selected ? accent : workspaceTextColor,
          fontSize: 13,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }
}

final class _PreferenceChoice extends StatelessWidget {
  const _PreferenceChoice({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final accent = WorkspaceAppearanceScope.of(context).accentColor;
    return CupertinoButton(
      minimumSize: const Size(36, 36),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      color: selected ? accent : workspaceSecondarySurfaceColor,
      borderRadius: BorderRadius.circular(7),
      onPressed: onPressed,
      child: Text(
        label,
        style: TextStyle(
          color: selected ? CupertinoColors.white : workspaceTextColor,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

final class _AccentColorButton extends StatelessWidget {
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
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      minimumSize: const Size(38, 38),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: selected ? color.withValues(alpha: 0.14) : null,
      borderRadius: BorderRadius.circular(7),
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(label),
        ],
      ),
    );
  }
}

final class _SettingsSectionTitle extends StatelessWidget {
  const _SettingsSectionTitle({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 5),
        Text(
          subtitle,
          style: const TextStyle(
            color: workspaceMutedColor,
            fontSize: 12,
            height: 1.4,
          ),
        ),
      ],
    ),
  );
}

final class _SettingsLabel extends StatelessWidget {
  const _SettingsLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      color: workspaceMutedColor,
      fontSize: 12,
      fontWeight: FontWeight.w600,
    ),
  );
}

final class _SettingsMessageBox extends StatelessWidget {
  const _SettingsMessageBox({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('settings-operation-message'),
    margin: const EdgeInsets.only(bottom: 18),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: (isError ? CupertinoColors.systemRed : CupertinoColors.systemGreen)
          .withValues(alpha: 0.1),
      borderRadius: workspaceBorderRadius,
      border: Border.all(
        color:
            (isError ? CupertinoColors.systemRed : CupertinoColors.systemGreen)
                .withValues(alpha: 0.35),
      ),
    ),
    child: SelectableText(
      message,
      style: TextStyle(
        color: isError
            ? CupertinoColors.systemRed
            : CupertinoColors.systemGreen,
        fontSize: 12,
        height: 1.45,
      ),
    ),
  );
}

final class _SettingsStatusRows extends StatelessWidget {
  const _SettingsStatusRows({required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final row in rows)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 112, child: _SettingsLabel(row.$1)),
              Expanded(
                child: SelectableText(
                  row.$2,
                  style: const TextStyle(fontSize: 13, height: 1.4),
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

final class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.title,
    required this.value,
    required this.active,
  });

  final String title;
  final String value;
  final bool active;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('settings-semantic-effective-status'),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: workspaceSecondarySurfaceColor,
      border: Border.all(color: workspaceSoftLineColor),
      borderRadius: workspaceBorderRadius,
    ),
    child: Row(
      children: [
        Icon(
          active
              ? CupertinoIcons.check_mark_circled
              : CupertinoIcons.info_circle,
          size: 18,
          color: active
              ? CupertinoColors.systemGreen
              : CupertinoColors.systemOrange,
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(value, style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ],
    ),
  );
}

final class _InfoText extends StatelessWidget {
  const _InfoText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      color: workspaceMutedColor,
      fontSize: 12,
      height: 1.45,
    ),
  );
}

final class _WarningText extends StatelessWidget {
  const _WarningText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(
      color: CupertinoColors.systemYellow.withValues(alpha: 0.13),
      borderRadius: workspaceBorderRadius,
    ),
    child: Text(text, style: const TextStyle(fontSize: 12, height: 1.45)),
  );
}
