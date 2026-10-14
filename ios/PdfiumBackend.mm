#import "PdfiumBackend.h"

#include "pdfium-adapter/PdfiumDocumentSession.hpp"
#include "pdfium-adapter/PdfiumPageAssembler.hpp"
#include "pdfium-adapter/PdfiumContentWriter.hpp"
#include <cmath>
#include <cstring>
#include <exception>
#include <limits>
#include <string_view>

namespace pdfium = margelo::nitro::inksignpdf::pdfium;

namespace {
NSString *errorName(pdfium::PdfiumErrorCode code) {
  switch (code) {
    case pdfium::PdfiumErrorCode::InvalidInput: return @"invalid_pdf";
    case pdfium::PdfiumErrorCode::InvalidPageIndex: return @"page_not_found";
    case pdfium::PdfiumErrorCode::DocumentOpenFailed: return @"pdf_load_failed";
    case pdfium::PdfiumErrorCode::PageOpenFailed: return @"pdf_page_load_failed";
    case pdfium::PdfiumErrorCode::Closed: return @"operation_cancelled";
    case pdfium::PdfiumErrorCode::LastPageRequired: return @"last_page_required";
    case pdfium::PdfiumErrorCode::InvalidAssemblyCommand: return @"invalid_page_operation";
    case pdfium::PdfiumErrorCode::SaveFailed: return @"pdf_write_failed";
    case pdfium::PdfiumErrorCode::ValidationFailed: return @"pdf_validation_failed";
    case pdfium::PdfiumErrorCode::UnsupportedText: return @"unsupported_text";
    default: return @"pdfium_operation_failed";
  }
}

void report(NSError **error, const pdfium::PdfiumError& failure) {
  if (!error) return;
  NSString *message = [[NSString alloc] initWithBytes:failure.message.data()
                                             length:failure.message.size()
                                           encoding:NSUTF8StringEncoding];
  NSString *name = errorName(failure.code);
  *error = [NSError errorWithDomain:@"InkSignPdf.Pdfium" code:static_cast<NSInteger>(failure.code)
                           userInfo:@{NSLocalizedDescriptionKey:
                               [NSString stringWithFormat:@"%@: %@", name, message ?: @"PDFium operation failed"],
                                      @"code": name}];
}

std::vector<std::uint8_t> ownedBytes(NSData *data) {
  std::vector<std::uint8_t> bytes(data.length);
  if (data.length) std::memcpy(bytes.data(), data.bytes, data.length);
  return bytes;
}
}

@interface InkSignPdfPdfiumPageMetadata ()
- (instancetype)initWithMetadata:(const pdfium::PdfiumPageMetadata&)metadata;
@end
@implementation InkSignPdfPdfiumPageMetadata
- (instancetype)initWithMetadata:(const pdfium::PdfiumPageMetadata&)metadata {
  if ((self = [super init])) {
    _pageIndex = static_cast<NSInteger>(metadata.pageIndex);
    _visibleBox = CGRectMake(metadata.visibleLeft, metadata.visibleBottom,
      metadata.visibleRight - metadata.visibleLeft, metadata.visibleTop - metadata.visibleBottom);
    _mediaBox = CGRectMake(metadata.mediaBoxLeft, metadata.mediaBoxBottom,
                           metadata.mediaBoxRight - metadata.mediaBoxLeft,
                           metadata.mediaBoxTop - metadata.mediaBoxBottom);
    _rotation = metadata.rotation * 90;
    _displaySize = CGSizeMake(metadata.width, metadata.height);
  }
  return self;
}
@end

@interface InkSignPdfPdfiumGlyph ()
- (instancetype)initWithSnapshot:(const pdfium::PdfiumPageAnalysisSnapshot&)snapshot index:(std::size_t)index;
@end
@implementation InkSignPdfPdfiumGlyph
- (instancetype)initWithSnapshot:(const pdfium::PdfiumPageAnalysisSnapshot&)snapshot index:(std::size_t)index {
  if ((self = [super init])) {
    _scalar = static_cast<uint32_t>(snapshot.text[index]);
    _visualRow = snapshot.visualRows[index];
    const auto& bounds = snapshot.characterBounds[index];
    _hasBounds = bounds.has_value();
    _bounds = bounds ? CGRectMake(bounds->left, bounds->top, bounds->right - bounds->left,
                                  bounds->bottom - bounds->top) : CGRectZero;
  }
  return self;
}
@end

