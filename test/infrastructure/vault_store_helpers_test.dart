import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/infrastructure/vault/vault_store_helpers.dart';

void main() {
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
