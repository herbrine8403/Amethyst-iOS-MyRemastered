//
//  AiAPIClient.h
//  Amethyst
//
//  OpenAI 兼容流式 Chat Completions 客户端。
//  支持 SSE 流式返回，节流 onChunk 回调（≤200ms），block 一律回主线程。
//

#import <Foundation/Foundation.h>
#import "AiProvider.h"
#import "AiMessage.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiAPIClient : NSObject

/// 发起一次流式对话请求
/// @param messages 对话上下文（system/user/assistant）
/// @param tools 工具定义（Phase 3 使用，本期通常传 nil）
/// @param onChunk 流式片段回调（delta 为本次累计的内容增量；toolCalls 透传，Phase 3 使用）
/// @param onComplete 请求结束回调（fullResponse 含 @"content" 全文；error 为空表示成功）
- (void)streamChatWithProvider:(AiProvider *)provider
                      messages:(NSArray<AiMessage *> *)messages
                         tools:(nullable NSArray<NSDictionary *> *)tools
                       onChunk:(void (^)(NSString * _Nullable delta, NSDictionary * _Nullable toolCalls))onChunk
                    onComplete:(void (^)(NSDictionary * _Nullable fullResponse, NSError * _Nullable error))onComplete;

/// 取消当前请求（供停止按钮）
- (void)stop;

/// 连通性测试：向提供商发一条极短的 user "ping" 消息（内部复用流式通道），
/// 成功回调 successMessage（如"连接成功"），失败回调 error。
/// 不改动既有 streamChatWithProvider:... 方法签名。
- (void)testConnectionWithProvider:(AiProvider *)provider
                        completion:(void (^)(NSString * _Nullable successMessage, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END