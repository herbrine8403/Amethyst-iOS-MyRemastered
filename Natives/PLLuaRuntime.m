#import "PLLuaRuntime.h"
#import "PLUIPackManager.h"
#import <stdlib.h>
#import "lua.h"
#import "lauxlib.h"
#import "lualib.h"

static NSString * const PLLuaRuntimeErrorDomain = @"PLLuaRuntimeErrorDomain";
// VM 内存硬限额：节点树 + 脚本状态的规模远小于此，超限视为失控脚本。
static NSUInteger const PLLuaRuntimeMemoryCap = 4 * 1024 * 1024;
// 每 200 万条指令检查一次截止时间，钩子本身的开销可忽略。
static int const PLLuaRuntimeHookInterval = 2000000;

#pragma mark - C 桥（Lua ↔ ObjC）

typedef struct {
    NSUInteger used;
    NSUInteger cap;
} PLLuaAllocContext;

/// 限额分配器：超限时返回 NULL，Lua 会抛 memory error 而不是吃光内存。
static void *PLLuaAlloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    PLLuaAllocContext *ctx = (PLLuaAllocContext *)ud;
    if (nsize == 0) {
        free(ptr);
        if (ptr) ctx->used -= (NSUInteger)osize;
        return NULL;
    }
    if (ptr == NULL) {
        if (ctx->used + (NSUInteger)nsize > ctx->cap) return NULL;
        ctx->used += (NSUInteger)nsize;
        return malloc(nsize);
    }
    if (ctx->used + (NSUInteger)nsize < (NSUInteger)osize) return NULL; // 溢出保护
    if (ctx->used - (NSUInteger)osize + (NSUInteger)nsize > ctx->cap) return NULL;
    ctx->used = ctx->used - (NSUInteger)osize + (NSUInteger)nsize;
    return realloc(ptr, nsize);
}

static int PLLuaPanic(lua_State *L) {
    const char *msg = lua_tostring(L, -1);
    NSLog(@"[PLLuaRuntime] VM panic: %s", msg ? msg : "unknown");
    return 0;
}

@interface PLLuaRuntime ()
@property (nonatomic, assign) lua_State *L;
@property (nonatomic, assign) PLLuaAllocContext *alloc;
@property (nonatomic, copy) NSString *packIdentifier;
@property (nonatomic, assign) NSTimeInterval deadline; // 0 = 无预算
@end

static PLLuaRuntime *PLLuaBridgeSelf(lua_State *L) {
    lua_getglobal(L, "__self");
    PLLuaRuntime *runtime = (__bridge PLLuaRuntime *)lua_touserdata(L, -1);
    lua_pop(L, 1);
    return runtime;
}

/// ObjC 值 → Lua（NSDictionary/NSArray/NSString/NSNumber，其余归为 nil）。
static void PLLuaPushObject(lua_State *L, id obj) {
    if (obj == nil || obj == NSNull.null) {
        lua_pushnil(L);
    } else if ([obj isKindOfClass:NSString.class]) {
        const char *s = [obj UTF8String];
        if (s) lua_pushstring(L, s); else lua_pushnil(L);
    } else if ([obj isKindOfClass:NSNumber.class]) {
        NSNumber *n = obj;
        if ([n isEqual:@YES] || [n isEqual:@NO]) {
            lua_pushboolean(L, [n boolValue]);
        } else if (strcmp([n objCType], @encode(BOOL)) == 0) {
            lua_pushboolean(L, [n boolValue]);
        } else {
            lua_Integer i = [n longLongValue];
            double d = [n doubleValue];
            if ((double)i == d) lua_pushinteger(L, i);
            else lua_pushnumber(L, d);
        }
    } else if ([obj isKindOfClass:NSDictionary.class]) {
        lua_createtable(L, 0, (int)[obj count]);
        [obj enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
            if (![key isKindOfClass:NSString.class]) return;
            lua_pushstring(L, [key UTF8String]);
            PLLuaPushObject(L, value);
            lua_settable(L, -3);
        }];
    } else if ([obj isKindOfClass:NSArray.class]) {
        lua_createtable(L, (int)[obj count], 0);
        [obj enumerateObjectsUsingBlock:^(id value, NSUInteger idx, BOOL *stop) {
            PLLuaPushObject(L, value);
            lua_rawseti(L, -2, (lua_Integer)idx + 1);
        }];
    } else {
        lua_pushnil(L);
    }
}

