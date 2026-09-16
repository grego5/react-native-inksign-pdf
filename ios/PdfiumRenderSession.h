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

- (nullable instancetype)initWithData:(NSData *)data
                      fallbackFontPath:(nullable NSString *)fallbackFontPath
                       collectionIndex:(double)collectionIndex
                                 error:(NSError **)error
    NS_DESIGNATED_INITIALIZER
    NS_SWIFT_NAME(init(data:fallbackFontPath:collectionIndex:));

- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) NSUInteger pageCount;

- (CGSize)pageSizeForPage:(NSUInteger)pageIndex
                     error:(NSError **)error NS_SWIFT_NAME(pageSize(for:));

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

- (void)close;

@end

NS_ASSUME_NONNULL_END
