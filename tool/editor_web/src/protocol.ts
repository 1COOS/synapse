export const protocolVersion = 1;

export type EditorMode = 'editing' | 'reading';

export interface EditorChange {
  from: number;
  to: number;
  insert: string;
}

export interface EditorSelection {
  anchor: number;
  head: number;
}

export interface EditorSearchQuery {
  query: string;
  replacement: string;
  caseSensitive: boolean;
  wholeWord: boolean;
  visible: boolean;
}

export interface InitializeCommand {
  protocolVersion: number;
  type: 'initialize';
  paneId: string;
  noteId: string;
  generation: number;
  revision: number;
  markdown: string;
  selection: EditorSelection;
  mode: EditorMode;
  editable: boolean;
  focused: boolean;
  theme: EditorTheme;
}

export interface ApplyChangesCommand {
  protocolVersion: number;
  type: 'applyChanges';
  generation: number;
  baseRevision: number;
  revision: number;
  changes: EditorChange[];
  selection?: EditorSelection;
  addToHistory?: boolean;
}

export interface ReplaceDocumentCommand {
  protocolVersion: number;
  type: 'replaceDocument';
  generation: number;
  revision: number;
  markdown: string;
  selection?: EditorSelection;
  addToHistory?: boolean;
}

export interface EditorTheme {
  background: string;
  surface: string;
  text: string;
  muted: string;
  line: string;
  accent: string;
  codeBackground: string;
  highlight: string;
  fontSize: number;
  fontFamily: string;
}

export type HostCommand =
  | InitializeCommand
  | ApplyChangesCommand
  | ReplaceDocumentCommand
  | {
      protocolVersion: number;
      type: 'setMode';
      mode: EditorMode;
      editable: boolean;
      focused: boolean;
    }
  | { protocolVersion: number; type: 'setTheme'; theme: EditorTheme }
  | {
      protocolVersion: number;
      type: 'revealRange';
      from: number;
      to: number;
      focus: boolean;
    }
  | ({ protocolVersion: number; type: 'setSearch' } & EditorSearchQuery)
  | {
      protocolVersion: number;
      type: 'navigateSearch';
      direction: 'next' | 'previous';
    }
  | { protocolVersion: number; type: 'replaceSearch'; all: boolean }
  | { protocolVersion: number; type: 'closeSearch' }
  | { protocolVersion: number; type: 'flush'; requestId: number }
  | {
      protocolVersion: number;
      type: 'attachmentChunk';
      requestId: string;
      chunkIndex: number;
      chunkCount: number;
      mimeType: string;
      data: string;
    }
  | {
      protocolVersion: number;
      type: 'attachmentError';
      requestId: string;
      message: string;
    }
  | { protocolVersion: number; type: 'dispose' };

export interface EditorEventBase {
  protocolVersion: number;
  paneId: string;
  noteId: string;
  generation: number;
}

export type EditorEvent =
  | (EditorEventBase & { type: 'ready'; revision: number })
  | (EditorEventBase & {
      type: 'transaction';
      baseRevision: number;
      revision: number;
      clientSeq: number;
      changes: EditorChange[];
      selection: EditorSelection;
      composing: boolean;
      origin: string;
    })
  | (EditorEventBase & {
      type: 'selectionChanged';
      revision: number;
      selection: EditorSelection;
    })
  | (EditorEventBase & { type: 'focusChanged'; focused: boolean })
  | (EditorEventBase & {
      type: 'outlineChanged';
      revision: number;
      outline: Array<{ level: number; title: string; line: number; offset: number }>;
    })
  | (EditorEventBase & {
      type: 'commandState';
      revision: number;
      selection: EditorSelection;
      canUndo: boolean;
      canRedo: boolean;
      search: EditorSearchQuery & {
        currentIndex: number;
        matches: Array<{ from: number; to: number }>;
      };
    })
  | (EditorEventBase & {
      type: 'attachmentRequest';
      requestId: string;
      src: string;
    })
  | (EditorEventBase & {
      type: 'imageAction';
      action: 'copy' | 'cut' | 'resize' | 'move';
      src: string;
      revision: number;
      targetSrc?: string;
      beforeTarget?: boolean;
      width?: number;
    })
  | (EditorEventBase & {
      type: 'commandRequest';
      group: 'format' | 'paragraph' | 'list' | 'insert';
      command: string;
      revision: number;
      selection: EditorSelection;
    })
  | (EditorEventBase & { type: 'findRequest'; replace: boolean })
  | (EditorEventBase & {
      type: 'pasteImage';
      filename: string;
      mimeType: string;
      data: string;
      revision: number;
      selection: EditorSelection;
    })
  | (EditorEventBase & {
      type: 'flushAck';
      requestId: number;
      revision: number;
      clientSeq: number;
    })
  | (EditorEventBase & { type: 'openLink'; href: string })
  | (EditorEventBase & {
      type: 'performanceSample';
      name: string;
      durationMs: number;
    })
  | (EditorEventBase & { type: 'error'; message: string; stack?: string });

declare global {
  interface Window {
    SynapseBridge?: { postMessage(message: string): void };
    synapseHost?: { receive(command: HostCommand): void };
    synapseTest?: {
      getText(): string;
      getMode(): EditorMode;
      getSelection(): EditorSelection;
      insertText(text: string): void;
      measureInsert(text: string): number;
      undo(): boolean;
      setSelection(anchor: number, head: number): void;
      editColumn(side: 'left' | 'right', text: string): void;
      selectColumn(side: 'left' | 'right', anchor: number, head: number): void;
      selectAcrossColumns(
        anchorSide: 'left' | 'right',
        anchor: number,
        headSide: 'left' | 'right',
        head: number,
      ): void;
      getSelectedSource(): string;
      moveRangeToColumn(
        from: number,
        to: number,
        side: 'left' | 'right',
        offset: number,
      ): boolean;
    };
  }
}