/// Lua 值 → ObjC（嵌套表 → NSDictionary/NSArray；函数/userdata 丢弃为 nil）。
static id PLLuaToNSObject(lua_State *L, int idx) {
    // 遍历过程中会压栈，相对索引会漂移，一律转绝对索引。
    idx = lua_absindex(L, idx);
    switch (lua_type(L, idx)) {
        case LUA_TNIL:
            return nil;
        case LUA_TBOOLEAN:
            return @(lua_toboolean(L, idx));
        case LUA_TNUMBER:
            if (lua_isinteger(L, idx)) return @(lua_tointeger(L, idx));
            return @(lua_tonumber(L, idx));
        case LUA_TSTRING: {
            size_t len = 0;
            const char *s = lua_tolstring(L, idx, &len);
            return [[NSString alloc] initWithBytes:s length:len encoding:NSUTF8StringEncoding];
        }
        case LUA_TTABLE: {
            // 先探测是否为纯序列（键 1..n），否则按字符串键字典收集。
            lua_Integer n = (lua_Integer)lua_rawlen(L, idx);
            BOOL isArray = n > 0;
            if (isArray) {
                for (lua_Integer k = 1; k <= n; k++) {
                    lua_rawgeti(L, idx, k);
                    BOOL ok = !lua_isnil(L, -1);
                    lua_pop(L, 1);
                    if (!ok) { isArray = NO; break; }
                }
            }
            if (isArray) {
                NSMutableArray *array = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
                for (lua_Integer k = 1; k <= n; k++) {
                    lua_rawgeti(L, idx, k);
                    [array addObject:PLLuaToNSObject(L, -1) ?: NSNull.null];
                    lua_pop(L, 1);
                }
                return array;
            }
            NSMutableDictionary *dict = [NSMutableDictionary dictionary];
            lua_pushnil(L);
            while (lua_next(L, idx) != 0) {
                if (lua_type(L, -2) == LUA_TSTRING) {
                    size_t len = 0;
                    const char *ks = lua_tolstring(L, -2, &len);
                    NSString *key = [[NSString alloc] initWithBytes:ks length:len encoding:NSUTF8StringEncoding];
                    if (key) dict[key] = PLLuaToNSObject(L, -1) ?: NSNull.null;
                }
                lua_pop(L, 1);
            }
            return dict;
        }
        default:
            return nil;
    }
}

#pragma mark - __bridge 函数（脚本唯一能触达的原生能力）

static int PLLuaBridgeLog(lua_State *L) {
    luaL_Buffer buffer;
    luaL_buffinit(L, &buffer);
    int argc = lua_gettop(L);
    for (int i = 1; i <= argc; i++) {
        if (i > 1) luaL_addstring(&buffer, " ");
        const char *s = lua_tostring(L, i);
        luaL_addstring(&buffer, s ? s : "nil");
    }
    luaL_pushresult(&buffer);
    NSLog(@"[UIPack:%@] %s", PLLuaBridgeSelf(L).packIdentifier, lua_tostring(L, -1));
    return 0;
}

static int PLLuaBridgeAction(lua_State *L) {
    const char *name = luaL_optstring(L, 1, NULL);
    if (!name) return 0;
    PLLuaRuntime *runtime = PLLuaBridgeSelf(L);
    if (runtime.actionHandler) runtime.actionHandler(@(name));
    return 0;
}

static int PLLuaBridgeViewCmd(lua_State *L) {
    const char *viewId = luaL_optstring(L, 1, NULL);
    const char *command = luaL_optstring(L, 2, NULL);
    if (!viewId || !command) { lua_pushboolean(L, NO); return 1; }
    PLLuaRuntime *runtime = PLLuaBridgeSelf(L);
    id argument = PLLuaToNSObject(L, 3);
    BOOL ok = runtime.viewCommandHandler ? runtime.viewCommandHandler(@(viewId), @(command), argument) : NO;
    lua_pushboolean(L, ok);
    return 1;
}

static int PLLuaBridgeViewGetText(lua_State *L) {
    const char *viewId = luaL_optstring(L, 1, NULL);
    if (!viewId) { lua_pushnil(L); return 1; }
    PLLuaRuntime *runtime = PLLuaBridgeSelf(L);
    NSString *text = runtime.viewTextHandler ? runtime.viewTextHandler(@(viewId)) : nil;
    if (text) lua_pushstring(L, [text UTF8String]);
    else lua_pushnil(L);
    return 1;
}

/// 指令计数钩子：只做截止时间检查，超时抛 Lua 错误（被 pcall 捕获，不崩宿主）。
static void PLLuaTimeoutHook(lua_State *L, lua_Debug *ar) {
    PLLuaRuntime *runtime = PLLuaBridgeSelf(L);
    if (!runtime || runtime.deadline <= 0) return;
    if ([NSDate timeIntervalSinceReferenceDate] > runtime.deadline) {
        luaL_error(L, "script execution budget exceeded");
    }
}

