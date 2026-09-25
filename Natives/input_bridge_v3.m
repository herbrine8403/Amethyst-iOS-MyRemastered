/*
 * V3 input bridge implementation.
 *
 * Status:
 * - Active development
 * - Works with some bugs:
 *  + Modded versions gives broken stuff..
 */

#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "SurfaceViewController.h"

#include <assert.h>
#include <dlfcn.h>
#include <libgen.h>
#include <limits.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>
#include <stdio.h>

#include "jni.h"
#include "glfw_keycodes.h"
#include "ios_uikit_bridge.h"
#include "utils.h"

#include "JavaLauncher.h"

// SDL3 event injection via dlsym — used when GLFW callbacks are NULL (MC 26.3)
// Only SDL_PushEvent and SDL_GetWindowID are exported from libSDL3.dylib.
// Internal functions like SDL_SendMouseMotion are NOT exported, so we construct
// SDL_Event structs and push them directly.
//
// We cannot #include <SDL3/SDL_events.h> from the Natives build, so we define
// the minimal constants and structs we need inline.

// SDL3 event type constants (from SDL_events.h)
#define SDL3_EVENT_KEY_DOWN        0x300
#define SDL3_EVENT_KEY_UP          0x301
#define SDL3_EVENT_MOUSE_MOTION    0x400
#define SDL3_EVENT_MOUSE_BUTTON_DOWN 0x401
#define SDL3_EVENT_MOUSE_BUTTON_UP   0x402
#define SDL3_EVENT_MOUSE_WHEEL     0x403
// Task 82：SDL_EVENT_TEXT_INPUT（0x303=771）。MC 26.3 的
// SDLEventHandler.pollEvents 里 case 771 → handleTextInputEvent →
// keyboardHandler.textInput → charTyped，虚拟键盘字符的唯一入口。
#define SDL3_EVENT_TEXT_INPUT      0x303

typedef uint32_t SDL3_WindowID;
typedef uint32_t SDL3_MouseID;
typedef uint16_t SDL3_Keymod;
typedef int      SDL3_Scancode;
typedef uint32_t SDL3_Keycode;

// SDL3 MouseMotionEvent layout (must match SDL3 ABI exactly)
typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    SDL3_WindowID windowID;
    SDL3_MouseID which;
    uint32_t state;
    float x, y;
    float xrel, yrel;
} SDL3_MouseMotionEvent;

// SDL3 MouseButtonEvent layout
typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    SDL3_WindowID windowID;
    SDL3_MouseID which;
    uint8_t button;
    bool down;
    uint8_t clicks;
    uint8_t padding;
    float x, y;
} SDL3_MouseButtonEvent;

// SDL3 MouseWheelEvent layout
typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    SDL3_WindowID windowID;
    SDL3_MouseID which;
    float x, y;
    uint32_t direction;
    float mouse_x, mouse_y;
    int32_t integer_x, integer_y;
} SDL3_MouseWheelEvent;

// SDL3 KeyboardEvent layout
typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    SDL3_WindowID windowID;
    uint32_t which;
    SDL3_Scancode scancode;
    SDL3_Keycode key;
    SDL3_Keymod mod;
    uint16_t raw;
    bool down;
    bool repeat;
} SDL3_KeyboardEvent;

// Task 82：SDL3 TextInputEvent layout（与 SDL3 ABI 对齐：
// type@0 reserved@4 timestamp@8 windowID@16 pad@20 text@24，sizeof=32）。
// text 是指针而非内联数组（SDL3 改动），指向的 UTF-8 字符串必须在
// MC 轮询该事件时仍然存活——用下方的静态环形槽位保证。
typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    SDL3_WindowID windowID;
    const char *text;
} SDL3_TextInputEvent;

// Union large enough to hold any SDL3 event
typedef union {
    uint32_t type;
    char _padding[128];
} SDL3_Event;

typedef bool SDL_PushEvent_func(void *event);
typedef uint32_t SDL_GetWindowID_func(void *window);
typedef unsigned short SDL_GetModState_func(void);   // Task83: 读 SDL 虚拟修饰键态
typedef bool SDL_HideCursor_func(void);
typedef bool SDL_ShowCursor_func(void);

static SDL_PushEvent_func     *pSDL_PushEvent     = NULL;
static SDL_GetWindowID_func   *pSDL_GetWindowID   = NULL;
static SDL_GetModState_func   *pSDL_GetModState   = NULL;   // Task83
static void *g_sdlWindow = NULL;  // The real SDL3 window pointer

static void initSDLEventFuncs(void) {
    static BOOL inited = NO;
    if (inited) return;
    inited = YES;
    pSDL_PushEvent   = dlsym(RTLD_DEFAULT, "SDL_PushEvent");
    pSDL_GetWindowID = dlsym(RTLD_DEFAULT, "SDL_GetWindowID");
    pSDL_GetModState = dlsym(RTLD_DEFAULT, "SDL_GetModState");   // Task83
    NSLog(@"[InputDiag] initSDLEventFuncs: PushEvent=%p GetWindowID=%p g_sdlWindow=%p",
        (void*)pSDL_PushEvent, (void*)pSDL_GetWindowID, g_sdlWindow);
}

// Called from UIKit_CreateWindow to register the real SDL window
static void ame104_armAfkHeartbeat(void);  // Task104：AFK 心跳（前向声明，实现见 pushSDLMouseWheel 之后）

void Amethyst_SetSDLWindow(void *window) {
    g_sdlWindow = window;
    // Re-init in case libSDL3.dylib wasn't loaded at JNI_OnLoad time
    initSDLEventFuncs();
    // Task 104：窗口就绪即布防 AFK 心跳（26.3 的 30fps 短 AFK 限帧根治）
    ame104_armAfkHeartbeat();
    NSLog(@"[InputDiag] Amethyst_SetSDLWindow: %p PushEvent=%p", window, (void*)pSDL_PushEvent);
}

static SDL3_WindowID getSDLWindowID(void) {
    if (g_sdlWindow && pSDL_GetWindowID) {
        return pSDL_GetWindowID(g_sdlWindow);
    }
    return 0;
}

// Push a mouse motion event into SDL's event queue
static void pushSDLMouseMotion(float x, float y, float xrel, float yrel) {
    if (!pSDL_PushEvent || !g_sdlWindow) return;
    SDL3_MouseMotionEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = SDL3_EVENT_MOUSE_MOTION;
    ev.windowID = getSDLWindowID();
    ev.which = 0;
    ev.state = 0;
    ev.x = x;
    ev.y = y;
    ev.xrel = xrel;
    ev.yrel = yrel;
    pSDL_PushEvent((void*)&ev);
}

// Push a mouse button event into SDL's event queue
// sdlButton: 1=left, 2=middle, 3=right (SDL convention)
static void pushSDLMouseButton(uint8_t sdlButton, bool down, float x, float y) {
    if (!pSDL_PushEvent || !g_sdlWindow) return;
    SDL3_MouseButtonEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = down ? SDL3_EVENT_MOUSE_BUTTON_DOWN : SDL3_EVENT_MOUSE_BUTTON_UP;
    ev.windowID = getSDLWindowID();
    ev.which = 0;
    ev.button = sdlButton;
    ev.down = down;
    ev.clicks = 1;
    ev.x = x;
    ev.y = y;
    pSDL_PushEvent((void*)&ev);
}

// Task 53（输入修复）：SDL3 键事件的 key 字段（SDL_Keycode）。MC/RenderPearl
// 部分路径读 ev.key 而非 scancode；此前恒 0，空格/ESC/回车等在游戏内可能
// 无响应。纯函数计算（不 dlsym SDL_GetKeyFromScancode——规避跨版本 ABI
// 差异）：字母=小写 ASCII、数字=ASCII、常用控制键=SDL 控制字符码，其余
// = scancode | SDLK_SCANCODE_MASK(0x40000000)。
static uint32_t ame53_keycode_from_scancode(SDL3_Scancode sc) {
    if (sc >= 4 && sc <= 29)  return (uint32_t)('a' + (sc - 4));   // A-Z -> SDLK_a..z
    if (sc >= 30 && sc <= 38) return (uint32_t)('1' + (sc - 30));  // 1-9 -> SDLK_1..9
    if (sc == 39)             return (uint32_t)'0';                // SDLK_0
    switch (sc) {
        case 40: return 0x0D;   // SDLK_RETURN
        case 41: return 0x1B;   // SDLK_ESCAPE
        case 42: return 0x08;   // SDLK_BACKSPACE
        case 43: return 0x09;   // SDLK_TAB
        case 44: return 0x20;   // SDLK_SPACE
        case 45: return 0x2D;   // SDLK_MINUS '-'
        case 46: return 0x3D;   // SDLK_EQUAL '='
        case 47: return 0x5B;   // SDLK_LEFTBRACKET '['
        case 48: return 0x5D;   // SDLK_RIGHTBRACKET ']'
        case 49: return 0x5C;   // SDLK_BACKSLASH '\\'
        case 51: return 0x3B;   // SDLK_SEMICOLON ';'
        case 52: return 0x27;   // SDLK_APOSTROPHE '\''
        case 53: return 0x60;   // SDLK_GRAVE '`'
        case 54: return 0x2C;   // SDLK_COMMA ','
        case 55: return 0x2E;   // SDLK_PERIOD '.'
        case 56: return 0x2F;   // SDLK_SLASH '/'
        default:  return ((uint32_t)sc) | 0x40000000u;  // 功能键/小键盘等
    }
}

// Push a keyboard event into SDL's event queue
static void pushSDLKeyboardEvent(SDL3_Scancode scancode, bool down) {
    if (!pSDL_PushEvent || !g_sdlWindow) return;
    SDL3_KeyboardEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = down ? SDL3_EVENT_KEY_DOWN : SDL3_EVENT_KEY_UP;
    ev.windowID = getSDLWindowID();
    ev.which = 0;
    ev.scancode = scancode;
    ev.key = ame53_keycode_from_scancode(scancode);   // Task53: 补 key sym
    ev.mod = 0;
    ev.down = down;
    ev.repeat = false;
    pSDL_PushEvent((void*)&ev);
}

// ============================================================================
// Task 82：虚拟键盘文本输入（MC 26.3 / SDL3 路径）
//
// 根因：CallbackBridge_nativeSendChar 只有 GLFW 路径（GLFW_invoke_Char），
// 而 26.3 走 SDL3，GLFW_invoke_Char 恒为 NULL → 左上角 Keyboard 控件按钮
// 唤起的虚拟键盘打字全部被静默丢弃。修法：照 sendKey 的 Path B 模式，
// 把字符编成 UTF-8 后直接推 SDL_EVENT_TEXT_INPUT 事件，MC 26.3 的
// SDLEventHandler 会把它送进 keyboardHandler.textInput → charTyped
// （聊天框/搜索框等 Screen 打开时生效）。
// ============================================================================

