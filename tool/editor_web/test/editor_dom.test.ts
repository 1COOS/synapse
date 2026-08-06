// @vitest-environment jsdom

import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

import type { InitializeCommand } from '../src/protocol';

const messages: Array<Record<string, unknown>> = [];

beforeAll(async () => {
  vi.stubGlobal('ResizeObserver', class {
    observe() {}
    unobserve() {}
    disconnect() {}
  });
  vi.stubGlobal('requestAnimationFrame', (callback: FrameRequestCallback) =>
    window.setTimeout(() => callback(performance.now()), 0));
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
});

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

  it('updates the same editor state when switching modes', async () => {
    const markdown = '# Heading\n\nParagraph';
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    window.synapseTest!.insertText(' edited');
    window.synapseHost!.receive({
      protocolVersion: 1,
      type: 'setMode',
      mode: 'reading',
      editable: false,
      focused: true,
    });
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    expect(window.synapseTest!.getText()).toContain(' edited');
    expect(window.synapseTest!.getMode()).toBe('reading');
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

    const cell = document.querySelector<HTMLElement>('.synapse-table-frame td');
    expect(cell).not.toBeNull();
    cell!.textContent = 'Edited';
    cell!.dispatchEvent(new FocusEvent('blur'));

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
    const cell = document.querySelector<HTMLElement>('.synapse-table-frame td');
    expect(table?.style.width).toBe('720px');
    cell!.textContent = 'Edited';
    cell!.dispatchEvent(new FocusEvent('blur'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    expect(window.synapseTest!.getText()).toContain('<!-- synapse-table width="720" -->');
    expect(window.synapseTest!.getText()).toContain('| :--- | ---: |');
    expect(window.synapseTest!.getText()).toContain('| Edited | 2 |');
  });

  it('rebuilds compound widgets when editable mode changes', async () => {
    const markdown = '| A | B |\n| --- | --- |\n| 1 | 2 |\n\nAfter';
    window.synapseHost!.receive(initialize(markdown, 'editing'));
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(document.querySelector<HTMLElement>('.synapse-table-frame td')!.contentEditable).toBe('true');

    window.synapseHost!.receive({
      protocolVersion: 1,
      type: 'setMode',
      mode: 'reading',
      editable: false,
      focused: true,
    });
    await new Promise((resolve) => window.setTimeout(resolve, 20));

    expect(document.querySelector<HTMLElement>('.synapse-table-frame td')!.contentEditable).not.toBe('true');
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
      protocolVersion: 1,
      type: 'setMode',
      mode: 'reading',
      editable: false,
      focused: true,
    });
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(messages.filter((message) => message.type === 'error')).toEqual([]);
    expect(document.querySelectorAll('.synapse-column .synapse-table-frame')).toHaveLength(1);
    window.synapseHost!.receive({
      protocolVersion: 1,
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
      protocolVersion: 1,
      type: 'replaceDocument',
      generation: 1,
      revision: 1,
      markdown: 'Alpha **bold**',
      addToHistory: true,
    });
    expect(window.synapseTest!.undo()).toBe(true);
    expect(window.synapseTest!.getText()).toBe('Alpha');

    window.synapseHost!.receive({
      protocolVersion: 1,
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
      protocolVersion: 1,
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
      protocolVersion: 1,
      type: 'navigateSearch',
      direction: 'next',
    });
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    state = messages.filter((message) => message.type === 'commandState').at(-1)!;
    expect((state.search as { currentIndex: number }).currentIndex).toBe(1);

    window.synapseHost!.receive({
      protocolVersion: 1,
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
      protocolVersion: 1,
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
    const format = Array.from(buttons).find((button) => button.textContent === '格式 ›')!;
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

  it('reorders table rows and columns with drag handles', async () => {
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

    let rowHandles = document.querySelectorAll<HTMLElement>('.synapse-table-row-handle[draggable="true"]');
    rowHandles[0].dispatchEvent(new Event('dragstart', { bubbles: true }));
    rowHandles[1].dispatchEvent(new Event('drop', { bubbles: true, cancelable: true }));
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(window.synapseTest!.getText().indexOf('| 3 | 4 |')).toBeLessThan(
      window.synapseTest!.getText().indexOf('| 1 | 2 |'),
    );

    const columnHandles = document.querySelectorAll<HTMLElement>('.synapse-table-column-handle');
    columnHandles[0].dispatchEvent(new Event('dragstart', { bubbles: true }));
    columnHandles[1].dispatchEvent(new Event('drop', { bubbles: true, cancelable: true }));
    await new Promise((resolve) => window.setTimeout(resolve, 20));
    expect(window.synapseTest!.getText()).toContain('| B | A |');
    expect(window.synapseTest!.getText()).toContain('| ---: | :--- |');
  });
});

function initialize(
  markdown: string,
  mode: 'editing' | 'reading',
): InitializeCommand {
  return {
    protocolVersion: 1,
    type: 'initialize',
    paneId: 'pane-1',
    noteId: 'note.md',
    generation: 1,
    revision: 0,
    markdown,
    selection: { anchor: markdown.length, head: markdown.length },
    mode,
    editable: mode === 'editing',
    focused: true,
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
    },
  };
}
