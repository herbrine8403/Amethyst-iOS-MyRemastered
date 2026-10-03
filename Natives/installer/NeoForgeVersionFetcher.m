#import "NeoForgeVersionFetcher.h"
#import "PLMirrorCenter.h"

#pragma mark - ★ [PCL-ALIGN] 版本列表拉取工具（与 ForgeInstallViewController.m 保持同一实现风格）
//
// 背景：NeoForgeVersionFetcher 原先只认官方 maven API 的 {"versions":[...]} 形态，
// 且把官方源当首选（国内常不可达/60s 卡死），并且没有磁盘缓存 ⇒ 用户报
// “PCL 能找到 neoforge，我们不行”。此处对齐 PCL2 ModDownload.vb / ModNet.vb：
//   ① 解析与 JSON 形态无关（目录式 / versions / list 数组三种通吃 + rawVersion 归一化）；
//   ② 源顺序“快→慢”：BMCLAPI 轻接口 → BMCLAPI 目录式 → 官方 API（仅兜底，短超时）；
//   ③ 成功结果写磁盘缓存，短期内重进不再打网。

// ★ [PCL-ALIGN] 同步 GET（带超时 + 线性退避重试），非 2xx 视为失败。
//   等价于 PCL2 NetRequestByClientRetry（ModNet.vb）；全失败返回 nil。
static NSData *PALFetchWithRetry(NSString *urlString, NSInteger maxAttempts, NSTimeInterval timeout) {
    if (urlString.length == 0) return nil;
    if (maxAttempts < 1) maxAttempts = 1;
    if (timeout <= 0) timeout = 12.0;
    NSString *userAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";
    for (NSInteger attempt = 1; attempt <= maxAttempts; attempt++) {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
        req.timeoutInterval = timeout;
        req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        [req setValue:userAgent forHTTPHeaderField:@"User-Agent"];
        __block NSData *d = nil;
        __block NSInteger status = 0;
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                d = data;
                if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                    status = ((NSHTTPURLResponse *)response).statusCode;
                }
                dispatch_semaphore_signal(sem);
            }];
        [task resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 5.0) * NSEC_PER_SEC)));
        BOOL httpOK = (status == 0 || (status >= 200 && status < 300));
        if (d.length > 0 && httpOK) return d;
        NSLog(@"[PCL-ALIGN] NeoForge fetch attempt %ld/%ld failed (http=%ld, bytes=%lu) %@",
              (long)attempt, (long)maxAttempts, (long)status, (unsigned long)d.length, urlString);
        if (attempt < maxAttempts) [NSThread sleepForTimeInterval:1.2 * (double)attempt];
    }
    return nil;
}

// ★ [PCL-ALIGN] NeoForge 版本号形态（语义对齐 PCL2 ModDownload.vb GetNeoForgeEntries 的正则）：
//   (1.20.1-)?<num>.<seg>.<num>[.<num>][(-beta|-alpha)[.<num>]][+snapshot-<num>]
static NSRegularExpression *PALNeoForgeVersionRegex(void) {
    static NSRegularExpression *regex = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:
                 @"^(?:1\\.20\\.1-)?\\d+\\.[^\\.]+\\.[0-9]+(?:\\.[0-9]+)?(?:-(?:beta|alpha)(?:\\.[0-9]+)?)?(?:\\+snapshot-[0-9]+)?$"
                 options:0 error:nil];
    });
    return regex;
}
static BOOL PALLooksLikeNeoForgeVersion(NSString *name) {
    if (![name isKindOfClass:[NSString class]] || name.length == 0) return NO;
    NSRegularExpression *re = PALNeoForgeVersionRegex();
    if (!re) return NO;
    return [re firstMatchInString:name options:0 range:NSMakeRange(0, name.length)] != nil;
}

