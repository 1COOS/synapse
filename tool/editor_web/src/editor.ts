import {
  Annotation,
  ChangeSet,
  Compartment,
  EditorSelection as CmSelection,
  EditorState,
  Transaction,
  StateEffect,
  StateField,
} from '@codemirror/state';
import {
  Decoration,
  type DecorationSet,
  EditorView,
  type ViewUpdate,
  WidgetType,
  drawSelection,
  highlightActiveLine,
  keymap,
  placeholder,
} from '@codemirror/view';
import {
  defaultKeymap,
  history,
  historyKeymap,
  indentWithTab,
  redo,
  redoDepth,
  undo,
  undoDepth,
} from '@codemirror/commands';
import { markdown } from '@codemirror/lang-markdown';
import { defaultHighlightStyle, syntaxHighlighting, syntaxTree } from '@codemirror/language';
import {
  SearchQuery,
  getSearchQuery,
  replaceAll as replaceAllSearchMatches,
  replaceNext as replaceNextSearchMatch,
  search,
  setSearchQuery,
} from '@codemirror/search';

import {
  activeBlockForSelection,
  markdownImageSource,
  markdownImageWidth,
  splitMarkdownBlocks,
  type MarkdownBlock,
} from './markdown';
import {
  protocolVersion,
  type EditorChange,
  type EditorEvent,
  type EditorMode,
  type EditorSelection,
  type EditorTheme,
  type HostCommand,
  type InitializeCommand,
} from './protocol';

interface EditorRuntimeState {
  paneId: string;
  noteId: string;
  generation: number;
  revision: number;
  clientSeq: number;
  mode: EditorMode;
  editable: boolean;
  focused: boolean;
  theme: EditorTheme;
}

interface ModeValue {
  mode: EditorMode;
  editable: boolean;
  focused: boolean;
}

const hostChange = Annotation.define<boolean>();
const setMode = StateEffect.define<ModeValue>();
const setSearchVisibility = StateEffect.define<boolean>();
const modeField = StateField.define<ModeValue>({
  create: () => ({ mode: 'reading', editable: false, focused: false }),
  update(value, transaction) {
    for (const effect of transaction.effects) {
      if (effect.is(setMode)) return effect.value;
    }
    return value;
  },
});
const searchVisibilityField = StateField.define<boolean>({
  create: () => false,
  update(value, transaction) {
    for (const effect of transaction.effects) {
      if (effect.is(setSearchVisibility)) return effect.value;
    }
    return value;
  },
});

const editableCompartment = new Compartment();
const themeCompartment = new Compartment();

let view: EditorView | undefined;
let runtime: EditorRuntimeState | undefined;
let pendingChanges: ChangeSet | undefined;
let pendingFrame = 0;
let outlineTimer = 0;
let commandStateFrame = 0;
let inputStartedAt: number | undefined;
let pointerStartedAt: number | undefined;
let pendingNestedComposition = false;
let attachmentCounter = 0;
const attachmentCacheLimit = 24;

function post(event: Omit<EditorEvent, 'protocolVersion' | 'paneId' | 'noteId' | 'generation'> & { type: EditorEvent['type'] }): void {
  if (!runtime || !window.SynapseBridge) return;
  window.SynapseBridge.postMessage(JSON.stringify({
    protocolVersion,
    paneId: runtime.paneId,
    noteId: runtime.noteId,
    generation: runtime.generation,
    ...event,
  }));
}

function selectionOf(state: EditorState): EditorSelection {
  const main = state.selection.main;
  return { anchor: main.anchor, head: main.head };
}

function safeDispatchSelection(position: number): void {
  if (!view) return;
  const resolved = Math.max(0, Math.min(position, view.state.doc.length));
  view.dispatch({ selection: { anchor: resolved }, scrollIntoView: true });
  if (runtime?.mode === 'editing' && runtime.editable) view.focus();
}

const markdownRangeDragType = 'application/x-synapse-markdown-range';

interface DraggedMarkdownRange {
  from: number;
  to: number;
}

function writeDraggedMarkdownRange(event: DragEvent, from: number, to: number): void {
  event.dataTransfer?.setData(markdownRangeDragType, JSON.stringify({ from, to }));
  if (event.dataTransfer) event.dataTransfer.effectAllowed = 'move';
}

function readDraggedMarkdownRange(event: DragEvent): DraggedMarkdownRange | undefined {
  const encoded = event.dataTransfer?.getData(markdownRangeDragType);
  if (!encoded) return undefined;
  try {
    const decoded = JSON.parse(encoded) as Partial<DraggedMarkdownRange>;
    if (!Number.isInteger(decoded.from) || !Number.isInteger(decoded.to)) return undefined;
    return { from: decoded.from!, to: decoded.to! };
  } catch (_) {
    return undefined;
  }
}

function moveMarkdownRange(range: DraggedMarkdownRange, targetOffset: number): boolean {
  if (!view || !runtime?.editable) return false;
  const length = view.state.doc.length;
  const from = Math.max(0, Math.min(range.from, length));
  const to = Math.max(from, Math.min(range.to, length));
  const target = Math.max(0, Math.min(targetOffset, length));
  if (from === to || (target >= from && target <= to)) return false;
  const source = view.state.doc.sliceString(from, to);
  const insertionOffset = target > to ? target - (to - from) : target;
  const changes = target < from
    ? [
        { from: target, to: target, insert: source },
        { from, to, insert: '' },
      ]
    : [
        { from, to, insert: '' },
        { from: target, to: target, insert: source },
      ];
  view.dispatch({
    changes,
    selection: { anchor: insertionOffset + source.length },
  });
  return true;
}

function requestAttachment(src: string, listener: (url?: string) => void): () => void {
  const lease: AttachmentLease = { listener, released: false, cached: false };
  const cached = attachmentCache.get(src);
  if (cached) {
    cached.refs += 1;
    cached.lastUsed = performance.now();
    lease.cached = true;
    listener(cached.url);
    return () => releaseAttachmentLease(src, lease);
  }
  const inFlightRequestId = pendingAttachmentBySrc.get(src);
  if (inFlightRequestId) {
    pendingAttachments.get(inFlightRequestId)?.leases.add(lease);
    return () => releaseAttachmentLease(src, lease);
  }
  const requestId = `attachment-${++attachmentCounter}`;
  const pending: PendingAttachment = {
    src,
    mimeType: 'application/octet-stream',
    chunks: [],
    leases: new Set([lease]),
  };
  pendingAttachments.set(requestId, pending);
  pendingAttachmentBySrc.set(src, requestId);
  post({ type: 'attachmentRequest', requestId, src });
  return () => releaseAttachmentLease(src, lease);
}

function releaseAttachmentLease(src: string, lease: AttachmentLease): void {
  if (lease.released) return;
  lease.released = true;
  if (lease.cached) {
    const cached = attachmentCache.get(src);
    if (cached) {
      cached.refs = Math.max(0, cached.refs - 1);
      cached.lastUsed = performance.now();
    }
    evictAttachmentCache();
    return;
  }
  const requestId = pendingAttachmentBySrc.get(src);
  if (requestId) pendingAttachments.get(requestId)?.leases.delete(lease);
}

function evictAttachmentCache(): void {
  if (attachmentCache.size <= attachmentCacheLimit) return;
  const candidates = [...attachmentCache.entries()]
    .filter(([, value]) => value.refs === 0)
    .sort((left, right) => left[1].lastUsed - right[1].lastUsed);
  while (attachmentCache.size > attachmentCacheLimit && candidates.length > 0) {
    const [src, value] = candidates.shift()!;
    attachmentCache.delete(src);
    URL.revokeObjectURL(value.url);
  }
}

class PageBreakWidget extends WidgetType {
  constructor(readonly from: number) { super(); }

  eq(other: PageBreakWidget): boolean { return other.from === this.from; }

  toDOM(): HTMLElement {
    const root = document.createElement('div');
    root.className = 'synapse-page-break';
    const line = document.createElement('span');
    const label = document.createElement('span');
    label.textContent = '分页符';
    root.append(line, label, line.cloneNode());
    root.addEventListener('mousedown', (event) => {
      event.preventDefault();
      safeDispatchSelection(this.from);
    });
    return root;
  }

  ignoreEvent(): boolean { return false; }
}

class ImageWidget extends WidgetType {
  private disposeAttachment?: () => void;

  constructor(
    readonly from: number,
    readonly to: number,
    readonly src: string,
    readonly width: number,
    readonly block: boolean,
    readonly sourceText: string,
    readonly selected: boolean,
    readonly editable: boolean,
  ) { super(); }

  eq(other: ImageWidget): boolean {
    return other.from === this.from &&
      other.to === this.to &&
      other.src === this.src &&
      other.width === this.width &&
      other.block === this.block &&
      other.sourceText === this.sourceText &&
      other.selected === this.selected &&
      other.editable === this.editable;
  }

  toDOM(): HTMLElement {
    const root = document.createElement(this.block ? 'div' : 'span');
    root.className = this.block ? 'synapse-image-block' : 'synapse-inline-image';
    if (this.selected) root.classList.add('synapse-image-selected');
    root.dataset.src = this.src;
    root.draggable = this.editable;
    const loading = document.createElement('span');
    loading.className = 'synapse-image-loading';
    loading.textContent = '正在载入图片…';
    root.append(loading);
    this.disposeAttachment = requestAttachment(this.src, (url) => {
      root.replaceChildren();
      if (!url) {
        const broken = document.createElement('span');
        broken.className = 'synapse-image-broken';
        broken.textContent = this.src;
        root.append(broken);
        return;
      }
      const image = document.createElement('img');
      image.src = url;
      image.alt = this.src;
      image.draggable = false;
      image.style.width = `${this.width}px`;
      image.style.maxWidth = '100%';
      root.append(image);
      if (this.editable) {
        const handle = document.createElement('span');
        handle.className = 'synapse-image-resize';
        handle.addEventListener('pointerdown', (event) => this.beginResize(event, image));
        root.append(handle);
      }
    });
    if (this.selected && this.editable) {
      const source = document.createElement('textarea');
      source.className = 'synapse-image-source';
      source.value = this.sourceText;
      source.spellcheck = false;
      source.addEventListener('mousedown', (event) => event.stopPropagation());
      source.addEventListener('keydown', (event) => event.stopPropagation());
      source.addEventListener('blur', () => {
        if (!view || source.value === this.sourceText) return;
        view.dispatch({
          changes: { from: this.from, to: this.to, insert: source.value },
          selection: { anchor: this.from + source.selectionStart },
        });
      });
      root.prepend(source);
    }
    root.addEventListener('mousedown', (event) => {
      if ((event.target as HTMLElement).classList.contains('synapse-image-resize')) return;
      event.preventDefault();
      safeDispatchSelection(this.from);
    });
    root.addEventListener('contextmenu', (event) => {
      event.preventDefault();
      showContextMenu(event.clientX, event.clientY, this.from, this.to, this.src);
    });
    root.addEventListener('dragstart', (event) => {
      event.dataTransfer?.setData('application/x-synapse-image-src', this.src);
      writeDraggedMarkdownRange(event, this.from, this.to);
    });
    root.addEventListener('dragover', (event) => {
      if (!runtime?.editable) return;
      const dragged = event.dataTransfer?.types.includes('application/x-synapse-image-src') ||
        event.dataTransfer?.types.includes(markdownRangeDragType);
      if (!dragged) return;
      event.preventDefault();
      root.classList.add('synapse-image-drop-target');
    });
    root.addEventListener('dragleave', () => root.classList.remove('synapse-image-drop-target'));
    root.addEventListener('drop', (event) => {
      root.classList.remove('synapse-image-drop-target');
      const draggedRange = readDraggedMarkdownRange(event);
      if (draggedRange) {
        event.preventDefault();
        const bounds = root.getBoundingClientRect();
        const before = this.block
          ? event.clientY < bounds.top + bounds.height / 2
          : event.clientX < bounds.left + bounds.width / 2;
        moveMarkdownRange(draggedRange, before ? this.from : this.to);
        return;
      }
      const draggedSrc = event.dataTransfer?.getData('application/x-synapse-image-src');
      if (!runtime?.editable || !draggedSrc || draggedSrc === this.src) return;
      event.preventDefault();
      const bounds = root.getBoundingClientRect();
      flushPendingTransaction();
      post({
        type: 'imageAction',
        action: 'move',
        src: draggedSrc,
        revision: runtime.revision,
        targetSrc: this.src,
        beforeTarget: event.clientX < bounds.left + bounds.width / 2,
      });
    });
    return root;
  }

