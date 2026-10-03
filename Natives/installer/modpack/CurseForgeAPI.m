#import "utils.h"   // ★ [MODPACK-FIX] missingAPIKeyError 面向用户文案改用 localize()（与 ModrinthAPI.m 同约定：utils.h 置首）
#import "CurseForgeAPI.h"
#import "AFNetworking.h"
#import "PLPreferences.h"
#import "config.h"
#import "PLMirrorCenter.h"

// CurseForge 静态常量
static const NSInteger kCurseForgeGameIDMinecraft = 432;
static const NSInteger kCurseForgeClassIDBukkitPlugins = 5;
static const NSInteger kCurseForgeClassIDMods = 6;
static const NSInteger kCurseForgeClassIDResourcePacks = 12;
static const NSInteger kCurseForgeClassIDWorlds = 17;
static const NSInteger kCurseForgeClassIDModpacks = 4471;
static const NSInteger kCurseForgeClassIDShaders = 6552;
static const NSInteger kCurseForgeClassIDDataPacks = 6945;
static const NSInteger kCurseForgeCategoryIDServerUtility = 435;

// NSError userInfo keys for diagnostic information
NSString *const CurseForgeResponseContentTypeKey = @"CurseForgeResponseContentTypeKey";
NSString *const CurseForgeResponseSnippetKey = @"CurseForgeResponseSnippetKey";

/// 安全获取编译时 CurseForge API Key（避免 @nil 非法表达式）
/// 参考 CurseForgeAPIKeyViewController.m 中的 CFKCompiledAPIKey() 实现
static NSString *CFACompiledAPIKey(void) {
#define CFA_STR_INNER(x) #x
#define CFA_STR(x) CFA_STR_INNER(x)
    NSString *compiledKey = [NSString stringWithUTF8String:CFA_STR(CONFIG_CURSEFORGE_API_KEY)];
#undef CFA_STR
#undef CFA_STR_INNER
    // 处理字符串字面量两端的引号（CONFIG_CURSEFORGE_API_KEY 宏定义为 "actual_key" 时，字符串化后为 "\"actual_key\""）
    if (compiledKey.length >= 2 && [compiledKey hasPrefix:@"\""] && [compiledKey hasSuffix:@"\""]) {
        compiledKey = [compiledKey substringWithRange:NSMakeRange(1, compiledKey.length - 2)];
    }
    // 宏未定义时预处理器字符串化后得到宏名本身 "CONFIG_CURSEFORGE_API_KEY"，或为 nil 时得到 "nil"
    if ([compiledKey isEqualToString:@"nil"] || compiledKey.length == 0 ||
        [compiledKey isEqualToString:@"CONFIG_CURSEFORGE_API_KEY"]) {
        return @"";
    }
    return compiledKey;
}

@interface CurseForgeAPI ()
@property (nonatomic, strong) NSURLSession *session;   // 用于异步请求
// 错误诊断辅助方法：将 HTTP 响应信息封装进 NSError userInfo
- (NSError *)errorWithResponse:(NSURLResponse *)response
                          data:(NSData *)data
                 originalError:(NSError *)originalError
                       snippet:(NSString *)snippet;
// 调试日志辅助方法：输出请求/响应/JSON 解析错误的完整信息
- (void)debugLogRequest:(NSURLRequest *)request
               response:(NSURLResponse *)response
                   data:(NSData *)data
              jsonError:(NSError *)jsonError;
// 将 NSData 转为可打印字符串（处理非 UTF-8 内容，最多 maxLen 字节）
- (NSString *)printableStringFromData:(NSData *)data maxLen:(NSUInteger)maxLen;
@end

/// 经 PLMirrorCenter 按资源下载（AssetDownload）策略应用镜像
/// （CurseForge Edge/Media CDN 文件 → MCIM 镜像），URL 为空或无法解析时回退原始字符串
static NSString *CFAMirrorResolvedURL(NSString *urlString) {
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) return urlString;
    NSURL *resolved = [PLMirrorCenter preferredURLForOriginalURL:[NSURL URLWithString:urlString]
                                                    resourceType:PLMirrorResourceTypeAssetDownload];
    return resolved.absoluteString ?: urlString;
}

@implementation CurseForgeAPI

/// 重写 baseURL getter，根据 PLMirrorCenter 的资源搜索（AssetSearch）策略
/// 动态返回官方或 MCIM 镜像 URL，这样所有使用 self.baseURL 的请求都会自动走镜像
- (NSString *)baseURL {
    NSString *resolved = [PLMirrorCenter curseForgeAPIBaseURL];
    // ★ [MODPACK-FIX] 未配置 API key 时强制回落 MCIM 镜像（免 key，实测 200）。
    //   官方 api.curseforge.com 对无 x-api-key 的请求恒 403；而默认策略
    //   （official_first / auto）会让无 key 设备首选官方 → 「进入 CurseForge 源即报错」。
    //   有 key 的设备保持原镜像策略语义不变。
    if ([self apiKey].length == 0 && [resolved containsString:@"api.curseforge.com"]) {
        NSLog(@"[CurseForgeAPI] MODPACK-FIX: no API key -- baseURL forced to MCIM mirror (keyless, field-tested 200)");
        return [PLMirrorCenter mcimCurseForgeAPIBaseURL];
    }
    return resolved;
}

+ (instancetype)sharedInstance {
    static CurseForgeAPI *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super initWithURL:@"https://api.curseforge.com/v1"];
    if (self) {
        _session = [NSURLSession sharedSession];
    }
    return self;
}

#pragma mark - API Key 和 Headers

