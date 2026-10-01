// AMDesignTokens.m —— 见同名头文件
#import "AMDesignTokens.h"

CGFloat const AMCornerRadiusCard    = 16.0;
CGFloat const AMCornerRadiusItem    = 12.0;
CGFloat const AMCornerRadiusControl = 10.0;
CGFloat const AMCornerRadiusOverlay = 24.0;

CGFloat const AMSpacingXs  = 4.0;
CGFloat const AMSpacingSm  = 8.0;
CGFloat const AMSpacingMd  = 12.0;
CGFloat const AMSpacingLg  = 16.0;
CGFloat const AMSpacingXl  = 24.0;
CGFloat const AMSpacingXxl = 32.0;

static UIFont *AMRounded(CGFloat size, UIFontWeight weight) {
    // fontDescriptorWithDesign: iOS 9+，deployment target 14 无忧
    UIFontDescriptor *base = [UIFont systemFontOfSize:size weight:weight].fontDescriptor;
    UIFontDescriptor *rounded = [base fontDescriptorWithDesign:UIFontDescriptorDesignRounded];
    return [UIFont fontWithDescriptor:rounded size:size];
}

UIFont *AMFontDisplay(void)  { return AMRounded(28.0, UIFontWeightBold); }
UIFont *AMFontTitle(void)    { return AMRounded(22.0, UIFontWeightSemibold); }
UIFont *AMFontHeadline(void) { return AMRounded(17.0, UIFontWeightSemibold); }
UIFont *AMFontBody(void)     { return [UIFont systemFontOfSize:17.0]; }
UIFont *AMFontLabel(void)    { return [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium]; }
UIFont *AMFontCaption(void)  { return [UIFont systemFontOfSize:12.0]; }
