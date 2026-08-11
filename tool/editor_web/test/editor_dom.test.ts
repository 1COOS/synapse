// @vitest-environment jsdom

import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

import type { InitializeCommand } from '../src/protocol';

const messages: Array<Record<string, unknown>> = [];
const resizeObservers: Array<{
  callback: ResizeObserverCallback;
  observed: Set<Element>;
}> = [];
const requestAnimationFrameMock = vi.fn((callback: FrameRequestCallback) =>
  window.setTimeout(() => callback(performance.now()), 0));

function notifyResize(target: Element): void {
  for (const observer of resizeObservers) {
    if (!observer.observed.has(target)) continue;
    observer.callback(
      [{ target } as ResizeObserverEntry],
      observer as unknown as ResizeObserver,
    );
  }
}

beforeAll(async () => {
  vi.stubGlobal('ResizeObserver', class {
    private readonly record: {
      callback: ResizeObserverCallback;
      observed: Set<Element>;
    } = {
      callback: (_entries: ResizeObserverEntry[]) => {},
      observed: new Set<Element>(),
    };

    constructor(callback: ResizeObserverCallback) {
      this.record.callback = callback;
      resizeObservers.push(this.record);
    }

    observe(target: Element) {
      this.record.observed.add(target);
    }

    unobserve(target: Element) {
      this.record.observed.delete(target);
    }

    disconnect() {
      this.record.observed.clear();
    }
  });
  vi.stubGlobal('requestAnimationFrame', requestAnimationFrameMock);
  vi.stubGlobal('cancelAnimationFrame', (id: number) => window.clearTimeout(id));
  Range.prototype.getClientRects = () => [] as unknown as DOMRectList;
  Range.prototype.getBoundingClientRect = () => ({
    x: 0,
    y: 0,
    width: 0,
    height: 0,
    top: 0,
    right: 0,
    bottom: 0,
    left: 0,
    toJSON: () => ({}),
  });
  Object.defineProperty(HTMLElement.prototype, 'clientHeight', {
    configurable: true,
    get: () => 800,
  });
  Object.defineProperty(HTMLElement.prototype, 'clientWidth', {
    configurable: true,
    get: () => 1000,
  });
  window.SynapseBridge = {
    postMessage(message: string) {
      messages.push(JSON.parse(message) as Record<string, unknown>);
    },
  };
  await import('../src/editor');
});

beforeEach(() => {
  document.body.innerHTML = '<main id="editor"></main>';
  messages.length = 0;
  resizeObservers.length = 0;
  requestAnimationFrameMock.mockClear();
});

function pointerEvent(
  type: string,
  x: number,
  y: number,
  { button = 0, buttons = type === 'pointerup' ? 0 : 1 } = {},
): MouseEvent {
  return new MouseEvent(type, {
    bubbles: true,
    cancelable: true,
    clientX: x,
    clientY: y,
    button,
    buttons,
  });
}

function rect(
  left: number,
  top: number,
  width: number,
  height: number,
): DOMRect {
  return {
    x: left,
    y: top,
    left,
    top,
    width,
    height,
    right: left + width,
    bottom: top + height,
    toJSON: () => ({}),
  } as DOMRect;
}

function setBounds(element: Element, bounds: DOMRect): void {
  element.getBoundingClientRect = () => bounds;
}

function openDocumentContextMenu(x = 20, y = 20): HTMLElement {
  document.querySelector<HTMLElement>('.cm-content')!.dispatchEvent(
    new MouseEvent('contextmenu', {
      bubbles: true,
      cancelable: true,
      clientX: x,
      clientY: y,
    }),
  );
  return document.querySelector<HTMLElement>('.synapse-context-menu')!;
}

function openKeyboardContextMenu(): HTMLElement {
  document.querySelector<HTMLElement>('.cm-content')!.dispatchEvent(
    new KeyboardEvent('keydown', {
      key: 'ContextMenu',
      code: 'ContextMenu',
      bubbles: true,
      cancelable: true,
    }),
  );
  return document.querySelector<HTMLElement>('.synapse-context-menu')!;
}

function menuButton(root: ParentNode, label: string): HTMLButtonElement {
  return Array.from(root.querySelectorAll<HTMLButtonElement>('button')).find(
    (button) =>
      button.querySelector('.synapse-context-label')?.textContent === label,
  )!;
}

function clipboardRequest(action: string): Record<string, unknown> {
  return messages.filter(
    (message) =>
      message.type === 'clipboardRequest' && message.action === action,
  ).at(-1)!;
}

function copiedPlainText(target: HTMLElement): string | undefined {
  const values = new Map<string, string>();
  const event = new Event('copy', {
    bubbles: true,
    cancelable: true,
  }) as ClipboardEvent;
  Object.defineProperty(event, 'clipboardData', {
    value: {
      setData(type: string, value: string) {
        values.set(type, value);
      },
    },
  });
  target.dispatchEvent(event);
  expect(event.defaultPrevented).toBe(true);
  return values.get('text/plain');
}

function resolveClipboard(
  request: Record<string, unknown>,
  {
    outcome = 'success',
    hasText = false,
    hasImage = false,
    text,
  }: {
    outcome?: 'success' | 'unavailable' | 'stale' | 'failure';
    hasText?: boolean;
    hasImage?: boolean;
    text?: string;
  } = {},
): void {
  window.synapseHost!.receive({
    protocolVersion: 2,
    type: 'clipboardResult',
    requestId: request.requestId as number,
    revision: request.revision as number,
    generation: request.generation as number,
    outcome,
    hasText,
    hasImage,
    text,
  });
}

function selectCellText(cell: HTMLElement, anchor: number, head: number): void {
  cell.focus();
  const text = cell.firstChild ?? cell.appendChild(document.createTextNode(''));
  const range = document.createRange();
  range.setStart(text, anchor);
  range.setEnd(text, head);
  const selection = window.getSelection()!;
  selection.removeAllRanges();
  selection.addRange(range);
}

function tableCell(row: number, column: number): HTMLElement {
  return document.querySelector<HTMLElement>(
    `.synapse-table-cell-editor[data-table-row="${row}"]`
      + `[data-table-column="${column}"]`,
  )!;
}

function tableColumnParents(): HTMLElement[] {
  return Array.from(
    document.querySelectorAll<HTMLElement>('.synapse-table-column-handle'),
  ).map((handle) => handle.parentElement as HTMLElement);
}

function openTableSubmenu(cell: HTMLElement, label: string): HTMLElement {
  cell.dispatchEvent(new MouseEvent('contextmenu', {
    bubbles: true,
    cancelable: true,
    clientX: 20,
    clientY: 20,
  }));
  const trigger = Array.from(
    document.querySelectorAll<HTMLButtonElement>(
      '.synapse-context-menu > .synapse-context-submenu-group > button',
    ),
  ).find((button) =>
    button.querySelector('.synapse-context-label')?.textContent === label,
  )!;
  trigger.click();
  return trigger.parentElement!.querySelector<HTMLElement>(
    '.synapse-context-submenu',
  )!;
}

function invokeTableMenu(
  row: number,
  column: number,
  submenuLabel: string,
  actionLabel: string,
): void {
  const submenu = openTableSubmenu(
    tableCell(row, column),
    submenuLabel,
  );
  const action = Array.from(
    submenu.querySelectorAll<HTMLButtonElement>('button'),
  ).find((button) =>
    button.querySelector('.synapse-context-label')?.textContent === actionLabel,
  )!;
  action.click();
}