- (NSString *)apiKey {
    // 1. 运行时偏好（优先级最高）
    NSString *runtimeKey = [PLPreferences curseForgeAPIKey];
    if ([runtimeKey isKindOfClass:NSString.class] && runtimeKey.length > 0) {
        NSLog(@"[CurseForgeAPI] API Key source: runtime preference (length=%lu, prefix=%@...)",
              (unsigned long)runtimeKey.length,
              runtimeKey.length >= 8 ? [runtimeKey substringToIndex:8] : runtimeKey);
        return runtimeKey;
    }
    // 2. 编译时宏（使用字符串化宏方案，避免 @nil 边界问题）
    NSString *compiledKey = CFACompiledAPIKey();
    if (compiledKey.length > 0) {
        NSLog(@"[CurseForgeAPI] API Key source: compile-time macro (length=%lu, prefix=%@...)",
              (unsigned long)compiledKey.length,
              compiledKey.length >= 8 ? [compiledKey substringToIndex:8] : compiledKey);
        return compiledKey;
    }
    // 3. Info.plist
    NSString *infoPlistKey = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CurseForgeAPIKey"];
    if ([infoPlistKey isKindOfClass:NSString.class] && infoPlistKey.length > 0) {
        NSLog(@"[CurseForgeAPI] API Key source: Info.plist (length=%lu, prefix=%@...)",
              (unsigned long)infoPlistKey.length,
              infoPlistKey.length >= 8 ? [infoPlistKey substringToIndex:8] : infoPlistKey);
        return infoPlistKey;
    }
    NSLog(@"[CurseForgeAPI] Warning: API Key not configured!");
    return @"";
}

- (NSDictionary *)headers {
    NSString *key = [self apiKey];
    if (key.length == 0) {
        // ★ [MODPACK-FIX] keyless 不再返回 nil。旧实现把 headers == nil 当作
        //   「API key 缺失」的致命门（getEndpoint / postEndpoint / searchModWithFilters
        //   三处直接 missingAPIKeyError，请求根本不发出）——而 baseURL 在无 key 时
        //   已强制回落 MCIM 镜像（镜像无 key 实测 200）。两者语义互相打架 ⇒
        //   无 key 构建（所有 CI/sideload 构建）在 CurseForge 源上一律报
        //   "CurseForge API key is missing..." 死路。新语义：keyless = 照常发请求
        //   但不带 x-api-key（走镜像），有 key 照旧。
        static BOOL s_modpackFixKeylessLogged = NO;
        if (!s_modpackFixKeylessLogged) {
            s_modpackFixKeylessLogged = YES;
            NSLog(@"[CurseForgeAPI] MODPACK-FIX: no API key configured -- requests go keyless to the MCIM mirror");
        }
        return @{ @"Accept" : @"application/json" };
    }
    return @{
        @"Accept": @"application/json",
        @"x-api-key": key
    };
}

+ (BOOL)isAPIKeyConfigured {
    // 与 apiKey getter 保持一致的三层 fallback，避免 UI 门控与实际请求判断不一致
    NSString *runtimeKey = [PLPreferences curseForgeAPIKey];
    if ([runtimeKey isKindOfClass:NSString.class] && runtimeKey.length > 0) {
        return YES;
    }
    NSString *compiledKey = CFACompiledAPIKey();
    if (compiledKey.length > 0) {
        return YES;
    }
    NSString *infoPlistKey = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CurseForgeAPIKey"];
    if ([infoPlistKey isKindOfClass:NSString.class] && infoPlistKey.length > 0) {
        return YES;
    }
    return NO;
}

// ★ [MODPACK-FIX] CurseForge 源可用性 —— 恒定 YES。
//   key 仅「官方直连」需要；未配 key 时 baseURL 强制落 MCIM 镜像（免 key，实测 200），
//   源对所有人可用。凡「切到 CurseForge 源前先查 key」的 UI 门控都必须用本方法，
//   否则无 key 构建（所有 CI/sideload 构建）会被直接挡在门外并弹报错/被重定向到设置页。
+ (BOOL)isSourceAvailable {
    return YES;
}