// 每个 codepoint 的 UTF-8 最长 4 字节 + NUL = 5，取 8 对齐。
// 1024 个槽位：MC 每帧 pollEvents 排空队列，上千字符的积压只可能发生在
// 帧循环冻结时——那本身已是更大的故障。槽位复用只会覆盖早已被消费的事件。
#define AME82_TEXT_RING_SLOTS 1024
static char ame82_textRing[AME82_TEXT_RING_SLOTS][8];
static uint32_t ame82_textRingIdx = 0;
// UTF-16 代理对合并状态：TrackedTextField.sendText 按 UTF-16 码元逐个发送，
// emoji 等增补平面字符会拆成 high/low 两个码元，先记 high 再与 low 合并。
static uint32_t ame82_pendingHighSurrogate = 0;

static int ame82_utf8_encode(uint32_t cp, char out[8]) {
    if (cp < 0x80) {
        out[0] = (char)cp;
        return 1;
    }
    if (cp < 0x800) {
        out[0] = (char)(0xC0 | (cp >> 6));
        out[1] = (char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = (char)(0xE0 | (cp >> 12));
        out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[2] = (char)(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = (char)(0xF0 | (cp >> 18));
    out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    out[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    out[3] = (char)(0x80 | (cp & 0x3F));
    return 4;
}

// Push a text input event into SDL's event queue (one UTF-16 code unit,
// surrogate halves are merged into a single codepoint)
static void pushSDLTextInput(jchar codepoint) {
    if (!pSDL_PushEvent || !g_sdlWindow) return;

    uint32_t cp;
    if (codepoint >= 0xD800 && codepoint <= 0xDBFF) {
        // 高代理：等配对的低代理一起合成码点，暂不发事件
        ame82_pendingHighSurrogate = (uint32_t)codepoint;
        return;
    }
    if (codepoint >= 0xDC00 && codepoint <= 0xDFFF) {
        if (ame82_pendingHighSurrogate != 0) {
            cp = 0x10000 + ((ame82_pendingHighSurrogate - 0xD800) << 10) + ((uint32_t)codepoint - 0xDC00);
        } else {
            cp = 0xFFFD;   // 孤立低代理：替换字符，不向游戏注入乱码
        }
        ame82_pendingHighSurrogate = 0;
    } else {
        // 普通码元：若之前挂着一个未配对的高代理，就地丢弃（保持 UTF-16 语义）
        ame82_pendingHighSurrogate = 0;
        cp = (uint32_t)codepoint;
    }

    char *slot = ame82_textRing[ame82_textRingIdx];
    ame82_textRingIdx = (ame82_textRingIdx + 1) % AME82_TEXT_RING_SLOTS;
    const int len = ame82_utf8_encode(cp, slot);
    slot[len] = '\0';

    // 用 128 字节的 SDL3_Event 联合体承载，避免 SDL_PushEvent 拷贝整个
    // union 时读到栈上未初始化的尾部（32 字节的 TextInputEvent 单独声明
    // 会被越界读）。
    SDL3_Event ev;
    memset(&ev, 0, sizeof(ev));
    SDL3_TextInputEvent *te = (SDL3_TextInputEvent *)&ev;
    te->type = SDL3_EVENT_TEXT_INPUT;
    te->windowID = getSDLWindowID();
    te->text = slot;
    pSDL_PushEvent((void *)&ev);

    static int s_task82_textPushed = 0;
    s_task82_textPushed++;
    if (s_task82_textPushed <= 10 || s_task82_textPushed % 100 == 0) {
        NSLog(@"[InputDiag] Task82 SDL text input #%d: U+%04X -> \"%s\" (virtual keyboard chars now reach MC 26.3)",
              s_task82_textPushed, cp, slot);
    }
}

// ============================================================================
// Task 83：控件按钮键盘（custom 布局的 QWERTY 抽屉面板）打字支持
//
// 根因：SurfaceViewController executebtn 的 keycode>0 分支只发 GLFW key 事件
// （nativeSendKey → SDL3 key down/up 或 GLFW key 回调），而 MC 1.13+ 的
// 聊天框/书与笔/搜索框只消费 charTyped（GLFW char 回调 / SDL3
// SDL_EVENT_TEXT_INPUT）事件——纯 key 事件一律不进文本。所以"键盘图标"
// 抽屉里的字母/数字/符号按钮在聊天框里完全没有反应；而系统软键盘正常
// （inputTextField → nativeSendChar 链路，Task82 已修好 SDL3 分支）。
//
// 修法：executebtn 在按键按下（ACTION_DOWN）时对本键补发一个字符事件。
// - 映射按 US ANSI 布局（与 GLFW/CPredefinedProcGetKey 惯例一致）；
// - SHIFT 状态：SDL3 路径读 SDL_GetModState，GLFW 路径读 nativeSendKey
//   维护的 currMods；
// - Ctrl/Alt/Super 按住时抑制字符（与真实键盘一致：Ctrl+W 是快捷键不产文本，
//   也避免"持续奔跑"[CTRL,W] 组合键往聊天框里灌字符）；
// - CAPS_LOCK 按钮自管理虚拟大写状态（SDL 不为注入事件维护 KMOD_CAPS）；
// - 硬件键盘不受影响：pressesBegan → KeyboardInput.sendKeyEvent 同时发
//   key+char，不经过 executebtn，无重复字符风险。
// ============================================================================

static bool ame83_virtualCaps = false;

// GLFW 键码 → US ANSI 布局字符；不可打印键返回 0。
// shift/caps 仅对字母异或生效（真实键盘语义），数字/符号只看 shift。
static jchar ame83_keycodeToChar(int key, bool shift, bool caps) {
    if (key >= GLFW_KEY_A && key <= GLFW_KEY_Z) {
        bool upper = shift != caps;
        return (jchar)((key - GLFW_KEY_A) + (upper ? 'A' : 'a'));
    }
    if (key >= GLFW_KEY_0 && key <= GLFW_KEY_9) {
        if (!shift) return (jchar)('0' + (key - GLFW_KEY_0));
        static const jchar shifted[10] = {')','!','@','#','$','%','^','&','*','('};
        return shifted[key - GLFW_KEY_0];
    }
    if (key >= GLFW_KEY_NUMPAD_0 && key <= GLFW_KEY_NUMPAD_9) {
        return (jchar)('0' + (key - GLFW_KEY_NUMPAD_0));   // 小键盘不受 shift 影响
    }
    if (!shift) {
        switch (key) {
            case GLFW_KEY_SPACE:            return ' ';
            case GLFW_KEY_APOSTROPHE:       return '\'';
            case GLFW_KEY_COMMA:            return ',';
            case GLFW_KEY_MINUS:            return '-';
            case GLFW_KEY_PERIOD:           return '.';
            case GLFW_KEY_SLASH:            return '/';
            case GLFW_KEY_SEMICOLON:        return ';';
            case GLFW_KEY_EQUAL:            return '=';
            case GLFW_KEY_LEFT_BRACKET:     return '[';
            case GLFW_KEY_BACKSLASH:        return '\\';
            case GLFW_KEY_RIGHT_BRACKET:    return ']';
            case GLFW_KEY_GRAVE_ACCENT:     return '`';
            case GLFW_KEY_NUMPAD_DECIMAL:   return '.';
            case GLFW_KEY_NUMPAD_DIVIDE:    return '/';
            case GLFW_KEY_NUMPAD_MULTIPLY:  return '*';
            case GLFW_KEY_NUMPAD_SUBTRACT:  return '-';
            case GLFW_KEY_NUMPAD_ADD:       return '+';
            case GLFW_KEY_NUMPAD_EQUAL:     return '=';
        }
    } else {
        switch (key) {
            case GLFW_KEY_SPACE:            return ' ';
            // 34 = ASCII 双引号字符。不写成字面量形式：历史校验脚本
            // （括号计数器）先剥字符串再剥字符字面量，字面量里的双引号会被
            // 误当字符串起点，翻转全文件引号配对。
            case GLFW_KEY_APOSTROPHE:       return 34;
            case GLFW_KEY_COMMA:            return '<';
            case GLFW_KEY_MINUS:            return '_';
            case GLFW_KEY_PERIOD:           return '>';
            case GLFW_KEY_SLASH:            return '?';
            case GLFW_KEY_SEMICOLON:        return ':';
            case GLFW_KEY_EQUAL:            return '+';
            case GLFW_KEY_LEFT_BRACKET:     return '{';
            case GLFW_KEY_BACKSLASH:        return '|';
            case GLFW_KEY_RIGHT_BRACKET:    return '}';
            case GLFW_KEY_GRAVE_ACCENT:     return '~';
        }
    }
    return 0;
}

// executebtn 专用：按键按下时补发字符事件（Task83）。
// 返回 YES 表示发出了字符。仅由按钮路径调用，硬件键盘不走这里。
char getKeyModifiers(int key, int action);   // 定义于本文件 nativeSendKey 段

BOOL CallbackBridge_buttonKeySynthesizeText(int key) {
    if (key == GLFW_KEY_CAPS_LOCK) {
        ame83_virtualCaps = !ame83_virtualCaps;
        NSLog(@"[InputDiag] Task83 virtual caps-lock -> %d (button keyboard)", ame83_virtualCaps ? 1 : 0);
        return NO;
    }

    bool shift, ctrlLike;
    if (!GLFW_invoke_Char && g_sdlWindow && pSDL_GetModState != NULL) {
        // SDL3 路径（MC 26.3+）：修饰键态读 SDL 当前 mod state
        unsigned short m = pSDL_GetModState();
        shift = (m & 0x0003) != 0;                       // KMOD_LSHIFT|KMOD_RSHIFT
        ctrlLike = (m & (0x00C0 | 0x0300 | 0x0C00)) != 0; // Ctrl|Alt|GUI
    } else {
        // GLFW 路径（旧版 MC）：nativeSendKey 维护的 currMods（key=0 纯查询）
        char m = getKeyModifiers(0, 0);
        shift = (m & GLFW_MOD_SHIFT) != 0;
        ctrlLike = (m & (GLFW_MOD_CONTROL | GLFW_MOD_ALT | GLFW_MOD_SUPER)) != 0;
    }

    if (ctrlLike) return NO;   // Ctrl/Alt/Super 组合 = 快捷键语义，不产文本

    jchar ch = ame83_keycodeToChar(key, shift, ame83_virtualCaps);
    if (ch == 0) return NO;

    CallbackBridge_nativeSendChar(ch);
    static int s_task83_chars = 0;
    s_task83_chars++;
    if (s_task83_chars <= 10 || s_task83_chars % 100 == 0) {
        NSLog(@"[InputDiag] Task83 button text #%d: glfwKey=%d -> '%C' (button keyboard types in chat now)",
              s_task83_chars, key, ch);
    }
    return YES;
}

// Push a mouse wheel event into SDL's event queue
static void pushSDLMouseWheel(float x, float y) {
    if (!pSDL_PushEvent || !g_sdlWindow) return;
    SDL3_MouseWheelEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = SDL3_EVENT_MOUSE_WHEEL;
    ev.windowID = getSDLWindowID();
    ev.which = 0;
    ev.x = x;
    ev.y = y;
    ev.direction = 0;
    ev.mouse_x = cursorX;
    ev.mouse_y = cursorY;
    ev.integer_x = (int32_t)x;
    ev.integer_y = (int32_t)y;
    pSDL_PushEvent((void*)&ev);
}

// GLFW keycode → SDL_Scancode conversion
// ============================================================================
// Task 104（26.3 30fps 根治）：AFK 心跳——每 45s 推一个 (0,0) SDL 滚轮。
//
// 根因链（piston-data 26.3 client.jar CFR 反编译实证）：
//   * MC 26.3 的 FramerateLimitTracker.getThrottleReason()：当
//     inactivityFpsLimit == AFK（该版本默认值，InactivityFpsLimit 枚举仅
//     minimized/afk 两值）且 Util.getMillis() - latestInputTime > 60000ms
//     时返回 SHORT_AFK → getFramerateLimit() = min(maxFps, 30) = 30；
//   * Minecraft.runTick 尾部 framerateLimit < 260 时调
//     FramerateLimiter.limitDisplayFPS(framerateLimit)（LockSupport.parkNanos
//     睡到 33ms/帧）；
//   * iOS 上除触摸外没有持续输入流 → 加载期/挂机期必然越过 60s 阈值
//     → 整个加载期 + 无操作期被压在 30fps。与渲染器无关（zink/MG/MobileGL 同病）。
//     输入重置点仅在 MouseHandler.onButton/onScroll/onDrop/
//     handleAccumulatedMovement（后者还要求 isWindowActive）。
//
// 修复策略（双保险）：
//   1. 启动器仍写 inactivityFpsLimit=minimized（PojavLauncher，本轮加
//      落盘校验日志）+ MCOptionUtils.set 去重写入（清掉残留的 afk 旧行）；
//   2. 本心跳：游戏窗口就绪后每 45s 推一个 (0,0) SDL_MOUSEWHEEL ——
//     MouseHandler.onScroll 在句柄检查后第一行就是 onInputReceived()，
//     SHORT_AFK/LONG_AFK 的 60s/600s 阈值在游戏运行期间永不达成。
//
// (0,0) 滚轮的零副作用论证（26.3 反编译）：
//   * 加载期 overlay != null → onScroll 整个处理体被跳过（仅剩
//     onInputReceived）；
//   * 游戏内 screen==null → scrollWheelHandler.onMouseScroll(0,0) →
//     wheelXY=(0,0) → 提前 return（快捷栏不变）；
//   * 菜单内 screen.mouseScrolled(x,y,0,0)：0 增量对原版控件为算术空转。
// GLFW 路径（1.20.1 等）g_sdlWindow 恒 NULL，心跳静默不推（零回归——
// 旧版本无 inactivityFpsLimit 机制）。
// ============================================================================
static void ame104_armAfkHeartbeat(void) {
    static dispatch_source_t s_ame104_timer = nil;
    if (s_ame104_timer) return;
    s_ame104_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    if (!s_ame104_timer) return;
    dispatch_source_set_timer(s_ame104_timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)45 * NSEC_PER_SEC),
                              (int64_t)45 * NSEC_PER_SEC,
                              (int64_t)5 * NSEC_PER_SEC);
    static unsigned long s_ame104_beats = 0;
    dispatch_source_set_event_handler(s_ame104_timer, ^{
        if (!g_sdlWindow || !pSDL_PushEvent) return;
        pushSDLMouseWheel(0.0f, 0.0f);
        ++s_ame104_beats;
        if (s_ame104_beats <= 3 || s_ame104_beats % 20 == 0) {
            NSLog(@"[InputDiag] Task104 AFK heartbeat #%lu: wheel(0,0) pushed -- MC onScroll resets the 60s inactivity clock (SHORT_AFK 30fps cap unreachable)",
                  s_ame104_beats);
        }
    });
    dispatch_resume(s_ame104_timer);
    NSLog(@"[InputDiag] Task104 AFK heartbeat armed: 45s interval, wheel(0,0) -- inactivity FPS caps (30/10) cannot engage while the game runs");
}

static int glfwKeyToSDLScancode(int glfwKey) {
    // Printable keys: ASCII-based, same as USB HID usage
    if (glfwKey >= GLFW_KEY_A && glfwKey <= GLFW_KEY_Z) return 4 + (glfwKey - GLFW_KEY_A);   // SDL_SCANCODE_A=4
    // Task 53（输入修复）：数字键修正。SDL 扫描码是 HID 顺序 1,2,...,9,0
    //（SDL_SCANCODE_1=30 ... SDL_SCANCODE_9=38, SDL_SCANCODE_0=39），不是
    // 0,1,...,9。旧映射 `39 + (glfwKey - GLFW_KEY_0)` 把 1-9 全部偏移 +10
    //（→40..48 = RETURN/ESC/BACKSPACE/TAB/SPACE/MINUS/...），表现为：快捷栏
    // 数字键全部失效、按 5 变成空格等错乱。
    if (glfwKey >= GLFW_KEY_1 && glfwKey <= GLFW_KEY_9) return 30 + (glfwKey - GLFW_KEY_1); // SDL_SCANCODE_1=30..SDL_SCANCODE_9=38
    if (glfwKey == GLFW_KEY_0) return 39;                                                  // SDL_SCANCODE_0=39
    if (glfwKey >= GLFW_KEY_F1 && glfwKey <= GLFW_KEY_F25) return 58 + (glfwKey - GLFW_KEY_F1); // SDL_SCANCODE_F1=58
    if (glfwKey >= GLFW_KEY_NUMPAD_0 && glfwKey <= GLFW_KEY_NUMPAD_9) return 98 + (glfwKey - GLFW_KEY_NUMPAD_0);
    switch (glfwKey) {
        case GLFW_KEY_SPACE:           return 44;
        case GLFW_KEY_APOSTROPHE:      return 52;
        case GLFW_KEY_COMMA:           return 54;
        case GLFW_KEY_MINUS:           return 45;
        case GLFW_KEY_PERIOD:          return 55;
        case GLFW_KEY_SLASH:           return 56;
        case GLFW_KEY_SEMICOLON:       return 51;
        case GLFW_KEY_EQUAL:           return 46;
        case GLFW_KEY_LEFT_BRACKET:    return 47;
        case GLFW_KEY_BACKSLASH:       return 49;
        case GLFW_KEY_RIGHT_BRACKET:   return 48;
        case GLFW_KEY_GRAVE_ACCENT:    return 53;
        case GLFW_KEY_ESCAPE:          return 41;
        case GLFW_KEY_ENTER:           return 40;
        case GLFW_KEY_TAB:             return 43;
        case GLFW_KEY_BACKSPACE:       return 42;
        case GLFW_KEY_INSERT:          return 73;
        case GLFW_KEY_DELETE:          return 76;
        case GLFW_KEY_DPAD_RIGHT:      return 79;
        case GLFW_KEY_DPAD_LEFT:       return 80;
        case GLFW_KEY_DPAD_DOWN:       return 81;
        case GLFW_KEY_DPAD_UP:         return 82;
        case GLFW_KEY_PAGE_UP:         return 75;
        case GLFW_KEY_PAGE_DOWN:       return 78;
        case GLFW_KEY_HOME:            return 74;
        case GLFW_KEY_END:             return 77;
        case GLFW_KEY_CAPS_LOCK:       return 57;
        case GLFW_KEY_SCROLL_LOCK:     return 71;
        case GLFW_KEY_NUM_LOCK:        return 83;
        case GLFW_KEY_PRINT_SCREEN:    return 70;
        case GLFW_KEY_PAUSE:           return 72;
        case GLFW_KEY_LEFT_SHIFT:      return 225;
        case GLFW_KEY_LEFT_CONTROL:    return 224;
        case GLFW_KEY_LEFT_ALT:        return 226;
        case GLFW_KEY_LEFT_SUPER:      return 227;
        case GLFW_KEY_RIGHT_SHIFT:     return 229;
        case GLFW_KEY_RIGHT_CONTROL:   return 228;
        case GLFW_KEY_RIGHT_ALT:       return 230;
        case GLFW_KEY_RIGHT_SUPER:     return 231;
        case GLFW_KEY_MENU:            return 101;
        case GLFW_KEY_NUMPAD_ADD:      return 87;
        case GLFW_KEY_NUMPAD_SUBTRACT: return 86;
        case GLFW_KEY_NUMPAD_MULTIPLY: return 85;
        case GLFW_KEY_NUMPAD_DIVIDE:   return 84;
        case GLFW_KEY_NUMPAD_DECIMAL:  return 220;
        case GLFW_KEY_NUMPAD_ENTER:    return 88;
        case GLFW_KEY_NUMPAD_EQUAL:    return 103;
        default:                       return 0; // SDL_SCANCODE_UNKNOWN
    }
}

// SDL button ID mapping: GLFW uses 0-based, SDL uses 1-based
static uint8_t glfwButtonToSDLButton(int glfwButton) {
    switch (glfwButton) {
        case GLFW_MOUSE_BUTTON_LEFT:   return 1; // SDL_BUTTON_LEFT
        case GLFW_MOUSE_BUTTON_RIGHT:  return 3; // SDL_BUTTON_RIGHT
        case GLFW_MOUSE_BUTTON_MIDDLE: return 2; // SDL_BUTTON_MIDDLE
        default:                       return (uint8_t)(glfwButton + 1);
    }
}

jint (*orig_ProcessImpl_forkAndExec)(JNIEnv *env, jobject process, jint mode, jbyteArray helperpath, jbyteArray prog, jbyteArray argBlock, jint argc, jbyteArray envBlock, jint envc, jbyteArray dir, jintArray std_fds, jboolean redirectErrorStream);
jlong (*orig_ProcessHandleImpl_isAlive0)(JNIEnv *env, jclass clazz, jlong jpid);

NSString* processPath(NSString* path) {
    if ([path hasPrefix:@"file:"]) {
        path = [path substringFromIndex:5].stringByRemovingPercentEncoding;
    }
    path = path.stringByResolvingSymlinksInPath;

    NSString *prefix = @"file";
    if ([UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:@"shareddocuments://"]] &&
      ![path hasPrefix:@"/var/mobile/Documents"]) {
        // Prefer opening in Files if containerized
        prefix = @"shareddocuments";
    } else if ([UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:@"filza://"]]) {
        // Open in Filza if installed
        prefix = @"filza";
    } else if ([UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:@"santander://"]]) {
        // Open in Santander if installed
        prefix = @"santander";
    }

    return [NSString stringWithFormat:@"%@://%@", prefix, path];
}

