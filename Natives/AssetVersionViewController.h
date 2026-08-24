//
//  AssetVersionViewController.h
//  Amethyst
//
//  通用资源版本选择视图控制器
//  适用于 资源包 / 数据包 / 世界 三类无"加载器"概念的资产
//  参照 ModVersionViewController，但不显示加载器过滤按钮（仅游戏版本过滤）
//  复用 ModVersion 作为版本模型（其结构与 ShaderVersion 一致）
//

#import <UIKit/UIKit.h>
#import "ModVersion.h"

NS_ASSUME_NONNULL_BEGIN

// 资产类型枚举：用于决定标题与默认行为
typedef NS_ENUM(NSInteger, AssetVersionType) {
    AssetVersionTypeResourcePack = 0, // 资源包
    AssetVersionTypeDataPack = 1,     // 数据包
    AssetVersionTypeWorld = 2,        // 世界
};

@class AssetVersionViewController;

@protocol AssetVersionViewControllerDelegate <NSObject>
// 用户选中某个版本后回调
- (void)assetVersionViewController:(AssetVersionViewController *)viewController
               didSelectVersion:(ModVersion *)version;
@end

@interface AssetVersionViewController : UIViewController

// 资产类型（决定标题文案，例如"选择资源包版本"）
@property (nonatomic, assign) AssetVersionType assetType;
// 在线项目的 Modrinth/CurseForge ID
@property (nonatomic, copy, nullable) NSString *projectID;
// 在线 API 来源：1=Modrinth，2=CurseForge；默认 1
@property (nonatomic, assign) NSInteger apiSource;
// 项目显示名（用于导航栏标题）
@property (nonatomic, copy, nullable) NSString *projectDisplayName;
// 代理
@property (nonatomic, weak, nullable) id<AssetVersionViewControllerDelegate> delegate;

// FCL 风格：传入当前 profile 的偏好版本
// AssetVersionViewController 会优先选中匹配的 chip，并把匹配的版本置顶
// 注：资产类型（资源包/数据包/世界）无加载器概念，故无 preferredLoader
// 阶段3统一：补齐与 ModVersionViewController 不对称的 preferred 属性
@property (nonatomic, copy, nullable) NSString *preferredGameVersion;

// --- 项目展示信息（用于详情 header，由 DownloadViewController 传入）---
// 补齐之前版本页缺少的项目封面图/标题/作者/下载量/标签/描述等信息显示
@property (nonatomic, copy, nullable) NSString *projectIconURL;
@property (nonatomic, copy, nullable) NSString *projectAuthor;
@property (nonatomic, strong, nullable) NSNumber *projectDownloads;
@property (nonatomic, strong, nullable) NSNumber *projectLikes;
@property (nonatomic, copy, nullable) NSString *projectDescription;
@property (nonatomic, strong, nullable) NSArray<NSString *> *projectCategories;
@property (nonatomic, copy, nullable) NSString *projectLastUpdated;

@end

NS_ASSUME_NONNULL_END
