//
//  DataPackItem.m
//  Amethyst
//
//  数据包数据模型实现
//

#import "DataPackItem.h"

@implementation DataPackItem

- (instancetype)initWithFilePath:(NSString *)path {
    if (self = [super init]) {
        _filePath = [path copy];
        _fileName = [[path lastPathComponent] copy];
        [self refreshDisabledFlag];
        NSString *name = [_fileName copy];

        if ([name hasSuffix:@".disabled"]) {
            name = [name substringToIndex:name.length - [@".disabled" length]];
        }
        if ([name hasSuffix:@".zip"]) {
            name = [name stringByDeletingPathExtension];
        }
        _displayName = name.length ? name : _fileName;
    }
    return self;
}

- (instancetype)initWithOnlineData:(NSDictionary *)data {
    if (self = [super init]) {
        // 来自 Modrinth 搜索结果
        _onlineID = data[@"id"] ? [data[@"id"] description] : nil;
        _apiSource = [data[@"apiSource"] integerValue] == 2 ? 2 : 1;
        _displayName = data[@"title"] ?: @"";
        _dataPackDescription = data[@"description"] ?: @"";
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
        _fileName = nil;
    }
    return self;
}

- (void)refreshDisabledFlag {
    _disabled = [_fileName.lowercaseString hasSuffix:@".disabled"];
}

- (NSString *)basename {
    NSString *name = _fileName ?: @"";
    if ([name hasSuffix:@".disabled"]) {
        name = [name substringToIndex:name.length - [@".disabled" length]];
    }
    if ([name hasSuffix:@".zip"]) name = [name stringByDeletingPathExtension];
    return name;
}

@end
