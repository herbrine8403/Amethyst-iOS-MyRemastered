#import "PLThemeManager.h"
#import "LauncherPreferences.h"

NSString * const PLThemeDidChangeNotification = @"PLThemeDidChangeNotification";
NSString * const PLDefaultThemeIdentifier = @"pcl-classic";

static NSString * const PLThemeErrorDomain = @"PLThemeErrorDomain";
static NSInteger const PLThemeManifestVersion = 1;

@interface PLThemeManager ()
@property (nonatomic, copy, readwrite) NSString *activeIdentifier;
@property (nonatomic, copy, readwrite) NSString *displayName;
@property (nonatomic, copy) NSDictionary<NSString *, id> *colors;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *images;
@property (nonatomic, copy) NSString *themeRoot;
@end

@implementation PLThemeManager

+ (PLThemeManager *)sharedManager {
    static PLThemeManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [PLThemeManager new];
        [manager reload];
    });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _activeIdentifier = PLDefaultThemeIdentifier;
        _displayName = @"PCL Classic";
        _colors = @{};
        _images = @{};
    }
    return self;
}

- (NSString *)externalThemesRoot {
    const char *home = getenv("POJAV_HOME");
    if (!home || home[0] == '\0') return nil;
    return [[NSString stringWithUTF8String:home] stringByAppendingPathComponent:@"themes"];
}

- (BOOL)isSafeIdentifier:(NSString *)identifier {
    if (![identifier isKindOfClass:NSString.class] || identifier.length == 0 || identifier.length > 64) {
        return NO;
    }
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                               @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    return [identifier rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound &&
           ![identifier isEqualToString:@"."] && ![identifier isEqualToString:@".."];
}

- (nullable NSString *)bundledRootForIdentifier:(NSString *)identifier {
    NSString *relative = [@"themes" stringByAppendingPathComponent:identifier];
    NSString *manifest = [NSBundle.mainBundle pathForResource:@"manifest"
                                                        ofType:@"json"
                                                   inDirectory:relative];
    return manifest.stringByDeletingLastPathComponent;
}

- (nullable NSString *)externalRootForIdentifier:(NSString *)identifier {
    NSString *themesRoot = [self externalThemesRoot];
    if (!themesRoot) return nil;
    NSString *candidate = [themesRoot stringByAppendingPathComponent:identifier].stringByStandardizingPath;
    NSString *prefix = [themesRoot.stringByStandardizingPath stringByAppendingString:@"/"];
    if (![candidate hasPrefix:prefix]) return nil;
    NSString *manifest = [candidate stringByAppendingPathComponent:@"manifest.json"];
    return [NSFileManager.defaultManager fileExistsAtPath:manifest] ? candidate : nil;
}

- (nullable NSString *)rootForIdentifier:(NSString *)identifier {
    if (![self isSafeIdentifier:identifier]) return nil;
    // 用户主题允许覆盖同名内置主题，便于快速迭代皮肤。
    return [self externalRootForIdentifier:identifier] ?: [self bundledRootForIdentifier:identifier];
}

- (nullable NSDictionary *)JSONDictionaryAtPath:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

- (nullable NSDictionary *)manifestAtRoot:(NSString *)root expectedIdentifier:(NSString *)identifier {
    NSDictionary *manifest = [self JSONDictionaryAtPath:[root stringByAppendingPathComponent:@"manifest.json"]];
    if (![manifest[@"schemaVersion"] isKindOfClass:NSNumber.class] ||
        [manifest[@"schemaVersion"] integerValue] != PLThemeManifestVersion ||
        ![manifest[@"id"] isKindOfClass:NSString.class] ||
        ![manifest[@"id"] isEqualToString:identifier]) {
        return nil;
    }
    return manifest;
}

- (BOOL)loadIdentifier:(NSString *)identifier {
    NSString *root = [self rootForIdentifier:identifier];
    NSDictionary *manifest = root ? [self manifestAtRoot:root expectedIdentifier:identifier] : nil;
    if (!manifest) return NO;

    NSString *colorsFile = [manifest[@"colors"] isKindOfClass:NSString.class] ? manifest[@"colors"] : @"colors.json";
    if ([colorsFile.lastPathComponent isEqualToString:colorsFile] == NO) return NO;
    NSDictionary *colors = [self JSONDictionaryAtPath:[root stringByAppendingPathComponent:colorsFile]] ?: @{};
    NSDictionary *images = [manifest[@"images"] isKindOfClass:NSDictionary.class] ? manifest[@"images"] : @{};

    self.activeIdentifier = identifier;
    self.displayName = [manifest[@"name"] isKindOfClass:NSString.class] ? manifest[@"name"] : identifier;
    self.colors = colors;
    self.images = images;
    self.themeRoot = root;
    return YES;
}

- (void)reload {
    NSString *selected = getPrefObject(@"general.theme_pack");
    if (![selected isKindOfClass:NSString.class] || ![self loadIdentifier:selected]) {
        if (![self loadIdentifier:PLDefaultThemeIdentifier]) {
            self.activeIdentifier = PLDefaultThemeIdentifier;
            self.displayName = @"PCL Classic";
            self.colors = @{};
            self.images = @{};
            self.themeRoot = nil;
        }
    }
}

- (NSArray<NSDictionary *> *)availableThemes {
    NSMutableDictionary<NSString *, NSDictionary *> *themes = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    NSString *bundled = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"themes"];
    if (bundled) [roots addObject:bundled];
    NSString *external = [self externalThemesRoot];
    if (external) [roots addObject:external];

    for (NSString *root in roots) {
        NSArray<NSString *> *children = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil] ?: @[];
        for (NSString *identifier in children) {
            if (![self isSafeIdentifier:identifier]) continue;
            NSString *themeRoot = [root stringByAppendingPathComponent:identifier];
            NSDictionary *manifest = [self manifestAtRoot:themeRoot expectedIdentifier:identifier];
            if (!manifest) continue;
            themes[identifier] = @{
                @"id": identifier,
                @"name": [manifest[@"name"] isKindOfClass:NSString.class] ? manifest[@"name"] : identifier,
                @"author": [manifest[@"author"] isKindOfClass:NSString.class] ? manifest[@"author"] : @""
            };
        }
    }
    return [themes.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
}