void openURLGlobal(NSString *path) {
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);

    dispatch_async(dispatch_get_main_queue(), ^{
        if ([path hasPrefix:@"http"]) {
            openLink(UIWindow.mainWindow.rootViewController, [NSURL URLWithString:path]);
            dispatch_group_leave(group);
            return;
        }
        NSString *realPath = processPath(path);
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:realPath] options:@{} completionHandler:^(BOOL success) {
            if (success) {
                NSLog(@"Opened \"%@\"", realPath);
            } else {
                NSLog(@"Failed to open \"%@\"", realPath);
            }
            dispatch_group_leave(group);
        }];
    });

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
}

/**
 * Hooked version of java.lang.UNIXProcess.forkAndExec()
 * which is used to handle the "open" command.
 *
 * iOS 沙箱禁止 fork/exec，原生 forkAndExec 必然失败并可能导致进程崩溃。
 * 此处对非 "open" 命令不再透传给原生实现，而是抛出明确的 Java IOException，
 * 让调用方（如 Forge/NeoForge installer.jar 的 processor 步骤）能优雅失败而非原生崩溃。
 * "open" 命令仍走 URL scheme 转发到 Files/Filza 等外部应用。
 */
jint
hooked_ProcessImpl_forkAndExec(JNIEnv *env, jobject process, jint mode, jbyteArray helperpath, jbyteArray prog, jbyteArray argBlock, jint argc, jbyteArray envBlock, jint envc, jbyteArray dir, jintArray std_fds, jboolean redirectErrorStream) {
    char *pProg = (char *)((*env)->GetByteArrayElements(env, prog, NULL));

    // Here we only handle the "open" command
    if (strcmp(basename(pProg), "open")) {
        // 非 "open" 命令：iOS 沙箱禁止 fork/exec，透传给原生实现会导致
        // "Operation not permitted" 或直接崩溃。改为抛 IOException 让上层优雅失败。
        NSLog(@"[input_bridge] Blocked fork/exec of '%s' (iOS sandbox forbids fork/exec)", pProg);
        (*env)->ReleaseByteArrayElements(env, prog, (jbyte *)pProg, 0);
        jclass exClass = (*env)->FindClass(env, "java/io/IOException");
        if (exClass != NULL) {
            (*env)->ThrowNew(env, exClass, "fork/exec not permitted on iOS sandbox");
            (*env)->DeleteLocalRef(env, exClass);
        }
        return -1;
    }

    char *path = (char *)((*env)->GetByteArrayElements(env, argBlock, NULL));
    openURLGlobal(@(path));

    (*env)->ReleaseByteArrayElements(env, prog, (jbyte *)pProg, 0);
    (*env)->ReleaseByteArrayElements(env, argBlock, (jbyte *)path, 0);
    return 0;
}

