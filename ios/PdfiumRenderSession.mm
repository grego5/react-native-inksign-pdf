#import "PdfiumRenderSession.h"

#include "../core/pdfium-adapter/PdfiumDocumentSession.hpp"
#include "../core/pdfium-adapter/PdfiumPageAssembler.hpp"

#include <dispatch/dispatch.h>

#include <cstdint>
#include <cmath>
#include <cstddef>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <utility>
#include <vector>

using margelo::nitro::inksignpdf::pdfium::PdfiumDocumentSession;
using margelo::nitro::inksignpdf::pdfium::PdfiumError;
using margelo::nitro::inksignpdf::pdfium::PdfiumErrorCode;
using margelo::nitro::inksignpdf::pdfium::PdfiumFallbackFont;
using margelo::nitro::inksignpdf::pdfium::PdfiumPageMetadata;
using margelo::nitro::inksignpdf::pdfium::PdfiumPageRenderRequest;
using margelo::nitro::inksignpdf::pdfium::PdfiumAppendInput;
using margelo::nitro::inksignpdf::pdfium::PdfiumAppendInputType;
using margelo::nitro::inksignpdf::pdfium::PdfiumImagePlacement;
using margelo::nitro::inksignpdf::pdfium::PdfiumPageAssembler;
using margelo::nitro::inksignpdf::pdfium::PdfiumPageAssemblyCommand;
using margelo::nitro::inksignpdf::pdfium::PdfiumPageAssemblyOperation;

NSErrorDomain const InkSignPdfPdfiumErrorDomain =
    @"com.margelo.nitro.inksignpdf.pdfium";
NSInteger const InkSignPdfPdfiumInvalidFallbackFontErrorCode =
    static_cast<NSInteger>(PdfiumErrorCode::InvalidFallbackFont);

