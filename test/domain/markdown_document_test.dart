import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/markdown/markdown_document.dart';

void main() {
  test('parses frontmatter and heading outline from markdown', () {
    const markdown = '''
---
id: project-1
title: 心经学习
template: scripture
---

# 心经学习

## 观自在

### 照见五蕴皆空
''';

    final document = MarkdownDocument.parse(markdown);

    expect(document.frontmatter['template'], 'scripture');
    expect(document.outline.map((node) => node.title), contains('心经学习'));
    expect(document.outline.first.children.first.title, '观自在');
    expect(document.outline.first.children.first.children.first.level, 3);
  });

  test('serializes frontmatter without losing the markdown body', () {
    final document = MarkdownDocument(
      frontmatter: {'id': 'project-1', 'title': '学科笔记', 'template': 'subject'},
      body: '# 学科笔记\n\n## 概念\n',
    );

    final markdown = document.toMarkdown();

    expect(markdown, contains('template: subject'));
    expect(markdown, contains('# 学科笔记'));
  });
}
