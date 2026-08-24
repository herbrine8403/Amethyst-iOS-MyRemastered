#import <UIKit/UIKit.h>

// 下载页面 - 版本/模组/光影/资源包/数据包/整合包/世界 七个标签
@interface DownloadViewController : UIViewController

/// 初始显示的 tab（0版本 1模组 2光影 3资源包 4数据包 5整合包 6世界），默认 0；
/// 供资源管理界面"去下载"引导跳转时定位到对应资源类型
@property (nonatomic, assign) NSInteger initialTabIndex;

/// 资源下载目标档案。由资源管理页传入；为空时回退到当前或首个有效档案。
@property (nonatomic, copy, nullable) NSString *targetProfileName;

@end
