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
  ViewPlugin,
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
  type EditorPageBoundary,
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
let pointerInteractionHost: HTMLElement | undefined;
let pageLayoutHost: HTMLElement | undefined;
let pageLayoutScrollHost: HTMLElement | undefined;
let pageLayoutFrame = 0;
let pageLayoutFallbackTimer = 0;
let pageLayoutBoundaries: EditorPageBoundary[] = [];
let pageLayoutStale = false;
let pendingNestedComposition = false;
let pendingColumnFocus: {
  layoutFrom: number;
  side: 'left' | 'right';
} | undefined;
let pendingTableFocus: {
  blockFrom: number;
  row: number;
  column: number;
  openContextMenu?: { x: number; y: number };
} | undefined;
let attachmentCounter = 0;
const attachmentCacheLimit = 24;

type EditorEventPayload = EditorEvent extends infer Event
  ? Event extends EditorEvent
    ? Omit<Event, 'protocolVersion' | 'paneId' | 'noteId' | 'generation'>
    : never
  : never;

function post(event: EditorEventPayload): void {
  if (!runtime || !window.SynapseBridge) return;
  window.SynapseBridge.postMessage(JSON.stringify({
    protocolVersion,
    paneId: runtime.paneId,
    noteId: runtime.noteId,
    generation: runtime.generation,
    ...event,
  }));
}

function clearPageLayout(): void {
  if (pageLayoutFrame) cancelAnimationFrame(pageLayoutFrame);
  if (pageLayoutFallbackTimer) window.clearTimeout(pageLayoutFallbackTimer);
  pageLayoutFrame = 0;
  pageLayoutFallbackTimer = 0;
  pageLayoutScrollHost?.removeEventListener('scroll', schedulePageLayout);
  pageLayoutScrollHost = undefined;
  pageLayoutHost?.remove();
  pageLayoutHost = undefined;
}

function schedulePageLayout(): void {
  if (pageLayoutFrame) return;
  const frame = requestAnimationFrame(() => {
    if (pageLayoutFrame !== frame) return;
    pageLayoutFrame = 0;
    if (pageLayoutFallbackTimer) {
      window.clearTimeout(pageLayoutFallbackTimer);
      pageLayoutFallbackTimer = 0;
    }
    renderPageLayout();
  });
  pageLayoutFrame = frame;
  pageLayoutFallbackTimer = window.setTimeout(() => {
    if (pageLayoutFrame !== frame) return;
    cancelAnimationFrame(frame);
    pageLayoutFrame = 0;
    pageLayoutFallbackTimer = 0;
    renderPageLayout();
  }, 50);
}

function renderPageLayout(): void {
  if (!view || pageLayoutBoundaries.length === 0) {
    pageLayoutHost?.replaceChildren();
    return;
  }
  if (!pageLayoutHost || !pageLayoutHost.isConnected) {
    pageLayoutHost = document.createElement('div');
    pageLayoutHost.className = 'synapse-page-layout';
    pageLayoutHost.setAttribute('aria-hidden', 'true');
    view.scrollDOM.append(pageLayoutHost);
  }
  if (pageLayoutScrollHost !== view.scrollDOM) {
    pageLayoutScrollHost?.removeEventListener('scroll', schedulePageLayout);
    pageLayoutScrollHost = view.scrollDOM;
    pageLayoutScrollHost.addEventListener('scroll', schedulePageLayout, {
      passive: true,
    });
  }
  const scrollBounds = view.scrollDOM.getBoundingClientRect();
  const contentBounds = view.contentDOM.getBoundingClientRect();
  pageLayoutHost.style.left = `${contentBounds.left - scrollBounds.left + view.scrollDOM.scrollLeft}px`;
  pageLayoutHost.style.width = `${contentBounds.width}px`;
  pageLayoutHost.style.height = `${view.scrollDOM.scrollHeight}px`;
  pageLayoutHost.classList.toggle('synapse-page-layout-stale', pageLayoutStale);
  const children: HTMLElement[] = [];
  for (const boundary of pageLayoutBoundaries) {
    const coordinates = coordsAtMarkdownOffset(boundary.sourceOffset);
    if (!coordinates) continue;
    const line = document.createElement('div');
    line.className = 'synapse-page-boundary';
    line.dataset.pageIndex = String(boundary.pageIndex);
    line.style.top = `${coordinates.top - scrollBounds.top + view.scrollDOM.scrollTop}px`;
    const label = document.createElement('span');
    label.className = 'synapse-page-boundary-label';
    label.textContent = `第 ${boundary.pageIndex} 页结束 / 第 ${boundary.pageIndex + 1} 页开始`;
    line.append(label);
    children.push(line);
  }
  pageLayoutHost.replaceChildren(...children);
}

function handleSurfacePointerInteraction(event: PointerEvent): void {
  if (
    event.target instanceof Element &&
    event.target.closest('.synapse-context-menu')
  ) return;
  post({ type: 'pointerInteraction' });
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
  block: boolean;
  noteId?: string;
  generation?: number;
  revision?: number;
  src?: string;
  sourceBlockFrom?: number;
  sourceBlockTo?: number;
}

interface ImageDropBoundary {
  sourceOffset: number;
  blockFrom: number;
  blockTo: number;
  placement: 'before' | 'after';
  blockRect: DOMRect;
  surfaceRect: DOMRect;
  valid: boolean;
}

interface ImageDragSession {
  range: DraggedMarkdownRange;
  pointerId: number;
  clientX: number;
  clientY: number;
  active: boolean;
  sourceRoot: HTMLElement;
  sourceHandle: HTMLElement;
  preview?: HTMLElement;
  targetOverlay?: HTMLElement;
  indicator?: HTMLElement;
  target?: ImageDropBoundary;
  feedbackFrame: number;
  feedbackTimer: number;
  autoScrollFrame: number;
  autoScrollTimer: number;
  move: (event: PointerEvent | MouseEvent) => void;
  finish: (event: PointerEvent | MouseEvent) => void;
  cancel: () => void;
  keydown: (event: KeyboardEvent) => void;
  scroll: () => void;
}

let activeImageDragSession: ImageDragSession | undefined;

function writeDraggedMarkdownRange(
  event: DragEvent,
  from: number,
  to: number,
  block = false,
): void {
  event.dataTransfer?.setData(
    markdownRangeDragType,
    JSON.stringify({ from, to, block }),
  );
  if (event.dataTransfer) event.dataTransfer.effectAllowed = 'move';
}

function readDraggedMarkdownRange(event: DragEvent): DraggedMarkdownRange | undefined {
  const encoded = event.dataTransfer?.getData(markdownRangeDragType);
  if (!encoded) return undefined;
  try {
    const decoded = JSON.parse(encoded) as Partial<DraggedMarkdownRange>;
    if (!Number.isInteger(decoded.from) || !Number.isInteger(decoded.to)) return undefined;
    return {
      from: decoded.from!,
      to: decoded.to!,
      block: decoded.block === true,
      noteId: typeof decoded.noteId === 'string' ? decoded.noteId : undefined,
      generation: Number.isInteger(decoded.generation) ? decoded.generation : undefined,
      revision: Number.isInteger(decoded.revision) ? decoded.revision : undefined,
      src: typeof decoded.src === 'string' ? decoded.src : undefined,
      sourceBlockFrom: Number.isInteger(decoded.sourceBlockFrom)
        ? decoded.sourceBlockFrom
        : undefined,
      sourceBlockTo: Number.isInteger(decoded.sourceBlockTo)
        ? decoded.sourceBlockTo
        : undefined,
    };
  } catch (_) {
    return undefined;
  }
}

function normalizedImageSrc(src: string): string {
  const slashNormalized = src.trim().replaceAll('\\', '/');
  try {
    return decodeURIComponent(slashNormalized);
  } catch (_) {
    return slashNormalized;
  }
}

function draggedRangeStillValid(range: DraggedMarkdownRange): boolean {
  if (!view || !runtime?.editable) return false;
  if (range.noteId != null && range.noteId !== runtime.noteId) return false;
  if (range.generation != null && range.generation !== runtime.generation) {
    return false;
  }
  if (range.revision != null && range.revision !== runtime.revision) return false;
  const length = view.state.doc.length;
  if (range.from < 0 || range.to <= range.from || range.to > length) return false;
  if (range.src != null) {
    const currentSource = view.state.doc.sliceString(range.from, range.to);
    const currentSrc = markdownImageSource(currentSource) ??
      imageRanges({
        from: range.from,
        to: range.to,
        text: currentSource,
        kind: 'paragraph',
      })[0]?.src;
    if (
      currentSrc == null ||
      normalizedImageSrc(currentSrc) !== normalizedImageSrc(range.src)
    ) {
      return false;
    }
  }
  if (range.sourceBlockFrom != null && range.sourceBlockTo != null) {
    const sourceBlock = splitMarkdownBlocks(view.state.doc.toString()).find(
      (block) => range.from >= block.from && range.to <= block.to,
    );
    if (
      sourceBlock?.from !== range.sourceBlockFrom ||
      sourceBlock.to !== range.sourceBlockTo
    ) {
      return false;
    }
  }
  return true;
}

function moveMarkdownRange(range: DraggedMarkdownRange, targetOffset: number): boolean {
  if (!view || !draggedRangeStillValid(range)) return false;
  const length = view.state.doc.length;
  const from = Math.max(0, Math.min(range.from, length));
  const to = Math.max(from, Math.min(range.to, length));
  const target = Math.max(0, Math.min(targetOffset, length));
  if (from === to || (target >= from && target <= to)) return false;
  const source = view.state.doc.sliceString(from, to);
  const insertionOffset = target > to ? target - (to - from) : target;
  const remaining = `${view.state.doc.sliceString(0, from)}${view.state.doc.sliceString(to)}`;
  let insertion = source;
  if (range.block) {
    const before = insertionOffset > 0 ? remaining[insertionOffset - 1] : undefined;
    const after = insertionOffset < remaining.length ? remaining[insertionOffset] : undefined;
    if (before != null && before !== '\n' && !insertion.startsWith('\n')) {
      insertion = `\n${insertion}`;
    }
    if (after != null && after !== '\n' && !insertion.endsWith('\n')) {
      insertion = `${insertion}\n`;
    }
  }
  const changes = target < from
    ? [
        { from: target, to: target, insert: insertion },
        { from, to, insert: '' },
      ]
    : [
        { from, to, insert: '' },
        { from: target, to: target, insert: insertion },
      ];
  view.dispatch({
    changes,
    selection: { anchor: insertionOffset + insertion.length },
  });
  return true;
}

function moveImageRange(
  range: DraggedMarkdownRange,
  targetOffset: number,
): boolean {
  if (!view || range.src == null || !draggedRangeStillValid(range)) return false;
  const length = view.state.doc.length;
  const target = Math.max(0, Math.min(targetOffset, length));
  const source = view.state.doc.sliceString(range.from, range.to).trim();
  if (source.length === 0) return false;
  const { from: removalFrom, to: removalTo } = imageRemovalBounds(range);
  if (target >= removalFrom && target <= removalTo) return false;
  const insertionOffset = target > removalTo
    ? target - (removalTo - removalFrom)
    : target;
  const remaining = `${view.state.doc.sliceString(0, removalFrom)}`
    + `${view.state.doc.sliceString(removalTo)}`;
  const before = remaining.slice(0, insertionOffset);
  const after = remaining.slice(insertionOffset);
  const leading = before.length === 0
    ? ''
    : before.endsWith('\n\n')
      ? ''
      : before.endsWith('\n')
        ? '\n'
        : '\n\n';
  const trailing = after.length === 0
    ? ''
    : after.startsWith('\n\n')
      ? ''
      : after.startsWith('\n')
        ? '\n'
        : '\n\n';
  const insertion = `${leading}${source}${trailing}`;
  const changes = target < removalFrom
    ? [
        { from: target, to: target, insert: insertion },
        { from: removalFrom, to: removalTo, insert: '' },
      ]
    : [
        { from: removalFrom, to: removalTo, insert: '' },
        { from: target, to: target, insert: insertion },
      ];
  const selectedOffset = insertionOffset + leading.length;
  view.dispatch({
    changes,
    selection: { anchor: selectedOffset },
    annotations: Transaction.userEvent.of('move.image'),
  });
  requestAnimationFrame(() => focusImageAtMarkdownOffset(selectedOffset));
  return true;
}

function imageRemovalBounds(
  range: DraggedMarkdownRange,
): { from: number; to: number } {
  if (!view) return { from: range.from, to: range.to };
  let from = range.from;
  let to = range.to;
  const standalone =
    range.sourceBlockFrom === range.from &&
    range.sourceBlockTo === range.to;
  if (standalone && view.state.doc.sliceString(to, to + 1) === '\n') {
    to += 1;
  } else if (
    standalone &&
    from > 0 &&
    view.state.doc.sliceString(from - 1, from) === '\n'
  ) {
    from -= 1;
    if (
      from > 0 &&
      view.state.doc.sliceString(from - 1, from) === '\r'
    ) {
      from -= 1;
    }
  }
  return { from, to };
}

function pointerBelongsToImageDrag(
  session: ImageDragSession,
  event: PointerEvent | MouseEvent,
): boolean {
  const pointerId = 'pointerId' in event ? event.pointerId : undefined;
  return !Number.isInteger(pointerId) || pointerId === session.pointerId;
}

function createImageDragPreview(session: ImageDragSession): HTMLElement {
  const preview = document.createElement('div');
  preview.className = 'synapse-image-drag-preview';
  preview.setAttribute('aria-hidden', 'true');
  const sourceImage = session.sourceRoot.querySelector<HTMLImageElement>('img');
  if (sourceImage?.src) {
    const image = document.createElement('img');
    image.src = sourceImage.src;
    image.alt = sourceImage.alt;
    image.draggable = false;
    preview.append(image);
  } else {
    const fallback = document.createElement('span');
    fallback.className = 'synapse-image-drag-preview-fallback';
    fallback.textContent = '图片';
    preview.append(fallback);
  }
  return preview;
}

function clearImageDragTarget(session: ImageDragSession): void {
  session.target = undefined;
  session.targetOverlay?.remove();
  session.targetOverlay = undefined;
  session.indicator?.remove();
  session.indicator = undefined;
  session.preview?.classList.add('synapse-image-drop-invalid');
}

function renderImageDragFeedback(session: ImageDragSession): void {
  if (activeImageDragSession !== session || !session.active || !view) return;
  if (!session.preview) {
    session.preview = createImageDragPreview(session);
    view.dom.append(session.preview);
  }
  session.preview.style.transform =
    `translate3d(${session.clientX + 14}px, ${session.clientY + 14}px, 0)`;
  const target = imageDropBoundaryAtCoords(
    session.range,
    session.clientX,
    session.clientY,
  );
  if (!target) {
    clearImageDragTarget(session);
    return;
  }
  session.target = target;
  session.preview.classList.toggle('synapse-image-drop-invalid', !target.valid);
  const overlay = session.targetOverlay ?? document.createElement('span');
  overlay.className = 'synapse-image-drop-target';
  overlay.classList.toggle('synapse-image-drop-invalid', !target.valid);
  overlay.dataset.placement = target.placement;
  overlay.style.left = `${target.blockRect.left}px`;
  overlay.style.top = `${target.blockRect.top}px`;
  overlay.style.width = `${Math.max(1, target.blockRect.width)}px`;
  overlay.style.height = `${Math.max(2, target.blockRect.height)}px`;
  if (!overlay.isConnected) view.dom.append(overlay);
  session.targetOverlay = overlay;
  const indicator = session.indicator ?? document.createElement('span');
  indicator.className = 'synapse-image-block-drop-indicator';
  indicator.classList.toggle('synapse-image-drop-invalid', !target.valid);
  indicator.dataset.placement = target.placement;
  indicator.style.left = `${target.surfaceRect.left}px`;
  indicator.style.top = `${target.placement === 'before'
    ? target.blockRect.top
    : target.blockRect.bottom}px`;
  indicator.style.width = `${Math.max(1, target.surfaceRect.width)}px`;
  if (!indicator.isConnected) view.dom.append(indicator);
  session.indicator = indicator;
}

function scheduleImageDragFeedback(session: ImageDragSession): void {
  if (session.feedbackFrame || session.feedbackTimer) return;
  const run = () => {
    if (session.feedbackFrame) cancelAnimationFrame(session.feedbackFrame);
    if (session.feedbackTimer) window.clearTimeout(session.feedbackTimer);
    session.feedbackFrame = 0;
    session.feedbackTimer = 0;
    renderImageDragFeedback(session);
  };
  session.feedbackFrame = requestAnimationFrame(run);
  session.feedbackTimer = window.setTimeout(run, 16);
}