@interface InkSignPdfPdfiumRule ()
- (instancetype)initWithSegment:(const pdfium::PdfiumRuleSegment&)segment;
@end
@implementation InkSignPdfPdfiumRule
- (instancetype)initWithSegment:(const pdfium::PdfiumRuleSegment&)segment {
  if ((self = [super init])) {
    _start = CGPointMake(segment.startX, segment.startY);
    _end = CGPointMake(segment.endX, segment.endY);
  }
  return self;
}
@end

@interface InkSignPdfPdfiumAnalysis ()
- (instancetype)initWithMetadata:(const pdfium::PdfiumPageMetadata&)metadata
                        snapshot:(const pdfium::PdfiumPageAnalysisSnapshot&)snapshot;
@end
@implementation InkSignPdfPdfiumAnalysis
- (instancetype)initWithMetadata:(const pdfium::PdfiumPageMetadata&)metadata
                        snapshot:(const pdfium::PdfiumPageAnalysisSnapshot&)snapshot {
  if ((self = [super init])) {
    _metadata = [[InkSignPdfPdfiumPageMetadata alloc] initWithMetadata:metadata];
    NSMutableArray *glyphs = [NSMutableArray arrayWithCapacity:snapshot.text.size()];
    for (std::size_t index = 0; index < snapshot.text.size(); ++index)
      [glyphs addObject:[[InkSignPdfPdfiumGlyph alloc] initWithSnapshot:snapshot index:index]];
    _glyphs = [glyphs copy];
    NSMutableArray *tops = [NSMutableArray arrayWithCapacity:snapshot.visualRowTops.size()];
    NSMutableArray *bottoms = [NSMutableArray arrayWithCapacity:snapshot.visualRowBottoms.size()];
    for (double value : snapshot.visualRowTops) [tops addObject:@(value)];
    for (double value : snapshot.visualRowBottoms) [bottoms addObject:@(value)];
    _rowTops = [tops copy];
    _rowBottoms = [bottoms copy];
    NSMutableArray *rules = [NSMutableArray arrayWithCapacity:snapshot.rules.size()];
    for (const auto& segment : snapshot.rules)
      [rules addObject:[[InkSignPdfPdfiumRule alloc] initWithSegment:segment]];
    _rules = [rules copy];
  }
  return self;
}
@end

@implementation InkSignPdfPdfiumInput
- (instancetype)initWithPdfData:(NSData *)data {
  if ((self = [super init])) { _data = [data copy]; _image = NO; _placement = CGAffineTransformIdentity; }
  return self;
}
- (instancetype)initWithImageData:(NSData *)data pageSize:(CGSize)size
                         rotation:(NSInteger)rotation placement:(CGAffineTransform)placement {
  if ((self = [super init])) {
    _data = [data copy]; _image = YES; _pageSize = size; _rotation = rotation; _placement = placement;
  }
  return self;
}
@end

@implementation InkSignPdfPdfiumExportGlyph
- (instancetype)init {
  if ((self = [super init])) _unicode = @"";
  return self;
}
@end

@implementation InkSignPdfPdfiumExportRun
- (instancetype)init {
  if ((self = [super init])) {
    _lineText = @"";
    _glyphs = @[];
    _transform = CGAffineTransformIdentity;
  }
  return self;
}
@end

@implementation InkSignPdfPdfiumExportPath
- (instancetype)init {
  if ((self = [super init])) { _commandTypes = @[]; _coordinates = @[]; }
  return self;
}
@end