  destroy(): void { this.disposeAttachment?.(); }

  ignoreEvent(): boolean { return false; }

  private beginResize(event: PointerEvent, image: HTMLImageElement): void {
    event.preventDefault();
    event.stopPropagation();
    const startX = event.clientX;
    const startWidth = image.getBoundingClientRect().width;
    const move = (next: PointerEvent) => {
      image.style.width = `${Math.max(120, Math.min(1600, startWidth + next.clientX - startX))}px`;
    };
    const end = () => {
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', end);
      const width = Math.round(image.getBoundingClientRect().width);
      flushPendingTransaction();
      post({
        type: 'imageAction',
        action: 'resize',
        src: this.src,
        revision: runtime!.revision,
        width,
      });
    };
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', end, { once: true });
  }
}

interface TableModel {
  width?: number;
  header: string[];
  alignments: string[];
  rows: string[][];
  trailingNewline: boolean;
}

function parseTableRow(line: string): string[] {
  let source = line.trim();
  if (source.startsWith('|')) source = source.slice(1);
  if (source.endsWith('|') && !source.endsWith('\\|')) source = source.slice(0, -1);
  const cells: string[] = [];
  let value = '';
  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    let slashCount = 0;
    for (let cursor = index - 1; cursor >= 0 && source[cursor] === '\\'; cursor -= 1) slashCount += 1;
    if (character === '|' && slashCount % 2 === 0) {
      cells.push(value.trim());
      value = '';
    } else {
      value += character;
    }
  }
  cells.push(value.trim());
  return cells;
}

function parseTableModel(markdownText: string): TableModel | undefined {
  const trailingNewline = markdownText.endsWith('\n');
  const lines = markdownText.replace(/\n$/, '').split(/\r?\n/);
  const widthMatch = /^<!--\s*synapse-table\s+width="(\d+)"\s*-->$/i.exec(lines[0]?.trim() ?? '');
  const tableLines = widthMatch ? lines.slice(1) : lines;
  if (tableLines.length < 2) return undefined;
  const parsedRows = tableLines.map(parseTableRow);
  const columnCount = Math.max(1, ...parsedRows.map((row) => row.length));
  const normalize = (row: string[]) => [
    ...row,
    ...Array.from({ length: columnCount - row.length }, () => ''),
  ];
  return {
    width: widthMatch ? clampTableWidth(Number(widthMatch[1]), columnCount) : undefined,
    header: normalize(parsedRows[0]),
    alignments: normalize(parsedRows[1]),
    rows: parsedRows.slice(2).map(normalize),
    trailingNewline,
  };
}

function clampTableWidth(width: number, columnCount: number): number {
  return Math.max(columnCount * 64, Math.min(Math.max(1200, columnCount * 64), Math.round(width)));
}

function serializeTableModel(model: TableModel): string {
  const line = (row: string[]) => `| ${row.join(' | ')} |`;
  const markdown = [
    ...(model.width == null ? [] : [`<!-- synapse-table width="${clampTableWidth(model.width, model.header.length)}" -->`]),
    line(model.header),
    line(model.alignments.map((value) => /^:?-{3,}:?$/.test(value.replace(/\s/g, '')) ? value : '---')),
    ...model.rows.map(line),
  ].join('\n');
  return model.trailingNewline ? `${markdown}\n` : markdown;
}

function moveItem<T>(items: T[], from: number, to: number): T[] {
  if (from === to || from < 0 || to < 0 || from >= items.length || to >= items.length) return items;
  const result = [...items];
  const [moved] = result.splice(from, 1);
  result.splice(to, 0, moved);
  return result;
}

class TableWidget extends WidgetType {
  constructor(readonly block: MarkdownBlock, readonly editable: boolean) { super(); }

  eq(other: TableWidget): boolean {
    return other.block.from === this.block.from &&
      other.block.text === this.block.text &&
      other.editable === this.editable;
  }

  toDOM(): HTMLElement {
    const frame = document.createElement('div');
    frame.className = 'synapse-table-frame';
    frame.draggable = this.editable;
    frame.addEventListener('dragstart', (event) => {
      if ((event.target as Element).closest('.synapse-table-row-handle, .synapse-table-column-handle')) return;
      writeDraggedMarkdownRange(event, this.block.from, this.block.to);
    });
    const model = parseTableModel(this.block.text);
    if (!model) {
      frame.textContent = this.block.text;
      return frame;
    }
    let selectedRow = 0;
    let selectedColumn = 0;
    const commit = (next: TableModel) => {
      if (!view || !this.editable) return;
      const markdown = serializeTableModel(next);
      const previousHead = view.state.selection.main.head;
      const delta = markdown.length - (this.block.to - this.block.from);
      const anchor = previousHead <= this.block.from
        ? previousHead
        : previousHead >= this.block.to
          ? previousHead + delta
          : Math.min(
              view.state.doc.length + delta,
              this.block.from + markdown.length + 1,
            );
      view.dispatch({
        changes: { from: this.block.from, to: this.block.to, insert: markdown },
        selection: { anchor },
      });
    };
    if (this.editable) {
      const controls = document.createElement('div');
      controls.className = 'synapse-table-controls';
      const action = (label: string, title: string, invoke: () => void) => {
        const button = document.createElement('button');
        button.type = 'button';
        button.textContent = label;
        button.title = title;
        button.addEventListener('mousedown', (event) => event.preventDefault());
        button.addEventListener('click', invoke);
        controls.append(button);
      };
      action('+ 行', '在当前行下方插入', () => {
        const rows = [...model.rows];
        rows.splice(Math.max(0, selectedRow), 0, Array.from({ length: model.header.length }, () => ''));
        commit({ ...model, rows });
      });
      action('− 行', '删除当前行', () => {
        if (selectedRow <= 0) return;
        commit({ ...model, rows: model.rows.filter((_, index) => index !== selectedRow - 1) });
      });
      action('+ 列', '在当前列右侧插入', () => {
        const insertAt = Math.min(model.header.length, selectedColumn + 1);
        const insert = (row: string[]) => [...row.slice(0, insertAt), '', ...row.slice(insertAt)];
        commit({
          ...model,
          width: model.width == null ? undefined : clampTableWidth(model.width + 64, model.header.length + 1),
          header: insert(model.header),
          alignments: insert(model.alignments),
          rows: model.rows.map(insert),
        });
      });
      action('− 列', '删除当前列', () => {
        if (model.header.length <= 1) return;
        const remove = (row: string[]) => row.filter((_, index) => index !== selectedColumn);
        commit({
          ...model,
          header: remove(model.header),
          alignments: remove(model.alignments),
          rows: model.rows.map(remove),
        });
      });
      action('↑ 行', '上移当前行', () => {
        if (selectedRow <= 1) return;
        commit({ ...model, rows: moveItem(model.rows, selectedRow - 1, selectedRow - 2) });
      });
      action('↓ 行', '下移当前行', () => {
        if (selectedRow <= 0 || selectedRow >= model.rows.length) return;
        commit({ ...model, rows: moveItem(model.rows, selectedRow - 1, selectedRow) });
      });
      action('← 列', '左移当前列', () => {
        if (selectedColumn <= 0) return;
        const move = (row: string[]) => moveItem(row, selectedColumn, selectedColumn - 1);
        commit({ ...model, header: move(model.header), alignments: move(model.alignments), rows: model.rows.map(move) });
      });
      action('→ 列', '右移当前列', () => {
        if (selectedColumn >= model.header.length - 1) return;
        const move = (row: string[]) => moveItem(row, selectedColumn, selectedColumn + 1);
        commit({ ...model, header: move(model.header), alignments: move(model.alignments), rows: model.rows.map(move) });
      });
      frame.append(controls);
    }
    const table = document.createElement('table');
    if (model.width != null) table.style.width = `${model.width}px`;
    const rows = [model.header, ...model.rows];
    let draggedRow: number | undefined;
    let draggedColumn: number | undefined;
    rows.forEach((row, rowIndex) => {
      const tr = document.createElement('tr');
      if (this.editable) {
        const rowHandle = document.createElement('th');
        rowHandle.className = 'synapse-table-row-handle';
        rowHandle.title = rowIndex === 0 ? '表头' : '拖动调整行顺序';
        if (rowIndex > 0) {
          rowHandle.draggable = true;
          rowHandle.addEventListener('dragstart', (event) => {
            draggedRow = rowIndex - 1;
            if (event.dataTransfer) event.dataTransfer.effectAllowed = 'move';
          });
          rowHandle.addEventListener('dragover', (event) => event.preventDefault());
          rowHandle.addEventListener('drop', (event) => {
            event.preventDefault();
            const target = rowIndex - 1;
            if (draggedRow == null || draggedRow === target) return;
            commit({ ...model, rows: moveItem(model.rows, draggedRow, target) });
          });
        }
        tr.append(rowHandle);
      }
      row.forEach((value, columnIndex) => {
        const cell = document.createElement(rowIndex === 0 ? 'th' : 'td');
        cell.textContent = value.replace(/\\\|/g, '|');
        if (this.editable) {
          if (rowIndex === 0) {
            const columnHandle = document.createElement('span');
            columnHandle.className = 'synapse-table-column-handle';
            columnHandle.title = '拖动调整列顺序';
            columnHandle.draggable = true;
            columnHandle.addEventListener('mousedown', (event) => event.stopPropagation());
            columnHandle.addEventListener('dragstart', (event) => {
              event.stopPropagation();
              draggedColumn = columnIndex;
              if (event.dataTransfer) event.dataTransfer.effectAllowed = 'move';
            });
            columnHandle.addEventListener('dragover', (event) => event.preventDefault());
            columnHandle.addEventListener('drop', (event) => {
              event.preventDefault();
              event.stopPropagation();
              if (draggedColumn == null || draggedColumn === columnIndex) return;
              const move = (source: string[]) => moveItem(source, draggedColumn!, columnIndex);
              commit({
                ...model,
                header: move(model.header),
                alignments: move(model.alignments),
                rows: model.rows.map(move),
              });
            });
            cell.append(columnHandle);
          }
          cell.contentEditable = 'true';
          cell.spellcheck = false;
          cell.addEventListener('mousedown', (event) => {
            event.stopPropagation();
            selectedRow = rowIndex;
            selectedColumn = columnIndex;
          });
          cell.addEventListener('keydown', (event) => {
            if (event.key === 'Enter' && !event.shiftKey) {
              event.preventDefault();
              cell.blur();
            }
          });
          cell.addEventListener('blur', () => {
            const next = cell.textContent?.replace(/\r?\n/g, ' ') ?? '';
            const escaped = next.replace(/\|/g, '\\|');
            if (escaped === value) return;
            const updated: TableModel = {
              ...model,
              header: [...model.header],
              rows: model.rows.map((row) => [...row]),
            };
            if (rowIndex === 0) updated.header[columnIndex] = escaped;
            else updated.rows[rowIndex - 1][columnIndex] = escaped;
            commit(updated);
          });
        }
        tr.append(cell);
      });
      table.append(tr);
    });
    frame.append(table);
    if (this.editable) {
      const resize = document.createElement('span');
      resize.className = 'synapse-table-resize';
      resize.addEventListener('pointerdown', (event) => {
        event.preventDefault();
        event.stopPropagation();
        const startX = event.clientX;
        const startWidth = table.getBoundingClientRect().width;
        const move = (next: PointerEvent) => {
          table.style.width = `${clampTableWidth(startWidth + next.clientX - startX, model.header.length)}px`;
        };
        const end = () => {
          window.removeEventListener('pointermove', move);
          window.removeEventListener('pointerup', end);
          commit({ ...model, width: clampTableWidth(table.getBoundingClientRect().width, model.header.length) });
        };
        window.addEventListener('pointermove', move);
        window.addEventListener('pointerup', end, { once: true });
      });
      frame.append(resize);
    }
    frame.addEventListener('mousedown', (event) => {
      if ((event.target as HTMLElement).isContentEditable) return;
      event.preventDefault();
      safeDispatchSelection(this.block.from);
    });
    frame.addEventListener('contextmenu', (event) => {
      event.preventDefault();
      showContextMenu(event.clientX, event.clientY, this.block.from, this.block.to);
    });
    return frame;
  }

