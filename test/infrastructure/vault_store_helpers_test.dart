import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/infrastructure/vault/vault_store_helpers.dart';

void main() {
  test('decodes local image paths without re-encoding Unicode', () {
    expect(
      localVaultImageSourcePath(
        '中文笔记.assets/attachments/图片.png',
        windows: false,
      ),
      '中文笔记.assets/attachments/图片.png',
    );
    expect(
      localVaultImageSourcePath(
        '%E4%B8%AD%E6%96%87%20%E7%AC%94%E8%AE%B0.assets/attachments/a%20b.png',
        windows: false,
      ),
      '中文 笔记.assets/attachments/a b.png',
    );
    expect(
      localVaultImageSourcePath(
        '中文%25笔记.assets/attachments/100%25.png',
        windows: false,
      ),
      '中文%笔记.assets/attachments/100%.png',
    );
    expect(
      localVaultImageSourcePath(
        'file:///tmp/%E4%B8%AD%E6%96%87.png',
        windows: false,
      ),
      '/tmp/中文.png',
    );
    expect(
      localVaultImageSourcePath(
        'https://example.com/image.png',
        windows: false,
      ),
      isNull,
    );
    expect(
      localVaultImageSourcePath('data:image/png;base64,AA==', windows: false),
      isNull,
    );
  });

  test('rewrites only local note asset image references', () {
    const markdown = '''# Note

<img src="Old Note.assets/attachments/a.png" width="480">
<img src='./Old Note.assets/attachments/b.png'>
![raw](<Old Note.assets/attachments/c image.png>)
![encoded](Old%20Note.assets/attachments/d%20image.png)
![other](Other.assets/attachments/e.png)
![remote](https://example.com/Old%20Note.assets/f.png)

```html
<img src="Old Note.assets/attachments/example.png">
![example](Old%20Note.assets/attachments/example.png)
```
''';

    final rewritten = rewriteNoteAssetReferences(
      markdown,
      oldAssetsDirectory: 'Old Note.assets',
      newAssetsDirectory: 'New Note.assets',
    );

    expect(rewritten, contains('src="New Note.assets/attachments/a.png"'));
    expect(rewritten, contains("src='./New Note.assets/attachments/b.png'"));
    expect(
      rewritten,
      contains('![raw](<New Note.assets/attachments/c image.png>)'),
    );
    expect(
      rewritten,
      contains('![encoded](New%20Note.assets/attachments/d%20image.png)'),
    );
    expect(rewritten, contains('![other](Other.assets/attachments/e.png)'));
    expect(
      rewritten,
      contains('![remote](https://example.com/Old%20Note.assets/f.png)'),
    );
    expect(
      rewritten,
      contains('<img src="Old Note.assets/attachments/example.png">'),
    );
    expect(
      rewritten,
      contains('![example](Old%20Note.assets/attachments/example.png)'),
    );
  });

  test(
    'returns the original markdown when the assets basename is unchanged',
    () {
      const markdown = '<img src="Note.assets/attachments/a.png">';

      expect(
        rewriteNoteAssetReferences(
          markdown,
          oldAssetsDirectory: 'Note.assets',
          newAssetsDirectory: 'Note.assets',
        ),
        same(markdown),
      );
    },
  );
}
