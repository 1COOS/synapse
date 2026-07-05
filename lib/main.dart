import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'infrastructure/ai/ai_provider.dart';
import 'infrastructure/config/provider_config_store.dart';
import 'infrastructure/config/settings_store.dart';
import 'infrastructure/config/vault_location_store.dart';
import 'infrastructure/input/image_input_service.dart';
import 'infrastructure/vault/vault_backend.dart';
import 'presentation/cupertino/workspace.dart';

void main() {
  runApp(const SynapseApp());
}

class SynapseApp extends StatelessWidget {
  const SynapseApp({
    super.key,
    this.vault,
    this.imageInput,
    this.settingsStore,
    this.providerConfigStore,
    this.vaultLocationStore,
    this.aiProvider,
    this.directoryPicker,
    this.vaultBackendFactory,
    this.providerConfigTester,
  });

  final VaultBackend? vault;
  final ImageInputService? imageInput;
  final SettingsStore? settingsStore;
  final ProviderConfigStore? providerConfigStore;
  final VaultLocationStore? vaultLocationStore;
  final AiProvider? aiProvider;
  final DirectoryPicker? directoryPicker;
  final VaultBackendFactory? vaultBackendFactory;
  final ProviderConfigTester? providerConfigTester;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: CupertinoApp(
        debugShowCheckedModeBanner: false,
        title: 'Synapse',
        theme: const CupertinoThemeData(
          brightness: Brightness.light,
          primaryColor: CupertinoColors.activeBlue,
          scaffoldBackgroundColor: Color(0xFFF5F5F7),
        ),
        home: SynapseWorkspace(
          initialVault: vault,
          imageInput: imageInput,
          settingsStore: settingsStore,
          providerConfigStore: providerConfigStore,
          vaultLocationStore: vaultLocationStore,
          aiProvider: aiProvider,
          directoryPicker: directoryPicker,
          vaultBackendFactory: vaultBackendFactory,
          providerConfigTester: providerConfigTester,
        ),
      ),
    );
  }
}