function scheduleImageDragAutoScroll(session: ImageDragSession): void {
  if (session.autoScrollFrame || session.autoScrollTimer) return;
  const tick = () => {
    if (session.autoScrollFrame) cancelAnimationFrame(session.autoScrollFrame);
    if (session.autoScrollTimer) window.clearTimeout(session.autoScrollTimer);
    session.autoScrollFrame = 0;
    session.autoScrollTimer = 0;
    if (activeImageDragSession !== session || !session.active || !view) return;
    const bounds = view.scrollDOM.getBoundingClientRect();
    let changed = false;
    if (session.clientY < bounds.top + 32) {
      const previous = view.scrollDOM.scrollTop;
      view.scrollDOM.scrollTop -= 14;
      changed = view.scrollDOM.scrollTop !== previous;
    } else if (session.clientY > bounds.bottom - 32) {
      const previous = view.scrollDOM.scrollTop;
      view.scrollDOM.scrollTop += 14;
      changed = view.scrollDOM.scrollTop !== previous;
    }
    if (!changed) return;
    renderImageDragFeedback(session);
    scheduleImageDragAutoScroll(session);
  };
  session.autoScrollFrame = requestAnimationFrame(tick);
  session.autoScrollTimer = window.setTimeout(tick, 16);
}

function activateImageDrag(session: ImageDragSession): void {
  if (session.active || !view) return;
  session.active = true;
  session.sourceRoot.classList.add('synapse-image-dragging');
  session.sourceHandle.classList.add('synapse-image-handle-dragging');
  view.dom.classList.add('synapse-image-drag-active');
  renderImageDragFeedback(session);
}

function cleanupImageDrag(session: ImageDragSession): void {
  if (session.feedbackFrame) cancelAnimationFrame(session.feedbackFrame);
  if (session.feedbackTimer) window.clearTimeout(session.feedbackTimer);
  if (session.autoScrollFrame) cancelAnimationFrame(session.autoScrollFrame);
  if (session.autoScrollTimer) window.clearTimeout(session.autoScrollTimer);
  session.feedbackFrame = 0;
  session.feedbackTimer = 0;
  session.autoScrollFrame = 0;
  session.autoScrollTimer = 0;
  window.removeEventListener('pointermove', session.move, true);
  window.removeEventListener('mousemove', session.move, true);
  window.removeEventListener('pointerup', session.finish, true);
  window.removeEventListener('mouseup', session.finish, true);
  window.removeEventListener('pointercancel', session.cancel, true);
  window.removeEventListener('keydown', session.keydown, true);
  view?.scrollDOM.removeEventListener('scroll', session.scroll);
  session.sourceRoot.classList.remove('synapse-image-dragging');
  session.sourceHandle.classList.remove('synapse-image-handle-dragging');
  view?.dom.classList.remove('synapse-image-drag-active');
  session.preview?.remove();
  session.targetOverlay?.remove();
  session.indicator?.remove();
  session.preview = undefined;
  session.targetOverlay = undefined;
  session.indicator = undefined;
  session.target = undefined;
  if (activeImageDragSession === session) activeImageDragSession = undefined;
}

function cancelActiveImageDrag(): void {
  const session = activeImageDragSession;
  if (session) cleanupImageDrag(session);
}

