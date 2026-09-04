#import "PLUIPackManager.h"
#import "PLThemeManager.h"
#import "LauncherPreferences.h"
#import "UZKArchive.h"

// UI 包 = schemaVersion 2 的主题包。纯颜色包（1）不进入本管理器。
static NSInteger const PLUIPackSchemaVersion = 2;
// 脚本总量限额（与沙箱预算一致），超限直接判坏包走回退。
static NSUInteger const PLUIPackMaxScriptBytes = 256 * 1024;
// 导入失败/无效包的错误域与错误码。
static NSString * const PLUIPackImportErrorDomain = @"PLUIPackImportError";
static NSInteger const PLUIPackImportErrorCodeNotAPack = 10;
static NSInteger const PLUIPackImportErrorCodeExtractFailed = 11;
static NSInteger const PLUIPackImportErrorCodeReplaceFailed = 12;

@interface PLUIPackManager ()
// PLUIPack 未实现 NSCopying，copy 修饰会在赋值时调 copyWithZone: 直接崩
// （默认主题 pcl-classic 即 schemaVersion 2，启动必走此赋值路径）；strong 足够——
// PLUIPack 是构造时拷贝好所有字段的不可变值对象。
@property (nonatomic, nullable, strong, readwrite) PLUIPack *activePack;
@end

@implementation PLUIPack

- (instancetype)initWithIdentifier:(NSString *)identifier
                        displayName:(NSString *)displayName
                             author:(NSString *)author
                           rootPath:(NSString *)rootPath
                          entryPath:(NSString *)entryPath {
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        _displayName = [displayName copy];
        _author = [author copy];
        _rootPath = [rootPath copy];
        _entryPath = [entryPath copy];
    }
    return self;
}

@end

@implementation PLUIPackManager

+ (PLUIPackManager *)sharedManager {
    static PLUIPackManager *manager;
    static dispatch_once_t onceToken;
    // 只做纯初始化，不在此调 reload：libdispatch 块内抛出的 ObjC 异常
    // 无法被调用方（PLUIShellViewController buildShell 的 @try）捕获，
    // 会击穿欢迎界面兜底直接闪退。reload 由壳在 @try 内显式调用。
    dispatch_once(&onceToken, ^{
        manager = [PLUIPackManager new];
    });
    return manager;
}

- (void)reload {
    // 激活源优先级：1) 导入包 uipack/active；2) theme_pack 指向的 themes UI 包。
    PLUIPack *imported = [self loadPackAtRoot:[PLUIPackManager importedPackRoot] expectedIdentifier:nil];
    if (imported) {
        self.activePack = imported;
        return;
    }
    NSString *selected = getPrefObject(@"general.theme_pack");
    self.activePack = [self loadPackWithIdentifier:selected];
}

- (NSArray<PLUIPack *> *)availableUIPacks {
    NSMutableArray<PLUIPack *> *packs = [NSMutableArray array];
    for (NSDictionary *theme in [PLThemeManager.sharedManager availableThemes]) {
        NSString *identifier = theme[@"id"];
        if (![theme[@"schemaVersion"] isKindOfClass:NSNumber.class]) continue;
        if ([theme[@"schemaVersion"] integerValue] != PLUIPackSchemaVersion) continue;
        PLUIPack *pack = [self loadPackWithIdentifier:identifier];
        if (pack) [packs addObject:pack];
    }
    return [packs sortedArrayUsingComparator:^NSComparisonResult(PLUIPack *a, PLUIPack *b) {
        return [a.displayName localizedCaseInsensitiveCompare:b.displayName];
    }];
}

- (nullable NSString *)mainLuaSourceForPack:(PLUIPack *)pack {
    if (!pack.entryPath) return nil;
    NSData *data = [NSData dataWithContentsOfFile:pack.entryPath];
    if (!data || data.length == 0 || data.length > PLUIPackMaxScriptBytes) return nil;
    NSString *source = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return source.length > 0 ? source : nil;
}

#pragma mark - 加载与校验

- (nullable NSDictionary *)JSONDictionaryAtPath:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

- (nullable PLUIPack *)loadPackWithIdentifier:(NSString *)identifier {
    if (![identifier isKindOfClass:NSString.class]) return nil;
    // rootForIdentifier 内部完成安全标识符校验与 外部覆盖内置 的解析。
    NSString *root = [PLThemeManager.sharedManager rootForIdentifier:identifier];
    if (!root) return nil;
    return [self loadPackAtRoot:root expectedIdentifier:identifier];
}