/**
 * Hooked version of java.lang.ProcessHandleImpl.isAlive0()
 * which is used to ignore "Operation not permitted"
 */
jlong hooked_ProcessHandleImpl_isAlive0(JNIEnv *env, jclass clazz, jlong jpid) {
    jlong result = orig_ProcessHandleImpl_isAlive0(env, clazz, jpid);
    if ((*env)->ExceptionOccurred(env)) {
        (*env)->ExceptionClear(env);
    }
    return result;
}

// Part of awt_bridge
void CTCClipboard_nQuerySystemClipboard(JNIEnv *env, jclass clazz) {
    if(method_SystemClipboardDataReceived == NULL) {
        class_CTCClipboard = (*env)->NewGlobalRef(env, clazz);
        method_SystemClipboardDataReceived = (*env)->GetStaticMethodID(env, clazz, "systemClipboardDataReceived", "(Ljava/lang/String;Ljava/lang/String;)V");
    }
    // From Java_net_kdt_pojavlaunch_AWTInputBridge_nativeClipboardReceived
    // Note: we cannot use main_queue here as it will cause deadlock
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        JNIEnv *env;
        (*runtimeJavaVMPtr)->AttachCurrentThread(runtimeJavaVMPtr, &env, NULL);
        const char* mimeChars = "text/plain";
        (*env)->CallStaticVoidMethod(env, class_CTCClipboard, method_SystemClipboardDataReceived,
            UIKit_accessClipboard(env, CLIPBOARD_PASTE, NULL),
            (*env)->NewStringUTF(env, mimeChars));
        (*runtimeJavaVMPtr)->DetachCurrentThread(runtimeJavaVMPtr);
    });
}

void CTCClipboard_nPutClipboardData(JNIEnv* env, jclass clazz, jstring clipboardData, jstring clipboardDataMime) {
    // TODO: handle non-text data(?)
    UIKit_accessClipboard(env, CLIPBOARD_COPY, clipboardData);
}

void CTCDesktopPeer_openGlobal(JNIEnv *env, jclass clazz, jstring path) {
    const char* stringChars = (*env)->GetStringUTFChars(env, path, NULL);
    openURLGlobal(@(stringChars));
    (*env)->ReleaseStringUTFChars(env, path, stringChars);
}

void registerOpenHandler(JNIEnv *env) {
    jclass cls;

    // Hook forkAndExec
    orig_ProcessImpl_forkAndExec = dlsym(RTLD_DEFAULT, "Java_java_lang_UNIXProcess_forkAndExec");
    if (!orig_ProcessImpl_forkAndExec) {
        orig_ProcessImpl_forkAndExec = dlsym(RTLD_DEFAULT, "Java_java_lang_ProcessImpl_forkAndExec");
        cls = (*env)->FindClass(env, "java/lang/ProcessImpl");
    } else {
        cls = (*env)->FindClass(env, "java/lang/UNIXProcess");
    }
    JNINativeMethod forkAndExecMethod[] = {
        {"forkAndExec", "(I[B[B[BI[BI[B[IZ)I", (void *)&hooked_ProcessImpl_forkAndExec}
    };
    (*env)->RegisterNatives(env, cls, forkAndExecMethod, 1);

    // (Java 17 only) Hook isAlive0
    cls = (*env)->FindClass(env, "java/lang/ProcessHandleImpl");
    if ((*env)->ExceptionOccurred(env)) {
        // Java 8
        (*env)->ExceptionClear(env);
    } else {
        orig_ProcessHandleImpl_isAlive0 = dlsym(RTLD_DEFAULT, "Java_java_lang_ProcessHandleImpl_isAlive0");
        JNINativeMethod isAlive0Method[] = {
            {"isAlive0", "(J)J", (void *)&hooked_ProcessHandleImpl_isAlive0}
        };
        (*env)->RegisterNatives(env, cls, isAlive0Method, 1);
    }

    // Register CTCClipboard natives
    cls = (*env)->FindClass(env, "net/java/openjdk/cacio/ctc/CTCClipboard");
    if ((*env)->ExceptionOccurred(env)) {
        // Java 17
        (*env)->ExceptionClear(env);
        cls = (*env)->FindClass(env, "com/github/caciocavallosilano/cacio/ctc/CTCClipboard");
    }
    JNINativeMethod clipboardMethods[] = {
        {"nQuerySystemClipboard", "()V", (void *)&CTCClipboard_nQuerySystemClipboard},
        {"nPutClipboardData", "(Ljava/lang/String;Ljava/lang/String;)V", (void *)&CTCClipboard_nPutClipboardData}
    };
    (*env)->RegisterNatives(env, cls, clipboardMethods, 2);

    // Register CTCDesktopPeer natives
    cls = (*env)->FindClass(env, "net/java/openjdk/cacio/ctc/CTCDesktopPeer");
    if ((*env)->ExceptionOccurred(env)) {
        // Java 17, not available
        //(*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        return;
    }
    JNINativeMethod peerOpenMethods[] = {
        {"openFile", "(Ljava/lang/String;)V", (void *)&CTCDesktopPeer_openGlobal},
        {"openUri", "(Ljava/lang/String;)V", (void *)&CTCDesktopPeer_openGlobal}
    };
    (*env)->RegisterNatives(env, cls, peerOpenMethods, 2);
}

// JNI_OnLoad
void JNI_OnLoadGLFW() {
    if (runtimeJNIEnvPtr == NULL) {
        NSLog(@"[JNI] JNI_OnLoadGLFW: runtimeJNIEnvPtr is NULL, skipping");
        return;
    }
    jclass clazz = (*runtimeJNIEnvPtr)->FindClass(runtimeJNIEnvPtr, "org/lwjgl/glfw/GLFW");
    if (clazz == NULL) {
        if ((*runtimeJNIEnvPtr)->ExceptionOccurred(runtimeJNIEnvPtr)) {
            (*runtimeJNIEnvPtr)->ExceptionDescribe(runtimeJNIEnvPtr);
            (*runtimeJNIEnvPtr)->ExceptionClear(runtimeJNIEnvPtr);
        }
        NSLog(@"[JNI] JNI_OnLoadGLFW: FindClass(org/lwjgl/glfw/GLFW) returned NULL, skipping registration");
        return;
    }
    vmGlfwClass = (*runtimeJNIEnvPtr)->NewGlobalRef(runtimeJNIEnvPtr, clazz);
    method_internalWindowSizeChanged = (*runtimeJNIEnvPtr)->GetStaticMethodID(runtimeJNIEnvPtr, vmGlfwClass, "internalWindowSizeChanged", "(JII)V");
    if ((*runtimeJNIEnvPtr)->ExceptionOccurred(runtimeJNIEnvPtr)) {
        (*runtimeJNIEnvPtr)->ExceptionDescribe(runtimeJNIEnvPtr);
        (*runtimeJNIEnvPtr)->ExceptionClear(runtimeJNIEnvPtr);
        method_internalWindowSizeChanged = NULL;
    }
    jfieldID field_keyDownBuffer = (*runtimeJNIEnvPtr)->GetStaticFieldID(runtimeJNIEnvPtr, vmGlfwClass, "keyDownBuffer", "Ljava/nio/ByteBuffer;");
    if ((*runtimeJNIEnvPtr)->ExceptionOccurred(runtimeJNIEnvPtr)) {
        (*runtimeJNIEnvPtr)->ExceptionDescribe(runtimeJNIEnvPtr);
        (*runtimeJNIEnvPtr)->ExceptionClear(runtimeJNIEnvPtr);
        field_keyDownBuffer = NULL;
    }
    if (field_keyDownBuffer != NULL) {
        jobject keyDownBufferJ = (*runtimeJNIEnvPtr)->GetStaticObjectField(runtimeJNIEnvPtr, vmGlfwClass, field_keyDownBuffer);
        if (keyDownBufferJ != NULL) {
            keyDownBuffer = (*runtimeJNIEnvPtr)->GetDirectBufferAddress(runtimeJNIEnvPtr, keyDownBufferJ);
        }
    }
    NSLog(@"[JNI] JNI_OnLoadGLFW registered, class=%p, method=%p, keyDownBuffer=%p", (void *)vmGlfwClass, (void *)method_internalWindowSizeChanged, (void *)keyDownBuffer);
}

jint JNI_OnLoad(JavaVM* vm, void* reserved) {
    runtimeJavaVMPtr = vm;

    // Initialize SDL3 event function pointers for MC 26.3+ input
    initSDLEventFuncs();

    JNIEnv *env;
    (*runtimeJavaVMPtr)->GetEnv(runtimeJavaVMPtr, (void **)&env, JNI_VERSION_1_4);
    registerOpenHandler(env);
    if (!getenv("POJAV_SKIP_JNI_GLFW")) {
        runtimeJNIEnvPtr = env;
        JNI_OnLoadGLFW();
    }

    return JNI_VERSION_1_4;
}

// Should be?
void JNI_OnUnload(JavaVM* vm, void* reserved) {
    runtimeJNIEnvPtr = NULL;
}

