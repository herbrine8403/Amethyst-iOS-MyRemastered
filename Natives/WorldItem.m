//
//  WorldItem.m
//  Amethyst
//
//  世界存档数据模型实现
//

#import "WorldItem.h"

@implementation WorldItem

- (instancetype)initWithFilePath:(NSString *)path {
    if (self = [super init]) {
        _filePath = [path copy];
        _worldName = [[path lastPathComponent] copy];
        _displayName = [_worldName copy];

        // 检测 level.dat 是否存在
        NSString *levelDat = [path stringByAppendingPathComponent:@"level.dat"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:levelDat]) {
            _levelDatPath = [levelDat copy];
            // 读取 level.dat 修改时间作为 lastPlayed
            NSError *err = nil;
            NSDictionary *attrs = [fm attributesOfItemAtPath:levelDat error:&err];
            if (!err && attrs[NSFileModificationDate]) {
                NSDate *modDate = attrs[NSFileModificationDate];
                NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
                fmt.dateStyle = NSDateFormatterShortStyle;
                fmt.timeStyle = NSDateFormatterShortStyle;
                _lastPlayed = [fmt stringFromDate:modDate];
            }
        }

        // 计算世界目录大小
        _worldSize = [self directorySizeAtPath:path];
    }
    return self;
}

- (instancetype)initWithOnlineData:(NSDictionary *)data {
    if (self = [super init]) {
        // 来自 Modrinth/CurseForge 搜索结果
        _onlineID = data[@"id"] ? [data[@"id"] description] : nil;
        _apiSource = [data[@"apiSource"] integerValue] == 2 ? 2 : 1;
        _displayName = data[@"title"] ?: @"";
        _worldDescription = data[@"description"] ?: @"";
        _iconURL = data[@"imageUrl"] ?: @"";
        _author = data[@"author"] ?: @"";

        // 处理数字类型
        id downloadsValue = data[@"downloads"];
        if ([downloadsValue isKindOfClass:[NSNumber class]]) {
            _downloads = downloadsValue;
        } else if ([downloadsValue respondsToSelector:@selector(longLongValue)]) {
            _downloads = @([downloadsValue longLongValue]);
        }

        id likesValue = data[@"likes"];
        if ([likesValue isKindOfClass:[NSNumber class]]) {
            _likes = likesValue;
        } else if ([likesValue respondsToSelector:@selector(longLongValue)]) {
            _likes = @([likesValue longLongValue]);
        }

        // 日期与分类
        _lastUpdated = data[@"lastUpdated"] ?: @"";
        _categories = data[@"categories"] ?: @[];

        // 这些属性在选定下载版本前为 nil
        _filePath = nil;
        _worldName = nil;
        _levelDatPath = nil;
    }
    return self;
}

- (NSString *)basename {
    return _worldName ?: _displayName ?: @"";
}

// 递归计算目录大小
- (NSNumber *)directorySizeAtPath:(NSString *)path {
    if (!path) return @0;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) return @0;

    unsigned long long size = 0;
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:path];
    NSString *fileName;
    while ((fileName = [enumerator nextObject])) {
        NSDictionary *attrs = [enumerator fileAttributes];
        if (attrs[NSFileSize]) {
            size += [attrs[NSFileSize] unsignedLongLongValue];
        }
    }
    return @(size);
}

@end
