//
//  AiAPIClient.m
//  Amethyst
//

#import "AiAPIClient.h"

/// 节流阈值：流式回调最多每 200ms 触发一次，避免主队列/UI 过载
static const NSTimeInterval kChunkThrottleInterval = 0.2;

@interface AiAPIClient () <NSURLSessionDataDelegate>
@property (nonatomic, strong, nullable) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *currentTask;

@property (nonatomic, copy, nullable) void (^onChunk)(NSString * _Nullable delta, NSDictionary * _Nullable toolCalls);
@property (nonatomic, copy, nullable) void (^onComplete)(NSDictionary * _Nullable fullResponse, NSError * _Nullable error);

@property (nonatomic, strong) NSMutableString *streamBuffer;    // 未切分完的流缓冲
@property (nonatomic, strong) NSMutableData *streamData;        // 原始字节缓冲（保证跨块多字节字符完整性）
@property (nonatomic, strong) NSMutableString *fullResponseText; // 已接收全文
@property (nonatomic, strong) NSMutableString *pendingDelta;     // 待节流刷新的增量
@property (nonatomic, assign) NSTimeInterval lastChunkFlushTime;
@property (nonatomic, assign) BOOL streamDone;
@property (nonatomic, assign) NSInteger statusCode;
@end

@implementation AiAPIClient

- (instancetype)init {
    self = [super init];
    if (self) {
        self.streamBuffer = [NSMutableString string];
        self.streamData = [NSMutableData data];
        self.fullResponseText = [NSMutableString string];
        self.pendingDelta = [NSMutableString string];
    }
    return self;
}

- (void)dealloc {
    [self.session invalidateAndCancel];
}

#pragma mark - 请求入口