describe('CodeMirror live preview', () => {
  it('keeps the exact Markdown source while rendering structural previews', async () => {
    const markdown = [
      '# Heading',
      '',
      '| A | B |',
      '| --- | --- |',
      '| 1 | 2 |',
      '',
      '<!-- synapse:columns ratio="50:50" -->',
      'Left',
      '<!-- synapse:column -->',
      'Right',
      '<!-- synapse:columns-end -->',
      '',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'reading'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    expect(messages.filter((message) => message.type === 'error')).toEqual([]);
    expect(window.synapseTest!.getText()).toBe(markdown);
    expect(document.querySelector('.synapse-table-frame')).not.toBeNull();
    expect(document.querySelector('.synapse-columns')).not.toBeNull();
    expect(messages.some((message) => message.type === 'ready')).toBe(true);
  });

  it('remeasures parent and nested editors when dynamic blocks resize', async () => {
    const markdown = [
      '<img src="Note.assets/attachments/outer.png" width="320">',
      '',
      '<!-- synapse:columns ratio="50:50" -->',
      'Left',
      '<!-- synapse:column -->',
      'Right',
      '<!-- synapse:columns-end -->',
      '',
      'After',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const image = document.querySelector<HTMLElement>(
      '.cm-editor > .cm-scroller > .cm-content .synapse-image-block',
    )!;
    const columns = document.querySelector<HTMLElement>('.synapse-columns')!;
    expect(
      resizeObservers.some((observer) => observer.observed.has(image)),
    ).toBe(true);
    expect(
      resizeObservers.some((observer) => observer.observed.has(columns)),
    ).toBe(true);

    const imageMeasureRequests =
      window.synapseTest!.getDynamicBlockMeasureRequests();
    notifyResize(image);
    expect(window.synapseTest!.getDynamicBlockMeasureRequests()).toBeGreaterThan(
      imageMeasureRequests,
    );
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const columnMeasureRequests =
      window.synapseTest!.getDynamicBlockMeasureRequests();
    notifyResize(columns);
    expect(window.synapseTest!.getDynamicBlockMeasureRequests()).toBeGreaterThan(
      columnMeasureRequests,
    );
  });

  it('uses DOM caret positions for forward and reverse outer text drags', async () => {
    const markdown = [
      '<img src="Note.assets/attachments/outer.png" width="320">',
      '',
      'First line',
      'Second line',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const lines = Array.from(document.querySelectorAll<HTMLElement>('.cm-line'));
    const first = lines.find((line) => line.textContent === 'First line')!;
    const second = lines.find((line) => line.textContent === 'Second line')!;
    const firstText = document.createTreeWalker(
      first,
      NodeFilter.SHOW_TEXT,
    ).nextNode() as Text;
    const secondText = document.createTreeWalker(
      second,
      NodeFilter.SHOW_TEXT,
    ).nextNode() as Text;
    const original = Object.getOwnPropertyDescriptor(
      document,
      'caretRangeFromPoint',
    );
    Object.defineProperty(document, 'caretRangeFromPoint', {
      configurable: true,
      value: (_x: number, y: number) => {
        const range = document.createRange();
        if (y < 150) range.setStart(firstText, 0);
        else range.setStart(secondText, secondText.length);
        range.collapse(true);
        return range;
      },
    });
    const drag = (
      start: HTMLElement,
      startY: number,
      endY: number,
    ) => {
      start.dispatchEvent(new MouseEvent('mousedown', {
        bubbles: true,
        cancelable: true,
        detail: 1,
        button: 0,
        buttons: 1,
        clientX: 20,
        clientY: startY,
      }));
      document.dispatchEvent(new MouseEvent('mousemove', {
        bubbles: true,
        cancelable: true,
        detail: 1,
        button: 0,
        buttons: 1,
        clientX: 20,
        clientY: endY,
      }));
      document.dispatchEvent(new MouseEvent('mouseup', {
        bubbles: true,
        cancelable: true,
        detail: 1,
        button: 0,
        buttons: 0,
        clientX: 20,
        clientY: endY,
      }));
    };

    try {
      const firstFrom = markdown.indexOf('First line');
      const secondTo = markdown.indexOf('Second line') + 'Second line'.length;
      drag(first, 100, 200);
      expect(window.synapseTest!.getSelection()).toEqual({
        anchor: firstFrom,
        head: secondTo,
      });
      expect(window.synapseTest!.getSelectedSource()).toBe(
        'First line\nSecond line',
      );

      drag(second, 200, 100);
      expect(window.synapseTest!.getSelection()).toEqual({
        anchor: secondTo,
        head: firstFrom,
      });
      expect(window.synapseTest!.getSelectedSource()).toBe(
        'First line\nSecond line',
      );
    } finally {
      if (original) {
        Object.defineProperty(document, 'caretRangeFromPoint', original);
      } else {
        Reflect.deleteProperty(document, 'caretRangeFromPoint');
      }
    }
  });

  it('updates the same editor state when switching modes', async () => {
    const markdown = '# Heading\n\nParagraph';
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    window.synapseTest!.insertText(' edited');
    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'setMode',
      mode: 'reading',
      editable: false,
      focused: true,
    });
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    expect(window.synapseTest!.getText()).toContain(' edited');
    expect(window.synapseTest!.getMode()).toBe('reading');
  });

  it('renders non-mutating page layout overlays and clears stale lines', async () => {
    const markdown = '# Heading\n\nFirst page\n\nSecond page';
    const rangeRects = vi.spyOn(Range.prototype, 'getClientRects')
      .mockImplementation(() => [rect(16, 120, 2, 18)] as unknown as DOMRectList);
    const rangeBounds = vi.spyOn(Range.prototype, 'getBoundingClientRect')
      .mockImplementation(() => rect(16, 120, 2, 18));
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    window.synapseTest!.setSelection(3, 8);
    const selection = window.synapseTest!.getSelection();

    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'setPageLayout',
      boundaries: [{
        pageIndex: 1,
        sourceOffset: markdown.indexOf('Second'),
      }],
      stale: false,
    });
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const host = document.querySelector<HTMLElement>('.synapse-page-layout')!;
    const line = host.querySelector<HTMLElement>('.synapse-page-boundary')!;
    expect(host.getAttribute('aria-hidden')).toBe('true');
    expect(window.getComputedStyle(host).pointerEvents).toBe('none');
    expect(line.dataset.pageIndex).toBe('1');
    expect(line.textContent).toBe('第 1 页结束 / 第 2 页开始');
    expect(window.synapseTest!.getText()).toBe(markdown);
    expect(window.synapseTest!.getSelection()).toEqual(selection);

    const scroller = document.querySelector<HTMLElement>('.cm-scroller')!;
    scroller.scrollTop = 40;
    scroller.dispatchEvent(new Event('scroll'));
    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'setPageLayout',
      boundaries: [{
        pageIndex: 1,
        sourceOffset: markdown.indexOf('Second'),
      }],
      stale: true,
    });
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    expect(host.classList.contains('synapse-page-layout-stale')).toBe(true);
    expect(host.querySelectorAll('.synapse-page-boundary')).toHaveLength(1);
    expect(window.synapseTest!.getText()).toBe(markdown);
    expect(window.synapseTest!.getSelection()).toEqual(selection);

    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'setPageLayout',
      boundaries: [],
      stale: false,
    });
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    expect(host.querySelectorAll('.synapse-page-boundary')).toHaveLength(0);
    expect(window.synapseTest!.getText()).toBe(markdown);
    expect(window.synapseTest!.getSelection()).toEqual(selection);
    rangeRects.mockRestore();
    rangeBounds.mockRestore();
  });

  it('reactivates unfocused plain and column editors on their first pointer interaction', async () => {
    window.synapseHost!.receive(initialize('Alpha', 'editing', false));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    let content = document.querySelector<HTMLElement>('.cm-content')!;
    expect(content.getAttribute('contenteditable')).not.toBe('true');
    content.dispatchEvent(new MouseEvent('pointerdown', {
      bubbles: true,
      cancelable: true,
      clientX: 10,
      clientY: 10,
    }));
    expect(messages.some(
      (message) => message.type === 'focusChanged' && message.focused === true,
    )).toBe(true);
    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'setMode',
      mode: 'editing',
      editable: true,
      focused: true,
    });
    await new Promise((resolve) => window.setTimeout(resolve, 0));
    content = document.querySelector<HTMLElement>('.cm-content')!;
    expect(content.getAttribute('contenteditable')).toBe('true');
    expect(document.activeElement).toBe(content);

    messages.length = 0;
    const markdown = [
      '<!-- synapse:columns ratio="50:50" -->',
      'Left',
      '<!-- synapse:column -->',
      'Right',
      '<!-- synapse:columns-end -->',
      '',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing', false));
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    const leftColumn = document.querySelectorAll<HTMLElement>(
      '.synapse-column .cm-content',
    )[0];
    expect(leftColumn.getAttribute('contenteditable')).not.toBe('true');
    leftColumn.dispatchEvent(new MouseEvent('pointerdown', {
      bubbles: true,
      cancelable: true,
      clientX: 10,
      clientY: 10,
    }));
    expect(messages.some(
      (message) => message.type === 'focusChanged' && message.focused === true,
    )).toBe(true);
    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'setMode',
      mode: 'editing',
      editable: true,
      focused: true,
    });
    await new Promise((resolve) => window.setTimeout(resolve, 0));
    expect(window.synapseTest!.columnHasFocus('left')).toBe(true);
    expect(document.activeElement).toBe(
      document.querySelectorAll<HTMLElement>(
        '.synapse-column .cm-content',
      )[0],
    );
  });

  it('reactivates an unfocused table and restores the intended cell', async () => {
    const markdown = '| A | B |\n| --- | --- |\n| 1 | 2 |\n';
    window.synapseHost!.receive(initialize(markdown, 'editing', false));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const inactiveCell = tableCell(1, 1);
    expect(inactiveCell.contentEditable).not.toBe('true');
    inactiveCell.dispatchEvent(pointerEvent('pointerdown', 30, 30));

    expect(messages.some(
      (message) => message.type === 'focusChanged' && message.focused === true,
    )).toBe(true);
    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'setMode',
      mode: 'editing',
      editable: true,
      focused: true,
    });
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const activeCell = tableCell(1, 1);
    expect(activeCell.contentEditable).toBe('true');
    expect(document.activeElement).toBe(activeCell);
    expect(document.querySelector('.synapse-table-controls')).toBeNull();
  });

  it('commits table cells and column source through parent transactions', async () => {
    const markdown = [
      '| A | B |',
      '| --- | --- |',
      '| 1 | 2 |',
      '',
      '<!-- synapse:columns ratio="50:50" -->',
      'Left',
      '<!-- synapse:column -->',
      'Right',
      '<!-- synapse:columns-end -->',
      '',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const cell = document.querySelector<HTMLElement>(
      '.synapse-table-frame td .synapse-table-cell-editor',
    );
    expect(cell).not.toBeNull();
    cell!.textContent = 'Edited';
    cell!.dispatchEvent(new InputEvent('input', { bubbles: true }));

    expect(document.querySelector('.synapse-column .cm-editor')).not.toBeNull();
    window.synapseTest!.editColumn('left', '\nLeft edited\n');
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    expect(window.synapseTest!.getText()).toContain('| Edited | 2 |');
    expect(window.synapseTest!.getText()).toContain('Left edited');
  });

  it('preserves table width and alignment while editing cells', async () => {
    const markdown = [
      '<!-- synapse-table width="720" -->',
      '| A | B |',
      '| :--- | ---: |',
      '| 1 | 2 |',
      '',
      'After',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const table = document.querySelector<HTMLTableElement>('.synapse-table-frame table');
    const cell = document.querySelector<HTMLElement>(
      '.synapse-table-frame td .synapse-table-cell-editor',
    );
    expect(table?.style.width).toBe('720px');
    cell!.textContent = 'Edited';
    cell!.dispatchEvent(new InputEvent('input', { bubbles: true }));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    expect(window.synapseTest!.getText()).toContain('<!-- synapse-table width="720" -->');
    expect(window.synapseTest!.getText()).toContain('| :--- | ---: |');
    expect(window.synapseTest!.getText()).toContain('| Edited | 2 |');
  });

  it('rebuilds compound widgets when editable mode changes', async () => {
    const markdown = '| A | B |\n| --- | --- |\n| 1 | 2 |\n\nAfter';
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(
      document.querySelector<HTMLElement>('.synapse-table-cell-editor')!
        .contentEditable,
    ).toBe('true');

    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'setMode',
      mode: 'reading',
      editable: false,
      focused: true,
    });
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    expect(
      document.querySelector<HTMLElement>('.synapse-table-cell-editor')!
        .contentEditable,
    ).not.toBe('true');
  });

  it('keeps table DOM and the next cell caret stable across incremental commits', async () => {
    const markdown = '| A | B |\n| --- | --- |\n| 1 | 2 |\n\nAfter';
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const table = document.querySelector<HTMLTableElement>(
      '.synapse-table-frame table',
    )!;
    const cells = document.querySelectorAll<HTMLElement>(
      '.synapse-table-frame td .synapse-table-cell-editor',
    );
    const first = cells[0];
    const second = cells[1];
    first.focus();
    first.textContent = 'Edited';
    first.dispatchEvent(new InputEvent('input', { bubbles: true }));
    const click = new MouseEvent('mousedown', {
      bubbles: true,
      cancelable: true,
      clientX: 20,
      clientY: 20,
    });
    expect(second.dispatchEvent(click)).toBe(true);
    second.focus();
    const range = document.createRange();
    range.selectNodeContents(second);
    range.collapse(false);
    window.getSelection()!.removeAllRanges();
    window.getSelection()!.addRange(range);

    await new Promise((resolve) => window.setTimeout(resolve, 20));

    expect(document.querySelector('.synapse-table-frame table')).toBe(table);
    expect(document.activeElement).toBe(second);
    expect(window.getSelection()!.focusNode).toBe(second.firstChild);
    expect(first.textContent).toBe('Edited');
    expect(window.synapseTest!.getText()).toContain('| Edited | 2 |');
  });

  it('flushes pending cell drafts before mode changes and structure commands', async () => {
    const markdown = '| A | B |\n| --- | --- |\n| 1 | 2 |\n\nAfter';
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const first = document.querySelector<HTMLElement>(
      '.synapse-table-frame td .synapse-table-cell-editor',
    )!;
    first.textContent = 'Draft';
    first.dispatchEvent(new InputEvent('input', { bubbles: true }));
    invokeTableMenu(1, 0, '行', '下方插入行');
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    expect(window.synapseTest!.getText()).toContain('| Draft | 2 |');
    expect(window.synapseTest!.getText()).toContain('|  |  |');
    expect(window.synapseTest!.undo()).toBe(true);
    expect(window.synapseTest!.getText()).toBe(markdown);

    const restored = document.querySelector<HTMLElement>(
      '.synapse-table-frame td .synapse-table-cell-editor',
    )!;
    restored.textContent = 'Before mode';
    restored.dispatchEvent(new InputEvent('input', { bubbles: true }));
    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'setMode',
      mode: 'reading',
      editable: false,
      focused: true,
    });
    expect(window.synapseTest!.getText()).toContain('| Before mode | 2 |');
  });

  it('adds and deletes table rows and columns from the context menu', async () => {
    const markdown = [
      '| A | B |',
      '| --- | --- |',
      '| 1 | 2 |',
      '| 3 | 4 |',
      '',
      'After',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    invokeTableMenu(1, 0, '行', '上方插入行');
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(window.synapseTest!.getText()).toContain('|  |  |\n| 1 | 2 |');

    invokeTableMenu(2, 0, '行', '删除行');
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(window.synapseTest!.getText()).not.toContain('| 1 | 2 |');

    invokeTableMenu(1, 0, '列', '右侧插入列');
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(window.synapseTest!.getText()).toContain('| A |  | B |');

    invokeTableMenu(1, 1, '列', '删除列');
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(window.synapseTest!.getText()).toContain('| A | B |');
    expect(window.synapseTest!.getText()).not.toContain('| A |  | B |');

    const headerMenu = openTableSubmenu(tableCell(0, 0), '行');
    const deleteHeader = Array.from(
      headerMenu.querySelectorAll<HTMLButtonElement>('button'),
    ).find((button) =>
      button.querySelector('.synapse-context-label')?.textContent === '删除行',
    )!;
    expect(deleteHeader.disabled).toBe(true);

    invokeTableMenu(1, 1, '列', '删除列');
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    const singleColumnMenu = openTableSubmenu(tableCell(1, 0), '列');
    const deleteLastColumn = Array.from(
      singleColumnMenu.querySelectorAll<HTMLButtonElement>('button'),
    ).find((button) => button.textContent === '删除列')!;
    expect(deleteLastColumn.disabled).toBe(true);
  });

  it('keeps the visual table DOM synchronized through parent undo and redo', async () => {
    const markdown = '| A | B |\n| --- | --- |\n| 1 | 2 |\n\nAfter';
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const table = document.querySelector<HTMLTableElement>(
      '.synapse-table-frame table',
    )!;
    const cell = table.querySelector<HTMLElement>(
      'td .synapse-table-cell-editor',
    )!;
    cell.focus();
    cell.textContent = 'Edited';
    cell.dispatchEvent(new InputEvent('input', { bubbles: true }));
    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'flush',
      requestId: 2,
    });
    expect(window.synapseTest!.getText()).toContain('| Edited | 2 |');

    expect(window.synapseTest!.undo()).toBe(true);
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(document.querySelector('.synapse-table-frame table')).toBe(table);
    expect(cell.textContent).toBe('1');
    expect(window.synapseTest!.getText()).toBe(markdown);

    expect(window.synapseTest!.redo()).toBe(true);
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(document.querySelector('.synapse-table-frame table')).toBe(table);
    expect(cell.textContent).toBe('Edited');
    expect(window.synapseTest!.getText()).toContain('| Edited | 2 |');
  });

  it('edits a visual table inside columns without handing focus to the parent', async () => {
    const markdown = [
      '<!-- synapse:columns ratio="50:50" -->',
      '| A | B |',
      '| --- | --- |',
      '| 1 | 2 |',
      '<!-- synapse:column -->',
      'Right',
      '<!-- synapse:columns-end -->',
      '',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const table = document.querySelector<HTMLTableElement>(
      '.synapse-column .synapse-table-frame table',
    )!;
    const columns = document.querySelector<HTMLElement>('.synapse-columns')!;
    const cells = table.querySelectorAll<HTMLElement>(
      'td .synapse-table-cell-editor',
    );
    cells[0].focus();
    expect(columns.classList.contains('synapse-columns-focused')).toBe(true);
    cells[0].textContent = 'Nested';
    cells[0].dispatchEvent(new InputEvent('input', { bubbles: true }));
    cells[1].focus();
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    expect(document.querySelector('.synapse-column .synapse-table-frame table'))
      .toBe(table);
    expect(document.activeElement).toBe(cells[1]);
    expect(columns.classList.contains('synapse-columns-focused')).toBe(true);
    expect(window.synapseTest!.getText()).toContain('| Nested | 2 |');

    const headerCells = tableColumnParents();
    setBounds(headerCells[0], rect(100, 40, 100, 40));
    setBounds(headerCells[1], rect(200, 40, 100, 40));
    const columnHandle = document.querySelector<HTMLElement>(
      '.synapse-column .synapse-table-column-handle[data-table-column="0"]',
    )!;
    columnHandle.dispatchEvent(pointerEvent('pointerdown', 120, 42));
    window.dispatchEvent(pointerEvent('pointermove', 290, 42));
    window.dispatchEvent(pointerEvent('pointerup', 290, 42));
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(window.synapseTest!.getText()).toContain('| B | A |');
    expect(window.synapseTest!.getText()).toContain('| 2 | Nested |');

    invokeTableMenu(1, 0, '行', '下方插入行');
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(window.synapseTest!.getText()).toContain(
      '| 2 | Nested |\n|  |  |',
    );
  });

  it('shows the columns frame only while focus remains inside the editable region', async () => {
    const markdown = [
      '<!-- synapse:columns ratio="50:50" -->',
      'Left',
      '<!-- synapse:column -->',
      'Right',
      '<!-- synapse:columns-end -->',
      '',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    let columns = document.querySelector<HTMLElement>('.synapse-columns')!;
    const content = columns.querySelector<HTMLElement>(
      '.synapse-columns-content',
    )!;
    const controls = columns.querySelector<HTMLElement>(
      '.synapse-columns-controls',
    )!;
    const divider = columns.querySelector<HTMLElement>(
      '.synapse-columns-divider',
    )!;
    const columnRegions = columns.querySelectorAll<HTMLElement>(
      '.synapse-column',
    );
    const contents = columns.querySelectorAll<HTMLElement>('.cm-content');
    expect(columns.classList.contains('synapse-columns-editable')).toBe(true);
    expect(columns.classList.contains('synapse-columns-focused')).toBe(false);
    expect(content.style.gridTemplateColumns).toBe('50fr 0px 50fr');
    expect(controls.hidden).toBe(false);
    expect(getComputedStyle(controls).visibility).toBe('hidden');
    expect(getComputedStyle(columnRegions[0]).padding).toBe('0px 12px');
    expect(getComputedStyle(columnRegions[1]).padding).toBe('0px 12px');
    expect(getComputedStyle(divider).pointerEvents).toBe('none');

    contents[0].focus();
    expect(columns.classList.contains('synapse-columns-focused')).toBe(true);
    expect(getComputedStyle(controls).visibility).toBe('visible');
    expect(getComputedStyle(divider).pointerEvents).toBe('auto');
    expect(content.style.gridTemplateColumns).toBe('50fr 0px 50fr');

    contents[1].focus();
    await Promise.resolve();
    expect(columns.classList.contains('synapse-columns-focused')).toBe(true);
    expect(document.querySelector('.synapse-columns')).toBe(columns);
    expect(columns.querySelector('.synapse-columns-controls')).toBe(controls);
    expect(columns.querySelector('.synapse-columns-divider')).toBe(divider);
    expect(content.style.gridTemplateColumns).toBe('50fr 0px 50fr');

    const outside = document.createElement('button');
    document.body.append(outside);
    outside.focus();
    await Promise.resolve();
    expect(columns.classList.contains('synapse-columns-focused')).toBe(false);
    expect(getComputedStyle(controls).visibility).toBe('hidden');
    expect(getComputedStyle(divider).pointerEvents).toBe('none');
    expect(content.style.gridTemplateColumns).toBe('50fr 0px 50fr');
    expect(getComputedStyle(columnRegions[0]).padding).toBe('0px 12px');
    expect(getComputedStyle(columnRegions[1]).padding).toBe('0px 12px');

    contents[0].focus();
    expect(columns.classList.contains('synapse-columns-focused')).toBe(true);
    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'setMode',
      mode: 'reading',
      editable: false,
      focused: true,
    });
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    columns = document.querySelector<HTMLElement>('.synapse-columns')!;
    expect(columns.classList.contains('synapse-columns-editable')).toBe(false);
    expect(columns.classList.contains('synapse-columns-focused')).toBe(false);
    const readingControls = columns.querySelector<HTMLElement>(
      '.synapse-columns-controls',
    )!;
    expect(readingControls.hidden).toBe(true);
    expect(getComputedStyle(readingControls).display).toBe('none');
    expect(
      columns.querySelector<HTMLElement>('.synapse-columns-content')!.style
        .gridTemplateColumns,
    ).toBe('50fr 0px 50fr');
    for (const column of columns.querySelectorAll<HTMLElement>(
      '.synapse-column',
    )) {
      expect(getComputedStyle(column).padding).toBe('0px 12px');
    }
  });

  it('updates and flattens columns through parent transactions', async () => {
    const markdown = [
      '<!-- synapse:columns ratio="50:50" -->',
      'Left',
      '<!-- synapse:column -->',
      'Right',
      '<!-- synapse:columns-end -->',
      '',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const ratio = Array.from(document.querySelectorAll<HTMLButtonElement>('.synapse-columns-controls button'))
      .find((button) => button.textContent === '2:3');
    ratio!.click();
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(window.synapseTest!.getText()).toContain('ratio="40:60"');

    const flatten = Array.from(document.querySelectorAll<HTMLButtonElement>('.synapse-columns-controls button'))
      .find((button) => button.textContent === '取消双栏');
    flatten!.click();
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(window.synapseTest!.getText()).toContain('Left');
    expect(window.synapseTest!.getText()).toContain('Right');
    expect(window.synapseTest!.getText()).not.toContain('synapse:columns');
  });

  it('maps forward and reverse cross-column selections to source offsets', async () => {
    const markdown = [
      '<!-- synapse:columns ratio="50:50" -->',
      'Left AB',
      '<!-- synapse:column -->',
      'Right CD',
      '<!-- synapse:columns-end -->',
      'After',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    window.synapseTest!.selectAcrossColumns('left', 6, 'right', 6);
    let selection = window.synapseTest!.getSelection();
    expect(selection.anchor).toBeLessThan(selection.head);
    expect(window.synapseTest!.getSelectedSource()).toContain('B\n<!-- synapse:column -->\nRight');

    window.synapseTest!.selectAcrossColumns('right', 6, 'left', 6);
    selection = window.synapseTest!.getSelection();
    expect(selection.anchor).toBeGreaterThan(selection.head);
    expect(window.synapseTest!.getSelectedSource()).toContain('B\n<!-- synapse:column -->\nRight');
  });

  it('copies the exact single-column Markdown through native and menu copy', async () => {
    const markdown = [
      '<!-- synapse:columns ratio="50:50" -->',
      'Left **bold** tail',
      '<!-- synapse:column -->',
      'Right [link](https://example.com)',
      '<!-- synapse:columns-end -->',
      '',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const contents = document.querySelectorAll<HTMLElement>(
      '.synapse-column .cm-content',
    );
    window.synapseTest!.selectColumn('left', 5, 13);
    expect(copiedPlainText(contents[0])).toBe('**bold**');

    window.synapseTest!.selectColumn('right', 33, 6);
    expect(copiedPlainText(contents[1])).toBe('[link](https://example.com)');
    window.synapseTest!.selectColumn('right', 0, 33);
    contents[1].dispatchEvent(new MouseEvent('contextmenu', {
      bubbles: true,
      cancelable: true,
      clientX: 20,
      clientY: 20,
    }));
    menuButton(
      document.querySelector<HTMLElement>('.synapse-context-menu')!,
      '复制',
    ).click();
    expect(clipboardRequest('copy')).toMatchObject({
      target: 'document',
      text: 'Right [link](https://example.com)',
    });
    expect(window.synapseTest!.getText()).toBe(markdown);
  });

  it('removes only valid column markers from portable Markdown copies', async () => {
    const markdown = [
      'Before <!-- keep:inline -->',
      '<!-- synapse:columns ratio="50:50" -->',
      'Left AB',
      '<!-- synapse:column -->',
      'Right CD',
      '<!-- synapse:columns-end -->',
      '<!-- keep:block -->',
      'After',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    const contents = document.querySelectorAll<HTMLElement>(
      '.synapse-column .cm-content',
    );

    window.synapseTest!.selectAcrossColumns('left', 6, 'right', 6);
    expect(copiedPlainText(contents[1])).toBe('B\nRight ');

    window.synapseTest!.selectAcrossColumns('right', 6, 'left', 6);
    expect(copiedPlainText(contents[0])).toBe('B\nRight ');

    window.synapseTest!.setSelection(0, markdown.length);
    expect(copiedPlainText(contents[1])).toBe([
      'Before <!-- keep:inline -->',
      'Left AB',
      'Right CD',
      '<!-- keep:block -->',
      'After',
    ].join('\n'));
    expect(window.synapseTest!.getText()).toBe(markdown);
  });

  it('copies a real child selection while columns are read-only', async () => {
    const markdown = [
      '<!-- synapse:columns ratio="50:50" -->',
      'Left reading text',
      '<!-- synapse:column -->',
      'Right reading text',
      '<!-- synapse:columns-end -->',
      '',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'reading'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    const right = document.querySelectorAll<HTMLElement>(
      '.synapse-column .cm-content',
    )[1];

    window.synapseTest!.selectColumn('right', 6, 13);
    expect(copiedPlainText(right)).toBe('reading');
    expect(window.synapseTest!.getText()).toBe(markdown);
  });

  it('keeps both column editors focused while mapping start middle and end carets', async () => {
    const markdown = [
      '<!-- synapse:columns ratio="50:50" -->',
      'Left AB',
      '<!-- synapse:column -->',
      'Right CD',
      '<!-- synapse:columns-end -->',
      '',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const contents = document.querySelectorAll<HTMLElement>(
      '.synapse-column .cm-content',
    );
    const leftStart = markdown.indexOf('\n') + 1;
    const rightMarker = '<!-- synapse:column -->\n';
    const rightStart = markdown.indexOf(rightMarker) + rightMarker.length;
    for (const offset of [0, 4, 7]) {
      contents[0].focus();
      window.synapseTest!.selectColumn('left', offset, offset);
      await new Promise((resolve) => window.setTimeout(resolve, 0));
      expect(document.activeElement).toBe(contents[0]);
      expect(window.synapseTest!.getSelection()).toEqual({
        anchor: leftStart + offset,
        head: leftStart + offset,
      });
    }
    for (const offset of [0, 5, 8]) {
      contents[1].focus();
      window.synapseTest!.selectColumn('right', offset, offset);
      await new Promise((resolve) => window.setTimeout(resolve, 0));
      expect(document.activeElement).toBe(contents[1]);
      expect(window.synapseTest!.getSelection()).toEqual({
        anchor: rightStart + offset,
        head: rightStart + offset,
      });
    }
  });

  it('protects column markers when backspace removes the last editable blank line', async () => {
    const left = '戒禁取见：非道谓道,非因计因。';
    const markdown = [
      '<!-- synapse:columns ratio="50:50" -->',
      left,
      '',
      '<!-- synapse:column -->',
      'Right',
      '<!-- synapse:columns-end -->',
      '',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const leftContent = document.querySelectorAll<HTMLElement>(
      '.synapse-column .cm-content',
    )[0];
    leftContent.focus();
    window.synapseTest!.selectColumn('left', left.length + 1, left.length + 1);
    leftContent.dispatchEvent(new KeyboardEvent('keydown', {
      key: 'Backspace',
      code: 'Backspace',
      bubbles: true,
      cancelable: true,
    }));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    expect(window.synapseTest!.getText()).toContain(
      `${left}\n<!-- synapse:column -->`,
    );
    expect(window.synapseTest!.getText()).not.toContain(
      `${left}<!-- synapse:column -->`,
    );
    expect(document.querySelector('.synapse-columns')).not.toBeNull();
    expect(leftContent.textContent).not.toContain('synapse:column');
  });

  it('clears a selected column image when focus leaves its column region', async () => {
    const markdown = [
      '<!-- synapse:columns ratio="50:50" -->',
      'Left',
      '<!-- synapse:column -->',
      '![image](Note.assets/attachments/selected.png)',
      '<!-- synapse:columns-end -->',
      '',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const contents = document.querySelectorAll<HTMLElement>(
      '.synapse-column .cm-content',
    );
    contents[1].focus();
    document.querySelector<HTMLElement>(
      '.synapse-column:nth-child(3) .synapse-image-block',
    )!.click();
    await Promise.resolve();
    expect(document.querySelector('.synapse-image-selected')).not.toBeNull();
    expect(document.querySelector('.synapse-image-move-handle')).not.toBeNull();
    expect(document.querySelector('.synapse-image-source')).toBeNull();

    const outside = document.createElement('button');
    document.body.append(outside);
    outside.focus();
    await Promise.resolve();
    expect(document.querySelector('.synapse-image-selected')).toBeNull();
    expect(document.querySelector('.synapse-image-source')).toBeNull();

    contents[0].focus();
    await Promise.resolve();
    expect(
      document.querySelector('.synapse-columns')!.classList.contains(
        'synapse-columns-focused',
      ),
    ).toBe(true);
    expect(document.querySelector('.synapse-image-selected')).toBeNull();
  });

  it('selects an outer image after focus moves from a column editor', async () => {
    const src = 'Note.assets/attachments/outer.png';
    const markdown = [
      `<img src="${src}" width="320">`,
      '',
      'Alpha first',
      'Beta second',
      '',
      '| A | B |',
      '| --- | --- |',
      '| 1 | 2 |',
      '',
      '<!-- synapse:columns ratio="50:50" -->',
      'Left',
      '<!-- synapse:column -->',
      'Right',
      '<!-- synapse:columns-end -->',
      '',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const attachmentRequest = messages.find(
      (message) =>
        message.type === 'attachmentRequest' && message.src === src,
    )!;
    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'attachmentChunk',
      requestId: attachmentRequest.requestId as string,
      chunkIndex: 0,
      chunkCount: 1,
      mimeType: 'image/png',
      data: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAF/gL+Xw3vWQAAAABJRU5ErkJggg==',
    });
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const columnContent = document.querySelector<HTMLElement>(
      '.synapse-column .cm-content',
    )!;
    columnContent.focus();
    window.synapseTest!.selectColumn('left', 2, 2);
    expect(document.activeElement).toBe(columnContent);

    const outer = document.querySelector<HTMLElement>(
      '.cm-editor > .cm-scroller > .cm-content .synapse-image-block',
    )!;
    outer.dispatchEvent(pointerEvent('pointerdown', 160, 90));
    outer.dispatchEvent(new MouseEvent('mousedown', {
      bubbles: true,
      cancelable: true,
      button: 0,
      buttons: 1,
      clientX: 160,
      clientY: 90,
    }));
    outer.dispatchEvent(pointerEvent('pointerup', 160, 90));
    outer.dispatchEvent(new MouseEvent('mouseup', {
      bubbles: true,
      cancelable: true,
      button: 0,
      buttons: 0,
      clientX: 160,
      clientY: 90,
    }));
    outer.dispatchEvent(new MouseEvent('click', {
      bubbles: true,
      cancelable: true,
      button: 0,
      clientX: 160,
      clientY: 90,
    }));
    await Promise.resolve();

    expect(document.activeElement).toBe(
      document.querySelector('.cm-editor > .cm-scroller > .cm-content'),
    );
    expect(
      document.querySelector('.synapse-image-selected')?.getAttribute(
        'data-src',
      ),
    ).toBe(src);
    expect(document.querySelector('.synapse-image-resize-right')).not.toBeNull();

    window.synapseTest!.setSelection(markdown.length, markdown.length);
    await Promise.resolve();

    expect(
      document.querySelector('.synapse-image-selected')?.getAttribute(
        'data-src',
      ),
    ).toBe(src);
    expect(document.querySelector('.synapse-image-resize-right')).not.toBeNull();

    const parentContent = document.querySelector<HTMLElement>(
      '.cm-editor > .cm-scroller > .cm-content',
    )!;
    const alphaFrom = markdown.indexOf('Alpha first');
    const alphaTo = alphaFrom + 'Alpha first'.length;
    parentContent.dispatchEvent(pointerEvent('pointerdown', 20, 260));
    window.synapseTest!.setSelection(alphaFrom, alphaTo);
    await Promise.resolve();

    expect(document.querySelector('.synapse-image-selected')).not.toBeNull();
    expect(window.synapseTest!.getSelection()).toEqual({
      anchor: alphaFrom,
      head: alphaTo,
    });
    expect(window.synapseTest!.getSelectedSource()).toBe('Alpha first');

    parentContent.dispatchEvent(pointerEvent('pointerup', 20, 260));
    await Promise.resolve();

    expect(document.querySelector('.synapse-image-selected')).toBeNull();
    expect(window.synapseTest!.getSelection()).toEqual({
      anchor: alphaFrom,
      head: alphaTo,
    });
    expect(window.synapseTest!.getSelectedSource()).toBe('Alpha first');

    document.querySelector<HTMLElement>('.synapse-image-block')!.click();
    await Promise.resolve();
    const betaTo = markdown.indexOf('Beta second') + 'Beta second'.length;
    parentContent.dispatchEvent(pointerEvent('pointerdown', 20, 280));
    window.synapseTest!.setSelection(betaTo, alphaFrom);
    window.dispatchEvent(pointerEvent('pointerup', 20, 280));
    await Promise.resolve();

    expect(window.synapseTest!.getSelection()).toEqual({
      anchor: betaTo,
      head: alphaFrom,
    });
    expect(window.synapseTest!.getSelectedSource()).toBe(
      'Alpha first\nBeta second',
    );
    expect(document.querySelector('.synapse-image-selected')).toBeNull();

    document.querySelector<HTMLElement>('.synapse-image-block')!.click();
    await Promise.resolve();
    parentContent.dispatchEvent(pointerEvent('pointerdown', 20, 260));
    window.synapseTest!.setSelection(alphaFrom, alphaTo);
    parentContent.dispatchEvent(pointerEvent('pointercancel', 20, 260));
    await Promise.resolve();

    expect(document.querySelector('.synapse-image-selected')).not.toBeNull();
    expect(window.synapseTest!.getSelection()).toEqual({
      anchor: alphaFrom,
      head: alphaTo,
    });

    columnContent.dispatchEvent(pointerEvent('pointerdown', 400, 360));
    window.synapseTest!.selectColumn('right', 0, 5);
    await Promise.resolve();
    expect(document.querySelector('.synapse-image-selected')).not.toBeNull();
    columnContent.dispatchEvent(pointerEvent('pointerup', 400, 360));
    await Promise.resolve();
    expect(document.querySelector('.synapse-image-selected')).toBeNull();

    document.querySelector<HTMLElement>('.synapse-image-block')!.click();
    await Promise.resolve();
    expect(window.synapseTest!.getParentImageSelection()).toBe(0);
    const cell = tableCell(1, 1);
    cell.dispatchEvent(pointerEvent('pointerdown', 160, 320));
    await Promise.resolve();
    expect(window.synapseTest!.getPendingParentImageSelectionDismiss()).toBe(
      true,
    );
    expect(document.querySelector('.synapse-image-selected')).not.toBeNull();
    cell.dispatchEvent(pointerEvent('pointerup', 160, 320));
    await Promise.resolve();
    expect(document.querySelector('.synapse-image-selected')).toBeNull();
  });

  it('selects only the clicked inline image without exposing img source', async () => {
    const first = '<img src="Note.assets/attachments/first.png" width="320">';
    const second = '<img src="Note.assets/attachments/second.png" width="360">';
    const markdown = `Before ${first} between ${second} after\n\nTail`;
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    let images = document.querySelectorAll<HTMLElement>(
      '.synapse-inline-image',
    );
    expect(images).toHaveLength(2);
    expect(document.querySelector('.synapse-image-move-handle')).toBeNull();
    expect(document.querySelector('.synapse-image-resize')).toBeNull();
    images[1].click();
    await Promise.resolve();

    images = document.querySelectorAll<HTMLElement>('.synapse-inline-image');
    expect(images).toHaveLength(2);
    expect(document.querySelector('.synapse-image-selected')?.getAttribute('data-src'))
      .toBe('Note.assets/attachments/second.png');
    expect(document.querySelector('.synapse-image-source')).toBeNull();
    expect(document.querySelector('.synapse-image-move-handle')?.getAttribute('title'))
      .toBe('拖动图片');

    document.querySelector<HTMLElement>('.cm-content')!.dispatchEvent(
      new KeyboardEvent('keydown', {
        key: 'Delete',
        code: 'Delete',
        bubbles: true,
        cancelable: true,
      }),
    );
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(window.synapseTest!.getText()).toContain(first);
    expect(window.synapseTest!.getText()).not.toContain(second);
    expect(window.synapseTest!.getText()).toContain(`${first} between  after`);
  });

  it('resizes a selected image from the right handle with mouse events', async () => {
    const src = 'Note.assets/attachments/resize.png';
    const markdown = `<img src="${src}" width="320">\n\nAfter`;
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const attachmentRequest = messages.find(
      (message) =>
        message.type === 'attachmentRequest' && message.src === src,
    )!;
    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'attachmentChunk',
      requestId: attachmentRequest.requestId as string,
      chunkIndex: 0,
      chunkCount: 1,
      mimeType: 'image/png',
      data: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAF/gL+Xw3vWQAAAABJRU5ErkJggg==',
    });
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const imageRoot = document.querySelector<HTMLElement>(
      '.synapse-image-block',
    )!;
    imageRoot.dispatchEvent(pointerEvent('pointerdown', 160, 90));
    imageRoot.dispatchEvent(new MouseEvent('mousedown', {
      bubbles: true,
      cancelable: true,
      button: 0,
      buttons: 1,
      clientX: 160,
      clientY: 90,
    }));
    imageRoot.dispatchEvent(pointerEvent('pointerup', 160, 90));
    imageRoot.dispatchEvent(new MouseEvent('mouseup', {
      bubbles: true,
      cancelable: true,
      button: 0,
      buttons: 0,
      clientX: 160,
      clientY: 90,
    }));
    imageRoot.dispatchEvent(new MouseEvent('click', {
      bubbles: true,
      cancelable: true,
      button: 0,
      clientX: 160,
      clientY: 90,
    }));
    await Promise.resolve();

    const selected = document.querySelector<HTMLElement>(
      '.synapse-image-selected',
    )!;
    const image = selected.querySelector<HTMLImageElement>('img')!;
    image.getBoundingClientRect = () => rect(
      0,
      0,
      Number.parseFloat(image.style.width) || 320,
      180,
    );
    const handle = selected.querySelector<HTMLElement>(
      '.synapse-image-resize-right',
    )!;
    const handleStyle = getComputedStyle(handle);
    expect(handleStyle.width).toBe('18px');
    expect(handleStyle.height).toBe('18px');
    expect(handleStyle.zIndex).toBe('6');
    const pointerDown = pointerEvent('pointerdown', 320, 180);
    handle.dispatchEvent(pointerDown);
    const down = new MouseEvent('mousedown', {
      bubbles: true,
      cancelable: true,
      button: 0,
      buttons: 1,
      clientX: 320,
      clientY: 180,
    });
    handle.dispatchEvent(down);
    window.dispatchEvent(new MouseEvent('mousemove', {
      bubbles: true,
      cancelable: true,
      button: 0,
      buttons: 1,
      clientX: 400,
      clientY: 180,
    }));
    window.dispatchEvent(new MouseEvent('mouseup', {
      bubbles: true,
      cancelable: true,
      button: 0,
      buttons: 0,
      clientX: 400,
      clientY: 180,
    }));
    const click = new MouseEvent('click', {
      bubbles: true,
      cancelable: true,
      button: 0,
      clientX: 400,
      clientY: 180,
    });
    handle.dispatchEvent(click);

    expect(pointerDown.defaultPrevented).toBe(true);
    expect(down.defaultPrevented).toBe(true);
    expect(click.defaultPrevented).toBe(true);
    expect(document.querySelector('.synapse-image-selected')).not.toBeNull();
    expect(image.style.width).toBe('400px');
    expect(messages.filter((message) => message.type === 'imageAction').at(-1))
      .toMatchObject({
        action: 'resize',
        src,
        from: 0,
        to: markdown.indexOf('\n'),
        width: 400,
      });
    expect(window.synapseTest!.getText()).toBe(markdown);
  });

  it('moves a selected image to the document end from its handle', async () => {
    const imageMarkdown =
      '<img src="Note.assets/attachments/end.png" width="320">';
    const markdown = `${imageMarkdown}\n\n# Heading\n\nParagraph`;
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    document.querySelector<HTMLElement>('.synapse-image-block')!.click();
    await Promise.resolve();
    const selected = document.querySelector<HTMLElement>(
      '.synapse-image-selected',
    )!;
    const handle = selected.querySelector<HTMLElement>(
      '.synapse-image-move-handle',
    )!;
    const editor = document.querySelector<HTMLElement>('.cm-editor')!;
    const scroller = document.querySelector<HTMLElement>('.cm-scroller')!;
    const content = document.querySelector<HTMLElement>('.cm-content')!;
    setBounds(editor, rect(0, 0, 640, 400));
    setBounds(scroller, rect(0, 0, 640, 400));
    setBounds(content, rect(0, 0, 640, 220));

    handle.dispatchEvent(new MouseEvent('mousedown', {
      bubbles: true,
      cancelable: true,
      button: 0,
      buttons: 1,
      clientX: 12,
      clientY: 12,
    }));
    expect(document.querySelector('.synapse-image-drag-preview')).not.toBeNull();
    window.dispatchEvent(new MouseEvent('mousemove', {
      bubbles: true,
      cancelable: true,
      buttons: 1,
      clientX: 120,
      clientY: 300,
    }));
    const preview = document.querySelector<HTMLElement>(
      '.synapse-image-drag-preview',
    )!;
    expect(preview).not.toBeNull();
    expect(preview.style.transform).toContain('translate3d(134px, 314px');
    expect(document.querySelector('.synapse-image-drop-target')).not.toBeNull();
    expect(document.querySelector('.synapse-image-block-drop-indicator'))
      .not.toBeNull();
    selected.remove();
    window.dispatchEvent(new MouseEvent('mousemove', {
      bubbles: true,
      cancelable: true,
      buttons: 1,
      clientX: 140,
      clientY: 300,
    }));
    expect(document.querySelector('.synapse-image-drag-preview')).toBe(preview);
    expect(preview.style.transform).toContain('translate3d(154px, 314px');
    window.dispatchEvent(new MouseEvent('mouseup', {
      bubbles: true,
      cancelable: true,
      button: 0,
      buttons: 0,
      clientX: 120,
      clientY: 300,
    }));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const updated = window.synapseTest!.getText();
    expect(updated.indexOf('Paragraph')).toBeLessThan(
      updated.indexOf(imageMarkdown),
    );
    expect(updated).toMatch(/Paragraph\n\n<img src=/);
    expect(document.querySelector('.synapse-image-selected')).not.toBeNull();
    expect(document.querySelector('.synapse-image-source')).toBeNull();
  });

  it('auto-scrolls a document-level image drag and cleans up on cancel', async () => {
    const imageMarkdown =
      '<img src="Note.assets/attachments/scroll.png" width="320">';
    const markdown = [
      imageMarkdown,
      '',
      ...Array.from({ length: 80 }, (_, index) => `Paragraph ${index}`),
    ].join('\n\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    document.querySelector<HTMLElement>('.synapse-image-block')!.click();
    await Promise.resolve();
    const editor = document.querySelector<HTMLElement>('.cm-editor')!;
    const scroller = document.querySelector<HTMLElement>('.cm-scroller')!;
    const content = document.querySelector<HTMLElement>('.cm-content')!;
    setBounds(editor, rect(0, 0, 1000, 800));
    setBounds(scroller, rect(0, 0, 1000, 800));
    setBounds(content, rect(0, 0, 1000, 2200));
    scroller.scrollTop = 100;
    const handle = document.querySelector<HTMLElement>(
      '.synapse-image-move-handle',
    )!;

    handle.dispatchEvent(pointerEvent('pointerdown', 20, 20));
    window.dispatchEvent(pointerEvent('pointermove', 120, 790));
    await new Promise((resolve) => window.setTimeout(resolve, 10));

    expect(scroller.scrollTop).toBeGreaterThan(100);
    expect(document.querySelector('.synapse-image-drag-preview')).not.toBeNull();
    window.dispatchEvent(new MouseEvent('pointercancel', {
      bubbles: true,
      cancelable: true,
    }));
    expect(window.synapseTest!.getText()).toBe(markdown);
    expect(document.querySelector('.synapse-image-drag-preview')).toBeNull();
    expect(document.querySelector('.synapse-image-drop-target')).toBeNull();
  });

  it('marks equivalent and outside image drops invalid and cleans feedback', async () => {
    const imageMarkdown =
      '<img src="Note.assets/attachments/invalid.png" width="320">';
    const markdown = `${imageMarkdown}\n\nAfter`;
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    document.querySelector<HTMLElement>('.synapse-image-block')!.click();
    await Promise.resolve();
    const editor = document.querySelector<HTMLElement>('.cm-editor')!;
    const scroller = document.querySelector<HTMLElement>('.cm-scroller')!;
    const content = document.querySelector<HTMLElement>('.cm-content')!;
    const selected = document.querySelector<HTMLElement>(
      '.synapse-image-selected',
    )!;
    setBounds(editor, rect(0, 0, 640, 320));
    setBounds(scroller, rect(0, 0, 640, 320));
    setBounds(content, rect(0, 0, 640, 240));
    setBounds(selected, rect(16, 40, 320, 100));
    const after = Array.from(
      document.querySelectorAll<HTMLElement>('.cm-line'),
    ).find((line) => line.textContent === 'After')!;
    setBounds(after, rect(16, 170, 608, 40));

    let handle = selected.querySelector<HTMLElement>(
      '.synapse-image-move-handle',
    )!;
    handle.dispatchEvent(pointerEvent('pointerdown', 20, 44));
    window.dispatchEvent(pointerEvent('pointermove', 120, 70));
    expect(document.querySelector('.synapse-image-drag-preview')?.classList
      .contains('synapse-image-drop-invalid')).toBe(true);
    expect(document.querySelector('.synapse-image-drop-target')?.classList
      .contains('synapse-image-drop-invalid')).toBe(true);
    window.dispatchEvent(pointerEvent('pointerup', 120, 70));
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(window.synapseTest!.getText()).toBe(markdown);
    expect(document.querySelector('.synapse-image-drag-preview')).toBeNull();

    handle = document.querySelector<HTMLElement>(
      '.synapse-image-move-handle',
    )!;
    handle.dispatchEvent(pointerEvent('pointerdown', 20, 44));
    window.dispatchEvent(pointerEvent('pointermove', 120, 174));
    expect(document.querySelector('.synapse-image-drag-preview')?.classList
      .contains('synapse-image-drop-invalid')).toBe(true);
    expect(document.querySelector('.synapse-image-drop-target')?.classList
      .contains('synapse-image-drop-invalid')).toBe(true);
    window.dispatchEvent(pointerEvent('pointerup', 120, 174));
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(window.synapseTest!.getText()).toBe(markdown);

    handle = document.querySelector<HTMLElement>(
      '.synapse-image-move-handle',
    )!;
    handle.dispatchEvent(pointerEvent('pointerdown', 20, 44));
    window.dispatchEvent(pointerEvent('pointermove', 700, 70));
    expect(document.querySelector('.synapse-image-drag-preview')?.classList
      .contains('synapse-image-drop-invalid')).toBe(true);
    expect(document.querySelector('.synapse-image-drop-target')).toBeNull();
    expect(document.querySelector('.synapse-image-block-drop-indicator'))
      .toBeNull();
    window.dispatchEvent(new KeyboardEvent('keydown', {
      key: 'Escape',
      bubbles: true,
      cancelable: true,
    }));
    expect(window.synapseTest!.getText()).toBe(markdown);
    expect(document.querySelector('.synapse-image-drag-preview')).toBeNull();
    expect(document.querySelector('.synapse-image-drop-target')).toBeNull();
  });

  it('aborts image drag on mode and host revision changes', async () => {
    const imageMarkdown =
      '<img src="Note.assets/attachments/stale.png" width="320">';
    const markdown = `${imageMarkdown}\n\nAfter`;
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    document.querySelector<HTMLElement>('.synapse-image-block')!.click();
    await Promise.resolve();
    const editor = document.querySelector<HTMLElement>('.cm-editor')!;
    const scroller = document.querySelector<HTMLElement>('.cm-scroller')!;
    const content = document.querySelector<HTMLElement>('.cm-content')!;
    setBounds(editor, rect(0, 0, 640, 320));
    setBounds(scroller, rect(0, 0, 640, 320));
    setBounds(content, rect(0, 0, 640, 220));

    let handle = document.querySelector<HTMLElement>(
      '.synapse-image-move-handle',
    )!;
    handle.dispatchEvent(pointerEvent('pointerdown', 20, 20));
    window.dispatchEvent(pointerEvent('pointermove', 120, 280));
    expect(document.querySelector('.synapse-image-drag-preview')).not.toBeNull();
    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'setMode',
      mode: 'reading',
      editable: false,
      focused: true,
    });
    expect(document.querySelector('.synapse-image-drag-preview')).toBeNull();
    window.dispatchEvent(pointerEvent('pointerup', 120, 280));
    expect(window.synapseTest!.getText()).toBe(markdown);

    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'setMode',
      mode: 'editing',
      editable: true,
      focused: true,
    });
    document.querySelector<HTMLElement>('.synapse-image-block')!.click();
    await Promise.resolve();
    handle = document.querySelector<HTMLElement>(
      '.synapse-image-move-handle',
    )!;
    handle.dispatchEvent(pointerEvent('pointerdown', 20, 20));
    window.dispatchEvent(pointerEvent('pointermove', 120, 280));
    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'applyChanges',
      generation: 1,
      baseRevision: 0,
      revision: 1,
      changes: [{ from: markdown.length, to: markdown.length, insert: '\n\nExternal' }],
    });
    expect(document.querySelector('.synapse-image-drag-preview')).toBeNull();
    window.dispatchEvent(pointerEvent('pointerup', 120, 280));
    expect(window.synapseTest!.getText()).toBe(`${markdown}\n\nExternal`);
  });

  it('selects before and after boundaries for every visible markdown block kind', async () => {
    const source = '<img src="Note.assets/attachments/source.png" width="320">';
    const targetImage =
      '<img src="Note.assets/attachments/target.png" width="320">';
    const markdown = [
      source,
      '',
      '# Heading',
      '',
      'Paragraph',
      '',
      '- Item',
      '',
      '> Quote',
      '',
      '```',
      'code',
      '```',
      '',
      '| A | B |',
      '| --- | --- |',
      '| 1 | 2 |',
      '',
      targetImage,
      '',
      '<!-- synapse:page-break -->',
      '',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    document.querySelector<HTMLElement>('.synapse-image-block')!.click();
    await Promise.resolve();

    const editor = document.querySelector<HTMLElement>('.cm-editor')!;
    const scroller = document.querySelector<HTMLElement>('.cm-scroller')!;
    const content = document.querySelector<HTMLElement>('.cm-content')!;
    setBounds(editor, rect(0, 0, 720, 640));
    setBounds(scroller, rect(0, 0, 720, 640));
    setBounds(content, rect(16, 0, 688, 620));
    const selected = document.querySelector<HTMLElement>(
      '.synapse-image-selected',
    )!;
    setBounds(selected, rect(16, 10, 240, 56));
    const lines = Array.from(
      document.querySelectorAll<HTMLElement>('.cm-line'),
    );
    const line = (text: string) => lines.find((candidate) =>
      candidate.textContent?.includes(text))!;
    const codeLine = line('code');
    const codeLineIndex = lines.indexOf(codeLine);
    const targets: Array<{
      name: string;
      element: HTMLElement | undefined;
      bounds: DOMRect;
    }> = [
      { name: 'heading', element: line('Heading'), bounds: rect(16, 90, 688, 36) },
      { name: 'paragraph', element: line('Paragraph'), bounds: rect(16, 140, 688, 36) },
      { name: 'list', element: line('Item'), bounds: rect(16, 190, 688, 36) },
      { name: 'quote', element: line('Quote'), bounds: rect(16, 240, 688, 36) },
      { name: 'code', element: codeLine, bounds: rect(16, 290, 688, 76) },
      {
        name: 'table',
        element: document.querySelector<HTMLElement>('.synapse-table-frame')!,
        bounds: rect(16, 380, 688, 64),
      },
      {
        name: 'image',
        element: document.querySelectorAll<HTMLElement>(
          '.synapse-image-block',
        )[1],
        bounds: rect(16, 460, 240, 56),
      },
      {
        name: 'page-break',
        element: document.querySelector<HTMLElement>('.synapse-page-break')!,
        bounds: rect(16, 530, 688, 44),
      },
    ];
    for (const target of targets) {
      expect(target.element, target.name).toBeDefined();
      setBounds(target.element!, target.bounds);
    }
    setBounds(lines[codeLineIndex - 1], rect(16, 290, 688, 22));
    setBounds(codeLine, rect(16, 320, 688, 22));
    setBounds(lines[codeLineIndex + 1], rect(16, 344, 688, 22));

    const handle = selected.querySelector<HTMLElement>(
      '.synapse-image-move-handle',
    )!;
    for (const target of targets) {
      handle.dispatchEvent(pointerEvent('pointerdown', 20, 14));
      window.dispatchEvent(pointerEvent(
        'pointermove',
        target.bounds.left + 20,
        target.bounds.top + 4,
      ));
      expect(document.querySelector<HTMLElement>(
        '.synapse-image-block-drop-indicator',
      )?.dataset.placement).toBe('before');
      window.dispatchEvent(pointerEvent(
        'pointermove',
        target.bounds.left + 20,
        target.bounds.bottom - 4,
      ));
      await new Promise((resolve) => window.setTimeout(resolve, 0));
      expect(document.querySelector<HTMLElement>(
        '.synapse-image-block-drop-indicator',
      )?.dataset.placement).toBe('after');
      window.dispatchEvent(new MouseEvent('pointercancel', {
        bubbles: true,
        cancelable: true,
      }));
      expect(document.querySelector('.synapse-image-drag-preview')).toBeNull();
    }
    expect(window.synapseTest!.getText()).toBe(markdown);
  });

  it('drags an image between column editors without replacing the drag source', async () => {
    const src = 'Note.assets/attachments/drag.png';
    const imageMarkdown = `![drag](${src})`;
    const markdown = [
      '<!-- synapse:columns ratio="50:50" -->',
      imageMarkdown,
      '<!-- synapse:column -->',
      'Right',
      '<!-- synapse:columns-end -->',
      '',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const attachmentRequest = messages.find(
      (message) => message.type === 'attachmentRequest' && message.src === src,
    )!;
    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'attachmentChunk',
      requestId: attachmentRequest.requestId as string,
      chunkIndex: 0,
      chunkCount: 1,
      mimeType: 'image/png',
      data: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAF/gL+Xw3vWQAAAABJRU5ErkJggg==',
    });
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const columns = document.querySelector<HTMLElement>('.synapse-columns')!;
    const contents = columns.querySelectorAll<HTMLElement>('.cm-content');
    contents[0].focus();
    await Promise.resolve();
    let sourceImage = columns.querySelector<HTMLElement>(
      '.synapse-column .synapse-image-block',
    )!;
    const renderedImage = sourceImage.querySelector<HTMLImageElement>('img')!;
    expect(renderedImage).not.toBeNull();
    expect(getComputedStyle(renderedImage).pointerEvents).toBe('none');
    expect(sourceImage.draggable).toBe(false);
    expect(sourceImage.querySelector('.synapse-image-move-handle')).toBeNull();
    expect(sourceImage.querySelector('.synapse-image-resize')).toBeNull();
    sourceImage.dispatchEvent(new MouseEvent('pointerdown', {
      bubbles: true,
      cancelable: true,
      button: 0,
      clientX: 10,
      clientY: 10,
    }));
    window.dispatchEvent(new MouseEvent('pointermove', {
      bubbles: true,
      cancelable: true,
      buttons: 1,
      clientX: 20,
      clientY: 10,
    }));
    expect(sourceImage.classList.contains('synapse-image-dragging')).toBe(false);
    window.dispatchEvent(new MouseEvent('pointercancel', {
      bubbles: true,
      cancelable: true,
    }));
    expect(sourceImage.classList.contains('synapse-image-dragging')).toBe(false);
    sourceImage.click();
    await Promise.resolve();
    sourceImage = columns.querySelector<HTMLElement>(
      '.synapse-column .synapse-image-selected',
    )!;
    expect(sourceImage).not.toBeNull();
    expect(sourceImage.querySelector('.synapse-image-source')).toBeNull();
    expect(sourceImage.querySelector('.synapse-image-move-handle')).not.toBeNull();
    expect(sourceImage.querySelectorAll('.synapse-image-resize')).toHaveLength(2);

    const sides = columns.querySelectorAll<HTMLElement>('.synapse-column');
    const rightLine = Array.from(
      sides[1].querySelectorAll<HTMLElement>('.cm-line'),
    ).find((line) => line.textContent === 'Right')!;
    setBounds(columns, rect(0, 0, 640, 280));
    setBounds(
      document.querySelector<HTMLElement>('.cm-editor')!,
      rect(0, 0, 640, 320),
    );
    setBounds(
      document.querySelector<HTMLElement>('.cm-scroller')!,
      rect(0, 0, 640, 320),
    );
    setBounds(
      document.querySelector<HTMLElement>('.cm-editor > .cm-scroller > .cm-content')!,
      rect(0, 0, 640, 280),
    );
    setBounds(sides[0], rect(0, 0, 310, 280));
    setBounds(sides[1], rect(330, 0, 310, 280));
    setBounds(
      sides[1].querySelector<HTMLElement>('.cm-content')!,
      rect(330, 0, 310, 240),
    );
    setBounds(rightLine, rect(346, 100, 140, 40));
    const elementFromPoint = Object.getOwnPropertyDescriptor(
      document,
      'elementFromPoint',
    );
    Object.defineProperty(document, 'elementFromPoint', {
      configurable: true,
      value: () => rightLine,
    });
    const moveHandle = sourceImage.querySelector<HTMLElement>(
      '.synapse-image-move-handle',
    )!;
    moveHandle.dispatchEvent(pointerEvent('pointerdown', 12, 12));
    window.dispatchEvent(pointerEvent('pointermove', 400, 130));
    expect(sourceImage.classList.contains('synapse-image-dragging')).toBe(true);
    expect(document.querySelector('.synapse-image-drag-preview')).not.toBeNull();
    expect(document.querySelector('.synapse-image-drop-target')).not.toBeNull();
    expect(document.querySelector('.synapse-image-block-drop-indicator'))
      .not.toBeNull();
    window.dispatchEvent(pointerEvent('pointerup', 400, 130));
    if (elementFromPoint) {
      Object.defineProperty(document, 'elementFromPoint', elementFromPoint);
    } else {
      Reflect.deleteProperty(document, 'elementFromPoint');
    }
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    expect(document.querySelector('.synapse-image-drag-preview')).toBeNull();
    expect(document.querySelector('.synapse-image-drop-target')).toBeNull();
    expect(document.querySelector('.synapse-image-block-drop-indicator'))
      .toBeNull();

    const updated = window.synapseTest!.getText();
    const separator = updated.indexOf('<!-- synapse:column -->');
    const image = updated.indexOf(imageMarkdown);
    const end = updated.indexOf('<!-- synapse:columns-end -->');
    expect(image).toBeGreaterThan(separator);
    expect(image).toBeLessThan(end);
    const movedColumns = document.querySelector<HTMLElement>(
      '.synapse-columns',
    );
    expect(movedColumns, updated).not.toBeNull();
    const movedSides = movedColumns!.querySelectorAll('.synapse-column');
    expect(movedSides, updated).toHaveLength(2);
    const movedImage = movedSides[1]
      .querySelector<HTMLElement>('.synapse-image-block')!;
    expect(movedImage).not.toBeNull();
    movedImage.click();
    await Promise.resolve();
    expect(document.querySelector('.synapse-image-selected')).not.toBeNull();
    expect(document.querySelector('.synapse-image-source')).toBeNull();
    expect(document.querySelector('.synapse-image-move-handle')).not.toBeNull();

    document.querySelectorAll<HTMLElement>(
      '.synapse-column .cm-content',
    )[0].focus();
    await Promise.resolve();
    expect(document.querySelector('.synapse-image-selected')).toBeNull();
    expect(document.querySelector('.synapse-image-source')).toBeNull();
  });

  it('keeps table composition focused and reports it as composing', async () => {
    const markdown = '| A | B |\n| --- | --- |\n| 1 | 2 |\n\nAfter';
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const table = document.querySelector<HTMLTableElement>(
      '.synapse-table-frame table',
    )!;
    const cell = table.querySelector<HTMLElement>(
      'td .synapse-table-cell-editor',
    )!;
    cell.focus();
    cell.dispatchEvent(new CompositionEvent('compositionstart', {
      bubbles: true,
      data: '',
    }));
    cell.textContent = '中文输入';
    cell.dispatchEvent(new InputEvent('input', {
      bubbles: true,
      inputType: 'insertCompositionText',
      data: '中文输入',
    }));
    cell.dispatchEvent(new CompositionEvent('compositionend', {
      bubbles: true,
      data: '中文输入',
    }));
    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'flush',
      requestId: 1,
    });
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    expect(document.querySelector('.synapse-table-frame table')).toBe(table);
    expect(document.activeElement).toBe(cell);
    expect(window.synapseTest!.getText()).toContain('| 中文输入 | 2 |');
    expect(
      messages.filter((message) => message.type === 'transaction').at(-1)!
        .composing,
    ).toBe(true);
  });

  it('batches column IME composition through the parent transaction', async () => {
    const markdown = [
      '<!-- synapse:columns ratio="50:50" -->',
      'Left',
      '<!-- synapse:column -->',
      'Right',
      '<!-- synapse:columns-end -->',
      '',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const content = document.querySelector<HTMLElement>('.synapse-column .cm-content')!;
    content.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true, data: '' }));
    window.synapseTest!.editColumn('left', '\n中文输入\n');
    content.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '中文输入' }));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const transaction = messages.filter((message) => message.type === 'transaction').at(-1)!;
    expect(transaction.composing).toBe(true);
    expect(window.synapseTest!.getText()).toContain('中文输入');
  });

  it('moves structural Markdown into a column through one parent history transaction', async () => {
    const table = '| A | B |\n| --- | --- |\n| 1 | 2 |\n';
    const markdown = [
      table.trimEnd(),
      '<!-- synapse:columns ratio="50:50" -->',
      'Left',
      '<!-- synapse:column -->',
      'Right',
      '<!-- synapse:columns-end -->',
      '',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    expect(window.synapseTest!.moveRangeToColumn(0, table.length, 'left', 0)).toBe(true);
    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'setMode',
      mode: 'reading',
      editable: false,
      focused: true,
    });
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(messages.filter((message) => message.type === 'error')).toEqual([]);
    expect(document.querySelectorAll('.synapse-column .synapse-table-frame')).toHaveLength(1);
    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'setMode',
      mode: 'editing',
      editable: true,
      focused: true,
    });
    expect(window.synapseTest!.undo()).toBe(true);
    expect(window.synapseTest!.getText()).toBe(markdown);
  });

  it('keeps user host commands in history but excludes external refreshes', async () => {
    window.synapseHost!.receive(initialize('Alpha', 'editing'));
    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'replaceDocument',
      generation: 1,
      revision: 1,
      markdown: 'Alpha **bold**',
      addToHistory: true,
    });
    expect(window.synapseTest!.undo()).toBe(true);
    expect(window.synapseTest!.getText()).toBe('Alpha');

    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'replaceDocument',
      generation: 1,
      revision: 2,
      markdown: 'External',
      addToHistory: false,
    });
    expect(window.synapseTest!.undo()).toBe(false);
    expect(window.synapseTest!.getText()).toBe('External');
  });

  it('owns find navigation and replacement in CodeMirror search state', async () => {
    window.synapseHost!.receive(initialize('Alpha alpha Alpha', 'editing'));
    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'setSearch',
      query: 'Alpha',
      replacement: 'Omega',
      caseSensitive: false,
      wholeWord: true,
      visible: true,
    });
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    let state = messages.filter((message) => message.type === 'commandState').at(-1)!;
    expect((state.search as { matches: unknown[] }).matches).toHaveLength(3);
    expect((state.search as { currentIndex: number }).currentIndex).toBe(0);
    expect(document.querySelectorAll('.synapse-search-match')).toHaveLength(3);

    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'navigateSearch',
      direction: 'next',
    });
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    state = messages.filter((message) => message.type === 'commandState').at(-1)!;
    expect((state.search as { currentIndex: number }).currentIndex).toBe(1);

    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'replaceSearch',
      all: true,
    });
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(window.synapseTest!.getText()).toBe('Omega Omega Omega');
    expect(window.synapseTest!.undo()).toBe(true);
    expect(window.synapseTest!.getText()).toBe('Alpha alpha Alpha');
  });

  it('projects CodeMirror search highlights into both column subviews', async () => {
    const markdown = [
      '<!-- synapse:columns ratio="50:50" -->',
      'Alpha left',
      '<!-- synapse:column -->',
      'Alpha right',
      '<!-- synapse:columns-end -->',
      '',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'reading'));
    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'setSearch',
      query: 'Alpha',
      replacement: '',
      caseSensitive: true,
      wholeWord: true,
      visible: true,
    });
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    expect(document.querySelectorAll('.synapse-column .synapse-search-match')).toHaveLength(2);
  });

  it('reports command and input-to-paint performance samples', async () => {
    window.synapseHost!.receive(initialize('Alpha', 'editing'));
    document.querySelector<HTMLElement>('.cm-content')!.dispatchEvent(
      new InputEvent('beforeinput', { bubbles: true, inputType: 'insertText', data: '!' }),
    );
    window.synapseTest!.insertText('!');
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    expect(messages.some((message) => message.type === 'commandState')).toBe(true);
    expect(messages.some((message) => message.type === 'performanceSample' && message.name === 'inputToPaint')).toBe(true);
  });

  it('deduplicates attachment requests for repeated visible images', async () => {
    const src = 'Note.assets/attachments/shared.png';
    window.synapseHost!.receive(initialize(
      `![first](${src}) ![second](${src})\n\nAfter`,
      'reading',
    ));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    expect(
      messages.filter((message) => message.type === 'attachmentRequest'),
    ).toHaveLength(1);
  });

  it('supports keyboard navigation inside the WebView context menu', async () => {
    window.synapseHost!.receive(initialize('Alpha', 'editing'));
    window.synapseTest!.setSelection(0, 5);
    document.querySelector<HTMLElement>('.cm-content')!.dispatchEvent(
      new MouseEvent('contextmenu', {
        bubbles: true,
        cancelable: true,
        clientX: 20,
        clientY: 20,
      }),
    );
    const menu = document.querySelector<HTMLElement>('.synapse-context-menu');
    const buttons = menu!.querySelectorAll<HTMLButtonElement>('button:not(:disabled)');

    expect(menu!.getAttribute('role')).toBe('menu');
    expect(document.activeElement).toBe(buttons[0]);
    menu!.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }));
    expect(document.activeElement).toBe(buttons[1]);
    const format = Array.from(buttons).find((button) =>
      button.querySelector('.synapse-context-label')?.textContent === '格式',
    )!;
    format.focus();
    format.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }));
    const submenu = format.parentElement!.querySelector<HTMLElement>('.synapse-context-submenu')!;
    expect(submenu.hidden).toBe(false);
    expect(document.activeElement).toBe(submenu.querySelector('button'));
    submenu.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true }));
    expect(document.activeElement).toBe(format);
    menu!.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    expect(document.querySelector('.synapse-context-menu')).toBeNull();
  });

  it('renders the complete polished document menu with stable checked state', async () => {
    const markdown = '**Alpha** Beta';
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    window.synapseTest!.setSelection(2, 7);

    const menu = openKeyboardContextMenu();
    const labels = Array.from(
      menu.querySelectorAll<HTMLButtonElement>(
        ':scope > button, :scope > .synapse-context-submenu-group > button',
      ),
    ).map((button) =>
      button.querySelector('.synapse-context-label')?.textContent,
    );
    expect(labels).toEqual([
      '撤销',
      '重做',
      '复制',
      '剪切',
      '粘贴',
      '以纯文本粘贴',
      '全选',
      '查找所选内容',
      '替换…',
      '插入',
      '格式',
      '段落',
      '列表',
    ]);
    expect(menu.querySelectorAll('[role="separator"]')).toHaveLength(3);
    expect(getComputedStyle(menu).backgroundColor).toBe(
      'rgba(58, 58, 62, 0.9)',
    );
    expect(getComputedStyle(menu).borderRadius).toBe('12px');
    expect(getComputedStyle(menu).fontSize).toBe('13px');
    const copyStyle = getComputedStyle(menuButton(menu, '复制'));
    expect(copyStyle.height).toBe('30px');
    expect(copyStyle.paddingLeft).toBe('6px');
    expect(copyStyle.paddingRight).toBe('10px');
    expect(copyStyle.gap).toBe('2px');
    expect(
      getComputedStyle(
        menuButton(menu, '复制').querySelector('.synapse-context-check')!,
      ).width,
    ).toBe('12px');
    expect(menuButton(menu, '复制').querySelector('svg')).toBeNull();
    expect(menuButton(menu, '以纯文本粘贴').textContent).toContain('⇧⌘V');

    menuButton(menu, '格式').click();
    const formatMenu = menuButton(menu, '格式').parentElement!
      .querySelector<HTMLElement>('.synapse-context-submenu')!;
    expect(menuButton(formatMenu, '加粗').getAttribute('aria-checked')).toBe(
      'true',
    );
    expect(menuButton(formatMenu, '加粗').textContent).toContain('⌘B');
    expect(menuButton(formatMenu, '斜体').textContent).toContain('⌘I');
  });

  it('reports surface interactions and accepts host menu dismissal without mutation', () => {
    window.synapseHost!.receive(initialize('Alpha Beta', 'editing'));
    window.synapseTest!.setSelection(0, 5);
    const content = document.querySelector<HTMLElement>('.cm-content')!;
    content.dispatchEvent(pointerEvent('pointerdown', 20, 20));
    expect(messages.some((message) => message.type === 'pointerInteraction'))
      .toBe(true);

    const menu = openKeyboardContextMenu();
    const scroll = document.querySelector<HTMLElement>('.cm-scroller')!;
    scroll.scrollTop = 37;
    const before = {
      text: window.synapseTest!.getText(),
      selection: window.synapseTest!.getSelection(),
      scrollTop: scroll.scrollTop,
    };

    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'dismissContextMenu',
    });

    expect(menu.isConnected).toBe(false);
    expect(window.synapseTest!.getText()).toBe(before.text);
    expect(window.synapseTest!.getSelection()).toEqual(before.selection);
    expect(scroll.scrollTop).toBe(before.scrollTop);
  });

  it('keeps read-only commands visible and disables every mutation', () => {
    window.synapseHost!.receive(initialize('Alpha Beta', 'reading'));
    window.synapseTest!.setSelection(0, 5);

    const menu = openKeyboardContextMenu();
    for (const label of [
      '撤销',
      '重做',
      '剪切',
      '粘贴',
      '以纯文本粘贴',
      '替换…',
      '插入',
      '格式',
      '段落',
      '列表',
    ]) {
      expect(menuButton(menu, label).disabled, label).toBe(true);
    }
    for (const label of ['复制', '全选', '查找所选内容']) {
      expect(menuButton(menu, label).disabled, label).toBe(false);
    }
  });

  it('preserves document and column selections in clipboard requests', () => {
    window.synapseHost!.receive(initialize('Alpha Beta', 'editing'));
    window.synapseTest!.setSelection(0, 5);
    const before = window.synapseTest!.getText();
    const menu = openKeyboardContextMenu();

    expect(window.synapseTest!.getSelection()).toEqual({ anchor: 0, head: 5 });
    menuButton(menu, '复制').click();
    expect(clipboardRequest('copy')).toMatchObject({
      target: 'document',
      revision: 0,
      selection: { anchor: 0, head: 5 },
    });
    expect(window.synapseTest!.getText()).toBe(before);

    const markdown = [
      '<!-- synapse:columns ratio="50:50" -->',
      'Left',
      '<!-- synapse:column -->',
      'Right',
      '<!-- synapse:columns-end -->',
      '',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    window.synapseTest!.selectColumn('right', 0, 5);
    const rightContent = document.querySelectorAll<HTMLElement>(
      '.synapse-column .cm-content',
    )[1];
    rightContent.dispatchEvent(new MouseEvent('contextmenu', {
      bubbles: true,
      cancelable: true,
      clientX: 20,
      clientY: 20,
    }));
    menuButton(
      document.querySelector<HTMLElement>('.synapse-context-menu')!,
      '复制',
    ).click();
    const rightFrom = markdown.indexOf('Right');
    expect(clipboardRequest('copy')).toMatchObject({
      target: 'document',
      selection: { anchor: rightFrom, head: rightFrom + 5 },
    });
  });

  it('applies table cut only after host success and rejects stale paste', async () => {
    const markdown = '| A | B |\n| --- | --- |\n| 1 | 2 |\n\nAfter';
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    let cell = tableCell(1, 0);
    selectCellText(cell, 0, 1);
    cell.dispatchEvent(new MouseEvent('contextmenu', {
      bubbles: true,
      cancelable: true,
      clientX: 20,
      clientY: 20,
    }));
    menuButton(document, '剪切').click();
    const failedCut = clipboardRequest('cut');
    expect(cell.textContent).toBe('1');
    resolveClipboard(failedCut, { outcome: 'failure' });
    await Promise.resolve();
    expect(window.synapseTest!.getText()).toBe(markdown);

    cell = tableCell(1, 0);
    selectCellText(cell, 0, 1);
    cell.dispatchEvent(new MouseEvent('contextmenu', {
      bubbles: true,
      cancelable: true,
      clientX: 20,
      clientY: 20,
    }));
    menuButton(document, '剪切').click();
    const successfulCut = clipboardRequest('cut');
    expect(cell.textContent).toBe('1');
    resolveClipboard(successfulCut, { hasText: true });
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(window.synapseTest!.getText()).toContain('|  | 2 |');

    cell = tableCell(1, 0);
    cell.dispatchEvent(new MouseEvent('contextmenu', {
      bubbles: true,
      cancelable: true,
      clientX: 20,
      clientY: 20,
    }));
    const availability = clipboardRequest('availability');
    resolveClipboard(availability, { hasText: true });
    await Promise.resolve();
    const paste = menuButton(document, '粘贴');
    expect(paste.disabled).toBe(false);
    paste.click();
    const pasteRequest = clipboardRequest('paste');
    const current = window.synapseTest!.getText();
    window.synapseHost!.receive({
      protocolVersion: 2,
      type: 'applyChanges',
      generation: 1,
      baseRevision: 1,
      revision: 2,
      changes: [{ from: current.length, to: current.length, insert: '\nExternal' }],
      addToHistory: false,
    });
    resolveClipboard(pasteRequest, { hasText: true, text: 'PASTE' });
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(window.synapseTest!.getText()).not.toContain('PASTE');
    expect(window.synapseTest!.getText()).toContain('External');
  });

  it('uses the exact image source and the remembered text caret for paste', async () => {
    const markdown = 'Before\n\n![one](one.png)\n\n![two](two.png)';
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    window.synapseTest!.setSelection(3, 3);
    const images = document.querySelectorAll<HTMLElement>(
      '.synapse-image-block',
    );

    images[1].dispatchEvent(new MouseEvent('contextmenu', {
      bubbles: true,
      cancelable: true,
      clientX: 20,
      clientY: 20,
    }));
    menuButton(document, '复制图片').click();
    const secondImageFrom = markdown.indexOf('![two]');
    expect(messages.filter((message) => message.type === 'imageAction').at(-1))
      .toMatchObject({
        action: 'copy',
        src: 'two.png',
        revision: 0,
        from: secondImageFrom,
        to: secondImageFrom + '![two](two.png)'.length,
      });

    images[1].dispatchEvent(new MouseEvent('contextmenu', {
      bubbles: true,
      cancelable: true,
      clientX: 20,
      clientY: 20,
    }));
    const availability = clipboardRequest('availability');
    resolveClipboard(availability, { hasText: true });
    await Promise.resolve();
    const paste = menuButton(document, '粘贴');
    expect(paste.disabled).toBe(false);
    paste.click();
    expect(clipboardRequest('paste')).toMatchObject({
      target: 'document',
      selection: { anchor: 3, head: 3 },
    });
  });

  it('marks destructive table actions and flips edge submenus into view', async () => {
    window.synapseHost!.receive(initialize(
      '| A | B |\n| --- | --- |\n| 1 | 2 |\n',
      'editing',
    ));
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    const bounds = vi.spyOn(
      HTMLElement.prototype,
      'getBoundingClientRect',
    ).mockImplementation(function (this: HTMLElement) {
      if (this.classList.contains('synapse-context-submenu')) {
        return rect(window.innerWidth - 40, window.innerHeight - 40, 220, 240);
      }
      if (this.classList.contains('synapse-context-submenu-group')) {
        return rect(window.innerWidth - 30, window.innerHeight - 50, 20, 30);
      }
      return rect(0, 0, 0, 0);
    });

    tableCell(1, 0).dispatchEvent(new MouseEvent('contextmenu', {
      bubbles: true,
      cancelable: true,
      clientX: window.innerWidth + 200,
      clientY: window.innerHeight + 200,
    }));
    const menu = document.querySelector<HTMLElement>('.synapse-context-menu')!;
    expect(Number.parseFloat(menu.style.left)).toBeLessThanOrEqual(
      window.innerWidth - 8,
    );
    expect(Number.parseFloat(menu.style.top)).toBeLessThanOrEqual(
      window.innerHeight - 8,
    );
    expect(menuButton(menu, '删除表格').dataset.destructive).toBe('true');
    const menuCss = Array.from(document.styleSheets)
      .flatMap((sheet) => Array.from(sheet.cssRules))
      .map((rule) => rule.cssText)
      .join('\n');
    expect(menuCss).toContain(
      '.synapse-context-menu button[data-destructive="true"]',
    );

    const row = menuButton(menu, '行');
    row.click();
    const submenu = row.parentElement!
      .querySelector<HTMLElement>('.synapse-context-submenu')!;
    expect(submenu.style.right).toBe('calc(100% + 6px)');
    expect(Number.parseFloat(submenu.style.top)).toBeLessThan(0);
    expect(menuButton(submenu, '删除行').dataset.destructive).toBe('true');
    bounds.mockRestore();
  });

  it('reorders table rows and columns with pointer drag handles', async () => {
    const markdown = [
      '| A | B |',
      '| :--- | ---: |',
      '| 1 | 2 |',
      '| 3 | 4 |',
      '',
      'After',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    let dataRows = Array.from(
      document.querySelectorAll<HTMLElement>('.synapse-table-frame table tr'),
    ).slice(1);
    setBounds(dataRows[0], rect(0, 100, 320, 40));
    setBounds(dataRows[1], rect(0, 140, 320, 40));
    let rowHandle = document.querySelector<HTMLElement>(
      '.synapse-table-row-handle[data-table-row="1"]',
    )!;
    rowHandle.dispatchEvent(pointerEvent('pointerdown', 8, 110));
    window.dispatchEvent(pointerEvent('pointermove', 8, 175));
    window.dispatchEvent(pointerEvent('pointerup', 8, 175));
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(window.synapseTest!.getText().indexOf('| 3 | 4 |')).toBeLessThan(
      window.synapseTest!.getText().indexOf('| 1 | 2 |'),
    );

    const resolvedHeaderCells = tableColumnParents();
    setBounds(resolvedHeaderCells[0], rect(100, 40, 100, 40));
    setBounds(resolvedHeaderCells[1], rect(200, 40, 100, 40));
    const columnHandle = document.querySelector<HTMLElement>(
      '.synapse-table-column-handle[data-table-column="0"]',
    )!;
    columnHandle.dispatchEvent(pointerEvent('pointerdown', 120, 42));
    window.dispatchEvent(pointerEvent('pointermove', 290, 42));
    window.dispatchEvent(pointerEvent('pointerup', 290, 42));
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(window.synapseTest!.getText()).toContain('| B | A |');
    expect(window.synapseTest!.getText()).toContain('| ---: | :--- |');
  });

  it('moves the complete table block with pointer drag feedback', async () => {
    const markdown = [
      '| A | B |',
      '| :--- | ---: |',
      '| 1 | 2 |',
      '',
      'After',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const editor = document.querySelector<HTMLElement>('.cm-editor')!;
    const scroller = document.querySelector<HTMLElement>('.cm-scroller')!;
    const content = document.querySelector<HTMLElement>('.cm-content')!;
    const after = Array.from(
      document.querySelectorAll<HTMLElement>('.cm-line'),
    ).find((line) => line.textContent === 'After')!;
    setBounds(editor, rect(0, 0, 640, 320));
    setBounds(scroller, rect(0, 0, 640, 320));
    setBounds(content, rect(0, 0, 640, 240));
    setBounds(after, rect(16, 180, 120, 32));
    const elementFromPoint = Object.getOwnPropertyDescriptor(
      document,
      'elementFromPoint',
    );
    Object.defineProperty(document, 'elementFromPoint', {
      configurable: true,
      value: () => after,
    });
    const handle = document.querySelector<HTMLElement>(
      '.synapse-table-block-handle',
    )!;

    handle.dispatchEvent(pointerEvent('pointerdown', 20, 20));
    window.dispatchEvent(pointerEvent('pointermove', 96, 196));
    expect(document.querySelector('.synapse-table-block-drop-indicator'))
      .not.toBeNull();
    window.dispatchEvent(pointerEvent('pointerup', 96, 196));
    if (elementFromPoint) {
      Object.defineProperty(document, 'elementFromPoint', elementFromPoint);
    } else {
      Reflect.deleteProperty(document, 'elementFromPoint');
    }
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    expect(window.synapseTest!.getText().indexOf('After')).toBeLessThan(
      window.synapseTest!.getText().indexOf('| A | B |'),
    );
    expect(window.synapseTest!.getText()).toContain(
      '| A | B |\n| :--- | ---: |\n| 1 | 2 |',
    );
    expect(document.querySelector('.synapse-table-dragging')).toBeNull();
    expect(document.querySelector('.synapse-table-block-drop-indicator'))
      .toBeNull();
  });

  it('auto-scrolls table pointer drags and fully cleans up cancellation', async () => {
    const markdown = [
      '| A | B |',
      '| --- | --- |',
      '| 1 | 2 |',
      '| 3 | 4 |',
      '',
      'After',
    ].join('\n');
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    const scroller = document.querySelector<HTMLElement>('.cm-scroller')!;
    setBounds(scroller, rect(0, 0, 1000, 800));
    scroller.scrollTop = 100;
    const dataRows = Array.from(
      document.querySelectorAll<HTMLElement>('.synapse-table-frame table tr'),
    ).slice(1);
    setBounds(dataRows[0], rect(0, 100, 320, 40));
    setBounds(dataRows[1], rect(0, 140, 320, 40));
    const handle = document.querySelector<HTMLElement>(
      '.synapse-table-row-handle[data-table-row="1"]',
    )!;
    handle.dispatchEvent(pointerEvent('pointerdown', 8, 110));
    window.dispatchEvent(pointerEvent('pointermove', 8, 790));
    await new Promise((resolve) => window.setTimeout(resolve, 10));

    expect(scroller.scrollTop).toBeGreaterThan(100);
    expect(handle.classList.contains('synapse-table-dragging')).toBe(true);
    window.dispatchEvent(new KeyboardEvent('keydown', {
      key: 'Escape',
      bubbles: true,
      cancelable: true,
    }));
    await new Promise((resolve) => window.setTimeout(resolve, 10));

    expect(window.synapseTest!.getText()).toBe(markdown);
    expect(document.querySelector('.synapse-table-dragging')).toBeNull();
    expect(document.querySelector('[class*="synapse-table-row-drop-"]'))
      .toBeNull();
  });
});

function initialize(
  markdown: string,
  mode: 'editing' | 'reading',
  focused = true,
): InitializeCommand {
  return {
    protocolVersion: 2,
    type: 'initialize',
    paneId: 'pane-1',
    noteId: 'note.md',
    generation: 1,
    revision: 0,
    markdown,
    selection: { anchor: markdown.length, head: markdown.length },
    mode,
    editable: mode === 'editing' && focused,
    focused,
    theme: {
      background: '#ffffff',
      surface: '#f7f7f7',
      text: '#111111',
      muted: '#777777',
      line: '#dddddd',
      accent: '#0066ff',
      codeBackground: '#f2f2f2',
      highlight: '#fff59d',
      fontSize: 14,
      fontFamily: 'sans-serif',
      contextMenu: {
        background: 'rgba(58,58,62,.9)',
        text: '#f7f7fa',
        disabledText: 'rgba(247,247,250,.4)',
        divider: 'rgba(255,255,255,.18)',
        border: 'rgba(255,255,255,.14)',
        danger: '#ff453a',
      },
    },
  };
}