@implementation InkSignPdfPdfiumBackend
+ (NSData *)writeData:(NSData *)data
                pages:(NSArray<InkSignPdfPdfiumPageMetadata *> *)pages
            rotations:(NSArray<NSNumber *> *)rotations
                paths:(NSArray<InkSignPdfPdfiumExportPath *> *)paths
                 runs:(NSArray<InkSignPdfPdfiumExportRun *> *)runs
                fonts:(NSArray<NSData *> *)fonts
                error:(NSError **)error {
  try {
    auto invalid = [&](const char *message) -> NSData * {
      report(error, {pdfium::PdfiumErrorCode::InvalidInput, message});
      return nil;
    };
    const auto maxIndex = std::numeric_limits<std::int32_t>::max();
    if (data.length > maxIndex || pages.count > maxIndex || runs.count > maxIndex ||
        rotations.count != pages.count) return invalid("Invalid export snapshot size");
    auto indexFits = [maxIndex](NSInteger value) { return value >= 0 && value <= maxIndex; };
    pdfium::PdfiumContentInput input;
    input.pathCommandOffsets.push_back(0);
    for (NSUInteger index = 0; index < pages.count; ++index) {
      const auto page = pages[index];
      const NSInteger rotation = rotations[index].integerValue;
      if (page.pageIndex != static_cast<NSInteger>(index) || rotation < 0 || rotation > 270 ||
          rotation % 90 != 0) return invalid("Invalid export page order or rotation");
      input.pageIndices.push_back(static_cast<std::int32_t>(index));
      input.pageRotations.push_back(static_cast<std::int32_t>(rotation / 90));
      input.pageDimensions.push_back(rotation % 180 ? page.visibleBox.size.height : page.visibleBox.size.width);
      input.pageDimensions.push_back(rotation % 180 ? page.visibleBox.size.width : page.visibleBox.size.height);
    }
    for (NSData *font in fonts) {
      input.fontResources.push_back(ownedBytes(font));
      // An exact CoreText face is mandatory; no standard-font substitution.
      input.explicitFontSelections.push_back(1);
    }
    for (InkSignPdfPdfiumExportPath *path in paths) {
      if (!indexFits(path.pageIndex) || path.commandTypes.count > maxIndex ||
          path.coordinates.count != path.commandTypes.count * 6 ||
          input.pathCommandTypes.size() + path.commandTypes.count > static_cast<std::size_t>(maxIndex))
        return invalid("Invalid export path buffers");
      input.pathPageIndices.push_back(static_cast<std::int32_t>(path.pageIndex));
      input.pathColors.push_back(static_cast<std::int32_t>(path.color));
      for (NSNumber *type in path.commandTypes) input.pathCommandTypes.push_back(type.intValue);
      for (NSNumber *value in path.coordinates) input.pathCoordinates.push_back(value.floatValue);
      input.pathCommandOffsets.push_back(static_cast<std::int32_t>(input.pathCommandTypes.size()));
    }
    std::vector<pdfium::PdfiumShapedRun> shapedRuns;
    for (InkSignPdfPdfiumExportRun *run in runs) {
      if (!indexFits(run.pageIndex) || !indexFits(run.lineID) || !indexFits(run.visualOrder) ||
          !indexFits(run.fontIndex) || run.sourceRange.location > static_cast<NSUInteger>(maxIndex) ||
          run.sourceRange.length > static_cast<NSUInteger>(maxIndex) ||
          run.sourceRange.location > run.lineText.length ||
          run.sourceRange.length > run.lineText.length - run.sourceRange.location)
        return invalid("Invalid export text range");
      std::u16string text(run.lineText.length, 0);
      [run.lineText getCharacters:reinterpret_cast<unichar *>(text.data())
                           range:NSMakeRange(0, run.lineText.length)];
      input.textRunPageIndices.push_back(static_cast<std::int32_t>(run.pageIndex));
      input.textRunLineIds.push_back(static_cast<std::int32_t>(run.lineID));
      input.textRunTexts.push_back(std::move(text));
      input.textRunSourceRanges.push_back(static_cast<std::int32_t>(run.sourceRange.location));
      input.textRunSourceRanges.push_back(static_cast<std::int32_t>(run.sourceRange.length));
      input.textRunBidiLevels.push_back(run.rightToLeft ? 1 : 0);
      input.textRunBaseDirections.push_back(run.baseRightToLeft ? 1 : 0);
      input.textRunVisualOrder.push_back(static_cast<std::int32_t>(run.visualOrder));
      input.textRunAlignments.push_back(0);
      input.textRunFontIndices.push_back(static_cast<std::int32_t>(run.fontIndex));
      input.textRunColors.push_back(static_cast<std::int32_t>(run.color));
      input.textRunGeometry.insert(input.textRunGeometry.end(), {0, 0, 0, static_cast<float>(run.fontSize), 0});
      const auto matrix = run.transform;
      input.textRunTransforms.insert(input.textRunTransforms.end(), {
          static_cast<float>(matrix.a), static_cast<float>(matrix.b), static_cast<float>(matrix.c),
          static_cast<float>(matrix.d), static_cast<float>(matrix.tx), static_cast<float>(matrix.ty)});
      if (run.hasClip) {
        input.textRunClips.push_back(std::array<float, 4>{
            static_cast<float>(CGRectGetMinX(run.clip)), static_cast<float>(CGRectGetMinY(run.clip)),
            static_cast<float>(CGRectGetMaxX(run.clip)), static_cast<float>(CGRectGetMaxY(run.clip))});
      } else input.textRunClips.push_back(std::nullopt);
      pdfium::PdfiumShapedRun shaped;
      shaped.prepositioned = true;
      for (InkSignPdfPdfiumExportGlyph *glyph in run.glyphs) {
        if (glyph.sourceOffset < static_cast<NSInteger>(run.sourceRange.location) ||
            static_cast<NSUInteger>(glyph.sourceOffset) >= NSMaxRange(run.sourceRange))
          return invalid("Invalid export glyph cluster");
        std::u16string unicode(glyph.unicode.length, 0);
        [glyph.unicode getCharacters:reinterpret_cast<unichar *>(unicode.data())
                               range:NSMakeRange(0, glyph.unicode.length)];
        shaped.glyphs.push_back({static_cast<std::uint32_t>(glyph.sourceOffset - run.sourceRange.location),
            shaped.glyphs.size(), glyph.glyphID, std::move(unicode),
            static_cast<float>(glyph.position.x), static_cast<float>(glyph.position.y)});
      }
      shapedRuns.push_back(std::move(shaped));
    }
    std::vector<std::uint8_t> output;
    const auto failure = pdfium::PdfiumContentWriter::write(ownedBytes(data), input,
        [&](std::size_t index, auto, auto, bool, float) { return shapedRuns.at(index); }, output);
    if (!failure) { report(error, failure); return nil; }
    return [NSData dataWithBytes:output.data() length:output.size()];
  } catch (const std::exception& exception) {
    report(error, {pdfium::PdfiumErrorCode::MutationFailed, exception.what()});
    return nil;
  }
}

