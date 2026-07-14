import 'vault_resource.dart';

final class VaultMigrationRequirement {
  VaultMigrationRequirement({
    required this.noteCount,
    required this.affectedNoteCount,
    required List<VaultResourceNode> previewResources,
  }) : previewResources = List<VaultResourceNode>.unmodifiable(
         previewResources.map(_freezeResource),
       );

  final int noteCount;
  final int affectedNoteCount;
  final List<VaultResourceNode> previewResources;
}

VaultResourceNode _freezeResource(VaultResourceNode resource) {
  return VaultResourceNode(
    id: resource.id,
    title: resource.title,
    path: resource.path,
    type: resource.type,
    children: List<VaultResourceNode>.unmodifiable(
      resource.children.map(_freezeResource),
    ),
  );
}
