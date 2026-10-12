import type { HybridObject } from 'react-native-nitro-modules'
import type { AndroidFallbackFont, DocumentState, ImagePageSize, PageInfo, PageTextMethods } from './InkSignView.nitro'

export interface NamedFontSource {
  name: string
  uri: string
}

export interface DocumentOpenOptions {
  imagePageSize?: ImagePageSize
  targetDpi?: number
  jpegQuality?: number
  androidFallbackFont?: AndroidFallbackFont
}

export interface DocumentAddPagesOptions {
  sources: string[]
  imagePageSize?: ImagePageSize
  targetDpi?: number
  jpegQuality?: number
}

export interface DocumentAddPagesResult {
  addedPageCount: number
  pageCount: number
}

export interface DocumentPage extends HybridObject<{ android: 'kotlin' }>, PageTextMethods {
  getState(): PageInfo
}

export interface InkSignDocument extends HybridObject<{ android: 'kotlin' }> {
  getState(): DocumentState
  readonly pageCount: number
  getPage(index: number): Promise<DocumentPage>
  loadFonts(fonts: NamedFontSource[]): Promise<void>
  addPages(options: DocumentAddPagesOptions): Promise<DocumentAddPagesResult>
  removePage(index: number): Promise<void>
  movePage(fromIndex: number, toIndex: number): Promise<void>
  rotatePage(index: number, degrees: number): Promise<void>
  /** Returns a caller-owned temporary file; close never deletes successful outputs. */
  finalize(): Promise<string>
  /** Terminal and idempotent. Drains admitted work and waits for resource cleanup. */
  close(): Promise<void>
}

export interface InkSignDocumentFactory extends HybridObject<{ android: 'kotlin' }> {
  openDoc(uri: string, options?: DocumentOpenOptions): Promise<InkSignDocument>
}