- (void)streamChatWithProvider:(AiProvider *)provider
                      messages:(NSArray<AiMessage *> *)messages
                         tools:(nullable NSArray<NSDictionary *> *)tools
                       onChunk:(void (^)(NSString * _Nullable delta, NSDictionary * _Nullable toolCalls))onChunk
                    onComplete:(void (^)(NSDictionary * _Nullable fullResponse, NSError * _Nullable error))onComplete {
    if (!provider || provider.baseURL.length == 0 || provider.model.length == 0) {
        NSError *err = [NSError errorWithDomain:@"AiAPIClient" code:100
                                        userInfo:@{NSLocalizedDescriptionKey: @"AI 提供商配置不完整（缺少 baseURL 或 model）"}];
        if (onComplete) {
            dispatch_async(dispatch_get_main_queue(), ^{ onComplete(nil, err); });
        }
        return;
    }

    self.onChunk = onChunk;
    self.onComplete = onComplete;
    [self.streamBuffer setString:@""];
    [self.streamData setLength:0];
    [self.fullResponseText setString:@""];
    [self.pendingDelta setString:@""];
    self.streamDone = NO;
    self.statusCode = 0;

    // 构造 URL：baseURL 末尾不是 / 则补 /，再拼 chat/completions
    NSString *base = provider.baseURL;
    if (![base hasSuffix:@"/"]) {
        base = [base stringByAppendingString:@"/"];
    }
    NSString *urlString = [base stringByAppendingString:@"chat/completions"];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        NSError *err = [NSError errorWithDomain:@"AiAPIClient" code:101
                                        userInfo:@{NSLocalizedDescriptionKey: @"无效的 API 地址"}];
        if (onComplete) {
            dispatch_async(dispatch_get_main_queue(), ^{ onComplete(nil, err); });
        }
        return;
    }

    // Body
    NSMutableArray *payloadMessages = [NSMutableArray array];
    // 待刷出的「assistant 携带多个 tool_calls」消息缓冲（OpenAI 要求同一助手消息携带 tool_calls 数组）
    __block NSString *pendingAssistantContent = @"";
    __block NSMutableArray *pendingToolCalls = nil;
    dispatch_block_t flushPendingToolCalls = ^{
        if (pendingToolCalls.count == 0) { pendingToolCalls = nil; return; }
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"role"] = @"assistant";
        entry[@"content"] = pendingAssistantContent ?: @"";
        entry[@"tool_calls"] = pendingToolCalls;
        [payloadMessages addObject:entry];
        pendingToolCalls = nil;
        pendingAssistantContent = @"";
    };
    for (AiMessage *m in messages) {
        // 跳过流式占位消息
        if (m.streaming) continue;

        // assistant 的工具调用记录：把连续的 isToolCall 助手消息合并进同一条 tool_calls 数组
        if (m.isToolCall && [m.role isEqualToString:@"assistant"]) {
            if (!pendingToolCalls) {
                pendingToolCalls = [NSMutableArray array];
                pendingAssistantContent = m.content ?: @"";
            } else if (m.content.length > 0 && pendingAssistantContent.length == 0) {
                pendingAssistantContent = m.content;
            }
            NSMutableDictionary *func = [NSMutableDictionary dictionary];
            if (m.toolName.length > 0) func[@"name"] = m.toolName;
            if (m.toolArguments.length > 0) func[@"arguments"] = m.toolArguments;
            NSMutableDictionary *call = [NSMutableDictionary dictionary];
            if (m.toolCallID.length > 0) call[@"id"] = m.toolCallID;
            call[@"type"] = @"function";
            call[@"function"] = func;
            [pendingToolCalls addObject:call];
            continue;
        }

        // 其它角色消息：先把缓冲的 assistant tool_calls 刷出
        flushPendingToolCalls();

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"role"] = m.role ?: @"";
        entry[@"content"] = m.content ?: @"";
        if ([m.role isEqualToString:@"tool"] && m.toolCallID.length > 0) {
            entry[@"tool_call_id"] = m.toolCallID;
        }
        [payloadMessages addObject:entry];
    }
    flushPendingToolCalls();
    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    body[@"model"] = provider.model ?: @"";
    body[@"messages"] = payloadMessages;
    body[@"stream"] = @YES;
    body[@"temperature"] = @(provider.temperature);
    body[@"max_tokens"] = @(provider.maxTokens);
    if (tools.count > 0) {
        body[@"tools"] = tools;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if (provider.apiKey.length > 0) {
        [request setValue:[NSString stringWithFormat:@"Bearer %@", provider.apiKey] forHTTPHeaderField:@"Authorization"];
    }
    request.timeoutInterval = 120;
    NSError *serializeError = nil;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&serializeError];
    if (serializeError || !request.HTTPBody) {
        if (onComplete) {
            dispatch_async(dispatch_get_main_queue(), ^{ onComplete(nil, serializeError); });
        }
        return;
    }

    // 会话（后台专用队列解析，避免阻塞主线程）
    if (!self.session) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 120;
        NSOperationQueue *queue = [[NSOperationQueue alloc] init];
        queue.maxConcurrentOperationCount = 1;
        self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:queue];
    }

    self.currentTask = [self.session dataTaskWithRequest:request];
    [self.currentTask resume];
}

#pragma mark - 取消

- (void)stop {
    [self.currentTask cancel];
}

#pragma mark - 连通性测试

- (void)testConnectionWithProvider:(AiProvider *)provider
                        completion:(void (^)(NSString * _Nullable successMessage, NSError * _Nullable error))completion {
    if (!provider || provider.baseURL.length == 0 || provider.model.length == 0) {
        NSError *err = [NSError errorWithDomain:@"AiAPIClient" code:100
                                        userInfo:@{NSLocalizedDescriptionKey: @"AI 提供商配置不完整（缺少 baseURL 或 model）"}];
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, err); });
        }
        return;
    }

    AiMessage *ping = [AiMessage messageWithRole:@"user" content:@"ping"];
    // 复用流式通道发起极其简短的对话请求，忽略增量，仅在结束时回传结果
    [self streamChatWithProvider:provider
                        messages:@[ping]
                           tools:nil
                         onChunk:nil
                      onComplete:^(NSDictionary * _Nullable fullResponse, NSError * _Nullable error) {
        if (completion) {
            if (error) {
                completion(nil, error);
            } else {
                completion(@"连接成功", nil);
            }
        }
    }];
}

#pragma mark - 流式解析