- (NSError *)missingAPIKeyError {
    // ★ [MODPACK-FIX] 面向用户的文案改为可执行的引导（复用已有 i18n 键，指向设置页
    //   CurseForge API Key 入口），不再是英文死路 "Set CURSEFORGE_API_KEY before building"。
    //   注意：正常情况下无 key 已走镜像免 key 路径，本错误仅在镜像亦不可达时兜底。
    return [NSError errorWithDomain:@"CurseForgeAPI"
                               code:401
                           userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_172", nil)}];
}

#pragma mark - 错误诊断辅助

- (NSError *)errorWithResponse:(NSURLResponse *)response
                          data:(NSData *)data
                 originalError:(NSError *)originalError
                       snippet:(NSString *)snippet {
    NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    NSInteger statusCode = httpResponse.statusCode;
    NSString *contentType = httpResponse.allHeaderFields[@"Content-Type"];

    // 取响应体前 1024 字节作为 snippet（如果调用方未提供）
    if (!snippet && data.length > 0) {
        snippet = [self printableStringFromData:data maxLen:1024];
    }

    // 构造 userInfo
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    if (originalError) {
        [userInfo addEntriesFromDictionary:originalError.userInfo];
        if (originalError.localizedDescription.length > 0) {
            userInfo[NSLocalizedDescriptionKey] = originalError.localizedDescription;
        }
    } else {
        userInfo[NSLocalizedDescriptionKey] = @"CurseForge API request failed";
    }
    if (statusCode > 0) {
        userInfo[@"CurseForgeHTTPStatusCodeKey"] = @(statusCode);
    }
    if (contentType.length > 0) {
        userInfo[CurseForgeResponseContentTypeKey] = contentType;
    }
    if (snippet.length > 0) {
        userInfo[CurseForgeResponseSnippetKey] = snippet;
    }

    // 打印诊断日志
    NSLog(@"[CurseForgeAPI] ❌ Request failed - statusCode=%ld, contentType=%@, error=%@, snippet=%@",
          (long)statusCode, contentType, originalError.localizedDescription, snippet);

    return [NSError errorWithDomain:@"CurseForgeAPI"
                               code:originalError.code ?: 0
                           userInfo:[userInfo copy]];
}

#pragma mark - 调试日志辅助

// 将 NSData 转为可打印字符串（处理非 UTF-8 内容，最多 maxLen 字节）
- (NSString *)printableStringFromData:(NSData *)data maxLen:(NSUInteger)maxLen {
    if (!data || data.length == 0) return @"";
    NSUInteger len = MIN(data.length, maxLen);
    NSData *subData = [data subdataWithRange:NSMakeRange(0, len)];
    // 尝试 UTF-8
    NSString *str = [[NSString alloc] initWithData:subData encoding:NSUTF8StringEncoding];
    if (str) return str;
    // 尝试 ISO-8859-1（Latin-1，能解码任意字节）
    str = [[NSString alloc] initWithData:subData encoding:NSISOLatin1StringEncoding];
    if (str) return str;
    // 兜底：十六进制
    NSMutableString *hex = [NSMutableString stringWithCapacity:len * 3];
    const char *bytes = subData.bytes;
    for (NSUInteger i = 0; i < len; i++) {
        [hex appendFormat:@"%02x ", (unsigned char)bytes[i]];
    }
    return [NSString stringWithFormat:@"(non-text data, hex) %@", hex];
}

// 输出请求/响应/JSON 解析错误的完整调试日志
- (void)debugLogRequest:(NSURLRequest *)request
               response:(NSURLResponse *)response
                   data:(NSData *)data
              jsonError:(NSError *)jsonError {
    NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    NSInteger statusCode = httpResponse.statusCode;
    NSString *contentType = httpResponse.allHeaderFields[@"Content-Type"];
    NSURL *url = request.URL;
    NSString *method = request.HTTPMethod ?: @"GET";

    NSLog(@"\n"
          "========== [CurseForgeAPI] DEBUG ==========\n"
          "📍 Request: %@ %@\n"
          "📍 Request Headers:",
          method, url.absoluteString ?: @"<nil URL>");

    // 打印请求头（脱敏 API Key）
    NSDictionary *reqHeaders = request.allHTTPHeaderFields ?: @{};
    for (NSString *key in reqHeaders) {
        NSString *value = reqHeaders[key];
        if ([key.lowercaseString containsString:@"api"] || [key.lowercaseString containsString:@"key"]) {
            // 只显示前 8 位 + 长度
            if (value.length > 8) {
                NSLog(@"    %@: %@... (len=%lu)", key, [value substringToIndex:8], (unsigned long)value.length);
            } else {
                NSLog(@"    %@: (len=%lu)", key, (unsigned long)value.length);
            }
        } else {
            NSLog(@"    %@: %@", key, value);
        }
    }

    NSLog(@"📍 Response: statusCode=%ld, contentType=%@, dataLength=%lu",
          (long)statusCode, contentType ?: @"<none>", (unsigned long)(data.length));

    if (httpResponse) {
        // 打印响应头（最多 20 项）
        NSDictionary *respHeaders = httpResponse.allHeaderFields;
        NSUInteger i = 0;
        for (NSString *key in respHeaders) {
            if (i++ >= 20) break;
            NSLog(@"    %@: %@", key, respHeaders[key]);
        }
    }

    if (jsonError) {
        NSLog(@"📍 JSON Parse Error: domain=%@, code=%ld, desc=%@",
              jsonError.domain, (long)jsonError.code,
              jsonError.localizedDescription ?: @"<no description>");
    }

    if (data.length > 0) {
        NSString *bodyStr = [self printableStringFromData:data maxLen:2048];
        NSLog(@"📍 Response Body (first 2048 bytes):\n%@", bodyStr);
    } else {
        NSLog(@"📍 Response Body: (empty)");
    }
    NSLog(@"========== [CurseForgeAPI] END DEBUG ==========");
}

#pragma mark - 同步网络请求（原有 AFNetworking 实现，保持兼容）

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    // ★ [MODPACK-FIX] 不再把 headers==nil 当作致命门：headers 现无 key 也返回
    //   Accept-only 字典（keyless 请求走 MCIM 镜像，实测 200）。
    NSDictionary *headers = [self headers];
    
    __block id result;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    [manager GET:url parameters:params headers:headers progress:nil
          success:^(NSURLSessionTask *task, id obj) {
        result = obj;
        dispatch_group_leave(group);
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        self.lastError = error;
        dispatch_group_leave(group);
    }];
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    return result;
}

- (id)postEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    // ★ [MODPACK-FIX] 同 getEndpoint：headers 恒非 nil，去掉 keyless 致命门。
    NSDictionary *headers = [self headers];
    
    __block id result;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    manager.requestSerializer = [AFJSONRequestSerializer serializer];
    [manager POST:url parameters:params headers:headers progress:nil
           success:^(NSURLSessionTask *task, id obj) {
        result = obj;
        dispatch_group_leave(group);
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        self.lastError = error;
        dispatch_group_leave(group);
    }];
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    return result;
}

#pragma mark - 项目类型映射

- (NSNumber *)classIDForProjectType:(NSString *)projectType {
    if ([projectType isEqualToString:@"modpack"]) {
        return @(kCurseForgeClassIDModpacks);
    }
    if ([projectType isEqualToString:@"plugin"]) {
        return @(kCurseForgeClassIDBukkitPlugins);
    }
    if ([projectType isEqualToString:@"datapack"]) {
        return @(kCurseForgeClassIDDataPacks);
    }
    if ([projectType isEqualToString:@"shader"]) {
        return @(kCurseForgeClassIDShaders);
    }
    if ([projectType isEqualToString:@"resourcepack"]) {
        return @(kCurseForgeClassIDResourcePacks);
    }
    if ([projectType isEqualToString:@"world"]) {
        return @(kCurseForgeClassIDWorlds);
    }
    return @(kCurseForgeClassIDMods);
}

