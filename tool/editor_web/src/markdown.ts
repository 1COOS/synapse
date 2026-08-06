import type { EditorSelection } from './protocol';

export interface MarkdownBlock {
  from: number;
  to: number;
  text: string;
  kind:
    | 'blank'
    | 'heading'
    | 'list'
    | 'blockquote'
    | 'code'
    | 'table'
    | 'image'
    | 'pageBreak'
    | 'columnsStart'
    | 'columnsSeparator'
    | 'columnsEnd'
    | 'paragraph';
  level?: number;
}

const pageBreak = '<!-- synapse:page-break -->';
const columnsStart = /^<!--\s*synapse:columns(?:\s+ratio="(\d+):(\d+)")?\s*-->$/;
const columnsSeparator = /^<!--\s*synapse:column\s*-->$/;
const columnsEnd = /^<!--\s*synapse:columns-end\s*-->$/;
const tableWidthComment = /^<!--\s*synapse-table\s+width="[^"]*"\s*-->$/i;
const markdownImage = /^!\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)\s*$/;
const htmlImage = /^<img\b[^>]*\bsrc=(?:"([^"]+)"|'([^']+)')[^>]*>\s*$/i;

interface Line {
  from: number;
  to: number;
  text: string;
}

function linesOf(markdown: string): Line[] {
  const result: Line[] = [];
  let from = 0;
  for (let index = 0; index <= markdown.length; index += 1) {
    if (index !== markdown.length && markdown.charCodeAt(index) !== 10) continue;
    const to = index < markdown.length ? index + 1 : index;
    result.push({ from, to, text: markdown.slice(from, index) });
    from = to;
  }
  return result;
}

function block(kind: MarkdownBlock['kind'], lines: Line[], start: number, end: number, level?: number): MarkdownBlock {
  const from = lines[start]?.from ?? 0;
  const to = end > start ? lines[end - 1].to : from;
  return { from, to, text: lines.slice(start, end).map((line, index) => `${line.text}${line.to > line.from + line.text.length ? '\n' : ''}`).join(''), kind, level };
}

function isTableLine(text: string): boolean {
  const trimmed = text.trim();
  return trimmed.startsWith('|') && trimmed.endsWith('|') && trimmed.split('|').length >= 4;
}

function isListLine(text: string): boolean {
  return /^\s*(?:[-*+]\s+|\d+[.)]\s+)/.test(text);
}

export function splitMarkdownBlocks(markdown: string): MarkdownBlock[] {
  if (markdown.length === 0) return [{ from: 0, to: 0, text: '', kind: 'paragraph' }];
  const lines = linesOf(markdown);
  const result: MarkdownBlock[] = [];
  let index = 0;
  while (index < lines.length) {
    const start = index;
    const text = lines[index].text;
    const trimmed = text.trim();
    if (trimmed.length === 0) {
      while (index < lines.length && lines[index].text.trim().length === 0) index += 1;
      result.push(block('blank', lines, start, index));
      continue;
    }
    const startColumns = columnsStart.exec(trimmed);
    if (startColumns) {
      index += 1;
      result.push(block('columnsStart', lines, start, index));
      continue;
    }
    if (columnsSeparator.test(trimmed)) {
      index += 1;
      result.push(block('columnsSeparator', lines, start, index));
      continue;
    }
    if (columnsEnd.test(trimmed)) {
      index += 1;
      result.push(block('columnsEnd', lines, start, index));
      continue;
    }
    if (trimmed === pageBreak) {
      index += 1;
      result.push(block('pageBreak', lines, start, index));
      continue;
    }
    const heading = /^(#{1,6})\s+/.exec(trimmed);
    if (heading) {
      index += 1;
      result.push(block('heading', lines, start, index, heading[1].length));
      continue;
    }
    if (/^\s*```/.test(text)) {
      index += 1;
      while (index < lines.length) {
        const closes = /^\s*```/.test(lines[index].text);
        index += 1;
        if (closes) break;
      }
      result.push(block('code', lines, start, index));
      continue;
    }
    if (markdownImage.test(trimmed) || htmlImage.test(trimmed)) {
      index += 1;
      result.push(block('image', lines, start, index));
      continue;
    }
    if (
      tableWidthComment.test(trimmed) &&
      index + 1 < lines.length &&
      isTableLine(lines[index + 1].text)
    ) {
      index += 2;
      while (index < lines.length && isTableLine(lines[index].text)) index += 1;
      result.push(block('table', lines, start, index));
      continue;
    }
    if (isTableLine(text)) {
      index += 1;
      while (index < lines.length && isTableLine(lines[index].text)) index += 1;
      result.push(block('table', lines, start, index));
      continue;
    }
    if (isListLine(text)) {
      index += 1;
      while (index < lines.length && (isListLine(lines[index].text) || /^\s{2,}\S/.test(lines[index].text))) index += 1;
      result.push(block('list', lines, start, index));
      continue;
    }
    if (/^\s*>/.test(text)) {
      index += 1;
      while (index < lines.length && /^\s*>/.test(lines[index].text)) index += 1;
      result.push(block('blockquote', lines, start, index));
      continue;
    }
    index += 1;
    while (index < lines.length) {
      const next = lines[index].text;
      const nextTrimmed = next.trim();
      const special =
        nextTrimmed.length === 0 ||
        columnsStart.test(nextTrimmed) ||
        columnsSeparator.test(nextTrimmed) ||
        columnsEnd.test(nextTrimmed) ||
        nextTrimmed === pageBreak ||
        markdownImage.test(nextTrimmed) ||
        htmlImage.test(nextTrimmed) ||
        tableWidthComment.test(nextTrimmed) ||
        /^(?:\s*#{1,6}\s+|\s*```|\s*>|\s*(?:[-*+]\s+|\d+[.)]\s+))/.test(next) ||
        isTableLine(next);
      if (special) break;
      index += 1;
    }
    result.push(block('paragraph', lines, start, index));
  }
  return result;
}

export function activeBlockForSelection(blocks: MarkdownBlock[], selection: EditorSelection): MarkdownBlock | undefined {
  const offset = selection.head;
  return blocks.find((candidate, index) =>
    offset >= candidate.from &&
    (offset < candidate.to || (index === blocks.length - 1 && offset === candidate.to)));
}

export function markdownImageSource(text: string): string | undefined {
  const trimmed = text.trim();
  const markdownMatch = markdownImage.exec(trimmed);
  if (markdownMatch) return markdownMatch[1];
  const htmlMatch = htmlImage.exec(trimmed);
  return htmlMatch?.[1] ?? htmlMatch?.[2];
}

export function markdownImageWidth(text: string): number {
  const htmlWidth = /\bwidth=(?:"(\d+)"|'(\d+)'|(\d+))/i.exec(text);
  const value = Number(htmlWidth?.[1] ?? htmlWidth?.[2] ?? htmlWidth?.[3] ?? 640);
  return Math.max(120, Math.min(1600, Number.isFinite(value) ? value : 640));
}

export function outlineForMarkdown(markdown: string): Array<{ level: number; title: string; line: number; offset: number }> {
  const result: Array<{ level: number; title: string; line: number; offset: number }> = [];
  let offset = 0;
  markdown.split('\n').forEach((line, index) => {
    const match = /^(#{1,6})\s+(.+?)\s*$/.exec(line);
    if (match) result.push({ level: match[1].length, title: match[2].replace(/\s+#+$/, '').trim(), line: index + 1, offset });
    offset += line.length + 1;
  });
  return result;
}
