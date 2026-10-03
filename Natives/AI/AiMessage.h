//
//  AiMessage.h
//  Amethyst
//
//  对话消息数据模型：role + content。
//  tool_calls / function_call 等字段留待 Phase 3 扩展，本期仅保留 role/content。
//  streaming 仅运行时标记，用于标识正在流式生成中的占位助手消息，不持久化。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AiMessage : NSObject

/// 消息角色：system / user / assistant / tool
@property (nonatomic, copy) NSString *role;
/// 消息内容
@property (nonatomic, copy) NSString *content;
/// 是否正处于流式生成中（仅运行时标记，不写入磁盘）
@property (nonatomic, assign) BOOL streaming;
/// 创建时间
@property (nonatomic, strong) NSDate *createdAt;

// ===== Phase 3 工具调用扩展字段（可选，向后兼容）=====
/// 工具调用 ID（assistant 的 function_call，以及对应 tool 结果的 tool_call_id）
@property (nonatomic, copy, nullable) NSString *toolCallID;
/// 工具名（assistant 的 function_call 名称）
@property (nonatomic, copy, nullable) NSString *toolName;
/// 工具参数（JSON 字符串，assistant 的 function_call arguments）
@property (nonatomic, copy, nullable) NSString *toolArguments;
/// 是否为助理的工具调用记录（function_call）
@property (nonatomic, assign) BOOL isToolCall;
/// 是否为工具执行结果消息（role=tool）
@property (nonatomic, assign) BOOL isToolResult;
/// 工具执行是否成功（结果卡片用于区分 ✅/❌，默认成功）
@property (nonatomic, assign) BOOL toolSucceeded;

/// 便捷构造
+ (instancetype)messageWithRole:(NSString *)role content:(NSString *)content;

/// 构造 assistant 的工具调用消息（isToolCall=YES，role=assistant，content 可为空）
+ (instancetype)toolCallMessageWithName:(NSString *)name arguments:(NSString *)arguments;

/// 构造工具结果消息（isToolResult=YES，role=tool，并绑定 tool_call_id）
+ (instancetype)toolResultMessageWithContent:(NSString *)content toolCallID:(NSString *)toolCallID;

/// JSON 系列化
- (instancetype)initWithDictionary:(NSDictionary *)dict;
- (NSDictionary *)toDictionary;

@end

NS_ASSUME_NONNULL_END