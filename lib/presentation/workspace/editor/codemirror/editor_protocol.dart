import 'dart:convert';

const synapseEditorProtocolVersion = 2;

enum CodeMirrorDocumentMode { editing, reading }

final class EditorPageBoundary {
  const EditorPageBoundary({
    required this.pageIndex,
    required this.sourceOffset,
  });

  final int pageIndex;
  final int sourceOffset;

  Map<String, Object?> toJson() => {
    'pageIndex': pageIndex,
    'sourceOffset': sourceOffset,
  };

  @override
  bool operator ==(Object other) =>
      other is EditorPageBoundary &&
      other.pageIndex == pageIndex &&
      other.sourceOffset == sourceOffset;

  @override
  int get hashCode => Object.hash(pageIndex, sourceOffset);
}

final class EditorPageLayout {
  EditorPageLayout({
    required List<EditorPageBoundary> boundaries,
    required this.stale,
  }) : boundaries = List<EditorPageBoundary>.unmodifiable(boundaries);

  static final empty = EditorPageLayout(boundaries: const [], stale: false);

  final List<EditorPageBoundary> boundaries;
  final bool stale;

  Map<String, Object?> toJson() => {
    'boundaries': [for (final boundary in boundaries) boundary.toJson()],
    'stale': stale,
  };

