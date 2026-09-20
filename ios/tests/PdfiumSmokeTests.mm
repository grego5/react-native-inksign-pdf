#import <XCTest/XCTest.h>

extern "C" bool ReactNativeInkSignPdfPdfiumSmoke();

@interface PdfiumSmokeTests : XCTestCase
@end

@implementation PdfiumSmokeTests

- (void)testPdfiumInitializesAndDestroysLibraryContext {
  XCTAssertTrue(ReactNativeInkSignPdfPdfiumSmoke());
}

@end
