import 'package:flutter/foundation.dart';

import '../../../application/search/search_index.dart';
import '../../../domain/vault/vault_resource.dart';
import '../../../infrastructure/config/synapse_settings.dart';
import '../state/note_materials_registry.dart';
import '../state/split_workspace_controller.dart';

enum WorkspacePhase { needsVault, ready, webPreview, unsupported }

enum WorkspaceSection { resources, notes, sources }

enum WorkspaceLeftMode { resources, search }

enum WorkspaceOperation {
  startup,
  vaultSwitch,
  settings,
  resourceMutation,
  search,
  materials,
  editorCommand,
}

enum WorkspaceActionResult { committed, cancelled, busy, aborted, failed }

@immutable
final class WorkspaceState {
  WorkspaceState({
    required this.phase,
    required List<VaultResourceNode> resources,
    required this.selectedResourceId,
    required List<SearchResult> searchResults,
    required Map<String, NoteMaterialsSnapshot> materials,
    required this.splitRoot,
    required this.focusedPaneId,
    required Set<String> sessionNoteIds,
    this.leftMode = WorkspaceLeftMode.resources,
    this.narrowSection = WorkspaceSection.resources,
    this.leftPaneCollapsed = false,
    this.rightPaneCollapsed = false,
    this.settings = SynapseSettings.defaults,
    this.vaultLabel = '',
    this.vaultRoot,
    Set<String> savingNoteIds = const {},
    Set<String> lockedSessionNoteIds = const {},
    this.isAutoSaving = false,
    this.activeOperation,
    this.message = '',
    this.reloadRequired = false,
    Set<String> collapsedFolderIds = const {},
    this.selectedPreviewImageSrc,
  }) : resources = List<VaultResourceNode>.unmodifiable(
         resources.map(_freezeResource),
       ),
       searchResults = List<SearchResult>.unmodifiable(
         searchResults.map(_freezeSearchResult),
       ),
       materials = Map<String, NoteMaterialsSnapshot>.unmodifiable(materials),
       sessionNoteIds = Set<String>.unmodifiable(sessionNoteIds),
       savingNoteIds = Set<String>.unmodifiable(savingNoteIds),
       lockedSessionNoteIds = Set<String>.unmodifiable(lockedSessionNoteIds),
       collapsedFolderIds = Set<String>.unmodifiable(collapsedFolderIds);

  final WorkspacePhase phase;
  final List<VaultResourceNode> resources;
  final String? selectedResourceId;
  final List<SearchResult> searchResults;
  final Map<String, NoteMaterialsSnapshot> materials;
  final SplitNode splitRoot;
  final String focusedPaneId;
  final Set<String> sessionNoteIds;
  final WorkspaceLeftMode leftMode;
  final WorkspaceSection narrowSection;
  final bool leftPaneCollapsed;
  final bool rightPaneCollapsed;
  final SynapseSettings settings;
  WorkspacePreferences get preferences => settings.preferences;
  ProviderConfig get providerConfig => settings.providerConfig;
  final String vaultLabel;
  final String? vaultRoot;
  final Set<String> savingNoteIds;
  final Set<String> lockedSessionNoteIds;
  final bool isAutoSaving;
  final WorkspaceOperation? activeOperation;
  final String message;
  final bool reloadRequired;
  final Set<String> collapsedFolderIds;
  final String? selectedPreviewImageSrc;

  bool get hasVault =>
      phase == WorkspacePhase.ready || phase == WorkspacePhase.webPreview;

  bool get isBusy => activeOperation != null;

  VaultResourceNode? get selectedResource =>
      _findResource(resources, selectedResourceId);

  NoteMaterialsSnapshot materialsFor(String noteId) =>
      materials[noteId] ?? NoteMaterialsSnapshot.empty;

  WorkspaceState copyWith({
    WorkspacePhase? phase,
    List<VaultResourceNode>? resources,
    Object? selectedResourceId = _unset,
    List<SearchResult>? searchResults,
    Map<String, NoteMaterialsSnapshot>? materials,
    SplitNode? splitRoot,
    String? focusedPaneId,
    Set<String>? sessionNoteIds,
    WorkspaceLeftMode? leftMode,
    WorkspaceSection? narrowSection,
    bool? leftPaneCollapsed,
    bool? rightPaneCollapsed,
    SynapseSettings? settings,
    String? vaultLabel,
    Object? vaultRoot = _unset,
    Set<String>? savingNoteIds,
    Set<String>? lockedSessionNoteIds,
    bool? isAutoSaving,
    Object? activeOperation = _unset,
    String? message,
    bool? reloadRequired,
    Set<String>? collapsedFolderIds,
    Object? selectedPreviewImageSrc = _unset,
  }) {
    return WorkspaceState(
      phase: phase ?? this.phase,
      resources: resources ?? this.resources,
      selectedResourceId: identical(selectedResourceId, _unset)
          ? this.selectedResourceId
          : selectedResourceId as String?,
      searchResults: searchResults ?? this.searchResults,
      materials: materials ?? this.materials,
      splitRoot: splitRoot ?? this.splitRoot,
      focusedPaneId: focusedPaneId ?? this.focusedPaneId,
      sessionNoteIds: sessionNoteIds ?? this.sessionNoteIds,
      leftMode: leftMode ?? this.leftMode,
      narrowSection: narrowSection ?? this.narrowSection,
      leftPaneCollapsed: leftPaneCollapsed ?? this.leftPaneCollapsed,
      rightPaneCollapsed: rightPaneCollapsed ?? this.rightPaneCollapsed,
      settings: settings ?? this.settings,
      vaultLabel: vaultLabel ?? this.vaultLabel,
      vaultRoot: identical(vaultRoot, _unset)
          ? this.vaultRoot
          : vaultRoot as String?,
      savingNoteIds: savingNoteIds ?? this.savingNoteIds,
      lockedSessionNoteIds: lockedSessionNoteIds ?? this.lockedSessionNoteIds,
      isAutoSaving: isAutoSaving ?? this.isAutoSaving,
      activeOperation: identical(activeOperation, _unset)
          ? this.activeOperation
          : activeOperation as WorkspaceOperation?,
      message: message ?? this.message,
      reloadRequired: reloadRequired ?? this.reloadRequired,
      collapsedFolderIds: collapsedFolderIds ?? this.collapsedFolderIds,
      selectedPreviewImageSrc: identical(selectedPreviewImageSrc, _unset)
          ? this.selectedPreviewImageSrc
          : selectedPreviewImageSrc as String?,
    );
  }
}

const Object _unset = Object();

SearchResult _freezeSearchResult(SearchResult result) {
  return SearchResult(
    id: result.id,
    noteId: result.noteId,
    title: result.title,
    text: result.text,
    score: result.score,
    reasons: List<SearchMatchReason>.unmodifiable(result.reasons),
  );
}

VaultResourceNode? _findResource(
  List<VaultResourceNode> resources,
  String? id,
) {
  if (id == null) {
    return null;
  }
  for (final resource in resources) {
    if (resource.id == id) {
      return resource;
    }
    final nested = _findResource(resource.children, id);
    if (nested != null) {
      return nested;
    }
  }
  return null;
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