#define ADD_CALLBACK_WWIN(NAME) \
JNIEXPORT jlong JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSet##NAME##Callback(JNIEnv * env, jclass cls, jlong window, jlong callbackptr) { \
    void** oldCallback = (void**) &GLFW_invoke_##NAME; \
    GLFW_invoke_##NAME = (GLFW_invoke_##NAME##_func*) (uintptr_t) callbackptr; \
    return (jlong) (uintptr_t) *oldCallback; \
}

ADD_CALLBACK_WWIN(Char)
ADD_CALLBACK_WWIN(CharMods)
ADD_CALLBACK_WWIN(CursorEnter)
ADD_CALLBACK_WWIN(CursorPos)
ADD_CALLBACK_WWIN(FramebufferSize)
ADD_CALLBACK_WWIN(Key)
ADD_CALLBACK_WWIN(MouseButton)
ADD_CALLBACK_WWIN(Scroll)
ADD_CALLBACK_WWIN(WindowPos)
ADD_CALLBACK_WWIN(WindowSize)

#undef ADD_CALLBACK_WWIN

void handleFramebufferSizeJava(void* window, int w, int h) {
    if(GLFW_invoke_CursorEnter)GLFW_invoke_CursorEnter(window, 1);
    if(GLFW_invoke_WindowPos)GLFW_invoke_WindowPos(window, 0, 0);
    (*runtimeJNIEnvPtr)->CallStaticVoidMethod(runtimeJNIEnvPtr, vmGlfwClass, method_internalWindowSizeChanged, (long)window, w, h);
}

// Issue #140 加固：事件队列容量与 environ.h 中的 events[8000] 严格对应。
// 之前散落在各处的字面量 7999 与数组真实长度不一致，是越界读取的隐患。
#define AME_EVENT_QUEUE_CAP 8000

