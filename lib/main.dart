import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'infrastructure/ai/ai_provider.dart';
import 'infrastructure/config/provider_config_store.dart';
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
    this.providerConfigStore,
    this.aiProvider,
    this.providerConfigTester,
  });

  final VaultBackend? vault;
  final ImageInputService? imageInput;
  final ProviderConfigStore? providerConfigStore;
  final AiProvider? aiProvider;
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
          providerConfigStore: providerConfigStore,
          aiProvider: aiProvider,
          providerConfigTester: providerConfigTester,
        ),
      ),
    );
  }
}
