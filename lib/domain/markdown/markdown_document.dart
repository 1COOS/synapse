import 'package:yaml/yaml.dart';

import '../vault/vault_resource.dart';

class MarkdownDocument {
  const MarkdownDocument({required this.frontmatter, required this.body});

  final Map<String, Object?> frontmatter;
  final String body;

  String get visibleTitle => noteTitleFromMarkdownBody(body);

  List<OutlineNode> get outline => extractOutline(body);

  static MarkdownDocument parse(String markdown) {
    if (!markdown.startsWith('---\n')) {
      return MarkdownDocument(frontmatter: const {}, body: markdown);
    }

    final end = markdown.indexOf('\n---\n', 4);
    if (end == -1) {
      return MarkdownDocument(frontmatter: const {}, body: markdown);
    }

    final rawYaml = markdown.substring(4, end);
    final parsed = loadYaml(rawYaml);
    final body = markdown.substring(end + '\n---\n'.length);

    return MarkdownDocument(frontmatter: _yamlToMap(parsed), body: body);
  }

  String toMarkdown() {
    final buffer = StringBuffer('---\n');
    for (final entry in frontmatter.entries) {
      buffer.writeln('${entry.key}: ${entry.value}');
    }
    buffer.writeln('---\n');
    buffer.write(body.trimLeft());
    return buffer.toString();
  }

  MarkdownDocument copyWithSyncedBody(String body, {DateTime? updatedAt}) {
    final syncedFrontmatter = <String, Object?>{
      ...frontmatter,
      'title': noteTitleFromMarkdownBody(body),
      if (updatedAt != null) 'updatedAt': formatMarkdownTimestamp(updatedAt),
    };
    return MarkdownDocument(frontmatter: syncedFrontmatter, body: body);
  }
}

const untitledNoteTitle = '未命名';

String formatMarkdownTimestamp(DateTime value) {
  final local = value.toLocal();
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  final year = local.year.toString().padLeft(4, '0');
  final month = twoDigits(local.month);
  final day = twoDigits(local.day);
  final hour = twoDigits(local.hour);
  final minute = twoDigits(local.minute);
  return '$year-$month-$day $hour:$minute';
}

String noteTitleFromMarkdownBody(String body) {
  for (final line in body.split(RegExp(r'\r?\n'))) {
    if (line.trim().isEmpty) {
      continue;
    }
    final match = RegExp(r'^#\s+(.+?)\s*$').firstMatch(line);
    if (match == null) {
      return untitledNoteTitle;
    }
    final title = match.group(1)!.replaceAll(RegExp(r'\s+#+$'), '').trim();
    return title.isEmpty ? untitledNoteTitle : title;
  }
  return untitledNoteTitle;
}

String markdownBodyWithTitle(String body, String title) {
  final cleanTitle = title.trim().isEmpty ? untitledNoteTitle : title.trim();
  final lines = body.split('\n');
  for (var index = 0; index < lines.length; index += 1) {
    final line = lines[index];
    if (line.trim().isEmpty) {
      continue;
    }
    if (RegExp(r'^#\s+.+?\s*$').hasMatch(line)) {
      lines[index] = '# $cleanTitle';
      return lines.join('\n');
    }
    return '# $cleanTitle\n\n${body.trimLeft()}';
  }
  return '# $cleanTitle\n';
}

List<OutlineNode> extractOutline(String markdown) {
  final roots = <_MutableOutlineNode>[];
  final stack = <_MutableOutlineNode>[];
  final lines = markdown.split(RegExp(r'\r?\n'));

  for (var index = 0; index < lines.length; index += 1) {
    final match = RegExp(r'^(#{1,6})\s+(.+?)\s*$').firstMatch(lines[index]);
    if (match == null) {
      continue;
    }

    final level = match.group(1)!.length;
    final title = match.group(2)!.replaceAll(RegExp(r'\s+#+$'), '').trim();
    final node = _MutableOutlineNode(
      id: '${index + 1}-${_slug(title)}',
      title: title,
      level: level,
      line: index + 1,
    );

    while (stack.isNotEmpty && stack.last.level >= level) {
      stack.removeLast();
    }

    if (stack.isEmpty) {
      roots.add(node);
    } else {
      stack.last.children.add(node);
    }
    stack.add(node);
  }

  return roots.map((node) => node.snapshot).toList();
}

String markdownTable(List<String> headers, List<List<String>> rows) {
  String escape(String value) =>
      value.replaceAll('|', r'\|').replaceAll('\n', '<br>');
  final header = '| ${headers.map(escape).join(' | ')} |';
  final separator = '| ${headers.map((_) => '---').join(' | ')} |';
  final body = rows
      .map((row) => '| ${row.map(escape).join(' | ')} |')
      .join('\n');
  return [header, separator, body].where((line) => line.isNotEmpty).join('\n');
}

Map<String, Object?> _yamlToMap(Object? value) {
  if (value is! YamlMap) {
    return const {};
  }
  return {for (final entry in value.entries) entry.key.toString(): entry.value};
}

String sanitizeFileName(String value) {
  final cleaned = value
      .trim()
      .replaceAll(RegExp(r'[\\/:*?"<>|#%{}^~\[\]`]'), '-')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp('-{2,}'), '-')
      .replaceAll(RegExp(r'^\.+'), '');
  if (cleaned.isEmpty) {
    return 'untitled';
  }
  return cleaned.length > 80 ? cleaned.substring(0, 80) : cleaned;
}

String _slug(String value) =>
    sanitizeFileName(value).toLowerCase().replaceAll(' ', '-');

class _MutableOutlineNode {
  _MutableOutlineNode({
    required this.id,
    required this.title,
    required this.level,
    required this.line,
  });

  final String id;
  final String title;
  final int level;
  final int line;
  final List<_MutableOutlineNode> children = [];

  OutlineNode get snapshot => OutlineNode(
    id: id,
    title: title,
    level: level,
    line: line,
    children: children.map((child) => child.snapshot).toList(),
  );
}