void pojavPumpEvents(void* window) {
    static BOOL setInputReady = NO;
    static int pumpCount = 0;
    if(!setInputReady) {
        setInputReady = YES;
        CallbackBridge_nativeSetInputReady(YES);
        NSLog(@"[InputDiag] pojavPumpEvents: isInputReady set to YES, showingWindow=%p", (void*)showingWindow);
    }
    pumpCount++;

    // Poll SDL relative mouse mode periodically (not just on touch) so cursor
    // hides automatically when entering the map, without needing a touch first.
    if (g_sdlWindow && pumpCount % 30 == 0) {
        typedef bool (*GetRelModeFunc)(void*);
        static GetRelModeFunc getRelMode = NULL;
        static bool inited = false;
        if (!inited) {
            getRelMode = (GetRelModeFunc)dlsym(RTLD_DEFAULT, "SDL_GetWindowRelativeMouseMode");
            inited = true;
        }
        if (getRelMode) {
            bool relMode = getRelMode(g_sdlWindow);
            if (relMode != isGrabbing) {
                BOOL wasGrabbing = isGrabbing;
                isGrabbing = relMode;

                if (!wasGrabbing && relMode) {
                    pushSDLMouseButton(1, false, (float)cursorX, (float)cursorY);
                }

                typedef bool (*VoidFunc)(void);
                static VoidFunc hideCursor = NULL;
                static VoidFunc showCursor = NULL;
                if (!hideCursor) hideCursor = (VoidFunc)dlsym(RTLD_DEFAULT, "SDL_HideCursor");
                if (!showCursor) showCursor = (VoidFunc)dlsym(RTLD_DEFAULT, "SDL_ShowCursor");
                if (relMode && hideCursor) hideCursor();
                else if (!relMode && showCursor) showCursor();

                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        // Issue #140 加固：rootViewController 的类型并非恒为
                        // SurfaceViewController（分栏容器/外部显示场景下会变）。
                        // 原先无条件强转后调用，一旦类型不符就会打到错误的选择子上。
                        UIViewController *root = UIWindow.mainWindow.rootViewController;
                        if ([root isKindOfClass:[SurfaceViewController class]]) {
                            [(SurfaceViewController *)root updateGrabState];
                        }
                    } @catch (NSException *e) {}
                });

                NSLog(@"[InputDiag] isGrabbing synced from SDL (pump): %d", isGrabbing);
            }
        }
    }
    if (pumpCount <= 5 || pumpCount % 300 == 0) {
        NSLog(@"[InputDiag] pojavPumpEvents #%d: window=%p GLFW_invoke_Key=%p GLFW_invoke_CursorPos=%p GLFW_invoke_Char=%p isGrabbing=%d isUseStackQueue=%d eventCounter=%d",
            pumpCount, window,
            (void*)GLFW_invoke_Key, (void*)GLFW_invoke_CursorPos, (void*)GLFW_invoke_Char,
            isGrabbing, isUseStackQueueCall,
            (int)atomic_load_explicit(&eventCounter, memory_order_relaxed));
    }
    size_t counter = atomic_load_explicit(&eventCounter, memory_order_acquire);
    // Issue #140 加固：counter 由其它线程递增，读取到的值可能超过数组长度
    // （并发窗口内 fetch_add 与钳制之间存在时间差）。越界的循环读取会扫到
    // events 之后的全局数据，读到什么完全不可控。
    if (counter > AME_EVENT_QUEUE_CAP) {
        counter = AME_EVENT_QUEUE_CAP;
        atomic_store_explicit(&eventCounter, AME_EVENT_QUEUE_CAP, memory_order_release);
    }
    if((cLastX != cursorX || cLastY != cursorY) && GLFW_invoke_CursorPos) {
        cLastX = cursorX;
        cLastY = cursorY;
        if (isUseStackQueueCall)
            GLFW_invoke_CursorPos(window, cursorX, cursorY);
    }
    for(size_t i = 0; i < counter; i++) {
        GLFWInputEvent event = events[i];
        switch(event.type) {
            case EVENT_TYPE_CHAR:
                if(GLFW_invoke_Char) GLFW_invoke_Char(window, event.i1);
                break;
            case EVENT_TYPE_CHAR_MODS:
                if(GLFW_invoke_CharMods) GLFW_invoke_CharMods(window, event.i1, event.i2);
                break;
            case EVENT_TYPE_KEY:
                if(GLFW_invoke_Key) GLFW_invoke_Key(window, event.i1, event.i2, event.i3, event.i4);
                break;
            case EVENT_TYPE_MODIFIERS:
                CallbackBridge_syncModifiersToMC(event.i1);
                break;
            case EVENT_TYPE_MOUSE_BUTTON:
                if(GLFW_invoke_MouseButton) GLFW_invoke_MouseButton(window, event.i1, event.i2, event.i3);
                break;
            case EVENT_TYPE_SCROLL:
                if(GLFW_invoke_Scroll) GLFW_invoke_Scroll(window, event.f1, event.f2);
                break;
            case EVENT_TYPE_FRAMEBUFFER_SIZE:
                handleFramebufferSizeJava(window, event.i1, event.i2);
                if(GLFW_invoke_FramebufferSize) GLFW_invoke_FramebufferSize(window, event.i1, event.i2);
                break;
            case EVENT_TYPE_WINDOW_SIZE:
                handleFramebufferSizeJava(window, event.i1, event.i2);
                if(GLFW_invoke_WindowSize) GLFW_invoke_WindowSize(window, event.i1, event.i2);
                break;
        }
    }
    // Issue #140 加固：派发完必须把队列消费掉。原先这里写回的是同一个 counter，
    // 等于一条事件都没清——事件会被逐帧重放，且 counter 一旦涨到上限，
    // sendData 的新事件就被永久丢弃，输入彻底失灵。
    atomic_store_explicit(&eventCounter, 0, memory_order_release);
}
void pojavRewindEvents() {
    atomic_store_explicit(&eventCounter, 0, memory_order_release);
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwGetCursorPos(JNIEnv *env, jclass clazz, jlong window, jobject xpos,
                                          jobject ypos) {
    *(double*)(*env)->GetDirectBufferAddress(env, xpos) = cursorX;
    *(double*)(*env)->GetDirectBufferAddress(env, ypos) = cursorY;
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwGetCursorPosA(JNIEnv *env, jclass clazz, jlong window,
                                            jdoubleArray xpos, jdoubleArray ypos) {
    (*env)->SetDoubleArrayRegion(env, xpos, 0,1, &cursorX);
    (*env)->SetDoubleArrayRegion(env, ypos, 0,1, &cursorY);
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_GLFW_glfwSetCursorPos(JNIEnv *env, jclass clazz, jlong window, jdouble xpos,
                                          jdouble ypos) {
    cLastX = cursorX = xpos;
    cLastY = cursorY = ypos;
}

void sendData(short type, int i1, int i2, short i3, short i4) {
    // Issue #140 加固：原先是 load → 写槽 → store(counter+1) 的三步非原子序列。
    // 触摸线程与游戏线程并发进来时，两个写者会拿到同一个槽位互相覆盖，
    // 而消费者可能读到写了一半的事件。改为原子占位再写，槽位一一对应。
    size_t slot = atomic_fetch_add_explicit(&eventCounter, 1, memory_order_acq_rel);
    if (slot < AME_EVENT_QUEUE_CAP) {
        GLFWInputEvent *event = &events[slot];
        event->type = type;
        event->i1 = i1;
        event->i2 = i2;
        event->i3 = i3;
        event->i4 = i4;
    } else {
        atomic_store_explicit(&eventCounter, AME_EVENT_QUEUE_CAP, memory_order_release);
    }
}

void sendDataFloat(short type, float i1, float i2, short i3, short i4) {
    size_t slot = atomic_fetch_add_explicit(&eventCounter, 1, memory_order_acq_rel);
    if (slot < AME_EVENT_QUEUE_CAP) {
        GLFWInputEvent *event = &events[slot];
        event->type = type;
        event->f1 = i1;
        event->f2 = i2;
        event->i3 = i3;
        event->i4 = i4;
    } else {
        atomic_store_explicit(&eventCounter, AME_EVENT_QUEUE_CAP, memory_order_release);
    }
}

void closeGLFWWindow() {
    NSLog(@"Closing GLFW window");

    /*
    jclass glfwClazz = (*runtimeJNIEnvPtr)->FindClass(runtimeJNIEnvPtr, "org/lwjgl/glfw/GLFW");
    assert(glfwClazz != NULL);
    jmethodID glfwMethod = (*runtimeJNIEnvPtr)->GetStaticMethodID(runtimeJNIEnvPtr, glfwMethod, "glfwSetWindowShouldClose", "(JZ)V");
    assert(glfwMethod != NULL);
    
    (*runtimeJNIEnvPtr)->CallStaticVoidMethod(
        runtimeJNIEnvPtr,
        glfwClazz, glfwMethod,
        (jlong) showingWindow, JNI_TRUE
    );
    */
    exit(-1);
}

// ============================================================================
// Task 63：guiScale 原生直读（物品栏点击修复）
//
// 现象（Air 7c4bff5 构建日志实锤）：grab 状态每次切换都打印
//   "updateMCGuiScale skipped: no JNIEnv for this thread"
// —— GetEnv 与 AttachCurrentThread 在同步线程上双双失败，Java 侧
// UIKit.updateMCGuiScale() 从未被调用，guiScale 永远卡在初始值 1。
// 后果：mcscale() 把 hotbar 命中区缩到极小，点击物品栏几乎必然落空，
// 被当作普通游戏触摸消费。
//
// 修复思路：不再依赖 JNIEnv。options.txt 就在 POJAV_GAME_DIR（= cwd
// = -Duser.dir，main.m 已 setenv）下，native 直接解析 guiScale 行，
// 复刻 Java 侧 UIKit.updateMCGuiScale() 的完整算法：
//   raw = options.txt 的 guiScale（0/缺省 = auto）
//   auto = max(min(mGLFWWindowWidth/320, mGLFWWindowHeight/240), 1)
//   scale = (raw == 0 || auto < raw) ? auto : raw
// 其中 mGLFWWindow* 与 native 全局 windowWidth/windowHeight 同源
// （launchJVM 告知的启动器像素口径）。
//
// 刷新时机：grab 状态每次切换（进游戏/开菜单/关菜单）。用户在 MC
// 设置里改 GUI 大小必然经过"开菜单(grab off) → 改 → 关菜单(grab on)"，
// 下一次切换即拿到新值。文件只在切换沿读取，开销可忽略。
// ============================================================================
static int readGuiScaleFromOptions(void) {
    const char *gameDir = getenv("POJAV_GAME_DIR");
    if (gameDir == NULL) return 0;
    char path[PATH_MAX];
    if (snprintf(path, sizeof(path), "%s/options.txt", gameDir) >= (int)sizeof(path)) return 0;
    FILE *f = fopen(path, "r");
    if (f == NULL) return 0;
    int value = 0;
    char line[256];
    while (fgets(line, sizeof(line), f) != NULL) {
        if (strncmp(line, "guiScale:", 9) == 0) {
            value = atoi(line + 9);
            break;
        }
    }
    fclose(f);
    return value;   // 0 = 未找到行（视为 auto）
}

static void refreshGuiScaleNatively(void) {
    int raw = readGuiScaleFromOptions();
    if (windowWidth <= 0 || windowHeight <= 0) return;   // 启动早期兜底
    int autoScale = MAX(MIN(windowWidth / 320, windowHeight / 240), 1);
    int newScale = (raw == 0 || autoScale < raw) ? autoScale : raw;
    if (newScale != guiScale) {
        NSLog(@"[HotbarDiag] Task63 native guiScale refresh: %d -> %d (raw=%d auto=%d win=%dx%d)",
              guiScale, newScale, raw, autoScale, windowWidth, windowHeight);
        guiScale = newScale;
    }
}

// ============================================================================
// 运行期 JavaVM 解析回退
//
// 26.3 + SDL3 路径下本库由 dyld 直接加载（非 System.loadLibrary），JNI_OnLoad
// 不执行，runtimeJavaVMPtr 保持 NULL，于是所有需要主动回调 Java 的逻辑都被跳过。
// 日志证据：26.3 侧没有 "[JNI] JNI_OnLoadGLFW registered"，且反复出现
//   "[InputDiag] updateMCGuiScale skipped: no JNIEnv for this thread"
//
// JNI Invocation API 的 JNI_GetCreatedJavaVMs 可在任意时刻枚举进程内已创建的
// JVM，不依赖 JNI_OnLoad；此处作为回退取得运行期 VM。
// ============================================================================
typedef jint (*ame_JNI_GetCreatedJavaVMs_t)(JavaVM **, jsize, jsize *);

static JavaVM *ame_resolveRuntimeVM(void) {
    if (runtimeJavaVMPtr != NULL) return runtimeJavaVMPtr;

    static ame_JNI_GetCreatedJavaVMs_t s_getCreatedVMs = NULL;
    static BOOL s_lookupDone = NO;
    if (!s_lookupDone) {
        s_lookupDone = YES;
        s_getCreatedVMs = (ame_JNI_GetCreatedJavaVMs_t)dlsym(RTLD_DEFAULT, "JNI_GetCreatedJavaVMs");
        if (s_getCreatedVMs == NULL) {
            NSLog(@"[InputDiag] JNI_GetCreatedJavaVMs not available (runtime VM unreachable)");
        }
    }
    if (s_getCreatedVMs == NULL) return NULL;

    JavaVM *vms[4];
    jsize nVMs = 0;
    if (s_getCreatedVMs(vms, 4, &nVMs) != JNI_OK || nVMs <= 0 || vms[0] == NULL) return NULL;

    runtimeJavaVMPtr = vms[0];
    NSLog(@"[InputDiag] runtime JavaVM resolved via JNI_GetCreatedJavaVMs: %p", (void *)runtimeJavaVMPtr);
    return runtimeJavaVMPtr;
}

// ============================================================================
// guiScale 本地推导（MC auto 档规则）
//
// guiScale 目前只能由 Java 侧经 JNI 回推（见 updateMCGuiScale）。在 26.3+SDL3
// 下该 JNI 链路尚未跑通时，guiScale 会停在初始值 1，使物品栏命中区退化到
// 180x20 像素而点不中。这里按 MC Options.calculateScale 的 auto 规则从物理
// 尺寸推导，作为兜底：
//   scale = 1; while (w/(scale+1) >= 320 && h/(scale+1) >= 240) scale++;
// 对 2436x1125 得 4，与 GLFW 路径下实测值一致。
// ============================================================================
static int ame_deriveGuiScale(void) {
    // Air Task63 同口径：以启动器告知 MC 的窗口像素（windowWidth/Height）
    // 为准，而非未缩放的物理屏。非 100% 分辨率下二者不同，用物理尺寸会把
    // 物品栏命中区放大 1/resolutionScale 倍而点不中。
    int w = (windowWidth > 0) ? (int)windowWidth : (int)physicalWidth;
    int h = (windowHeight > 0) ? (int)windowHeight : (int)physicalHeight;
    if (w <= 0 || h <= 0) return 1;
    int scale = 1;
    const int maxScale = 8;
    while (scale < maxScale && (w / (scale + 1)) >= 320 && (h / (scale + 1)) >= 240) {
        scale++;
    }
    return scale;
}

const int hotbarKeys[9] = {
    GLFW_KEY_1, GLFW_KEY_2, GLFW_KEY_3,
    GLFW_KEY_4, GLFW_KEY_5, GLFW_KEY_6,
    GLFW_KEY_7, GLFW_KEY_8, GLFW_KEY_9
};
int guiScale = 1;
int mcscale(CGFloat input) {
    return (int)((guiScale * input)/resolutionScale);
}
int callback_SurfaceViewController_touchHotbar(CGFloat x, CGFloat y) {
    // 诊断：物品栏点不动时，靠这段代码一次性定位卡在哪一环。
    // 可能的失败原因互不相关，只看现象无法区分：
    //   1. isGrabbing 恒为 0 —— SDL3 下抓取状态没同步过来（最常见）
    //   2. guiScale 卡在初始值 1 —— mcscale() 把命中区域缩小到约 60x6 像素
    //   3. 传入坐标与 physicalWidth/Height 不同坐标系（rootView vs surfaceView）
    //   4. resolutionScale 异常
    // 限频：每 20 次打印一次，避免触摸时刷屏。
    static int hotbarDiagCount = 0;
    BOOL shouldLog = ((hotbarDiagCount++ % 20) == 0);

    // guiScale 兜底：JNI 回推在 26.3+SDL3 下可能一次都没成功过，
    // 此时按 MC auto 规则从物理尺寸推导，避免命中区退化成 180x20 像素。
    if (guiScale <= 1) {
        int derived = ame_deriveGuiScale();
        if (derived > 1) {
            guiScale = derived;
            if (shouldLog) {
                NSLog(@"[HotbarDiag] guiScale fallback derived=%d (JNI never updated)", derived);
            }
        }
    }

    if (isGrabbing == JNI_FALSE) {
        if (shouldLog) {
            NSLog(@"[HotbarDiag] REJECT isGrabbing=0 | x=%.1f y=%.1f | phys=%dx%d guiScale=%d resScale=%.2f sdlWin=%p",
                  x, y, (int)physicalWidth, (int)physicalHeight, guiScale,
                  (double)resolutionScale, g_sdlWindow);
        }
        return -1;
    }

    int barHeight = mcscale(20);
    int barY = physicalHeight - barHeight;
    if (y < barY) {
        if (shouldLog) {
            NSLog(@"[HotbarDiag] REJECT above bar | y=%.1f < barY=%d (barH=%d physH=%d guiScale=%d resScale=%.2f)",
                  y, barY, barHeight, (int)physicalHeight, guiScale, (double)resolutionScale);
        }
        return -1;
    }

    int barWidth = mcscale(180);
    int barX = (physicalWidth / 2) - (barWidth / 2);
    if (x < barX || x >= barX + barWidth) {
        if (shouldLog) {
            NSLog(@"[HotbarDiag] REJECT outside bar | x=%.1f not in [%d,%d) barW=%d physW=%d guiScale=%d resScale=%.2f",
                  x, barX, barX + barWidth, barWidth, (int)physicalWidth, guiScale, (double)resolutionScale);
        }
        return -1;
    }

    int slot = hotbarKeys[(int) MathUtils_map(x, barX, barX + barWidth, 0, 9)];
    if (shouldLog) {
        NSLog(@"[HotbarDiag] HIT slot key=%d | x=%.1f barX=%d barW=%d physW=%d guiScale=%d",
              slot, x, barX, barWidth, (int)physicalWidth, guiScale);
    }
    return slot;
}

JNIEXPORT void JNICALL Java_net_kdt_pojavlaunch_uikit_UIKit_updateMCGuiScale(JNIEnv* env, jclass clazz, jint scale) {
    guiScale = scale;
}

JNIEXPORT jstring JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeClipboard(JNIEnv* env, jclass clazz, jint action, jstring copySrc) {
    NSDebugLog(@"Debug: Clipboard access is going on\n");
    return UIKit_accessClipboard(env, action, copySrc);
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeSetGrabbing(JNIEnv* env, jclass clazz, jboolean grabbing, jfloat xset, jfloat yset) {
    isGrabbing = grabbing;

    // Manage SDL cursor visibility: hide when grabbing (in-game), show when not (menu)
    static SDL_HideCursor_func *pSDL_HideCursor = NULL;
    static SDL_ShowCursor_func *pSDL_ShowCursor = NULL;
    static BOOL cursorFuncsResolved = NO;
    if (!cursorFuncsResolved) {
        pSDL_HideCursor = dlsym(RTLD_DEFAULT, "SDL_HideCursor");
        pSDL_ShowCursor = dlsym(RTLD_DEFAULT, "SDL_ShowCursor");
        cursorFuncsResolved = YES;
    }
    if (pSDL_HideCursor && pSDL_ShowCursor) {
        if (grabbing) {
            pSDL_HideCursor();
            NSLog(@"[InputDiag] nativeSetGrabbing: SDL_HideCursor called");
        } else {
            pSDL_ShowCursor();
            NSLog(@"[InputDiag] nativeSetGrabbing: SDL_ShowCursor called");
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        SurfaceViewController *vc = [SurfaceViewController currentInstance];
        if (vc) {
            [vc updateGrabState];
        }
    });
}

JNIEXPORT jboolean JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeIsGrabbing(JNIEnv* env, jclass clazz) {
    return isGrabbing;
}

void CallbackBridge_nativeSetInputReady(BOOL inputReady) {
    isInputReady = inputReady;
    if (inputReady) {
        if (GLFW_invoke_FramebufferSize) {
            GLFW_invoke_FramebufferSize((void*) showingWindow, windowWidth, windowHeight);
        }
        if (GLFW_invoke_WindowSize) {
            GLFW_invoke_FramebufferSize((void*) showingWindow, windowWidth, windowHeight);
        }
    }
}

// Queue modifier synchronization from UIKit callbacks. JNI work is consumed
// by pojavPumpEvents on the game thread, where runtimeJNIEnvPtr is valid.
void CallbackBridge_queueModifierSync(int mods) {
    if (!isInputReady) return;
    sendData(EVENT_TYPE_MODIFIERS, mods, 0, 0, 0);
}

// ============================================================================
// issue #27 修复（参照 FCL commit 08c0716）：物理键盘 modifier 同步
//
// MC 1.21.9+ 不再仅依赖 key 回调中的 mods 参数，而是通过
// InputConstants.isKeyDown(window, GLFW_KEY_LEFT_SHIFT) 查询 modifier 状态。
// 该状态由 MC 内部缓存维护，仅靠 GLFW key callback 无法同步，
// 必须显式调用 Java 端 setModifiers 才能更新。
//
// 此处通过 JNI 反射调用 com.mojang.blaze3d.platform.InputConstants
// 的内部方法（如果存在），实现 modifier 缓存的显式同步。
// 旧版本 MC 没有此机制，调用会安全失败（找不到方法直接返回）。
//
// 由 KeyboardInput.m 在物理键盘事件中调用（pressesBegan/pressesEnded），
// 也可被 Java 端 CallbackBridge.nativeSetModifiers 调用。
// ============================================================================
void CallbackBridge_syncModifiersToMC(int mods) {
    if (!runtimeJavaVMPtr || !isInputReady) return;

    JNIEnv *env = NULL;
    jint envStatus = (*runtimeJavaVMPtr)->GetEnv(
        runtimeJavaVMPtr, (void **)&env, JNI_VERSION_1_4);
    if (envStatus != JNI_OK || !env) return;

    jclass inputConstantsClass = (*env)->FindClass(env, "com/mojang/blaze3d/platform/InputConstants");
    if (!inputConstantsClass) {
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        return;
    }
    jmethodID setModifiersMethod = (*env)->GetStaticMethodID(env, inputConstantsClass, "setModifiers", "(I)V");
    if (!setModifiersMethod) {
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        (*env)->DeleteLocalRef(env, inputConstantsClass);
        return;
    }
    (*env)->CallStaticVoidMethod(env, inputConstantsClass, setModifiersMethod, (jint)mods);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
    }
    (*env)->DeleteLocalRef(env, inputConstantsClass);
}

// JNI wrapper：供 Java 端 CallbackBridge.nativeSetModifiers(int) 调用
JNIEXPORT void JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeSetModifiers(JNIEnv* env, jclass clazz, jint mods) {
    CallbackBridge_syncModifiersToMC(mods);
}

BOOL CallbackBridge_nativeSendChar(jchar codepoint /* jint codepoint */) {
    if (GLFW_invoke_Char && isInputReady) {
        if (isUseStackQueueCall) {
            sendData(EVENT_TYPE_CHAR, codepoint, 0, 0, 0);
        } else {
            GLFW_invoke_Char((void*) showingWindow, (unsigned int) codepoint);
            // return lwjgl2_triggerCharEvent(codepoint);
        }
        return YES;
    }
    // Path B: SDL3 text-input events (MC 26.3+) -- Task 82
    // 虚拟键盘字符在 26.3 下的唯一通道：GLFW_invoke_Char 为 NULL 时改推
    // SDL_EVENT_TEXT_INPUT，MC 的 SDLEventHandler.handleTextInputEvent 消费。
    if (!GLFW_invoke_Char && g_sdlWindow) {
        pushSDLTextInput(codepoint);
        return YES;
    }
    return NO;
}

BOOL CallbackBridge_nativeSendCharMods(jchar codepoint, int mods) {
    if (GLFW_invoke_CharMods && isInputReady) {
        if (isUseStackQueueCall) {
            sendData(EVENT_TYPE_CHAR_MODS, (unsigned int) codepoint, mods, 0, 0);
        } else {
            GLFW_invoke_CharMods((void*) showingWindow, codepoint, mods);
        }
        return YES;
    }
    return NO;
}
/*
JNIEXPORT void JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeSendCursorEnter(JNIEnv* env, jclass clazz, jint entered) {
    if (GLFW_invoke_CursorEnter && isInputReady) {
        GLFW_invoke_CursorEnter(showingWindow, entered);
    }
}
*/

// ============================================================================
// grab 状态同步（MC 26.3 / SDL3）
//
// MC 26.3 改用 SDL3 后不再调用 glfwSetInputMode，于是 CallbackBridge_nativeSetGrabbing
// 与 pojavPumpEvents 都不会被触发，isGrabbing 只能从 SDL 侧同步。
//
// 原先只靠 CallbackBridge_nativeSendCursorPos 里的轮询，而它有两个致命缺陷：
//   1. 必须由触摸事件驱动 —— 进世界后玩家不碰屏幕就永远同步不了
//   2. 若 MC 根本不启用 SDL relative mouse mode，轮询结果恒为 false
// 实测日志中 isGrabbing 全程为 0，正是这条链路断了。
//
// isGrabbing 直接决定游戏内物品栏能否点击：
//   callback_SurfaceViewController_touchHotbar() 首行即 `if (isGrabbing == JNI_FALSE) return -1;`
// 同时 guiScale 也只有在本函数里才会刷新，而 mcscale() 用它计算物品栏命中区域；
// guiScale 卡在初始值 1 会让区域缩小到约 60x6 像素，等于点不中。
// 两者任一失效都会表现为"hotbar 点不动"，即上游 issue 里反馈的那个现象。
//
// 调用方：
//   1. main_hook.m 的 hooked_dlsym 拦截 SDL_SetWindowRelativeMouseMode（主路径）
//   2. CallbackBridge_nativeSendCursorPos 的轮询（兜底）
//
// 注意这里可能在任意线程被调用（渲染线程 / UI 主线程），因此 JNI 调用必须
// 获取本线程自己的 JNIEnv，不能复用 runtimeJNIEnvPtr。
// ============================================================================
void CallbackBridge_syncGrabStateFromSDL(BOOL relMode, const char *source) {
    static BOOL lastRelMode = NO;
    static BOOL haveLast = NO;

    if (haveLast && relMode == lastRelMode) return;
    haveLast = YES;
    lastRelMode = relMode;

    BOOL wasGrabbing = isGrabbing;
    isGrabbing = relMode;
    NSLog(@"[InputDiag] grab state -> %d (was %d, source=%s)",
          relMode, wasGrabbing, source ? source : "?");

    // 进入抓取时补发一次左键释放：菜单里那次 ACTION_DOWN 否则永远不会抬起
    if (!wasGrabbing && relMode) {
        pushSDLMouseButton(1, false, (float)cursorX, (float)cursorY);
        NSLog(@"[InputDiag] Released stale mouse button on grab enter");
    }

    // 光标显隐
    typedef bool (*VoidFunc)(void);
    static VoidFunc hideCursor = NULL;
    static VoidFunc showCursor = NULL;
    if (!hideCursor) hideCursor = (VoidFunc)dlsym(RTLD_DEFAULT, "SDL_HideCursor");
    if (!showCursor) showCursor = (VoidFunc)dlsym(RTLD_DEFAULT, "SDL_ShowCursor");
    if (relMode && hideCursor) hideCursor();
    else if (!relMode && showCursor) showCursor();

    // 刷新 guiScale（物品栏命中判定依赖它）。
    // Task 63：先做原生直读（不依赖 JNIEnv），再由下方 JNI 链（若可用）覆盖。
    refreshGuiScaleNatively();

    // MC 26.3 走 SDL 时 glfwSetInputMode 不会被调用，guiScale 不会自动更新。
    //
    // 不加 isInputReady 判断：26.3 下 pojavPumpEvents 从不执行，isInputReady 恒为 NO，
    // 加了会让这里永远跳过。
    JNIEnv *scaleEnv = NULL;
    BOOL scaleDidAttach = NO;
    JavaVM *scaleVM = ame_resolveRuntimeVM();
    if (scaleVM != NULL) {
        jint st = (*scaleVM)->GetEnv(scaleVM, (void **)&scaleEnv, JNI_VERSION_1_4);
        if (st == JNI_EDETACHED || st != JNI_OK || scaleEnv == NULL) {
            scaleEnv = NULL;
            if ((*scaleVM)->AttachCurrentThread(scaleVM, &scaleEnv, NULL) == JNI_OK && scaleEnv != NULL) {
                scaleDidAttach = YES;
            } else {
                scaleEnv = NULL;
                NSLog(@"[InputDiag] updateMCGuiScale: AttachCurrentThread failed");
            }
        }
    } else {
        NSLog(@"[InputDiag] updateMCGuiScale skipped: no runtime JavaVM");
    }
    if (scaleEnv != NULL) {
        @try {
            jclass uikitClass = (*scaleEnv)->FindClass(scaleEnv, "net/kdt/pojavlaunch/uikit/UIKit");
            if (uikitClass == NULL) {
                if ((*scaleEnv)->ExceptionCheck(scaleEnv)) (*scaleEnv)->ExceptionClear(scaleEnv);
                NSLog(@"[InputDiag] updateMCGuiScale: UIKit class not found");
            } else {
                jmethodID updateScale = (*scaleEnv)->GetStaticMethodID(scaleEnv, uikitClass, "updateMCGuiScale", "()V");
                if (updateScale == NULL) {
                    if ((*scaleEnv)->ExceptionCheck(scaleEnv)) (*scaleEnv)->ExceptionClear(scaleEnv);
                    NSLog(@"[InputDiag] updateMCGuiScale: method not found");
                } else {
                    (*scaleEnv)->CallStaticVoidMethod(scaleEnv, uikitClass, updateScale);
                    if ((*scaleEnv)->ExceptionCheck(scaleEnv)) {
                        (*scaleEnv)->ExceptionDescribe(scaleEnv);
                        (*scaleEnv)->ExceptionClear(scaleEnv);
                    } else {
                        NSLog(@"[InputDiag] updateMCGuiScale called, guiScale=%d", guiScale);
                    }
                }
                (*scaleEnv)->DeleteLocalRef(scaleEnv, uikitClass);
            }
        } @catch (NSException *e) {
            NSLog(@"[InputDiag] updateMCGuiScale exception: %@", e);
        }
        if (scaleDidAttach) {
            (*scaleVM)->DetachCurrentThread(scaleVM);
        }
    } else {
        NSLog(@"[InputDiag] updateMCGuiScale skipped: no JNIEnv for this thread");
    }

    // UI 侧（虚拟鼠标指针等）切回主线程刷新
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            SurfaceViewController *vc = (SurfaceViewController *)UIWindow.mainWindow.rootViewController;
            if (vc) {
                [vc updateGrabState];
            } else {
                NSLog(@"[InputDiag] updateGrabState: UIWindow.mainWindow is nil");
            }
        } @catch (NSException *e) {
            NSLog(@"[InputDiag] updateGrabState exception: %@", e);
        }
    });
}