- (NSArray<NSString *> *)preferredFileExtensionsForProjectType:(NSString *)projectType {
    if ([projectType isEqualToString:@"shader"] ||
        [projectType isEqualToString:@"resourcepack"] ||
        [projectType isEqualToString:@"datapack"] ||
        [projectType isEqualToString:@"modpack"] ||
        [projectType isEqualToString:@"world"]) {
        return @[@"zip"];
    }
    return @[@"jar"];
}

#pragma mark - 文件校验与 URL 构造

- (BOOL)file:(NSDictionary *)file matchesProjectType:(NSString *)projectType {
    if (![file isKindOfClass:NSDictionary.class]) return NO;
    if ([file[@"isAvailable"] respondsToSelector:@selector(boolValue)] &&
        ![file[@"isAvailable"] boolValue]) {
        return NO;
    }
    if ([projectType isEqualToString:@"modpack"] && [file[@"isServerPack"] boolValue]) {
        return NO;
    }
    
    NSString *fileName = [file[@"fileName"] isKindOfClass:NSString.class] ? file[@"fileName"] : @"";
    NSString *extension = fileName.pathExtension.lowercaseString;
    NSArray *extensions = [self preferredFileExtensionsForProjectType:projectType];
    return extensions.count == 0 || [extensions containsObject:extension];
}

- (NSString *)imageURLForProject:(NSDictionary *)project {
    NSDictionary *logo = [project[@"logo"] isKindOfClass:NSDictionary.class] ? project[@"logo"] : nil;
    NSString *image = logo[@"thumbnailUrl"];
    if (![image isKindOfClass:NSString.class] || image.length == 0) {
        image = logo[@"url"];
    }
    return [image isKindOfClass:NSString.class] ? image : @"";
}

- (NSMutableDictionary *)projectFromCurseForgeProject:(NSDictionary *)project projectType:(NSString *)projectType {
    NSString *title = project[@"name"];
    NSString *description = project[@"summary"];
    return @{
        @"apiSource": @(2),
        @"isModpack": @([projectType isEqualToString:@"modpack"]),
        @"projectType": projectType ?: @"mod",
        @"id": [project[@"id"] description] ?: @"",
        @"title": [title isKindOfClass:NSString.class] ? title : @"",
        @"description": [description isKindOfClass:NSString.class] ? description : @"",
        @"imageUrl": [self imageURLForProject:project]
    }.mutableCopy;
}

- (NSString *)sha1ForFile:(NSDictionary *)file {
    NSArray *hashes = [file[@"hashes"] isKindOfClass:NSArray.class] ? file[@"hashes"] : @[];
    for (NSDictionary *hash in hashes) {
        if ([hash[@"algo"] integerValue] == 1 && [hash[@"value"] isKindOfClass:NSString.class]) {
            return hash[@"value"];
        }
    }
    return @"";
}