/// 从字节缓冲里取出以 \n 结尾的完整字节串解码并切行处理（保留不完整的多字节尾部）
- (void)processBufferedStreamData {
    if (self.streamData.length == 0) return;
    static unsigned char lf = '\n';
    NSData *lfData = [NSData dataWithBytes:&lf length:1];
    NSRange lastLF = [self.streamData rangeOfData:lfData options:NSDataSearchBackwards
                                            range:NSMakeRange(0, self.streamData.length)];
    // 尚无完整行：可能是多字节字符被切开尚未拼齐，保留字节等待下一块
    if (lastLF.location == NSNotFound) return;
    NSUInteger completeLen = lastLF.location + 1;
    NSData *completeData = [self.streamData subdataWithRange:NSMakeRange(0, completeLen)];
    NSString *text = [[NSString alloc] initWithData:completeData encoding:NSUTF8StringEncoding];
    if (text.length > 0) {
        [self processStreamText:text];
    }
    [self.streamData replaceBytesInRange:NSMakeRange(0, completeLen) withBytes:NULL length:0];
}

/// 追加接收到的文本并切行处理
- (void)processStreamText:(NSString *)text {
    if (text.length == 0 || self.streamDone) return;
    [self.streamBuffer appendString:text];

    // 每次处理缓冲里完整的一行
    NSInteger consumed = 0;
    NSRange range;
    BOOL done = NO;
    while (!done) {
        range = [self.streamBuffer rangeOfString:@"\n"];
        if (range.location == NSNotFound) break;
        NSString *line = [self.streamBuffer substringToIndex:range.location];
        NSRange fullRange = NSMakeRange(0, range.location + 1);
        [self.streamBuffer deleteCharactersInRange:fullRange];
        consumed += range.location + 1;
        [self processStreamLine:line];
    }
    (void)consumed;

    // 缓冲过大但一直没换行符（异常）时清空，避免无限累积
    if (self.streamBuffer.length > 1024 * 1024) {
        [self.streamBuffer setString:@""];
    }
}

