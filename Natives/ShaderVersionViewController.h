//
//  ShaderVersionViewController.h
//  Amethyst
//
//  View controller for selecting shader versions
//

#import <UIKit/UIKit.h>
#import "ShaderItem.h"
#import "ShaderVersion.h"

NS_ASSUME_NONNULL_BEGIN

@class ShaderVersionViewController;

@protocol ShaderVersionViewControllerDelegate <NSObject>
- (void)shaderVersionViewController:(ShaderVersionViewController *)viewController didSelectVersion:(ShaderVersion *)version;
@end

@interface ShaderVersionViewController : UIViewController

@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, strong) ShaderItem *shaderItem;
@property (nonatomic, weak) id<ShaderVersionViewControllerDelegate> delegate;
/// 初始 API 来源：1=Modrinth，2=CurseForge；默认 1。
@property (nonatomic, assign) NSInteger initialSource;

// FCL 风格：传入当前 profile 的偏好版本和加载器
// ShaderVersionViewController 会优先选中匹配的 chip，并把匹配的版本置顶
// 不传则保持原有"全部"默认行为
// 补齐与 ModVersionViewController 不对称的 preferred 属性（阶段3统一）
@property (nonatomic, copy, nullable) NSString *preferredGameVersion;
@property (nonatomic, copy, nullable) NSString *preferredLoader;

// API 来源：1 = Modrinth（默认），2 = CurseForge。
// 关键修复（CurseForge 搜索结果丢失来源）：光影搜索结果可能来自 CurseForge（数字 project ID），
// 进入版本页时必须沿用搜索时的 API 来源，否则会拿 CurseForge 数字 ID 请求 Modrinth API
// 导致版本列表拉不到。参照 ZL2 的 platform 枚举贯穿搜索→详情→版本全链路。
@property (nonatomic, assign) NSInteger apiSource;

@end

NS_ASSUME_NONNULL_END