- (NSString *)downloadURLForFile:(NSDictionary *)file {
    NSString *url = file[@"downloadUrl"];
    if ([url isKindOfClass:NSString.class] && url.length > 0) {
        return CFAMirrorResolvedURL(url);
    }

    NSString *modId = [file[@"modId"] description];
    NSString *fileId = [file[@"id"] description];
    if (modId.length == 0 || fileId.length == 0) {
        return @"";
    }
    NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files/%@/download-url", modId, fileId] params:nil];
    NSString *fallback = [response isKindOfClass:NSDictionary.class] ? response[@"data"] : nil;
    if ([fallback isKindOfClass:NSString.class] && fallback.length > 0) {
        return CFAMirrorResolvedURL(fallback);
    }

    // 最终 fallback：Edge CDN
    NSString *fileName = [file[@"fileName"] isKindOfClass:NSString.class] ? file[@"fileName"] : @"";
    NSInteger numericFileId = fileId.integerValue;
    if (numericFileId <= 0 || fileName.length == 0) {
        return @"";
    }
    NSString *encodedName = [fileName stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    NSString *cdnURL = [NSString stringWithFormat:@"https://edge.forgecdn.net/files/%ld/%03ld/%@",
            (long)(numericFileId / 1000),
            (long)(numericFileId % 1000),
            encodedName ?: fileName];
    return CFAMirrorResolvedURL(cdnURL);
}

- (NSString *)gameVersionSummaryForFile:(NSDictionary *)file {
    NSArray<NSString *> *gameVersions = [file[@"gameVersions"] isKindOfClass:NSArray.class] ? file[@"gameVersions"] : @[];
    NSMutableArray<NSString *> *minecraftVersions = [NSMutableArray new];
    NSMutableArray<NSString *> *loaders = [NSMutableArray new];
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    for (NSString *value in gameVersions) {
        if (![value isKindOfClass:NSString.class] || value.length == 0) continue;
        unichar first = [value characterAtIndex:0];
        if ([digits characterIsMember:first]) {
            [minecraftVersions addObject:value];
        } else if ([value rangeOfString:@"client" options:NSCaseInsensitiveSearch].location == NSNotFound &&
                   [value rangeOfString:@"server" options:NSCaseInsensitiveSearch].location == NSNotFound) {
            [loaders addObject:value];
        }
    }
    NSString *mcVersion = minecraftVersions.firstObject ?: @"";
    NSString *loader = loaders.firstObject ?: @"";
    if (mcVersion.length > 0 && loader.length > 0) {
        return [NSString stringWithFormat:@"%@/%@", mcVersion, loader];
    }
    return mcVersion.length > 0 ? mcVersion : loader;
}

#pragma mark - 同步搜索（原始实现）

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters
                     previousPageResult:(NSMutableArray *)previousPageResult {
    int pageSize = 50;
    NSString *projectType = searchFilters[@"projectType"];
    if (projectType.length == 0) {
        projectType = searchFilters[@"isModpack"] ? ([searchFilters[@"isModpack"] boolValue] ? @"modpack" : @"mod") : @"modpack";
    }
    
    NSMutableDictionary *params = @{
        @"gameId": @(kCurseForgeGameIDMinecraft),
        @"classId": [self classIDForProjectType:projectType],
        @"pageSize": @(pageSize),
        @"index": @(previousPageResult.count)
    }.mutableCopy;
    NSString *query = [searchFilters[@"name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (query.length > 0) {
        params[@"searchFilter"] = query;
    }
    if (searchFilters[@"mcVersion"].length > 0) {
        params[@"gameVersion"] = searchFilters[@"mcVersion"];
    }
    if ([projectType isEqualToString:@"minecraft_java_server"]) {
        params[@"categoryId"] = @(kCurseForgeCategoryIDServerUtility);
    }
    
    NSDictionary *response = [self getEndpoint:@"mods/search" params:params];
    if (!response) return nil;
    
    NSMutableArray *result = previousPageResult ?: [NSMutableArray new];
    NSArray *projects = [response[@"data"] isKindOfClass:NSArray.class] ? response[@"data"] : @[];
    for (NSDictionary *project in projects) {
        if (![project isKindOfClass:NSDictionary.class]) continue;
        [result addObject:[self projectFromCurseForgeProject:project projectType:projectType]];
    }
    
    NSDictionary *pagination = [response[@"pagination"] isKindOfClass:NSDictionary.class] ? response[@"pagination"] : @{};
    NSUInteger total = [pagination[@"totalCount"] unsignedIntegerValue];
    NSUInteger index = [pagination[@"index"] unsignedIntegerValue];
    NSUInteger count = [pagination[@"resultCount"] unsignedIntegerValue];
    self.reachedLastPage = total == 0 || index + count >= total;
    return result;
}

#pragma mark - 同步加载详情

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSString *projectId = [item[@"id"] description];
    if (projectId.length == 0) return;
    
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
    NSMutableArray<NSString *> *urls = [NSMutableArray new];
    NSMutableArray<NSString *> *hashes = [NSMutableArray new];
    NSMutableArray<NSString *> *sizes = [NSMutableArray new];
    NSMutableArray<NSString *> *fileNames = [NSMutableArray new];
    NSMutableArray<NSString *> *fileTypes = [NSMutableArray new];
    NSString *projectType = item[@"projectType"] ?: @"mod";
    
    NSUInteger index = 0;
    NSUInteger total = NSUIntegerMax;
    while (index < total) {
        NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files", projectId]
                                            params:@{@"pageSize": @10000, @"index": @(index)}];
        if (!response) return;
        
        NSArray *files = [response[@"data"] isKindOfClass:NSArray.class] ? response[@"data"] : @[];
        for (NSDictionary *file in files) {
            [self addFile:file toNames:names mcNames:mcNames urls:urls hashes:hashes sizes:sizes fileNames:fileNames fileTypes:fileTypes projectType:projectType];
        }
        
        NSDictionary *pagination = [response[@"pagination"] isKindOfClass:NSDictionary.class] ? response[@"pagination"] : @{};
        total = [pagination[@"totalCount"] unsignedIntegerValue];
        NSUInteger resultCount = [pagination[@"resultCount"] unsignedIntegerValue];
        if (resultCount == 0) break;
        index += resultCount;
    }
    
    if (names.count == 0) {
        self.lastError = [NSError errorWithDomain:@"CurseForgeAPI"
                                             code:404
                                         userInfo:@{NSLocalizedDescriptionKey: @"No downloadable files were found for this CurseForge project."}];
        return;
    }
    
    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionFileNames"] = fileNames;
    item[@"versionFileTypes"] = fileTypes;
    item[@"versionDetailsLoaded"] = @(YES);
}

// 辅助：添加单个文件信息到数组（供 loadDetailsOfMod 内部调用）
- (void)addFile:(NSDictionary *)file toNames:(NSMutableArray *)names mcNames:(NSMutableArray *)mcNames urls:(NSMutableArray *)urls hashes:(NSMutableArray *)hashes sizes:(NSMutableArray *)sizes fileNames:(NSMutableArray *)fileNames fileTypes:(NSMutableArray *)fileTypes projectType:(NSString *)projectType {
    if (![self file:file matchesProjectType:projectType]) return;
    NSString *url = [self downloadURLForFile:file];
    if (url.length == 0) return;
    
    NSString *name = file[@"displayName"];
    if (![name isKindOfClass:NSString.class] || name.length == 0) {
        name = file[@"fileName"];
    }
    NSString *fileName = file[@"fileName"];
    if (![fileName isKindOfClass:NSString.class] || fileName.length == 0) {
        fileName = url.lastPathComponent;
    }
    
    [names addObject:name ?: @"Download"];
    [mcNames addObject:[self gameVersionSummaryForFile:file] ?: @""];
    [sizes addObject:file[@"fileLength"] ?: @0];
    [urls addObject:url];
    [hashes addObject:[self sha1ForFile:file] ?: @""];
    [fileNames addObject:fileName ?: @"download"];
    [fileTypes addObject:@""];
}

#pragma mark - 异步搜索（新增，推荐）