+ (NSArray<InkSignPdfPdfiumPageMetadata *> *)assembleData:(NSData *)data
                                               operation:(InkSignPdfPdfiumAssemblyOperation)operation
                                                  inputs:(NSArray<InkSignPdfPdfiumInput *> *)inputs
                                               pageIndex:(NSInteger)pageIndex
                                        destinationIndex:(NSInteger)destinationIndex
                                               outputURL:(NSURL *)outputURL error:(NSError **)error {
  try {
    if (!outputURL.isFileURL || pageIndex < 0 || destinationIndex < 0) {
      report(error, {pdfium::PdfiumErrorCode::InvalidAssemblyCommand, "Invalid assembly indices or output URL"});
      return nil;
    }
    pdfium::PdfiumPageAssemblyCommand command;
    switch (operation) {
      case InkSignPdfPdfiumAssemblyOperationCreate: command.operation = pdfium::PdfiumPageAssemblyOperation::Create; break;
      case InkSignPdfPdfiumAssemblyOperationAppend: command.operation = pdfium::PdfiumPageAssemblyOperation::Append; break;
      case InkSignPdfPdfiumAssemblyOperationRemove: command.operation = pdfium::PdfiumPageAssemblyOperation::Remove; break;
      case InkSignPdfPdfiumAssemblyOperationMove: command.operation = pdfium::PdfiumPageAssemblyOperation::Move; break;
      default:
        report(error, {pdfium::PdfiumErrorCode::InvalidAssemblyCommand, "Unknown assembly operation"});
        return nil;
    }
    command.pageIndex = static_cast<std::size_t>(pageIndex);
    command.destinationIndex = static_cast<std::size_t>(destinationIndex);
    for (InkSignPdfPdfiumInput *source in inputs) {
      pdfium::PdfiumAppendInput input;
      input.type = source.image ? pdfium::PdfiumAppendInputType::Image : pdfium::PdfiumAppendInputType::Pdf;
      input.bytes = ownedBytes(source.data);
      input.pageWidth = source.pageSize.width;
      input.pageHeight = source.pageSize.height;
      if (source.image && (source.rotation < 0 || source.rotation > 270 || source.rotation % 90 != 0)) {
        report(error, {pdfium::PdfiumErrorCode::InvalidInput, "Invalid image page rotation"});
        return nil;
      }
      input.rotation = static_cast<int>(source.rotation / 90);
      const auto transform = source.placement;
      input.placement = {transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty};
      command.appendInputs.push_back(std::move(input));
    }
    auto result = pdfium::PdfiumPageAssembler::assemble(data ? ownedBytes(data) : std::vector<std::uint8_t>{},
      std::move(command), outputURL.path.fileSystemRepresentation);
    if (!result) { report(error, result.error); return nil; }
    NSMutableArray *pages = [NSMutableArray arrayWithCapacity:result.pages.size()];
    for (const auto& metadata : result.pages)
      [pages addObject:[[InkSignPdfPdfiumPageMetadata alloc] initWithMetadata:metadata]];
    return [pages copy];
  } catch (const std::exception& exception) {
    report(error, {pdfium::PdfiumErrorCode::MutationFailed, exception.what()});
    return nil;
  }
}

