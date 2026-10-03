//
//  AiMessage.m
//  Amethyst
//

#import "AiMessage.h"

@implementation AiMessage

+ (instancetype)messageWithRole:(NSString *)role content:(NSString *)content {
    AiMessage *message = [[AiMessage alloc] init];
    message.role = role ?: @"user";
    message.content = content ?: @"";
    return message;
}

+ (instancetype)toolCallMessageWithName:(NSString *)name arguments:(NSString *)arguments {
    AiMessage *message = [[AiMessage alloc] init];
    message.role = @"assistant";
    message.content = @"";
    message.isToolCall = YES;
    message.toolName = name ?: @"";
    message.toolArguments = arguments ?: @"";
    return message;
}

+ (instancetype)toolResultMessageWithContent:(NSString *)content toolCallID:(NSString *)toolCallID {
    AiMessage *message = [[AiMessage alloc] init];
    message.role = @"tool";
    message.isToolResult = YES;
    message.content = content ?: @"";
    message.toolCallID = toolCallID ?: @"";
    return message;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _role = @"user";
        _content = @"";
        _streaming = NO;
        _createdAt = [NSDate date];
        _toolCallID = nil;
        _toolName = nil;
        _toolArguments = nil;
        _isToolCall = NO;
        _isToolResult = NO;
        _toolSucceeded = YES;
    }
    return self;
}

- (instancetype)initWithDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    self = [self init];
    if (!self) return nil;
    if ([dict[@"role"] isKindOfClass:[NSString class]]) _role = dict[@"role"];
    if ([dict[@"content"] isKindOfClass:[NSString class]]) _content = dict[@"content"];
    if ([dict[@"toolCallID"] isKindOfClass:[NSString class]]) _toolCallID = dict[@"toolCallID"];
    if ([dict[@"toolName"] isKindOfClass:[NSString class]]) _toolName = dict[@"toolName"];
    if ([dict[@"toolArguments"] isKindOfClass:[NSString class]]) _toolArguments = dict[@"toolArguments"];
    if ([dict[@"isToolCall"] isKindOfClass:[NSNumber class]]) _isToolCall = [dict[@"isToolCall"] boolValue];
    if ([dict[@"isToolResult"] isKindOfClass:[NSNumber class]]) _isToolResult = [dict[@"isToolResult"] boolValue];
    if ([dict[@"toolSucceeded"] isKindOfClass:[NSNumber class]]) _toolSucceeded = [dict[@"toolSucceeded"] boolValue];
    // 时间戳（可选）
    NSNumber *ts = dict[@"createdAt"];
    if ([ts isKindOfClass:[NSNumber class]]) {
        _createdAt = [NSDate dateWithTimeIntervalSince1970:ts.doubleValue];
    }
    return self;
}

- (NSDictionary *)toDictionary {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"role"] = self.role ?: @"";
    dict[@"content"] = self.content ?: @"";
    dict[@"createdAt"] = @([self.createdAt timeIntervalSince1970]);
    // 仅在有值时写出，保证与旧版会话 JSON 向后兼容
    if (self.toolCallID.length > 0) dict[@"toolCallID"] = self.toolCallID;
    if (self.toolName.length > 0) dict[@"toolName"] = self.toolName;
    if (self.toolArguments.length > 0) dict[@"toolArguments"] = self.toolArguments;
    if (self.isToolCall) dict[@"isToolCall"] = @YES;
    if (self.isToolResult) dict[@"isToolResult"] = @YES;
    // 仅写出失败态，成功（默认值）不写，兼容旧版
    if (!self.toolSucceeded) dict[@"toolSucceeded"] = @NO;
    return [dict copy];
}

@end