- (void)searchModWithFilters:(NSDictionary *)filters
                  completion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    NSString *projectType = filters[@"projectType"];
    if (projectType.length == 0) {
        // 防御性回退：与同步版本一致，未指定 projectType 但声明 isModpack 时按整合包搜索
        projectType = [filters[@"isModpack"] boolValue] ? @"modpack" : @"mod";
    }
    NSString *query = filters[@"query"] ?: filters[@"name"] ?: @"";
    NSNumber *limitNum = filters[@"limit"] ?: @50;
    int limit = [limitNum intValue];
    NSNumber *offsetNum = filters[@"offset"] ?: @0;
    int offset = [offsetNum intValue];
    NSString *mcVersion = filters[@"mcVersion"] ?: filters[@"version"];
    
    // 构造 URL
    NSMutableString *urlString = [NSMutableString stringWithFormat:@"%@/mods/search?gameId=%ld&classId=%@&pageSize=%d&index=%d",
                                  self.baseURL,
                                  (long)kCurseForgeGameIDMinecraft,
                                  [self classIDForProjectType:projectType],
                                  limit, offset];
    if (query.length > 0) {
        NSString *encodedQuery = [query stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        [urlString appendFormat:@"&searchFilter=%@", encodedQuery];
    }
    if (mcVersion.length > 0) {
        [urlString appendFormat:@"&gameVersion=%@", mcVersion];
    }
    
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"CurseForgeAPI" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        return;
    }
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    NSDictionary *headers = [self headers];
    // ★ [MODPACK-FIX] keyless 不再拦截（旧：headers==nil -> 立即 missingAPIKeyError，
    //   请求根本不发出，使 Task162 的镜像回退成死代码）。headers 无 key 时也返回
    //   Accept-only 字典，照常发往 MCIM 镜像。for-in 对 nil 本就安全，此处不加门。
    for (NSString *key in headers) {
        [request setValue:headers[key] forHTTPHeaderField:key];
    }
    request.timeoutInterval = 30.0;
    NSLog(@"[CurseForgeAPI] searchModWithFilters starting request: %@", urlString);

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            // 网络错误：透传原 NSError 并附带 HTTP 诊断信息（如可获取）
            NSLog(@"[CurseForgeAPI] searchModWithFilters network error: %@", error.localizedDescription);
            [self debugLogRequest:request response:response data:data jsonError:nil];
            NSError *diagnosticError = [self errorWithResponse:response data:data originalError:error snippet:nil];
            if (completion) completion(nil, diagnosticError);
            return;
        }
        if (!data || data.length == 0) {
            // 响应数据为空：返回包含 HTTP 状态码的 NSError
            NSLog(@"[CurseForgeAPI] searchModWithFilters empty response");
            [self debugLogRequest:request response:response data:data jsonError:nil];
            NSError *emptyError = [NSError errorWithDomain:@"CurseForgeAPI"
                                                      code:2
                                                  userInfo:@{NSLocalizedDescriptionKey: @"CurseForge API returned empty response"}];
            NSError *diagnosticError = [self errorWithResponse:response data:data originalError:emptyError snippet:nil];
            if (completion) completion(nil, diagnosticError);
            return;
        }

        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![json isKindOfClass:NSDictionary.class]) {
            // JSON 解析失败：输出完整调试日志，便于诊断 401 HTML 错误页等场景
            NSLog(@"[CurseForgeAPI] searchModWithFilters JSON parse failed");
            [self debugLogRequest:request response:response data:data jsonError:jsonError];
            NSError *baseError = jsonError ?: [NSError errorWithDomain:@"CurseForgeAPI"
                                                                   code:3
                                                               userInfo:@{NSLocalizedDescriptionKey: @"CurseForge API returned non-JSON response"}];
            NSError *diagnosticError = [self errorWithResponse:response data:data originalError:baseError snippet:nil];
            if (completion) completion(nil, diagnosticError);
            return;
        }
        
        NSArray *projects = json[@"data"];
        if (![projects isKindOfClass:NSArray.class]) { if (completion) completion(@[], nil); return; }

        NSMutableArray *results = [NSMutableArray array];
        for (NSDictionary *project in projects) {
            if (![project isKindOfClass:NSDictionary.class]) continue;
            [results addObject:[self projectFromCurseForgeProject:project projectType:projectType]];
        }

        // 更新分页状态
        NSDictionary *pagination = json[@"pagination"] ?: @{};
        NSUInteger total = [pagination[@"totalCount"] unsignedIntegerValue];
        NSUInteger idx = [pagination[@"index"] unsignedIntegerValue];
        NSUInteger count = [pagination[@"resultCount"] unsignedIntegerValue];
        self.reachedLastPage = total == 0 || idx + count >= total;

        NSLog(@"[CurseForgeAPI] searchModWithFilters success: returned %lu items (total=%lu)",
              (unsigned long)results.count, (unsigned long)total);
        if (completion) completion(results, nil);
    }];
    [task resume];
}

#pragma mark - 异步获取版本

- (void)getVersionsForModWithID:(NSString *)modID
                     completion:(void (^)(NSArray<ModVersion *> * _Nullable, NSError * _Nullable))completion {
    if (modID.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"CurseForgeAPI" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid mod ID"}]);
        return;
    }

    // 直接异步调用 loadDetailsOfMod:completion:，避免阻塞调用线程
    NSMutableDictionary *item = [@{@"id": modID, @"projectType": @"mod"} mutableCopy];
    [self loadDetailsOfMod:item completion:^(NSError * _Nullable error) {
        if (error) {
            if (completion) completion(nil, error);
            return;
        }
        if (completion) completion(item[@"versions"], nil);
    }];
}

// Task 5.10：在线整合包下载路径统一——zip 下载完成后由
// MinecraftResourceDownloadTask.importDownloadedModpackPackage:detail: 复用
// ModpackImportService 统一导入（解析/解压/依赖下载/加载器/游戏文件/profile），
// 此处不再维护 API 侧的整合包解包双轨逻辑（modpackDependencyInfoFromManifest:/
// fileForProjectID:fileID:/filesByFileID:/submitDownloadTasksFromPackage: 已删除）。

