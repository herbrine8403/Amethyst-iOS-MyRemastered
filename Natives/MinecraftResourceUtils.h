#import <UIKit/UIKit.h>

#define TYPE_INSTALLED 0
#define TYPE_RELEASE 1
#define TYPE_SNAPSHOT 2
#define TYPE_OLDBETA 3
#define TYPE_OLDALPHA 4

@interface MinecraftResourceUtils : NSObject

+ (void)processVersion:(NSMutableDictionary *)json inheritsFrom:(NSMutableDictionary *)inheritsFrom;
+ (void)tweakVersionJson:(NSMutableDictionary *)json;

+ (NSObject *)findVersion:(NSString *)version inList:(NSArray *)list;
+ (NSObject *)findNearestVersion:(NSObject *)version expectedType:(int)type;

// 评估 Mojang 版本 JSON 中的 OS 规则（iOS 视作 osx）
+ (BOOL)evaluateRules:(NSArray *)rules;
// 将规则化的 JVM 参数项展开为字符串数组
+ (NSArray<NSString *> *)flattenJvmArg:(id)arg;

/// 参照 ZL2 Install.ForgeLike.progressIgnoreList：
/// bootstraplauncher 0.1.17+ 只会对 classpath 中库的文件名应用 -DignoreList，
/// 必须在 -DignoreList 末尾追加 ${primary_jar_name}，否则主 jar 被 SecureJarHandler 忽略导致启动崩溃。
/// 非新 bootstraplauncher 时为空操作。json 需为可变的 arguments.jvm 数组。
+ (void)applyBootstrapLauncherIgnoreListFix:(NSMutableDictionary *)json;

/// 参照 ZL2 Install.OptiFine.checkOFLaunchWrapper：
/// 生成 OptiFine 运行所需的 launchwrapper library 条目（同时落盘 / 按需下载）。
///   - OptiFine 1.13+ 安装包内嵌 launchwrapper-of-<ver>.jar + launchwrapper-of.txt，
///     官方安装器会解压到 libraries/optifine/launchwrapper-of/<ver>/；
///   - 旧版（1.12 及以下）使用 net.minecraft:launchwrapper:1.12。
/// @return 可直接拼入 version.json 的 libraries 数组；失败返回 nil。
+ (NSArray *)optifineLaunchWrapperLibrariesWithOptiFineJarPath:(NSString *)optifineJarPath
                                                  librariesDir:(NSString *)librariesDir;

@end
