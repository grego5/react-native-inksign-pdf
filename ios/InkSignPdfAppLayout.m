#import "InkSignPdfAppLayout.h"
#import <React/RCTI18nUtil.h>

@implementation InkSignPdfAppLayout

+ (BOOL)isRTL {
  return [[RCTI18nUtil sharedInstance] isRTL];
}

@end
