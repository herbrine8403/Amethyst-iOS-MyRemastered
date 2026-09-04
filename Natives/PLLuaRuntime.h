#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class PLUIPack;

/// UI 材质包的 Lua 沙箱运行时。
///
/// 一个 runtime 对应一个包的一颗 Lua VM：
/// - 沙箱：vendored Lua 5.4，linit.c 编译期裁掉 os/io/debug/package，
///   自定义分配器限额内存，指令钩子限制执行时长；
/// - ui 构建器：内置 prelude 定义 ui.row/ui.button/... 与 ui.dimen，
///   build(ui) 返回的 Lua 表被转换为不可变 NSDictionary 节点树交给布局引擎；
/// - launcher API：launcher.state / launcher.view(id) / launcher.action(name) / launcher.log(...)，
///   view 与 action 经 C 桥回到 ObjC（动作白名单由 PLUIActionRouter 把关）。
///
/// 只允许主线程使用；VM 与 runtime 同生命周期（dealloc 时 lua_close）。
@interface PLLuaRuntime : NSObject

/// build(ui) 与包顶层代码的执行预算（秒），默认 2s，超时抛 Lua 错误。
@property (nonatomic, assign) NSTimeInterval buildTimeout;
/// 事件函数（onReady/onClick/...）的执行预算（秒），默认 0.2s。
@property (nonatomic, assign) NSTimeInterval eventTimeout;

/// view 变更回调。command ∈ {setText, setTextColor, setImage, setVisible, setEnabled}，
/// 返回 NO 表示目标 view 不存在。
@property (nonatomic, nullable, copy) BOOL (^viewCommandHandler)(NSString *viewId, NSString *command, id argument);
/// view 读取回调（getText）。view 不存在返回 nil。
@property (nonatomic, nullable, copy) NSString *_Nullable (^viewTextHandler)(NSString *viewId);
/// 动作回调。脚本只能触发白名单动作，安全校验在路由层完成。
@property (nonatomic, nullable, copy) void (^actionHandler)(NSString *action);

/// 创建并加载包脚本。加载失败（语法错误/超预算）返回 nil 并填充 error。
- (nullable instancetype)initWithPack:(PLUIPack *)pack
                         scriptSource:(NSString *)source
                                 error:(NSError **)error;

/// 调用 build(ui) 并返回节点树（NSDictionary）。build 缺失或超时返回 nil。
- (nullable NSDictionary *)buildTreeWithError:(NSError **)error;

/// 派发事件（onReady/onClick/onAccountChange/...）。
/// 返回 NO 表示包未定义该事件；事件执行出错只记日志不向上抛。
- (BOOL)dispatchEvent:(NSString *)name arguments:(NSArray<id> *)arguments;

/// 刷新 launcher.state（NSDictionary → Lua 只读快照）。
- (void)setState:(NSDictionary<NSString *, id> *)state;

@end

NS_ASSUME_NONNULL_END