/// 从任意目录加载 UI 包。expectedIdentifier 非 nil 时要求 manifest id 与其一致
/// （themes 机制约定）；为 nil 时（导入包 uipack/active）只要求 manifest 有 id。
- (nullable PLUIPack *)loadPackAtRoot:(nullable NSString *)root
                    expectedIdentifier:(nullable NSString *)expectedIdentifier {
    if (![root isKindOfClass:NSString.class] || root.length == 0) return nil;

    NSDictionary *manifest = [self JSONDictionaryAtPath:[root stringByAppendingPathComponent:@"manifest.json"]];
    if (!manifest) return nil;
    NSInteger version = [manifest[@"schemaVersion"] isKindOfClass:NSNumber.class]
        ? [manifest[@"schemaVersion"] integerValue] : 0;
    NSString *manifestId = [manifest[@"id"] isKindOfClass:NSString.class] ? manifest[@"id"] : nil;
    BOOL idOk = manifestId.length > 0 &&
        (!expectedIdentifier || [manifestId isEqualToString:expectedIdentifier]);
    if (version != PLUIPackSchemaVersion || !idOk) {
        return nil;
    }

    NSString *entryPath = [self validatedEntryPathInRoot:root manifest:manifest];
    if (!entryPath) {
        NSLog(@"[PLUIPackManager] pack at %@ rejected: missing or invalid entry script", root.lastPathComponent);
        return nil;
    }

    return [[PLUIPack alloc] initWithIdentifier:manifestId
                                     displayName:[manifest[@"name"] isKindOfClass:NSString.class] ? manifest[@"name"] : manifestId
                                          author:[manifest[@"author"] isKindOfClass:NSString.class] ? manifest[@"author"] : @""
                                        rootPath:root
                                       entryPath:entryPath];
}

/// 校验入口脚本路径与大小。只允许包根下的单段文件名（默认 main.lua），
/// 禁止子目录、绝对路径与 ".."，从源头挡住目录穿越。
- (nullable NSString *)validatedEntryPathInRoot:(NSString *)root manifest:(NSDictionary *)manifest {
    NSString *entry = [manifest[@"entry"] isKindOfClass:NSString.class] ? manifest[@"entry"] : @"main.lua";
    if (entry.length == 0 || entry.isAbsolutePath) return nil;
    if (![entry isEqualToString:entry.lastPathComponent]) return nil;
    if ([entry hasPrefix:@"."] || [entry containsString:@".."] || [entry containsString:@"/"]) return nil;

    NSString *path = [root stringByAppendingPathComponent:entry];
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
    if (size == 0 || size > PLUIPackMaxScriptBytes) return nil;
    return path;
}

#pragma mark - 导入（uipack/active）

+ (nullable NSString *)importedPackRoot {
    const char *home = getenv("POJAV_HOME");
    if (!home || home[0] == '\0') return nil;
    return [[NSString stringWithUTF8String:home]
        stringByAppendingPathComponent:@"uipack/active"];
}

/// staging 目录（uipack/active-staging）：先在 staging 校验，通过后原子替换 active。
+ (nullable NSString *)importedPackStagingRoot {
    const char *home = getenv("POJAV_HOME");
    if (!home || home[0] == '\0') return nil;
    return [[NSString stringWithUTF8String:home]
        stringByAppendingPathComponent:@"uipack/active-staging"];
}

/// zip 解压后常见"顶层目录包裹"（如 mypack/manifest.json）：
/// 若 staging 根无 manifest.json 而唯一子目录有，则把子目录内容上移到根。
- (void)hoistWrappedRootDirectoryIfNeeded:(NSString *)root {
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"manifest.json"]]) return;
    NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:root error:nil];
    if (children.count != 1) return;
    NSString *onlyDir = [root stringByAppendingPathComponent:children.firstObject];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:onlyDir isDirectory:&isDir] || !isDir) return;
    if (![fm fileExistsAtPath:[onlyDir stringByAppendingPathComponent:@"manifest.json"]]) return;

    for (NSString *item in [fm contentsOfDirectoryAtPath:onlyDir error:nil]) {
        [fm moveItemAtPath:[onlyDir stringByAppendingPathComponent:item]
                    toPath:[root stringByAppendingPathComponent:item] error:nil];
    }
    [fm removeItemAtPath:onlyDir error:nil];
}