#pragma mark - prelude（ui 构建器 + launcher API 的 Lua 侧）

// 注意：这里的 prelude 在脚本之前执行，定义全局 ui / launcher / __bridge 之上的友好封装。
static NSString * const PLLuaPrelude = @"\
local function _node(kind, props)\n\
  if type(props) ~= 'table' then props = {} end\n\
  props.kind = kind\n\
  return props\n\
end\n\
ui = {}\n\
for _, k in ipairs({'row','column','button','text','image','spacer','divider','content','nav','panel','tileGrid'}) do\n\
  ui[k] = function(p) return _node(k, p) end\n\
end\n\
-- ui.dimen({phone=56, pad=70}) / ui.dimen(64)：响应式尺寸\n\
ui.dimen = function(v)\n\
  if type(v) == 'table' then return { _dimen = v } end\n\
  return { _dimen = { default = v } }\n\
end\n\
launcher = {}\n\
function launcher.log(...)\n\
  __bridge.log(...)\n\
end\n\
function launcher.action(name)\n\
  if type(name) == 'string' then __bridge.action(name) end\n\
end\n\
function launcher.view(id)\n\
  if type(id) ~= 'string' then return nil end\n\
  local h = { _id = id }\n\
  function h:setText(t) return __bridge.viewCmd(self._id, 'setText', t) end\n\
  function h:setTextColor(c) return __bridge.viewCmd(self._id, 'setTextColor', c) end\n\
  function h:setImage(i) return __bridge.viewCmd(self._id, 'setImage', i) end\n\
  function h:setVisible(v) return __bridge.viewCmd(self._id, 'setVisible', v ~= false) end\n\
  function h:setEnabled(e) return __bridge.viewCmd(self._id, 'setEnabled', e ~= false) end\n\
  function h:getText() return __bridge.viewGetText(self._id) end\n\
  return h\n\
end\n\
";

#pragma mark - PLLuaRuntime

@implementation PLLuaRuntime

- (instancetype)init {
    [NSException raise:NSInvalidArgumentException format:@"use initWithPack:scriptSource:error:"];
    return nil;
}

