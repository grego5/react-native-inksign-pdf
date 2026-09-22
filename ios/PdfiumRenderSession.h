#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const InkSignPdfPdfiumErrorDomain;
FOUNDATION_EXPORT NSInteger const InkSignPdfPdfiumInvalidFallbackFontErrorCode;

/// Objective-C++ ownership boundary for the shared PDFium document session.
/// The session owns its serial worker and never exposes PDFium handles to Swift.
@interface InkSignPdfPdfiumSession : NSObject {
 @private
  void *_state;
}

/// Creates a new PDF directly from ordered PDF and image append inputs.
+ (nullable NSArray<NSValue *> *)assembleNewPDFWithAppendInputs:(NSArray<NSDictionary<NSString *, id> *> *)appendInputs
                                                    scratchURL:(NSURL *)scratchURL
                                                         error:(NSError **)error
    NS_SWIFT_NAME(assembleNewPDF(appendInputs:scratchURL:));

- (nullable instancetype)initWithData:(NSData *)data
                      fallbackFontPath:(nullable NSString *)fallbackFontPath
                       collectionIndex:(double)collectionIndex
                                 error:(NSError **)error
    NS_SWIFT_NAME(init(data:fallbackFontPath:collectionIndex:));

- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) NSUInteger pageCount;

- (BOOL)pageSizeForPage:(NSUInteger)pageIndex
                  size:(CGSize *)size
                 error:(NSError **)error NS_SWIFT_NAME(pageSize(for:into:));

/// Renders directly into the caller-owned tightly packed or strided BGRA data.
- (BOOL)renderPage:(NSUInteger)pageIndex
              width:(int32_t)width
             height:(int32_t)height
             stride:(int32_t)stride
      pageToDevice:(CGAffineTransform)pageToDevice
              clip:(CGRect)clip
         background:(uint32_t)background
              flags:(uint32_t)flags
             pixels:(NSMutableData *)pixels
              error:(NSError **)error;

/// Writes a detached candidate PDF using the shared page assembler. Append
/// inputs use dictionaries with `type`, `data`, `pageWidth`, `pageHeight`, and
/// affine placement components `a` through `f`.
- (nullable NSArray<NSValue *> *)assemblePDFData:(NSData *)data
                                       operation:(NSInteger)operation
                                        pageIndex:(NSUInteger)pageIndex
                                  destinationIndex:(NSUInteger)destinationIndex
                                      appendInputs:(NSArray<NSDictionary<NSString *, id> *> *)appendInputs
                                        scratchURL:(NSURL *)scratchURL
                                             error:(NSError **)error
    NS_SWIFT_NAME(assemble(data:operation:pageIndex:destinationIndex:appendInputs:scratchURL:));

- (void)close;

@end

NS_ASSUME_NONNULL_END
