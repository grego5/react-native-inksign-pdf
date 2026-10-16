import type { HybridObject } from 'react-native-nitro-modules'
import type { AndroidFallbackFont, DocumentState, ImagePageSize, PageInfo, PageInputType, PageQuery, PageTextMethods } from './InkSignTypes'

export interface NamedFontSource {
  name: string
  uri: string
}

export interface DocumentOptions {
  /** Restricts actual input content; omission accepts PDFs and images. */
  type?: PageInputType
  /** Record tracked edits for undo/redo, independent of viewer attachment. Defaults to true. */
  recordHistory?: boolean
  /** Session-only tag assigned to every initial page. */
  tag?: string
  imagePageSize?: ImagePageSize
  targetDpi?: number
  jpegQuality?: number
  androidFallbackFont?: AndroidFallbackFont
  /** Initial inputs load asynchronously before subsequent commands. Omission or [] creates an empty owner. */
  sources?: string[]
}

export interface DocumentAddPagesOptions {
  /** Restricts actual input content; omission accepts PDFs and images. */
  type?: PageInputType
  /** Session-only tag assigned to every page imported by this call. */
  tag?: string
  /** Ordered explicit inputs bypass UI; omission selects natively, and [] imports nothing. */
  sources?: string[]
  imagePageSize?: ImagePageSize
  targetDpi?: number
  jpegQuality?: number
}

export interface DocumentAddPagesResult {
  addedPageCount: number
  pageCount: number
}

export interface DocumentPage extends HybridObject<{ ios: 'swift'; android: 'kotlin' }>, PageTextMethods {
  getState(): PageInfo
  undo(): void
  redo(): void
  clear(): void
  clearInk(): void
}

export interface InkSignDocument extends HybridObject<{ ios: 'swift'; android: 'kotlin' }> {
  getState(): DocumentState
  readonly pageCount: number
  getPage(index: PageQuery): Promise<DocumentPage>
  /** Reads matching IDs in current document order without preparing analysis. */
  getPageIdsByTag(tag: string): string[]
  loadFonts(fonts: NamedFontSource[]): Promise<void>
  /** Imports all inputs atomically in order, preserving viewer selection. Omitted sources
   * present native multiple selection without requiring a viewer. User cancellation
   * returns zero added pages with the current count; lifecycle cancellation rejects
   * operation_cancelled. Unsupported/type-mismatched content rejects unsupported_content.
   */
  addPages(options?: DocumentAddPagesOptions): Promise<DocumentAddPagesResult>
  removePage(index: number): Promise<void>
  movePage(fromIndex: number, toIndex: number): Promise<void>
  rotatePage(index: number, degrees: number): Promise<void>
  /** Returns a caller-owned temporary file; close never deletes successful outputs. */
  finalize(): Promise<string>
  /** Terminal and idempotent. Drains admitted work and waits for resource cleanup. */
  close(): Promise<void>
}

export interface InkSignDocumentFactory extends HybridObject<{ ios: 'swift'; android: 'kotlin' }> {
  /** Returns an owner synchronously and queues any initial sources before later commands. */
  createDocument(options?: DocumentOptions): InkSignDocument
}
