#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Owned values only; callers invoke the backend on their serial PDF queue.
@interface InkSignPdfPdfiumPageMetadata : NSObject
@property(nonatomic, readonly) NSInteger pageIndex;
@property(nonatomic, readonly) CGRect mediaBox;
@property(nonatomic, readonly) NSInteger rotation;
@property(nonatomic, readonly) CGSize displaySize;
@end

/// Detached export values; construct before submitting to the serial PDF queue.
@interface InkSignPdfPdfiumExportGlyph : NSObject
@property(nonatomic) uint32_t glyphID;
@property(nonatomic) NSInteger sourceOffset;
@property(nonatomic, copy) NSString *unicode;
@property(nonatomic) CGPoint position;
@end

@interface InkSignPdfPdfiumExportRun : NSObject
@property(nonatomic) NSInteger pageIndex;
@property(nonatomic) NSInteger lineID;
@property(nonatomic, copy) NSString *lineText;
@property(nonatomic) NSRange sourceRange;
@property(nonatomic) BOOL rightToLeft;
@property(nonatomic) BOOL baseRightToLeft;
@property(nonatomic) NSInteger visualOrder;
@property(nonatomic) NSInteger fontIndex;
@property(nonatomic) CGFloat fontSize;
@property(nonatomic) uint32_t color;
@property(nonatomic) CGAffineTransform transform;
@property(nonatomic) BOOL hasClip;
@property(nonatomic) CGRect clip;
@property(nonatomic, copy) NSArray<InkSignPdfPdfiumExportGlyph *> *glyphs;
@end

@interface InkSignPdfPdfiumExportPath : NSObject
@property(nonatomic) NSInteger pageIndex;
@property(nonatomic) uint32_t color;
@property(nonatomic, copy) NSArray<NSNumber *> *commandTypes;
/// Six coordinates per command, matching the portable writer's path format.
@property(nonatomic, copy) NSArray<NSNumber *> *coordinates;
@end

@interface InkSignPdfPdfiumGlyph : NSObject
@property(nonatomic, readonly) uint32_t scalar;
@property(nonatomic, readonly) BOOL hasBounds;
@property(nonatomic, readonly) CGRect bounds;
@property(nonatomic, readonly) NSInteger visualRow;
@end

@interface InkSignPdfPdfiumRule : NSObject
@property(nonatomic, readonly) CGPoint start;
@property(nonatomic, readonly) CGPoint end;
@end

@interface InkSignPdfPdfiumAnalysis : NSObject
@property(nonatomic, readonly, strong) InkSignPdfPdfiumPageMetadata *metadata;
@property(nonatomic, readonly, copy) NSArray<InkSignPdfPdfiumGlyph *> *glyphs;
@property(nonatomic, readonly, copy) NSArray<NSNumber *> *rowTops;
@property(nonatomic, readonly, copy) NSArray<NSNumber *> *rowBottoms;
@property(nonatomic, readonly, copy) NSArray<InkSignPdfPdfiumRule *> *rules;
@end

typedef NS_ENUM(NSInteger, InkSignPdfPdfiumAssemblyOperation) {
  InkSignPdfPdfiumAssemblyOperationCreate,
  InkSignPdfPdfiumAssemblyOperationAppend,
  InkSignPdfPdfiumAssemblyOperationRemove,
  InkSignPdfPdfiumAssemblyOperationMove
};

@interface InkSignPdfPdfiumInput : NSObject
@property(nonatomic, readonly, copy) NSData *data;
@property(nonatomic, readonly) BOOL image;
@property(nonatomic, readonly) CGSize pageSize;
@property(nonatomic, readonly) NSInteger rotation;
@property(nonatomic, readonly) CGAffineTransform placement;
- (instancetype)initWithPdfData:(NSData *)data NS_SWIFT_NAME(init(pdfData:));
- (instancetype)initWithImageData:(NSData *)data pageSize:(CGSize)size
                         rotation:(NSInteger)rotation placement:(CGAffineTransform)placement
    NS_SWIFT_NAME(init(imageData:pageSize:rotation:placement:));
@end

@interface InkSignPdfPdfiumBackend : NSObject
+ (nullable NSData *)writeData:(NSData *)data
                         pages:(NSArray<InkSignPdfPdfiumPageMetadata *> *)pages
                     rotations:(NSArray<NSNumber *> *)rotations
                         paths:(NSArray<InkSignPdfPdfiumExportPath *> *)paths
                          runs:(NSArray<InkSignPdfPdfiumExportRun *> *)runs
                         fonts:(NSArray<NSData *> *)fonts
                         error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(write(data:pages:rotations:paths:runs:fonts:));
+ (nullable NSArray<InkSignPdfPdfiumPageMetadata *> *)inspectData:(NSData *)data
                                                          error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(inspect(data:));
+ (nullable NSArray<InkSignPdfPdfiumAnalysis *> *)analyzeData:(NSData *)data
                                                pageIndices:(nullable NSArray<NSNumber *> *)indices
                                                      error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(analyze(data:pageIndices:));
+ (nullable NSArray<InkSignPdfPdfiumPageMetadata *> *)assembleData:(nullable NSData *)data
                                                       operation:(InkSignPdfPdfiumAssemblyOperation)operation
                                                          inputs:(NSArray<InkSignPdfPdfiumInput *> *)inputs
                                                       pageIndex:(NSInteger)pageIndex
                                                destinationIndex:(NSInteger)destinationIndex
                                                       outputURL:(NSURL *)outputURL
                                                           error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(assemble(data:operation:inputs:pageIndex:destinationIndex:outputURL:));
@end

NS_ASSUME_NONNULL_END
