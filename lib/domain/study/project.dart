enum StudyTemplate {
  scripture('scripture', '经文'),
  book('book', '书籍'),
  subject('subject', '学科'),
  custom('custom', '自定义');

  const StudyTemplate(this.value, this.label);

  final String value;
  final String label;

  static StudyTemplate fromValue(String? value) {
    return StudyTemplate.values.firstWhere(
      (template) => template.value == value,
      orElse: () => StudyTemplate.custom,
    );
  }
}

enum SourceType { text, image }

enum SourceState { ready, pending, processed, failed }

enum ProposalStatus { pending, applied, rejected }

class Project {
  const Project({
    required this.id,
    required this.title,
    required this.template,
    required this.rootPath,
    required this.markdownPath,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final StudyTemplate template;
  final String rootPath;
  final String markdownPath;
  final DateTime createdAt;
  final DateTime updatedAt;

  Project copyWith({
    String? title,
    StudyTemplate? template,
    String? rootPath,
    String? markdownPath,
    DateTime? updatedAt,
  }) {
    return Project(
      id: id,
      title: title ?? this.title,
      template: template ?? this.template,
      rootPath: rootPath ?? this.rootPath,
      markdownPath: markdownPath ?? this.markdownPath,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class ProjectContent extends Project {
  const ProjectContent({
    required super.id,
    required super.title,
    required super.template,
    required super.rootPath,
    required super.markdownPath,
    required super.createdAt,
    required super.updatedAt,
    required this.markdown,
    required this.outline,
    required this.sources,
  });

  final String markdown;
  final List<OutlineNode> outline;
  final List<SourceItem> sources;

  Project get project => Project(
    id: id,
    title: title,
    template: template,
    rootPath: rootPath,
    markdownPath: markdownPath,
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
    required this.projectId,
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
  final String projectId;
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

  Map<String, Object?> toJson() => {
    'id': id,
    'projectId': projectId,
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
      projectId: json['projectId']! as String,
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
    required this.projectId,
    required this.sourceIds,
    required this.title,
    required this.proposedMarkdown,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String projectId;
  final List<String> sourceIds;
  final String title;
  final String proposedMarkdown;
  final ProposalStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;

  AiProposal copyWith({ProposalStatus? status, DateTime? updatedAt}) {
    return AiProposal(
      id: id,
      projectId: projectId,
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
    'projectId': projectId,
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
      projectId: json['projectId']! as String,
      sourceIds: (json['sourceIds']! as List<Object?>).cast<String>(),
      title: json['title']! as String,
      proposedMarkdown: json['proposedMarkdown']! as String,
      status: ProposalStatus.values.byName(json['status']! as String),
      createdAt: DateTime.parse(json['createdAt']! as String),
      updatedAt: DateTime.parse(json['updatedAt']! as String),
    );
  }
}

class ProviderConfig {
  const ProviderConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.chatModel,
    required this.visionModel,
    required this.embeddingModel,
  });

  final String baseUrl;
  final String apiKey;
  final String chatModel;
  final String visionModel;
  final String embeddingModel;
}