  @override
  bool operator ==(Object other) {
    if (other is! EditorPageLayout ||
        other.stale != stale ||
        other.boundaries.length != boundaries.length) {
      return false;
    }
    for (var index = 0; index < boundaries.length; index += 1) {
      if (other.boundaries[index] != boundaries[index]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(stale, Object.hashAll(boundaries));
}

final class EditorChange {
  const EditorChange({
    required this.from,
    required this.to,
    required this.insert,
  });

  final int from;
  final int to;
  final String insert;

  factory EditorChange.fromJson(Map<String, Object?> json) => EditorChange(
    from: json['from']! as int,
    to: json['to']! as int,
    insert: json['insert']! as String,
  );

  Map<String, Object?> toJson() => {'from': from, 'to': to, 'insert': insert};
}

final class EditorSelection {
  const EditorSelection({required this.anchor, required this.head});

  final int anchor;
  final int head;

  factory EditorSelection.fromJson(Map<String, Object?> json) =>
      EditorSelection(
        anchor: json['anchor']! as int,
        head: json['head']! as int,
      );

  Map<String, Object?> toJson() => {'anchor': anchor, 'head': head};
}

final class EditorSearchQuery {
  const EditorSearchQuery({
    required this.query,
    required this.replacement,
    required this.caseSensitive,
    required this.wholeWord,
    required this.visible,
  });

  final String query;
  final String replacement;
  final bool caseSensitive;
  final bool wholeWord;
  final bool visible;

  Map<String, Object?> toJson() => {
    'query': query,
    'replacement': replacement,
    'caseSensitive': caseSensitive,
    'wholeWord': wholeWord,
    'visible': visible,
  };
}

final class EditorSearchMatch {
  const EditorSearchMatch({required this.from, required this.to});

  final int from;
  final int to;

  factory EditorSearchMatch.fromJson(Map<String, Object?> json) =>
      EditorSearchMatch(from: json['from']! as int, to: json['to']! as int);
}

final class EditorSearchState {
  const EditorSearchState({
    required this.query,
    required this.replacement,
    required this.caseSensitive,
    required this.wholeWord,
    required this.visible,
    required this.currentIndex,
    required this.matches,
  });

  final String query;
  final String replacement;
  final bool caseSensitive;
  final bool wholeWord;
  final bool visible;
  final int currentIndex;
  final List<EditorSearchMatch> matches;

  factory EditorSearchState.fromJson(Map<String, Object?> json) =>
      EditorSearchState(
        query: json['query']! as String,
        replacement: json['replacement']! as String,
        caseSensitive: json['caseSensitive']! as bool,
        wholeWord: json['wholeWord']! as bool,
        visible: json['visible']! as bool,
        currentIndex: json['currentIndex']! as int,
        matches: [
          for (final match in json['matches']! as List<Object?>)
            EditorSearchMatch.fromJson(match! as Map<String, Object?>),
        ],
      );
}

final class EditorCommandState {
  const EditorCommandState({
    required this.revision,
    required this.selection,
    required this.canUndo,
    required this.canRedo,
    required this.search,
  });

  final int revision;
  final EditorSelection selection;
  final bool canUndo;
  final bool canRedo;
  final EditorSearchState search;

  factory EditorCommandState.fromJson(Map<String, Object?> json) =>
      EditorCommandState(
        revision: json['revision']! as int,
        selection: EditorSelection.fromJson(
          json['selection']! as Map<String, Object?>,
        ),
        canUndo: json['canUndo']! as bool,
        canRedo: json['canRedo']! as bool,
        search: EditorSearchState.fromJson(
          json['search']! as Map<String, Object?>,
        ),
      );
}

final class EditorPerformanceSample {
  const EditorPerformanceSample({required this.name, required this.durationMs});

  final String name;
  final double durationMs;
}

final class EditorCommandRequest {
  const EditorCommandRequest({
    required this.group,
    required this.command,
    required this.selection,
    required this.revision,
  });

  final String group;
  final String command;
  final EditorSelection selection;
  final int revision;
}

final class EditorClipboardRequest {
  const EditorClipboardRequest({
    required this.requestId,
    required this.action,
    required this.target,
    required this.revision,
    required this.generation,
    this.selection,
    this.text,
  });

  final int requestId;
  final String action;
  final String target;
  final int revision;
  final int generation;
  final EditorSelection? selection;
  final String? text;

  factory EditorClipboardRequest.fromJson(Map<String, Object?> json) =>
      EditorClipboardRequest(
        requestId: json['requestId']! as int,
        action: json['action']! as String,
        target: json['target']! as String,
        revision: json['revision']! as int,
        generation: json['generation']! as int,
        selection: json['selection'] == null
            ? null
            : EditorSelection.fromJson(
                json['selection']! as Map<String, Object?>,
              ),
        text: json['text'] as String?,
      );
}

final class EditorClipboardResult {
  const EditorClipboardResult({
    required this.requestId,
    required this.revision,
    required this.generation,
    required this.outcome,
    required this.hasText,
    required this.hasImage,
    this.text,
  });

  final int requestId;
  final int revision;
  final int generation;
  final String outcome;
  final bool hasText;
  final bool hasImage;
  final String? text;

  Map<String, Object?> toJson() => {
    'protocolVersion': synapseEditorProtocolVersion,
    'type': 'clipboardResult',
    'requestId': requestId,
    'revision': revision,
    'generation': generation,
    'outcome': outcome,
    'hasText': hasText,
    'hasImage': hasImage,
    if (text != null) 'text': text,
  };
}

final class EditorTransaction {
  const EditorTransaction({
    required this.paneId,
    required this.noteId,
    required this.generation,
    required this.baseRevision,
    required this.revision,
    required this.clientSeq,
    required this.changes,
    required this.selection,
    required this.composing,
    required this.origin,
  });

  final String paneId;
  final String noteId;
  final int generation;
  final int baseRevision;
  final int revision;
  final int clientSeq;
  final List<EditorChange> changes;
  final EditorSelection selection;
  final bool composing;
  final String origin;

  factory EditorTransaction.fromJson(Map<String, Object?> json) =>
      EditorTransaction(
        paneId: json['paneId']! as String,
        noteId: json['noteId']! as String,
        generation: json['generation']! as int,
        baseRevision: json['baseRevision']! as int,
        revision: json['revision']! as int,
        clientSeq: json['clientSeq']! as int,
        changes: [
          for (final change in json['changes']! as List<Object?>)
            EditorChange.fromJson(change! as Map<String, Object?>),
        ],
        selection: EditorSelection.fromJson(
          json['selection']! as Map<String, Object?>,
        ),
        composing: json['composing']! as bool,
        origin: json['origin']! as String,
      );
}

final class EditorThemeData {
  const EditorThemeData({
    required this.background,
    required this.surface,
    required this.text,
    required this.muted,
    required this.line,
    required this.accent,
    required this.codeBackground,
    required this.highlight,
    required this.fontSize,
    required this.fontFamily,
    required this.contextMenu,
  });

  final String background;
  final String surface;
  final String text;
  final String muted;
  final String line;
  final String accent;
  final String codeBackground;
  final String highlight;
  final double fontSize;
  final String fontFamily;
  final EditorContextMenuThemeData contextMenu;

  Map<String, Object?> toJson() => {
    'background': background,
    'surface': surface,
    'text': text,
    'muted': muted,
    'line': line,
    'accent': accent,
    'codeBackground': codeBackground,
    'highlight': highlight,
    'fontSize': fontSize,
    'fontFamily': fontFamily,
    'contextMenu': contextMenu.toJson(),
  };
}

final class EditorContextMenuThemeData {
  const EditorContextMenuThemeData({
    required this.background,
    required this.text,
    required this.disabledText,
    required this.divider,
    required this.border,
    required this.danger,
  });

  final String background;
  final String text;
  final String disabledText;
  final String divider;
  final String border;
  final String danger;

  Map<String, Object?> toJson() => {
    'background': background,
    'text': text,
    'disabledText': disabledText,
    'divider': divider,
    'border': border,
    'danger': danger,
  };
}

Map<String, Object?> decodeEditorMessage(String message) {
  final decoded = jsonDecode(message);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('Editor bridge message must be a JSON object.');
  }
  final version = decoded['protocolVersion'];
  if (version != synapseEditorProtocolVersion) {
    throw FormatException('Unsupported editor protocol version: $version.');
  }
  return decoded;
}

String applyEditorChanges(String source, List<EditorChange> changes) {
  var updated = source;
  var lastFrom = source.length + 1;
  for (final change in changes.reversed) {
    if (change.from < 0 ||
        change.to < change.from ||
        change.to > source.length ||
        change.to > lastFrom) {
      throw RangeError('Invalid or overlapping editor change.');
    }
    updated = updated.replaceRange(change.from, change.to, change.insert);
    lastFrom = change.from;
  }
  return updated;
}

List<EditorChange> singleReplacementChanges(String before, String after) {
  if (before == after) {
    return const [];
  }
  var prefix = 0;
  final commonLength = before.length < after.length
      ? before.length
      : after.length;
  while (prefix < commonLength &&
      before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
    prefix += 1;
  }
  var beforeSuffix = before.length;
  var afterSuffix = after.length;
  while (beforeSuffix > prefix &&
      afterSuffix > prefix &&
      before.codeUnitAt(beforeSuffix - 1) ==
          after.codeUnitAt(afterSuffix - 1)) {
    beforeSuffix -= 1;
    afterSuffix -= 1;
  }
  return [
    EditorChange(
      from: prefix,
      to: beforeSuffix,
      insert: after.substring(prefix, afterSuffix),
    ),
  ];
}
