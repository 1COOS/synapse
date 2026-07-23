import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/presentation/workspace/editor/markdown_image_transform.dart';

void main() {
  group('image width', () {
    test('reads HTML image width and clamps to supported bounds', () {
      expect(imageWidthFromTag('<img src="a.png" width="640">'), 640);
      expect(imageWidthFromTag('<img src="a.png" width="40">'), 120);
      expect(imageWidthFromTag('<img src="a.png" width="2400">'), 1200);
      expect(imageWidthFromTag('<img src="a.png">'), 480);
    });

    test('replaces only the requested image tag width', () {
      const markdown =
          '<img src="note.assets/first.png" width="320">\n'
          '<img src="note.assets/second.png" width="360">';

      expect(
        replaceImageWidthInMarkdown(
          markdown: markdown,
          src: 'note.assets/first.png',
          width: 720,
        ),
        '<img src="note.assets/first.png" width="720">\n'
        '<img src="note.assets/second.png" width="360">',
      );
    });
  });

  group('image movement', () {
    const first = '<img src="note.assets/first.png" width="320">';
    const second = '<img src="note.assets/second.png" width="360">';

    test('moves an image before the target tag', () {
      expect(
        moveImageTagInMarkdown(
          markdown: '$first $second',
          draggedSrc: 'note.assets/second.png',
          targetSrc: 'note.assets/first.png',
          beforeTarget: true,
        ),
        '$second $first',
      );
    });

    test('moves an image after the target tag', () {
      expect(
        moveImageTagInMarkdown(
          markdown: '$first $second',
          draggedSrc: 'note.assets/first.png',
          targetSrc: 'note.assets/second.png',
          beforeTarget: false,
        ),
        '$second $first',
      );
    });
  });

  group('image insertion', () {
    const tag = '<img src="note.assets/image.png" width="480">';

    test('inline insertion preserves surrounding text spacing', () {
      expect(
        inlineImageInsertion(
          text: 'beforeafter',
          index: 6,
          tag: tag,
          beforeTarget: false,
        ),
        ' $tag ',
      );
    });

    test('block insertion preserves existing line breaks', () {
      expect(
        blockImageInsertion(text: 'before\nafter', start: 7, end: 7, tag: tag),
        '\n$tag\n\n',
      );
      expect(
        blockImageInsertion(
          text: 'before\n\nafter',
          start: 8,
          end: 8,
          tag: tag,
        ),
        '$tag\n\n',
      );
    });

    test('inserts a persistent blank line between inline images', () {
      const first = '<img src="note.assets/first.png" width="320">';
      const second = '<img src="note.assets/second.png" width="360">';
      const markdown = '$first $second';
      final reference = findMarkdownImageReference(
        markdown: markdown,
        src: 'note.assets/first.png',
      )!;

      final inserted = insertBlankLineAfterMarkdownImage(
        markdown: markdown,
        reference: reference,
      );

      expect(inserted.markdown, '$first\n\n$second');
      expect(inserted.insertionOffset, first.length + 1);
    });

    test('adds another persistent blank line after a block image', () {
      const first = '<img src="note.assets/first.png" width="320">';
      const second = '<img src="note.assets/second.png" width="360">';
      const markdown = '$first\n\n$second';
      final reference = findMarkdownImageReference(
        markdown: markdown,
        src: 'note.assets/first.png',
      )!;

      final inserted = insertBlankLineAfterMarkdownImage(
        markdown: markdown,
        reference: reference,
      );

      expect(inserted.markdown, '$first\n\n\n$second');
      expect(inserted.insertionOffset, first.length + 1);
    });
  });

  group('image removal', () {
    const first = '<img src="note.assets/first.png" width="320">';
    const second = '<img src="note.assets/second.png" width="360">';

    test('removes only the selected inline image reference', () {
      const markdown = 'before $first $second after';
      final reference = findMarkdownImageReference(
        markdown: markdown,
        src: 'note.assets/first.png',
      )!;

      final removed = removeMarkdownImageReference(
        markdown: markdown,
        reference: reference,
      );

      expect(removed.markdown, 'before $second after');
      expect(removed.insertionOffset, 'before '.length);
    });

    test('removes a standalone image without leaving extra separators', () {
      const markdown = 'before\n\n$first\n\nafter';
      final reference = findMarkdownImageReference(
        markdown: markdown,
        src: 'note.assets/first.png',
      )!;

      final removed = removeMarkdownImageReference(
        markdown: markdown,
        reference: reference,
      );

      expect(removed.markdown, 'before\n\nafter');
    });

    test('removes standalone images cleanly at document boundaries', () {
      final leadingReference = findMarkdownImageReference(
        markdown: '$first\n\nsecond',
        src: 'note.assets/first.png',
      )!;
      final trailingReference = findMarkdownImageReference(
        markdown: 'first\n\n$second',
        src: 'note.assets/second.png',
      )!;

      expect(
        removeMarkdownImageReference(
          markdown: '$first\n\nsecond',
          reference: leadingReference,
        ).markdown,
        'second',
      );
      expect(
        removeMarkdownImageReference(
          markdown: 'first\n\n$second',
          reference: trailingReference,
        ).markdown,
        'first\n',
      );
    });

    test('finds and removes a standard Markdown image reference', () {
      const markdown =
          '![first](note.assets/first.png) '
          '![second](note.assets/second.png)';
      final reference = findMarkdownImageReference(
        markdown: markdown,
        src: 'note.assets/first.png',
      )!;

      final removed = removeMarkdownImageReference(
        markdown: markdown,
        reference: reference,
      );

      expect(removed.markdown, '![second](note.assets/second.png)');
    });
  });

  test('normalizes percent encoded and escaped image sources', () {
    expect(
      normalizeImageSrc(r'note.assets\100%25 image.png'),
      'note.assets/100% image.png',
    );
    expect(
      normalizeImageSrc('note.assets/100% image.png'),
      'note.assets/100% image.png',
    );
  });
}