- (void)processStreamLine:(NSString *)line {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return;

    // 前缀兼容三种形态："data: "、"data:"（无空格）、以及整行无前缀（裸行直接把整行作为 payload）
    NSString *payload = nil;
    if ([trimmed hasPrefix:@"data: "]) {
        payload = [trimmed substringFromIndex:6];
    } else if ([trimmed hasPrefix:@"data:"]) {
        payload = [trimmed substringFromIndex:5];
    } else {
        payload = trimmed;
    }
    NSString *payloadTrimmed = [payload stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([payloadTrimmed isEqualToString:@"[DONE]"]) {
        self.streamDone = YES;
        // 标记，交 toComplete 处理剩余刷新
        return;
    }

    NSData *jsonData = [payloadTrimmed dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    if (error || ![json isKindOfClass:[NSDictionary class]]) return;

    NSArray *choices = json[@"choices"];
    if (![choices isKindOfClass:[NSArray class]] || choices.count == 0) return;
    NSDictionary *choice = choices[0];
    if (![choice isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *delta = choice[@"delta"];
    if (![delta isKindOfClass:[NSDictionary class]]) return;

    id content = delta[@"content"];
    NSString *deltaText = nil;
    if ([content isKindOfClass:[NSString class]] && content != (id)[NSNull null]) {
        deltaText = content;
        [self.fullResponseText appendString:deltaText];
        [self.pendingDelta appendString:deltaText];
    }

    // tool_calls（Phase 3 使用，本期仅透传）
    NSArray *toolCallArr = delta[@"tool_calls"];
    if ([toolCallArr isKindOfClass:[NSArray class]]) {
        NSDictionary *toolCallsInfo = @{@"tool_calls": toolCallArr};
        void (^chunk)(NSString *, NSDictionary *) = self.onChunk;
        if (chunk) {
            NSString *emptyDelta = @"";
            dispatch_async(dispatch_get_main_queue(), ^{ chunk(emptyDelta, toolCallsInfo); });
        }
    }

    // 节流：距上次刷新 < 200ms 则暂存 pendingDelta，等待下次刷新/结束刷出
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if ((now - self.lastChunkFlushTime) >= kChunkThrottleInterval) {
        [self flushPendingDelta];
    }
}

- (void)flushPendingDelta {
    if (self.pendingDelta.length > 0 && self.onChunk) {
        NSString *delta = [self.pendingDelta copy];
        [self.pendingDelta setString:@""];
        void (^chunk)(NSString *, NSDictionary *) = self.onChunk;
        if (chunk) {
            NSString *safeDelta = delta;
            dispatch_async(dispatch_get_main_queue(), ^{ chunk(safeDelta, nil); });
        }
    }
    self.lastChunkFlushTime = [[NSDate date] timeIntervalSince1970];
}

#pragma mark - 错误构造

- (NSError *)errorFromResponseBody {
    NSString *body = self.fullResponseText.length > 0 ? self.fullResponseText : @"";
    NSString *message = [NSString stringWithFormat:@"请求失败（HTTP %ld）", (long)self.statusCode];
    NSError *jsonError = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding]
                                                         options:0 error:&jsonError];
    if (json && [json isKindOfClass:[NSDictionary class]]) {
        NSDictionary *errorObj = json[@"error"];
        if ([errorObj isKindOfClass:[NSDictionary class]] && [errorObj[@"message"] isKindOfClass:[NSString class]]) {
            NSString *m = errorObj[@"message"];
            if (m.length > 0) message = m;
        }
    }
    return [NSError errorWithDomain:@"AiAPIClient" code:self.statusCode
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
              dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        self.statusCode = [(NSHTTPURLResponse *)response statusCode];
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (self.streamDone) return;
    if (data.length == 0) return;
    // 关键修复（AI 说话说不全/好话说一半）：不能把每块 data 直接按 UTF8 解码成字符串，
    // 否则中文/emoji 等多字节字符恰落在两块 data 切分边界时，前一块解码损坏，
    // 导致该 SSE 行 JSON 解析失败被整行丢弃，输出表现为被截断/少字/空白。
    // 改为字节级缓冲：只解码以 \n 结尾的完整字节串，跨块的多字节字符保留到后续拼齐。
    [self.streamData appendData:data];
    [self processBufferedStreamData];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    self.streamDone = YES;

    void (^complete)(NSDictionary *, NSError *) = self.onComplete;
    self.onComplete = nil;
    self.onChunk = nil;

    if (error) {
        NSError *outError = error;
        if (error.code == NSURLErrorCancelled) {
            outError = [NSError errorWithDomain:@"AiAPIClient" code:NSURLErrorCancelled
                                       userInfo:@{NSLocalizedDescriptionKey: @"已停止生成"}];
        }
        [self flushPendingDelta];
        if (complete) {
            dispatch_async(dispatch_get_main_queue(), ^{ complete(nil, outError); });
        }
        return;
    }

    if (self.statusCode != 0 && self.statusCode != 200) {
        [self flushPendingDelta];
        NSError *apiError = [self errorFromResponseBody];
        if (complete) {
            dispatch_async(dispatch_get_main_queue(), ^{ complete(nil, apiError); });
        }
        return;
    }

    // 处理末尾没有换行的最后一块字节（避免丢失最后几个字/整块结尾内容）
    if (self.streamData.length > 0) {
        NSString *tail = [[NSString alloc] initWithData:self.streamData encoding:NSUTF8StringEncoding];
        if (tail.length > 0) {
            [self processStreamText:tail];
        }
        [self.streamData setLength:0];
    }
    // 兜底：streamBuffer 里若仍有未以 \n 结尾的残行（内容最后一行或 data: [DONE] 无尾换行），
    // 复制后清空 buffer，作为最后一个完整行解析一次，确保末尾 delta 刷出
    if (self.streamBuffer.length > 0) {
        NSString *tailLine = [self.streamBuffer copy];
        [self.streamBuffer setString:@""];
        [self processStreamLine:tailLine];
    }
    [self flushPendingDelta];
    NSDictionary *fullResponse = @{@"content": [self.fullResponseText copy] ?: @""};
    if (complete) {
        dispatch_async(dispatch_get_main_queue(), ^{ complete(fullResponse, nil); });
    }
}

@end