// ★ [PCL-ALIGN] 解析 NeoForge 版本列表 JSON，返回“原始 api 名”数组。同时兼容三种上游格式：
//     • BMCLAPI 目录式：{"name":"neoforge","files":[{"name":"21.1.1","type":"DIRECTORY"},…]}
//     • 官方 maven API：{"isSnapshot":false,"versions":["21.1.1",…]}
//     • BMCLAPI 按版本轻接口：/neoforge/list/<mc> → [{version:"21.1.1",mcversion:…,rawVersion:…},…]
//   PCL2 对“原始 JSON 文本”直接正则扫引号内版本号，因此对形态免疫；这里先结构化提取，
//   失败时同款正则兜底。返回 nil 表示 0 条。
static NSArray<NSString *> *PALParseNeoForgeList(NSData *data) {
    if (data.length == 0) return nil;
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    void (^addName)(id) = ^(id raw) {
        if (![raw isKindOfClass:[NSString class]]) return;
        NSString *n = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!PALLooksLikeNeoForgeVersion(n)) return;
        if (![names containsObject:n]) [names addObject:n];
    };

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([json isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)json;
        NSArray *versions = dict[@"versions"];      // 官方 maven API
        if ([versions isKindOfClass:[NSArray class]]) {
            for (id v in versions) addName(v);
        }
        NSArray *files = dict[@"files"];            // BMCLAPI 目录式
        if ([files isKindOfClass:[NSArray class]]) {
            for (id f in files) {
                if (![f isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *fd = (NSDictionary *)f;
                NSString *type = fd[@"type"];
                if ([type isKindOfClass:[NSString class]] &&
                    ![type isEqualToString:@"DIRECTORY"] && ![type isEqualToString:@"FILE"]) continue;
                NSString *nm = fd[@"name"];
                if (![nm isKindOfClass:[NSString class]]) continue;
                if ([nm rangeOfString:@"maven"].location != NSNotFound) continue; // 跳过 maven 元数据项
                addName(nm);
            }
        }
    } else if ([json isKindOfClass:[NSArray class]]) {  // /neoforge/list/<mc>
        for (id item in (NSArray *)json) {
            if ([item isKindOfClass:[NSString class]]) { addName(item); continue; }
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *d = (NSDictionary *)item;
            NSString *mcv = d[@"mcversion"];
            NSString *raw = d[@"rawVersion"];
            NSString *ver = d[@"version"];
            // ★ 实测 /neoforge/list/1.20.1 里有的条目 rawVersion = "1.20.1-forge-47.1.80"
            //   带 forge- 中缀、不可直接当版本号，此时应由 mcversion+version 归一化成
            //   "1.20.1-47.1.80"，而非整条丢弃（实测 1.20.1 里 25/60 条是这种）：
            //   ① raw（如 "1.20.1-47.1.5"）② mcversion+"-"+version（如 "1.20.1-47.1.80"）
            //   ③ version（现代包，如 "21.1.1"）
            NSString *chosen = nil;
            if ([raw isKindOfClass:[NSString class]] && PALLooksLikeNeoForgeVersion(raw)) {
                chosen = raw;
            }
            if (!chosen && [mcv isKindOfClass:[NSString class]] && [ver isKindOfClass:[NSString class]]) {
                NSString *combined = [mcv stringByAppendingFormat:@"-%@", ver];
                if (PALLooksLikeNeoForgeVersion(combined)) chosen = combined;
            }
            if (!chosen && [ver isKindOfClass:[NSString class]] && PALLooksLikeNeoForgeVersion(ver)) {
                chosen = ver;
            }
            if (chosen) addName(chosen);
        }
    }

    // 正则兜底（与 PCL2 GetNeoForgeEntries 同款）：把 JSON 文本中所有引号内的版本号抓出来
    if (names.count == 0) {
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (text.length > 0) {
            NSRegularExpression *quoted = [NSRegularExpression regularExpressionWithPattern:@"\"([^\"]+)\"" options:0 error:nil];
            [quoted enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                                  usingBlock:^(NSTextCheckingResult *r, NSMatchingFlags flags, BOOL *stop) {
                if (r.numberOfRanges < 2) return;
                addName([text substringWithRange:[r rangeAtIndex:1]]);
            }];
        }
    }
    return names.count > 0 ? names : nil;
}

// ★ [PCL-ALIGN] 版本列表磁盘缓存（PCL2 用 CacheCow FileStore 做 HTTP 缓存，效果等价）。
//   路径：Caches/pcl_align_version_cache/<vendor>_<mc>.json，内容 {ts, versions[]}。
//   与 ForgeInstallViewController.m 同一目录/命名，保持单一实现风格。有效期默认 6 小时。
static NSString *PALVersionCacheDirectory(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *base = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
        if (base.length == 0) base = NSTemporaryDirectory();
        dir = [base stringByAppendingPathComponent:@"pcl_align_version_cache"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return dir;
}
static NSString *PALVersionCachePath(NSString *vendor, NSString *gameVersion) {
    NSString *raw = [NSString stringWithFormat:@"%@_%@",
                     vendor.length ? vendor : @"Unknown",
                     gameVersion.length ? gameVersion : @"all"];
    NSCharacterSet *bad = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSString *safe = [[raw componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
    return [PALVersionCacheDirectory() stringByAppendingPathComponent:[safe stringByAppendingString:@".json"]];
}
static NSArray<NSString *> *PALCacheRead(NSString *vendor, NSString *gameVersion, NSTimeInterval ttl) {
    NSData *data = [NSData dataWithContentsOfFile:PALVersionCachePath(vendor, gameVersion)];
    if (data.length == 0) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *dict = (NSDictionary *)obj;
    NSArray *versions = dict[@"versions"];
    NSNumber *ts = dict[@"ts"];
    if (![versions isKindOfClass:[NSArray class]] || versions.count == 0) return nil;
    if (ttl > 0 && ([NSDate date].timeIntervalSince1970 - ts.doubleValue) > ttl) return nil;
    NSMutableArray<NSString *> *out = [NSMutableArray new];
    for (id v in versions) {
        if ([v isKindOfClass:[NSString class]] && [v length] > 0) [out addObject:v];
    }
    return out.count > 0 ? out : nil;
}
static void PALCacheWrite(NSString *vendor, NSString *gameVersion, NSArray<NSString *> *versions) {
    if (versions.count == 0) return;
    NSDictionary *obj = @{ @"ts": @([NSDate date].timeIntervalSince1970),
                           @"vendor": vendor ?: @"",
                           @"gameVersion": gameVersion ?: @"",
                           @"versions": versions };
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (data.length == 0) return;
    [data writeToFile:PALVersionCachePath(vendor, gameVersion) atomically:YES];
}

@implementation NeoForgeVersionFetcher

#pragma mark - Public

+ (void)fetchVersionsForGameVersion:(NSString *)gameVersion
                         completion:(void (^)(NSArray *versions, NSError *error))completion {
    if (!completion) return;
    if (!gameVersion || gameVersion.length == 0) {
        completion(@[], [NSError errorWithDomain:@"NeoForge" code:1 userInfo:@{NSLocalizedDescriptionKey:@"No game version"}]);
        return;
    }
    // ★ [PCL-ALIGN] 全部走后台队列，内部为同步拉取（带超时/重试）；completion 在后台队列回调，
    //   与旧实现（NSURLSession / dispatch_group_notify 回调）一致，调用方自行切主线程。
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self fetchVersionsSyncForGameVersion:gameVersion completion:completion];
    });
}

// ★ [PCL-ALIGN] 实际取列表逻辑（后台线程执行）。日志前缀统一 [PCL-ALIGN]，用户贴日志即可定位。
+ (void)fetchVersionsSyncForGameVersion:(NSString *)gameVersion
                             completion:(void (^)(NSArray *versions, NSError *error))completion {
    NSLog(@"[PCL-ALIGN] NeoForgeVersionFetcher begin: mc=%@ (impl=NeoForgeVersionFetcher.m, PCL-aligned)", gameVersion);

    // ① 磁盘缓存（6h）
    NSArray<NSString *> *cached = PALCacheRead(@"NeoForge", gameVersion, 6 * 3600.0);
    if (cached.count > 0) {
        NSArray *filtered = [self filterVersions:cached gameVersion:gameVersion];
        if (filtered.count > 0) {
            NSLog(@"[PCL-ALIGN] NeoForgeVersionFetcher cache HIT vendor=NeoForge mc=%@ (raw=%lu, filtered=%lu)",
                  gameVersion, (unsigned long)cached.count, (unsigned long)filtered.count);
            completion(filtered, nil);
            return;
        }
        NSLog(@"[PCL-ALIGN] NeoForgeVersionFetcher cache hit but all filtered out, refetching from network");
    } else {
        NSLog(@"[PCL-ALIGN] NeoForgeVersionFetcher cache MISS vendor=NeoForge mc=%@", gameVersion);
    }

    // ② 源顺序“快→慢”：BMCLAPI 轻接口 → BMCLAPI 目录式 → 官方 API（仅兜底，短超时）
    NSString *mcEncoded = [gameVersion stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    NSMutableArray<NSString *> *collected = [NSMutableArray new];
    __block NSString *lastSource = nil;

    void (^collectFrom)(NSString *, NSInteger, NSTimeInterval, NSString *) =
        ^(NSString *urlString, NSInteger attempts, NSTimeInterval timeout, NSString *label) {
        NSData *data = PALFetchWithRetry(urlString, attempts, timeout);
        if (!data) {
            NSLog(@"[PCL-ALIGN] NeoForgeVersionFetcher source=%@ URL=%@ fetch FAILED", label, urlString);
            return;
        }
        NSArray<NSString *> *parsed = PALParseNeoForgeList(data);
        NSLog(@"[PCL-ALIGN] NeoForgeVersionFetcher source=%@ URL=%@ bytes=%lu parsed=%lu",
              label, urlString, (unsigned long)data.length, (unsigned long)parsed.count);
        if (parsed.count == 0) return;
        for (NSString *v in parsed) {
            if (![collected containsObject:v]) [collected addObject:v];
        }
        lastSource = label;
    };

    // ① 最快：BMCLAPI 按 MC 版本轻接口（实测 ~0.3s，仅含当前 MC）
    collectFrom([NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/neoforge/list/%@", mcEncoded],
                2, 10.0, @"BMCLAPI-list");
    // ② BMCLAPI 目录式全量（neoforge 现代包 + forge 旧包(1.20.1)）
    if (collected.count == 0) {
        collectFrom(@"https://bmclapi2.bangbang93.com/neoforge/meta/api/maven/details/releases/net/neoforged/neoforge",
                    2, 10.0, @"BMCLAPI-details");
        collectFrom(@"https://bmclapi2.bangbang93.com/neoforge/meta/api/maven/details/releases/net/neoforged/forge",
                    2, 10.0, @"BMCLAPI-details-legacy");
    }
    // ③ 官方 API（最终兜底；部分网络不可达，短超时单次，不再默认首选）
    if (collected.count == 0) {
        collectFrom(@"https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge",
                    1, 10.0, @"official");
        collectFrom(@"https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/forge",
                    1, 10.0, @"official-legacy");
    }

    NSArray *filtered = [self filterVersions:collected gameVersion:gameVersion];
    if (filtered.count > 0) {
        // ★ [PCL-ALIGN] 写磁盘缓存（缓存已按 gameVersion 过滤的结果，键含 mc ⇒ 与 ForgeInstallViewController 口径一致）
        PALCacheWrite(@"NeoForge", gameVersion, filtered);
        NSLog(@"[PCL-ALIGN] NeoForgeVersionFetcher done: mc=%@ source=%@ raw=%lu filtered=%lu (cached)",
              gameVersion, lastSource ?: @"none", (unsigned long)collected.count, (unsigned long)filtered.count);
        completion(filtered, nil);
    } else if (collected.count > 0) {
        NSLog(@"[PCL-ALIGN] NeoForgeVersionFetcher done: mc=%@ source=%@ raw=%lu filtered=0 (no match)",
              gameVersion, lastSource ?: @"none", (unsigned long)collected.count);
        completion(@[], [NSError errorWithDomain:@"NeoForge" code:2 userInfo:@{NSLocalizedDescriptionKey:@"No matching NeoForge versions"}]);
    } else {
        NSLog(@"[PCL-ALIGN] NeoForgeVersionFetcher done: mc=%@ all sources empty/failed", gameVersion);
        completion(@[], [NSError errorWithDomain:@"NeoForge" code:3 userInfo:@{NSLocalizedDescriptionKey:@"No NeoForge version list available"}]);
    }
}

+ (NSString *)installerURLForVersion:(NSString *)version {
    if (!version || version.length == 0) return nil;
    // 官方 URL 构造后统一经 PLMirrorCenter（ModLoader 类型）取当前策略首选 URL：
    // mirror_first → BMCLAPI /maven（PLMirrorCenter 会吸收官方路径中的 /releases 段），
    // official_first → 官方 maven 原样返回
    NSString *officialURL;
    // Legacy 1.20.1 versions use the old forge coordinates.
    if ([version containsString:@"1.20.1"] || [version hasPrefix:@"47."]) {
        // 官方 maven 路径必须包含 /releases/，否则 404
        officialURL = [NSString stringWithFormat:@"https://maven.neoforged.net/releases/net/neoforged/forge/%@/forge-%@-installer.jar", version, version];
    } else {
        // 官方 maven 路径必须包含 /releases/，否则 404
        officialURL = [NSString stringWithFormat:@"https://maven.neoforged.net/releases/net/neoforged/neoforge/%@/neoforge-%@-installer.jar", version, version];
    }
    return [[PLMirrorCenter preferredURLForOriginalURL:[NSURL URLWithString:officialURL]
                                          resourceType:PLMirrorResourceTypeModLoader] absoluteString];
}

#pragma mark - Internal

+ (NSArray *)filterVersions:(NSArray *)versions gameVersion:(NSString *)gameVersion {
    NSMutableArray *filtered = [NSMutableArray array];
    for (id obj in versions) {
        if (![obj isKindOfClass:[NSString class]]) continue;
        NSString *version = obj;
        NSString *mcVersion = [self extractMinecraftVersionFromNeoForgeVersion:version];
        if ([mcVersion isEqualToString:gameVersion]) {
            [filtered addObject:version];
        }
    }
    [filtered sortUsingComparator:^NSComparisonResult(NSString *v1, NSString *v2) {
        return [v2 compare:v1 options:NSNumericSearch];
    }];
    // ★ [NEOFORGE-FIX] 把“过滤前 N 条 / 归属到本 MC 的 M 条 / 若为 0 则给出前几条的归属推断”打清楚，
    //   这样用户贴日志即可判断是“命名映射错”还是“该 MC 真没有 NeoForge”。
    NSLog(@"[PCL-ALIGN] NeoForgeVersionFetcher filter: targetMC=%@ in=%lu matched=%lu",
          gameVersion, (unsigned long)versions.count, (unsigned long)filtered.count);
    if (filtered.count == 0 && versions.count > 0) {
        NSMutableString *sample = [NSMutableString string];
        NSUInteger n = MIN((NSUInteger)6, versions.count);
        for (NSUInteger i = 0; i < n; i++) {
            id v = versions[i];
            if (![v isKindOfClass:[NSString class]]) continue;
            [sample appendFormat:@"%@→%@ ", v, [self extractMinecraftVersionFromNeoForgeVersion:v]];
        }
        NSLog(@"[PCL-ALIGN] NeoForgeVersionFetcher filter: 0 matched for mc=%@; sample(v→inferredMC)=%@",
              gameVersion, sample.length ? sample : @"(no string entries)");
    }
    return filtered;
}

+ (NSString *)extractMinecraftVersionFromNeoForgeVersion:(NSString *)version {
    // 1.20.1 special versions: 1.20.1-47.1.3 -> 1.20.1
    // 同时覆盖 47.x.y 系列（1.20.1 NeoForge release 版本号，不含 "1.20.1" 子串）
    if ([version containsString:@"1.20.1"] || [version hasPrefix:@"47."]) {
        return @"1.20.1";
    }

    // 0.x special snapshots: 0.25w14craftmine.3 -> 25w14craftmine
    if ([version hasPrefix:@"0."]) {
        NSString *part = [version substringFromIndex:2];
        NSRange hyphenRange = [part rangeOfString:@"-"];
        if (hyphenRange.location != NSNotFound) {
            part = [part substringToIndex:hyphenRange.location];
        }
        NSRange lastDot = [part rangeOfString:@"." options:NSBackwardsSearch];
        if (lastDot.location != NSNotFound) {
            part = [part substringToIndex:lastDot.location];
        }
        return part;
    }

    NSString *cleanVersion = version;
    NSRange hyphenRange = [version rangeOfString:@"-"];
    if (hyphenRange.location != NSNotFound) {
        cleanVersion = [version substringToIndex:hyphenRange.location];
    }

    NSArray *components = [cleanVersion componentsSeparatedByString:@"."];
    if (components.count >= 2) {
        NSString *major = components[0];
        NSString *minor = components[1];

        NSCharacterSet *nonNumbers = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
        BOOL majorIsNum = [major rangeOfCharacterFromSet:nonNumbers].location == NSNotFound;
        BOOL minorIsNum = [minor rangeOfCharacterFromSet:nonNumbers].location == NSNotFound;

        if (majorIsNum && minorIsNum) {
            NSInteger majorVal = [major integerValue];
            // 关键修复（阶段6：NeoForge 直装版本号解析错误，参照 ForgeInstallViewController.m）
            //
            // NeoForge loader 版本号格式：major.minor.patch[.build]
            //   - major = MC minor（如 21 → MC 1.21）
            //   - minor = MC patch（如 1 → MC 1.21.1）
            //   - patch = NeoForge 自己的 build 号（与 MC 版本无关）
            //
            // 之前使用 components[2]（patch）作为 MC patch 号，导致：
            //   - 21.1.5 被解析为 MC 1.21.5（错误，应为 1.21.1）
            //   - 26.1.0.0 被解析为 MC 1.26.0（凑巧正确，但逻辑错误）
            //   - 用户在 UI 中看不到正确分组的 loader 版本，被迫选错 → install_profile.json
            //     中 maven 坐标版本错误 → 404
            //
            // 正确实现：用 minor（components[1]）作为 MC patch 号，与 ForgeInstallViewController.m 一致
            // ★ [NEOFORGE-FIX] 年份制命名（Mojang 26.x 起，NeoForge 改为与 MC 同号）：
            //   实测 BMCLAPI /neoforge/list/26.2 条目 version="26.2.0.0-beta"、mcversion="26.2"；
            //   此命名下 **MC 版本不带 "1." 前缀** —— 26.2.0.0-beta → MC "26.2"。
            //   旧逻辑一律当 "1.<major>.<minor>" ⇒ 得到 "1.26.2" ≠ "26.2"，26.2 的 89 条全被过滤掉，
            //   用户看到空列表 +“加载失败”。判据 major>=25（旧命名 major 只到 21；快照走上面 "0." 分支）。
            if (majorVal >= 25) {
                return [NSString stringWithFormat:@"%@.%@", major, minor];
            }
            // 旧命名（NeoForge 20.x/21.x 对应 MC 1.20.x/1.21.x）：MC 版本 = 1.<major>.<minor>
            // 覆盖 20.2.88 → 1.20.2、21.1.5 → 1.21.1；minor 才是 MC patch，patch 是 NeoForge 自己的 build 号。
            return [NSString stringWithFormat:@"1.%@.%@", major, minor];
        }
    }

    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(\\d+\\.\\d+)" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:version options:0 range:NSMakeRange(0, version.length)];
    if (match) {
        return [NSString stringWithFormat:@"1.%@", [version substringWithRange:match.range]];
    }

    return @"Unknown";
}

@end