  ignoreEvent(): boolean { return false; }
}

const refreshColumnPreview = StateEffect.define<null>();

interface ColumnSideRuntime {
  parentView: EditorView;
  editorView: EditorView;
  baseOffset: number;
  toOffset: number;
  editable: boolean;
  syncing: boolean;
  editableCompartment: Compartment;
  themeCompartment: Compartment;
  host: HTMLElement;
  columnsState?: ColumnsDomState;
}

interface ColumnsDomState {
  widget: ColumnsWidget;
  parentView: EditorView;
  root: HTMLElement;
  content: HTMLElement;
  controls: HTMLElement;
  divider: HTMLElement;
  left: ColumnSideRuntime;
  right: ColumnSideRuntime;
  dragAnchor?: number;
  crossSelecting: boolean;
  pointerMove: (event: PointerEvent) => void;
  pointerUp: () => void;
}

const columnsDomStates = new WeakMap<HTMLElement, ColumnsDomState>();

function absoluteBlock(block: MarkdownBlock, baseOffset: number): MarkdownBlock {
  return {
    ...block,
    from: baseOffset + block.from,
    to: baseOffset + block.to,
  };
}

function buildColumnDecorations(state: EditorState, runtimeState: ColumnSideRuntime): DecorationSet {
  const doc = state.doc.toString();
  const blocks = splitMarkdownBlocks(doc);
  const active = activeBlockForSelection(blocks, selectionOf(state));
  const ranges: any[] = [];
  for (const block of blocks) {
    const activeBlock = runtimeState.editable && active?.from === block.from;
    const absolute = absoluteBlock(block, runtimeState.baseOffset);
    if (block.kind === 'pageBreak' && !activeBlock) {
      ranges.push(Decoration.replace({ widget: new PageBreakWidget(absolute.from), block: true }).range(block.from, block.to));
      continue;
    }
    if (block.kind === 'image') {
      const src = markdownImageSource(block.text);
      if (src) {
        ranges.push(Decoration.replace({
          widget: new ImageWidget(
            absolute.from,
            absolute.to,
            src,
            markdownImageWidth(block.text),
            true,
            block.text,
            activeBlock,
            runtimeState.editable,
          ),
          block: true,
        }).range(block.from, block.to));
      }
      continue;
    }
    if (block.kind === 'table' && !activeBlock) {
      ranges.push(Decoration.replace({ widget: new TableWidget(absolute, runtimeState.editable), block: true }).range(block.from, block.to));
      continue;
    }
    if (!activeBlock) {
      const images = imageRanges(block);
      const overlapsImage = (from: number, to: number) =>
        images.some((image) => from < image.to && to > image.from);
      for (const marker of markerRanges(block)) {
        if (!overlapsImage(marker.from, marker.to) && marker.from < marker.to) {
          ranges.push(Decoration.replace({}).range(marker.from, marker.to));
        }
      }
      for (const style of inlineStyleDecorations(block)) ranges.push(style);
      for (const image of images) {
        ranges.push(Decoration.replace({
          widget: new ImageWidget(
            runtimeState.baseOffset + image.from,
            runtimeState.baseOffset + image.to,
            image.src,
            image.width,
            false,
            doc.slice(image.from, image.to),
            false,
            runtimeState.editable,
          ),
        }).range(image.from, image.to));
      }
    }
    if (block.kind === 'heading') ranges.push(Decoration.line({ class: `synapse-heading synapse-heading-${block.level ?? 1}` }).range(block.from));
    if (block.kind === 'blockquote') ranges.push(Decoration.line({ class: 'synapse-blockquote' }).range(block.from));
    if (block.kind === 'code') ranges.push(Decoration.line({ class: 'synapse-code-block' }).range(block.from));
  }
  ranges.sort((left, right) => left.from - right.from || left.to - right.to);
  return Decoration.set(ranges, true);
}

function columnPreview(runtimeState: ColumnSideRuntime) {
  return StateField.define<DecorationSet>({
    create: (state) => buildColumnDecorations(state, runtimeState),
    update(value, transaction) {
      if (transaction.docChanged || transaction.selection || transaction.effects.some((effect) => effect.is(refreshColumnPreview))) {
        return buildColumnDecorations(transaction.state, runtimeState);
      }
      return value;
    },
    provide: (field) => EditorView.decorations.from(field),
  });
}

function columnEditorTheme(theme: EditorTheme) {
  return EditorView.theme({
    '&': { height: 'auto', color: theme.text, backgroundColor: 'transparent', fontSize: `${theme.fontSize}px` },
    '.cm-scroller': { overflow: 'visible', fontFamily: theme.fontFamily, lineHeight: '1.55' },
    '.cm-content': { minHeight: '112px', padding: '7px 0', caretColor: theme.accent },
    '.cm-focused': { outline: 'none' },
    '.cm-line': { padding: '3px 0' },
    '.cm-selectionBackground, ::selection': { backgroundColor: `${theme.accent}38 !important` },
    '.cm-cursor': { borderLeftColor: theme.accent },
  });
}

function sideSelection(
  selection: EditorSelection,
  from: number,
  to: number,
): EditorSelection {
  const clamp = (value: number) => Math.max(from, Math.min(value, to)) - from;
  return { anchor: clamp(selection.anchor), head: clamp(selection.head) };
}

function syncColumnRuntime(
  runtimeState: ColumnSideRuntime,
  source: string,
  from: number,
  to: number,
  editable: boolean,
  parentSelection: EditorSelection,
): void {
  const previousEditable = runtimeState.editable;
  runtimeState.baseOffset = from;
  runtimeState.toOffset = to;
  runtimeState.editable = editable;
  const sourceMatches = runtimeState.editorView.state.doc.toString() === source;
  if (runtimeState.editorView.composing && sourceMatches && previousEditable === editable) {
    return;
  }
  runtimeState.syncing = true;
  try {
    const childSelection = sideSelection(parentSelection, from, to);
    const query = getSearchQuery(runtimeState.parentView.state);
    const visible = runtimeState.parentView.state.field(searchVisibilityField);
    runtimeState.editorView.dispatch({
      changes: sourceMatches
        ? undefined
        : { from: 0, to: runtimeState.editorView.state.doc.length, insert: source },
      selection: childSelection,
      effects: [
        runtimeState.editableCompartment.reconfigure([
          EditorView.editable.of(editable),
          EditorState.readOnly.of(!editable),
        ]),
        runtimeState.themeCompartment.reconfigure(columnEditorTheme(runtime!.theme)),
        setSearchQuery.of(query),
        setSearchVisibility.of(visible),
        refreshColumnPreview.of(null),
      ],
      annotations: hostChange.of(true),
    });
  } finally {
    runtimeState.syncing = false;
  }
}

