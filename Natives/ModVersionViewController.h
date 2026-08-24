#import <UIKit/UIKit.h>
#import <UIKit/UIKit.h>
#import "ModItem.h"
#import "ModVersion.h"

NS_ASSUME_NONNULL_BEGIN

@class ModVersionViewController;

@protocol ModVersionViewControllerDelegate <NSObject>
- (void)modVersionViewController:(ModVersionViewController *)viewController didSelectVersion:(ModVersion *)version;
@end

@interface ModVersionViewController : UIViewController

@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, strong) ModItem *modItem;
@property (nonatomic, weak) id<ModVersionViewControllerDelegate> delegate;
/// 初始 API 来源：1=Modrinth，2=CurseForge；默认 1。
@property (nonatomic, assign) NSInteger initialSource;

// FCL 风格：传入当前 profile 的偏好版本和加载器
// ModVersionViewController 会优先选中匹配的 chip，并把匹配的版本置顶
// 不传则保持原有"全部"默认行为
@property (nonatomic, copy, nullable) NSString *preferredGameVersion;
@property (nonatomic, copy, nullable) NSString *preferredLoader;

@end

NS_ASSUME_NONNULL_END