function beginImageDrag(
  event: PointerEvent | MouseEvent,
  range: DraggedMarkdownRange,
  sourceRoot: HTMLElement,
  sourceHandle: HTMLElement,
): void {
  if (!view || !runtime?.editable || !runtime.focused || event.button !== 0) {
    return;
  }
  event.preventDefault();
  event.stopPropagation();
  cancelActiveImageDrag();
  const eventPointerId = 'pointerId' in event ? event.pointerId : undefined;
  const pointerId = Number.isInteger(eventPointerId) ? eventPointerId! : 1;
  const session = {} as ImageDragSession;
  session.range = range;
  session.pointerId = pointerId;
  session.clientX = event.clientX;
  session.clientY = event.clientY;
  session.active = false;
  session.sourceRoot = sourceRoot;
  session.sourceHandle = sourceHandle;
  session.feedbackFrame = 0;
  session.feedbackTimer = 0;
  session.autoScrollFrame = 0;
  session.autoScrollTimer = 0;
  session.move = (next) => {
    if (!pointerBelongsToImageDrag(session, next)) return;
    session.clientX = next.clientX;
    session.clientY = next.clientY;
    const alreadyActive = session.active;
    activateImageDrag(session);
    next.preventDefault();
    if (alreadyActive) renderImageDragFeedback(session);
    scheduleImageDragAutoScroll(session);
  };
  session.finish = (next) => {
    if (!pointerBelongsToImageDrag(session, next)) return;
    session.clientX = next.clientX;
    session.clientY = next.clientY;
    if (session.active) renderImageDragFeedback(session);
    const shouldMove = session.active && session.target?.valid === true;
    const targetOffset = session.target?.sourceOffset;
    cleanupImageDrag(session);
    if (shouldMove && targetOffset != null) moveImageRange(range, targetOffset);
  };
  session.cancel = () => cleanupImageDrag(session);
  session.keydown = (keyEvent) => {
    if (keyEvent.key !== 'Escape') return;
    keyEvent.preventDefault();
    cleanupImageDrag(session);
  };
  session.scroll = () => {
    if (session.active) scheduleImageDragFeedback(session);
  };
  activeImageDragSession = session;
  window.addEventListener('pointermove', session.move, true);
  window.addEventListener('mousemove', session.move, true);
  window.addEventListener('pointerup', session.finish, true);
  window.addEventListener('mouseup', session.finish, true);
  window.addEventListener('pointercancel', session.cancel, true);
  window.addEventListener('keydown', session.keydown, true);
  view.scrollDOM.addEventListener('scroll', session.scroll, { passive: true });
  activateImageDrag(session);
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
  constructor(readonly from: number, readonly to: number) { super(); }

  eq(other: PageBreakWidget): boolean {
    return other.from === this.from && other.to === this.to;
  }

  toDOM(): HTMLElement {
    const root = document.createElement('div');
    root.className = 'synapse-page-break';
    root.dataset.markdownFrom = String(this.from);
    root.dataset.markdownTo = String(this.to);
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
    readonly selected: boolean,
    readonly editable: boolean,
    readonly activate?: () => void,
  ) { super(); }

  eq(other: ImageWidget): boolean {
    return other.from === this.from &&
      other.to === this.to &&
      other.src === this.src &&
      other.width === this.width &&
      other.block === this.block &&
      other.selected === this.selected &&
      other.editable === this.editable;
  }

  toDOM(): HTMLElement {
    const root: HTMLElement = document.createElement(
      this.block ? 'div' : 'span',
    );
    root.className = this.block ? 'synapse-image-block' : 'synapse-inline-image';
    if (this.selected) root.classList.add('synapse-image-selected');
    root.dataset.src = this.src;
    root.dataset.markdownFrom = String(this.from);
    root.dataset.markdownTo = String(this.to);
    root.draggable = false;
    const appendControls = (image?: HTMLImageElement) => {
      if (!this.selected || !this.editable) return;
      const moveHandle = document.createElement('span');
      moveHandle.className = 'synapse-image-move-handle';
      moveHandle.title = '拖动图片';
      moveHandle.setAttribute('aria-label', '拖动图片');
      moveHandle.addEventListener('pointerdown', (event) => {
        this.beginMove(event, root, moveHandle);
      });
      moveHandle.addEventListener('mousedown', (event) => {
        if (activeImageDragSession) return;
        this.beginMove(event, root, moveHandle);
      });
      root.append(moveHandle);
      if (!image) return;
      for (const side of ['left', 'right'] as const) {
        const resizeHandle = document.createElement('span');
        resizeHandle.className =
          `synapse-image-resize synapse-image-resize-${side}`;
        resizeHandle.setAttribute(
          'aria-label',
          `${side === 'left' ? '左侧' : '右侧'}缩放图片`,
        );
        resizeHandle.addEventListener('pointerdown', (event) => {
          this.beginResize(event, image, side);
        });
        root.append(resizeHandle);
      }
    };
    const loading = document.createElement('span');
    loading.className = 'synapse-image-loading';
    loading.textContent = '正在载入图片…';
    root.append(loading);
    appendControls();
    this.disposeAttachment = requestAttachment(this.src, (url) => {
      root.replaceChildren();
      let image: HTMLImageElement | undefined;
      if (!url) {
        const broken = document.createElement('span');
        broken.className = 'synapse-image-broken';
        broken.textContent = this.src;
        root.append(broken);
      } else {
        image = document.createElement('img');
        image.src = url;
        image.alt = this.src;
        image.draggable = false;
        image.style.width = `${this.width}px`;
        image.style.maxWidth = '100%';
        root.append(image);
      }
      appendControls(image);
    });
    root.addEventListener('click', (event) => {
      if ((event.target as HTMLElement).closest(
        '.synapse-image-resize, .synapse-image-move-handle',
      )) return;
      event.preventDefault();
      if (this.activate) this.activate();
      else safeDispatchSelection(this.from);
    });
    root.addEventListener('contextmenu', (event: MouseEvent) => {
      event.preventDefault();
      if (this.activate) this.activate();
      else safeDispatchSelection(this.from);
      showContextMenu(event.clientX, event.clientY, {
        kind: 'image',
        from: this.from,
        to: this.to,
        src: this.src,
        pasteSelection: rememberedTextSelection,
      });
    });
    return root;
  }

  destroy(): void {
    this.disposeAttachment?.();
  }

  ignoreEvent(): boolean { return true; }

  private beginMove(
    event: PointerEvent | MouseEvent,
    root: HTMLElement,
    handle: HTMLElement,
  ): void {
    if (!view || !runtime?.editable || event.button !== 0) return;
    event.preventDefault();
    event.stopPropagation();
    flushPendingTransaction();
    const sourceBlock = splitMarkdownBlocks(view.state.doc.toString()).find(
      (block) => this.from >= block.from && this.to <= block.to,
    );
    if (!sourceBlock) return;
    const range: DraggedMarkdownRange = {
      from: this.from,
      to: this.to,
      block: true,
      noteId: runtime.noteId,
      generation: runtime.generation,
      revision: runtime.revision,
      src: normalizedImageSrc(this.src),
      sourceBlockFrom: sourceBlock.from,
      sourceBlockTo: sourceBlock.to,
    };
    beginImageDrag(event, range, root, handle);
  }

  private beginResize(
    event: PointerEvent,
    image: HTMLImageElement,
    side: 'left' | 'right',
  ): void {
    event.preventDefault();
    event.stopPropagation();
    const startX = event.clientX;
    const startWidth = image.getBoundingClientRect().width;
    const move = (next: PointerEvent) => {
      const delta = next.clientX - startX;
      const width = side === 'left' ? startWidth - delta : startWidth + delta;
      image.style.width = `${Math.max(120, Math.min(1600, width))}px`;
    };
    const cleanup = () => {
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', end);
      window.removeEventListener('pointercancel', cancel);
    };
    const end = () => {
      cleanup();
      const width = Math.round(image.getBoundingClientRect().width);
      flushPendingTransaction();
      post({
        type: 'imageAction',
        action: 'resize',
        src: this.src,
        revision: runtime!.revision,
        from: this.from,
        to: this.to,
        width,
      });
    };
    const cancel = () => cleanup();
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', end, { once: true });
    window.addEventListener('pointercancel', cancel, { once: true });
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

interface TableDomState {
  widget: TableWidget;
  frame: HTMLElement;
  table: HTMLTableElement;
  model: TableModel;
  cells: HTMLElement[][];
  selectedRow: number;
  selectedColumn: number;
  pendingFrame: number;
  focusRestoreFrame: number;
  composing: boolean;
  contextMenuOpen: boolean;
  focusedCell?: HTMLElement;
  committingMarkdown?: string;
  drag?: TablePointerDrag;
}

type TableDragKind = 'row' | 'column' | 'table';

interface TablePointerDrag {
  kind: TableDragKind;
  pointerId: number;
  source: number;
  startX: number;
  startY: number;
  clientX: number;
  clientY: number;
  active: boolean;
  insertionSlot: number;
  targetOffset?: number;
  handle: HTMLElement;
  blockIndicator?: HTMLElement;
  autoScrollFrame: number;
  move: (event: PointerEvent) => void;
  finish: (event?: PointerEvent) => void;
  cancel: () => void;
  keydown: (event: KeyboardEvent) => void;
}

interface CellSelectionSnapshot {
  anchor: number;
  head: number;
}

const tableDomStates = new WeakMap<HTMLElement, TableDomState>();
const mountedTableStates = new Set<TableDomState>();

function cloneTableModel(model: TableModel): TableModel {
  return {
    ...model,
    header: [...model.header],
    alignments: [...model.alignments],
    rows: model.rows.map((row) => [...row]),
  };
}

function tableDomHasSameShape(
  state: TableDomState,
  model: TableModel,
): boolean {
  return state.cells.length === model.rows.length + 1 &&
    state.cells.every((row) => row.length === model.header.length);
}

function tableCellValue(model: TableModel, rowIndex: number, columnIndex: number): string {
  return rowIndex === 0
    ? model.header[columnIndex]
    : model.rows[rowIndex - 1][columnIndex];
}

function withTableCellValue(
  model: TableModel,
  rowIndex: number,
  columnIndex: number,
  value: string,
): TableModel {
  const updated = cloneTableModel(model);
  if (rowIndex === 0) updated.header[columnIndex] = value;
  else updated.rows[rowIndex - 1][columnIndex] = value;
  return updated;
}

function displayTableCell(value: string): string {
  return value.replace(/\\\|/g, '|');
}

function editorTableCellValue(editor: HTMLElement): string {
  return (editor.textContent ?? '')
    .replace(/\r?\n/g, ' ')
    .replace(/\|/g, '\\|');
}

function cellTextOffset(
  editor: HTMLElement,
  node: Node | null,
  offset: number,
): number | undefined {
  if (!node || !editor.contains(node)) return undefined;
  const range = document.createRange();
  range.selectNodeContents(editor);
  range.setEnd(node, offset);
  return range.toString().length;
}

function captureCellSelection(
  editor: HTMLElement,
): CellSelectionSnapshot | undefined {
  const selection = window.getSelection();
  if (!selection || selection.rangeCount === 0) return undefined;
  const anchor = cellTextOffset(
    editor,
    selection.anchorNode,
    selection.anchorOffset,
  );
  const head = cellTextOffset(
    editor,
    selection.focusNode,
    selection.focusOffset,
  );
  return anchor == null || head == null ? undefined : { anchor, head };
}

function cellTextPoint(editor: HTMLElement, offset: number): [Node, number] {
  const walker = document.createTreeWalker(editor, NodeFilter.SHOW_TEXT);
  let remaining = Math.max(0, offset);
  let node = walker.nextNode();
  while (node) {
    const length = node.textContent?.length ?? 0;
    if (remaining <= length) return [node, remaining];
    remaining -= length;
    node = walker.nextNode();
  }
  const text = editor.appendChild(document.createTextNode(''));
  return [text, 0];
}

function restoreCellSelection(
  editor: HTMLElement,
  snapshot: CellSelectionSnapshot | undefined,
  focus = false,
): void {
  if (focus) editor.focus({ preventScroll: true });
  if (!snapshot) return;
  if (document.activeElement !== editor) return;
  const [anchorNode, anchorOffset] = cellTextPoint(editor, snapshot.anchor);
  const [headNode, headOffset] = cellTextPoint(editor, snapshot.head);
  const selection = window.getSelection();
  selection?.setBaseAndExtent(
    anchorNode,
    anchorOffset,
    headNode,
    headOffset,
  );
}

function commitTableModel(
  state: TableDomState,
  next: TableModel = state.model,
  userEvent = 'input.table',
): boolean {
  if (!view || !state.widget.editable) return false;
  if (state.pendingFrame) cancelAnimationFrame(state.pendingFrame);
  state.pendingFrame = 0;
  state.model = cloneTableModel(next);
  const markdown = serializeTableModel(state.model);
  if (
    markdown === state.widget.block.text ||
    markdown === state.committingMarkdown
  ) return false;
  const activeElement = document.activeElement;
  const parentRecoveredFocus = activeElement instanceof HTMLElement &&
    activeElement.classList.contains('cm-content') &&
    view.dom.contains(activeElement);
  const focusedCell = state.focusedCell?.isConnected &&
      (activeElement === state.focusedCell || parentRecoveredFocus)
    ? state.focusedCell
    : undefined;
  const cellSelection = focusedCell
    ? captureCellSelection(focusedCell)
    : undefined;
  const editorScrollTop = view.scrollDOM.scrollTop;
  const editorScrollLeft = view.scrollDOM.scrollLeft;
  const tableScrollLeft = state.frame.scrollLeft;
  state.committingMarkdown = markdown;
  view.dispatch({
    changes: {
      from: state.widget.block.from,
      to: state.widget.block.to,
      insert: markdown,
    },
    annotations: Transaction.userEvent.of(userEvent),
  });
  if (focusedCell?.isConnected && state.frame.contains(focusedCell)) {
    restoreCellSelection(focusedCell, cellSelection, true);
    view.scrollDOM.scrollTop = editorScrollTop;
    view.scrollDOM.scrollLeft = editorScrollLeft;
    state.frame.scrollLeft = tableScrollLeft;
    if (state.focusRestoreFrame) cancelAnimationFrame(state.focusRestoreFrame);
    state.focusRestoreFrame = requestAnimationFrame(() => {
      state.focusRestoreFrame = 0;
      const active = document.activeElement;
      const editorRecoveredFocus = active instanceof HTMLElement &&
        active.classList.contains('cm-content') &&
        view?.dom.contains(active);
      if (
        state.focusedCell !== focusedCell ||
        (!editorRecoveredFocus && active !== focusedCell)
      ) return;
      restoreCellSelection(focusedCell, cellSelection, true);
      if (view) {
        view.scrollDOM.scrollTop = editorScrollTop;
        view.scrollDOM.scrollLeft = editorScrollLeft;
      }
      state.frame.scrollLeft = tableScrollLeft;
    });
  }
  return true;
}

function scheduleTableCommit(state: TableDomState): void {
  if (state.pendingFrame) return;
  state.pendingFrame = requestAnimationFrame(() => {
    state.pendingFrame = 0;
    commitTableModel(state);
  });
}

function flushPendingTableEdits(): void {
  for (const state of [...mountedTableStates]) {
    if (state.pendingFrame) commitTableModel(state);
  }
}

function tableCellPosition(
  state: TableDomState,
  target: EventTarget | null,
): { row: number; column: number } {
  const element = target instanceof Element ? target : null;
  const indexed = element?.closest<HTMLElement>('[data-table-row]');
  const row = Number(indexed?.dataset.tableRow ?? state.selectedRow);
  const column = Number(indexed?.dataset.tableColumn ?? state.selectedColumn);
  return {
    row: Number.isInteger(row) ? row : state.selectedRow,
    column: Number.isInteger(column) ? column : state.selectedColumn,
  };
}

function queueTableFocus(
  state: TableDomState,
  row: number,
  column: number,
  openContextMenu?: { x: number; y: number },
): void {
  pendingColumnFocus = undefined;
  pendingTableFocus = {
    blockFrom: state.widget.block.from,
    row,
    column,
    openContextMenu,
  };
}

function focusPendingTable(): boolean {
  const pending = pendingTableFocus;
  if (!pending) return false;
  for (const state of mountedTableStates) {
    if (
      !state.frame.isConnected ||
      !state.widget.editable ||
      state.widget.block.from !== pending.blockFrom
    ) continue;
    pendingTableFocus = undefined;
    state.selectedRow = Math.max(
      0,
      Math.min(pending.row, state.model.rows.length),
    );
    state.selectedColumn = Math.max(
      0,
      Math.min(pending.column, state.model.header.length - 1),
    );
    const cell = state.cells[state.selectedRow]?.[state.selectedColumn];
    if (cell) {
      state.focusedCell = cell;
      cell.focus({ preventScroll: true });
    } else {
      safeDispatchSelection(state.widget.block.from);
    }
    if (pending.openContextMenu) {
      const editor = state.cells[state.selectedRow]?.[state.selectedColumn];
      if (!editor) return true;
      showContextMenu(
        pending.openContextMenu.x,
        pending.openContextMenu.y,
        tableCellContextTarget(state, state.selectedRow, state.selectedColumn, editor),
      );
    }
    return true;
  }
  return false;
}

function requestTableActivation(
  state: TableDomState,
  row: number,
  column: number,
  openContextMenu?: { x: number; y: number },
): void {
  queueTableFocus(state, row, column, openContextMenu);
  safeDispatchSelection(state.widget.block.from);
  post({ type: 'focusChanged', focused: true });
}

function commitTableStructure(
  state: TableDomState,
  next: TableModel,
  row: number,
  column: number,
): boolean {
  queueTableFocus(state, row, column);
  const changed = commitTableModel(state, next, 'input.table.structure');
  if (!changed) {
    pendingTableFocus = undefined;
    return false;
  }
  if (!focusPendingTable()) {
    requestAnimationFrame(() => focusPendingTable());
  }
  return true;
}

function insertTableRow(state: TableDomState, after: boolean): void {
  const model = state.model;
  const selected = state.selectedRow;
  const insertAt = selected === 0
    ? 0
    : Math.max(0, Math.min(
        model.rows.length,
        selected - 1 + (after ? 1 : 0),
      ));
  const rows = model.rows.map((row) => [...row]);
  rows.splice(
    insertAt,
    0,
    Array.from({ length: model.header.length }, () => ''),
  );
  commitTableStructure(
    state,
    { ...model, rows },
    insertAt + 1,
    state.selectedColumn,
  );
}

function deleteTableRow(state: TableDomState): void {
  if (state.selectedRow <= 0 || state.model.rows.length === 0) return;
  const removeAt = state.selectedRow - 1;
  const rows = state.model.rows.filter((_, index) => index !== removeAt);
  commitTableStructure(
    state,
    { ...state.model, rows },
    Math.min(state.selectedRow, rows.length),
    state.selectedColumn,
  );
}

function insertTableColumn(state: TableDomState, after: boolean): void {
  const model = state.model;
  const insertAt = Math.max(
    0,
    Math.min(
      model.header.length,
      state.selectedColumn + (after ? 1 : 0),
    ),
  );
  const insert = (row: string[]) => [
    ...row.slice(0, insertAt),
    '',
    ...row.slice(insertAt),
  ];
  commitTableStructure(
    state,
    {
      ...model,
      width: model.width == null
        ? undefined
        : clampTableWidth(model.width + 64, model.header.length + 1),
      header: insert(model.header),
      alignments: insert(model.alignments),
      rows: model.rows.map(insert),
    },
    state.selectedRow,
    insertAt,
  );
}

function deleteTableColumn(state: TableDomState): void {
  const model = state.model;
  if (model.header.length <= 1) return;
  const removeAt = Math.max(
    0,
    Math.min(state.selectedColumn, model.header.length - 1),
  );
  const remove = (row: string[]) =>
    row.filter((_, index) => index !== removeAt);
  commitTableStructure(
    state,
    {
      ...model,
      header: remove(model.header),
      alignments: remove(model.alignments),
      rows: model.rows.map(remove),
    },
    state.selectedRow,
    Math.min(removeAt, model.header.length - 2),
  );
}

function clearTableDropFeedback(state: TableDomState): void {
  for (const element of state.frame.querySelectorAll<HTMLElement>(
    '.synapse-table-row-drop-before, .synapse-table-row-drop-after, '
      + '.synapse-table-column-drop-before, '
      + '.synapse-table-column-drop-after',
  )) {
    element.classList.remove(
      'synapse-table-row-drop-before',
      'synapse-table-row-drop-after',
      'synapse-table-column-drop-before',
      'synapse-table-column-drop-after',
    );
  }
}

function insertionSlot(
  elements: HTMLElement[],
  coordinate: number,
  horizontal: boolean,
): number {
  for (let index = 0; index < elements.length; index += 1) {
    const bounds = elements[index].getBoundingClientRect();
    const midpoint = horizontal
      ? bounds.left + bounds.width / 2
      : bounds.top + bounds.height / 2;
    if (coordinate < midpoint) return index;
  }
  return elements.length;
}

function markTableInsertion(
  state: TableDomState,
  elements: HTMLElement[],
  slot: number,
  kind: 'row' | 'column',
): void {
  clearTableDropFeedback(state);
  if (elements.length === 0) return;
  const targetIndex = slot >= elements.length ? elements.length - 1 : slot;
  const suffix = slot >= elements.length ? 'after' : 'before';
  if (kind === 'row') {
    elements[targetIndex].classList.add(`synapse-table-row-drop-${suffix}`);
    return;
  }
  for (const row of state.cells) {
    row[targetIndex]?.parentElement?.classList.add(
      `synapse-table-column-drop-${suffix}`,
    );
  }
}

function tableRowElements(state: TableDomState): HTMLElement[] {
  return Array.from(state.table.rows)
    .slice(1)
    .map((row) => row as HTMLElement);
}

function tableColumnElements(state: TableDomState): HTMLElement[] {
  return state.cells[0]?.map(
    (editor) => editor.parentElement as HTMLElement,
  ) ?? [];
}

function updateBlockDropIndicator(drag: TablePointerDrag): void {
  if (!view || drag.targetOffset == null) return;
  const coordinates = view.coordsAtPos(drag.targetOffset);
  const indicator = drag.blockIndicator ?? document.createElement('span');
  indicator.className = 'synapse-table-block-drop-indicator';
  const editorBounds = view.dom.getBoundingClientRect();
  indicator.style.left = `${editorBounds.left}px`;
  indicator.style.top = `${coordinates?.top ?? drag.clientY}px`;
  indicator.style.width = `${editorBounds.width}px`;
  if (!drag.blockIndicator) document.body.append(indicator);
  drag.blockIndicator = indicator;
}

function updateTableDragTarget(
  state: TableDomState,
  drag: TablePointerDrag,
): void {
  if (drag.kind === 'row') {
    const elements = tableRowElements(state);
    drag.insertionSlot = insertionSlot(elements, drag.clientY, false);
    markTableInsertion(state, elements, drag.insertionSlot, 'row');
    return;
  }
  if (drag.kind === 'column') {
    const elements = tableColumnElements(state);
    drag.insertionSlot = insertionSlot(elements, drag.clientX, true);
    markTableInsertion(state, elements, drag.insertionSlot, 'column');
    return;
  }
  drag.targetOffset = markdownOffsetAtCoords(drag.clientX, drag.clientY);
  updateBlockDropIndicator(drag);
}

function scheduleTableAutoScroll(
  state: TableDomState,
  drag: TablePointerDrag,
): void {
  if (drag.autoScrollFrame) return;
  const tick = () => {
    drag.autoScrollFrame = 0;
    if (state.drag !== drag || !drag.active || !view) return;
    let changed = false;
    const editorBounds = view.scrollDOM.getBoundingClientRect();
    if (drag.clientY < editorBounds.top + 32) {
      view.scrollDOM.scrollTop -= 14;
      changed = true;
    } else if (drag.clientY > editorBounds.bottom - 32) {
      view.scrollDOM.scrollTop += 14;
      changed = true;
    }
    if (drag.kind !== 'row') {
      const frameBounds = state.frame.getBoundingClientRect();
      if (drag.clientX < frameBounds.left + 28) {
        state.frame.scrollLeft -= 14;
        changed = true;
      } else if (drag.clientX > frameBounds.right - 28) {
        state.frame.scrollLeft += 14;
        changed = true;
      }
    }
    if (!changed) return;
    updateTableDragTarget(state, drag);
    drag.autoScrollFrame = requestAnimationFrame(tick);
  };
  drag.autoScrollFrame = requestAnimationFrame(tick);
}

function cleanupTableDrag(state: TableDomState, drag: TablePointerDrag): void {
  if (drag.autoScrollFrame) cancelAnimationFrame(drag.autoScrollFrame);
  window.removeEventListener('pointermove', drag.move);
  window.removeEventListener('pointerup', drag.finish);
  window.removeEventListener('pointercancel', drag.cancel);
  window.removeEventListener('keydown', drag.keydown, true);
  clearTableDropFeedback(state);
  drag.blockIndicator?.remove();
  drag.handle.classList.remove('synapse-table-dragging');
  try {
    if (drag.handle.hasPointerCapture?.(drag.pointerId)) {
      drag.handle.releasePointerCapture(drag.pointerId);
    }
  } catch (_) {
    // The WebView may already have released capture during cancellation.
  }
  if (state.drag === drag) state.drag = undefined;
}

function beginTableDrag(
  state: TableDomState,
  event: PointerEvent,
  kind: TableDragKind,
  source: number,
  handle: HTMLElement,
): void {
  if (!state.widget.editable || event.button !== 0) return;
  event.preventDefault();
  event.stopPropagation();
  state.drag?.cancel();
  const pointerId = Number.isInteger(event.pointerId) ? event.pointerId : 1;
  const drag = {} as TablePointerDrag;
  drag.kind = kind;
  drag.pointerId = pointerId;
  drag.source = source;
  drag.startX = event.clientX;
  drag.startY = event.clientY;
  drag.clientX = event.clientX;
  drag.clientY = event.clientY;
  drag.active = false;
  drag.insertionSlot = source;
  drag.handle = handle;
  drag.autoScrollFrame = 0;
  drag.move = (next) => {
    drag.clientX = next.clientX;
    drag.clientY = next.clientY;
    if (!drag.active) {
      const distance = Math.hypot(
        drag.clientX - drag.startX,
        drag.clientY - drag.startY,
      );
      if (distance < 4) return;
      drag.active = true;
      handle.classList.add('synapse-table-dragging');
      commitTableModel(state);
    }
    next.preventDefault();
    updateTableDragTarget(state, drag);
    scheduleTableAutoScroll(state, drag);
  };
  drag.finish = () => {
    const active = drag.active;
    const slot = drag.insertionSlot;
    const targetOffset = drag.targetOffset;
    cleanupTableDrag(state, drag);
    if (!active) {
      if (kind === 'table') safeDispatchSelection(state.widget.block.from);
      return;
    }
    if (kind === 'row') {
      const target = Math.max(
        0,
        Math.min(
          state.model.rows.length - 1,
          slot > source ? slot - 1 : slot,
        ),
      );
      if (target === source) return;
      commitTableStructure(
        state,
        { ...state.model, rows: moveItem(state.model.rows, source, target) },
        target + 1,
        state.selectedColumn,
      );
      return;
    }
    if (kind === 'column') {
      const target = Math.max(
        0,
        Math.min(
          state.model.header.length - 1,
          slot > source ? slot - 1 : slot,
        ),
      );
      if (target === source) return;
      const move = (row: string[]) => moveItem(row, source, target);
      commitTableStructure(
        state,
        {
          ...state.model,
          header: move(state.model.header),
          alignments: move(state.model.alignments),
          rows: state.model.rows.map(move),
        },
        state.selectedRow,
        target,
      );
      return;
    }
    if (targetOffset != null) {
      moveMarkdownRange(
        {
          from: state.widget.block.from,
          to: state.widget.block.to,
          block: true,
        },
        targetOffset,
      );
    }
  };
  drag.cancel = () => cleanupTableDrag(state, drag);
  drag.keydown = (keyEvent) => {
    if (keyEvent.key !== 'Escape') return;
    keyEvent.preventDefault();
    drag.cancel();
  };
  state.drag = drag;
  window.addEventListener('pointermove', drag.move);
  window.addEventListener('pointerup', drag.finish);
  window.addEventListener('pointercancel', drag.cancel);
  window.addEventListener('keydown', drag.keydown, true);
  try {
    handle.setPointerCapture?.(pointerId);
  } catch (_) {
    // Global pointer listeners remain the fallback in WebKit.
  }
}

function buildTableDom(state: TableDomState): void {
  const { frame } = state;
  const editable = state.widget.editable;
  const table = state.table;
  if (state.model.width != null) table.style.width = `${state.model.width}px`;
  const rows = [state.model.header, ...state.model.rows];
  state.cells = [];
  rows.forEach((row, rowIndex) => {
    const tr = document.createElement('tr');
    if (editable) {
      const rowHandle = document.createElement('th');
      rowHandle.className = 'synapse-table-row-handle';
      rowHandle.title = rowIndex === 0 ? '表头固定' : '拖动调整行顺序';
      rowHandle.dataset.tableRow = String(rowIndex);
      rowHandle.dataset.tableColumn = String(state.selectedColumn);
      if (rowIndex > 0) {
        rowHandle.addEventListener('pointerdown', (event) => {
          state.selectedRow = rowIndex;
          beginTableDrag(state, event, 'row', rowIndex - 1, rowHandle);
        });
      }
      tr.append(rowHandle);
    }
    const cellEditors: HTMLElement[] = [];
    row.forEach((value, columnIndex) => {
      const cell = document.createElement(rowIndex === 0 ? 'th' : 'td');
      cell.dataset.tableRow = String(rowIndex);
      cell.dataset.tableColumn = String(columnIndex);
      const editor = document.createElement('span');
      editor.className = 'synapse-table-cell-editor';
      editor.dataset.tableRow = String(rowIndex);
      editor.dataset.tableColumn = String(columnIndex);
      editor.textContent = displayTableCell(value);
      editor.contentEditable = editable ? 'true' : 'false';
      editor.tabIndex = editable ? 0 : -1;
      editor.spellcheck = false;
      if (editable) {
        editor.addEventListener('mousedown', (event) => {
          event.stopPropagation();
          state.selectedRow = rowIndex;
          state.selectedColumn = columnIndex;
        });
        editor.addEventListener('focus', () => {
          state.selectedRow = rowIndex;
          state.selectedColumn = columnIndex;
          state.focusedCell = editor;
        });
        editor.addEventListener('input', () => {
          state.model = withTableCellValue(
            state.model,
            rowIndex,
            columnIndex,
            editorTableCellValue(editor),
          );
          pendingNestedComposition = pendingNestedComposition || state.composing;
          scheduleTableCommit(state);
        });
        editor.addEventListener('compositionstart', () => {
          state.composing = true;
          pendingNestedComposition = true;
        });
        editor.addEventListener('compositionend', () => {
          state.composing = false;
          scheduleTableCommit(state);
        });
        editor.addEventListener('keydown', (event) => {
          const modifier = event.metaKey || event.ctrlKey;
          if (modifier && event.key.toLowerCase() === 'z') {
            event.preventDefault();
            commitTableModel(state);
            if (view) (event.shiftKey ? redo : undo)(view);
            return;
          }
          if (modifier && event.key.toLowerCase() === 'y') {
            event.preventDefault();
            commitTableModel(state);
            if (view) redo(view);
            return;
          }
          if (event.key === 'Enter' && !event.shiftKey) {
            event.preventDefault();
            commitTableModel(state);
            editor.blur();
          }
        });
      }
      cell.append(editor);
      if (editable && rowIndex === 0) {
        const columnHandle = document.createElement('span');
        columnHandle.className = 'synapse-table-column-handle';
        columnHandle.title = '拖动调整列顺序';
        columnHandle.contentEditable = 'false';
        columnHandle.dataset.tableRow = '0';
        columnHandle.dataset.tableColumn = String(columnIndex);
        columnHandle.addEventListener('pointerdown', (event) => {
          state.selectedRow = 0;
          state.selectedColumn = columnIndex;
          beginTableDrag(
            state,
            event,
            'column',
            columnIndex,
            columnHandle,
          );
        });
        cell.append(columnHandle);
      }
      tr.append(cell);
      cellEditors.push(editor);
    });
    state.cells.push(cellEditors);
    table.append(tr);
  });
  frame.append(table);

  if (editable) {
    const blockHandle = document.createElement('span');
    blockHandle.className = 'synapse-table-block-handle';
    blockHandle.title = '拖动整张表格';
    blockHandle.setAttribute('aria-label', '拖动整张表格');
    blockHandle.addEventListener('pointerdown', (event) =>
      beginTableDrag(state, event, 'table', -1, blockHandle));
    frame.append(blockHandle);

    const resize = document.createElement('span');
    resize.className = 'synapse-table-resize';
    resize.addEventListener('pointerdown', (event) => {
      event.preventDefault();
      event.stopPropagation();
      const startX = event.clientX;
      const startWidth = table.getBoundingClientRect().width;
      const move = (next: PointerEvent) => {
        table.style.width = `${clampTableWidth(
          startWidth + next.clientX - startX,
          state.model.header.length,
        )}px`;
      };
      const cleanup = () => {
        window.removeEventListener('pointermove', move);
        window.removeEventListener('pointerup', end);
        window.removeEventListener('pointercancel', cancel);
      };
      const end = () => {
        cleanup();
        commitTableModel(
          state,
          {
            ...state.model,
            width: clampTableWidth(
              table.getBoundingClientRect().width,
              state.model.header.length,
            ),
          },
          'input.table.structure',
        );
      };
      const cancel = () => {
        cleanup();
        if (state.model.width == null) table.style.removeProperty('width');
        else table.style.width = `${state.model.width}px`;
      };
      window.addEventListener('pointermove', move);
      window.addEventListener('pointerup', end, { once: true });
      window.addEventListener('pointercancel', cancel, { once: true });
    });
    frame.append(resize);
  }

  frame.addEventListener('pointerdown', (event) => {
    if (event.button !== 0 || runtime?.mode !== 'editing') return;
    const position = tableCellPosition(state, event.target);
    state.selectedRow = position.row;
    state.selectedColumn = position.column;
    if (state.widget.editable && runtime.focused) return;
    requestTableActivation(state, position.row, position.column);
    event.preventDefault();
    event.stopPropagation();
  }, true);
  frame.addEventListener('mousedown', (event) => {
    const target = event.target instanceof Element ? event.target : null;
    if (target?.closest(
      '.synapse-table-cell-editor, .synapse-table-block-handle, '
        + '.synapse-table-row-handle, .synapse-table-column-handle, '
        + '.synapse-table-resize, td, th',
    )) return;
    event.preventDefault();
    safeDispatchSelection(state.widget.block.from);
  });
  frame.addEventListener('focusout', () => {
    window.setTimeout(() => {
      if (
        !state.contextMenuOpen &&
        !frame.contains(document.activeElement)
      ) commitTableModel(state);
    }, 0);
  });
  frame.addEventListener('contextmenu', (event) => {
    event.preventDefault();
    const position = tableCellPosition(state, event.target);
    state.selectedRow = position.row;
    state.selectedColumn = position.column;
    if (runtime?.mode === 'editing' && !state.widget.editable) {
      requestTableActivation(
        state,
        position.row,
        position.column,
        { x: event.clientX, y: event.clientY },
      );
      return;
    }
    if (state.pendingFrame) cancelAnimationFrame(state.pendingFrame);
    state.pendingFrame = 0;
    const editor = state.cells[position.row]?.[position.column];
    if (editor) {
      showContextMenu(
        event.clientX,
        event.clientY,
        tableCellContextTarget(state, position.row, position.column, editor),
      );
    }
  });
}

function tableCellContextTarget(
  state: TableDomState,
  row: number,
  column: number,
  editor: HTMLElement,
): TableCellContextTarget {
  const selection = captureCellSelection(editor) ?? {
    anchor: editor.textContent?.length ?? 0,
    head: editor.textContent?.length ?? 0,
  };
  return { kind: 'tableCell', state, row, column, editor, selection };
}

class TableWidget extends WidgetType {
  constructor(readonly block: MarkdownBlock, readonly editable: boolean) {
    super();
  }

  eq(other: TableWidget): boolean {
    return other.block.from === this.block.from &&
      other.block.text === this.block.text &&
      other.editable === this.editable;
  }

  toDOM(): HTMLElement {
    const frame = document.createElement('div');
    frame.className = 'synapse-table-frame';
    frame.dataset.markdownFrom = String(this.block.from);
    frame.dataset.markdownTo = String(this.block.to);
    frame.contentEditable = 'false';
    const model = parseTableModel(this.block.text);
    if (!model) {
      frame.textContent = this.block.text;
      return frame;
    }
    const state: TableDomState = {
      widget: this,
      frame,
      table: document.createElement('table'),
      model: cloneTableModel(model),
      cells: [],
      selectedRow: 0,
      selectedColumn: 0,
      pendingFrame: 0,
      focusRestoreFrame: 0,
      composing: false,
      contextMenuOpen: false,
    };
    tableDomStates.set(frame, state);
    mountedTableStates.add(state);
    buildTableDom(state);
    return frame;
  }

  ignoreEvent(): boolean {
    return true;
  }

  updateDOM(dom: HTMLElement): boolean {
    const state = tableDomStates.get(dom);
    const next = parseTableModel(this.block.text);
    if (
      !state ||
      !next ||
      state.widget.editable !== this.editable ||
      !tableDomHasSameShape(state, next)
    ) return false;
    const selfCommit = state.committingMarkdown === this.block.text;
    state.widget = this;
    dom.dataset.markdownFrom = String(this.block.from);
    dom.dataset.markdownTo = String(this.block.to);
    state.model = cloneTableModel(next);
    if (next.width == null) state.table.style.removeProperty('width');
    else state.table.style.width = `${next.width}px`;
    for (let rowIndex = 0; rowIndex < state.cells.length; rowIndex += 1) {
      for (
        let columnIndex = 0;
        columnIndex < state.cells[rowIndex].length;
        columnIndex += 1
      ) {
        const editor = state.cells[rowIndex][columnIndex];
        if (selfCommit && document.activeElement === editor) continue;
        const value = displayTableCell(
          tableCellValue(next, rowIndex, columnIndex),
        );
        if (editor.textContent === value) continue;
        const selection = captureCellSelection(editor);
        editor.textContent = value;
        restoreCellSelection(editor, selection);
      }
    }
    state.committingMarkdown = undefined;
    return true;
  }

  destroy(dom: HTMLElement): void {
    const state = tableDomStates.get(dom);
    if (!state) return;
    state.drag?.cancel();
    if (state.pendingFrame) cancelAnimationFrame(state.pendingFrame);
    if (state.focusRestoreFrame) cancelAnimationFrame(state.focusRestoreFrame);
    mountedTableStates.delete(state);
    tableDomStates.delete(dom);
  }
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
  themeKey: string;
  searchKey: string;
  focusRestoreFrame: number;
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

function syncColumnsFocus(state: ColumnsDomState): void {
  state.root.classList.toggle(
    'synapse-columns-focused',
    state.widget.editable && state.root.contains(document.activeElement),
  );
}

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
  const selection = selectionOf(state);
  const active = activeBlockForSelection(blocks, selection);
  const imageFocused =
    runtimeState.editable &&
    runtimeState.host.contains(document.activeElement);
  const ranges: any[] = [];
  for (const block of blocks) {
    const activeBlock =
      runtimeState.editable &&
      runtimeState.host.contains(document.activeElement) &&
      active?.from === block.from;
    const absolute = absoluteBlock(block, runtimeState.baseOffset);
    if (block.kind === 'pageBreak' && !activeBlock) {
      ranges.push(Decoration.replace({ widget: new PageBreakWidget(absolute.from, absolute.to), block: true }).range(block.from, block.to));
      continue;
    }
    if (block.kind === 'image') {
      const src = markdownImageSource(block.text);
      if (src) {
        const selected =
          imageFocused && imageSelectionMatches(selection, block.from);
        ranges.push(Decoration.replace({
          widget: new ImageWidget(
            absolute.from,
            absolute.to,
            src,
            markdownImageWidth(block.text),
            true,
            selected,
            runtimeState.editable,
            () => {
              runtimeState.editorView.focus();
              runtimeState.editorView.dispatch({
                selection: { anchor: block.from },
              });
            },
          ),
          block: true,
        }).range(block.from, block.to));
      }
      continue;
    }
    if (block.kind === 'table') {
      ranges.push(Decoration.replace({ widget: new TableWidget(absolute, runtimeState.editable), block: true }).range(block.from, block.to));
      continue;
    }
    const images = imageRanges(block);
    const selectedImage = imageFocused
      ? images.find((image) => imageSelectionMatches(selection, image.from))
      : undefined;
    if (!activeBlock || selectedImage != null) {
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
            selectedImage?.from === image.from,
            runtimeState.editable,
            () => {
              runtimeState.editorView.focus();
              runtimeState.editorView.dispatch({
                selection: { anchor: image.from },
              });
            },
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

function columnThemeKey(theme: EditorTheme): string {
  return JSON.stringify(theme);
}

function columnSearchKey(query: SearchQuery, visible: boolean): string {
  return JSON.stringify({
    search: query.search,
    replace: query.replace,
    caseSensitive: query.caseSensitive,
    wholeWord: query.wholeWord,
    visible,
  });
}

function dispatchParentFromColumn(
  runtimeState: ColumnSideRuntime,
  transaction: Parameters<EditorView['dispatch']>[0],
): void {
  const hadFocus = runtimeState.editorView.hasFocus;
  const parentScrollTop = runtimeState.parentView.scrollDOM.scrollTop;
  const parentScrollLeft = runtimeState.parentView.scrollDOM.scrollLeft;
  const childScrollTop = runtimeState.editorView.scrollDOM.scrollTop;
  const childScrollLeft = runtimeState.editorView.scrollDOM.scrollLeft;
  runtimeState.parentView.dispatch(transaction);
  if (!hadFocus) return;
  const restore = () => {
    runtimeState.editorView.focus();
    runtimeState.parentView.scrollDOM.scrollTop = parentScrollTop;
    runtimeState.parentView.scrollDOM.scrollLeft = parentScrollLeft;
    runtimeState.editorView.scrollDOM.scrollTop = childScrollTop;
    runtimeState.editorView.scrollDOM.scrollLeft = childScrollLeft;
  };
  restore();
  if (runtimeState.focusRestoreFrame) {
    cancelAnimationFrame(runtimeState.focusRestoreFrame);
  }
  runtimeState.focusRestoreFrame = requestAnimationFrame(() => {
    runtimeState.focusRestoreFrame = 0;
    if (runtimeState.editorView.hasFocus) return;
    const active = document.activeElement;
    const parentRecoveredFocus = active instanceof HTMLElement &&
      active.classList.contains('cm-content') &&
      runtimeState.parentView.dom.contains(active) &&
      !runtimeState.host.contains(active);
    if (parentRecoveredFocus) restore();
  });
}

function syncColumnRuntime(
  runtimeState: ColumnSideRuntime,
  source: string,
  from: number,
  to: number,
  editable: boolean,
  parentSelection: EditorSelection,
): void {
  const previousBaseOffset = runtimeState.baseOffset;
  const previousEditable = runtimeState.editable;
  runtimeState.baseOffset = from;
  runtimeState.toOffset = to;
  runtimeState.editable = editable;
  runtimeState.editorView.contentDOM.tabIndex = editable ? 0 : -1;
  const sourceMatches = runtimeState.editorView.state.doc.toString() === source;
  if (runtimeState.editorView.composing && sourceMatches && previousEditable === editable) {
    return;
  }
  runtimeState.syncing = true;
  try {
    const childSelection = sideSelection(parentSelection, from, to);
    const query = getSearchQuery(runtimeState.parentView.state);
    const visible = runtimeState.parentView.state.field(searchVisibilityField);
    const nextThemeKey = columnThemeKey(runtime!.theme);
    const nextSearchKey = columnSearchKey(query, visible);
    const selection = selectionOf(runtimeState.editorView.state);
    const effects: StateEffect<unknown>[] = [];
    if (previousEditable !== editable) {
      effects.push(
        runtimeState.editableCompartment.reconfigure([
          EditorView.editable.of(editable),
          EditorState.readOnly.of(!editable),
        ]),
      );
    }
    if (runtimeState.themeKey !== nextThemeKey) {
      runtimeState.themeKey = nextThemeKey;
      effects.push(
        runtimeState.themeCompartment.reconfigure(
          columnEditorTheme(runtime!.theme),
        ),
      );
    }
    if (runtimeState.searchKey !== nextSearchKey) {
      runtimeState.searchKey = nextSearchKey;
      effects.push(setSearchQuery.of(query), setSearchVisibility.of(visible));
    }
    if (previousBaseOffset !== from || previousEditable !== editable) {
      effects.push(refreshColumnPreview.of(null));
    }
    const selectionMatches =
      selection.anchor === childSelection.anchor &&
      selection.head === childSelection.head;
    if (sourceMatches && selectionMatches && effects.length === 0) {
      return;
    }
    runtimeState.editorView.dispatch({
      changes: sourceMatches
        ? undefined
        : { from: 0, to: runtimeState.editorView.state.doc.length, insert: source },
      selection: selectionMatches ? undefined : childSelection,
      effects,
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
  const query = getSearchQuery(parentView.state);
  const runtimeState: ColumnSideRuntime = {
    parentView,
    editorView: undefined as unknown as EditorView,
    baseOffset: from,
    toOffset: to,
    editable,
    syncing: false,
    editableCompartment: new Compartment(),
    themeCompartment: new Compartment(),
    host,
    themeKey: columnThemeKey(runtime!.theme),
    searchKey: columnSearchKey(
      query,
      parentView.state.field(searchVisibilityField),
    ),
    focusRestoreFrame: 0,
  };
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
          ...imageKeyBindings(() => runtimeState.baseOffset),
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
            dispatchParentFromColumn(runtimeState, {
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
            dispatchParentFromColumn(runtimeState, {
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
          pointerdown(event, editorView) {
            if (event.button !== 2) return false;
            const position = editorView.posAtCoords({
              x: event.clientX,
              y: event.clientY,
            });
            const selection = editorView.state.selection.main;
            if (
              position != null &&
              !selection.empty &&
              position >= selection.from &&
              position <= selection.to
            ) {
              event.preventDefault();
              return true;
            }
            return false;
          },
          contextmenu(event, editorView) {
            event.preventDefault();
            const local = editorView.posAtCoords({ x: event.clientX, y: event.clientY }) ?? editorView.state.selection.main.head;
            showContextMenu(
              event.clientX,
              event.clientY,
              documentContextTarget(editorView, local, runtimeState.baseOffset),
            );
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
  runtimeState.editorView.contentDOM.tabIndex = editable ? 0 : -1;
  const refreshFocusPreview = () => {
    if (!runtimeState.editorView.dom.isConnected) return;
    runtimeState.editorView.dispatch({
      effects: refreshColumnPreview.of(null),
      annotations: hostChange.of(true),
    });
  };
  runtimeState.host.addEventListener('focusin', refreshFocusPreview);
  runtimeState.host.addEventListener('focusout', () => {
    queueMicrotask(refreshFocusPreview);
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

function markdownOffsetAtCoords(x: number, y: number): number | undefined {
  for (const root of document.querySelectorAll<HTMLElement>('.synapse-columns')) {
    const bounds = root.getBoundingClientRect();
    if (x < bounds.left || x > bounds.right || y < bounds.top || y > bounds.bottom) {
      continue;
    }
    const state = columnsDomStates.get(root);
    if (state) return absolutePosAtCoords(state, x, y);
  }
  const resolved = view?.posAtCoords({ x, y });
  if (resolved != null) return resolved;
  if (!view || typeof document.elementFromPoint !== 'function') return undefined;
  const pointed = document.elementFromPoint(x, y);
  const line = pointed?.closest<HTMLElement>('.cm-line');
  if (!line || !view.dom.contains(line)) return undefined;
  const bounds = line.getBoundingClientRect();
  const offset = x < bounds.left + bounds.width / 2
    ? 0
    : line.childNodes.length;
  try {
    return view.posAtDOM(line, offset);
  } catch (_) {
    return undefined;
  }
}

interface ImageDropSurface {
  editorView: EditorView;
  baseOffset: number;
  host: HTMLElement;
  rect: DOMRect;
  parent: boolean;
}

interface ImageDropBlock {
  from: number;
  to: number;
  rect: DOMRect;
}

function rectFromEdges(
  left: number,
  top: number,
  right: number,
  bottom: number,
): DOMRect {
  const width = Math.max(0, right - left);
  const height = Math.max(0, bottom - top);
  return {
    x: left,
    y: top,
    left,
    top,
    right,
    bottom,
    width,
    height,
    toJSON: () => ({ left, top, right, bottom, width, height }),
  } as DOMRect;
}

function horizontalDistance(x: number, rect: DOMRect): number {
  if (x < rect.left) return rect.left - x;
  if (x > rect.right) return x - rect.right;
  return 0;
}

function imageDropSurfaceAtCoords(
  x: number,
  y: number,
): ImageDropSurface | undefined {
  if (!view) return undefined;
  const scrollRect = view.scrollDOM.getBoundingClientRect();
  if (
    x < scrollRect.left || x > scrollRect.right ||
    y < scrollRect.top || y > scrollRect.bottom
  ) {
    return undefined;
  }
  for (const root of document.querySelectorAll<HTMLElement>('.synapse-columns')) {
    const rootRect = root.getBoundingClientRect();
    if (
      x < rootRect.left || x > rootRect.right ||
      y < rootRect.top || y > rootRect.bottom
    ) {
      continue;
    }
    const state = columnsDomStates.get(root);
    if (!state) continue;
    const sides = [state.left, state.right]
      .map((side) => ({ side, rect: side.host.getBoundingClientRect() }))
      .sort((left, right) =>
        horizontalDistance(x, left.rect) - horizontalDistance(x, right.rect));
    const chosen = sides[0];
    if (!chosen) continue;
    return {
      editorView: chosen.side.editorView,
      baseOffset: chosen.side.baseOffset,
      host: chosen.side.host,
      rect: chosen.rect,
      parent: false,
    };
  }
  const contentRect = view.contentDOM.getBoundingClientRect();
  const rect = contentRect.width > 0 ? contentRect : view.dom.getBoundingClientRect();
  return {
    editorView: view,
    baseOffset: 0,
    host: view.dom,
    rect,
    parent: true,
  };
}

function domLineAtPosition(
  editorView: EditorView,
  position: number,
): HTMLElement | undefined {
  try {
    const resolved = editorView.domAtPos(
      Math.max(0, Math.min(position, editorView.state.doc.length)),
    );
    const element = resolved.node instanceof Element
      ? resolved.node
      : resolved.node.parentElement;
    return element?.closest<HTMLElement>('.cm-line') ?? undefined;
  } catch (_) {
    return undefined;
  }
}

function structuralBlockElement(
  surface: ImageDropSurface,
  from: number,
  to: number,
): HTMLElement | undefined {
  return Array.from(
    surface.host.querySelectorAll<HTMLElement>(
      '[data-markdown-from][data-markdown-to]',
    ),
  ).find((element) =>
    Number(element.dataset.markdownFrom) === from &&
    Number(element.dataset.markdownTo) === to);
}

function imageDropBlockRect(
  surface: ImageDropSurface,
  localBlock: MarkdownBlock,
): DOMRect | undefined {
  const from = surface.baseOffset + localBlock.from;
  const to = surface.baseOffset + localBlock.to;
  const structural = structuralBlockElement(surface, from, to);
  const structuralRect = structural?.getBoundingClientRect();
  if (structuralRect && structuralRect.width > 0 && structuralRect.height > 0) {
    return structuralRect;
  }
  const firstLine = domLineAtPosition(surface.editorView, localBlock.from);
  const lastLine = domLineAtPosition(
    surface.editorView,
    Math.max(localBlock.from, localBlock.to - 1),
  );
  const firstRect = firstLine?.getBoundingClientRect();
  const lastRect = lastLine?.getBoundingClientRect();
  if (
    firstRect && lastRect &&
    firstRect.height > 0 && lastRect.height > 0
  ) {
    return rectFromEdges(
      surface.rect.left,
      Math.min(firstRect.top, lastRect.top),
      surface.rect.right,
      Math.max(firstRect.bottom, lastRect.bottom),
    );
  }
  const start = coordsAtEditorOffset(surface.editorView, localBlock.from);
  const end = coordsAtEditorOffset(
    surface.editorView,
    Math.max(localBlock.from, localBlock.to - 1),
  );
  if (!start || !end) return undefined;
  const top = Math.min(start.top, end.top);
  const bottom = Math.max(start.bottom, end.bottom);
  if (bottom <= top) return undefined;
  return rectFromEdges(surface.rect.left, top, surface.rect.right, bottom);
}

function parentColumnRanges(): Array<{ from: number; to: number }> {
  const ranges: Array<{ from: number; to: number }> = [];
  for (const root of document.querySelectorAll<HTMLElement>('.synapse-columns')) {
    const state = columnsDomStates.get(root);
    if (state) ranges.push({ from: state.widget.from, to: state.widget.to });
  }
  return ranges;
}

function visibleImageDropBlocks(surface: ImageDropSurface): ImageDropBlock[] {
  if (!view) return [];
  const scrollRect = view.scrollDOM.getBoundingClientRect();
  const columnRanges = surface.parent ? parentColumnRanges() : [];
  const blocks: ImageDropBlock[] = [];
  for (const block of splitMarkdownBlocks(surface.editorView.state.doc.toString())) {
    if (
      block.kind === 'blank' ||
      block.kind === 'columnsStart' ||
      block.kind === 'columnsSeparator' ||
      block.kind === 'columnsEnd'
    ) {
      continue;
    }
    const absoluteFrom = surface.baseOffset + block.from;
    const absoluteTo = surface.baseOffset + block.to;
    if (
      columnRanges.some((range) =>
        absoluteFrom >= range.from && absoluteTo <= range.to)
    ) {
      continue;
    }
    const rect = imageDropBlockRect(surface, block);
    if (!rect || rect.bottom < scrollRect.top || rect.top > scrollRect.bottom) {
      continue;
    }
    blocks.push({ from: absoluteFrom, to: absoluteTo, rect });
  }
  if (surface.parent) {
    for (const root of document.querySelectorAll<HTMLElement>('.synapse-columns')) {
      const state = columnsDomStates.get(root);
      if (!state) continue;
      const rect = root.getBoundingClientRect();
      if (rect.bottom < scrollRect.top || rect.top > scrollRect.bottom) continue;
      blocks.push({ from: state.widget.from, to: state.widget.to, rect });
    }
  }
  blocks.sort((left, right) =>
    left.rect.top - right.rect.top || left.from - right.from);
  return blocks;
}

function verticalDistance(y: number, rect: DOMRect): number {
  if (y < rect.top) return rect.top - y;
  if (y > rect.bottom) return y - rect.bottom;
  return 0;
}

function imageDropBoundaryAtCoords(
  range: DraggedMarkdownRange,
  x: number,
  y: number,
): ImageDropBoundary | undefined {
  if (!runtime?.editable || !runtime.focused || !draggedRangeStillValid(range)) {
    return undefined;
  }
  const surface = imageDropSurfaceAtCoords(x, y);
  if (!surface) return undefined;
  const removal = imageRemovalBounds(range);
  const validSourceOffset = (sourceOffset: number) =>
    sourceOffset < removal.from || sourceOffset > removal.to;
  const blocks = visibleImageDropBlocks(surface);
  const docLength = surface.editorView.state.doc.length;
  if (blocks.length === 0) {
    const top = Math.max(surface.rect.top, view!.scrollDOM.getBoundingClientRect().top);
    const blockRect = rectFromEdges(
      surface.rect.left,
      top,
      surface.rect.right,
      top + 24,
    );
    const sourceOffset = surface.baseOffset + docLength;
    return {
      sourceOffset,
      blockFrom: sourceOffset,
      blockTo: sourceOffset,
      placement: 'after',
      blockRect,
      surfaceRect: surface.rect,
      valid: validSourceOffset(sourceOffset),
    };
  }
  let block = blocks[0];
  for (const candidate of blocks.slice(1)) {
    if (verticalDistance(y, candidate.rect) < verticalDistance(y, block.rect)) {
      block = candidate;
    }
  }
  let placement: 'before' | 'after';
  let sourceOffset: number;
  if (y < blocks[0].rect.top) {
    block = blocks[0];
    placement = 'before';
    sourceOffset = surface.baseOffset;
  } else if (y > blocks[blocks.length - 1].rect.bottom) {
    block = blocks[blocks.length - 1];
    placement = 'after';
    sourceOffset = surface.baseOffset + docLength;
  } else {
    placement = y < block.rect.top + block.rect.height / 2
      ? 'before'
      : 'after';
    sourceOffset = placement === 'before' ? block.from : block.to;
  }
  return {
    sourceOffset,
    blockFrom: block.from,
    blockTo: block.to,
    placement,
    blockRect: block.rect,
    surfaceRect: surface.rect,
    valid: validSourceOffset(sourceOffset),
  };
}

function coordsAtEditorOffset(editorView: EditorView, offset: number) {
  const position = Math.max(
    0,
    Math.min(offset, editorView.state.doc.length),
  );
  const coordinates = editorView.coordsAtPos(position);
  if (coordinates) return coordinates;
  try {
    const block = editorView.lineBlockAt(position);
    const top = editorView.documentTop + block.top;
    return {
      top,
      bottom: top + block.height,
    };
  } catch (_) {
    return undefined;
  }
}

function coordsAtMarkdownOffset(offset: number) {
  for (const root of document.querySelectorAll<HTMLElement>('.synapse-columns')) {
    const state = columnsDomStates.get(root);
    if (!state) continue;
    for (const side of [state.left, state.right]) {
      if (offset < side.baseOffset || offset > side.toOffset) continue;
      return coordsAtEditorOffset(side.editorView, offset - side.baseOffset);
    }
  }
  return view ? coordsAtEditorOffset(view, offset) : undefined;
}

function focusImageAtMarkdownOffset(offset: number): void {
  for (const root of document.querySelectorAll<HTMLElement>('.synapse-columns')) {
    const state = columnsDomStates.get(root);
    if (!state) continue;
    for (const side of [state.left, state.right]) {
      if (offset < side.baseOffset || offset > side.toOffset) continue;
      side.editorView.focus();
      side.editorView.dispatch({
        selection: {
          anchor: Math.max(
            0,
            Math.min(offset - side.baseOffset, side.editorView.state.doc.length),
          ),
        },
      });
      return;
    }
  }
  view?.focus();
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
    readonly flattenedSource: string,
  ) { super(); }

  eq(other: ColumnsWidget): boolean {
    return other.from === this.from && other.to === this.to && other.left === this.left && other.right === this.right && other.ratio === this.ratio && other.editable === this.editable && other.flattenedSource === this.flattenedSource;
  }

  toDOM(parentView: EditorView): HTMLElement {
    const root = document.createElement('div');
    root.className = 'synapse-columns';
    root.dataset.markdownFrom = String(this.from);
    root.dataset.markdownTo = String(this.to);
    root.contentEditable = 'false';
    const content = document.createElement('div');
    content.className = 'synapse-columns-content';
    content.style.gridTemplateColumns = `${this.ratio}fr 0px ${100 - this.ratio}fr`;
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
    const state: ColumnsDomState = {
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
    };
    leftRuntime.columnsState = state;
    rightRuntime.columnsState = state;
    columnsDomStates.set(root, state);
    root.addEventListener('focusin', () => syncColumnsFocus(state));
    root.addEventListener('focusout', () => {
      queueMicrotask(() => syncColumnsFocus(state));
    });
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
        changes: { from: widget.from, to: widget.to, insert: widget.flattenedSource },
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
        if (
          event.target instanceof Element &&
          event.target.closest('.synapse-table-frame')
        ) return;
        const local = side.editorView.posAtCoords({ x: event.clientX, y: event.clientY });
        if (!state.widget.editable || !runtime?.focused) {
          pendingColumnFocus = {
            layoutFrom: state.widget.from,
            side: state.left === side ? 'left' : 'right',
          };
          state.parentView.dispatch({
            selection: {
              anchor: side.baseOffset +
                (local ?? side.editorView.state.selection.main.head),
            },
          });
          post({ type: 'focusChanged', focused: true });
          event.preventDefault();
          return;
        }
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

  ignoreEvent(): boolean { return true; }

  updateDOM(dom: HTMLElement, parentView: EditorView): boolean {
    const state = columnsDomStates.get(dom);
    if (!state) return false;
    state.widget = this;
    dom.dataset.markdownFrom = String(this.from);
    dom.dataset.markdownTo = String(this.to);
    state.parentView = parentView;
    state.controls.hidden = !this.editable;
    state.root.classList.toggle('synapse-columns-editable', this.editable);
    syncColumnsFocus(state);
    state.content.style.gridTemplateColumns = `${this.ratio}fr 0px ${100 - this.ratio}fr`;
    syncColumnRuntime(state.left, this.left, this.leftOffset, this.leftTo, this.editable, selectionOf(parentView.state));
    syncColumnRuntime(state.right, this.right, this.rightOffset, this.rightTo, this.editable, selectionOf(parentView.state));
    return true;
  }

  destroy(dom: HTMLElement): void {
    const state = columnsDomStates.get(dom);
    if (!state) return;
    window.removeEventListener('pointermove', state.pointerMove);
    window.removeEventListener('pointerup', state.pointerUp);
    if (state.left.focusRestoreFrame) {
      cancelAnimationFrame(state.left.focusRestoreFrame);
    }
    if (state.right.focusRestoreFrame) {
      cancelAnimationFrame(state.right.focusRestoreFrame);
    }
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

function focusPendingColumn(): boolean {
  const pending = pendingColumnFocus;
  pendingColumnFocus = undefined;
  if (!pending) return false;
  for (const root of document.querySelectorAll<HTMLElement>('.synapse-columns')) {
    const state = columnsDomStates.get(root);
    if (!state || state.widget.from !== pending.layoutFrom) continue;
    state[pending.side].editorView.focus();
    return true;
  }
  return false;
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

function imageSelectionMatches(
  selection: EditorSelection,
  imageFrom: number,
): boolean {
  return selection.anchor === imageFrom && selection.head === imageFrom;
}

interface SelectedImageRange {
  from: number;
  to: number;
  src: string;
  block: MarkdownBlock;
}

function selectedImageRange(
  state: EditorState,
  baseOffset = 0,
): SelectedImageRange | undefined {
  const selection = selectionOf(state);
  if (selection.anchor !== selection.head) return undefined;
  for (const block of splitMarkdownBlocks(state.doc.toString())) {
    if (block.kind === 'image') {
      const src = markdownImageSource(block.text);
      if (src && imageSelectionMatches(selection, block.from)) {
        return {
          from: baseOffset + block.from,
          to: baseOffset + block.to,
          src,
          block: absoluteBlock(block, baseOffset),
        };
      }
      continue;
    }
    const image = imageRanges(block).find((candidate) =>
      imageSelectionMatches(selection, candidate.from));
    if (image) {
      return {
        from: baseOffset + image.from,
        to: baseOffset + image.to,
        src: image.src,
        block: absoluteBlock(block, baseOffset),
      };
    }
  }
  return undefined;
}

function withoutStructuralTrailingLineBreak(source: string): string {
  if (source.endsWith('\r\n')) return source.slice(0, -2);
  if (source.endsWith('\n')) return source.slice(0, -1);
  return source;
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
    const fullLeft = documentText.slice(leftOffset, separator.from);
    const fullRight = documentText.slice(rightOffset, end.from);
    const left = withoutStructuralTrailingLineBreak(fullLeft);
    const right = withoutStructuralTrailingLineBreak(fullRight);
    result.push({
      from: start.from,
      to: end.to,
      widget: new ColumnsWidget(
        start.from,
        end.to,
        left,
        right,
        leftOffset,
        leftOffset + left.length,
        rightOffset,
        rightOffset + right.length,
        ratio,
        editable,
        `${fullLeft}${fullRight}`,
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
      ranges.push(Decoration.replace({ widget: new PageBreakWidget(block.from, block.to), block: true }).range(block.from, block.to));
      continue;
    }
    if (block.kind === 'image') {
      const src = markdownImageSource(block.text);
      if (src) ranges.push(Decoration.replace({
        widget: new ImageWidget(
          block.from,
          block.to,
          src,
          markdownImageWidth(block.text),
          true,
          imageSelectionMatches(selection, block.from),
          editable,
        ),
        block: true,
      }).range(block.from, block.to));
      continue;
    }
    if (block.kind === 'table') {
      ranges.push(Decoration.replace({ widget: new TableWidget(block, editable), block: true }).range(block.from, block.to));
      continue;
    }
    const images = imageRanges(block);
    const selectedImage = images.find((image) =>
      imageSelectionMatches(selection, image.from));
    if (!activeBlock || selectedImage != null) {
      const overlapsImage = (from: number, to: number) =>
        images.some((image) => from < image.to && to > image.from);
      for (const marker of markerRanges(block)) {
        if (overlapsImage(marker.from, marker.to)) continue;
        if (marker.from < marker.to) ranges.push(Decoration.replace({}).range(marker.from, marker.to));
      }
      for (const style of inlineStyleDecorations(block)) ranges.push(style);
      for (const image of images) {
        ranges.push(Decoration.replace({
          widget: new ImageWidget(
            image.from,
            image.to,
            image.src,
            image.width,
            false,
            selectedImage?.from === image.from,
            editable,
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
    '.cm-scroller': { position: 'relative', overflow: 'auto', fontFamily: theme.fontFamily, lineHeight: '1.55' },
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
    '.synapse-page-layout': { position: 'absolute', top: '0', zIndex: '5', pointerEvents: 'none', userSelect: 'none' },
    '.synapse-page-layout-stale': { opacity: '0.4' },
    '.synapse-page-boundary': { position: 'absolute', left: '0', width: '100%', height: '0', borderTop: `1px dashed ${theme.accent}`, pointerEvents: 'none' },
    '.synapse-page-boundary-label': { position: 'absolute', right: '0', top: '0', transform: 'translateY(-50%)', padding: '2px 4px', borderRadius: '4px', color: theme.accent, backgroundColor: theme.background, font: '600 10px/1.2 -apple-system, BlinkMacSystemFont, sans-serif', whiteSpace: 'nowrap' },
    '.synapse-image-block': { position: 'relative', display: 'block', width: 'fit-content', maxWidth: '100%', margin: '5px 0' },
    '.synapse-inline-image': { position: 'relative', display: 'inline-block', verticalAlign: 'middle', maxWidth: '100%' },
    '.synapse-image-block img, .synapse-inline-image img': { display: 'block', height: 'auto', borderRadius: '6px', pointerEvents: 'none' },
    '.synapse-image-selected': { outline: `1px solid ${theme.accent}`, outlineOffset: '3px', borderRadius: '6px' },
    '.synapse-image-dragging': { opacity: '0.58' },
    '&.synapse-image-drag-active, &.synapse-image-drag-active *': { cursor: 'grabbing !important' },
    '.synapse-image-drag-preview': { position: 'fixed', left: '0', top: '0', zIndex: '2147483646', display: 'flex', alignItems: 'center', justifyContent: 'center', boxSizing: 'border-box', maxWidth: '180px', maxHeight: '120px', overflow: 'hidden', padding: '4px', border: `1px solid ${theme.accent}`, borderRadius: '8px', backgroundColor: theme.surface, boxShadow: '0 10px 28px rgba(0,0,0,.28)', opacity: '.86', pointerEvents: 'none', userSelect: 'none', willChange: 'transform' },
    '.synapse-image-drag-preview img': { display: 'block', width: 'auto', height: 'auto', maxWidth: '172px', maxHeight: '112px', objectFit: 'contain', borderRadius: '5px' },
    '.synapse-image-drag-preview-fallback': { minWidth: '72px', minHeight: '48px', display: 'flex', alignItems: 'center', justifyContent: 'center', color: theme.muted, font: '600 12px/1.2 -apple-system, BlinkMacSystemFont, sans-serif' },
    '.synapse-image-drop-target': { position: 'fixed', zIndex: '2147483644', boxSizing: 'border-box', border: `1px solid ${theme.accent}`, borderRadius: '6px', backgroundColor: `${theme.accent}16`, pointerEvents: 'none', userSelect: 'none' },
    '.synapse-image-loading': { color: theme.muted, fontSize: '12px' },
    '.synapse-image-broken': { color: theme.muted, textDecoration: 'line-through' },
    '.synapse-image-move-handle': { position: 'absolute', left: '-7px', top: '-7px', zIndex: '3', width: '18px', height: '18px', borderRadius: '4px', color: theme.muted, backgroundColor: theme.surface, boxShadow: `0 0 0 1px ${theme.line}`, cursor: 'grab', userSelect: 'none' },
    '.synapse-image-move-handle::before': { content: '"⠿"', display: 'block', fontSize: '13px', lineHeight: '18px', textAlign: 'center' },
    '.synapse-image-handle-dragging': { cursor: 'grabbing !important' },
    '.synapse-image-resize': { position: 'absolute', bottom: '-5px', width: '10px', height: '10px', borderRadius: '50%', backgroundColor: theme.accent },
    '.synapse-image-resize-left': { left: '-5px', cursor: 'nesw-resize' },
    '.synapse-image-resize-right': { right: '-5px', cursor: 'nwse-resize' },
    '.synapse-image-block-drop-indicator': { position: 'fixed', zIndex: '2147483645', height: '2px', borderRadius: '2px', backgroundColor: theme.accent, boxShadow: `0 0 0 1px ${theme.background}`, pointerEvents: 'none', userSelect: 'none' },
    '.synapse-image-drag-preview.synapse-image-drop-invalid': { borderColor: theme.contextMenu.danger, opacity: '.62' },
    '.synapse-image-drop-target.synapse-image-drop-invalid': { borderColor: theme.contextMenu.danger, backgroundColor: `${theme.contextMenu.danger}12` },
    '.synapse-image-block-drop-indicator.synapse-image-drop-invalid': { backgroundColor: theme.contextMenu.danger },
    '.synapse-bold': { fontWeight: '700' },
    '.synapse-italic': { fontStyle: 'italic' },
    '.synapse-strike': { textDecoration: 'line-through' },
    '.synapse-highlight': { backgroundColor: theme.highlight, borderRadius: '2px' },
    '.synapse-inline-code': { backgroundColor: theme.codeBackground, fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace', borderRadius: '3px', padding: '1px 3px' },
    '.synapse-search-match': { backgroundColor: `${theme.highlight}a8`, borderRadius: '2px' },
    '.synapse-search-current': { outline: `1px solid ${theme.accent}`, backgroundColor: `${theme.accent}2e` },
    '.synapse-link': { color: theme.accent, textDecoration: 'underline', cursor: 'pointer' },
    '.synapse-table-frame': { position: 'relative', overflowX: 'auto', border: `1px solid ${theme.line}`, borderRadius: '7px', margin: '4px 0' },
    '.synapse-table-frame table': { minWidth: '100%', borderCollapse: 'collapse' },
    '.synapse-table-frame th, .synapse-table-frame td': { position: 'relative', borderRight: `1px solid ${theme.line}`, borderBottom: `1px solid ${theme.line}`, padding: '0', textAlign: 'left', verticalAlign: 'top' },
    '.synapse-table-frame th': { backgroundColor: theme.surface, fontWeight: '650' },
    '.synapse-table-cell-editor': { display: 'block', boxSizing: 'border-box', width: '100%', minWidth: '64px', minHeight: '2.55em', padding: '8px 10px', outline: 'none', whiteSpace: 'pre-wrap', overflowWrap: 'anywhere', cursor: 'text' },
    '.synapse-table-cell-editor:focus': { boxShadow: `inset 0 0 0 1px ${theme.accent}` },
    '.synapse-table-row-handle': { width: '22px', minWidth: '22px', padding: '0 !important', cursor: 'grab' },
    '.synapse-table-row-handle::before': { content: '"⋮⋮"', color: theme.muted, fontSize: '10px' },
    '.synapse-table-column-handle': { position: 'absolute', top: '0', left: '0', right: '0', height: '8px', cursor: 'grab', zIndex: '2' },
    '.synapse-table-block-handle': { position: 'absolute', top: '3px', left: '3px', zIndex: '3', width: '18px', height: '18px', borderRadius: '4px', opacity: '0', color: theme.muted, backgroundColor: theme.surface, cursor: 'grab', userSelect: 'none', transition: 'opacity 80ms ease' },
    '.synapse-table-block-handle::before': { content: '"⠿"', display: 'block', fontSize: '13px', lineHeight: '18px', textAlign: 'center' },
    '.synapse-table-frame:hover .synapse-table-block-handle, .synapse-table-frame:focus-within .synapse-table-block-handle': { opacity: '1' },
    '.synapse-table-dragging': { cursor: 'grabbing !important', opacity: '1 !important' },
    '.synapse-table-row-drop-before > *': { boxShadow: `inset 0 2px 0 ${theme.accent}` },
    '.synapse-table-row-drop-after > *': { boxShadow: `inset 0 -2px 0 ${theme.accent}` },
    '.synapse-table-column-drop-before': { boxShadow: `inset 2px 0 0 ${theme.accent}` },
    '.synapse-table-column-drop-after': { boxShadow: `inset -2px 0 0 ${theme.accent}` },
    '.synapse-table-block-drop-indicator': { position: 'fixed', zIndex: '2147483646', height: '2px', backgroundColor: theme.accent, pointerEvents: 'none' },
    '.synapse-table-resize': { position: 'absolute', top: '0', right: '0', bottom: '0', width: '8px', cursor: 'col-resize', backgroundColor: 'transparent' },
    '.synapse-columns': { border: '1px solid transparent', borderRadius: '7px', overflowX: 'auto' },
    '.synapse-columns-editable.synapse-columns-focused': { borderColor: theme.line },
    '.synapse-columns-controls': { display: 'flex', visibility: 'hidden', gap: '4px', alignItems: 'center', padding: '4px 7px', borderBottom: `1px solid ${theme.line}`, backgroundColor: theme.surface },
    '.synapse-columns-controls[hidden]': { display: 'none' },
    '.synapse-columns-editable.synapse-columns-focused .synapse-columns-controls': { visibility: 'visible' },
    '.synapse-columns-controls button': { border: '0', borderRadius: '4px', padding: '3px 6px', color: theme.text, backgroundColor: 'transparent', font: '11px/1.4 inherit' },
    '.synapse-columns-content': { display: 'grid', alignItems: 'stretch' },
    '.synapse-column': { minWidth: '240px', padding: '0 12px', overflow: 'visible' },
    '.synapse-column > .cm-editor': { height: 'auto' },
    '.synapse-columns-divider': { position: 'relative', zIndex: '2', width: '10px', marginLeft: '-5px', pointerEvents: 'none' },
    '.synapse-columns-divider::after': { content: '""', position: 'absolute', top: '0', bottom: '0', left: '50%', width: '1px', transform: 'translateX(-0.5px)', backgroundColor: 'transparent' },
    '.synapse-columns-editable.synapse-columns-focused .synapse-columns-divider': { cursor: 'col-resize', pointerEvents: 'auto' },
    '.synapse-columns-editable.synapse-columns-focused .synapse-columns-divider::after': { backgroundColor: theme.line },
    '.synapse-projected-line': { minHeight: '1.55em', whiteSpace: 'pre-wrap' },
    '.synapse-context-menu': { position: 'fixed', zIndex: '2147483647', minWidth: '204px', maxHeight: 'calc(100vh - 16px)', overflow: 'visible', padding: '6px', borderRadius: '12px', border: `1px solid ${theme.contextMenu.border}`, color: theme.contextMenu.text, backgroundColor: theme.contextMenu.background, backdropFilter: 'blur(24px)', WebkitBackdropFilter: 'blur(24px)', boxShadow: '0 14px 32px rgba(0,0,0,.28)', font: '400 13px/1.15 -apple-system, BlinkMacSystemFont, sans-serif', boxSizing: 'border-box' },
    '.synapse-context-menu button': { display: 'flex', alignItems: 'center', width: '100%', height: '30px', border: '0', borderRadius: '7px', padding: '0 10px 0 6px', gap: '2px', textAlign: 'left', color: theme.contextMenu.text, background: 'transparent', font: 'inherit', whiteSpace: 'nowrap', outline: 'none' },
    '.synapse-context-menu button:hover, .synapse-context-menu button:focus-visible, .synapse-context-menu button[data-active="true"]': { color: theme.contextMenu.text, backgroundColor: theme.accent },
    '.synapse-context-menu button:disabled': { color: theme.contextMenu.disabledText, background: 'transparent' },
    '.synapse-context-menu button[data-destructive="true"]:not(:hover):not(:focus-visible)': { color: theme.contextMenu.danger },
    '.synapse-context-menu button[data-destructive="true"]:hover, .synapse-context-menu button[data-destructive="true"]:focus-visible': { color: theme.contextMenu.text, backgroundColor: theme.contextMenu.danger },
    '.synapse-context-check': { width: '12px', flex: '0 0 12px', textAlign: 'center' },
    '.synapse-context-label': { flex: '1 1 auto', overflow: 'hidden', textOverflow: 'ellipsis' },
    '.synapse-context-shortcut': { flex: '0 0 auto', marginLeft: '14px', color: 'inherit', opacity: '.72' },
    '.synapse-context-chevron': { flex: '0 0 auto', marginLeft: '10px', fontSize: '16px', lineHeight: '1' },
    '.synapse-context-separator': { height: '1px', margin: '4px 8px', backgroundColor: theme.contextMenu.divider },
    '.synapse-context-submenu-group': { position: 'relative' },
    '.synapse-context-submenu': { position: 'absolute', left: 'calc(100% + 6px)', top: '-6px', minWidth: '170px', padding: '6px', borderRadius: '12px', border: `1px solid ${theme.contextMenu.border}`, backgroundColor: theme.contextMenu.background, backdropFilter: 'blur(24px)', WebkitBackdropFilter: 'blur(24px)', boxShadow: '0 14px 32px rgba(0,0,0,.28)', boxSizing: 'border-box' },
    '.synapse-context-submenu[hidden]': { display: 'none' },
  });
}

function updateListener(update: ViewUpdate): void {
  if (!runtime) return;
  if (update.docChanged && activeImageDragSession) cancelActiveImageDrag();
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
    const selection = selectionOf(update.state);
    rememberTextSelection(selection);
    post({ type: 'selectionChanged', revision: runtime.revision, selection });
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
  flushPendingTableEdits();
  if (!runtime || !view || !pendingChanges) return;
  const changes: EditorChange[] = [];
  pendingChanges.iterChanges((fromA, toA, _fromB, _toB, inserted) => {
    changes.push({ from: fromA, to: toA, insert: inserted.toString() });
  });
  pendingChanges = undefined;
  pendingColumnFocus = undefined;
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

function imageKeyBindings(baseOffsetValue: number | (() => number) = 0) {
  const baseOffset = () => typeof baseOffsetValue === 'function'
    ? baseOffsetValue()
    : baseOffsetValue;
  const selected = (editorView: EditorView) =>
    selectedImageRange(editorView.state, baseOffset());
  const remove = (editorView: EditorView) => {
    const image = selected(editorView);
    if (!image || !runtime?.editable) return false;
    const offset = baseOffset();
    const from = image.from - offset;
    const to = image.to - offset;
    editorView.dispatch({
      changes: { from, to, insert: '' },
      selection: { anchor: from },
      annotations: Transaction.userEvent.of('delete.image'),
    });
    return true;
  };
  return [
    {
      key: 'Enter',
      preventDefault: true,
      run: (editorView: EditorView) => {
        const image = selected(editorView);
        if (!image || !runtime?.editable) return false;
        const localTo = image.to - baseOffset();
        const doc = editorView.state.doc.toString();
        let insert = '\n\n';
        let anchor = localTo + insert.length;
        if (image.block.kind === 'image') {
          if (doc[localTo] === '\n') {
            insert = '';
            anchor = localTo + 1;
          } else {
            insert = '\n';
            anchor = localTo + 1;
          }
        }
        editorView.dispatch({
          changes: insert.length > 0
            ? { from: localTo, to: localTo, insert }
            : undefined,
          selection: { anchor },
          annotations: Transaction.userEvent.of('input.image-enter'),
        });
        return true;
      },
    },
    { key: 'Backspace', preventDefault: true, run: remove },
    { key: 'Delete', preventDefault: true, run: remove },
    {
      key: 'Mod-c',
      run: (editorView: EditorView) => {
        const image = selected(editorView);
        if (!image || !runtime) return false;
        flushPendingTransaction();
        post({
          type: 'imageAction',
          action: 'copy',
          src: image.src,
          revision: runtime.revision,
          from: image.from,
          to: image.to,
        });
        return true;
      },
    },
    {
      key: 'Mod-x',
      run: (editorView: EditorView) => {
        const image = selected(editorView);
        if (!image || !runtime?.editable) return false;
        flushPendingTransaction();
        post({
          type: 'imageAction',
          action: 'cut',
          src: image.src,
          revision: runtime.revision,
          from: image.from,
          to: image.to,
        });
        return true;
      },
    },
    {
      key: 'Escape',
      run: (editorView: EditorView) => {
        const image = selected(editorView);
        if (!image) return false;
        editorView.dispatch({
          selection: { anchor: image.to - baseOffset() },
        });
        return true;
      },
    },
  ];
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
          if (view) requestFind(false, selectionOf(view.state));
          return true;
        },
      },
      {
        key: 'Alt-Mod-f',
        preventDefault: true,
        run: () => {
          if (view) requestFind(true, selectionOf(view.state));
          return true;
        },
      },
      {
        key: 'Ctrl-h',
        preventDefault: true,
        run: () => {
          if (view) requestFind(true, selectionOf(view.state));
          return true;
        },
      },
      { key: 'Mod-b', preventDefault: true, run: () => requestCommand('format', 'bold') },
      { key: 'Mod-i', preventDefault: true, run: () => requestCommand('format', 'italic') },
      ...imageKeyBindings(),
      {
        key: 'Shift-F10',
        preventDefault: true,
        run: (editorView) => {
          const head = editorView.state.selection.main.head;
          const coordinates = editorView.coordsAtPos(head);
          showContextMenu(
            coordinates?.left ?? 20,
            coordinates?.bottom ?? 20,
            documentContextTarget(editorView, head),
          );
          return true;
        },
      },
      {
        key: 'ContextMenu',
        preventDefault: true,
        run: (editorView) => {
          const head = editorView.state.selection.main.head;
          const coordinates = editorView.coordsAtPos(head);
          showContextMenu(
            coordinates?.left ?? 20,
            coordinates?.bottom ?? 20,
            documentContextTarget(editorView, head),
          );
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
    ViewPlugin.fromClass(class {
      update(update: ViewUpdate) {
        if (
          update.docChanged ||
          update.viewportChanged ||
          update.geometryChanged
        ) schedulePageLayout();
      }
    }),
    EditorView.domEventHandlers({
      beforeinput() {
        inputStartedAt = performance.now();
        return false;
      },
      pointerdown(event, editorView) {
        pointerStartedAt = performance.now();
        if (event.button === 2) {
          const position = editorView.posAtCoords({
            x: event.clientX,
            y: event.clientY,
          });
          const selection = editorView.state.selection.main;
          if (
            position != null &&
            !selection.empty &&
            position >= selection.from &&
            position <= selection.to
          ) {
            event.preventDefault();
            return true;
          }
        }
        if (!runtime?.focused || !runtime.editable) {
          if (
            event.target instanceof Element &&
            event.target.closest('.synapse-columns')
          ) {
            return false;
          }
          const position = editorView.posAtCoords({
            x: event.clientX,
            y: event.clientY,
          }) ?? editorView.state.selection.main.head;
          editorView.dispatch({ selection: { anchor: position } });
          post({ type: 'focusChanged', focused: true });
          event.preventDefault();
          return true;
        }
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
        showContextMenu(
          event.clientX,
          event.clientY,
          documentContextTarget(editorView, position),
        );
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
  cancelActiveImageDrag();
  clearPageLayout();
  pageLayoutBoundaries = [];
  pageLayoutStale = false;
  view?.destroy();
  clearAttachmentState();
  clearClipboardRequests();
  pendingChanges = undefined;
  pendingColumnFocus = undefined;
  pendingTableFocus = undefined;
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
  if (pointerInteractionHost !== parent) {
    pointerInteractionHost?.removeEventListener(
      'pointerdown',
      handleSurfacePointerInteraction,
      true,
    );
    parent.addEventListener('pointerdown', handleSurfacePointerInteraction, true);
    pointerInteractionHost = parent;
  }
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
  rememberTextSelection(command.selection);
  post({ type: 'ready', revision: runtime.revision });
  scheduleOutline();
  scheduleCommandState();
}

function applyChanges(command: Extract<HostCommand, { type: 'applyChanges' }>): void {
  if (!view || !runtime || command.generation !== runtime.generation) return;
  cancelActiveImageDrag();
  flushPendingTransaction();
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
  cancelActiveImageDrag();
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
        if (!command.editable || !command.focused || command.mode !== 'editing') {
          cancelActiveImageDrag();
        }
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
        if (command.focused && command.editable) {
          const activeInsideColumns =
            document.activeElement instanceof Element &&
            document.activeElement.closest('.synapse-columns') != null;
          if (
            !focusPendingTable() &&
            !focusPendingColumn() &&
            !activeInsideColumns
          ) view.focus();
        } else {
          pendingColumnFocus = undefined;
          pendingTableFocus = undefined;
        }
        break;
      case 'setTheme':
        if (!view || !runtime) break;
        runtime.theme = command.theme;
        view.dispatch({ effects: themeCompartment.reconfigure(editorTheme(command.theme)) });
        syncVisibleColumns();
        break;
      case 'setPageLayout':
        pageLayoutBoundaries = command.boundaries
          .filter((boundary) =>
            Number.isInteger(boundary.pageIndex) &&
            Number.isInteger(boundary.sourceOffset) &&
            boundary.pageIndex > 0 &&
            boundary.sourceOffset >= 0)
          .map((boundary) => ({
            pageIndex: boundary.pageIndex,
            sourceOffset: boundary.sourceOffset,
          }));
        pageLayoutStale = command.stale;
        schedulePageLayout();
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
      case 'dismissContextMenu': contextMenuDismiss?.(); break;
      case 'flush':
        flushPendingTransaction();
        if (runtime) post({ type: 'flushAck', requestId: command.requestId, revision: runtime.revision, clientSeq: runtime.clientSeq });
        break;
      case 'attachmentChunk': receiveAttachmentChunk(command); break;
      case 'attachmentError': receiveAttachmentError(command.requestId); break;
      case 'clipboardResult': receiveClipboardResult(command); break;
      case 'dispose':
        cancelActiveImageDrag();
        flushPendingTransaction();
        clearPageLayout();
        view?.destroy();
        clearAttachmentState();
        clearClipboardRequests();
        pendingColumnFocus = undefined;
        pendingTableFocus = undefined;
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
  selection: EditorSelection = view ? selectionOf(view.state) : { anchor: 0, head: 0 },
): boolean {
  if (!view || !runtime?.editable) return false;
  flushPendingTransaction();
  post({
    type: 'commandRequest',
    group,
    command,
    revision: runtime.revision,
    selection,
  });
  return true;
}

type ClipboardResultCommand = Extract<HostCommand, { type: 'clipboardResult' }>;

interface DocumentContextTarget {
  kind: 'document';
  editorView: EditorView;
  baseOffset: number;
  selection: EditorSelection;
}

interface ImageContextTarget {
  kind: 'image';
  from: number;
  to: number;
  src: string;
  pasteSelection?: EditorSelection;
}

interface TableCellContextTarget {
  kind: 'tableCell';
  state: TableDomState;
  row: number;
  column: number;
  editor: HTMLElement;
  selection: CellSelectionSnapshot;
}

type ContextMenuTarget =
  | DocumentContextTarget
  | ImageContextTarget
  | TableCellContextTarget;

interface DocumentMenuState {
  hasSelection: boolean;
  canFormat: boolean;
  canUseStructure: boolean;
  insideColumns: boolean;
  inlineFormats: Set<'highlight' | 'bold' | 'italic' | 'strikethrough'>;
  paragraph: 'heading1' | 'heading2' | 'heading3' | 'heading4' | 'body' | 'blockquote';
  list?: 'unordered' | 'ordered' | 'task';
}

interface MenuActionOptions {
  enabled?: boolean;
  checked?: boolean;
  shortcut?: string;
  destructive?: boolean;
}

let rememberedTextSelection: EditorSelection | undefined;
let clipboardRequestCounter = 0;
const clipboardRequests = new Map<
  number,
  {
    resolve: (result: ClipboardResultCommand) => void;
    timeout: number;
    revision: number;
    generation: number;
  }
>();

function requestClipboard(
  action: 'availability' | 'copy' | 'cut' | 'paste' | 'pastePlain',
  target: 'document' | 'tableCell',
  options: { selection?: EditorSelection; text?: string } = {},
): Promise<ClipboardResultCommand> {
  if (!runtime) {
    return Promise.resolve({
      protocolVersion,
      type: 'clipboardResult',
      requestId: -1,
      revision: -1,
      generation: -1,
      outcome: 'stale',
      hasText: false,
      hasImage: false,
    });
  }
  const requestId = ++clipboardRequestCounter;
  const revision = runtime.revision;
  const generation = runtime.generation;
  return new Promise((resolve) => {
    const timeout = window.setTimeout(() => {
      clipboardRequests.delete(requestId);
      resolve({
        protocolVersion,
        type: 'clipboardResult',
        requestId,
        revision,
        generation,
        outcome: 'failure',
        hasText: false,
        hasImage: false,
      });
    }, 5000);
    clipboardRequests.set(requestId, {
      resolve,
      timeout,
      revision,
      generation,
    });
    post({
      type: 'clipboardRequest',
      requestId,
      action,
      target,
      revision,
      selection: options.selection,
      text: options.text,
    });
  });
}

function receiveClipboardResult(command: ClipboardResultCommand): void {
  const pending = clipboardRequests.get(command.requestId);
  if (!pending) return;
  clipboardRequests.delete(command.requestId);
  window.clearTimeout(pending.timeout);
  if (
    runtime == null ||
    command.revision !== pending.revision ||
    command.generation !== pending.generation ||
    runtime.revision !== pending.revision ||
    runtime.generation !== pending.generation
  ) {
    pending.resolve({
      ...command,
      outcome: 'stale',
      hasText: false,
      hasImage: false,
      text: undefined,
    });
    return;
  }
  pending.resolve(command);
}

function clearClipboardRequests(): void {
  for (const [requestId, pending] of clipboardRequests) {
    window.clearTimeout(pending.timeout);
    pending.resolve({
      protocolVersion,
      type: 'clipboardResult',
      requestId,
      revision: pending.revision,
      generation: pending.generation,
      outcome: 'stale',
      hasText: false,
      hasImage: false,
    });
  }
  clipboardRequests.clear();
}

function orderedSelection(selection: EditorSelection): { from: number; to: number } {
  return selection.anchor <= selection.head
    ? { from: selection.anchor, to: selection.head }
    : { from: selection.head, to: selection.anchor };
}

function documentContextTarget(
  editorView: EditorView,
  localPosition: number,
  baseOffset = 0,
): DocumentContextTarget {
  const current = editorView.state.selection.main;
  const preserve = !current.empty &&
    localPosition >= current.from &&
    localPosition <= current.to;
  if (!preserve) {
    editorView.dispatch({ selection: { anchor: localPosition } });
  }
  const selection = preserve ? current : editorView.state.selection.main;
  const target = {
    kind: 'document' as const,
    editorView,
    baseOffset,
    selection: {
      anchor: baseOffset + selection.anchor,
      head: baseOffset + selection.head,
    },
  };
  rememberTextSelection(target.selection);
  return target;
}

function rememberTextSelection(selection: EditorSelection): void {
  if (!view) return;
  const blocks = splitMarkdownBlocks(view.state.doc.toString());
  const block = activeBlockForSelection(blocks, selection);
  if (
    block == null ||
    block.kind === 'table' ||
    block.kind === 'image' ||
    block.kind === 'pageBreak' ||
    block.kind === 'columnsStart' ||
    block.kind === 'columnsSeparator' ||
    block.kind === 'columnsEnd'
  ) return;
  rememberedTextSelection = { ...selection };
}

function lineBounds(markdown: string, offset: number): { from: number; to: number; text: string } {
  const resolved = Math.max(0, Math.min(offset, markdown.length));
  const from = markdown.lastIndexOf('\n', Math.max(0, resolved - 1)) + 1;
  const newline = markdown.indexOf('\n', resolved);
  const to = newline < 0 ? markdown.length : newline;
  return { from, to, text: markdown.slice(from, to) };
}

function selectionInsideColumns(markdown: string, offset: number): boolean {
  let inside = false;
  for (const block of splitMarkdownBlocks(markdown)) {
    if (block.from > offset) break;
    if (block.kind === 'columnsStart') inside = true;
    if (block.kind === 'columnsEnd') inside = false;
  }
  return inside;
}

function selectionIntersectsProtectedStructure(
  markdown: string,
  selection: EditorSelection,
): boolean {
  const range = orderedSelection(selection);
  return splitMarkdownBlocks(markdown).some((block) => {
    const protectedBlock =
      block.kind === 'code' ||
      block.kind === 'table' ||
      block.kind === 'pageBreak' ||
      block.kind === 'columnsStart' ||
      block.kind === 'columnsSeparator' ||
      block.kind === 'columnsEnd';
    if (!protectedBlock) return false;
    if (range.from === range.to) {
      return range.from >= block.from && range.from < block.to;
    }
    return range.from < block.to && range.to > block.from;
  });
}

function selectionHasDelimiter(
  markdown: string,
  selection: EditorSelection,
  open: string,
  close = open,
): boolean {
  const range = orderedSelection(selection);
  if (range.from !== range.to) {
    return markdown.slice(Math.max(0, range.from - open.length), range.from) === open &&
      markdown.slice(range.to, range.to + close.length) === close;
  }
  const line = lineBounds(markdown, range.from);
  const local = range.from - line.from;
  const before = line.text.slice(0, local);
  const after = line.text.slice(local);
  const opening = before.lastIndexOf(open);
  return opening >= 0 && after.indexOf(close) >= 0;
}

function selectionHasSingleDelimiter(
  markdown: string,
  selection: EditorSelection,
  marker: '*' | '_',
): boolean {
  const range = orderedSelection(selection);
  if (range.from !== range.to) {
    return markdown.slice(range.from - 1, range.from) === marker &&
      markdown.slice(range.from - 2, range.from - 1) !== marker &&
      markdown.slice(range.to, range.to + 1) === marker &&
      markdown.slice(range.to + 1, range.to + 2) !== marker;
  }
  const line = lineBounds(markdown, range.from);
  const local = range.from - line.from;
  const before = line.text.slice(0, local);
  const after = line.text.slice(local);
  for (let index = before.length - 1; index >= 0; index -= 1) {
    if (before[index] !== marker) continue;
    if (before[index - 1] === marker || before[index + 1] === marker) continue;
    const closing = after.indexOf(marker);
    if (closing >= 0 && after[closing - 1] !== marker && after[closing + 1] !== marker) {
      return true;
    }
  }
  return false;
}

function documentMenuState(target: DocumentContextTarget): DocumentMenuState {
  const markdown = view?.state.doc.toString() ?? '';
  const range = orderedSelection(target.selection);
  const hasSelection = range.from !== range.to;
  const protectedSelection = selectionIntersectsProtectedStructure(
    markdown,
    target.selection,
  );
  const line = lineBounds(markdown, target.selection.head);
  const trimmed = line.text.trimStart();
  const heading = /^(#{1,4})\s+/.exec(trimmed);
  const paragraph = heading
    ? (`heading${heading[1].length}` as DocumentMenuState['paragraph'])
    : /^>\s?/.test(trimmed)
      ? 'blockquote'
      : 'body';
  const list = /^\s*[-*+]\s+\[[ xX]\]\s+/.test(line.text)
    ? 'task'
    : /^\s*[-*+]\s+/.test(line.text)
      ? 'unordered'
      : /^\s*\d+[.)]\s+/.test(line.text)
        ? 'ordered'
        : undefined;
  const inlineFormats = new Set<DocumentMenuState['inlineFormats'] extends Set<infer T> ? T : never>();
  if (selectionHasDelimiter(markdown, target.selection, '==')) inlineFormats.add('highlight');
  if (
    selectionHasDelimiter(markdown, target.selection, '**') ||
    selectionHasDelimiter(markdown, target.selection, '__')
  ) inlineFormats.add('bold');
  if (
    selectionHasSingleDelimiter(markdown, target.selection, '*') ||
    selectionHasSingleDelimiter(markdown, target.selection, '_')
  ) inlineFormats.add('italic');
  if (selectionHasDelimiter(markdown, target.selection, '~~')) inlineFormats.add('strikethrough');
  return {
    hasSelection,
    canFormat: Boolean(runtime?.editable) && hasSelection && !protectedSelection,
    canUseStructure: Boolean(runtime?.editable) && !protectedSelection,
    insideColumns: selectionInsideColumns(markdown, target.selection.head),
    inlineFormats,
    paragraph,
    list,
  };
}

function requestFind(replace: boolean, selection?: EditorSelection): void {
  if (!view || !runtime) return;
  const range = selection == null ? undefined : orderedSelection(selection);
  const selectionText = range == null || range.from === range.to
    ? undefined
    : view.state.doc.sliceString(range.from, range.to);
  post({
    type: 'findRequest',
    replace,
    selectionText,
    anchorOffset: selection?.head,
  });
}

let contextMenu: HTMLElement | undefined;
let contextMenuDismiss: (() => void) | undefined;

function showContextMenu(
  x: number,
  y: number,
  target: ContextMenuTarget,
): void {
  post({ type: 'pointerInteraction' });
  contextMenuDismiss?.();
  if (!runtime) return;
  const menu = document.createElement('div');
  menu.className = 'synapse-context-menu';
  menu.setAttribute('role', 'menu');
  if (target.kind === 'tableCell') target.state.contextMenuOpen = true;
  const buttons: HTMLButtonElement[] = [];
  let outsideClose: ((event: Event) => void) | undefined;
  const restoreTargetFocus = () => {
    if (target.kind === 'tableCell') {
      if (target.editor.isConnected) {
        restoreCellSelection(target.editor, target.selection, true);
      }
      return;
    }
    const editorView = target.kind === 'document' ? target.editorView : view;
    editorView?.contentDOM.focus({ preventScroll: true });
  };
  const dismiss = (restoreFocus = false) => {
    menu.remove();
    if (outsideClose) window.removeEventListener('pointerdown', outsideClose, true);
    if (contextMenu === menu) {
      contextMenu = undefined;
      contextMenuDismiss = undefined;
    }
    if (target.kind === 'tableCell') {
      target.state.contextMenuOpen = false;
      if (target.state.frame.isConnected) commitTableModel(target.state);
    }
    if (restoreFocus) restoreTargetFocus();
  };
  const action = (
    label: string,
    invoke: () => unknown | Promise<unknown>,
    options: MenuActionOptions = {},
    parent: HTMLElement = menu,
    collection: HTMLButtonElement[] = buttons,
  ) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.disabled = options.enabled === false;
    button.tabIndex = -1;
    button.setAttribute('role', 'menuitem');
    button.setAttribute('aria-checked', String(options.checked === true));
    if (options.destructive) button.dataset.destructive = 'true';
    const check = document.createElement('span');
    check.className = 'synapse-context-check';
    check.textContent = options.checked ? '✓' : '';
    const text = document.createElement('span');
    text.className = 'synapse-context-label';
    text.textContent = label;
    button.append(check, text);
    if (options.shortcut) {
      const shortcut = document.createElement('span');
      shortcut.className = 'synapse-context-shortcut';
      shortcut.textContent = options.shortcut;
      button.append(shortcut);
    }
    button.addEventListener('pointerdown', (event) => event.preventDefault());
    button.addEventListener('click', () => {
      try {
        const pending = invoke();
        if (pending instanceof Promise) {
          void pending.catch((error) => {
            const resolved = error instanceof Error ? error : new Error(String(error));
            post({ type: 'error', message: resolved.message, stack: resolved.stack });
          });
        }
      } finally {
        dismiss(true);
      }
    });
    collection.push(button);
    parent.append(button);
    return button;
  };
  const separator = (parent: HTMLElement = menu) => {
    const element = document.createElement('div');
    element.className = 'synapse-context-separator';
    element.setAttribute('role', 'separator');
    parent.append(element);
  };
  const setEnabled = (button: HTMLButtonElement, enabled: boolean) => {
    button.disabled = !enabled;
  };
  const submenu = (
    label: string,
    enabled: boolean,
    build: (
      add: (
        label: string,
        invoke: () => unknown | Promise<unknown>,
        options?: MenuActionOptions,
      ) => HTMLButtonElement,
    ) => void,
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
    trigger.disabled = !enabled;
    trigger.tabIndex = -1;
    trigger.setAttribute('role', 'menuitem');
    trigger.setAttribute('aria-haspopup', 'menu');
    trigger.setAttribute('aria-expanded', 'false');
    const check = document.createElement('span');
    check.className = 'synapse-context-check';
    const text = document.createElement('span');
    text.className = 'synapse-context-label';
    text.textContent = label;
    const chevron = document.createElement('span');
    chevron.className = 'synapse-context-chevron';
    chevron.textContent = '›';
    trigger.append(check, text, chevron);
    buttons.push(trigger);
    let closeTimer = 0;
    const positionPanel = () => {
      panel.style.left = 'calc(100% + 6px)';
      panel.style.right = 'auto';
      panel.style.top = '-6px';
      const bounds = panel.getBoundingClientRect();
      if (bounds.right > window.innerWidth - 8) {
        panel.style.left = 'auto';
        panel.style.right = 'calc(100% + 6px)';
      }
      const adjusted = panel.getBoundingClientRect();
      if (adjusted.bottom > window.innerHeight - 8) {
        const groupBounds = group.getBoundingClientRect();
        panel.style.top = `${window.innerHeight - 8 - adjusted.height - groupBounds.top}px`;
      }
    };
    const open = () => {
      if (!enabled) return;
      window.clearTimeout(closeTimer);
      for (const other of menu.querySelectorAll<HTMLElement>('.synapse-context-submenu')) other.hidden = true;
      for (const other of menu.querySelectorAll<HTMLElement>('[aria-haspopup="menu"]')) {
        other.setAttribute('aria-expanded', 'false');
        if (other instanceof HTMLButtonElement) other.dataset.active = 'false';
      }
      panel.hidden = false;
      trigger.setAttribute('aria-expanded', 'true');
      trigger.dataset.active = 'true';
      positionPanel();
    };
    const close = () => {
      panel.hidden = true;
      trigger.setAttribute('aria-expanded', 'false');
      trigger.dataset.active = 'false';
    };
    const scheduleClose = () => {
      window.clearTimeout(closeTimer);
      closeTimer = window.setTimeout(close, 200);
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
    trigger.addEventListener('mouseleave', scheduleClose);
    trigger.addEventListener('keydown', (event) => {
      if (event.key !== 'ArrowRight' && event.key !== 'Enter' && event.key !== ' ') return;
      event.preventDefault();
      open();
      items.find((item) => !item.disabled)?.focus();
    });
    panel.addEventListener('mouseenter', () => window.clearTimeout(closeTimer));
    panel.addEventListener('mouseleave', scheduleClose);
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
    build((itemLabel, invoke, options = {}) => action(itemLabel, invoke, options, panel, items));
    group.append(trigger, panel);
    menu.append(group);
  };
  const clipboardButtons: HTMLButtonElement[] = [];
  const history = () => {
    action('撤销', () => { if (view) undo(view); }, {
      enabled: runtime!.editable && Boolean(view && undoDepth(view.state) > 0),
      shortcut: '⌘Z',
    });
    action('重做', () => { if (view) redo(view); }, {
      enabled: runtime!.editable && Boolean(view && redoDepth(view.state) > 0),
      shortcut: '⇧⌘Z',
    });
    separator();
  };
  if (target.kind === 'image') {
    history();
    action('复制图片', () => {
      flushPendingTransaction();
      post({
        type: 'imageAction',
        action: 'copy',
        src: target.src,
        revision: runtime!.revision,
        from: target.from,
        to: target.to,
      });
    });
    action('剪切图片', () => {
      flushPendingTransaction();
      post({
        type: 'imageAction',
        action: 'cut',
        src: target.src,
        revision: runtime!.revision,
        from: target.from,
        to: target.to,
      });
    }, { enabled: runtime.editable });
    const paste = action('粘贴', async () => {
      if (!target.pasteSelection) return;
      await requestClipboard('paste', 'document', { selection: target.pasteSelection });
    }, { enabled: false });
    clipboardButtons.push(paste);
    separator();
    const imageSelection = { anchor: target.from, head: target.from };
    action('查找…', () => requestFind(false, imageSelection), { shortcut: '⌘F' });
    action('替换…', () => requestFind(true, imageSelection), {
      enabled: runtime.editable,
      shortcut: '⌥⌘F',
    });
  } else if (target.kind === 'tableCell') {
    history();
    const cellText = target.editor.textContent ?? '';
    const cellFrom = Math.min(target.selection.anchor, target.selection.head);
    const cellTo = Math.max(target.selection.anchor, target.selection.head);
    const selectedText = cellText.slice(cellFrom, cellTo);
    action('复制', async () => {
      await requestClipboard('copy', 'tableCell', { text: selectedText });
    }, { enabled: selectedText.length > 0 });
    action('剪切', async () => {
      const result = await requestClipboard('cut', 'tableCell', { text: selectedText });
      if (result.outcome === 'success') {
        replaceTableCellContextSelection(target, '');
      }
    }, { enabled: runtime.editable && target.state.widget.editable && selectedText.length > 0 });
    const paste = action('粘贴', async () => {
      const result = await requestClipboard('paste', 'tableCell');
      if (result.outcome === 'success' && result.text != null) {
        replaceTableCellContextSelection(target, result.text);
      }
    }, { enabled: false });
    clipboardButtons.push(paste);
    action('全选', () => {
      target.selection = { anchor: 0, head: cellText.length };
      restoreCellSelection(target.editor, target.selection, true);
    }, { enabled: cellText.length > 0, shortcut: '⌘A' });
    separator();
    action(selectedText.length > 0 ? '查找所选内容' : '查找…', () => {
      post({
        type: 'findRequest',
        replace: false,
        selectionText: selectedText || undefined,
        anchorOffset: target.state.widget.block.from,
      });
    }, { shortcut: '⌘F' });
    action('替换…', () => {
      post({
        type: 'findRequest',
        replace: true,
        selectionText: selectedText || undefined,
        anchorOffset: target.state.widget.block.from,
      });
    }, { enabled: runtime.editable, shortcut: '⌥⌘F' });
    separator();
    const tableEditable = runtime.editable && target.state.widget.editable;
    submenu('行', tableEditable, (add) => {
      add('上方插入行', () => insertTableRow(target.state, false), {
        enabled: tableEditable && target.state.selectedRow > 0,
      });
      add('下方插入行', () => insertTableRow(target.state, true), {
        enabled: tableEditable,
      });
      add('末尾新增行', () => appendTableRow(target.state), {
        enabled: tableEditable,
      });
      add('删除行', () => deleteTableRow(target.state), {
        enabled: tableEditable && target.state.selectedRow > 0,
        destructive: true,
      });
    });
    submenu('列', tableEditable, (add) => {
      add('左侧插入列', () => insertTableColumn(target.state, false), {
        enabled: tableEditable,
      });
      add('右侧插入列', () => insertTableColumn(target.state, true), {
        enabled: tableEditable,
      });
      add('末尾新增列', () => appendTableColumn(target.state), {
        enabled: tableEditable,
      });
      add('删除列', () => deleteTableColumn(target.state), {
        enabled: tableEditable && target.state.model.header.length > 1,
        destructive: true,
      });
    });
    separator();
    action('删除表格', () => deleteTableBlock(target.state), {
      enabled: tableEditable,
      destructive: true,
    });
  } else {
    history();
    const state = documentMenuState(target);
    const range = orderedSelection(target.selection);
    action('复制', async () => {
      await requestClipboard('copy', 'document', { selection: target.selection });
    }, { enabled: state.hasSelection });
    action('剪切', async () => {
      await requestClipboard('cut', 'document', { selection: target.selection });
    }, { enabled: runtime.editable && state.hasSelection });
    const paste = action('粘贴', async () => {
      await requestClipboard('paste', 'document', { selection: target.selection });
    }, { enabled: false });
    const pastePlain = action('以纯文本粘贴', async () => {
      await requestClipboard('pastePlain', 'document', { selection: target.selection });
    }, { enabled: false, shortcut: '⇧⌘V' });
    clipboardButtons.push(paste, pastePlain);
    action('全选', () => {
      target.editorView.dispatch({
        selection: { anchor: 0, head: target.editorView.state.doc.length },
      });
    }, { shortcut: '⌘A' });
    separator();
    action(state.hasSelection ? '查找所选内容' : '查找…', () => {
      requestFind(false, target.selection);
    }, { shortcut: '⌘F' });
    action('替换…', () => requestFind(true, target.selection), {
      enabled: runtime.editable,
      shortcut: '⌥⌘F',
    });
    separator();
    submenu('插入', state.canUseStructure, (add) => {
      add('表格', () => requestCommand('insert', 'table', target.selection), {
        enabled: state.canUseStructure,
      });
      add('双栏', () => requestCommand('insert', 'columns', target.selection), {
        enabled: state.canUseStructure && !state.insideColumns,
      });
      add('分隔线', () => requestCommand('insert', 'divider', target.selection), {
        enabled: state.canUseStructure,
      });
      add('分页符', () => requestCommand('insert', 'pageBreak', target.selection), {
        enabled: state.canUseStructure && !state.insideColumns,
      });
    });
    submenu('格式', state.canFormat, (add) => {
      add('高亮', () => requestCommand('format', 'highlight', target.selection), {
        enabled: state.canFormat,
        checked: state.inlineFormats.has('highlight'),
      });
      add('加粗', () => requestCommand('format', 'bold', target.selection), {
        enabled: state.canFormat,
        checked: state.inlineFormats.has('bold'),
        shortcut: '⌘B',
      });
      add('斜体', () => requestCommand('format', 'italic', target.selection), {
        enabled: state.canFormat,
        checked: state.inlineFormats.has('italic'),
        shortcut: '⌘I',
      });
      add('删除线', () => requestCommand('format', 'strikethrough', target.selection), {
        enabled: state.canFormat,
        checked: state.inlineFormats.has('strikethrough'),
      });
    });
    submenu('段落', state.canUseStructure, (add) => {
      for (const [label, command] of [
        ['标题 1', 'heading1'],
        ['标题 2', 'heading2'],
        ['标题 3', 'heading3'],
        ['标题 4', 'heading4'],
        ['正文', 'body'],
        ['引用块', 'blockquote'],
      ] as const) {
        add(label, () => requestCommand('paragraph', command, target.selection), {
          enabled: state.canUseStructure,
          checked: state.paragraph === command,
        });
      }
    });
    submenu('列表', state.canUseStructure, (add) => {
      for (const [label, command] of [
        ['无序列表', 'unordered'],
        ['有序列表', 'ordered'],
        ['任务列表', 'task'],
      ] as const) {
        add(label, () => requestCommand('list', command, target.selection), {
          enabled: state.canUseStructure,
          checked: state.list === command,
        });
      }
    });
  }
  (view?.dom ?? document.body).append(menu);
  menu.style.left = `${Math.max(8, Math.min(x, window.innerWidth - menu.offsetWidth - 8))}px`;
  menu.style.top = `${Math.max(8, Math.min(y, window.innerHeight - menu.offsetHeight - 8))}px`;
  contextMenu = menu;
  contextMenuDismiss = dismiss;
  if (clipboardButtons.length > 0 && runtime.editable) {
    void requestClipboard('availability', target.kind === 'tableCell' ? 'tableCell' : 'document')
      .then((availability) => {
        const enabled = target.kind === 'tableCell'
          ? availability.hasText
          : availability.hasText || availability.hasImage;
        clipboardButtons.forEach((button, index) => {
          setEnabled(button, index === 1 ? availability.hasText : enabled);
        });
      });
  }
  const enabledButtons = () => buttons.filter((button) => !button.disabled);
  menu.addEventListener('keydown', (event) => {
    const items = enabledButtons();
    if (items.length === 0) return;
    const current = items.indexOf(document.activeElement as HTMLButtonElement);
    if (event.key === 'Escape') {
      event.preventDefault();
      dismiss(true);
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
    dismiss(false);
  };
  window.addEventListener('pointerdown', outsideClose, true);
}

function replaceTableCellContextSelection(
  target: TableCellContextTarget,
  replacement: string,
): void {
  if (!target.editor.isConnected || !target.state.widget.editable) return;
  const current = target.editor.textContent ?? '';
  const from = Math.min(target.selection.anchor, target.selection.head);
  const to = Math.max(target.selection.anchor, target.selection.head);
  const inserted = replacement.replace(/\r?\n/g, ' ');
  const updated = `${current.slice(0, from)}${inserted}${current.slice(to)}`;
  target.editor.textContent = updated;
  const caret = from + inserted.length;
  target.selection = { anchor: caret, head: caret };
  target.state.model = withTableCellValue(
    target.state.model,
    target.row,
    target.column,
    editorTableCellValue(target.editor),
  );
  commitTableModel(target.state);
  restoreCellSelection(target.editor, target.selection, true);
}

function appendTableRow(state: TableDomState): void {
  state.selectedRow = state.model.rows.length;
  insertTableRow(state, true);
}

function appendTableColumn(state: TableDomState): void {
  state.selectedColumn = state.model.header.length - 1;
  insertTableColumn(state, true);
}

function deleteTableBlock(state: TableDomState): void {
  if (!view || !state.widget.editable) return;
  if (state.pendingFrame) commitTableModel(state);
  const from = state.widget.block.from;
  view.dispatch({
    changes: { from, to: state.widget.block.to, insert: '' },
    selection: { anchor: from },
    annotations: Transaction.userEvent.of('delete.table'),
  });
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
  getRevision: () => runtime?.revision ?? -1,
  getPageLayout: () => ({
    boundaries: pageLayoutBoundaries.map((boundary) => ({ ...boundary })),
    stale: pageLayoutStale,
    framePending: pageLayoutFrame !== 0,
    hostConnected: pageLayoutHost?.isConnected ?? false,
    hostChildren: pageLayoutHost?.childElementCount ?? 0,
  }),
  getPendingClipboardCount: () => clipboardRequests.size,
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
  redo: () => view ? redo(view) : false,
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
  focusColumn: (side: 'left' | 'right') => {
    const root = document.querySelector<HTMLElement>('.synapse-columns');
    const state = root ? columnsDomStates.get(root) : undefined;
    state?.[side].editorView.focus();
  },
  columnHasFocus: (side: 'left' | 'right') => {
    const root = document.querySelector<HTMLElement>('.synapse-columns');
    const state = root ? columnsDomStates.get(root) : undefined;
    return state?.[side].editorView.hasFocus ?? false;
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
      { from, to, block: true },
      state[side].baseOffset + offset,
    );
  },
};
window.addEventListener('error', (event) => post({ type: 'error', message: event.message, stack: event.error?.stack }));
window.addEventListener('unhandledrejection', (event) => {
  const error = event.reason instanceof Error ? event.reason : new Error(String(event.reason));
  post({ type: 'error', message: error.message, stack: error.stack });
});
