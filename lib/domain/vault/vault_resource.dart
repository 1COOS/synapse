enum VaultResourceType { folder, note }

enum SourceType { text, image }

enum SourceState { ready, pending, processed, failed }

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
  const VaultNoteContent({
    required super.id,
    required super.title,
    required super.path,
    required super.markdownPath,
    required super.assetsPath,
    required super.createdAt,
    required super.updatedAt,
    required this.markdown,
    required this.outline,
    required this.sources,
  });

  final String markdown;
  final List<OutlineNode> outline;
  final List<SourceItem> sources;

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

class SourceItem {
  const SourceItem({
    required this.id,
    required this.noteId,
    required this.type,
    required this.title,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
    this.text,
    this.extractedText,
    this.attachmentPath,
    this.mimeType,
  });

  final String id;
  final String noteId;
  final SourceType type;
  final String title;
  final SourceState state;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? text;
  final String? extractedText;
  final String? attachmentPath;
  final String? mimeType;

  String get searchableText => extractedText ?? text ?? title;

  SourceItem copyWith({
    String? noteId,
    SourceState? state,
    DateTime? updatedAt,
    String? title,
    String? text,
    String? extractedText,
    String? attachmentPath,
    String? mimeType,
  }) {
    return SourceItem(
      id: id,
      noteId: noteId ?? this.noteId,
      type: type,
      title: title ?? this.title,
      state: state ?? this.state,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      text: text ?? this.text,
      extractedText: extractedText ?? this.extractedText,
      attachmentPath: attachmentPath ?? this.attachmentPath,
      mimeType: mimeType ?? this.mimeType,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'noteId': noteId,
    'type': type.name,
    'title': title,
    'state': state.name,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'text': text,
    'extractedText': extractedText,
    'attachmentPath': attachmentPath,
    'mimeType': mimeType,
  };

  static SourceItem fromJson(Map<String, Object?> json) {
    return SourceItem(
      id: json['id']! as String,
      noteId: json['noteId']! as String,
      type: SourceType.values.byName(json['type']! as String),
      title: json['title']! as String,
      state: SourceState.values.byName(json['state']! as String),
      createdAt: DateTime.parse(json['createdAt']! as String),
      updatedAt: DateTime.parse(json['updatedAt']! as String),
      text: json['text'] as String?,
      extractedText: json['extractedText'] as String?,
      attachmentPath: json['attachmentPath'] as String?,
      mimeType: json['mimeType'] as String?,
    );
  }
}

class AiProposal {
  const AiProposal({
    required this.id,
    required this.noteId,
    required this.sourceIds,
    required this.title,
    required this.proposedMarkdown,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String noteId;
  final List<String> sourceIds;
  final String title;
  final String proposedMarkdown;
  final ProposalStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;

  AiProposal copyWith({
    String? noteId,
    ProposalStatus? status,
    DateTime? updatedAt,
  }) {
    return AiProposal(
      id: id,
      noteId: noteId ?? this.noteId,
      sourceIds: sourceIds,
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
    'sourceIds': sourceIds,
    'title': title,
    'proposedMarkdown': proposedMarkdown,
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  static AiProposal fromJson(Map<String, Object?> json) {
    return AiProposal(
      id: json['id']! as String,
      noteId: json['noteId']! as String,
      sourceIds: (json['sourceIds']! as List<Object?>).cast<String>(),
      title: json['title']! as String,
      proposedMarkdown: json['proposedMarkdown']! as String,
      status: ProposalStatus.values.byName(json['status']! as String),
      createdAt: DateTime.parse(json['createdAt']! as String),
      updatedAt: DateTime.parse(json['updatedAt']! as String),
    );
  }
}
