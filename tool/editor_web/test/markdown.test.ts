import { describe, expect, it } from 'vitest';

import {
  activeBlockForSelection,
  markdownImageSource,
  outlineForMarkdown,
  splitMarkdownBlocks,
} from '../src/markdown';

describe('splitMarkdownBlocks', () => {
  it('preserves exact source ranges and structural blocks', () => {
    const markdown = [
      '# Heading',
      '',
      'Paragraph **bold**.',
      '',
      '| A | B |',
      '| --- | --- |',
      '| 1 | 2 |',
      '',
      '<!-- synapse:page-break -->',
      '',
      '![alt](Note.assets/attachments/image.png)',
      '',
    ].join('\n');
    const blocks = splitMarkdownBlocks(markdown);
    expect(blocks.map((block) => block.kind)).toContain('heading');
    expect(blocks.map((block) => block.kind)).toContain('table');
    expect(blocks.map((block) => block.kind)).toContain('pageBreak');
    expect(blocks.map((block) => block.kind)).toContain('image');
    expect(blocks.map((block) => markdown.slice(block.from, block.to)).join('')).toBe(markdown);
  });

  it('finds the active block with UTF-16 offsets', () => {
    const markdown = '中文😀段落\n\nSecond';
    const blocks = splitMarkdownBlocks(markdown);
    expect(activeBlockForSelection(blocks, { anchor: 3, head: 3 })?.text).toContain('中文');
    expect(activeBlockForSelection(blocks, { anchor: markdown.length, head: markdown.length })?.text).toContain('Second');
  });

  it('selects the next block when the caret is exactly on a shared boundary', () => {
    const markdown = 'Paragraph\n![image](image.png)';
    const blocks = splitMarkdownBlocks(markdown);
    const image = blocks.find((block) => block.kind === 'image')!;

    expect(activeBlockForSelection(
      blocks,
      { anchor: image.from, head: image.from },
    )).toBe(image);
  });

  it('keeps table width metadata inside the table source block', () => {
    const markdown = [
      '<!-- synapse-table width="720" -->',
      '| A | B |',
      '| :--- | ---: |',
      '| 1 | 2 |',
      '',
    ].join('\n');
    const blocks = splitMarkdownBlocks(markdown);

    expect(blocks[0].kind).toBe('table');
    expect(markdown.slice(blocks[0].from, blocks[0].to)).toBe(markdown);
    expect(blocks.map((block) => markdown.slice(block.from, block.to)).join('')).toBe(markdown);
  });
});

describe('markdown helpers', () => {
  it('extracts markdown and HTML image sources', () => {
    expect(markdownImageSource('![a](Note.assets/attachments/a.png)\n')).toBe('Note.assets/attachments/a.png');
    expect(markdownImageSource('<img src="Note.assets/attachments/b.png" width="640">\n')).toBe('Note.assets/attachments/b.png');
  });

  it('extracts a stable outline without changing source', () => {
    const markdown = '# Alpha\ntext\n## Beta\n';
    expect(outlineForMarkdown(markdown)).toEqual([
      { level: 1, title: 'Alpha', line: 1, offset: 0 },
      { level: 2, title: 'Beta', line: 3, offset: 13 },
    ]);
  });
});