- (NSMutableDictionary *)projectForFileHash:(NSNumber *)fingerprint projectType:(NSString *)projectType {
    // 修复：本方法接收的是 MurmurHash2 指纹数字（由 CurseForgeMurmurHash 对文件计算得到），
    // 原签名接收 NSString 且内部 [murmurHash longLongValue]，调用方传入文件路径时恒为 0，永不命中
    if (![fingerprint isKindOfClass:[NSNumber class]]) return nil;
    NSString *urlStr = [NSString stringWithFormat:@"%@/fingerprints/%ld", self.baseURL, (long)kCurseForgeGameIDMinecraft];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    // ★ [MODPACK-FIX] 空 key 不发空 x-api-key 头（空值头会被 MCIM 镜像网关当成坏请求）
    {
        NSString *modpackFixKey = [self apiKey];
        if (modpackFixKey.length > 0) {
            [request setValue:modpackFixKey forHTTPHeaderField:@"x-api-key"];
        }
    }
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{@"fingerprints": @[fingerprint]};
    NSError *jsonError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (jsonError) return nil;
    request.HTTPBody = bodyData;

    __block NSMutableDictionary *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *exactMatches = [json isKindOfClass:NSDictionary.class] ? json[@"data"][@"exactMatches"] : nil;
            if ([exactMatches isKindOfClass:NSArray.class] && exactMatches.count > 0) {
                NSDictionary *match = [exactMatches[0] isKindOfClass:NSDictionary.class] ? exactMatches[0] : nil;
                NSDictionary *file = [match[@"file"] isKindOfClass:NSDictionary.class] ? match[@"file"] : nil;
                if (file) {
                    result = [NSMutableDictionary dictionary];
                    // 修复：exactMatches[].id 是文件 ID 而非项目 ID，项目 ID 必须取 file.modId，
                    // 否则后续 mods/{id}/files 拉版本列表会查错项目
                    result[@"id"] = [file[@"modId"] stringValue];
                    result[@"fileId"] = [file[@"id"] stringValue];
                    result[@"name"] = file[@"displayName"];
                }
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    return result;
}

#pragma mark - 批量指纹反查

- (NSArray<NSMutableDictionary *> *)fileFingerprints:(NSArray<NSNumber *> *)fingerprints {
    if (!fingerprints || fingerprints.count == 0) return @[];
    NSString *urlStr = [NSString stringWithFormat:@"%@/fingerprints/%ld", self.baseURL, (long)kCurseForgeGameIDMinecraft];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return @[];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    // ★ [MODPACK-FIX] 空 key 不发空 x-api-key 头（空值头会被 MCIM 镜像网关当成坏请求）
    {
        NSString *modpackFixKey = [self apiKey];
        if (modpackFixKey.length > 0) {
            [request setValue:modpackFixKey forHTTPHeaderField:@"x-api-key"];
        }
    }
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{@"fingerprints": fingerprints};
    NSError *bodyError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&bodyError];
    if (bodyError) return @[];
    request.HTTPBody = bodyData;

    __block NSMutableArray *results = [NSMutableArray array];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *exactMatches = [json isKindOfClass:NSDictionary.class] ? json[@"data"][@"exactMatches"] : nil;
            if ([exactMatches isKindOfClass:NSArray.class]) {
                for (NSDictionary *match in exactMatches) {
                    if (![match isKindOfClass:NSDictionary.class]) continue;
                    NSDictionary *file = [match[@"file"] isKindOfClass:[NSDictionary class]] ? match[@"file"] : nil;
                    if (!file) continue;
                    NSMutableDictionary *item = [NSMutableDictionary dictionary];
                    // 修复：与 projectForFileHash 一致，项目 ID 取 file.modId（exactMatches[].id 是文件 ID），
                    // 名称取 file.displayName（顶层无 name 字段）
                    item[@"id"] = [file[@"modId"] stringValue];
                    item[@"fileId"] = [file[@"id"] stringValue];
                    item[@"name"] = file[@"displayName"];
                    [results addObject:item];
                }
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    return results;
}

#pragma mark - 异步详情加载

- (void)loadDetailsOfMod:(NSMutableDictionary *)item completion:(void (^)(NSError * _Nullable error))completion {
    NSString *modID = [item[@"id"] description];
    if (modID.length == 0) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion([NSError errorWithDomain:@"CurseForgeAPI" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid mod ID"}]);
        });
        return;
    }
    NSString *urlStr = [NSString stringWithFormat:@"%@/mods/%@/files", self.baseURL, modID];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion([NSError errorWithDomain:@"CurseForgeAPI" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        });
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    // ★ [MODPACK-FIX] 空 key 不发空 x-api-key 头（空值头会被 MCIM 镜像网关当成坏请求）
    {
        NSString *modpackFixKey = [self apiKey];
        if (modpackFixKey.length > 0) {
            [request setValue:modpackFixKey forHTTPHeaderField:@"x-api-key"];
        }
    }
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    request.timeoutInterval = 30.0;
    NSLog(@"[CurseForgeAPI] loadDetailsOfMod starting request modID=%@: %@", modID, urlStr);

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            // 网络错误：透传并附带诊断信息
            NSLog(@"[CurseForgeAPI] loadDetailsOfMod network error: %@", error.localizedDescription);
            [self debugLogRequest:request response:response data:data jsonError:nil];
            NSError *diagnosticError = [self errorWithResponse:response data:data originalError:error snippet:nil];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(diagnosticError); });
            return;
        }
        if (!data || data.length == 0) {
            // 响应数据为空
            NSLog(@"[CurseForgeAPI] loadDetailsOfMod empty response");
            [self debugLogRequest:request response:response data:data jsonError:nil];
            NSError *emptyError = [NSError errorWithDomain:@"CurseForgeAPI"
                                                      code:2
                                                  userInfo:@{NSLocalizedDescriptionKey: @"CurseForge API returned empty response"}];
            NSError *diagnosticError = [self errorWithResponse:response data:data originalError:emptyError snippet:nil];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(diagnosticError); });
            return;
        }

        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![json isKindOfClass:NSDictionary.class]) {
            // JSON 解析失败：输出完整调试日志
            NSLog(@"[CurseForgeAPI] loadDetailsOfMod JSON parse failed");
            [self debugLogRequest:request response:response data:data jsonError:jsonError];
            NSError *baseError = jsonError ?: [NSError errorWithDomain:@"CurseForgeAPI"
                                                                   code:3
                                                               userInfo:@{NSLocalizedDescriptionKey: @"CurseForge API returned non-JSON response"}];
            NSError *diagnosticError = [self errorWithResponse:response data:data originalError:baseError snippet:nil];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(diagnosticError); });
            return;
        }

        NSArray *files = [json isKindOfClass:NSDictionary.class] ? json[@"data"] : nil;
        if (![files isKindOfClass:NSArray.class]) files = @[];
        NSMutableArray *versions = [NSMutableArray array];
        for (NSDictionary *file in files) {
            if (![file isKindOfClass:NSDictionary.class]) continue;
            ModVersion *mv = [[ModVersion alloc] initWithDictionary:file];
            if (mv) [versions addObject:mv];
        }
        item[@"versions"] = versions;
        NSLog(@"[CurseForgeAPI] loadDetailsOfMod success: modID=%@, %lu versions",
              modID, (unsigned long)versions.count);
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
    }];
    [task resume];
}