void CallbackBridge_nativeSendCursorPos(char event, CGFloat x, CGFloat y) {
    static int cursorSendCount = 0;
    cursorSendCount++;
    if (cursorSendCount <= 10 || cursorSendCount % 50 == 0) {
        NSLog(@"[InputDiag] sendCursorPos #%d: event=%d x=%.1f y=%.1f GLFW_invoke_CursorPos=%p isInputReady=%d g_sdlWindow=%p isGrabbing=%d",
            cursorSendCount, event, x, y,
            (void*)GLFW_invoke_CursorPos, isInputReady, g_sdlWindow, isGrabbing);
    }

    // Sync isGrabbing from SDL's relative mouse mode (MC 26.3 uses SDL, not GLFW).
    //
    // 主同步路径已移到 main_hook.m —— 那里通过 hooked_dlsym 拦截 MC 对
    // SDL_SetWindowRelativeMouseMode 的调用，MC 一切换立即同步，不要求玩家先触摸。
    // 这里保留轮询仅作兜底（例如 MC 改用其它 API 设置该状态时）。
    if (g_sdlWindow) {
        typedef bool (*GetRelModeFunc)(void*);
        static GetRelModeFunc getRelMode = NULL;
        static bool cursorFuncsInited = NO;
        if (!cursorFuncsInited) {
            getRelMode = (GetRelModeFunc)dlsym(RTLD_DEFAULT, "SDL_GetWindowRelativeMouseMode");
            cursorFuncsInited = YES;
            NSLog(@"[InputDiag] SDL_GetWindowRelativeMouseMode resolved: %p", (void *)getRelMode);
        }
        if (getRelMode) {
            CallbackBridge_syncGrabStateFromSDL(getRelMode(g_sdlWindow), "poll");
        }
    }

    // Update cursor position tracking regardless
    switch (event) {
        case ACTION_DOWN:
        case ACTION_UP:
            if (!isGrabbing) {
                cursorX = x;
                cursorY = y;
            }
            break;

        case ACTION_MOVE:
            if (isGrabbing) {
                cursorX += x - cLastX;
                cursorY += y - cLastY;
            } else {
                cursorX = x;
                cursorY = y;
            }
            break;

        case ACTION_MOVE_MOTION:
            cursorX += x;
            cursorY += y;
            break;
    }

    // Path A: GLFW callbacks (older MC versions)
    if (GLFW_invoke_CursorPos && isInputReady) {
        if (!isUseStackQueueCall) {
            GLFW_invoke_CursorPos((void*) showingWindow, (double) cursorX, (double) cursorY);
        }
    }

    // Path B: SDL3 events (MC 26.3+)
    // When GLFW callbacks are NULL, we inject SDL mouse events directly.
    //
    // The raw touch path NEVER sends mouse buttons.
    // All clicks are handled by the gesture system:
    //   - surfaceOnClick (tap)     → SDL right-click (place) or left-click (menu)
    //   - surfaceOnLongpress (hold) → SDL left-click (break)
    //   - touchesMoved (drag)      → ACTION_MOVE_MOTION → camera rotation
    //
    // If we also sent buttons here, every tap would double-click
    // (once from raw touch, once from gesture).
    if (!GLFW_invoke_CursorPos && g_sdlWindow) {
        if (event == ACTION_MOVE_MOTION) {
            pushSDLMouseMotion((float)cursorX, (float)cursorY, (float)x, (float)y);
        } else {
            // Menu or in-game: always send cursor position (absolute or delta)
            pushSDLMouseMotion((float)cursorX, (float)cursorY, 0, 0);
        }
    }
}

