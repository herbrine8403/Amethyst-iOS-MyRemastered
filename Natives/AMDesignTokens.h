// AMDesignTokens.h —— Amethyst 新 UI 设计系统 · 形状/间距/字体（ui-redesign P0）
// 数值对齐 Material 3 常用档位，视觉验收后可整体微调。
#import <UIKit/UIKit.h>

UIKIT_EXTERN CGFloat const AMCornerRadiusCard;     // 16
UIKIT_EXTERN CGFloat const AMCornerRadiusItem;     // 12
UIKIT_EXTERN CGFloat const AMCornerRadiusControl;  // 10
UIKIT_EXTERN CGFloat const AMCornerRadiusOverlay;  // 24

UIKIT_EXTERN CGFloat const AMSpacingXs;   // 4
UIKIT_EXTERN CGFloat const AMSpacingSm;   // 8
UIKIT_EXTERN CGFloat const AMSpacingMd;   // 12
UIKIT_EXTERN CGFloat const AMSpacingLg;   // 16
UIKIT_EXTERN CGFloat const AMSpacingXl;   // 24
UIKIT_EXTERN CGFloat const AMSpacingXxl;  // 32

// ZL2 顶栏/大标题用圆体（SF Rounded），正文用系统体。
UIFont *AMFontDisplay(void);   // 28  rounded bold    —— 启动页/空态大字
UIFont *AMFontTitle(void);     // 22  rounded semibold
UIFont *AMFontHeadline(void);  // 17  rounded semibold
UIFont *AMFontBody(void);     // 17  system regular
UIFont *AMFontLabel(void);    // 14  system medium
UIFont *AMFontCaption(void);  // 12  system regular