- (nullable instancetype)initWithPack:(PLUIPack *)pack
                         scriptSource:(NSString *)source
                                 error:(NSError **)error {
    self = [super init];
    if (self) {
        _packIdentifier = pack.identifier ?: @"unknown";
        _buildTimeout = 2.0;
        _eventTimeout = 0.2;

        _alloc = malloc(sizeof(PLLuaAllocContext));
        _alloc->used = 0;
        _alloc->cap = PLLuaRuntimeMemoryCap;
        _L = lua_newstate(PLLuaAlloc, _alloc);
        if (!_L) {
            if (error) *error = [NSError errorWithDomain:PLLuaRuntimeErrorDomain code:1
                                                 userInfo:@{NSLocalizedDescriptionKey: @"failed to create Lua VM"}];
            free(_alloc);
            return nil;
        }
        lua_atpanic(_L, PLLuaPanic);
        // 沙箱库集合（linit.c 裁剪：base/coroutine/table/string/math/utf8）
        luaL_openlibs(_L);

        lua_pushlightuserdata(_L, (__bridge void *)self);
        lua_setglobal(_L, "__self");

        // __bridge 表：脚本触达原生的唯一入口（log/action/viewCmd/viewGetText）
        lua_createtable(_L, 0, 4);
        lua_pushcfunction(_L, PLLuaBridgeLog);
        lua_setfield(_L, -2, "log");
        lua_pushcfunction(_L, PLLuaBridgeAction);
        lua_setfield(_L, -2, "action");
        lua_pushcfunction(_L, PLLuaBridgeViewCmd);
        lua_setfield(_L, -2, "viewCmd");
        lua_pushcfunction(_L, PLLuaBridgeViewGetText);
        lua_setfield(_L, -2, "viewGetText");
        lua_setglobal(_L, "__bridge");

        if (![self runChunk:PLLuaPrelude name:@"prelude" error:error] ||
            ![self runChunk:source name:pack.entryPath.lastPathComponent error:error]) {
            [self tearDownVM];
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    [self tearDownVM];
}

- (void)tearDownVM {
    if (_L) {
        lua_close(_L);
        _L = NULL;
    }
    if (_alloc) {
        free(_alloc);
        _alloc = NULL;
    }
}

- (BOOL)runChunk:(NSString *)chunk name:(NSString *)name error:(NSError **)error {
    if (!chunk.UTF8String) {
        if (error) *error = [NSError errorWithDomain:PLLuaRuntimeErrorDomain code:2
                                             userInfo:@{NSLocalizedDescriptionKey: @"script is not valid UTF-8"}];
        return NO;
    }
    self.deadline = [NSDate timeIntervalSinceReferenceDate] + self.buildTimeout;
    lua_sethook(_L, PLLuaTimeoutHook, LUA_MASKCOUNT, PLLuaRuntimeHookInterval);
    if (luaL_loadstring(_L, [chunk UTF8String]) != LUA_OK ||
        lua_pcall(_L, 0, 0, 0) != LUA_OK) {
        const char *msg = lua_tostring(_L, -1);
        NSString *reason = msg ? @(msg) : @"unknown load error";
        lua_pop(_L, 1);
        lua_sethook(_L, NULL, 0, 0);
        self.deadline = 0;
        NSLog(@"[PLLuaRuntime] %@ failed to load %@: %@", self.packIdentifier, name, reason);
        if (error) {
            *error = [NSError errorWithDomain:PLLuaRuntimeErrorDomain code:3
                                     userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        return NO;
    }
    lua_sethook(_L, NULL, 0, 0);
    self.deadline = 0;
    return YES;
}

- (nullable NSDictionary *)buildTreeWithError:(NSError **)error {
    if (!_L) return nil;
    self.deadline = [NSDate timeIntervalSinceReferenceDate] + self.buildTimeout;
    lua_sethook(_L, PLLuaTimeoutHook, LUA_MASKCOUNT, PLLuaRuntimeHookInterval);

    lua_getglobal(_L, "build");
    if (!lua_isfunction(_L, -1)) {
        lua_pop(_L, 1);
        [self clearHook];
        if (error) *error = [NSError errorWithDomain:PLLuaRuntimeErrorDomain code:4
                                             userInfo:@{NSLocalizedDescriptionKey: @"main.lua must define build(ui)"}];
        return nil;
    }
    lua_getglobal(_L, "ui");
    if (lua_pcall(_L, 1, 1, 0) != LUA_OK) {
        const char *msg = lua_tostring(_L, -1);
        NSString *reason = msg ? @(msg) : @"unknown build error";
        lua_pop(_L, 1);
        [self clearHook];
        NSLog(@"[PLLuaRuntime] %@ build() failed: %@", self.packIdentifier, reason);
        if (error) {
            *error = [NSError errorWithDomain:PLLuaRuntimeErrorDomain code:5
                                     userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        return nil;
    }
    id tree = PLLuaToNSObject(_L, -1);
    lua_pop(_L, 1);
    [self clearHook];
    if (![tree isKindOfClass:NSDictionary.class]) {
        if (error) *error = [NSError errorWithDomain:PLLuaRuntimeErrorDomain code:6
                                             userInfo:@{NSLocalizedDescriptionKey: @"build(ui) must return a node table"}];
        return nil;
    }
    return tree;
}

- (BOOL)dispatchEvent:(NSString *)name arguments:(NSArray<id> *)arguments {
    if (!_L || ![name isKindOfClass:NSString.class]) return NO;
    lua_getglobal(_L, [name UTF8String]);
    if (!lua_isfunction(_L, -1)) {
        lua_pop(_L, 1);
        return NO;
    }
    self.deadline = [NSDate timeIntervalSinceReferenceDate] + self.eventTimeout;
    lua_sethook(_L, PLLuaTimeoutHook, LUA_MASKCOUNT, PLLuaRuntimeHookInterval);
    for (id argument in arguments) PLLuaPushObject(_L, argument);
    if (lua_pcall(_L, (int)arguments.count, 0, 0) != LUA_OK) {
        const char *msg = lua_tostring(_L, -1);
        NSLog(@"[PLLuaRuntime] %@ event %@ failed: %s", self.packIdentifier, name, msg ? msg : "unknown");
        lua_pop(_L, 1);
    }
    [self clearHook];
    return YES;
}

- (void)setState:(NSDictionary<NSString *, id> *)state {
    if (!_L) return;
    lua_getglobal(_L, "launcher");
    if (lua_istable(_L, -1)) {
        PLLuaPushObject(_L, state ?: @{});
        lua_setfield(_L, -2, "state");
    }
    lua_pop(_L, 1);
}

- (void)clearHook {
    lua_sethook(_L, NULL, 0, 0);
    self.deadline = 0;
}

@end