- (BOOL)applyThemeIdentifier:(NSString *)identifier error:(NSError **)error {
    if (![self isSafeIdentifier:identifier] || ![self loadIdentifier:identifier]) {
        if (error) {
            *error = [NSError errorWithDomain:PLThemeErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid or unsupported theme pack"}];
        }
        return NO;
    }
    setPrefObject(@"general.theme_pack", identifier);
    [NSNotificationCenter.defaultCenter postNotificationName:PLThemeDidChangeNotification object:self];
    return YES;
}

- (nullable UIColor *)colorFromHex:(NSString *)hex {
    if (![hex isKindOfClass:NSString.class]) return nil;
    NSString *clean = [[hex stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                       stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (clean.length == 3) {
        unichar r = [clean characterAtIndex:0], g = [clean characterAtIndex:1], b = [clean characterAtIndex:2];
        clean = [NSString stringWithFormat:@"%C%C%C%C%C%C", r, r, g, g, b, b];
    }
    if (clean.length != 6 && clean.length != 8) return nil;
    unsigned long long rgba = 0;
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    if (![scanner scanHexLongLong:&rgba] || !scanner.isAtEnd) return nil;
    CGFloat alpha = clean.length == 8 ? (rgba & 0xFF) / 255.0 : 1.0;
    if (clean.length == 8) rgba >>= 8;
    return [UIColor colorWithRed:((rgba >> 16) & 0xFF) / 255.0
                           green:((rgba >> 8) & 0xFF) / 255.0
                            blue:(rgba & 0xFF) / 255.0
                           alpha:alpha];
}

- (UIColor *)colorForToken:(NSString *)token fallback:(UIColor *)fallback {
    id value = self.colors[token];
    if ([value isKindOfClass:NSString.class]) {
        return [self colorFromHex:value] ?: fallback;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSString *light = [value[@"light"] isKindOfClass:NSString.class] ? value[@"light"] : nil;
        NSString *dark = [value[@"dark"] isKindOfClass:NSString.class] ? value[@"dark"] : light;
        UIColor *lightColor = [self colorFromHex:light];
        UIColor *darkColor = [self colorFromHex:dark];
        if (!lightColor && !darkColor) return fallback;
        return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? (darkColor ?: lightColor ?: fallback)
                : (lightColor ?: darkColor ?: fallback);
        }];
    }
    return fallback;
}

- (nullable UIImage *)imageForToken:(NSString *)token {
    NSString *relative = self.images[token];
    if (![relative isKindOfClass:NSString.class] || relative.length == 0 || relative.isAbsolutePath) return nil;
    NSString *root = self.themeRoot.stringByStandardizingPath;
    NSString *candidate = [root stringByAppendingPathComponent:relative].stringByStandardizingPath;
    if (!root || ![candidate hasPrefix:[root stringByAppendingString:@"/"]]) return nil;
    return [UIImage imageWithContentsOfFile:candidate];
}

@end
