//
//  AiAgent.m
//  Amethyst
//

#import "AiAgent.h"
#import "AiMessage.h"
#import "AiSessionStore.h"
#import "AiSettings.h"
#import "AiAPIClient.h"
#import "AiToolRegistry.h"
#import "AiSafetyManager.h"

/// 工具循环最多轮数
static const NSInteger kMaxToolRounds = 10;
/// 同一工具调用最多尝试次数（含失败）
static const NSInteger kMaxToolAttempts = 3;

/// 工具调用结果已写入会话的消息变更通知名（object=AiSession）
static NSString * const kAiSessionMessagesDidChangeNotification = @"AiSessionMessagesDidChangeNotification";

@interface AiAgent ()
@property (nonatomic, strong) AiAPIClient *client;

// 工具循环运行时状态（一次 sendUserMessage 生命周期内有效）
@property (nonatomic, assign) BOOL running;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *attempts; // toolCallID -> 已尝试次数
@property (nonatomic, assign) NSInteger toolRound;                                   // 当前工具轮数
@end

@implementation AiAgent

+ (instancetype)sharedAgent {
    static AiAgent *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AiAgent alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _client = [[AiAPIClient alloc] init];
        _attempts = [NSMutableDictionary dictionary];
    }
    return self;
}

/// 会话持久化（每轮工具往返后调用，保证打断/杀进程后 history 完整）
- (void)saveSession:(AiSession *)session {
    if (!session) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[AiSessionStore sharedStore] updateSession:session];
    });
}

/// 广播会话消息变更（供 UI 监听即时刷新；纯广播，不破坏消息协议顺序）
- (void)notifyMessagesChanged:(AiSession *)session {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kAiSessionMessagesDidChangeNotification
                                                            object:session];
    });
}

/// 累积流式 tool_calls 片段：按 index 合并 name 与 args（arguments 为逐片增量拼接）
- (void)accumulateToolCalls:(NSArray *)rawToolCalls
                       into:(NSMutableDictionary *)accumulator {
    for (id item in rawToolCalls) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *tc = item;
        NSNumber *idxNum = tc[@"index"];
        NSInteger idx = (idxNum && [idxNum isKindOfClass:[NSNumber class]]) ? idxNum.integerValue : (NSInteger)accumulator.count;
        NSMutableDictionary *entry = accumulator[@(idx)];
        if (!entry) {
            entry = [NSMutableDictionary dictionary];
            entry[@"index"] = @(idx);
            accumulator[@(idx)] = entry;
        }
        // id 通常只在首片段出现
        if ([tc[@"id"] isKindOfClass:[NSString class]] && [tc[@"id"] length] > 0) {
            entry[@"id"] = tc[@"id"];
        }
        NSDictionary *func = tc[@"function"];
        if ([func isKindOfClass:[NSDictionary class]]) {
            if ([func[@"name"] isKindOfClass:[NSString class]] && [func[@"name"] length] > 0) {
                entry[@"name"] = func[@"name"];
            }
            if ([func[@"arguments"] isKindOfClass:[NSString class]]) {
                NSString *prev = entry[@"arguments"] ?: @"";
                entry[@"arguments"] = [prev stringByAppendingString:func[@"arguments"]];
            }
        }
        // 兼容部分兼容 OpenAI 协议的模型把 name 放在 tc 顶层（而非 function.name）
        if (![entry[@"name"] isKindOfClass:[NSString class]] || [entry[@"name"] length] == 0) {
            if ([tc[@"name"] isKindOfClass:[NSString class]] && [tc[@"name"] length] > 0) {
                entry[@"name"] = tc[@"name"];
            }
        }
    }
}

/// 解析工具参数 JSON 字符串为字典（失败返回空字典）
- (NSDictionary *)parseArgumentsJSON:(NSString *)jsonString {
    if (jsonString.length == 0) return @{};
    NSData *data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return @{};
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        return obj;
    }
    return @{};
}

