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

  test('derives note title from the visible first heading', () {
    const markdown = '''
---
title: 隐藏标题
createdAt: 2026-07-03 12:00
---

# 可见标题

正文
''';

    final document = MarkdownDocument.parse(markdown);

    expect(document.visibleTitle, '可见标题');
    expect(noteTitleFromMarkdownBody('#   \n正文'), '未命名');
    expect(noteTitleFromMarkdownBody('正文\n# 后续标题'), '未命名');
  });

  test('syncs hidden frontmatter with a visible body title', () {
    const markdown = '''
---
title: 旧标题
createdAt: 2026-07-03 12:00
updatedAt: 2026-07-03 12:00
---

# 旧标题

正文
''';

    final synced = MarkdownDocument.parse(markdown).copyWithSyncedBody(
      '# 新标题\n\n新的正文',
      updatedAt: DateTime(2026, 7, 5, 8, 30),
    );

    expect(synced.frontmatter['title'], '新标题');
    expect(synced.frontmatter['createdAt'], '2026-07-03 12:00');
    expect(synced.frontmatter['updatedAt'], '2026-07-05 08:30');
    expect(synced.body, '# 新标题\n\n新的正文');
  });
}
