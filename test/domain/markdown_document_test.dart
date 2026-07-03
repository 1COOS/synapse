import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/markdown/markdown_document.dart';

void main() {
  test('parses frontmatter and heading outline from markdown', () {
    const markdown = '''
---
title: 心经学习
createdAt: 2026-07-03 12:00
---

# 心经学习

## 观自在

### 照见五蕴皆空
''';

    final document = MarkdownDocument.parse(markdown);

    expect(document.frontmatter['title'], '心经学习');
    expect(document.frontmatter, isNot(contains('template')));
    expect(document.outline.map((node) => node.title), contains('心经学习'));
    expect(document.outline.first.children.first.title, '观自在');
    expect(document.outline.first.children.first.children.first.level, 3);
  });

  test('serializes frontmatter without losing the markdown body', () {
    final document = MarkdownDocument(
      frontmatter: {'title': '学习笔记', 'createdAt': '2026-07-03 12:00'},
      body: '# 学习笔记\n\n## 概念\n',
    );

    final markdown = document.toMarkdown();

    expect(markdown, isNot(contains('template:')));
    expect(markdown, contains('# 学习笔记'));
  });
}