/// 发送用户消息，驱动工具循环
- (void)sendUserMessage:(NSString *)text
                session:(AiSession *)session
               provider:(AiProvider *)provider
               streaming:(BOOL)streaming
           chunkHandler:(void (^)(NSString *partial))chunkHandler
     completionHandler:(void (^)(NSError *error))completionHandler {
    if (!session) {
        if (completionHandler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler([NSError errorWithDomain:@"AiAgent" code:1 userInfo:@{NSLocalizedDescriptionKey: @"会话为空"}]);
            });
        }
        return;
    }

    // 并发保护：上一个 flow 尚未结束（如工具仍在执行/等待确认）时，直接拒绝新消息
    if (self.running) {
        if (completionHandler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler([NSError errorWithDomain:@"AiAgent" code:3 userInfo:@{NSLocalizedDescriptionKey: @"上一条回复尚未完成，请稍候或先点停止"}]);
            });
        }
        return;
    }

    // 初始化循环状态
    self.running = YES;
    self.toolRound = 0;
    [self.attempts removeAllObjects];

    // 追加用户消息
    AiMessage *userMessage = [AiMessage messageWithRole:@"user" content:text ?: @""];
    [session.messages addObject:userMessage];

    [self startRoundInSession:session
                     provider:provider
                 chunkHandler:chunkHandler
           completionHandler:completionHandler];
}

#pragma mark - 工具循环：单轮请求

- (void)startRoundInSession:(AiSession *)session
                   provider:(AiProvider *)provider
               chunkHandler:(void (^)(NSString *partial))chunkHandler
         completionHandler:(void (^)(NSError *error))completionHandler {
    if (!self.running) return;

    // 轮数护栏
    if (self.toolRound >= kMaxToolRounds) {
        AiMessage *capMsg = [AiMessage messageWithRole:@"assistant" content:@"本轮工具调用已达上限，请让用户进一步说明。"];
        [session.messages addObject:capMsg];
        [self saveSession:session];
        self.running = NO;
        if (completionHandler) completionHandler(nil);
        return;
    }

    // 1. 拼装 payload：system + 历史（剔除流式占位、含 tool 消息）
    NSMutableArray *payloadMessages = [NSMutableArray array];
    NSString *systemPrompt = [[AiSettings sharedSettings] systemPrompt];

    // 动态注入今天日期（gameDir 自动命名「MC版本 加载器 YYYY.MM.DD」需要）
    NSDateFormatter *dateFmt = [[NSDateFormatter alloc] init];
    dateFmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"zh_CN"];
    [dateFmt setDateFormat:@"yyyy 年 M 月 d 日"];
    NSString *todayLine = [NSString stringWithFormat:@"今天是 %@。若需新建游戏目录，命名格式为「Minecraft版本 加载器 YYYY.MM.DD」。", [dateFmt stringFromDate:[NSDate date]]];
    systemPrompt = [systemPrompt stringByAppendingString:[NSString stringWithFormat:@"\n\n【今天日期】%@", todayLine]];

    // 2. 工具定义
    NSArray *tools = [[AiToolRegistry sharedRegistry] openAIToolSchemas];

    // 关键修复（AI 不知道自己能使用工具）：即便 tools 随请求作为 functions 传入，
    // 若系统提示未点明，模型往往只给文字建议而不主动调用工具。
    // 因此在存在工具时向 system prompt 追加一句明确的能力说明（不覆盖用户自定义内容，仅追加其尾）。
    if (tools.count > 0) {
        systemPrompt = [systemPrompt stringByAppendingString:@"\n\n你可以调用内置工具来直接操控启动器，例如：排查并分析崩溃日志、读取已安装的游戏版本与组件状态、直接安装 Minecraft 版本或 Fabric/Quilt 加载器（未装原版会自动先装，Fabric 会自动装 Fabric API）、下载/安装模组、光影、资源包、数据包（自动匹配实例 MC 版本）、查看与修改启动器设置（总设置与实例设置）、新建游戏目录（create_instance）、管理待办清单（todo_*）、查看下载进度（check_downloads）、读取多份日志（read_logs，含启动器日志）。"
            "版本号约定：install_loader 的 loaderVersion 与 install_* 的 versionId 均可传 \"latest\" 表示最新稳定版，无需先拉版本列表。"
            "安装顺序纪律：必须先装原版再装加载器——调用 install_loader 前先用 list_instances 确认目标实例的原版已装好，未装则先调 install_game_version 装原版，成功后才装加载器，最后才装 Mod；卸载/切换目录同理，先补原版。"
            "这些安装全部自动完成，用户可在下载中心实时查看进度，你无需也不应让用户去下载页手动操作（Forge/NeoForge/OptiFine 除外，它们需要图形安装器）。"
            "你可以并行执行多个工具调用；下载类工具可后台执行（wait=false）后继续做其它事，稍后用 check_downloads 查进度。"
            "当用户的请求可以通过这些工具完成时，请主动调用合适的工具去执行，而不是只给出文字建议；也请结合工具返回结果继续推进任务。"];
    }
    if (systemPrompt.length > 0) {
        [payloadMessages addObject:[AiMessage messageWithRole:@"system" content:systemPrompt]];
    }
    for (AiMessage *m in session.messages) {
        if (m.streaming) continue;
        [payloadMessages addObject:m];
    }

    // 3. 创建助手占位消息（streaming 标记）
    AiMessage *assistantMessage = [AiMessage messageWithRole:@"assistant" content:@""];
    assistantMessage.streaming = YES;
    [session.messages addObject:assistantMessage];

    __weak typeof(self) weakSelf = self;
    __block NSMutableDictionary *accToolCalls = [NSMutableDictionary dictionary];

    [self.client streamChatWithProvider:provider
                               messages:payloadMessages
                                  tools:tools
                                onChunk:^(NSString * _Nullable delta, NSDictionary * _Nullable toolCalls) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.running) return;
        if (delta.length > 0) {
            assistantMessage.content = [assistantMessage.content stringByAppendingString:delta];
            if (chunkHandler) chunkHandler(delta);
        }
        NSArray *raw = toolCalls[@"tool_calls"];
        if ([raw isKindOfClass:[NSArray class]] && raw.count > 0) {
            [strongSelf accumulateToolCalls:raw into:accToolCalls];
        }
    } onComplete:^(NSDictionary * _Nullable fullResponse, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        assistantMessage.streaming = NO;

        // 停止请求：直接收尾，不触发 completionHandler（UI 已由停止按钮复位）
        if (!strongSelf.running) {
            [strongSelf saveSession:session];
            return;
        }

        if (error) {
            // 出错：不追加错误消息到 history，仅 completionHandler 通知 UI 弹错
            if (assistantMessage.content.length == 0) {
                [session.messages removeObject:assistantMessage];
            }
            [strongSelf saveSession:session];
            strongSelf.running = NO;
            if (completionHandler) completionHandler(error);
            return;
        }

        if (accToolCalls.count > 0) {
            // 进入工具执行阶段
            [strongSelf saveSession:session];
            [strongSelf runToolCalls:accToolCalls
                    assistantMessage:assistantMessage
                             session:session
                            provider:provider
                        chunkHandler:chunkHandler
                  completionHandler:completionHandler];
        } else {
            // 无工具调用，正常结束
            [strongSelf saveSession:session];
            strongSelf.running = NO;
            if (completionHandler) completionHandler(nil);
        }
    }];
}

