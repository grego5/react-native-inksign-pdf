import type {
  AddPagesOptions,
  AddPagesResult,
  InkSignViewHandle,
  ImagePageSize,
  PageInfo,
  PageType,
} from '../../src'

declare const handle: InkSignViewHandle
declare const addPagesResult: AddPagesResult

const pdfType: PageType = 'pdf'
const imageType: PageType = 'image'
const optionalOptions: AddPagesOptions = {}
const pdfOptions: AddPagesOptions = { type: pdfType }
const imageOptions: AddPagesOptions = { type: imageType }
const customImagePageSize: ImagePageSize = { width: 432, height: 648 }
const sizedImageOptions: AddPagesOptions = { type: imageType, imagePageSize: customImagePageSize }

const appendedWithDefaults: Promise<AddPagesResult> = handle.addPages()
const appendedPdf: Promise<AddPagesResult> = handle.addPages(pdfOptions)
const appendedImage: Promise<AddPagesResult> = handle.addPages(imageOptions)
const appendedSizedImage: Promise<AddPagesResult> = handle.addPages(sizedImageOptions)
const removed: Promise<PageInfo> = handle.removePage()
const moved: Promise<PageInfo> = handle.movePage(0)
const optionalPageInfo: PageInfo | undefined = addPagesResult.pageInfo

void optionalOptions
void appendedWithDefaults
void appendedPdf
void appendedImage
void appendedSizedImage
void removed
void moved
void optionalPageInfo

// @ts-expect-error Only the public PDF and image page types are supported.
const unsupportedType: AddPagesOptions = { type: 'text' }

// @ts-expect-error The mutable-page contract has no obsolete append alias.
handle.appendPages()

// @ts-expect-error The mutable-page contract has no obsolete delete alias.
handle.deletePage()

// @ts-expect-error A move destination is required.
handle.movePage()

void unsupportedType
