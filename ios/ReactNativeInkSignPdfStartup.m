#import <Foundation/Foundation.h>

extern void ReactNativeInkSignPdfInitializeCacheArtifacts(void);

__attribute__((constructor))
static void ReactNativeInkSignPdfStartup(void) {
  ReactNativeInkSignPdfInitializeCacheArtifacts();
}