namespace {

const void *const kPdfiumQueueKey = &kPdfiumQueueKey;

NSInteger errorCode(PdfiumErrorCode code) {
  return static_cast<NSInteger>(code);
}

NSError *makeError(const PdfiumError &error) {
  NSString *message = error.message.empty()
      ? @"PDFium operation failed"
      : [NSString stringWithUTF8String:error.message.c_str()];
  return [NSError errorWithDomain:InkSignPdfPdfiumErrorDomain
                              code:errorCode(error.code)
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

void assignError(NSError **destination, const PdfiumError &error) {
  if (destination != nullptr) *destination = makeError(error);
}

struct PdfiumSessionState final {
  id queueOwner = nil;
  std::unique_ptr<PdfiumDocumentSession> session;
  std::size_t pageCount = 0;
  bool closed = false;

  dispatch_queue_t queue() const {
    return (dispatch_queue_t)queueOwner;
  }
};

PdfiumError closedError() {
  return {PdfiumErrorCode::Closed, "PDFium session is closed"};
}

NSArray<NSValue *> *assemblePDFData(
    NSData *data,
    NSInteger operation,
    NSUInteger pageIndex,
    NSUInteger destinationIndex,
    NSArray<NSDictionary<NSString *, id> *> *appendInputs,
    NSURL *scratchURL,
    BOOL allowsEmptyBase,
    NSError **error) {
  if (data == nil || (data.length == 0 && !allowsEmptyBase) || scratchURL == nil ||
      !scratchURL.isFileURL || scratchURL.path.length == 0 ||
      operation < 0 || operation > 2) {
    PdfiumError invalid{PdfiumErrorCode::InvalidInput,
                        "Invalid PDF page assembly input"};
    assignError(error, invalid);
    return nil;
  }

  std::vector<std::uint8_t> inputBytes;
  const auto *source = static_cast<const std::uint8_t *>(data.bytes);
  if (source != nullptr && data.length > 0) {
    inputBytes.assign(source, source + data.length);
  }

  PdfiumPageAssemblyCommand command;
  command.operation = static_cast<PdfiumPageAssemblyOperation>(operation);
  command.pageIndex = pageIndex;
  command.destinationIndex = destinationIndex;
  command.appendInputs.reserve(appendInputs.count);
  for (NSDictionary<NSString *, id> *value in appendInputs) {
    NSString *type = [[value[@"type"] class] isSubclassOfClass:NSString.class]
        ? value[@"type"] : nil;
    NSData *bytes = [[value[@"data"] class] isSubclassOfClass:NSData.class]
        ? value[@"data"] : nil;
    if (type == nil || bytes == nil || bytes.length == 0 ||
        ![type isEqualToString:@"pdf"] && ![type isEqualToString:@"image"]) {
      PdfiumError invalid{PdfiumErrorCode::InvalidInput,
                          "Invalid PDF page append input"};
      assignError(error, invalid);
      return nil;
    }
    PdfiumAppendInput append;
    append.type = [type isEqualToString:@"pdf"]
        ? PdfiumAppendInputType::Pdf : PdfiumAppendInputType::Image;
    const auto *bytesBegin = static_cast<const std::uint8_t *>(bytes.bytes);
    append.bytes.assign(bytesBegin, bytesBegin + bytes.length);
    if (auto number = value[@"pageWidth"];
        [[number class] isSubclassOfClass:NSNumber.class]) {
      append.pageWidth = [number doubleValue];
    }
    if (auto number = value[@"pageHeight"];
        [[number class] isSubclassOfClass:NSNumber.class]) {
      append.pageHeight = [number doubleValue];
    }
    double *components[] = {&append.placement.a, &append.placement.b,
                            &append.placement.c, &append.placement.d,
                            &append.placement.e, &append.placement.f};
    const char *keys[] = {"a", "b", "c", "d", "e", "f"};
    for (std::size_t index = 0; index < 6; ++index) {
      NSString *key = [NSString stringWithUTF8String:keys[index]];
      id number = value[key];
      if ([[number class] isSubclassOfClass:NSNumber.class]) {
        *components[index] = [number doubleValue];
      }
    }
    command.appendInputs.push_back(std::move(append));
  }

  const char *scratchPath = scratchURL.path.fileSystemRepresentation;
  if (scratchPath == nullptr || scratchPath[0] == '\0') {
    PdfiumError invalid{PdfiumErrorCode::InvalidInput,
                        "Invalid PDF page assembly output path"};
    assignError(error, invalid);
    return nil;
  }
  auto result = PdfiumPageAssembler::assemble(
      std::move(inputBytes), std::move(command), scratchPath);
  if (!result.ok()) {
    assignError(error, result.error);
    return nil;
  }
  NSMutableArray<NSValue *> *sizes = [NSMutableArray arrayWithCapacity:result.pages.size()];
  for (const auto &page : result.pages) {
    [sizes addObject:[NSValue valueWithCGSize:CGSizeMake(page.width, page.height)]];
  }
  return sizes;
}

}  // namespace

@interface InkSignPdfPdfiumSession ()
- (instancetype)initWithState:(PdfiumSessionState *)state NS_DESIGNATED_INITIALIZER;
@end

@implementation InkSignPdfPdfiumSession

+ (NSArray<NSValue *> *)assembleNewPDFWithAppendInputs:(NSArray<NSDictionary<NSString *, id> *> *)appendInputs
                                            scratchURL:(NSURL *)scratchURL
                                                 error:(NSError **)error {
  return assemblePDFData([NSData data],
                         static_cast<NSInteger>(PdfiumPageAssemblyOperation::Append),
                         0, 0, appendInputs, scratchURL, YES, error);
}

- (instancetype)initWithState:(PdfiumSessionState *)state {
  self = [super init];
  if (self != nil) _state = state;
  return self;
}

- (nullable instancetype)initWithData:(NSData *)data
                      fallbackFontPath:(NSString *)fallbackFontPath
                       collectionIndex:(double)collectionIndex
                                 error:(NSError **)error {
  PdfiumSessionState *state = new PdfiumSessionState();
  dispatch_queue_t queue = dispatch_queue_create(
      "com.margelo.nitro.inksignpdf.pdfium", DISPATCH_QUEUE_SERIAL);
  state->queueOwner = queue;
  dispatch_queue_set_specific(queue, kPdfiumQueueKey, state, nullptr);

  __block PdfiumError openError;
  dispatch_sync(queue, ^{
    const auto *source = static_cast<const std::uint8_t *>(data.bytes);
    std::vector<std::uint8_t> documentBytes;
    if (source != nullptr && data.length > 0) {
      documentBytes.assign(source, source + data.length);
    }

    std::optional<PdfiumFallbackFont> fallback;
    if (fallbackFontPath != nil) {
      if (fallbackFontPath.length == 0) {
        openError = {PdfiumErrorCode::InvalidFallbackFont,
                     "Invalid fallback font: path must not be empty"};
        return;
      }
      const char *path = fallbackFontPath.fileSystemRepresentation;
      if (path == nullptr || path[0] == '\0') {
        openError = {PdfiumErrorCode::InvalidFallbackFont,
                     "Invalid fallback font: path is not representable"};
        return;
      }
      if (!std::isfinite(collectionIndex) || collectionIndex < 0.0 ||
          std::floor(collectionIndex) != collectionIndex ||
          collectionIndex > static_cast<double>((std::numeric_limits<std::size_t>::max)())) {
        openError = {PdfiumErrorCode::InvalidFallbackFont,
                     "Invalid fallback font: collection index is invalid"};
        return;
      }
      fallback = PdfiumFallbackFont{
          path, static_cast<std::size_t>(collectionIndex)};
    }

    auto opened = PdfiumDocumentSession::open(
        std::move(documentBytes), {}, std::move(fallback));
    openError = std::move(opened.error);
    state->session = std::move(opened.session);
    if (state->session != nullptr) state->pageCount = state->session->pageCount();
  });

  if (state->session == nullptr || !openError.ok()) {
    if (openError.ok()) {
      openError = {PdfiumErrorCode::DocumentOpenFailed,
                   "PDFium could not open the document"};
    }
    assignError(error, openError);
    delete state;
    return nil;
  }

  return [self initWithState:state];
}

- (NSUInteger)pageCount {
  PdfiumSessionState *state = static_cast<PdfiumSessionState *>(_state);
  if (state == nullptr) return 0;
  __block std::size_t count = 0;
  dispatch_queue_t queue = state->queue();
  void (^work)(void) = ^{
    if (!state->closed && state->session != nullptr) {
      count = state->pageCount;
    }
  };
  if (dispatch_get_specific(kPdfiumQueueKey) == state) work();
  else dispatch_sync(queue, work);
  return static_cast<NSUInteger>(count);
}

- (BOOL)pageSizeForPage:(NSUInteger)pageIndex
                  size:(CGSize *)size
                 error:(NSError **)error {
  PdfiumSessionState *state = static_cast<PdfiumSessionState *>(_state);
  if (state == nullptr) {
    assignError(error, closedError());
    return NO;
  }

  __block PdfiumError result;
  __block PdfiumPageMetadata metadata;
  dispatch_queue_t queue = state->queue();
  void (^work)(void) = ^{
    if (state->closed || state->session == nullptr) {
      result = closedError();
      return;
    }
    result = state->session->inspectPage(pageIndex, metadata);
  };
  if (dispatch_get_specific(kPdfiumQueueKey) == state) work();
  else dispatch_sync(queue, work);
  if (!result.ok()) {
    assignError(error, result);
    return NO;
  }
  *size = CGSizeMake(metadata.width, metadata.height);
  return YES;
}

- (BOOL)renderPage:(NSUInteger)pageIndex
              width:(int32_t)width
             height:(int32_t)height
             stride:(int32_t)stride
      pageToDevice:(CGAffineTransform)pageToDevice
              clip:(CGRect)clip
         background:(uint32_t)background
              flags:(uint32_t)flags
             pixels:(NSMutableData *)pixels
              error:(NSError **)error {
  PdfiumSessionState *state = static_cast<PdfiumSessionState *>(_state);
  if (state == nullptr) {
    assignError(error, closedError());
    return NO;
  }

  __block PdfiumError result;
  dispatch_queue_t queue = state->queue();
  void (^work)(void) = ^{
    if (state->closed || state->session == nullptr) {
      result = closedError();
      return;
    }
    if (pixels == nil) {
      result = {PdfiumErrorCode::InvalidInput,
                "PDFium render pixels must not be nil"};
      return;
    }
    PdfiumPageRenderRequest request;
    request.pageIndex = pageIndex;
    request.width = width;
    request.height = height;
    request.stride = stride;
    request.pageToDevice = {pageToDevice.a, pageToDevice.b, pageToDevice.c,
                            pageToDevice.d, pageToDevice.tx, pageToDevice.ty};
    request.clip = {CGRectGetMinX(clip), CGRectGetMinY(clip),
                    CGRectGetMaxX(clip), CGRectGetMaxY(clip)};
    request.background = background;
    request.flags = flags;
    request.bgra = std::span<std::uint8_t>(
        static_cast<std::uint8_t *>(pixels.mutableBytes), pixels.length);
    result = state->session->renderPage(request);
  };
  if (dispatch_get_specific(kPdfiumQueueKey) == state) work();
  else dispatch_sync(queue, work);
  if (!result.ok()) {
    assignError(error, result);
    return NO;
  }
  return YES;
}

- (NSArray<NSValue *> *)assemblePDFData:(NSData *)data
                              operation:(NSInteger)operation
                               pageIndex:(NSUInteger)pageIndex
                         destinationIndex:(NSUInteger)destinationIndex
                             appendInputs:(NSArray<NSDictionary<NSString *, id> *> *)appendInputs
                               scratchURL:(NSURL *)scratchURL
                                    error:(NSError **)error {
  return assemblePDFData(data, operation, pageIndex, destinationIndex,
                         appendInputs, scratchURL, NO, error);
}

- (void)close {
  PdfiumSessionState *state = static_cast<PdfiumSessionState *>(_state);
  if (state == nullptr) return;
  dispatch_queue_t queue = state->queue();
  void (^work)(void) = ^{
    if (state->closed) return;
    state->closed = true;
    if (state->session != nullptr) {
      state->session->close();
      state->session.reset();
    }
    state->pageCount = 0;
  };
  if (dispatch_get_specific(kPdfiumQueueKey) == state) work();
  else dispatch_sync(queue, work);
}

- (void)dealloc {
  [self close];
  PdfiumSessionState *state = static_cast<PdfiumSessionState *>(_state);
  delete state;
  _state = nullptr;
}

@end