+ (NSArray<InkSignPdfPdfiumPageMetadata *> *)inspectData:(NSData *)data error:(NSError **)error {
  try {
    auto opened = pdfium::PdfiumDocumentSession::open(ownedBytes(data));
    if (!opened) { report(error, opened.error); return nil; }
    NSMutableArray *pages = [NSMutableArray arrayWithCapacity:opened.session->pageCount()];
    for (std::size_t index = 0; index < opened.session->pageCount(); ++index) {
      pdfium::PdfiumPageMetadata metadata;
      const auto result = opened.session->inspectPage(index, metadata);
      if (!result) { report(error, result); return nil; }
      [pages addObject:[[InkSignPdfPdfiumPageMetadata alloc] initWithMetadata:metadata]];
    }
    return [pages copy];
  } catch (const std::exception& exception) {
    report(error, {pdfium::PdfiumErrorCode::MutationFailed, exception.what()});
    return nil;
  }
}

+ (NSArray<InkSignPdfPdfiumAnalysis *> *)analyzeData:(NSData *)data
                                       pageIndices:(NSArray<NSNumber *> *)indices error:(NSError **)error {
  try {
    auto opened = pdfium::PdfiumDocumentSession::open(ownedBytes(data));
    if (!opened) { report(error, opened.error); return nil; }
    NSMutableArray *allIndices = nil;
    if (!indices) {
      allIndices = [NSMutableArray arrayWithCapacity:opened.session->pageCount()];
      for (std::size_t index = 0; index < opened.session->pageCount(); ++index) [allIndices addObject:@(index)];
      indices = allIndices;
    }
    NSMutableArray *pages = [NSMutableArray arrayWithCapacity:indices.count];
    for (NSNumber *value in indices) {
      const double index = value.doubleValue;
      if (!std::isfinite(index) || index < 0 || std::floor(index) != index || index >= opened.session->pageCount()) {
        report(error, {pdfium::PdfiumErrorCode::InvalidPageIndex, "The page index is outside this document"});
        return nil;
      }
      pdfium::PdfiumPageMetadata metadata;
      auto result = opened.session->inspectPage(static_cast<std::size_t>(index), metadata);
      if (!result) { report(error, result); return nil; }
      pdfium::PdfiumPageAnalysisSnapshot snapshot;
      result = opened.session->preparePageAnalysis(static_cast<std::size_t>(index), snapshot);
      if (!result) { report(error, result); return nil; }
      pdfium::projectVisiblePageAnalysis(snapshot);
      [pages addObject:[[InkSignPdfPdfiumAnalysis alloc] initWithMetadata:metadata snapshot:snapshot]];
    }
    return [pages copy];
  } catch (const std::exception& exception) {
    report(error, {pdfium::PdfiumErrorCode::MutationFailed, exception.what()});
    return nil;
  }
}
@end
