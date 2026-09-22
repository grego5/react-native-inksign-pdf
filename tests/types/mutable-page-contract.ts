import type {
  AddPagesOptions,
  AddPagesResult,
  InkSignViewHandle,
  PageInfo,
  PageType,
} from '../../src'

declare const handle: InkSignViewHandle

const pdfType: PageType = 'pdf'
const imageType: PageType = 'image'
const optionalOptions: AddPagesOptions = {}
const pdfOptions: AddPagesOptions = { type: pdfType }
const imageOptions: AddPagesOptions = { type: imageType }

const appendedWithDefaults: Promise<AddPagesResult> = handle.addPages()
const appendedPdf: Promise<AddPagesResult> = handle.addPages(pdfOptions)
const appendedImage: Promise<AddPagesResult> = handle.addPages(imageOptions)
const scanned: Promise<AddPagesResult> = handle.scanPages()
const removed: Promise<PageInfo> = handle.removePage()
const moved: Promise<PageInfo> = handle.movePage(0)

void optionalOptions
void appendedWithDefaults
void appendedPdf
void appendedImage
void scanned
void removed
void moved

// @ts-expect-error Only the public PDF and image page types are supported.
const unsupportedType: AddPagesOptions = { type: 'text' }

// @ts-expect-error The mutable-page contract has no obsolete append alias.
handle.appendPages()

// @ts-expect-error The mutable-page contract has no obsolete delete alias.
handle.deletePage()

// @ts-expect-error A move destination is required.
handle.movePage()

void unsupportedType