/// staging 内容必须是合法 UI 包（schemaVersion 2 + 有 id + entry 脚本有效）。
- (BOOL)validateImportedPackAtRoot:(NSString *)root error:(NSError **)error {
    NSDictionary *manifest = [self JSONDictionaryAtPath:[root stringByAppendingPathComponent:@"manifest.json"]];
    NSInteger version = [manifest[@"schemaVersion"] isKindOfClass:NSNumber.class]
        ? [manifest[@"schemaVersion"] integerValue] : 0;
    BOOL hasId = [manifest[@"id"] isKindOfClass:NSString.class] && [manifest[@"id"] length] > 0;
    if (version != PLUIPackSchemaVersion || !hasId ||
        ![self validatedEntryPathInRoot:root manifest:manifest]) {
        if (error) {
            *error = [NSError errorWithDomain:PLUIPackImportErrorDomain
                                          code:PLUIPackImportErrorCodeNotAPack
                                      userInfo:@{NSLocalizedDescriptionKey:
                                          @"Not a valid UI pack: manifest.json must declare schemaVersion 2, an id and a valid entry script (main.lua)"}];
        }
        return NO;
    }
    return YES;
}

- (BOOL)importPackFromURL:(NSURL *)url error:(NSError **)error {
    if (![url isKindOfClass:NSURL.class]) {
        if (error) {
            *error = [NSError errorWithDomain:PLUIPackImportErrorDomain
                                          code:PLUIPackImportErrorCodeNotAPack
                                      userInfo:@{NSLocalizedDescriptionKey: @"No file selected"}];
        }
        return NO;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *staging = [PLUIPackManager importedPackStagingRoot];
    NSString *active = [PLUIPackManager importedPackRoot];
    if (!staging || !active) {
        if (error) {
            *error = [NSError errorWithDomain:PLUIPackImportErrorDomain
                                          code:PLUIPackImportErrorCodeReplaceFailed
                                      userInfo:@{NSLocalizedDescriptionKey: @"POJAV_HOME is not initialized"}];
        }
        return NO;
    }

    // staging 全新开局；旧 active 在校验通过前不动。
    [fm removeItemAtPath:staging error:nil];
    if (![fm createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }

    BOOL staged = NO;
    BOOL accessing = [url startAccessingSecurityScopedResource];
    @try {
        NSNumber *isDirNumber = nil;
        BOOL isDir = NO;
        if ([url getResourceValue:&isDirNumber forKey:NSURLIsDirectoryKey error:nil] && isDirNumber) {
            isDir = isDirNumber.boolValue;
        } else {
            isDir = NO;
        }

        if (isDir) {
            // 文件夹导入：整包递归复制到 staging/（保留文件夹本身作为一层，稍后按需上移）
            NSString *dest = [staging stringByAppendingPathComponent:url.lastPathComponent];
            staged = [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dest] error:error];
        } else {
            // zip 导入：先拷贝到 tmp 再解压（安全作用域 URL 直接喂 UZKArchive 会读失败，
            // 同 LauncherRightPanelViewController 的 asCopy 修复）。
            NSString *tmpZip = [NSTemporaryDirectory() stringByAppendingPathComponent:@"uipack-import.zip"];
            [fm removeItemAtPath:tmpZip error:nil];
            staged = [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:tmpZip] error:error];
            if (staged) {
                UZKArchive *archive = [[UZKArchive alloc] initWithPath:tmpZip error:error];
                staged = archive && [archive extractFilesTo:staging overwrite:YES error:error];
                [fm removeItemAtPath:tmpZip error:nil];
            }
        }
    } @finally {
        if (accessing) [url stopAccessingSecurityScopedResource];
    }

    if (!staged) {
        [fm removeItemAtPath:staging error:nil];
        if (error && *error == nil) {
            *error = [NSError errorWithDomain:PLUIPackImportErrorDomain
                                          code:PLUIPackImportErrorCodeExtractFailed
                                      userInfo:@{NSLocalizedDescriptionKey: @"Failed to copy or extract the pack"}];
        }
        return NO;
    }

    [self hoistWrappedRootDirectoryIfNeeded:staging];

    // 校验失败：清理 staging，原 active 包不受影响。
    if (![self validateImportedPackAtRoot:staging error:error]) {
        [fm removeItemAtPath:staging error:nil];
        return NO;
    }

    // 原子替换：删旧 active → staging 改名。
    [fm removeItemAtPath:active error:nil];
    if (![fm moveItemAtPath:staging toPath:active error:error]) {
        [fm removeItemAtPath:staging error:nil];
        if (error && *error == nil) {
            *error = [NSError errorWithDomain:PLUIPackImportErrorDomain
                                          code:PLUIPackImportErrorCodeReplaceFailed
                                      userInfo:@{NSLocalizedDescriptionKey: @"Failed to activate the imported pack"}];
        }
        return NO;
    }

    [self reload];
    return YES;
}

@end