#pragma mark - 工具执行阶段

/// 并行执行本轮全部工具调用（enhance-ai-agent Task 15）：
/// - 无需安全确认的调用并发派发（各工具异步回调）；
/// - 需要用户确认的调用按 index 顺序串行确认（同一时刻只弹一个确认框）；
/// - 工具结果消息按工具 index 顺序 append 到会话历史（assistant tool_calls 之后），
///   各自完成即尽可能早地落盘（appendCursor 从首个未落位槽位起连续推进）；
/// - 全部完成后统一进入下一轮或以 terminalError 收尾。
/// 线程安全：工具 completion 与安全确认回调均在主线程，无竞态。
- (void)runToolCalls:(NSDictionary *)accToolCalls
    assistantMessage:(AiMessage *)assistantMessage
             session:(AiSession *)session
            provider:(AiProvider *)provider
        chunkHandler:(void (^)(NSString *partial))chunkHandler
  completionHandler:(void (^)(NSError *error))completionHandler {
    NSArray *allValues = accToolCalls.allValues;
    NSArray *orderedCalls = [allValues sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        NSInteger ia = [a[@"index"] integerValue];
        NSInteger ib = [b[@"index"] integerValue];
        return (ia > ib) ? NSOrderedDescending : ((ia < ib) ? NSOrderedAscending : NSOrderedSame);
    }];

    // 把首个调用挂到助手消息上（isToolCall），其余调用以 toolCallMessage 追加，
    // 序列化时这些连续的 isToolCall 助手消息被合并为同一条 assistant tool_calls 数组（见 AiAPIClient）。
    for (NSUInteger i = 0; i < orderedCalls.count; i++) {
        NSDictionary *call = orderedCalls[i];
        NSString *callID = call[@"id"];
        if (callID.length == 0) callID = [NSString stringWithFormat:@"call_%ld", (long)[call[@"index"] integerValue]];
        NSString *name = call[@"name"];
        NSString *args = call[@"arguments"] ?: @"";
        if (i == 0) {
            assistantMessage.isToolCall = YES;
            assistantMessage.toolCallID = callID;
            assistantMessage.toolName = name ?: @"";
            assistantMessage.toolArguments = args;
        } else {
            AiMessage *tc = [AiMessage toolCallMessageWithName:name ?: @"" arguments:args];
            tc.toolCallID = callID;
            [session.messages addObject:tc];
        }
    }
    [self saveSession:session];
    [self notifyMessagesChanged:session];

    const NSUInteger total = orderedCalls.count;
    if (total == 0) {
        [self startRoundInSession:session provider:provider chunkHandler:chunkHandler completionHandler:completionHandler];
        return;
    }

    __block NSError *terminalError = nil;
    __weak typeof(self) weakSelf = self;

    // 结果槽位：初始 NSNull；各调用完成即填入自己的槽位
    NSMutableArray *slots = [NSMutableArray arrayWithCapacity:total];
    for (NSUInteger i = 0; i < total; i++) [slots addObject:[NSNull null]];
    __block NSUInteger appendCursor = 0;   // 下一个待 append 的槽位（保证 tool 结果按工具序落盘）
    __block NSUInteger completedCount = 0;

    // 填槽并从 appendCursor 起连续 append（保序且尽量即时）
    void (^storeResult)(NSUInteger, AiMessage *) = ^(NSUInteger idx, AiMessage *msg) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (idx < slots.count) slots[idx] = msg;
        while (appendCursor < total &&
               ![[slots objectAtIndex:appendCursor] isKindOfClass:[NSNull class]]) {
            [session.messages addObject:[slots objectAtIndex:appendCursor]];
            appendCursor++;
        }
        [strongSelf saveSession:session];
        [strongSelf notifyMessagesChanged:session];
    };

    // 该轮全部工具执行完毕
    void (^finishRound)(void) = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.running) return;
        if (terminalError) {
            // 达到重试上限，以最终错误结束本轮
            strongSelf.running = NO;
            if (completionHandler) completionHandler(terminalError);
            return;
        }
        strongSelf.toolRound++;
        [strongSelf startRoundInSession:session
                                provider:provider
                            chunkHandler:chunkHandler
                      completionHandler:completionHandler];
    };

    // 单个调用完成：计数 + 可选的链式推进回调
    void (^noteCompleted)(dispatch_block_t) = ^(dispatch_block_t done) {
        completedCount++;
        if (completedCount >= total) finishRound();
        if (done) done();
    };

    // 执行第 idx 个调用（完成后调用 done；done 可为 nil）
    void (^executeCallAt)(NSUInteger, dispatch_block_t) = ^(NSUInteger idx, dispatch_block_t done) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.running) { if (done) done(); return; }

        NSDictionary *call = orderedCalls[idx];
        NSString *callID = call[@"id"];
        NSString *name = call[@"name"];
        NSString *arguments = call[@"arguments"] ?: @"";
        if (callID.length == 0) callID = [NSString stringWithFormat:@"call_%ld", (long)[call[@"index"] integerValue]];

        // 重试护栏：同一 callID 已执行 ≥3 次则不再回喂
        NSInteger attempts = [strongSelf.attempts[callID] integerValue];
        if (attempts >= kMaxToolAttempts) {
            AiMessage *failMsg = [AiMessage toolResultMessageWithContent:[NSString stringWithFormat:@"多次尝试仍失败：%@", name ?: @""] toolCallID:callID];
            failMsg.toolName = name ?: @"";
            failMsg.toolSucceeded = NO;
            storeResult(idx, failMsg);
            terminalError = [NSError errorWithDomain:@"AiAgent" code:2
                                            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"工具 %@ 多次尝试仍失败", name ?: callID]}];
            noteCompleted(done);
            return;
        }
        strongSelf.attempts[callID] = @(attempts + 1);

        // 校验工具是否存在
        id<AiTool> tool = [[AiToolRegistry sharedRegistry] toolForName:name ?: @""];
        if (!tool) {
            AiMessage *unknownMsg = [AiMessage toolResultMessageWithContent:[NSString stringWithFormat:@"未知工具：%@", name ?: @""] toolCallID:callID];
            unknownMsg.toolName = name ?: @"";
            unknownMsg.toolSucceeded = NO;
            storeResult(idx, unknownMsg);
            noteCompleted(done);
            return;
        }

        NSDictionary *normalizedParams = [[AiToolRegistry sharedRegistry] normalizedParams:[strongSelf parseArgumentsJSON:arguments]];

        void (^proceed)(void) = ^{
            __strong typeof(weakSelf) ss2 = weakSelf;
            if (!ss2 || !ss2.running) { if (done) done(); return; }
            [[AiToolRegistry sharedRegistry] executeToolNamed:name ?: @""
                                                       params:normalizedParams
                                                   completion:^(NSString * _Nullable result, NSError * _Nullable error) {
                __strong typeof(weakSelf) ss3 = weakSelf;
                if (!ss3) { if (done) done(); return; }
                NSString *content = result;
                if (content.length == 0 && error) content = error.localizedDescription;
                if (content.length == 0) content = @"（无返回）";
                AiMessage *resMsg = [AiMessage toolResultMessageWithContent:content toolCallID:callID];
                resMsg.toolName = name ?: @"";
                resMsg.toolSucceeded = (error == nil);
                storeResult(idx, resMsg);
                noteCompleted(done);
            }];
        };

        // 安全确认（DangerousWrite 等需确认时阻塞等待用户选择）
        if ([[AiSafetyManager sharedManager] needsUserConfirmationForPermission:tool.permission]) {
            [[AiSafetyManager sharedManager] requestConfirmationWithTitle:[NSString stringWithFormat:@"AI 请求执行「%@」", name ?: @""]
                                                                  message:[NSString stringWithFormat:@"该工具需要你确认后才执行。\n参数：%@", arguments]
                                                              completion:^(BOOL approved) {
                __strong typeof(weakSelf) ss4 = weakSelf;
                if (!ss4 || !ss4.running) { if (done) done(); return; }
                if (!approved) {
                    AiMessage *cancelMsg = [AiMessage toolResultMessageWithContent:@"用户已取消该操作" toolCallID:callID];
                    cancelMsg.toolName = name ?: @"";
                    cancelMsg.toolSucceeded = NO;
                    storeResult(idx, cancelMsg);
                    noteCompleted(done);
                    return;
                }
                proceed();
            }];
        } else {
            proceed();
        }
    };

    // 分类：需要确认的（串行链，避免同时弹多个确认框）/ 无需确认的（并发派发）
    NSMutableArray<NSNumber *> *immediateIndices = [NSMutableArray array];
    NSMutableArray<NSNumber *> *confirmIndices = [NSMutableArray array];
    for (NSUInteger i = 0; i < total; i++) {
        NSDictionary *call = orderedCalls[i];
        NSString *name = call[@"name"];
        id<AiTool> tool = [[AiToolRegistry sharedRegistry] toolForName:name ?: @""];
        if (tool && [[AiSafetyManager sharedManager] needsUserConfirmationForPermission:tool.permission]) {
            [confirmIndices addObject:@(i)];
        } else {
            [immediateIndices addObject:@(i)];
        }
    }

    // 并发派发无需确认的调用
    for (NSNumber *idxNum in immediateIndices) {
        executeCallAt(idxNum.unsignedIntegerValue, nil);
    }

    // 串行链处理需确认的调用（一个确认完成后再弹下一个）
    __block void (^confirmChain)(NSUInteger);
    confirmChain = ^(NSUInteger ci) {
        if (ci >= confirmIndices.count) { confirmChain = nil; return; }
        executeCallAt([confirmIndices[ci] unsignedIntegerValue], ^{
            confirmChain(ci + 1);
        });
    };
    confirmChain(0);
}

#pragma mark - 停止

- (void)stopCurrent {
    if (self.client) [self.client stop];
    self.running = NO;
}

@end