enum VaultResourceType { folder, note }

enum MediaKind { text, image, audio }

enum MaterialProcessingState { ready, pending, processed, failed }

@Deprecated('Use MediaKind.')
typedef SourceType = MediaKind;

@Deprecated('Use MaterialProcessingState.')
typedef SourceState = MaterialProcessingState;

enum ProposalStatus { pending, applied, rejected }

class VaultResourceNode {
  const VaultResourceNode({
    required this.id,
    required this.title,
    required this.path,
    required this.type,
    this.children = const [],
  });

  final String id;
  final String title;
  final String path;
  final VaultResourceType type;
  final List<VaultResourceNode> children;

  bool get isFolder => type == VaultResourceType.folder;
  bool get isNote => type == VaultResourceType.note;
}

class VaultNote {
  const VaultNote({
    required this.id,
    required this.title,
    required this.path,
    required this.markdownPath,
    required this.assetsPath,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String path;
  final String markdownPath;
  final String assetsPath;
  final DateTime createdAt;
  final DateTime updatedAt;

  VaultNote copyWith({
    String? id,
    String? title,
    String? path,
    String? markdownPath,
    String? assetsPath,
    DateTime? updatedAt,
  }) {
    return VaultNote(
      id: id ?? this.id,
      title: title ?? this.title,
      path: path ?? this.path,
      markdownPath: markdownPath ?? this.markdownPath,
      assetsPath: assetsPath ?? this.assetsPath,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class VaultNoteContent extends VaultNote {
  VaultNoteContent({
    required super.id,
    required super.title,
    required super.path,
    required super.markdownPath,
    required super.assetsPath,
    required super.createdAt,
    required super.updatedAt,
    required this.markdown,
    required this.outline,
    List<AiMaterial> aiMaterials = const [],
    List<NoteAttachment> attachments = const [],
    @Deprecated('Use aiMaterials.') List<AiMaterial>? sources,
  }) : aiMaterials = List<AiMaterial>.unmodifiable(
         aiMaterials.isNotEmpty ? aiMaterials : sources ?? const [],
       ),
       attachments = List<NoteAttachment>.unmodifiable(attachments);

  final String markdown;
  final List<OutlineNode> outline;
  final List<AiMaterial> aiMaterials;
  final List<NoteAttachment> attachments;

  @Deprecated('Use aiMaterials.')
  List<AiMaterial> get sources => aiMaterials;

  VaultNote get note => VaultNote(
    id: id,
    title: title,
    path: path,
    markdownPath: markdownPath,
    assetsPath: assetsPath,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

class OutlineNode {
  const OutlineNode({
    required this.id,
    required this.title,
    required this.level,
    required this.line,
    required this.children,
  });

  final String id;
  final String title;
  final int level;
  final int line;
  final List<OutlineNode> children;
}

class AiMaterial {
  AiMaterial({
    required this.id,
    required this.noteId,
    MediaKind? mediaKind,
    @Deprecated('Use mediaKind.') MediaKind? type,
    required this.title,
    MaterialProcessingState? processingState,
    @Deprecated('Use processingState.') MaterialProcessingState? state,
    required this.createdAt,
    required this.updatedAt,
    this.text,
    this.extractedText,
    String? contentPath,
    @Deprecated('Use contentPath.') String? attachmentPath,
    this.mimeType,
  }) : mediaKind = mediaKind ?? type ?? MediaKind.text,
       processingState =
           processingState ?? state ?? MaterialProcessingState.ready,
       contentPath = contentPath ?? attachmentPath;

  final String id;
  final String noteId;
  final MediaKind mediaKind;
  final String title;
  final MaterialProcessingState processingState;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? text;
  final String? extractedText;
  final String? contentPath;
  final String? mimeType;

  String get searchableText => extractedText ?? text ?? title;

  @Deprecated('Use mediaKind.')
  MediaKind get type => mediaKind;

  @Deprecated('Use processingState.')
  MaterialProcessingState get state => processingState;

  @Deprecated('Use contentPath.')
  String? get attachmentPath => contentPath;

  AiMaterial copyWith({
    String? noteId,
    MaterialProcessingState? processingState,
    @Deprecated('Use processingState.') MaterialProcessingState? state,
    DateTime? updatedAt,
    String? title,
    String? text,
    String? extractedText,
    String? contentPath,
    @Deprecated('Use contentPath.') String? attachmentPath,
    String? mimeType,
  }) {
    return AiMaterial(
      id: id,
      noteId: noteId ?? this.noteId,
      mediaKind: mediaKind,
      title: title ?? this.title,
      processingState: processingState ?? state ?? this.processingState,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      text: text ?? this.text,
      extractedText: extractedText ?? this.extractedText,
      contentPath: contentPath ?? attachmentPath ?? this.contentPath,
      mimeType: mimeType ?? this.mimeType,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'noteId': noteId,
    'mediaKind': mediaKind.name,
    'title': title,
    'processingState': processingState.name,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'text': text,
    'extractedText': extractedText,
    'contentPath': contentPath,
    'mimeType': mimeType,
  };

  static AiMaterial fromJson(Map<String, Object?> json) {
    return AiMaterial(
      id: json['id']! as String,
      noteId: json['noteId']! as String,
      mediaKind: MediaKind.values.byName(
        (json['mediaKind'] ?? json['type'])! as String,
      ),
      title: json['title']! as String,
      processingState: MaterialProcessingState.values.byName(
        (json['processingState'] ?? json['state'])! as String,
      ),
      createdAt: DateTime.parse(json['createdAt']! as String),
      updatedAt: DateTime.parse(json['updatedAt']! as String),
      text: json['text'] as String?,
      extractedText: json['extractedText'] as String?,
      contentPath: (json['contentPath'] ?? json['attachmentPath']) as String?,
      mimeType: json['mimeType'] as String?,
    );
  }
}

@Deprecated('Use AiMaterial.')
typedef SourceItem = AiMaterial;

class NoteAttachment {
  const NoteAttachment({
    required this.id,
    required this.noteId,
    required this.mediaKind,
    required this.title,
    required this.relativePath,
    required this.mimeType,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String noteId;
  final MediaKind mediaKind;
  final String title;
  final String relativePath;
  final String mimeType;
  final DateTime createdAt;
  final DateTime updatedAt;

  NoteAttachment copyWith({
    String? id,
    String? noteId,
    String? title,
    String? relativePath,
    String? mimeType,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return NoteAttachment(
      id: id ?? this.id,
      noteId: noteId ?? this.noteId,
      mediaKind: mediaKind,
      title: title ?? this.title,
      relativePath: relativePath ?? this.relativePath,
      mimeType: mimeType ?? this.mimeType,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'noteId': noteId,
    'mediaKind': mediaKind.name,
    'title': title,
    'relativePath': relativePath,
    'mimeType': mimeType,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  static NoteAttachment fromJson(Map<String, Object?> json) {
    return NoteAttachment(
      id: json['id']! as String,
      noteId: json['noteId']! as String,
      mediaKind: MediaKind.values.byName(json['mediaKind']! as String),
      title: json['title']! as String,
      relativePath: json['relativePath']! as String,
      mimeType: json['mimeType']! as String,
      createdAt: DateTime.parse(json['createdAt']! as String),
      updatedAt: DateTime.parse(json['updatedAt']! as String),
    );
  }
}

class AttachmentReferenceImpact {
  const AttachmentReferenceImpact({
    required this.noteId,
    required this.noteTitle,
    required this.occurrences,
  });

  final String noteId;
  final String noteTitle;
  final int occurrences;
}

class AttachmentDeletionImpact {
  const AttachmentDeletionImpact({
    required this.attachments,
    required this.references,
    this.noteFingerprints = const {},
  });

  final List<NoteAttachment> attachments;
  final List<AttachmentReferenceImpact> references;
  final Map<String, String> noteFingerprints;

  int get referenceCount =>
      references.fold(0, (total, reference) => total + reference.occurrences);

  bool get isUnreferenced => referenceCount == 0;
}

class ProposalMaterialSnapshot {
  const ProposalMaterialSnapshot({
    required this.materialId,
    required this.title,
    required this.mediaKind,
    required this.mimeType,
    required this.processingState,
  });

  final String materialId;
  final String title;
  final MediaKind mediaKind;
  final String? mimeType;
  final MaterialProcessingState processingState;

  factory ProposalMaterialSnapshot.fromMaterial(AiMaterial material) {
    return ProposalMaterialSnapshot(
      materialId: material.id,
      title: material.title,
      mediaKind: material.mediaKind,
      mimeType: material.mimeType,
      processingState: material.processingState,
    );
  }

  Map<String, Object?> toJson() => {
    'materialId': materialId,
    'title': title,
    'mediaKind': mediaKind.name,
    'mimeType': mimeType,
    'processingState': processingState.name,
  };

  static ProposalMaterialSnapshot fromJson(Map<String, Object?> json) {
    return ProposalMaterialSnapshot(
      materialId: json['materialId']! as String,
      title: json['title']! as String,
      mediaKind: MediaKind.values.byName(json['mediaKind']! as String),
      mimeType: json['mimeType'] as String?,
      processingState: MaterialProcessingState.values.byName(
        json['processingState']! as String,
      ),
    );
  }
}

class AiProposal {
  AiProposal({
    required this.id,
    required this.noteId,
    List<ProposalMaterialSnapshot>? materialSnapshots,
    @Deprecated('Use materialSnapshots.') List<String>? sourceIds,
    required this.title,
    required this.proposedMarkdown,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  }) : materialSnapshots = List<ProposalMaterialSnapshot>.unmodifiable(
         materialSnapshots ??
             (sourceIds ?? const []).map(
               (id) => ProposalMaterialSnapshot(
                 materialId: id,
                 title: '旧素材',
                 mediaKind: MediaKind.image,
                 mimeType: null,
                 processingState: MaterialProcessingState.ready,
               ),
             ),
       );

  final String id;
  final String noteId;
  final List<ProposalMaterialSnapshot> materialSnapshots;
  final String title;
  final String proposedMarkdown;
  final ProposalStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;

  List<String> get materialIds => materialSnapshots
      .map((snapshot) => snapshot.materialId)
      .toList(growable: false);

  @Deprecated('Use materialIds.')
  List<String> get sourceIds => materialIds;

  AiProposal copyWith({
    String? noteId,
    List<ProposalMaterialSnapshot>? materialSnapshots,
    ProposalStatus? status,
    DateTime? updatedAt,
  }) {
    return AiProposal(
      id: id,
      noteId: noteId ?? this.noteId,
      materialSnapshots: materialSnapshots ?? this.materialSnapshots,
      title: title,
      proposedMarkdown: proposedMarkdown,
      status: status ?? this.status,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'noteId': noteId,
    'materialSnapshots': materialSnapshots
        .map((snapshot) => snapshot.toJson())
        .toList(),
    'title': title,
    'proposedMarkdown': proposedMarkdown,
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  static AiProposal fromJson(Map<String, Object?> json) {
    final snapshotsJson = json['materialSnapshots'];
    return AiProposal(
      id: json['id']! as String,
      noteId: json['noteId']! as String,
      materialSnapshots: snapshotsJson is List<Object?>
          ? snapshotsJson
                .map(
                  (item) => ProposalMaterialSnapshot.fromJson(
                    (item as Map).cast<String, Object?>(),
                  ),
                )
                .toList()
          : null,
      sourceIds: snapshotsJson == null
          ? ((json['sourceIds'] as List<Object?>?) ?? const []).cast<String>()
          : null,
      title: json['title']! as String,
      proposedMarkdown: json['proposedMarkdown']! as String,
      status: ProposalStatus.values.byName(json['status']! as String),
      createdAt: DateTime.parse(json['createdAt']! as String),
      updatedAt: DateTime.parse(json['updatedAt']! as String),
    );
  }
}