char getKeyModifiers(int key, int action) {
    static char currMods;
    char mod;
    switch (key) {
        case GLFW_KEY_LEFT_SHIFT:
        case GLFW_KEY_RIGHT_SHIFT:
            mod = GLFW_MOD_SHIFT;
            break;
        case GLFW_KEY_LEFT_CONTROL:
        case GLFW_KEY_RIGHT_CONTROL:
            mod = GLFW_MOD_CONTROL;
            break;
        case GLFW_KEY_LEFT_ALT:
        case GLFW_KEY_RIGHT_ALT:
            mod = GLFW_MOD_ALT;
            break;
        case GLFW_KEY_LEFT_SUPER:
        case GLFW_KEY_RIGHT_SUPER:
            mod = GLFW_MOD_SUPER;
            break;
        case GLFW_KEY_CAPS_LOCK:
            mod = GLFW_MOD_CAPS_LOCK;
            break;
        case GLFW_KEY_NUM_LOCK:
            mod = GLFW_MOD_NUM_LOCK;
            break;
        default:
            return currMods;
    }
    if (action) {
        currMods |= mod;
    } else {
        currMods &= ~mod;
    }
    return currMods;
}

void CallbackBridge_nativeSendKey(int key, int scancode, int action, int mods) {
    static int keySendCount = 0;
    keySendCount++;
    if (keySendCount <= 10 || keySendCount % 50 == 0) {
        NSLog(@"[InputDiag] sendKey #%d: key=%d scancode=%d action=%d mods=%d GLFW_invoke_Key=%p isInputReady=%d g_sdlWindow=%p",
            keySendCount, key, scancode, action, mods,
            (void*)GLFW_invoke_Key, isInputReady, g_sdlWindow);
    }

    // Path A: GLFW callbacks (older MC versions)
    if (GLFW_invoke_Key && isInputReady) {
        keyDownBuffer[MAX(0, key-31)]=(jbyte)action;
        if (mods == 0) {
            mods = getKeyModifiers(key, action);
        }

        if (isUseStackQueueCall) {
            sendData(EVENT_TYPE_KEY, key, scancode, action, mods);
        } else {
            GLFW_invoke_Key((void*) showingWindow, key, scancode, action, mods);
        }
    }

    // Path B: SDL3 events (MC 26.3+)
    if (!GLFW_invoke_Key && g_sdlWindow) {
        int sdlScancode = glfwKeyToSDLScancode(key);
        if (sdlScancode != 0) {
            pushSDLKeyboardEvent(sdlScancode, action != 0);
        }
    }

    // On macOS, Minecraft expects the Command key
    if (key == GLFW_KEY_LEFT_CONTROL) {
        CallbackBridge_nativeSendKey(GLFW_KEY_LEFT_SUPER, 0, action, mods);
    } else if (key == GLFW_KEY_RIGHT_CONTROL) {
        CallbackBridge_nativeSendKey(GLFW_KEY_RIGHT_SUPER, 0, action, mods);
    }
}

void CallbackBridge_nativeSendMouseButton(int button, int action, int mods) {
    // Path A: GLFW callbacks (older MC versions)
    if (isInputReady) {
        if (button == -1) {
        } else if (GLFW_invoke_MouseButton) {
            if (mods == 0) {
                mods = getKeyModifiers(0, action);
            }

            if (isUseStackQueueCall) {
                sendData(EVENT_TYPE_MOUSE_BUTTON, button, action, mods, 0);
            } else {
                GLFW_invoke_MouseButton((void*) showingWindow, button, action, mods);
            }
        }
    }

    // Path B: SDL3 events (MC 26.3+)
    if (!GLFW_invoke_MouseButton && g_sdlWindow && button >= 0) {
        pushSDLMouseButton(glfwButtonToSDLButton(button), action != 0, (float)cursorX, (float)cursorY);
    }
}

void CallbackBridge_nativeSendScreenSize(int width, int height) {
    windowWidth = width;
    windowHeight = height;
    
    if (isInputReady) {
        if (GLFW_invoke_FramebufferSize) {
            if (isUseStackQueueCall) {
                sendData(EVENT_TYPE_FRAMEBUFFER_SIZE, width, height, 0, 0);
            } else {
                GLFW_invoke_FramebufferSize((void*) showingWindow, width, height);
            }
        }
        if (GLFW_invoke_WindowSize) {
            if (isUseStackQueueCall) {
                sendData(EVENT_TYPE_WINDOW_SIZE, width, height, 0, 0);
            } else {
                GLFW_invoke_WindowSize((void*) showingWindow, width, height);
            }
        }
    }
    
    // return (isInputReady && (GLFW_invoke_FramebufferSize || GLFW_invoke_WindowSize));
}

void CallbackBridge_nativeSendScroll(CGFloat xoffset, CGFloat yoffset) {
    // Path A: GLFW callbacks
    if (GLFW_invoke_Scroll && isInputReady) {
        if (isUseStackQueueCall) {
            sendDataFloat(EVENT_TYPE_SCROLL, xoffset, yoffset, 0, 0);
        } else {
            GLFW_invoke_Scroll((void*) showingWindow, (double) xoffset, (double) yoffset);
        }
    }

    // Path B: SDL3 events (MC 26.3+)
    if (!GLFW_invoke_Scroll && g_sdlWindow) {
        pushSDLMouseWheel((float)xoffset, (float)yoffset);
    }
}
JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSetShowingWindow(JNIEnv* env, jclass clazz, jlong window) {
    showingWindow = (long) window;
}

void CallbackBridge_pauseGameIfNeed() {
    if (isGrabbing) {
        CallbackBridge_nativeSendKey(GLFW_KEY_ESCAPE, 0, 1, 0);
        CallbackBridge_nativeSendKey(GLFW_KEY_ESCAPE, 0, 0, 0);
    }
}

// JNI bridge: MC 26.1/26.2 use LWJGL 3.4.1 Java bindings which declare
// native method "nsetupEnvData" (with "n" prefix), but the prebuilt
// liblwjgl.dylib built from 3.4.1 sources exports "setupEnvData"
// (without "n" prefix) — 3.4.1 dropped the "n" on the C side only.
// This function bridges the name mismatch by forwarding to the real
// implementation.
JNIEXPORT jlong JNICALL Java_org_lwjgl_system_ThreadLocalUtil_nsetupEnvData(
    JNIEnv *env, jclass clazz, jint functionCount) {
    typedef jlong (*SetupEnvDataFunc)(JNIEnv*, jclass, jint);
    static SetupEnvDataFunc realFunc = NULL;
    static bool resolved = false;
    if (!resolved) {
        realFunc = (SetupEnvDataFunc)dlsym(RTLD_DEFAULT,
            "Java_org_lwjgl_system_ThreadLocalUtil_setupEnvData");
        resolved = true;
        if (!realFunc) {
            NSLog(@"[LWJGL Bridge] nsetupEnvData: setupEnvData not found in loaded libraries!");
        }
    }
    if (realFunc) {
        return realFunc(env, clazz, functionCount);
    }
    NSLog(@"[LWJGL Bridge] nsetupEnvData: FATAL - no implementation found");
    return 0;
}
