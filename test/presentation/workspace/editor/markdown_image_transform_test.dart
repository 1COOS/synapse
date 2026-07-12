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