function createColumnEditor(
  host: HTMLElement,
  parentView: EditorView,
  source: string,
  from: number,
  to: number,
  editable: boolean,
): ColumnSideRuntime {
  const runtimeState = {
    parentView,
    editorView: undefined as unknown as EditorView,
    baseOffset: from,
    toOffset: to,
    editable,
    syncing: false,
    editableCompartment: new Compartment(),
    themeCompartment: new Compartment(),
    host,
  } satisfies ColumnSideRuntime;
  const query = getSearchQuery(parentView.state);
  runtimeState.editorView = new EditorView({
    parent: host,
    state: EditorState.create({
      doc: source,
      selection: sideSelection(selectionOf(parentView.state), from, to),
      extensions: [
        markdown(),
        syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
        drawSelection(),
        search({ top: true }),
        searchVisibilityField.init(() => parentView.state.field(searchVisibilityField)),
        searchHighlights,
        runtimeState.editableCompartment.of([
          EditorView.editable.of(editable),
          EditorState.readOnly.of(!editable),
        ]),
        runtimeState.themeCompartment.of(columnEditorTheme(runtime!.theme)),
        columnPreview(runtimeState),
        EditorView.lineWrapping,
        keymap.of([
          { key: 'Mod-z', preventDefault: true, run: () => view ? undo(view) : false },
          { key: 'Shift-Mod-z', preventDefault: true, run: () => view ? redo(view) : false },
          { key: 'Mod-y', preventDefault: true, run: () => view ? redo(view) : false },
          { key: 'Mod-b', preventDefault: true, run: () => requestCommand('format', 'bold') },
          { key: 'Mod-i', preventDefault: true, run: () => requestCommand('format', 'italic') },
          ...defaultKeymap,
          indentWithTab,
        ]),
        EditorView.updateListener.of((update) => {
          if (runtimeState.syncing) return;
          const external = update.transactions.every((transaction) => transaction.annotation(hostChange));
          if (update.docChanged && !external) {
            const changes: EditorChange[] = [];
            update.changes.iterChanges((fromA, toA, _fromB, _toB, inserted) => {
              changes.push({
                from: runtimeState.baseOffset + fromA,
                to: runtimeState.baseOffset + toA,
                insert: inserted.toString(),
              });
            });
            pendingNestedComposition = pendingNestedComposition || update.view.composing;
            parentView.dispatch({
              changes,
              selection: {
                anchor: runtimeState.baseOffset + update.state.selection.main.anchor,
                head: runtimeState.baseOffset + update.state.selection.main.head,
              },
            });
            return;
          }
          if (update.selectionSet && !external) {
            if (runtimeState.columnsState?.crossSelecting) return;
            parentView.dispatch({
              selection: {
                anchor: runtimeState.baseOffset + update.state.selection.main.anchor,
                head: runtimeState.baseOffset + update.state.selection.main.head,
              },
            });
          }
        }),
        EditorView.domEventHandlers({
          compositionstart() {
            pendingNestedComposition = true;
            return false;
          },
          compositionend() {
            window.setTimeout(() => {
              if (!pendingChanges) pendingNestedComposition = false;
            }, 0);
            return false;
          },
          focus() {
            post({ type: 'focusChanged', focused: true });
            return false;
          },
          contextmenu(event, editorView) {
            event.preventDefault();
            const local = editorView.posAtCoords({ x: event.clientX, y: event.clientY }) ?? editorView.state.selection.main.head;
            showContextMenu(event.clientX, event.clientY, runtimeState.baseOffset + local, runtimeState.baseOffset + local);
            return true;
          },
          paste(event, editorView) {
            const image = Array.from(event.clipboardData?.items ?? []).find((item) => item.type.startsWith('image/'));
            const file = image?.getAsFile();
            if (!file || !runtime?.editable) return false;
            event.preventDefault();
            const reader = new FileReader();
            reader.addEventListener('load', () => {
              const value = String(reader.result ?? '');
              const data = value.includes(',') ? value.slice(value.indexOf(',') + 1) : value;
              flushPendingTransaction();
              const selection = selectionOf(editorView.state);
              post({
                type: 'pasteImage',
                mimeType: file.type,
                filename: file.name || 'pasted.png',
                data,
                selection: {
                  anchor: runtimeState.baseOffset + selection.anchor,
                  head: runtimeState.baseOffset + selection.head,
                },
                revision: runtime!.revision,
              });
            });
            reader.readAsDataURL(file);
            return true;
          },
          dragover(event) {
            if (!runtime?.editable || !event.dataTransfer?.types.includes(markdownRangeDragType)) return false;
            event.preventDefault();
            return true;
          },
          drop(event, editorView) {
            const dragged = readDraggedMarkdownRange(event);
            if (!dragged || !runtime?.editable) return false;
            event.preventDefault();
            const local = editorView.posAtCoords({ x: event.clientX, y: event.clientY }) ?? editorView.state.selection.main.head;
            moveMarkdownRange(dragged, runtimeState.baseOffset + local);
            return true;
          },
        }),
      ],
    }),
  });
  runtimeState.syncing = true;
  runtimeState.editorView.dispatch({
    effects: setSearchQuery.of(query),
    annotations: hostChange.of(true),
  });
  runtimeState.syncing = false;
  return runtimeState;
}

function sideAtOffset(state: ColumnsDomState, offset: number): ColumnSideRuntime | undefined {
  if (offset >= state.left.baseOffset && offset <= state.left.toOffset) return state.left;
  if (offset >= state.right.baseOffset && offset <= state.right.toOffset) return state.right;
  return undefined;
}

function absolutePosAtCoords(state: ColumnsDomState, x: number, y: number): number | undefined {
  for (const side of [state.left, state.right]) {
    const bounds = side.host.getBoundingClientRect();
    if (x < bounds.left || x > bounds.right || y < bounds.top || y > bounds.bottom) continue;
    const local = side.editorView.posAtCoords({ x, y });
    return side.baseOffset + (local ?? (y < bounds.top + bounds.height / 2 ? 0 : side.editorView.state.doc.length));
  }
  return state.parentView.posAtCoords({ x, y }) ?? undefined;
}

class ColumnsWidget extends WidgetType {
  constructor(
    readonly from: number,
    readonly to: number,
    readonly left: string,
    readonly right: string,
    readonly leftOffset: number,
    readonly leftTo: number,
    readonly rightOffset: number,
    readonly rightTo: number,
    readonly ratio: number,
    readonly editable: boolean,
  ) { super(); }

  eq(other: ColumnsWidget): boolean {
    return other.from === this.from && other.to === this.to && other.left === this.left && other.right === this.right && other.ratio === this.ratio && other.editable === this.editable;
  }

  toDOM(parentView: EditorView): HTMLElement {
    const root = document.createElement('div');
    root.className = 'synapse-columns';
    const content = document.createElement('div');
    content.className = 'synapse-columns-content';
    content.style.gridTemplateColumns = `${this.ratio}fr 10px ${100 - this.ratio}fr`;
    const controls = document.createElement('div');
    controls.className = 'synapse-columns-controls';
    controls.hidden = !this.editable;
    root.classList.toggle('synapse-columns-editable', this.editable);
    const left = document.createElement('div');
    const right = document.createElement('div');
    left.className = 'synapse-column';
    right.className = 'synapse-column';
    const leftRuntime = createColumnEditor(left, parentView, this.left, this.leftOffset, this.leftTo, this.editable);
    const rightRuntime = createColumnEditor(right, parentView, this.right, this.rightOffset, this.rightTo, this.editable);
    const divider = document.createElement('span');
    divider.className = 'synapse-columns-divider';
    content.append(left, divider, right);
    root.append(controls, content);
    const state = {
      widget: this,
      parentView,
      root,
      content,
      controls,
      divider,
      left: leftRuntime,
      right: rightRuntime,
      pointerMove: (_event: PointerEvent) => {},
      pointerUp: () => {},
      crossSelecting: false,
    } satisfies ColumnsDomState;
    leftRuntime.columnsState = state;
    rightRuntime.columnsState = state;
    columnsDomStates.set(root, state);
    const action = (label: string, invoke: (widget: ColumnsWidget) => void) => {
      const button = document.createElement('button');
      button.type = 'button';
      button.textContent = label;
      button.addEventListener('mousedown', (event) => event.preventDefault());
      button.addEventListener('click', () => invoke(state.widget));
      controls.append(button);
    };
    const commitRatio = (widget: ColumnsWidget, ratio: number) => {
      const marker = parentView.state.doc.sliceString(widget.from, widget.leftOffset);
      const updated = marker.replace(
        /<!--\s*synapse:columns(?:\s+ratio="\d+:\d+")?\s*-->/,
        `<!-- synapse:columns ratio="${ratio}:${100 - ratio}" -->`,
      );
      parentView.dispatch({
        changes: { from: widget.from, to: widget.leftOffset, insert: updated },
        selection: { anchor: widget.leftOffset + updated.length - marker.length },
      });
    };
    action('1:1', (widget) => commitRatio(widget, 50));
    action('2:3', (widget) => commitRatio(widget, 40));
    action('3:2', (widget) => commitRatio(widget, 60));
    action('下方全宽', (widget) => safeDispatchSelection(widget.to));
    action('取消双栏', (widget) => {
      parentView.dispatch({
        changes: { from: widget.from, to: widget.to, insert: `${widget.left}${widget.right}` },
        selection: { anchor: widget.from },
      });
    });
    divider.addEventListener('pointerdown', (event) => {
      if (!state.widget.editable) return;
      event.preventDefault();
      const bounds = content.getBoundingClientRect();
      const move = (next: PointerEvent) => {
        const ratio = Math.max(30, Math.min(70, Math.round((next.clientX - bounds.left) / bounds.width * 100)));
        content.style.gridTemplateColumns = `${ratio}fr 10px ${100 - ratio}fr`;
        divider.dataset.ratio = String(ratio);
      };
      const end = () => {
        window.removeEventListener('pointermove', move);
        window.removeEventListener('pointerup', end);
        const widget = state.widget;
        const ratio = Number(divider.dataset.ratio ?? widget.ratio);
        if (ratio !== widget.ratio) commitRatio(widget, ratio);
      };
      window.addEventListener('pointermove', move);
      window.addEventListener('pointerup', end, { once: true });
    });
    for (const side of [leftRuntime, rightRuntime]) {
      side.host.addEventListener('pointerdown', (event) => {
        if (event.button !== 0) return;
        const local = side.editorView.posAtCoords({ x: event.clientX, y: event.clientY });
        state.dragAnchor = side.baseOffset + (local ?? side.editorView.state.selection.main.anchor);
        state.crossSelecting = false;
      }, true);
    }
    state.pointerMove = (event: PointerEvent) => {
      if ((event.buttons & 1) === 0) return;
      const target = absolutePosAtCoords(state, event.clientX, event.clientY);
      if (target == null) return;
      const anchor = state.dragAnchor ?? state.parentView.state.selection.main.anchor;
      const anchorSide = sideAtOffset(state, anchor);
      const targetSide = sideAtOffset(state, target);
      if (anchorSide != null && anchorSide === targetSide) return;
      state.crossSelecting = true;
      state.parentView.dispatch({ selection: { anchor, head: target } });
    };
    state.pointerUp = () => {
      state.dragAnchor = undefined;
      state.crossSelecting = false;
    };
    window.addEventListener('pointermove', state.pointerMove);
    window.addEventListener('pointerup', state.pointerUp);
    const copySourceSelection = (event: ClipboardEvent, cut: boolean) => {
      const selection = state.parentView.state.selection.main;
      if (selection.empty || selection.to <= state.widget.from || selection.from >= state.widget.to) return;
      event.preventDefault();
      event.clipboardData?.setData('text/plain', state.parentView.state.doc.sliceString(selection.from, selection.to));
      if (cut && state.widget.editable) {
        state.parentView.dispatch({
          changes: { from: selection.from, to: selection.to, insert: '' },
          selection: { anchor: selection.from },
        });
      }
    };
    root.addEventListener('copy', (event) => copySourceSelection(event, false), true);
    root.addEventListener('cut', (event) => copySourceSelection(event, true), true);
    return root;
  }

  ignoreEvent(): boolean { return false; }

  updateDOM(dom: HTMLElement, parentView: EditorView): boolean {
    const state = columnsDomStates.get(dom);
    if (!state) return false;
    state.widget = this;
    state.parentView = parentView;
    state.controls.hidden = !this.editable;
    state.root.classList.toggle('synapse-columns-editable', this.editable);
    state.content.style.gridTemplateColumns = `${this.ratio}fr 10px ${100 - this.ratio}fr`;
    syncColumnRuntime(state.left, this.left, this.leftOffset, this.leftTo, this.editable, selectionOf(parentView.state));
    syncColumnRuntime(state.right, this.right, this.rightOffset, this.rightTo, this.editable, selectionOf(parentView.state));
    return true;
  }

  destroy(dom: HTMLElement): void {
    const state = columnsDomStates.get(dom);
    if (!state) return;
    window.removeEventListener('pointermove', state.pointerMove);
    window.removeEventListener('pointerup', state.pointerUp);
    state.left.editorView.destroy();
    state.right.editorView.destroy();
    columnsDomStates.delete(dom);
  }
}

