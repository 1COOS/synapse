import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'infrastructure/bootstrap/workspace_dependencies_factory.dart';
import 'presentation/cupertino/workspace.dart';
import 'presentation/workspace/controller/workspace_controller.dart';
import 'presentation/workspace/editor/codemirror/document_surface.dart';
import 'presentation/workspace/editor/codemirror/document_surface_factory.dart';

void main() {
  final dependencies = createWorkspaceDependencies();
  runApp(
    ProviderScope(
      overrides: [
        workspaceDependenciesProvider.overrideWithValue(dependencies),
      ],
      child: const SynapseApp(),
    ),
  );
}

class SynapseApp extends StatelessWidget {
  const SynapseApp({
    super.key,
    this.documentSurfaceFactory = const PlatformDocumentSurfaceFactory(),
  });

  final DocumentSurfaceFactory documentSurfaceFactory;

  @override
  Widget build(BuildContext context) {
    return CupertinoApp(
      debugShowCheckedModeBanner: false,
      title: 'Synapse',
      theme: CupertinoThemeData(
        brightness: Brightness.light,
        primaryColor: CupertinoColors.activeBlue,
        scaffoldBackgroundColor: Color(0xFFF5F5F7),
      ),
      home: SynapseWorkspace(documentSurfaceFactory: documentSurfaceFactory),
    );
  }
}