#pragma mark - Server Packs（服务端整合包）

- (void)searchServersWithFilters:(NSDictionary *)filters
                      completion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    // CurseForge 没有独立的 server 类型，使用 modpack（classId=4471）作为"服务器整合包"展示
    NSMutableDictionary *serverFilters = [filters mutableCopy] ?: [NSMutableDictionary dictionary];
    serverFilters[@"projectType"] = @"modpack";
    // 复用现有的异步 modpack 搜索逻辑
    [self searchModWithFilters:serverFilters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        if (error) {
            if (completion) completion(nil, error);
            return;
        }
        // 在每个结果中追加 serverID 字段，便于 ServerItem 统一识别
        NSMutableArray *serverResults = [NSMutableArray array];
        for (NSDictionary *item in results) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *serverItem = [item mutableCopy];
            serverItem[@"serverID"] = item[@"id"] ?: @"";
            serverItem[@"projectType"] = @"modpack";
            [serverResults addObject:serverItem];
        }
        if (completion) completion(serverResults, nil);
    }];
}

- (void)getServerPackFilesForModpack:(NSString *)modpackID
                          completion:(void (^)(NSArray * _Nullable, NSError * _Nullable error))completion {
    if (modpackID.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"CurseForgeAPI" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid modpack ID"}]);
        return;
    }

    // 拉取该 modpack 的所有文件，筛选 isServerPack=true 的文件
    NSString *urlStr = [NSString stringWithFormat:@"%@/mods/%@/files?pageSize=10000", self.baseURL, modpackID];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"CurseForgeAPI" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    // ★ [MODPACK-FIX] 空 key 不发空 x-api-key 头（空值头会被 MCIM 镜像网关当成坏请求）
    {
        NSString *modpackFixKey = [self apiKey];
        if (modpackFixKey.length > 0) {
            [request setValue:modpackFixKey forHTTPHeaderField:@"x-api-key"];
        }
    }
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    request.timeoutInterval = 30.0;
    NSLog(@"[CurseForgeAPI] 🔍 getServerPackFilesForModpack: %@", urlStr);

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSError *diagnosticError = [self errorWithResponse:response data:data originalError:error snippet:nil];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, diagnosticError); });
            return;
        }
        if (!data || data.length == 0) {
            NSError *emptyError = [NSError errorWithDomain:@"CurseForgeAPI" code:3 userInfo:@{NSLocalizedDescriptionKey: @"CurseForge API returned empty response"}];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, emptyError); });
            return;
        }
        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![json isKindOfClass:NSDictionary.class]) {
            NSError *baseError = jsonError ?: [NSError errorWithDomain:@"CurseForgeAPI" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON"}];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, baseError); });
            return;
        }

        NSArray *files = [json[@"data"] isKindOfClass:[NSArray class]] ? json[@"data"] : @[];
        NSMutableArray *serverPacks = [NSMutableArray array];
        for (NSDictionary *file in files) {
            if (![file isKindOfClass:[NSDictionary class]]) continue;
            // 筛选 isServerPack=true 的文件（与 loadDetailsOfMod 中排除 server pack 的逻辑相反）
            if (![file[@"isServerPack"] boolValue]) continue;
            // 解析下载 URL 和文件名
            NSString *dlURL = [self downloadURLForFile:file];
            NSString *fileName = [file[@"fileName"] isKindOfClass:[NSString class]] ? file[@"fileName"] : @"";
            NSString *displayName = [file[@"displayName"] isKindOfClass:[NSString class]] ? file[@"displayName"] : fileName;
            [serverPacks addObject:@{
                @"serverPackDownloadURL": dlURL ?: @"",
                @"serverPackFileName": fileName ?: @"",
                @"serverPackDisplayName": displayName ?: fileName ?: @"",
                @"serverPackFileSize": file[@"fileLength"] ?: @0,
                @"fileId": [file[@"id"] description] ?: @"",
                @"modpackId": modpackID
            }];
        }
        NSLog(@"[CurseForgeAPI] getServerPackFilesForModpack success: modpackID=%@, %lu server packs",
              modpackID, (unsigned long)serverPacks.count);
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(serverPacks, nil); });
    }];
    [task resume];
}

@end