function syncVisibleColumns(): void {
  if (!view || !runtime) return;
  for (const root of document.querySelectorAll<HTMLElement>('.synapse-columns')) {
    const state = columnsDomStates.get(root);
    if (!state) continue;
    const widget = state.widget;
    syncColumnRuntime(state.left, widget.left, widget.leftOffset, widget.leftTo, widget.editable, selectionOf(view.state));
    syncColumnRuntime(state.right, widget.right, widget.rightOffset, widget.rightTo, widget.editable, selectionOf(view.state));
  }
}

function markerRanges(block: MarkdownBlock): Array<{ from: number; to: number }> {
  const result: Array<{ from: number; to: number }> = [];
  const text = block.text;
  if (block.kind === 'heading') {
    const match = /^(#{1,6}\s+)/.exec(text);
    if (match) result.push({ from: block.from, to: block.from + match[1].length });
  }
  let lineOffset = 0;
  for (const line of text.split('\n')) {
    const match = /^(\s*(?:>\s?|[-*+]\s+|\d+[.)]\s+))/.exec(line);
    if (match) result.push({ from: block.from + lineOffset, to: block.from + lineOffset + match[1].length });
    lineOffset += line.length + 1;
  }
  const paired = /(?:\*\*|__|~~|==|`)/g;
  for (const match of text.matchAll(paired)) {
    const start = block.from + (match.index ?? 0);
    result.push({ from: start, to: start + match[0].length });
  }
  const links = /\[([^\]]+)\]\(([^)]+)\)/g;
  for (const match of text.matchAll(links)) {
    const start = block.from + (match.index ?? 0);
    result.push({ from: start, to: start + 1 });
    result.push({
      from: start + 1 + match[1].length,
      to: start + match[0].length,
    });
  }
  return result;
}

function inlineStyleDecorations(block: MarkdownBlock) {
  const ranges = [];
  const patterns: Array<{ pattern: RegExp; className: string }> = [
    { pattern: /\*\*([^\n]+?)\*\*/g, className: 'synapse-bold' },
    { pattern: /__([^\n]+?)__/g, className: 'synapse-bold' },
    { pattern: /~~([^\n]+?)~~/g, className: 'synapse-strike' },
    { pattern: /==([^\n]+?)==/g, className: 'synapse-highlight' },
    { pattern: /`([^\n]+?)`/g, className: 'synapse-inline-code' },
    { pattern: /(?<!\*)\*([^*\n]+?)\*(?!\*)/g, className: 'synapse-italic' },
  ];
  for (const { pattern, className } of patterns) {
    for (const match of block.text.matchAll(pattern)) {
      const content = match[1];
      const contentOffset = match[0].indexOf(content);
      const from = block.from + (match.index ?? 0) + contentOffset;
      ranges.push(Decoration.mark({ class: className }).range(from, from + content.length));
    }
  }
  const links = /\[([^\]]+)\]\(([^)]+)\)/g;
  for (const match of block.text.matchAll(links)) {
    const from = block.from + (match.index ?? 0) + 1;
    ranges.push(
      Decoration.mark({
        class: 'synapse-link',
        attributes: { 'data-href': match[2] },
      }).range(from, from + match[1].length),
    );
  }
  return ranges;
}

function imageRanges(block: MarkdownBlock): Array<{ from: number; to: number; src: string; width: number }> {
  const result: Array<{ from: number; to: number; src: string; width: number }> = [];
  const pattern = /!\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)|<img\b[^>]*\bsrc=(?:"([^"]+)"|'([^']+)')[^>]*>/gi;
  for (const match of block.text.matchAll(pattern)) {
    const src = match[1] ?? match[2] ?? match[3];
    if (!src) continue;
    const from = block.from + (match.index ?? 0);
    result.push({ from, to: from + match[0].length, src, width: markdownImageWidth(match[0]) });
  }
  return result;
}

function columnsDecoration(
  blocks: MarkdownBlock[],
  editable: boolean,
  documentText: string,
): Array<{ from: number; to: number; widget: ColumnsWidget }> {
  const result: Array<{ from: number; to: number; widget: ColumnsWidget }> = [];
  for (let index = 0; index < blocks.length; index += 1) {
    const start = blocks[index];
    if (start.kind !== 'columnsStart') continue;
    const separatorIndex = blocks.findIndex((candidate, candidateIndex) => candidateIndex > index && candidate.kind === 'columnsSeparator');
    const endIndex = blocks.findIndex((candidate, candidateIndex) => candidateIndex > separatorIndex && candidate.kind === 'columnsEnd');
    if (separatorIndex < 0 || endIndex < 0) continue;
    const separator = blocks[separatorIndex];
    const end = blocks[endIndex];
    const ratioMatch = /ratio="(\d+):(\d+)"/.exec(start.text);
    const leftValue = Number(ratioMatch?.[1] ?? 50);
    const rightValue = Number(ratioMatch?.[2] ?? 50);
    const ratio = Math.max(30, Math.min(70, Math.round(leftValue / (leftValue + rightValue) * 100)));
    const leftOffset = start.to;
    const rightOffset = separator.to;
    result.push({
      from: start.from,
      to: end.to,
      widget: new ColumnsWidget(
        start.from,
        end.to,
        documentText.slice(start.to, separator.from),
        documentText.slice(separator.to, end.from),
        leftOffset,
        separator.from,
        rightOffset,
        end.from,
        ratio,
        editable,
      ),
    });
    index = endIndex;
  }
  return result;
}

function buildDecorations(state: EditorState): DecorationSet {
  const doc = state.doc.toString();
  const modeValue = state.field(modeField);
  const mode = modeValue.mode;
  const editable = mode === 'editing' && modeValue.editable;
  const selection = selectionOf(state);
  const blocks = splitMarkdownBlocks(doc);
  const active = activeBlockForSelection(blocks, selection);
  const ranges: Array<ReturnType<typeof Decoration.replace>['range'] extends never ? never : any> = [];

  for (const column of columnsDecoration(blocks, editable, doc)) {
    ranges.push(Decoration.replace({ widget: column.widget, block: true }).range(column.from, column.to));
  }
  const covered = ranges.map((range: { from: number; to: number }) => ({ from: range.from, to: range.to }));

  for (const block of blocks) {
    if (covered.some((range) => block.from >= range.from && block.to <= range.to)) continue;
    const activeBlock = mode === 'editing' && active?.from === block.from;
    if (block.kind === 'pageBreak' && !activeBlock) {
      ranges.push(Decoration.replace({ widget: new PageBreakWidget(block.from), block: true }).range(block.from, block.to));
      continue;
    }
    if (block.kind === 'image') {
      const src = markdownImageSource(block.text);
      if (src) ranges.push(Decoration.replace({ widget: new ImageWidget(block.from, block.to, src, markdownImageWidth(block.text), true, block.text, activeBlock, editable), block: true }).range(block.from, block.to));
      continue;
    }
    if (block.kind === 'table' && !activeBlock) {
      ranges.push(Decoration.replace({ widget: new TableWidget(block, editable), block: true }).range(block.from, block.to));
      continue;
    }
    if (!activeBlock) {
      const images = imageRanges(block);
      const overlapsImage = (from: number, to: number) =>
        images.some((image) => from < image.to && to > image.from);
      for (const marker of markerRanges(block)) {
        if (overlapsImage(marker.from, marker.to)) continue;
        if (marker.from < marker.to) ranges.push(Decoration.replace({}).range(marker.from, marker.to));
      }
      for (const style of inlineStyleDecorations(block)) ranges.push(style);
      for (const image of images) {
        ranges.push(Decoration.replace({ widget: new ImageWidget(image.from, image.to, image.src, image.width, false, doc.slice(image.from, image.to), false, editable) }).range(image.from, image.to));
      }
    }
    if (block.kind === 'heading') ranges.push(Decoration.line({ class: `synapse-heading synapse-heading-${block.level ?? 1}` }).range(block.from));
    if (block.kind === 'blockquote') ranges.push(Decoration.line({ class: 'synapse-blockquote' }).range(block.from));
    if (block.kind === 'code') ranges.push(Decoration.line({ class: 'synapse-code-block' }).range(block.from));
  }
  ranges.sort((left, right) => left.from - right.from || left.to - right.to);
  return Decoration.set(ranges, true);
}

const livePreview = StateField.define<DecorationSet>({
  create: (state) => buildDecorations(state),
  update(value, transaction) {
    if (
      transaction.docChanged ||
      transaction.selection ||
      transaction.effects.some((effect) => effect.is(setMode))
    ) {
      return buildDecorations(transaction.state);
    }
    return value;
  },
  provide: (field) => EditorView.decorations.from(field),
});

interface SearchMatchRange {
  from: number;
  to: number;
}

function collectSearchMatches(state: EditorState): SearchMatchRange[] {
  if (!state.field(searchVisibilityField)) return [];
  const query = getSearchQuery(state);
  if (!query.valid || query.search.length === 0) return [];
  const cursor = query.getCursor(state);
  const matches: SearchMatchRange[] = [];
  while (true) {
    const next = cursor.next();
    if (next.done) break;
    matches.push({ from: next.value.from, to: next.value.to });
  }
  return matches;
}

function currentSearchIndex(state: EditorState, matches: SearchMatchRange[]): number {
  const selection = state.selection.main;
  return matches.findIndex((match) => match.from === selection.from && match.to === selection.to);
}

function buildSearchDecorations(state: EditorState): DecorationSet {
  const matches = collectSearchMatches(state);
  const current = currentSearchIndex(state, matches);
  return Decoration.set(matches.map((match, index) => Decoration.mark({
    class: index === current ? 'synapse-search-match synapse-search-current' : 'synapse-search-match',
  }).range(match.from, match.to)));
}

const searchHighlights = StateField.define<DecorationSet>({
  create: (state) => buildSearchDecorations(state),
  update(value, transaction) {
    if (transaction.docChanged || transaction.selection || transaction.effects.length > 0) {
      return buildSearchDecorations(transaction.state);
    }
    return value;
  },
  provide: (field) => EditorView.decorations.from(field),
});

function scheduleCommandState(): void {
  if (commandStateFrame) return;
  commandStateFrame = window.setTimeout(() => {
    commandStateFrame = 0;
    postCommandState();
  }, 0);
}

function postCommandState(): void {
  if (!runtime || !view) return;
  const query = getSearchQuery(view.state);
  const matches = collectSearchMatches(view.state);
  post({
    type: 'commandState',
    revision: runtime.revision,
    selection: selectionOf(view.state),
    canUndo: undoDepth(view.state) > 0,
    canRedo: redoDepth(view.state) > 0,
    search: {
      query: query.search,
      replacement: query.replace,
      caseSensitive: query.caseSensitive,
      wholeWord: query.wholeWord,
      visible: view.state.field(searchVisibilityField),
      currentIndex: currentSearchIndex(view.state, matches),
      matches,
    },
  });
}

function schedulePerformanceSample(name: string, startedAt: number | undefined): void {
  if (startedAt == null) return;
  requestAnimationFrame(() => {
    post({ type: 'performanceSample', name, durationMs: performance.now() - startedAt });
  });
}

function editorTheme(theme: EditorTheme) {
  return EditorView.theme({
    '&': { height: '100%', color: theme.text, backgroundColor: theme.background, fontSize: `${theme.fontSize}px` },
    '.cm-scroller': { overflow: 'auto', fontFamily: theme.fontFamily, lineHeight: '1.55' },
    '.cm-content': { minHeight: '100%', padding: '54px 16px 18px', caretColor: theme.accent },
    '.cm-focused': { outline: 'none' },
    '.cm-line': { padding: '3px 0' },
    '.cm-selectionBackground, ::selection': { backgroundColor: `${theme.accent}38 !important` },
    '.cm-cursor': { borderLeftColor: theme.accent },
    '.synapse-heading': { fontWeight: '700', lineHeight: '1.3' },
    '.synapse-heading-1': { fontSize: '1.85em' },
    '.synapse-heading-2': { fontSize: '1.55em' },
    '.synapse-heading-3': { fontSize: '1.3em' },
    '.synapse-heading-4': { fontSize: '1.15em' },
    '.synapse-blockquote': { borderLeft: `3px solid ${theme.line}`, paddingLeft: '12px', color: theme.muted },
    '.synapse-code-block': { backgroundColor: theme.codeBackground, fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace' },
    '.synapse-page-break': { display: 'flex', alignItems: 'center', gap: '10px', color: theme.muted, fontSize: '12px', padding: '10px 0' },
    '.synapse-page-break > span:first-child, .synapse-page-break > span:last-child': { height: '1px', backgroundColor: theme.line, flex: '1' },
    '.synapse-image-block': { position: 'relative', display: 'block', width: 'fit-content', maxWidth: '100%', margin: '5px 0' },
    '.synapse-inline-image': { position: 'relative', display: 'inline-block', verticalAlign: 'middle', maxWidth: '100%' },
    '.synapse-image-block img, .synapse-inline-image img': { display: 'block', height: 'auto', borderRadius: '6px' },
    '.synapse-image-selected': { outline: `1px solid ${theme.accent}`, outlineOffset: '3px', borderRadius: '6px' },
    '.synapse-image-source': { display: 'block', width: '100%', minWidth: '320px', minHeight: '42px', boxSizing: 'border-box', marginBottom: '6px', border: `1px solid ${theme.line}`, borderRadius: '5px', padding: '6px 8px', color: theme.text, backgroundColor: theme.background, font: '12px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace', resize: 'vertical' },
    '.synapse-image-loading': { color: theme.muted, fontSize: '12px' },
    '.synapse-image-broken': { color: theme.muted, textDecoration: 'line-through' },
    '.synapse-image-resize': { position: 'absolute', right: '-5px', bottom: '-5px', width: '10px', height: '10px', borderRadius: '50%', backgroundColor: theme.accent, cursor: 'nwse-resize' },
    '.synapse-image-drop-target': { outline: `2px solid ${theme.accent}`, outlineOffset: '3px' },
    '.synapse-bold': { fontWeight: '700' },
    '.synapse-italic': { fontStyle: 'italic' },
    '.synapse-strike': { textDecoration: 'line-through' },
    '.synapse-highlight': { backgroundColor: theme.highlight, borderRadius: '2px' },
    '.synapse-inline-code': { backgroundColor: theme.codeBackground, fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace', borderRadius: '3px', padding: '1px 3px' },
    '.synapse-search-match': { backgroundColor: `${theme.highlight}a8`, borderRadius: '2px' },
    '.synapse-search-current': { outline: `1px solid ${theme.accent}`, backgroundColor: `${theme.accent}2e` },
    '.synapse-link': { color: theme.accent, textDecoration: 'underline', cursor: 'pointer' },
    '.synapse-table-frame': { position: 'relative', overflowX: 'auto', border: `1px solid ${theme.line}`, borderRadius: '7px', margin: '4px 0' },
    '.synapse-table-controls': { position: 'sticky', left: '0', display: 'flex', gap: '3px', padding: '4px 6px', borderBottom: `1px solid ${theme.line}`, backgroundColor: theme.surface },
    '.synapse-table-controls button': { border: `1px solid ${theme.line}`, borderRadius: '4px', padding: '2px 6px', color: theme.text, backgroundColor: theme.background, font: '11px/1.4 inherit' },
    '.synapse-table-frame table': { minWidth: '100%', borderCollapse: 'collapse' },
    '.synapse-table-frame th, .synapse-table-frame td': { borderRight: `1px solid ${theme.line}`, borderBottom: `1px solid ${theme.line}`, padding: '8px 10px', textAlign: 'left' },
    '.synapse-table-frame th': { backgroundColor: theme.surface, fontWeight: '650' },
    '.synapse-table-row-handle': { width: '22px', minWidth: '22px', padding: '0 !important', cursor: 'grab' },
    '.synapse-table-row-handle::before': { content: '"⋮⋮"', color: theme.muted, fontSize: '10px' },
    '.synapse-table-column-handle': { float: 'right', width: '16px', height: '16px', cursor: 'grab' },
    '.synapse-table-column-handle::before': { content: '"⋮"', color: theme.muted, fontSize: '11px' },
    '.synapse-table-resize': { position: 'absolute', top: '0', right: '0', bottom: '0', width: '8px', cursor: 'col-resize', backgroundColor: 'transparent' },
    '.synapse-columns': { border: '1px solid transparent', borderRadius: '7px', overflowX: 'auto' },
    '.synapse-columns-editable': { borderColor: theme.line },
    '.synapse-columns-controls': { display: 'flex', gap: '4px', alignItems: 'center', padding: '4px 7px', borderBottom: `1px solid ${theme.line}`, backgroundColor: theme.surface },
    '.synapse-columns-controls button': { border: '0', borderRadius: '4px', padding: '3px 6px', color: theme.text, backgroundColor: 'transparent', font: '11px/1.4 inherit' },
    '.synapse-columns-content': { display: 'grid', alignItems: 'stretch' },
    '.synapse-column': { minWidth: '240px', padding: '4px 10px', overflow: 'visible' },
    '.synapse-column > .cm-editor': { height: 'auto' },
    '.synapse-columns-divider': { width: '10px', cursor: 'col-resize', borderLeft: `1px solid ${theme.line}`, borderRight: `1px solid ${theme.line}`, backgroundColor: theme.surface },
    '.synapse-projected-line': { minHeight: '1.55em', whiteSpace: 'pre-wrap' },
    '.synapse-context-menu': { position: 'fixed', zIndex: '2147483647', minWidth: '190px', padding: '6px', borderRadius: '8px', border: `1px solid ${theme.line}`, backgroundColor: theme.surface, boxShadow: '0 12px 34px rgba(0,0,0,.18)' },
    '.synapse-context-menu button': { display: 'block', width: '100%', border: '0', borderRadius: '5px', padding: '7px 9px', textAlign: 'left', color: theme.text, background: 'transparent', font: 'inherit' },
    '.synapse-context-menu button:hover': { backgroundColor: `${theme.accent}18` },
    '.synapse-context-submenu-group': { position: 'relative' },
    '.synapse-context-submenu': { position: 'absolute', left: 'calc(100% - 2px)', top: '-6px', minWidth: '170px', padding: '6px', borderRadius: '8px', border: `1px solid ${theme.line}`, backgroundColor: theme.surface, boxShadow: '0 12px 34px rgba(0,0,0,.18)' },
    '.synapse-context-submenu[hidden]': { display: 'none' },
  });
}

function updateListener(update: ViewUpdate): void {
  if (!runtime) return;
  const external = update.transactions.every((transaction) => transaction.annotation(hostChange));
  if (update.docChanged && !external) {
    let composed: ChangeSet | undefined;
    for (const transaction of update.transactions) composed = composed ? composed.compose(transaction.changes) : transaction.changes;
    if (composed) pendingChanges = pendingChanges ? pendingChanges.compose(composed) : composed;
    scheduleTransaction();
    scheduleOutline();
    schedulePerformanceSample('inputToPaint', inputStartedAt);
    inputStartedAt = undefined;
  }
  if (update.selectionSet) {
    post({ type: 'selectionChanged', revision: runtime.revision, selection: selectionOf(update.state) });
    schedulePerformanceSample('pointerToSelectionPaint', pointerStartedAt);
    pointerStartedAt = undefined;
  }
  if (update.docChanged || update.selectionSet || update.transactions.some((transaction) => transaction.effects.length > 0)) {
    scheduleCommandState();
  }
}

function scheduleTransaction(): void {
  if (pendingFrame) return;
  pendingFrame = requestAnimationFrame(() => {
    pendingFrame = 0;
    flushPendingTransaction();
  });
}

function flushPendingTransaction(): void {
  if (!runtime || !view || !pendingChanges) return;
  const changes: EditorChange[] = [];
  pendingChanges.iterChanges((fromA, toA, _fromB, _toB, inserted) => {
    changes.push({ from: fromA, to: toA, insert: inserted.toString() });
  });
  pendingChanges = undefined;
  const baseRevision = runtime.revision;
  runtime.revision += 1;
  runtime.clientSeq += 1;
  const composing = view.composing || pendingNestedComposition;
  pendingNestedComposition = false;
  post({
    type: 'transaction',
    baseRevision,
    revision: runtime.revision,
    clientSeq: runtime.clientSeq,
    changes,
    selection: selectionOf(view.state),
    composing,
    origin: composing ? 'composition' : 'input',
  });
  scheduleCommandState();
}

function scheduleOutline(): void {
  window.clearTimeout(outlineTimer);
  outlineTimer = window.setTimeout(() => {
    if (!runtime || !view) return;
    const outline: Array<{ level: number; title: string; line: number; offset: number }> = [];
    syntaxTree(view.state).iterate({
      enter(node) {
        const match = /^ATXHeading([1-6])$/.exec(node.name);
        if (!match) return;
        const source = view!.state.doc.sliceString(node.from, node.to);
        outline.push({
          level: Number(match[1]),
          title: source.replace(/^#{1,6}\s+/, '').replace(/\s+#+\s*$/, '').trim(),
          line: view!.state.doc.lineAt(node.from).number,
          offset: node.from,
        });
      },
    });
    post({ type: 'outlineChanged', revision: runtime.revision, outline });
  }, 80);
}

function extensions(command: InitializeCommand) {
  const jsdom = navigator.userAgent.toLowerCase().includes('jsdom');
  return [
    markdown(),
    syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
    history(),
    ...(!jsdom ? [drawSelection(), highlightActiveLine()] : []),
    search({ top: true }),
    keymap.of([
      {
        key: 'Mod-f',
        preventDefault: true,
        run: () => {
          post({ type: 'findRequest', replace: false });
          return true;
        },
      },
      {
        key: 'Alt-Mod-f',
        preventDefault: true,
        run: () => {
          post({ type: 'findRequest', replace: true });
          return true;
        },
      },
      {
        key: 'Ctrl-h',
        preventDefault: true,
        run: () => {
          post({ type: 'findRequest', replace: true });
          return true;
        },
      },
      { key: 'Mod-b', preventDefault: true, run: () => requestCommand('format', 'bold') },
      { key: 'Mod-i', preventDefault: true, run: () => requestCommand('format', 'italic') },
      {
        key: 'Shift-F10',
        preventDefault: true,
        run: (editorView) => {
          const head = editorView.state.selection.main.head;
          const coordinates = editorView.coordsAtPos(head);
          showContextMenu(coordinates?.left ?? 20, coordinates?.bottom ?? 20, head, head);
          return true;
        },
      },
      ...defaultKeymap,
      ...historyKeymap,
      indentWithTab,
    ]),
    modeField.init(() => ({ mode: command.mode, editable: command.editable, focused: command.focused })),
    searchVisibilityField,
    editableCompartment.of([EditorView.editable.of(command.editable), EditorState.readOnly.of(!command.editable)]),
    themeCompartment.of(editorTheme(command.theme)),
    livePreview,
    searchHighlights,
    placeholder('选择或创建笔记后开始整理 Markdown'),
    EditorView.lineWrapping,
    EditorView.updateListener.of(updateListener),
    EditorView.domEventHandlers({
      beforeinput() {
        inputStartedAt = performance.now();
        return false;
      },
      pointerdown() {
        pointerStartedAt = performance.now();
        return false;
      },
      focus() {
        post({ type: 'focusChanged', focused: true });
        return false;
      },
      blur() {
        post({ type: 'focusChanged', focused: false });
        return false;
      },
      contextmenu(event, editorView) {
        event.preventDefault();
        const position = editorView.posAtCoords({ x: event.clientX, y: event.clientY }) ?? editorView.state.selection.main.head;
        showContextMenu(event.clientX, event.clientY, position, position);
        return true;
      },
      click(event) {
        const target = event.target instanceof Element
          ? event.target.closest<HTMLElement>('.synapse-link')
          : null;
        const href = target?.dataset.href;
        if (!href) return false;
        event.preventDefault();
        post({ type: 'openLink', href });
        return true;
      },
      paste(event) {
        const image = Array.from(event.clipboardData?.items ?? []).find((item) => item.type.startsWith('image/'));
        const file = image?.getAsFile();
        if (!file || !runtime?.editable) return false;
        event.preventDefault();
        const reader = new FileReader();
        reader.addEventListener('load', () => {
          const value = String(reader.result ?? '');
          const data = value.includes(',') ? value.slice(value.indexOf(',') + 1) : value;
          flushPendingTransaction();
          post({ type: 'pasteImage', mimeType: file.type, filename: file.name || 'pasted.png', data, selection: selectionOf(view!.state), revision: runtime!.revision });
        });
        reader.readAsDataURL(file);
        return true;
      },
    }),
  ];
}

function initialize(command: InitializeCommand): void {
  view?.destroy();
  clearAttachmentState();
  pendingChanges = undefined;
  if (pendingFrame) cancelAnimationFrame(pendingFrame);
  if (commandStateFrame) window.clearTimeout(commandStateFrame);
  pendingFrame = 0;
  commandStateFrame = 0;
  runtime = {
    paneId: command.paneId,
    noteId: command.noteId,
    generation: command.generation,
    revision: command.revision,
    clientSeq: 0,
    mode: command.mode,
    editable: command.editable,
    focused: command.focused,
    theme: command.theme,
  };
  const parent = document.querySelector<HTMLElement>('#editor');
  if (!parent) throw new Error('Missing #editor host.');
  parent.replaceChildren();
  view = new EditorView({
    parent,
    state: EditorState.create({
      doc: command.markdown,
      selection: CmSelection.single(command.selection.anchor, command.selection.head),
      extensions: extensions(command),
    }),
  });
  if (command.focused && command.editable) view.focus();
  post({ type: 'ready', revision: runtime.revision });
  scheduleOutline();
  scheduleCommandState();
}

function applyChanges(command: Extract<HostCommand, { type: 'applyChanges' }>): void {
  if (!view || !runtime || command.generation !== runtime.generation) return;
  if (command.baseRevision !== runtime.revision) {
    post({ type: 'error', message: `Revision mismatch: expected ${runtime.revision}, received ${command.baseRevision}` });
    return;
  }
  view.dispatch({
    changes: command.changes,
    selection: command.selection ? { anchor: command.selection.anchor, head: command.selection.head } : undefined,
    annotations: [
      hostChange.of(true),
      Transaction.addToHistory.of(command.addToHistory ?? false),
    ],
  });
  runtime.revision = command.revision;
}

function replaceDocument(command: Extract<HostCommand, { type: 'replaceDocument' }>): void {
  if (!view || !runtime || command.generation !== runtime.generation) return;
  view.dispatch({
    changes: { from: 0, to: view.state.doc.length, insert: command.markdown },
    selection: command.selection ? { anchor: command.selection.anchor, head: command.selection.head } : { anchor: Math.min(view.state.selection.main.head, command.markdown.length) },
    annotations: [
      hostChange.of(true),
      Transaction.addToHistory.of(command.addToHistory ?? false),
    ],
  });
  runtime.revision = command.revision;
  pendingChanges = undefined;
  scheduleOutline();
}

function setSearch(command: Extract<HostCommand, { type: 'setSearch' }>): void {
  if (!view) return;
  const previousQuery = getSearchQuery(view.state);
  const previousMatches = collectSearchMatches(view.state);
  const previousIndex = currentSearchIndex(view.state, previousMatches);
  const anchor = previousIndex >= 0
    ? previousMatches[previousIndex].from
    : view.state.selection.main.head;
  const nextQuery = new SearchQuery({
    search: command.query,
    replace: command.replacement,
    caseSensitive: command.caseSensitive,
    wholeWord: command.wholeWord,
    literal: true,
  });
  const queryChanged = !previousQuery.eq(nextQuery);
  view.dispatch({
    effects: [
      setSearchQuery.of(nextQuery),
      setSearchVisibility.of(command.visible),
    ],
  });
  if (command.visible && nextQuery.valid && nextQuery.search.length > 0 && queryChanged) {
    const matches = collectSearchMatches(view.state);
    const index = matches.findIndex((match) => match.from >= anchor);
    const match = matches[index >= 0 ? index : 0];
    if (match) view.dispatch({ selection: { anchor: match.from, head: match.to }, scrollIntoView: true });
  }
  syncVisibleColumns();
  scheduleCommandState();
}

function navigateSearch(direction: 'next' | 'previous'): void {
  if (!view) return;
  const matches = collectSearchMatches(view.state);
  if (matches.length === 0) {
    scheduleCommandState();
    return;
  }
  const current = currentSearchIndex(view.state, matches);
  const index = direction === 'next'
    ? (current + 1 + matches.length) % matches.length
    : (current - 1 + matches.length) % matches.length;
  const match = matches[index];
  view.dispatch({ selection: { anchor: match.from, head: match.to }, scrollIntoView: true });
  scheduleCommandState();
}

function replaceSearch(all: boolean): void {
  if (!view || !runtime?.editable) return;
  flushPendingTransaction();
  if (all) replaceAllSearchMatches(view);
  else replaceNextSearchMatch(view);
  flushPendingTransaction();
  scheduleCommandState();
}

function closeSearch(): void {
  if (!view) return;
  view.dispatch({ effects: setSearchVisibility.of(false) });
  syncVisibleColumns();
  scheduleCommandState();
}

function receive(command: HostCommand): void {
  try {
    if (command.protocolVersion !== protocolVersion) throw new Error(`Unsupported protocol ${command.protocolVersion}`);
    switch (command.type) {
      case 'initialize': initialize(command); break;
      case 'applyChanges': applyChanges(command); break;
      case 'replaceDocument': replaceDocument(command); break;
      case 'setMode':
        if (!view || !runtime) break;
        flushPendingTransaction();
        runtime.mode = command.mode;
        runtime.editable = command.editable;
        runtime.focused = command.focused;
        view.dispatch({
          effects: [
            setMode.of({ mode: command.mode, editable: command.editable, focused: command.focused }),
            editableCompartment.reconfigure([EditorView.editable.of(command.editable), EditorState.readOnly.of(!command.editable)]),
          ],
        });
        if (command.focused && command.editable) view.focus();
        break;
      case 'setTheme':
        if (!view || !runtime) break;
        runtime.theme = command.theme;
        view.dispatch({ effects: themeCompartment.reconfigure(editorTheme(command.theme)) });
        syncVisibleColumns();
        break;
      case 'revealRange':
        if (!view) break;
        view.dispatch({ selection: { anchor: command.from, head: command.to }, scrollIntoView: true });
        if (command.focus) view.focus();
        break;
      case 'setSearch': setSearch(command); break;
      case 'navigateSearch': navigateSearch(command.direction); break;
      case 'replaceSearch': replaceSearch(command.all); break;
      case 'closeSearch': closeSearch(); break;
      case 'flush':
        flushPendingTransaction();
        if (runtime) post({ type: 'flushAck', requestId: command.requestId, revision: runtime.revision, clientSeq: runtime.clientSeq });
        break;
      case 'attachmentChunk': receiveAttachmentChunk(command); break;
      case 'attachmentError': receiveAttachmentError(command.requestId); break;
      case 'dispose':
        view?.destroy();
        clearAttachmentState();
        if (pendingFrame) cancelAnimationFrame(pendingFrame);
        if (commandStateFrame) window.clearTimeout(commandStateFrame);
        pendingFrame = 0;
        commandStateFrame = 0;
        view = undefined;
        runtime = undefined;
        break;
    }
  } catch (error) {
    const resolved = error instanceof Error ? error : new Error(String(error));
    post({ type: 'error', message: resolved.message, stack: resolved.stack });
  }
}

function requestCommand(
  group: 'format' | 'paragraph' | 'list' | 'insert',
  command: string,
): boolean {
  if (!view || !runtime?.editable) return false;
  flushPendingTransaction();
  post({
    type: 'commandRequest',
    group,
    command,
    revision: runtime.revision,
    selection: selectionOf(view.state),
  });
  return true;
}

let contextMenu: HTMLElement | undefined;

function showContextMenu(x: number, y: number, from: number, to: number, imageSrc?: string): void {
  contextMenu?.remove();
  if (!runtime) return;
  const menu = document.createElement('div');
  menu.className = 'synapse-context-menu';
  menu.setAttribute('role', 'menu');
  const buttons: HTMLButtonElement[] = [];
  let outsideClose: ((event: Event) => void) | undefined;
  const dismiss = () => {
    menu.remove();
    if (outsideClose) window.removeEventListener('pointerdown', outsideClose, true);
    if (contextMenu === menu) contextMenu = undefined;
  };
  const action = (
    label: string,
    invoke: () => void,
    enabled = true,
    parent: HTMLElement = menu,
    collection: HTMLButtonElement[] = buttons,
  ) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = label;
    button.disabled = !enabled;
    button.tabIndex = -1;
    button.setAttribute('role', 'menuitem');
    button.addEventListener('click', () => { dismiss(); invoke(); });
    collection.push(button);
    parent.append(button);
    return button;
  };
  const submenu = (
    label: string,
    build: (add: (label: string, invoke: () => void, enabled?: boolean) => HTMLButtonElement) => void,
  ) => {
    const group = document.createElement('div');
    group.className = 'synapse-context-submenu-group';
    const panel = document.createElement('div');
    panel.className = 'synapse-context-submenu';
    panel.setAttribute('role', 'menu');
    panel.hidden = true;
    const items: HTMLButtonElement[] = [];
    const trigger = document.createElement('button');
    trigger.type = 'button';
    trigger.textContent = `${label} ›`;
    trigger.tabIndex = -1;
    trigger.setAttribute('role', 'menuitem');
    trigger.setAttribute('aria-haspopup', 'menu');
    trigger.setAttribute('aria-expanded', 'false');
    buttons.push(trigger);
    const open = () => {
      for (const other of menu.querySelectorAll<HTMLElement>('.synapse-context-submenu')) other.hidden = true;
      for (const other of menu.querySelectorAll<HTMLElement>('[aria-haspopup="menu"]')) other.setAttribute('aria-expanded', 'false');
      panel.hidden = false;
      trigger.setAttribute('aria-expanded', 'true');
    };
    const close = () => {
      panel.hidden = true;
      trigger.setAttribute('aria-expanded', 'false');
    };
    trigger.addEventListener('click', () => {
      if (panel.hidden) {
        open();
        items.find((item) => !item.disabled)?.focus();
      } else {
        close();
      }
    });
    trigger.addEventListener('mouseenter', open);
    trigger.addEventListener('keydown', (event) => {
      if (event.key !== 'ArrowRight' && event.key !== 'Enter' && event.key !== ' ') return;
      event.preventDefault();
      open();
      items.find((item) => !item.disabled)?.focus();
    });
    panel.addEventListener('keydown', (event) => {
      const enabled = items.filter((item) => !item.disabled);
      const current = enabled.indexOf(document.activeElement as HTMLButtonElement);
      if (event.key === 'ArrowLeft' || event.key === 'Escape') {
        event.preventDefault();
        close();
        trigger.focus();
        return;
      }
      let next: number | undefined;
      if (event.key === 'ArrowDown') next = (current + 1 + enabled.length) % enabled.length;
      if (event.key === 'ArrowUp') next = (current - 1 + enabled.length) % enabled.length;
      if (event.key === 'Home') next = 0;
      if (event.key === 'End') next = enabled.length - 1;
      if (next == null || enabled.length === 0) return;
      event.preventDefault();
      enabled[next].focus();
    });
    build((itemLabel, invoke, enabled = true) => action(itemLabel, invoke, enabled, panel, items));
    group.append(trigger, panel);
    menu.append(group);
  };
  if (imageSrc) {
    action('复制图片', () => {
      flushPendingTransaction();
      post({
        type: 'imageAction',
        action: 'copy',
        src: imageSrc,
        revision: runtime!.revision,
      });
    });
    action('剪切图片', () => {
      flushPendingTransaction();
      post({
        type: 'imageAction',
        action: 'cut',
        src: imageSrc,
        revision: runtime!.revision,
      });
    }, runtime.editable);
  } else {
    action('撤销', () => { if (view) undo(view); }, runtime.editable);
    action('重做', () => { if (view) redo(view); }, runtime.editable);
    action('复制', () => document.execCommand('copy'), from !== to || view?.state.selection.main.empty === false);
    action('剪切', () => document.execCommand('cut'), runtime.editable);
    action('粘贴', () => document.execCommand('paste'), runtime.editable);
    submenu('格式', (add) => {
      add('加粗', () => requestCommand('format', 'bold'), runtime!.editable);
      add('斜体', () => requestCommand('format', 'italic'), runtime!.editable);
      add('删除线', () => requestCommand('format', 'strikethrough'), runtime!.editable);
      add('高亮', () => requestCommand('format', 'highlight'), runtime!.editable);
    });
    submenu('段落', (add) => {
      add('一级标题', () => requestCommand('paragraph', 'heading1'), runtime!.editable);
      add('二级标题', () => requestCommand('paragraph', 'heading2'), runtime!.editable);
      add('正文', () => requestCommand('paragraph', 'body'), runtime!.editable);
      add('引用', () => requestCommand('paragraph', 'blockquote'), runtime!.editable);
    });
    submenu('列表', (add) => {
      add('无序列表', () => requestCommand('list', 'unordered'), runtime!.editable);
      add('有序列表', () => requestCommand('list', 'ordered'), runtime!.editable);
      add('任务列表', () => requestCommand('list', 'task'), runtime!.editable);
    });
    submenu('插入', (add) => {
      add('表格', () => requestCommand('insert', 'table'), runtime!.editable);
      add('双栏', () => requestCommand('insert', 'columns'), runtime!.editable);
      add('分隔线', () => requestCommand('insert', 'divider'), runtime!.editable);
      add('分页符', () => requestCommand('insert', 'pageBreak'), runtime!.editable);
    });
  }
  document.body.append(menu);
  menu.style.left = `${Math.max(8, Math.min(x, window.innerWidth - menu.offsetWidth - 8))}px`;
  menu.style.top = `${Math.max(8, Math.min(y, window.innerHeight - menu.offsetHeight - 8))}px`;
  contextMenu = menu;
  const enabledButtons = () => buttons.filter((button) => !button.disabled);
  menu.addEventListener('keydown', (event) => {
    const items = enabledButtons();
    if (items.length === 0) return;
    const current = items.indexOf(document.activeElement as HTMLButtonElement);
    if (event.key === 'Escape') {
      event.preventDefault();
      dismiss();
      view?.focus();
      return;
    }
    let next: number | undefined;
    if (event.key === 'ArrowDown') next = (current + 1 + items.length) % items.length;
    if (event.key === 'ArrowUp') next = (current - 1 + items.length) % items.length;
    if (event.key === 'Home') next = 0;
    if (event.key === 'End') next = items.length - 1;
    if (next == null) return;
    event.preventDefault();
    items[next].focus();
  });
  enabledButtons()[0]?.focus();
  outsideClose = (event: Event) => {
    if (event.target instanceof Node && menu.contains(event.target)) return;
    dismiss();
  };
  window.addEventListener('pointerdown', outsideClose, true);
}

interface PendingAttachment {
  src: string;
  mimeType: string;
  chunks: string[];
  leases: Set<AttachmentLease>;
}

interface AttachmentLease {
  listener: (url?: string) => void;
  released: boolean;
  cached: boolean;
}

interface CachedAttachment {
  url: string;
  refs: number;
  lastUsed: number;
}

const pendingAttachments = new Map<string, PendingAttachment>();
const pendingAttachmentBySrc = new Map<string, string>();
const attachmentCache = new Map<string, CachedAttachment>();

function clearAttachmentState(): void {
  pendingAttachments.clear();
  pendingAttachmentBySrc.clear();
  for (const cached of attachmentCache.values()) URL.revokeObjectURL(cached.url);
  attachmentCache.clear();
}

function receiveAttachmentChunk(command: Extract<HostCommand, { type: 'attachmentChunk' }>): void {
  const pending = pendingAttachments.get(command.requestId);
  if (!pending) return;
  pending.mimeType = command.mimeType;
  pending.chunks[command.chunkIndex] = command.data;
  if (pending.chunks.filter(Boolean).length !== command.chunkCount) return;
  const binary = atob(pending.chunks.join(''));
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  const url = URL.createObjectURL(new Blob([bytes], { type: pending.mimeType }));
  pendingAttachments.delete(command.requestId);
  pendingAttachmentBySrc.delete(pending.src);
  const activeLeases = [...pending.leases].filter((lease) => !lease.released);
  attachmentCache.set(pending.src, {
    url,
    refs: activeLeases.length,
    lastUsed: performance.now(),
  });
  for (const lease of activeLeases) {
    lease.cached = true;
    lease.listener(url);
  }
  evictAttachmentCache();
}

function receiveAttachmentError(requestId: string): void {
  const pending = pendingAttachments.get(requestId);
  if (!pending) return;
  pendingAttachments.delete(requestId);
  pendingAttachmentBySrc.delete(pending.src);
  for (const lease of pending.leases) {
    if (!lease.released) lease.listener(undefined);
  }
}

window.synapseHost = { receive };
window.synapseTest = {
  getText: () => view?.state.doc.toString() ?? '',
  getMode: () => runtime?.mode ?? 'reading',
  getSelection: () => view ? selectionOf(view.state) : { anchor: 0, head: 0 },
  insertText: (text: string) => {
    if (!view || !runtime?.editable) return;
    const selection = view.state.selection.main;
    view.dispatch({
      changes: { from: selection.from, to: selection.to, insert: text },
      selection: { anchor: selection.from + text.length },
    });
  },
  measureInsert: (text: string) => {
    if (!view || !runtime?.editable) return 0;
    const selection = view.state.selection.main;
    const startedAt = performance.now();
    view.dispatch({
      changes: { from: selection.from, to: selection.to, insert: text },
      selection: { anchor: selection.from + text.length },
    });
    return performance.now() - startedAt;
  },
  undo: () => view ? undo(view) : false,
  setSelection: (anchor: number, head: number) => {
    if (!view) return;
    view.dispatch({ selection: { anchor, head }, scrollIntoView: true });
  },
  editColumn: (side: 'left' | 'right', text: string) => {
    const root = document.querySelector<HTMLElement>('.synapse-columns');
    const state = root ? columnsDomStates.get(root) : undefined;
    const target = state?.[side];
    if (!target || !target.editable) return;
    target.editorView.dispatch({
      changes: { from: 0, to: target.editorView.state.doc.length, insert: text },
      selection: { anchor: text.length },
    });
  },
  selectColumn: (side: 'left' | 'right', anchor: number, head: number) => {
    const root = document.querySelector<HTMLElement>('.synapse-columns');
    const state = root ? columnsDomStates.get(root) : undefined;
    const target = state?.[side];
    if (!target) return;
    target.editorView.dispatch({ selection: { anchor, head } });
  },
  selectAcrossColumns: (
    anchorSide: 'left' | 'right',
    anchor: number,
    headSide: 'left' | 'right',
    head: number,
  ) => {
    const root = document.querySelector<HTMLElement>('.synapse-columns');
    const state = root ? columnsDomStates.get(root) : undefined;
    if (!state) return;
    state.parentView.dispatch({
      selection: {
        anchor: state[anchorSide].baseOffset + anchor,
        head: state[headSide].baseOffset + head,
      },
    });
  },
  getSelectedSource: () => {
    if (!view) return '';
    const selection = view.state.selection.main;
    return view.state.doc.sliceString(selection.from, selection.to);
  },
  moveRangeToColumn: (
    from: number,
    to: number,
    side: 'left' | 'right',
    offset: number,
  ) => {
    const root = document.querySelector<HTMLElement>('.synapse-columns');
    const state = root ? columnsDomStates.get(root) : undefined;
    if (!state) return false;
    return moveMarkdownRange(
      { from, to },
      state[side].baseOffset + offset,
    );
  },
};
window.addEventListener('error', (event) => post({ type: 'error', message: event.message, stack: event.error?.stack }));
window.addEventListener('unhandledrejection', (event) => {
  const error = event.reason instanceof Error ? event.reason : new Error(String(event.reason));
  post({ type: 'error', message: error.message, stack: error.stack });
});
