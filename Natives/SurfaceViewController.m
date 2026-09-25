#import <AVFoundation/AVFoundation.h>
#import <GameController/GameController.h>
#import <objc/runtime.h>
#import "authenticator/BaseAuthenticator.h"
#import "customcontrols/ControlButton.h"
#import "customcontrols/ControlDrawer.h"
#import "customcontrols/ControlSubButton.h"
#import "customcontrols/CustomControlsUtils.h"

#import "input/ControllerInput.h"
#import "input/GyroInput.h"
#import "input/KeyboardInput.h"

#import "JavaLauncher.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceUtils.h"
#import "PLProfiles.h"
#import "SurfaceViewController.h"
#import "utils.h"
#import "GameMenuOverlayView.h"
#import "TrackedTextField.h"
#import "TouchControllerBridge.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"
#import "LanPortDetector.h"
#import "BackgroundManager.h"

// 由 Natives/ctxbridges/gl_bridge.m 提供：SDL3（MC 26.3+）路径下 GL 拥有呈现层
// 且 MC 以「点」回报窗口尺寸，需要把 CAMetalLayer 对齐 1x。GLFW 与 Vulkan 路径恒 NO。
extern BOOL Amethyst_SDL3SurfaceWantsPoints(void);
// gl_bridge.m（Task 53/55）：GL 是否拥有呈现层 / 当前是否处于几何失配未治愈期。
extern bool ame_gl_surface_owns_layer(void);
extern bool ame_gl_surface_transposed(void);
// ZeroTier/Terracotta 联机暂时移除（排查启动崩溃）
// #import "MultiplayerManager.h"

#include "glfw_keycodes.h"
#include "utils.h"

#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/task_info.h>

// --- [START] TouchController Mod Support ---
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>

#define TC_MOD_PORT 12450

@interface TouchSender : NSObject {
    int _sock;
    struct sockaddr_in6 _target;
}
- (void)sendType:(int32_t)type id:(int32_t)fingerId x:(float)x y:(float)y;
@end

@implementation TouchSender

- (instancetype)init {
    self = [super init];
    if (self) {
        _sock = socket(AF_INET6, SOCK_DGRAM, 0);
        if (_sock < 0) {
            NSLog(@"[TouchController] Error: Failed to create socket");
        } else {
            // Increase send buffer size to reduce packet loss
            int sendBufSize = 256 * 1024; // 256KB
            if (setsockopt(_sock, SOL_SOCKET, SO_SNDBUF, &sendBufSize, sizeof(sendBufSize)) < 0) {
                NSLog(@"[TouchController] Warning: Failed to set send buffer size: %s", strerror(errno));
            }

            // Non-blocking mode
            int flags = fcntl(_sock, F_GETFL, 0);
            fcntl(_sock, F_SETFL, flags | O_NONBLOCK);

            memset(&_target, 0, sizeof(_target));
            _target.sin6_family = AF_INET6;
            _target.sin6_port = htons(TC_MOD_PORT);
            // Connect to localhost IPv6 ::1
            if (inet_pton(AF_INET6, "::1", &_target.sin6_addr) <= 0) {
                NSLog(@"[TouchController] Error: Invalid IPv6 address");
            } else {
                NSLog(@"[TouchController] Sender ready on port %d", TC_MOD_PORT);
            }
        }
    }
    return self;
}

- (void)dealloc {
    if (_sock >= 0) close(_sock);
}

- (void)sendType:(int32_t)type id:(int32_t)fingerId x:(float)x y:(float)y {
    if (_sock < 0) return;

    struct {
        int32_t type;
        int32_t id;
        int32_t x;
        int32_t y;
    } packet;

    packet.type = htonl(type);
    packet.id = htonl(fingerId);

    // Float to Int bits (Big Endian)
    union { float f; int32_t i; } ux, uy;
    ux.f = x;
    uy.f = y;
    packet.x = htonl(ux.i);
    packet.y = htonl(uy.i);

    
    size_t length = (type == 2) ? 8 : 16;

    // ä¼åéè¯æºå¶ï¼åå°éè¯æ¬¡æ°ï¼é¿åä¸å¿è¦çå»¶è¿
    int maxRetries = (type == 2) ? 2 : 1;
    int retry;
    ssize_t sent = -1;

    for (retry = 0; retry < maxRetries; retry++) {
        sent = sendto(_sock, &packet, length, 0, (struct sockaddr *)&_target, sizeof(_target));
        if (sent == length) {
            // åéæå
            break;
        } else if (sent < 0) {
            int err = errno;
            if (err == EAGAIN || err == EWOULDBLOCK) {
                // ç¼å²åºæ»¡ï¼ç­æä¼ç åéè¯
                usleep(500); // åå°ä¼ç æ¶é´å°0.5æ¯«ç§
                continue;
            } else {
                // å¶ä»éè¯¯ï¼è®°å½å¹¶éåºéè¯
                NSLog(@"[TouchController] Error: sendto failed: %s (type=%d, id=%d)", strerror(err), type, fingerId);
                break;
            }
        } else {
            // é¨ååéï¼çè®ºä¸ä¸ä¼åçï¼ï¼è®°å½å¹¶éè¯
            NSLog(@"[TouchController] Warning: partial send: %zd of %zu bytes", sent, length);
            usleep(500); // åå°ä¼ç æ¶é´å°0.5æ¯«ç§
        }
    }

    if (sent != length) {
        NSLog(@"[TouchController] Error: failed to send packet after %d retries (type=%d, id=%d)", maxRetries, type, fingerId);
    }
}
@end

#pragma mark - PLDisplayLinkTarget
// CADisplayLink 回调 target 类
//
// 关键修复（Vulkan FPS 显示无效）：
// 之前使用 [CADisplayLink displayLinkWithTarget:block selector:@selector(invoke)]
// 传递 block，但 block 的 invoke 方法签名 -(void)invoke 与 CADisplayLink 期望的
// -(void)selector:(CADisplayLink*)link 签名不匹配，导致回调不触发。
// 此类提供正确签名的 displayLinkTick: 方法，确保 CADisplayLink 回调正确触发。
@interface PLDisplayLinkTarget : NSObject
@property(nonatomic, assign) BOOL isVulkanMode;  // 配置预期 Vulkan 路径（仅诊断日志用，实际决策由 pojavIsActualVulkanPath() 运行时判定）
@property(nonatomic, assign) NSUInteger tickCount;  // 诊断用：累计 tick 次数
@end

@implementation PLDisplayLinkTarget

- (instancetype)initWithVulkanMode:(BOOL)isVulkanMode {
    self = [super init];
    if (self) {
        _isVulkanMode = isVulkanMode;
        _tickCount = 0;
    }
    return self;
}

// CADisplayLink 回调方法（正确签名：带 CADisplayLink* 参数）
//
// 关键修复（Vulkan/MoltenVK+OpenGL FPS 显示错误）：
// 之前用 viewDidLoad 时的静态字符串推断（isVulkanMode）决定是否递增 FPS 计数器，
// 但 graphicsApi=default 由 MC 内部决定，无法预判；且 MC 实际选择可能与配置不符。
// 现在每帧动态查询 pojavIsActualVulkanPath()（读 clientAPI == GLFW_NO_API），
// 与 MC 真实渲染路径一致，避免：
//   - 双重计数：Vulkan 渲染器但 MC 选 GL 路径，pojavSwapBuffers + displayLink 都计数
//   - 漏计数：graphicsApi=prefer_opengl 但 MC 走 Vulkan，displayLink 未启用 fallback
- (void)displayLinkTick:(CADisplayLink *)link {
    [GyroInput tick];
    [ControllerInput tick];
    // 动态判定：仅当 MC 真实走 Vulkan 路径时才递增 FPS 计数器
    BOOL actualVulkanPath = pojavIsActualVulkanPath();
    if (actualVulkanPath) {
        pojavIncrementFpsCounter();
    }
    _tickCount++;
    // 诊断日志：前 5 次回调 + 状态切换时输出，便于追踪 clientAPI 变化
    static BOOL s_lastActualVulkanPath = NO;
    BOOL stateChanged = (s_lastActualVulkanPath != actualVulkanPath);
    if (_tickCount <= 5 || stateChanged) {
        NSLog(@"[PLDisplayLinkTarget] displayLinkTick #%lu (configuredVulkan=%d, actualVulkanPath=%d, stateChanged=%d)",
              (unsigned long)_tickCount, _isVulkanMode, actualVulkanPath, stateChanged);
        s_lastActualVulkanPath = actualVulkanPath;
    }
}

@end

// --- [START] TouchController Static Library Support ---
// ProxyMessage ç±»åå®ä¹ (åè TouchController-iOSTest)
#define PROXY_MESSAGE_TYPE_ADD_POINTER 1
#define PROXY_MESSAGE_TYPE_REMOVE_POINTER 2
#define PROXY_MESSAGE_TYPE_VIBRATE 4
#define PROXY_MESSAGE_TYPE_INPUT_STATUS 7
#define PROXY_MESSAGE_TYPE_INPUT_CURSOR 9
#define PROXY_MESSAGE_TYPE_INPUT_AREA 11
#define PROXY_MESSAGE_TYPE_MOVE_VIEW 12
#define PROXY_MESSAGE_TYPE_CAPABILITY 5
#define PROXY_MESSAGE_TYPE_KEYBOARD_SHOW 8
#define PROXY_MESSAGE_TYPE_INITIALIZE 10

// Vibrate ç±»å
#define VIBRATE_KIND_BLOCK_BROKEN 0

// --- [END] TouchController Static Library Support ---

int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);
#define MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT        6

static int currentHotbarSlot = -1;
static GameSurfaceView* pojavWindow;

@interface SurfaceViewController ()<UITextFieldDelegate, UIGestureRecognizerDelegate> {
}

// FPS/内存监控相关（FPS 在 native pojavSwapBuffers 中计数，参照 FCL/ZL2）
@property(nonatomic) NSTimer *statsTimer;                 // 低频定时器，1s 一次
@property(nonatomic) CADisplayLink *statsDisplayLink;     // 渲染循环引用（用于 Gyro/Controller tick 和失效）
@property(nonatomic, strong) id statsDisplayLinkTarget;   // CADisplayLink 的 target（强引用防释放）

@property(nonatomic) NSDictionary* metadata;
@property(nonatomic) TrackedTextField *inputTextField;
@property(nonatomic) NSMutableArray* swipeableButtons;
@property(nonatomic) ControlButton* swipingButton;
@property(nonatomic) UITouch *primaryTouch, *hotbarTouch;

@property(nonatomic) UILongPressGestureRecognizer* longPressGesture, *longPressTwoGesture;
@property(nonatomic) UITapGestureRecognizer *tapGesture, *doubleTapGesture;
// TouchController 移动视角手势：右半区单指滑动
@property(nonatomic) UIPanGestureRecognizer *moveViewPanGesture;

@property(nonatomic) id mouseConnectCallback, mouseDisconnectCallback;
@property(nonatomic) id controllerConnectCallback, controllerDisconnectCallback;
// 关键修复（UI 累积异常）：MousePointerUpdated 块观察者之前未存储，
// 无法在 dealloc 中移除，导致每次进出游戏都泄漏一个观察者 + 对 self 的强引用。
// 现存为属性，dealloc 中统一移除。
@property(nonatomic) id mousePointerUpdatedCallback;

@property(nonatomic) CGFloat screenScale;
@property(nonatomic) CGFloat mouseSpeed;
@property(nonatomic) CGRect clickRange;
@property(nonatomic) BOOL isMacCatalystApp, shouldHideControlsFromRecording,
    shouldTriggerClick, shouldTriggerHaptic, slideableHotbar, toggleHidden;

@property(nonatomic) BOOL enableMouseGestures, enableHotbarGestures;

@property(nonatomic) UIImpactFeedbackGenerator *lightHaptic;
@property(nonatomic) UIImpactFeedbackGenerator *mediumHaptic;

@property(nonatomic, strong) TouchSender *touchSender;
@property(nonatomic) long long touchControllerTransportHandle;

// TouchController Text Input Support
@property(nonatomic, strong) UITextField *touchControllerTextField;
@property(nonatomic) BOOL touchControllerTextInputEnabled;

// 阶段13/16：启动遮罩层（参照 FCL/ZL2 的启动进度显示，JVM 启动到首帧渲染期间显示）
//
// 重要设计说明（参照 FCL/ZL2）：
//   launchOverlayView 的 userInteractionEnabled 必须为 NO，使其不拦截触摸事件。
//   这样视图层级下方的 gameMenuOverlay（悬浮球 + FPS 显示）在启动期间仍可
//   被用户拖动和点击。这是 FCL/ZL2 的做法——启动遮罩层是纯视觉层，不参与
//   交互。所有子控件（图标、进度条、文字）均为展示型，不需要接收触摸。
//
//   视图层级（从下到上）：
//     rootView (游戏渲染表面)
//       → menuView (底部弹出菜单)
//         → menuDimView (菜单背景遮罩)
//           → gameMenuOverlay (悬浮球 + FPS 显示) ← 需要可交互
//             → launchOverlayView (启动遮罩层) ← userInteractionEnabled = NO
//
//   触摸事件流程：
//     1. 用户触摸屏幕 → UIKit 从最顶层 view 开始 hitTest
//     2. launchOverlayView.userInteractionEnabled = NO → hitTest 返回 nil
//     3. 触摸穿透到 gameMenuOverlay
//     4. gameMenuOverlay.hitTest 检查是否命中 menuButton/statsLabel
//        - 命中 → 返回对应控件，用户可拖动/点击
//        - 未命中 → 返回 nil，触摸继续穿透到游戏画面
@property(nonatomic, strong) UIView *launchOverlayView;
@property(nonatomic, strong) CAGradientLayer *launchGradientLayer;
@property(nonatomic, strong) UIActivityIndicatorView *launchSpinner;
@property(nonatomic, strong) UILabel *launchTitleLabel;
@property(nonatomic, assign) NSTimeInterval launchStartTime;
@property(nonatomic, assign) BOOL launchOverlayDismissed;
@property(nonatomic, strong) UIButton *launchCancelButton;     // 取消启动按钮

@end

// Forward declaration: findSDL_uikitview is defined further down this file
// (after the @implementation block, near touchesBegan). Declaring it here
// avoids an implicit-declaration warning when pressesBegan/pressesEnded
// forward physical keyboard events to the embedded SDL_uikitview.
static UIView *findSDL_uikitview(UIView *root);

@implementation SurfaceViewController

#pragma mark - TouchController Static Library Support

// å¯å¨ TouchController æ¶æ¯æ¥æ¶å¾ªç¯
- (void)startTouchControllerMessageLoop {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (weakSelf.touchControllerTransportHandle >= 0 && ![weakSelf isViewDismissed]) {
            @autoreleasepool {
                NSMutableData *buffer = [NSMutableData dataWithLength:256];
                int result = [TouchControllerBridge receiveFromTransport:weakSelf.touchControllerTransportHandle buffer:buffer];

                if (result > 0) {
                    [buffer setLength:result];
                    [weakSelf processTouchControllerMessage:buffer];
                }

                // ä¼ç  16ms
                usleep(16000);
            }
        }
    });
}

// æ£æ¥è§å¾æ¯å¦å·²å³é­
- (BOOL)isViewDismissed {
    return !self.view.window || self.isBeingDismissed;
}

// ç¼ç  ProxyMessage: AddPointerMessage (type=1, index=int32, x=float, y=float)
- (NSData *)encodeAddPointerMessage:(int32_t)index x:(float)x y:(float)y {
    NSMutableData *data = [NSMutableData dataWithCapacity:16];
    int32_t type = htonl(PROXY_MESSAGE_TYPE_ADD_POINTER);
    int32_t indexBE = htonl(index);

    // å° float è½¬æ¢ä¸ºç½ç»å­èåº
    union { float f; uint32_t i; } ux, uy;
    ux.f = x;
    uy.f = y;
    uint32_t xBE = htonl(ux.i);
    uint32_t yBE = htonl(uy.i);

    [data appendBytes:&type length:4];
    [data appendBytes:&indexBE length:4];
    [data appendBytes:&xBE length:4];
    [data appendBytes:&yBE length:4];

    return data;
}

// ç¼ç  ProxyMessage: RemovePointerMessage (type=2, index=int32)
- (NSData *)encodeRemovePointerMessage:(int32_t)index {
    NSMutableData *data = [NSMutableData dataWithCapacity:8];
    int32_t type = htonl(PROXY_MESSAGE_TYPE_REMOVE_POINTER);
    int32_t indexBE = htonl(index);

    [data appendBytes:&type length:4];
    [data appendBytes:&indexBE length:4];

    return data;
}

// åé ProxyMessage å° TouchController éæåº
- (void)sendTouchControllerProxyMessage:(int32_t)index x:(float)x y:(float)y isRemove:(BOOL)isRemove {
    NSData *messageData;

    if (isRemove) {
        messageData = [self encodeRemovePointerMessage:index];
    } else {
        messageData = [self encodeAddPointerMessage:index x:x y:y];
    }

    if (self.touchControllerTransportHandle >= 0 && messageData) {
        [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:messageData];
    }
}

#pragma mark - TouchController Text Input Support

// ç¼ç  InputStatusMessage (type=7)
- (NSData *)encodeInputStatusMessageWithText:(NSString *)text
                              compositionStart:(int)compositionStart
                              compositionLength:(int)compositionLength
                              selectionStart:(int)selectionStart
                              selectionLength:(int)selectionLength
                              selectionLeft:(BOOL)selectionLeft {
    if (!text) {
        // æ æ°æ®ï¼åªåé type + 0
        int32_t type = htonl(7);
        NSMutableData *data = [NSMutableData dataWithCapacity:1];
        [data appendBytes:&type length:4];
        uint8_t hasData = 0;
        [data appendBytes:&hasData length:1];
        return data;
    }

    // å° UTF-16 è½¬æ¢ä¸º UTF-8
    NSData *textData = [text dataUsingEncoding:NSUTF8StringEncoding];
    const char *textBytes = (const char *)[textData bytes];
    int textLength = (int)[textData length];

    // è®¡ç® UTF-8 ä½ç½®
    NSString *prefix = [text substringToIndex:compositionStart];
    NSData *prefixData = [prefix dataUsingEncoding:NSUTF8StringEncoding];
    int compositionStartUtf8 = (int)[prefixData length];

    NSString *compSegment = [text substringWithRange:NSMakeRange(compositionStart, compositionLength)];
    NSData *compData = [compSegment dataUsingEncoding:NSUTF8StringEncoding];
    int compositionLengthUtf8 = (int)[compData length];

    NSString *selPrefix = [text substringToIndex:selectionStart];
    NSData *selPrefixData = [selPrefix dataUsingEncoding:NSUTF8StringEncoding];
    int selectionStartUtf8 = (int)[selPrefixData length];

    NSString *selSegment = [text substringWithRange:NSMakeRange(selectionStart, selectionLength)];
    NSData *selData = [selSegment dataUsingEncoding:NSUTF8StringEncoding];
    int selectionLengthUtf8 = (int)[selData length];

    // ç¼ç æ¶æ¯
    NSMutableData *data = [NSMutableData dataWithCapacity:5 + textLength + 17];
    int32_t type = htonl(7);
    [data appendBytes:&type length:4];

    uint8_t hasDataFlag = 1;
    [data appendBytes:&hasDataFlag length:1];

    int32_t textLengthBE = htonl(textLength);
    [data appendBytes:&textLengthBE length:4];
    [data appendBytes:textBytes length:textLength];

    int32_t compStartBE = htonl(compositionStartUtf8);
    int32_t compLenBE = htonl(compositionLengthUtf8);
    [data appendBytes:&compStartBE length:4];
    [data appendBytes:&compLenBE length:4];

    int32_t selStartBE = htonl(selectionStartUtf8);
    int32_t selLenBE = htonl(selectionLengthUtf8);
    [data appendBytes:&selStartBE length:4];
    [data appendBytes:&selLenBE length:4];

    uint8_t selectionLeftFlag = selectionLeft ? 1 : 0;
    [data appendBytes:&selectionLeftFlag length:1];

    return data;
}

// ç¼ç  InputCursorMessage (type=9)
- (NSData *)encodeInputCursorMessageWithRect:(CGRect)rect {
    NSMutableData *data = [NSMutableData dataWithCapacity:17];
    int32_t type = htonl(9);
    [data appendBytes:&type length:4];

    uint8_t hasData = 1;
    [data appendBytes:&hasData length:1];

    union { float f; uint32_t i; } left, top, width, height;
    left.f = rect.origin.x;
    top.f = rect.origin.y;
    width.f = rect.size.width;
    height.f = rect.size.height;

    uint32_t leftBE = htonl(left.i);
    uint32_t topBE = htonl(top.i);
    uint32_t widthBE = htonl(width.i);
    uint32_t heightBE = htonl(height.i);

    [data appendBytes:&leftBE length:4];
    [data appendBytes:&topBE length:4];
    [data appendBytes:&widthBE length:4];
    [data appendBytes:&heightBE length:4];

    return data;
}

// ç¼ç  InputAreaMessage (type=11)
- (NSData *)encodeInputAreaMessageWithRect:(CGRect)rect {
    NSMutableData *data = [NSMutableData dataWithCapacity:17];
    int32_t type = htonl(11);
    [data appendBytes:&type length:4];

    uint8_t hasData = 1;
    [data appendBytes:&hasData length:1];

    union { float f; uint32_t i; } left, top, width, height;
    left.f = rect.origin.x;
    top.f = rect.origin.y;
    width.f = rect.size.width;
    height.f = rect.size.height;

    uint32_t leftBE = htonl(left.i);
    uint32_t topBE = htonl(top.i);
    uint32_t widthBE = htonl(width.i);
    uint32_t heightBE = htonl(height.i);

    [data appendBytes:&leftBE length:4];
    [data appendBytes:&topBE length:4];
    [data appendBytes:&widthBE length:4];
    [data appendBytes:&heightBE length:4];

    return data;
}

// åéææ¬è¾å¥ç¶æå° TouchController
- (void)sendTextInputStatus {
    if (self.touchControllerTransportHandle < 0) return;

    NSString *text = self.touchControllerTextField.text ?: @"";
    UITextRange *selectedRange = self.touchControllerTextField.selectedTextRange;
    NSInteger selectionStart = [self.touchControllerTextField offsetFromPosition:self.touchControllerTextField.beginningOfDocument
                                                                  toPosition:selectedRange.start];
    NSInteger selectionLength = [self.touchControllerTextField offsetFromPosition:selectedRange.start
                                                                    toPosition:selectedRange.end];

    NSData *messageData = [self encodeInputStatusMessageWithText:text
                                              compositionStart:0
                                              compositionLength:0
                                              selectionStart:(int)selectionStart
                                              selectionLength:(int)selectionLength
                                              selectionLeft:NO];

    [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:messageData];
}

// åéåæ ä½ç½®ä¿¡æ¯
- (void)sendInputCursorWithRect:(CGRect)rect {
    if (self.touchControllerTransportHandle < 0) return;

    NSData *messageData = [self encodeInputCursorMessageWithRect:rect];
    [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:messageData];
}

// åéè¾å¥åºåä¿¡æ¯
- (void)sendInputAreaWithRect:(CGRect)rect {
    if (self.touchControllerTransportHandle < 0) return;

    NSData *messageData = [self encodeInputAreaMessageWithRect:rect];
    [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:messageData];
}

#pragma mark - TouchController Vibration Support

// ç¼ç  VibrateMessage (type=4)
- (NSData *)encodeVibrateMessageWithKind:(int32_t)kind {
    NSMutableData *data = [NSMutableData dataWithCapacity:8];
    int32_t type = htonl(PROXY_MESSAGE_TYPE_VIBRATE);
    int32_t kindBE = htonl(kind);

    [data appendBytes:&type length:4];
    [data appendBytes:&kindBE length:4];

    return data;
}

// è§¦åéå¨åé¦
- (void)triggerVibrationWithKind:(int32_t)kind {
    // æ£æ¥éå¨æ¯å¦å¯ç¨
    if (!getPrefBool(@"control.mod_touch_vibrate_enable")) {
        return;
    }

    // è·åéå¨å¼ºåº¦è®¾ç½®
    NSInteger intensity = [getPrefObject(@"control.mod_touch_vibrate_intensity") integerValue];
    if (intensity < 1) intensity = 1;
    if (intensity > 3) intensity = 3;

    // ä½¿ç¨ UIImpactFeedbackGenerator è§¦åéå¨
    UIImpactFeedbackGenerator *feedbackGenerator;
    switch (intensity) {
        case 1: // è½»åº¦éå¨
            feedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            break;
        case 2: // ä¸­åº¦éå¨
            feedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            break;
        case 3: // éåº¦éå¨
            feedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
            break;
        default:
            feedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            break;
    }

    [feedbackGenerator impactOccurred];

    // åæ¶åé VibrateMessage å° TouchController
    if (self.touchControllerTransportHandle >= 0) {
        NSData *messageData = [self encodeVibrateMessageWithKind:kind];
        [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:messageData];
    }
}

#pragma mark - TouchController Capability

// 编码 CapabilityMessage (type=5)
// 格式: 4B type (big endian) + 1B name_len + N B name (UTF-8) + 1B enabled (0/1)
- (NSData *)encodeCapabilityMessageWithName:(NSString *)name enabled:(BOOL)enabled {
    NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
    if (!nameData) {
        NSLog(@"[TouchController] Failed to encode capability name as UTF-8: %@", name);
        return nil;
    }

    uint8_t nameLen = (uint8_t)[nameData length];
    int32_t type = htonl(PROXY_MESSAGE_TYPE_CAPABILITY);
    uint8_t enabledByte = enabled ? 1 : 0;

    NSMutableData *data = [NSMutableData dataWithCapacity:4 + 1 + nameLen + 1];
    [data appendBytes:&type length:4];
    [data appendBytes:&nameLen length:1];
    [data appendBytes:[nameData bytes] length:nameLen];
    [data appendBytes:&enabledByte length:1];

    return data;
}

// 编码 InitializeMessage (type=10)
// 供未来启动器主动初始化使用，当前未调用
- (NSData *)encodeInitializeMessage {
    int32_t type = htonl(PROXY_MESSAGE_TYPE_INITIALIZE);
    return [NSData dataWithBytes:&type length:4];
}

// 在收到 InitializeMessage 后调用，向 Mod 声明启动器支持的能力
- (void)sendCapabilities {
    if (self.touchControllerTransportHandle < 0) {
        NSLog(@"[TouchController] Cannot send capabilities: transport not initialized");
        return;
    }

    // 发送 text_status 能力：声明启动器会通过 InputStatusMessage 上报文本编辑状态
    NSData *textStatusCap = [self encodeCapabilityMessageWithName:@"text_status" enabled:YES];
    [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:textStatusCap];

    // 发送 keyboard_show 能力：声明启动器会响应 KeyboardShowMessage 显示/隐藏键盘
    NSData *keyboardShowCap = [self encodeCapabilityMessageWithName:@"keyboard_show" enabled:YES];
    [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:keyboardShowCap];

    NSLog(@"[TouchController] Sent capabilities: text_status, keyboard_show");
}

#pragma mark - TouchController MoveView Support

// ç¼ç  MoveViewMessage (type=12)
- (NSData *)encodeMoveViewMessageWithScreenBased:(BOOL)screenBased
                                     deltaPitch:(float)deltaPitch
                                      deltaYaw:(float)deltaYaw {
    NSMutableData *data = [NSMutableData dataWithCapacity:13];
    int32_t type = htonl(PROXY_MESSAGE_TYPE_MOVE_VIEW);
    uint8_t screenBasedByte = screenBased ? 1 : 0;

    // å° float è½¬æ¢ä¸ºç½ç»å­èåº
    union { float f; uint32_t i; } up, uy;
    up.f = deltaPitch;
    uy.f = deltaYaw;
    uint32_t pitchBE = htonl(up.i);
    uint32_t yawBE = htonl(uy.i);

    [data appendBytes:&type length:4];
    [data appendBytes:&screenBasedByte length:1];
    [data appendBytes:&pitchBE length:4];
    [data appendBytes:&yawBE length:4];

    return data;
}

// åéç§»å¨è§è§æ¶æ¯
- (void)sendMoveViewWithDeltaPitch:(float)deltaPitch deltaYaw:(float)deltaYaw {
    if (self.touchControllerTransportHandle >= 0) {
        NSData *messageData = [self encodeMoveViewMessageWithScreenBased:YES
                                                              deltaPitch:deltaPitch
                                                               deltaYaw:deltaYaw];
        [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:messageData];
    }
}

#pragma mark - TouchController Message Receiver

// å¤çä» TouchController æ¥æ¶å°çæ¶æ¯
- (void)processTouchControllerMessage:(NSData *)messageData {
    if (messageData.length < 4) {
        NSLog(@"[TouchController] Message too short: %lu bytes", (unsigned long)messageData.length);
        return;
    }

    int32_t type;
    [messageData getBytes:&type length:4];
    type = ntohl(type);

    switch (type) {
        case PROXY_MESSAGE_TYPE_VIBRATE: {
            if (messageData.length >= 8) {
                int32_t kind;
                [messageData getBytes:&kind range:NSMakeRange(4, 4)];
                kind = ntohl(kind);
                
                // ä½¿ç¨ dispatch_async ç¡®ä¿å¨ä¸»çº¿ç¨ä¸­è°ç¨
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.view && !self.isBeingDismissed) {
                        [self triggerVibrationWithKind:kind];
                    }
                });
            }
            break;
        }
        case PROXY_MESSAGE_TYPE_MOVE_VIEW: {
            if (messageData.length >= 13) {
                uint8_t screenBasedByte;
                int32_t pitchBE, yawBE;
                [messageData getBytes:&screenBasedByte range:NSMakeRange(4, 1)];
                [messageData getBytes:&pitchBE range:NSMakeRange(5, 4)];
                [messageData getBytes:&yawBE range:NSMakeRange(9, 4)];

                BOOL screenBased = (screenBasedByte != 0);
                union { uint32_t i; float f; } up, uy;
                up.i = ntohl(pitchBE);
                uy.i = ntohl(yawBE);

                // MoveView æ¶æ¯éå¸¸æ¯ä»å®¢æ·ç«¯åéå°æå¡ç«¯ç
                // è¿éæä»¬è®°å½æ¥å¿ï¼å®éåºç¨å¯è½éè¦ç¹æ®å¤ç
                NSLog(@"[TouchController] Received MoveView: screenBased=%d, pitch=%.2f, yaw=%.2f",
                      screenBased, up.f, uy.f);
            }
            break;
        }
        case PROXY_MESSAGE_TYPE_INITIALIZE: {
            NSLog(@"[TouchController] Received InitializeMessage, sending capabilities");
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.view && !self.isBeingDismissed) {
                    [self sendCapabilities];
                }
            });
            break;
        }
        case PROXY_MESSAGE_TYPE_KEYBOARD_SHOW: {
            if (messageData.length >= 5) {
                uint8_t showByte;
                [messageData getBytes:&showByte range:NSMakeRange(4, 1)];
                BOOL show = (showByte != 0);
                NSLog(@"[TouchController] Received KeyboardShow: show=%d", show);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.view && !self.isBeingDismissed) {
                        if (show) {
                            [self.touchControllerTextField becomeFirstResponder];
                        } else {
                            [self.touchControllerTextField resignFirstResponder];
                        }
                    }
                });
            } else {
                NSLog(@"[TouchController] KeyboardShowMessage too short: %lu bytes", (unsigned long)messageData.length);
            }
            break;
        }
        case PROXY_MESSAGE_TYPE_CAPABILITY: {
            // Mod → launcher 方向的能力协商（未来扩展点）
            // 当前启动器不处理 Mod 声明的能力，仅记录日志
            if (messageData.length >= 6) {
                uint8_t nameLen;
                [messageData getBytes:&nameLen range:NSMakeRange(4, 1)];
                if (messageData.length >= (NSUInteger)(5 + nameLen + 1)) {
                    NSRange nameRange = NSMakeRange(5, nameLen);
                    NSString *capabilityName = [[NSString alloc] initWithData:[messageData subdataWithRange:nameRange] encoding:NSUTF8StringEncoding];
                    uint8_t enabledByte;
                    [messageData getBytes:&enabledByte range:NSMakeRange(5 + nameLen, 1)];
                    NSLog(@"[TouchController] Received Capability: name=%@, enabled=%d", capabilityName, enabledByte != 0);
                } else {
                    NSLog(@"[TouchController] CapabilityMessage too short for declared name length");
                }
            }
            break;
        }
        default: {
            NSUInteger dumpLen = MIN(messageData.length, (NSUInteger)32);
            NSMutableString *hexDump = [NSMutableString string];
            const uint8_t *bytes = (const uint8_t *)[messageData bytes];
            for (NSUInteger i = 0; i < dumpLen; i++) {
                [hexDump appendFormat:@"%02x ", bytes[i]];
            }
            NSLog(@"[TouchController] Unknown message type: %d, length: %lu, hex: %@",
                  type, (unsigned long)messageData.length, hexDump);
            break;
        }
    }
}

// åå§åææ¬è¾å¥å­æ®µ
#pragma mark - GestureRecognizer Delegate

// 仅 moveViewPanGesture 需要特殊判定；其他手势保持默认行为
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.moveViewPanGesture) {
        // 条件 1: TouchController 必须启用
        if (!getPrefBool(@"control.mod_touch_enable")) return NO;
        // 条件 2: 必须是静态库模式（mode == 2）
        NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];
        if (mode != 2) return NO;
        // 条件 3: 移动视角开关必须打开
        if (!getPrefBool(@"control.mod_touch_moveview_enable")) return NO;
        // 条件 4: 必须在游戏内（isGrabbing 为 true）
        if (isGrabbing != JNI_TRUE) return NO;
        // 条件 5: 触摸起点必须在 touchView 右半区
        CGPoint location = [gestureRecognizer locationInView:self.touchView];
        if (location.x < self.touchView.bounds.size.width / 2.0) return NO;
        return YES;
    }
    return YES;
}

#pragma mark - TouchController MoveView Gesture

// 处理右半区滑动手势，发送 MoveViewMessage 给 TouchController
- (void)handleMoveViewPanGesture:(UIPanGestureRecognizer *)gesture {
    // 双重检查（防御性编程，即使 gestureRecognizerShouldBegin 返回 YES 也再次验证）
    if (!getPrefBool(@"control.mod_touch_enable")) return;
    if (!getPrefBool(@"control.mod_touch_moveview_enable")) return;
    if (isGrabbing != JNI_TRUE) return;

    UIPanGestureRecognizer *panGesture = (UIPanGestureRecognizer *)gesture;
    CGPoint translation = [panGesture translationInView:self.touchView];

    switch (panGesture.state) {
        case UIGestureRecognizerStateBegan:
            // 起始位置无需特殊处理，translation 已经是相对起点
            break;
        case UIGestureRecognizerStateChanged: {
            // 计算增量视角变化
            // 注意：deltaPitch 对应 Y 轴（上下），deltaYaw 对应 X 轴（左右）
            // 灵敏度系数：将屏幕像素转换为合理的视角变化
            // 1.0 表示 1:1 映射（screenBased=true 时 Mod 端会乘以 sensitivity）
            float deltaPitch = (float)translation.y;
            float deltaYaw = (float)translation.x;
            [self sendMoveViewWithDeltaPitch:deltaPitch deltaYaw:deltaYaw];
            // 重置 translation 为零，让下一帧 delta 是增量而非累计
            [panGesture setTranslation:CGPointZero inView:self.touchView];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            // 清理状态（无需特殊操作，translation 已被重置或手势已结束）
            break;
        default:
            break;
    }
}

- (void)setupTouchControllerTextInput {
    if (!self.touchControllerTextField) {
        self.touchControllerTextField = [[UITextField alloc] initWithFrame:CGRectZero];
        self.touchControllerTextField.hidden = YES;
        self.touchControllerTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.touchControllerTextField.autocorrectionType = UITextAutocorrectionTypeNo;
        self.touchControllerTextField.keyboardType = UIKeyboardTypeDefault;
        [self.view addSubview:self.touchControllerTextField];

        // æ·»å ææ¬ååçå¬
        [self.touchControllerTextField addTarget:self
                                          action:@selector(textFieldDidChange:)
                                forControlEvents:UIControlEventEditingChanged];
    }
}

// å¤çææ¬åå
- (void)textFieldDidChange:(UITextField *)textField {
    [self sendTextInputStatus];
}

// æ¾ç¤ºææ¬è¾å¥çé¢
- (void)showTouchControllerTextInput {
    if (!self.touchControllerTextInputEnabled) return;

    [self setupTouchControllerTextInput];
    self.touchControllerTextField.hidden = NO;
    [self.touchControllerTextField becomeFirstResponder];

    // åéè¾å¥åºåä¿¡æ¯
    [self sendInputAreaWithRect:self.touchControllerTextField.frame];

    // åéåå§ææ¬ç¶æ
    [self sendTextInputStatus];
}

// éèææ¬è¾å¥çé¢
- (void)hideTouchControllerTextInput {
    [self.touchControllerTextField resignFirstResponder];
    self.touchControllerTextField.hidden = YES;

    // åéç©ºç¶æä»¥å³é­è¾å¥
    NSData *messageData = [self encodeInputStatusMessageWithText:nil
                                              compositionStart:0
                                              compositionLength:0
                                              selectionStart:0
                                              selectionLength:0
                                              selectionLeft:NO];
    [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:messageData];
}

#pragma mark - Initialization

- (instancetype)initWithMetadata:(NSDictionary *)metadata {
    self = [super init];
    if (self) {
        self.metadata = metadata;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    isControlModifiable = NO;
    self.isMacCatalystApp = NSProcessInfo.processInfo.isMacCatalystApp;
    // Load MetalHUD library
    dlopen("/usr/lib/libMTLHud.dylib", 0);

    self.lightHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:(UIImpactFeedbackStyleLight)];
    self.mediumHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:(UIImpactFeedbackStyleMedium)];
    
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    BOOL isTVOS = realUIIdiom == UIUserInterfaceIdiomTV;
    if (!isTVOS) {
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }

    // 渲染循环 tick：Gyro/Controller 输入采样（FPS 计数已移至 native pojavSwapBuffers）
    // Vulkan 模式下 MC 不调用 glfwSwapBuffers，FPS 计数器不递增，
    // 使用 CADisplayLink 作为 fallback：每帧触发时递增计数器。
    //
    // 关键修复（Vulkan FPS 显示无效）：
    //   之前使用 [CADisplayLink displayLinkWithTarget:tickInput selector:@selector(invoke)]
    //   传递 block，但 block 的 invoke 方法签名是 -(void)invoke，而 CADisplayLink 期望的
    //   selector 签名是 -(void)selector:(CADisplayLink*)link。签名不匹配导致回调不触发，
    //   FPS 计数器永远不递增，显示为 0。
    //   修复：使用专门的 target 类 PLDisplayLinkTarget，提供正确签名的回调方法。
    //
    //   另一个问题：currentRenderer 在 viewDidLoad 时从 PLProfiles 读取，但 JavaLauncher.m
    //   可能在启动时修改 AMETHYST_RENDERER 环境变量（如 auto → ANGLE）。
    //   因此同时检查 PLProfiles 和 AMETHYST_RENDERER 环境变量，任一为 Vulkan 即启用 fallback。
    //
    //   关键修复（Vulkan 渲染器 + OpenGL 路径的 FPS 计数）：
    //   当 renderer=libMoltenVK.dylib 但 MC 26.2+ 选 prefer_opengl 时，MC 走 GL 路径
    //   （glfwWindowHint(GLFW_OPENGL_API)），pojavSwapBuffers 会被调用（经 eglSwapBuffers）。
    //   此时不应启用 CADisplayLink fallback，否则会与 pojavSwapBuffers 的 FPS 计数重复。
    //   只有真正的 Vulkan 路径（graphicsApi=prefer_vulkan 且 renderer=libMoltenVK.dylib）
    //   才需要 CADisplayLink fallback，因为 Vulkan 路径不调用 pojavSwapBuffers。
    //
    //   注意（阶段2修复）：此处的 configuredVulkanExpected 仅用于诊断日志（PLDisplayLinkTarget.isVulkanMode），
    //   实际是否启用 fallback 由 displayLinkTick: 内部每帧动态查询 pojavIsActualVulkanPath()
    //   （读 clientAPI == GLFW_NO_API）决定，与 MC 真实渲染路径一致。
    NSString *currentRenderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
    NSString *envRenderer = NSProcessInfo.processInfo.environment[@"AMETHYST_RENDERER"];
    NSString *graphicsApi = NSProcessInfo.processInfo.environment[@"AMETHYST_GRAPHICS_API"];
    BOOL isVulkanRenderer = [currentRenderer isEqualToString:@ RENDERER_NAME_VULKAN] ||
                            [envRenderer isEqualToString:@ RENDERER_NAME_VULKAN];
    // 配置预期 Vulkan 路径：仅用于诊断日志，对比"配置预期"与"MC 实际选择"的差异
    BOOL configuredVulkanExpected = isVulkanRenderer &&
        ![graphicsApi isEqualToString:@"prefer_opengl"] &&
        ![graphicsApi isEqualToString:@"opengl"];
    NSLog(@"[SurfaceViewController] FPS counter setup: profileRenderer=%@, envRenderer=%@, graphicsApi=%@, isVulkan=%d, configuredVulkanExpected=%d (actual path decided at runtime via pojavIsActualVulkanPath)",
          currentRenderer, envRenderer, graphicsApi, isVulkanRenderer, configuredVulkanExpected);

    PLDisplayLinkTarget *linkTarget = [[PLDisplayLinkTarget alloc] initWithVulkanMode:configuredVulkanExpected];
    CADisplayLink *displayLink = [CADisplayLink displayLinkWithTarget:linkTarget
                                                            selector:@selector(displayLinkTick:)];
    if (@available(iOS 15.0, tvOS 15.0, *)) {
        // max_framerate 选项已移除：始终采用 30-120Hz 自适应范围。
        // 屏幕硬件决定实际帧率（60Hz 设备仍为 60，120Hz ProMotion 设备可达 120），
        // 不再人为限制在 60FPS。配合 disable_game_vsync 完整解锁 VSync 后帧率可超过屏幕刷新率。
        displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 120, 120);
    }
    [displayLink addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
    self.statsDisplayLink = displayLink;
    self.statsDisplayLinkTarget = linkTarget;  // 强引用防止释放

    // 低频采样定时器：每 1 秒读取一次 native FPS 计数器和内存占用
    // 参照 FCL/ZL2 的 1Hz 采样策略（FCL_GameMenu.java Thread.sleep(1000)）
    // pojavGetAndResetFps() 读取并重置计数器，1 秒间隔直接返回 FPS 值
    self.statsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                      target:self
                                                    selector:@selector(updateGameStats)
                                                    userInfo:nil
                                                     repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.statsTimer forMode:NSRunLoopCommonModes];

    CGFloat screenScale = UIScreen.mainScreen.scale;
    [self updateSavedResolution];

    self.rootView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width + 30.0, self.view.frame.size.height)];
    [self.view addSubview:self.rootView];

    self.ctrlView = [[ControlLayout alloc] initWithFrame:getSafeArea(self.view.frame)];
    [self performSelector:@selector(initCategory_Navigation)];

    self.surfaceView = [[GameSurfaceView alloc] initWithFrame:self.view.frame];
    self.surfaceView.layer.contentsScale = screenScale * resolutionScale;
    self.surfaceView.layer.magnificationFilter = self.surfaceView.layer.minificationFilter = kCAFilterNearest;
    self.surfaceView.multipleTouchEnabled = YES;
    pojavWindow = self.surfaceView;

    self.touchView = [[UIView alloc] initWithFrame:self.view.frame];
    self.touchView.backgroundColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.09 alpha:1.0];
    self.touchView.multipleTouchEnabled = YES;
    [self.touchView addSubview:self.surfaceView];

    [self.rootView addSubview:self.touchView];
    [self.rootView addSubview:self.ctrlView];

    [self performSelector:@selector(setupCategory_Navigation)];

    UIHoverGestureRecognizer *hoverGesture = [[NSClassFromString(@"UIHoverGestureRecognizer") alloc] initWithTarget:self action:@selector(surfaceOnHover:)];
    [self.touchView addGestureRecognizer:hoverGesture];

    self.tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(surfaceOnClick:)];
    self.tapGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.tapGesture.delegate = self;
    self.tapGesture.numberOfTapsRequired = 1;
    self.tapGesture.numberOfTouchesRequired = 1;
    self.tapGesture.cancelsTouchesInView = NO;
    self.tapGesture.delaysTouchesBegan = NO;
    self.tapGesture.delaysTouchesEnded = NO;
    [self.touchView addGestureRecognizer:self.tapGesture];

    self.doubleTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(surfaceOnDoubleClick:)];
    self.doubleTapGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.doubleTapGesture.delegate = self;
    self.doubleTapGesture.numberOfTapsRequired = 2;
    self.doubleTapGesture.numberOfTouchesRequired = 1;
    self.doubleTapGesture.cancelsTouchesInView = NO;
    self.doubleTapGesture.delaysTouchesBegan = NO;
    self.doubleTapGesture.delaysTouchesEnded = NO;
    [self.touchView addGestureRecognizer:self.doubleTapGesture];

    self.longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(surfaceOnLongpress:)];
    self.longPressGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.longPressGesture.cancelsTouchesInView = NO;
    self.longPressGesture.delaysTouchesBegan = NO;
    self.longPressGesture.delaysTouchesEnded = NO;
    self.longPressGesture.delegate = self;
    [self.touchView addGestureRecognizer:self.longPressGesture];

    self.longPressTwoGesture = [[UILongPressGestureRecognizer alloc]initWithTarget:self action:@selector(keyboardGesture:)];
    self.longPressTwoGesture.numberOfTouchesRequired = 2;
    self.longPressTwoGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.longPressTwoGesture.cancelsTouchesInView = NO;
    self.longPressTwoGesture.delaysTouchesBegan = NO;
    self.longPressTwoGesture.delaysTouchesEnded = NO;
    self.longPressTwoGesture.delegate = self;
    [self.touchView addGestureRecognizer:self.longPressTwoGesture];

    self.scrollPanGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(surfaceOnTouchesScroll:)];
    self.scrollPanGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.scrollPanGesture.delegate = self;
    self.scrollPanGesture.minimumNumberOfTouches = 2;
    self.scrollPanGesture.maximumNumberOfTouches = 2;
    self.scrollPanGesture.cancelsTouchesInView = NO;
    self.scrollPanGesture.delaysTouchesBegan = NO;
    self.scrollPanGesture.delaysTouchesEnded = NO;
    [self.touchView addGestureRecognizer:self.scrollPanGesture];

    // TouchController 移动视角手势：右半区单指滑动
    self.moveViewPanGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleMoveViewPanGesture:)];
    self.moveViewPanGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.moveViewPanGesture.delegate = self;
    self.moveViewPanGesture.maximumNumberOfTouches = 1;
    self.moveViewPanGesture.minimumNumberOfTouches = 1;
    // 不取消 touches 事件，让 touchesMoved 仍能触发（与 TC AddPointer 并存）
    self.moveViewPanGesture.cancelsTouchesInView = NO;
    self.moveViewPanGesture.delaysTouchesBegan = NO;
    self.moveViewPanGesture.delaysTouchesEnded = NO;
    [self.touchView addGestureRecognizer:self.moveViewPanGesture];

    virtualMouseEnabled = getPrefBool(@"control.virtmouse_enable");
    virtualMouseFrame = CGRectMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2, 18, 27);
    self.mousePointerView = [[UIImageView alloc] initWithFrame:virtualMouseFrame];
    self.mousePointerView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin |UIViewAutoresizingFlexibleBottomMargin;
    self.mousePointerView.hidden = !virtualMouseEnabled;
    [self reloadMousePointerImage];
    self.mousePointerView.userInteractionEnabled = NO;
    [self.touchView addSubview:self.mousePointerView];

    // 关键修复（UI 累积异常）：将块观察者存为属性，dealloc 中移除。
    // 之前返回值未存储，导致每次新建 SurfaceViewController 都泄漏一个观察者 + 强引用 self。
    self.mousePointerUpdatedCallback = [[NSNotificationCenter defaultCenter] addObserverForName:@"MousePointerUpdated" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        [self reloadMousePointerImage];
    }];

    self.inputTextField = [[TrackedTextField alloc] initWithFrame:CGRectMake(0, -32.0, self.view.frame.size.width, 30.0)];
    self.inputTextField.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.inputTextField.delegate = self;
    self.inputTextField.font = [UIFont fontWithName:@"Menlo-Regular" size:20];
    self.inputTextField.clearsOnBeginEditing = YES;
    self.inputTextField.textAlignment = NSTextAlignmentCenter;
    self.inputTextField.sendChar = ^(jchar keychar){ CallbackBridge_nativeSendChar(keychar); };
    self.inputTextField.sendCharMods = ^(jchar keychar, int mods){ CallbackBridge_nativeSendCharMods(keychar, mods); };
    self.inputTextField.sendKey = ^(int key, int scancode, int action, int mods) { CallbackBridge_nativeSendKey(key, scancode, action, mods); };

    self.swipeableButtons = [[NSMutableArray alloc] init];

    [KeyboardInput initKeycodeTable];
    self.mouseConnectCallback = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        GCMouse* mouse = note.object;
        [self registerMouseCallbacks:mouse];
        self.mousePointerView.hidden = isGrabbing || !virtualMouseEnabled;
        [self setNeedsUpdateOfPrefersPointerLocked];
    }];
    self.mouseDisconnectCallback = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        GCMouse* mouse = note.object;
        mouse.mouseInput.mouseMovedHandler = nil;
        [mouse.mouseInput.auxiliaryButtons makeObjectsPerformSelector:@selector(setPressedChangedHandler:) withObject:nil];
        [self setNeedsUpdateOfPrefersPointerLocked];
        if (getPrefBool(@"controll.hardware_hide")) { self.ctrlView.hidden = NO; }
    }];
    if (GCMouse.current != nil) { [self registerMouseCallbacks:GCMouse.current]; }

    self.controllerConnectCallback = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        GCController* controller = note.object;
        [ControllerInput initKeycodeTable];
        [ControllerInput registerControllerCallbacks:controller];
        self.mousePointerView.hidden = isGrabbing;
        virtualMouseEnabled = YES;
        if (getPrefBool(@"control.hardware_hide")) { self.ctrlView.hidden = YES; }
    }];
    self.controllerDisconnectCallback = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        GCController* controller = note.object;
        [ControllerInput unregisterControllerCallbacks:controller];
        if (getPrefBool(@"control.hardware_hide")) { self.ctrlView.hidden = NO; }
    }];
    if (GCController.controllers.count == 1) {
        [ControllerInput initKeycodeTable];
        [ControllerInput registerControllerCallbacks:GCController.controllers.firstObject];
    }

    [self.rootView addSubview:self.inputTextField];
    [self performSelector:@selector(initCategory_LogView)];
    [self updateJetsamControl];
    [self updatePreferenceChanges];
    [self loadCustomControls];

    if (UIApplication.sharedApplication.connectedScenes.count > 1 && getPrefBool(@"video.fullscreen_airplay")) {
        [self switchToExternalDisplay];
    }
    
    self.touchSender = [[TouchSender alloc] init];

    // åå§å TouchController éæåº Transport
    if (getPrefBool(@"control.mod_touch_enable")) {
        NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];
        if (mode == 2 && [TouchControllerBridge isTouchControllerAvailable]) {
            // éæåºæ¨¡å¼ï¼åå»º Transport
            self.touchControllerTransportHandle = [TouchControllerBridge createTransportWithName:@"/tmp/touchcontroller.sock"];
            if (self.touchControllerTransportHandle < 0) {
                NSLog(@"[TouchController] Failed to create transport for static library mode");
            } else {
                NSLog(@"[TouchController] Transport created successfully (handle: %lld)", self.touchControllerTransportHandle);
            }
        } else {
            self.touchControllerTransportHandle = -1;
        }
    } else {
        self.touchControllerTransportHandle = -1;
    }

    // åå§å TouchController ææ¬è¾å¥æ¯æ
    if (self.touchControllerTransportHandle >= 0) {
        self.touchControllerTextInputEnabled = YES;
        [self setupTouchControllerTextInput];
        NSLog(@"[TouchController] Text input support initialized");

        // å¯å¨æ¶æ¯æ¥æ¶å®æ¶å¨
        [self startTouchControllerMessageLoop];
    }

    // 阶段13：显示启动遮罩层（在 launchMinecraft 之前显示，首帧渲染后自动移除）
    [self setupLaunchOverlay];

    [self launchMinecraft];
}

- (void)reloadMousePointerImage {
    NSString *path = [NSString stringWithFormat:@"%s/controlmap/mouse_pointer.png", getenv("POJAV_HOME")];
    UIImage *img = [UIImage imageWithContentsOfFile:path];
    if (img) {
        self.mousePointerView.image = img;
    } else {
        self.mousePointerView.image = [UIImage imageNamed:@"MousePointer"];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self setNeedsUpdateOfPrefersPointerLocked];

    // LAN 端口检测器已改为手动输入模式（LanPortDetector.h 说明），
    // 自动检测（startDetecting/stopDetecting）已移除，无需在此启动。
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 更新启动遮罩层渐变背景的 frame（旋转/尺寸变化时）
    if (self.launchGradientLayer && self.launchOverlayView) {
        self.launchGradientLayer.frame = self.launchOverlayView.bounds;
    }
}

- (void)updateAudioSettings {
    NSError *sessionError = nil;
    AVAudioSessionCategory category;
    AVAudioSessionCategoryOptions options = 0;
    if(getPrefBool(@"video.allow_microphone")) {
        category = AVAudioSessionCategoryPlayAndRecord;
        options |= AVAudioSessionCategoryOptionAllowAirPlay | AVAudioSessionCategoryOptionAllowBluetoothA2DP | AVAudioSessionCategoryOptionDefaultToSpeaker;
    } else if(getPrefBool(@"video.silence_with_switch")) {
        category = AVAudioSessionCategorySoloAmbient;
    } else {
        category = AVAudioSessionCategoryPlayback;
    }
    if(!getPrefBool(@"video.silence_other_audio")) {
        options |= AVAudioSessionCategoryOptionMixWithOthers;
    }
    AVAudioSession *session = AVAudioSession.sharedInstance;
    [session setCategory:category withOptions:options error:&sessionError];
    [session setActive:YES error:&sessionError];
}

- (void)updateJetsamControl {
    if (!getEntitlementValue(@"com.apple.private.memorystatus")) {
        return;
    }
    // 必须与 JavaLauncher.m 中 launchJVM 的 allocmem 计算保持一致，
    // 否则会出现 Jetsam 上限 < JVM Xmx + native 开销 的情况，
    // 导致系统在 JVM 启动阶段 SIGKILL 进程（日志表现为 "XPC connection interrupted"）。
    int allocmem;
    if (getPrefBool(@"java.auto_ram")) {
        CGFloat autoRatio = getEntitlementValue(@"com.apple.private.memorystatus") ? 0.4 : 0.25;
        allocmem = roundf((NSProcessInfo.processInfo.physicalMemory >> 20) * autoRatio);
    } else {
        allocmem = (int)getPrefInt(@"java.allocated_memory");
    }
    // 1024 MB 留给 JVM native 堆 + UIKit/Metal/EGL 等非 Java 堆开销。
    int limit = allocmem + 1024;
    if (memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT, getpid(), limit, NULL, 0) == -1) {
        NSLog(@"Failed to set Jetsam task limit: error: %s", strerror(errno));
    } else {
        NSLog(@"Successfully set Jetsam task limit (allocmem=%d MB, limit=%d MB)", allocmem, limit);
    }
}

- (void)updatePreferenceChanges {
    if (getPrefBool(@"debug.debug_auto_correction")) {
        self.inputTextField.autocorrectionType = UITextAutocorrectionTypeDefault;
    } else {
        self.inputTextField.autocorrectionType = UITextAutocorrectionTypeNo;
    }

    BOOL gyroEnabled = getPrefBool(@"control.gyroscope_enable");
    BOOL gyroInvertX = getPrefBool(@"control.gyroscope_invert_x_axis");
    int gyroSensitivity = getPrefInt(@"control.gyroscope_sensitivity");
    [GyroInput updateSensitivity:gyroEnabled?gyroSensitivity:0 invertXAxis:gyroInvertX];

    self.mouseSpeed = getPrefFloat(@"control.mouse_speed") / 100.0;
    virtualMouseEnabled = getPrefBool(@"control.virtmouse_enable");
    self.mousePointerView.hidden = isGrabbing || !virtualMouseEnabled;

    CGFloat mouseScale = getPrefFloat(@"control.mouse_scale") / 100.0;
    virtualMouseFrame = CGRectMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2, 18.0 * mouseScale, 27 * mouseScale);
    self.mousePointerView.frame = virtualMouseFrame;

    self.shouldHideControlsFromRecording = getPrefFloat(@"control.recording_hide");
    [self.ctrlView hideViewFromCapture:self.shouldHideControlsFromRecording];
    self.ctrlView.frame = getSafeArea(self.view.frame);

    self.slideableHotbar = getPrefBool(@"control.slideable_hotbar");
    self.enableMouseGestures = getPrefBool(@"control.gesture_mouse");
    self.enableHotbarGestures = getPrefBool(@"control.gesture_hotbar");
    self.shouldTriggerHaptic = !getPrefBool(@"control.disable_haptics");

    self.scrollPanGesture.enabled = self.enableMouseGestures;
    self.doubleTapGesture.enabled = self.enableHotbarGestures;
    self.longPressGesture.minimumPressDuration = getPrefFloat(@"control.press_duration") / 1000.0;

    [self updateAudioSettings];
    [self updateSavedResolution];
    if (@available(iOS 16, tvOS 16, *)) {
        if ([self.surfaceView.layer isKindOfClass:CAMetalLayer.class]) {
            BOOL perfHUDEnabled = getPrefBool(@"video.performance_hud");
            ((CAMetalLayer *)self.surfaceView.layer).developerHUDProperties = perfHUDEnabled ? @{@"mode": @"default"} : nil;
        }
    }
    [self setNeedsUpdateOfPrefersPointerLocked];
}

- (void)updateSavedResolution {
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes.allObjects) {
        self.screenScale = scene.screen.scale;
        if (scene.session.role != UIWindowSceneSessionRoleApplication) {
            break;
        }
    }

    if (self.surfaceView.superview != nil) {
        self.surfaceView.frame = self.surfaceView.superview.frame;
    }

    resolutionScale = getPrefFloat(@"video.resolution") / 100.0;
    // MobileGL/SDL3 初始黑屏根治：video.resolution 尚未写入偏好时，
    // getPrefObject 返回 nil、[nil floatValue] 得 0，于是 resolutionScale=0
    // -> contentsScale=0、windowWidth/Height=0 -> drawableSize 被 MAX(0,1)
    // 钳成 1x1。EGLSurface 只在 gl_init_context 里创建一次，1x1 既不报错也不
    // 崩溃，画面永久全黑，且无法自愈 —— 表现正是「必须手动调一次分辨率
    // 才有画面」。这里把非法值（0/负/极小）统一兜底为 100%，
    // 正常值（0.25~1.0）完全不受影响。
    if (!(resolutionScale > 0.01f)) {
        NSLog(@"[SurfaceVC] video.resolution invalid (%.4f) -> falling back to 100%%", resolutionScale);
        resolutionScale = 1.0f;
    }
    self.surfaceView.layer.contentsScale = self.screenScale * resolutionScale;

    physicalWidth = roundf(self.surfaceView.frame.size.width * self.screenScale);
    physicalHeight = roundf(self.surfaceView.frame.size.height * self.screenScale);
    windowWidth = roundf(physicalWidth * resolutionScale);
    windowHeight = roundf(physicalHeight * resolutionScale);
    // 【iPhone X 1px 失配根治 —— "必须手动调一次分辨率才有画面"的成因】
    // 旧代码在此把奇数宽/高 -- 取偶（iPhone X: 375*3=1125 -> 1124）。
    // 但 ANGLE 建 EGL window surface 时**不读 drawableSize、也不理我们传的
    // EGL_WIDTH/HEIGHT attribs**，而是自行按 layer.bounds x contentsScale 建面
    // （设备实证：attribs=2436x1124，eglQuerySurface 回报 2436x1125）。
    // 于是三套尺寸永久差 1px：
    //     drawableSize / launchJVM 告知 MC 的值 = 2436x1124
    //     ANGLE surface（present 的 backbuffer）   = 2436x1125
    // Air 注释定案："drawable 必须等于将要呈现的 backbuffer 尺寸 —— 这是
    // 帧能上屏的硬约束"，不等即 present 失配 = 全黑，且 surface 只建一次，
    // 不会自愈；手动调一次分辨率会触发 SDL resize 事件（被 hook 改写成
    // surface 尺寸）把 MC viewport 推到 1125，画面才出现 —— 正是用户看到的现象。
    //
    // Air 在 iPad（1640 是偶数）上取偶不改变任何值，所以永远踩不到；
    // iPhone X 的 375*3=1125 是奇数，一踩一个准。
    // 这里去掉取偶，让 launchJVM 值 == drawable == bounds x contentsScale ==
    // surface 四者同源（Vulkan/MoltenVK 自管 swapchain，不依赖偶数尺寸）。
    if ([self.surfaceView.layer isKindOfClass:CAMetalLayer.class]) {
        CAMetalLayer *metalLayer = (CAMetalLayer *)self.surfaceView.layer;
        // SDL3（MC 26.3+）小窗根治：GL 路径下本层由 EGL surface 呈现，必须与 MC
        // 的真实渲染分辨率对齐。MC 26.3+SDL3 以「点」回报窗口尺寸（viewport
        // 812x375），旧代码无条件写 2x/3x 像素 drawableSize（2436x1125），于是
        // EGL surface 与 MC viewport 差一个设备 scale —— 画面只占左上 1/9。
        // 对齐 1x 后 surface == drawable == MC viewport 恒成立，CoreAnimation
        // 把 1x 帧放大到物理屏；旋转时三者随 bounds 同步翻转，不再互相打架。
        // Vulkan（标志为假，MoltenVK 自管 swapchain）与 GLFW 路径（MC 用的就是
        // 像素）保持原行为，不受影响。
        // Task 53/55：GL 拥有呈现层时，几何失配（转置/尺寸错）未治愈期间停写
        // drawableSize —— 此期由 gl_bridge 的几何重对齐独占写权保持 present
        // 自洽；本函数若继续写会与之每帧拉锯 = 画面分裂（Air Task53 同款 gate）。
        // 重对齐成功后 surface==drawable==bounds 像素，本写入变为同值 no-op。
        if (ame_gl_surface_owns_layer()) {
            if (!ame_gl_surface_transposed()) {
                metalLayer.drawableSize = CGSizeMake(MAX(windowWidth, 1), MAX(windowHeight, 1));
                NSLog(@"[SurfaceVC] drawableSize=%dx%d (contentsScale %.2f, resolution %.0f%%)",
                      (int)metalLayer.drawableSize.width, (int)metalLayer.drawableSize.height,
                      metalLayer.contentsScale, resolutionScale * 100.0f);
            }
        } else {
            metalLayer.drawableSize = CGSizeMake(MAX(windowWidth, 1), MAX(windowHeight, 1));
            NSLog(@"[SurfaceVC] drawableSize=%dx%d (contentsScale %.2f, resolution %.0f%%)",
                  (int)metalLayer.drawableSize.width, (int)metalLayer.drawableSize.height,
                  metalLayer.contentsScale, resolutionScale * 100.0f);
        }
        // 解锁帧率（关闭垂直同步）：三缓冲。
        // 默认 maximumDrawableCount（通常为 2）下，当两个 drawable 都在等待呈现时，
        // nextDrawable 会阻塞到 vblank 释放一个 drawable，间接把渲染线程锁在刷新率。
        // 设为 3（三缓冲）后几乎总有空闲 drawable，渲染线程不再因等待 drawable 而 stall，
        // 配合 VSync 关闭可让帧率超过屏幕刷新率。该值是 Metal 低延迟/高吞吐渲染的标准设置。
        // 注：此优化对 GL 类渲染器（经 CAMetalLayer 呈现）最有意义；Vulkan/MoltenVK 自管 swapchain。
        metalLayer.maximumDrawableCount = 3;

        // 显式设置 presentsWithTransaction=NO（默认值）。
        // presentsWithTransaction=YES 会导致 presentDrawable 同步等待 Core Animation 事务提交，
        // 增加延迟且不会提高帧率。设为 NO 让 presentDrawable 异步提交到 Core Animation，
        // 渲染线程可以立即继续下一帧渲染，配合 eglSwapInterval(0) 实现帧率解锁。
        // 这是 Metal 高吞吐渲染的标准配置。
        metalLayer.presentsWithTransaction = NO;

        // 确保异步绘制开启（GameSurfaceView.initWithFrame 已设置，此处二次确认）
        metalLayer.drawsAsynchronously = YES;

        // 记录 Metal 层配置（仅首次），帮助诊断帧率问题
        static BOOL s_loggedMetalConfig = NO;
        if (!s_loggedMetalConfig) {
            s_loggedMetalConfig = YES;
            NSLog(@"[SurfaceVC] CAMetalLayer configured: drawableSize=%.0fx%.0f, maximumDrawableCount=%ld, presentsWithTransaction=%d, drawsAsynchronously=%d, contentsScale=%.2f",
                  metalLayer.drawableSize.width, metalLayer.drawableSize.height,
                  (long)metalLayer.maximumDrawableCount,
                  metalLayer.presentsWithTransaction,
                  metalLayer.drawsAsynchronously,
                  metalLayer.contentsScale);
        }
    }
    CallbackBridge_nativeSendScreenSize(windowWidth, windowHeight);
}

- (void)updateControlHiddenState:(BOOL)hide {
    for (UIView *view in self.ctrlView.subviews) {
        ControlButton *button = (ControlButton *)view;
        if (!button.canBeHidden) continue;
        BOOL hidden = hide || !(
            (isGrabbing && [button.properties[@"displayInGame"] boolValue]) ||
            (!isGrabbing && [button.properties[@"displayInMenu"] boolValue]));
        if (!hidden && ![button isKindOfClass:ControlSubButton.class]) {
            button.hidden = hidden;
            if ([button isKindOfClass:ControlDrawer.class]) {
                [(ControlDrawer *)button restoreButtonVisibility];
            }
        } else if (hidden) {
            button.hidden = hidden;
        }
    }
}

- (void)updateGrabState {
    if (isGrabbing == JNI_TRUE) {
        CGFloat screenScale = self.surfaceView.layer.contentsScale;
        CallbackBridge_nativeSendCursorPos(ACTION_DOWN, lastVirtualMousePoint.x * screenScale, lastVirtualMousePoint.y * screenScale);
        virtualMouseFrame.origin.x = self.view.frame.size.width / 2;
        virtualMouseFrame.origin.y = self.view.frame.size.height / 2;
        self.mousePointerView.frame = virtualMouseFrame;
    }
    self.scrollPanGesture.enabled = !isGrabbing;
    self.mousePointerView.hidden = isGrabbing || !virtualMouseEnabled;
    [self setNeedsUpdateOfPrefersPointerLocked];
    [self updateControlHiddenState:NO];
}

// Task87：LTW × MC 26.x 兼容性预检 ------------------------------------------
// LTW 在 iOS 上把桌面 GL 3.3 转译到 Apple 系统 ANGLE 的 GLES 3.0
// （日志实证 "LTW: Running on OpenGL ES 3.0 with ESSL 300"），且 LTW 无纹理
// 缓冲（TBO）模拟层。而 MC 26.x 的云渲染管线（minecraft:core/rendertype_clouds）
// 在桌面 GL 3.3 下按核心规范使用 samplerBuffer（TBO 自 GL 3.1 起为核心特性）
// ——ES 3.0 后端没有 GL_EXT_texture_buffer，着色器编译死于
// "'samplerBuffer' : Illegal use of reserved word" → 资源重载阶段必崩在标题界面。
// Zink（桌面 GL 4.x 全量）与 MobileGlues（自带 TBO 模拟）不受影响。
// 版本口径复用 ame98_mcMajorFromVersionId（JavaLauncher.h 导出），与 ResolveLwjglVersion
// 共用同一实现，Fabric/NeoForge/Forge 前缀形态 ID 也不会漏判。
static BOOL ame87_mcVersionRequiresTextureBuffer(NSString *mcVersionId) {
    if (mcVersionId.length == 0) {
        return NO;
    }
    NSInteger major = ame98_mcMajorFromVersionId(mcVersionId);
    if (major <= 0) {
        return NO;
    }
    return major >= 26;
}

- (void)launchMinecraft {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Validate metadata first
        if (!self.metadata) {
            NSLog(@"[SurfaceViewController] Error: metadata is nil");
            dispatch_async(dispatch_get_main_queue(), ^{
                [self dismissLaunchOverlayOnError];
                showDialog(localize(@"Error", nil), @"æ¸¸æçæ®å è½½å¤±è´¥ï¼è¯·éæ°éæ©çæ¬");
            });
            return;
        }

        // Validate window dimensions
        if (windowWidth <= 0 || windowHeight <= 0) {
            NSLog(@"[SurfaceViewController] Error: invalid window size %dx%d", windowWidth, windowHeight);
            windowWidth = 1280;
            windowHeight = 720;
        }
        
        // Task87：LTW 渲染器 × MC 26.x 预检（渲染器能力缺口，见 ame87_mcVersionRequiresTextureBuffer 头注释）
        NSString *ame87_renderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
        NSString *ame87_versionId = [self.metadata[@"id"] description];
        if ([ame87_renderer isEqualToString:@ RENDERER_NAME_LTW]
            && ame87_mcVersionRequiresTextureBuffer(ame87_versionId)) {
            NSLog(@"[SurfaceViewController] Task87 launch gate: LTW renderer + MC %@ blocked -- GL 3.3 requires texture buffers for the 26.x clouds pipeline, LTW's iOS backend is GLES 3.0 without GL_EXT_texture_buffer; startup would crash at the title screen", ame87_versionId);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self dismissLaunchOverlayOnError];
                showDialog(localize(@"Error", nil),
                    [NSString stringWithFormat:@"LTW 渲染器不支持 MC %@：\n\n26.x 的云渲染管线需要纹理缓冲（samplerBuffer），而 LTW 在 iOS 上的 ES 3.0 后端无法提供，启动后必崩在标题界面。\n\n请到 设置 → 视频设置 → 渲染器 切换到 Zink 或 MobileGlues 后重试。LTW 仍可用于 1.21.x 及更早版本。", ame87_versionId]);
            });
            return;
        }

        // Get Java version
        int minVersion = [self.metadata[@"javaVersion"][@"majorVersion"] intValue];
        if (minVersion == 0) {
            minVersion = [self.metadata[@"javaVersion"][@"version"] intValue];
        }
        if (minVersion == 0) {
            minVersion = 8; // Default to Java 8
        }
        
        // Validate authenticator
        BaseAuthenticator *currentAuth = BaseAuthenticator.current;
        if (!currentAuth) {
            NSLog(@"[SurfaceViewController] Error: no authenticator available");
            dispatch_async(dispatch_get_main_queue(), ^{
                [self dismissLaunchOverlayOnError];
                showDialog(localize(@"Error", nil), @"è¯·åç»å½è´¦æ·");
            });
            return;
        }
        
        // Validate accountId（用作账户文件名，传给 Java 端加载对应账户）
        NSString *accountId = currentAuth.authData[@"accountId"];
        if (!accountId || accountId.length == 0) {
            // 兜底：极少数情况下 accountId 缺失（如旧账户未迁移），回退到 username
            accountId = currentAuth.authData[@"username"];
            if (!accountId || accountId.length == 0) {
                accountId = @"Player";
            }
        }

        NSLog(@"[SurfaceViewController] Launching Minecraft with accountId: %@, version: %d, size: %dx%d",
              accountId, minVersion, windowWidth, windowHeight);

        // Launch JVM（args[0] 传 accountId，Java 端 MinecraftAccount.load(accountId) 据此加载账户）
        int launchResult = launchJVM(accountId, self.metadata, windowWidth, windowHeight, minVersion);

        // JVM 启动失败（返回非 0）：移除启动遮罩层，让用户看到错误对话框
        // launchJVM 内部失败时会调用 showDialog 显示错误，此处仅负责清理遮罩层
        if (launchResult != 0) {
            NSLog(@"[SurfaceViewController] JVM launch failed with code %d", launchResult);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self dismissLaunchOverlayOnError];
            });
        }
    });
}

#pragma mark - 阶段13/16：启动遮罩层（仿 FCL/ZL2 全屏启动进度显示）

/// 创建并显示启动遮罩层（参照 FCL/ZL2 风格重构）：
///
/// 设计理念（参照 FCL/ZalithLauncher2）：
///   - 启动遮罩层是纯视觉层，不拦截任何触摸事件
///   - userInteractionEnabled = NO，让下层的 gameMenuOverlay（悬浮球/FPS）可交互
///   - 深色渐变背景 + 毛玻璃效果，营造沉浸式启动体验
///   - 居中信息卡片展示启动进度、阶段、Java 版本、内存、渲染器
///   - 底部取消按钮允许用户中止卡住的启动流程
///
/// 视觉布局（从上到下）：
///   ┌─────────────────────────────────┐
///   │         游戏图标 (72pt)          │
///   │       旋转指示器 (Medium)        │
///   │     "正在启动 Minecraft"         │
///   │      当前阶段文案                │
///   │   ━━━━━━━━━━━━━━━━ 45%          │
///   │         已耗时 12秒              │
///   │  ┌─────────────────────────┐    │
///   │  │ Java 17 │ 2048MB │ gl4es │    │
///   │  └─────────────────────────┘    │
///   │        [ 取消启动 ]              │
///   └─────────────────────────────────┘
- (void)setupLaunchOverlay {
    // ============================================================
    // FCL 风格启动界面：中间转圈圈 + 显示自定义启动器背景
    // ============================================================
    // 参照 FCL (FoldCraftLauncher) 的启动加载界面：
    //   - 背景显示启动器的自定义壁纸（如果有）
    //   - 屏幕正中央显示一个大的旋转加载指示器
    //   - 指示器下方显示简短的标题文字（如"正在启动 Minecraft"）
    //   - 不显示进度条、百分比、阶段文案、信息卡片等多余元素
    //   - 底部保留一个小的"取消启动"按钮
    //
    // 之前的实现包含了图标、进度条、百分比、已耗时、信息卡片、
    // 阶段轮转文案等大量元素，过于复杂。FCL 的设计理念是简洁：
    // 用户只需要知道"正在加载"即可，不需要知道详细的阶段和进度。
    self.launchStartTime = [NSDate timeIntervalSinceReferenceDate];
    self.launchOverlayDismissed = NO;

    // ========================================================================
    // 全屏遮罩容器
    // ========================================================================
    // userInteractionEnabled = NO：让触摸穿透到下层的 gameMenuOverlay，
    // 用户可在启动期间拖动悬浮球、查看 FPS。
    // 取消按钮单独加到 self.view 上（不受此设置影响）。
    self.launchOverlayView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.launchOverlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.launchOverlayView.userInteractionEnabled = NO;
    [self.view addSubview:self.launchOverlayView];

    // ========================================================================
    // 背景层：显示自定义启动器背景
    // ========================================================================
    // 有自定义壁纸时：透明遮罩 + 轻微暗化蒙层（增强文字可读性）
    // 无自定义壁纸时：使用深色渐变作为回退
    if ([[BackgroundManager sharedManager] hasBackground]) {
        // 有自定义背景：透明遮罩 + 轻微暗化蒙层
        self.launchOverlayView.backgroundColor = [UIColor clearColor];
        UIView *dimOverlay = [[UIView alloc] initWithFrame:self.launchOverlayView.bounds];
        dimOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        dimOverlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.3];
        dimOverlay.userInteractionEnabled = NO;
        [self.launchOverlayView addSubview:dimOverlay];
    } else {
        // 无自定义背景：使用深色渐变
        CAGradientLayer *gradient = [CAGradientLayer layer];
        gradient.frame = self.launchOverlayView.bounds;
        gradient.colors = @[
            (__bridge id)[UIColor colorWithRed:0.08 green:0.09 blue:0.13 alpha:1.0].CGColor,
            (__bridge id)[UIColor colorWithRed:0.03 green:0.03 blue:0.05 alpha:1.0].CGColor,
        ];
        gradient.locations = @[@0.0, @1.0];
        gradient.startPoint = CGPointMake(0.5, 0.0);
        gradient.endPoint = CGPointMake(0.5, 1.0);
        [self.launchOverlayView.layer insertSublayer:gradient atIndex:0];
        self.launchGradientLayer = gradient;
    }

    // ========================================================================
    // 中央内容容器（居中显示转圈圈 + 标题）
    // ========================================================================
    UIView *centerContainer = [[UIView alloc] init];
    centerContainer.translatesAutoresizingMaskIntoConstraints = NO;
    centerContainer.userInteractionEnabled = NO;
    [self.launchOverlayView addSubview:centerContainer];

    // 大号旋转指示器（FCL 风格：屏幕正中央的大转圈）
    self.launchSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.launchSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.launchSpinner.color = [UIColor whiteColor];
    [self.launchSpinner startAnimating];
    [centerContainer addSubview:self.launchSpinner];

    // 标题文字（转圈下方，简短提示）
    self.launchTitleLabel = [[UILabel alloc] init];
    self.launchTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.launchTitleLabel.text = localize(@"launch.title", @"正在启动 Minecraft");
    self.launchTitleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    self.launchTitleLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1.0];
    self.launchTitleLabel.textAlignment = NSTextAlignmentCenter;
    [centerContainer addSubview:self.launchTitleLabel];

    // ========================================================================
    // 取消启动按钮（底部，独立添加到 self.view 不受遮罩穿透影响）
    // ========================================================================
    self.launchCancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.launchCancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.launchCancelButton setTitle:localize(@"launch.cancel", @"取消启动") forState:UIControlStateNormal];
    [self.launchCancelButton setTitleColor:[UIColor colorWithWhite:0.7 alpha:1.0] forState:UIControlStateNormal];
    self.launchCancelButton.titleLabel.font = [UIFont systemFontOfSize:14];
    self.launchCancelButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.1];
    self.launchCancelButton.layer.cornerRadius = 8;
    self.launchCancelButton.layer.cornerCurve = kCACornerCurveContinuous;
    [self.launchCancelButton addTarget:self action:@selector(cancelLaunch) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.launchCancelButton];

    // ========================================================================
    // 布局约束
    // ========================================================================
    [NSLayoutConstraint activateConstraints:@[
        // 中央容器：水平居中，垂直居中
        [centerContainer.centerXAnchor constraintEqualToAnchor:self.launchOverlayView.centerXAnchor],
        [centerContainer.centerYAnchor constraintEqualToAnchor:self.launchOverlayView.centerYAnchor],

        // 旋转指示器：容器顶部居中
        [self.launchSpinner.topAnchor constraintEqualToAnchor:centerContainer.topAnchor],
        [self.launchSpinner.centerXAnchor constraintEqualToAnchor:centerContainer.centerXAnchor],

        // 标题：转圈下方
        [self.launchTitleLabel.topAnchor constraintEqualToAnchor:self.launchSpinner.bottomAnchor constant:16],
        [self.launchTitleLabel.leadingAnchor constraintEqualToAnchor:centerContainer.leadingAnchor],
        [self.launchTitleLabel.trailingAnchor constraintEqualToAnchor:centerContainer.trailingAnchor],
        [self.launchTitleLabel.bottomAnchor constraintEqualToAnchor:centerContainer.bottomAnchor],

        // 取消按钮：底部安全区域上方
        [self.launchCancelButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-24],
        [self.launchCancelButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.launchCancelButton.widthAnchor constraintEqualToConstant:120],
        [self.launchCancelButton.heightAnchor constraintEqualToConstant:36],
    ]];

    // 注册首帧渲染通知（egl_bridge.m 中 pojavSwapBuffers 首次调用时发送）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onFirstFrameRendered)
                                                 name:@"PojavFirstFrameRendered"
                                               object:nil];

    // 兜底：关闭 SDL GL bridge 后，GL 上下文由 SDL 自行管理，egl_bridge 的
    // pojavSwapBuffers 不再被调用，"PojavFirstFrameRendered" 永远不会发出，
    // 遮罩就会一直盖住画面，看起来像卡死（实测导致用户误判并手动取消启动）。
    // 这里加一个宽松的超时，到点直接移除遮罩 —— 遮罩只是加载提示，
    // 不该成为进入游戏的门槛。
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.launchOverlayDismissed) return;
        NSLog(@"[SurfaceViewController] Launch overlay timeout after 45s: "
              @"no PojavFirstFrameRendered received (SDL owns the GL context; "
              @"egl_bridge swap is not used). Dismissing overlay so it cannot block gameplay.");
        [strongSelf dismissLaunchOverlayOnError];
    });
}

/// 取消启动：用户点击"取消启动"按钮时调用。
/// 终止 JVM 启动流程，移除遮罩层，返回启动器主界面。
- (void)cancelLaunch {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"launch.cancel_confirm_title", @"确认取消启动？")
                                                                   message:localize(@"launch.cancel_confirm_message", @"取消启动将终止当前的游戏加载流程并返回启动器。")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"launch.cancel_confirm_yes", @"确认取消")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        NSLog(@"[SurfaceViewController] User cancelled launch");
        // 移除遮罩层
        [self dismissLaunchOverlayOnError];
        // 返回启动器
        [[SurfaceViewController currentInstance].logOutputView dismissAndReturnToLauncher];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"launch.cancel_confirm_no", @"继续等待")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// 定时器回调（每 0.5 秒）：
/// 1. 基于已耗时计算当前阶段索引（每 2.5 秒一个阶段，避免 static 变量在多次启动间不重置）
/// 2. 推进进度条（基于已耗时，封顶 95%）
/// 3. 更新已耗时显示
- (void)updateLaunchStage {
    // FCL 风格启动界面不再需要阶段轮转和进度推进。
    // 此方法保留为空实现仅为兼容可能的旧调用点（实际上 setupLaunchOverlay
    // 已不再创建 launchStageTimer，此方法不会被调用）。
}

/// 首帧渲染通知回调：淡出并移除启动遮罩层
- (void)onFirstFrameRendered {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.launchOverlayDismissed) return;
        self.launchOverlayDismissed = YES;

        [self.launchSpinner stopAnimating];

        NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - self.launchStartTime;

        // 隐藏取消按钮（淡出动画与遮罩层一起进行）
        [self.launchCancelButton setHidden:YES];

        // 淡出移除遮罩层（FCL 风格：简洁的淡出过渡）
        [UIView animateWithDuration:0.4
                              delay:0.1
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.launchOverlayView.alpha = 0.0;
            self.launchCancelButton.alpha = 0.0;
        }
                         completion:^(BOOL finished) {
            [self.launchOverlayView removeFromSuperview];
            self.launchOverlayView = nil;
            self.launchGradientLayer = nil;
            [self.launchCancelButton removeFromSuperview];
            self.launchCancelButton = nil;
            [[NSNotificationCenter defaultCenter] removeObserver:self name:@"PojavFirstFrameRendered" object:nil];
            NSLog(@"[SurfaceViewController] Launch overlay dismissed after %.1f seconds", elapsed);
        }];
    });
}

/// 启动失败时移除遮罩层（JVM 启动失败、metadata 为空等错误路径调用）
- (void)dismissLaunchOverlayOnError {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.launchOverlayDismissed) return;
        self.launchOverlayDismissed = YES;

        [self.launchSpinner stopAnimating];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:@"PojavFirstFrameRendered" object:nil];

        [self.launchOverlayView removeFromSuperview];
        self.launchOverlayView = nil;
        self.launchGradientLayer = nil;
        [self.launchCancelButton removeFromSuperview];
        self.launchCancelButton = nil;
        NSLog(@"[SurfaceViewController] Launch overlay dismissed due to launch error");
    });
}

- (void)loadCustomControls {
    self.edgeGesture.enabled = YES;
    [self.swipeableButtons removeAllObjects];
    NSString *controlFile = [PLProfiles resolveKeyForCurrentProfile:@"defaultTouchCtrl"];
    [self.ctrlView loadControlFile:controlFile];

    ControlButton *menuButton;
    for (ControlButton *button in self.ctrlView.subviews) {
        BOOL isSwipeable = [button.properties[@"isSwipeable"] boolValue];

        button.canBeHidden = YES;
        BOOL isMenuButton = NO;
        for (int i = 0; i < 4; i++) {
            int keycodeInt = [button.properties[@"keycodes"][i] intValue];
            button.canBeHidden &= keycodeInt != SPECIALBTN_TOGGLECTRL && keycodeInt != SPECIALBTN_VIRTUALMOUSE;
            if (keycodeInt == SPECIALBTN_MENU) {
                menuButton = button;
            }
        }

        [button addTarget:self action:@selector(executebtn_down:) forControlEvents:UIControlEventTouchDown];
        [button addTarget:self action:@selector(executebtn_up_inside:) forControlEvents:UIControlEventTouchUpInside];
        [button addTarget:self action:@selector(executebtn_up_outside:) forControlEvents:UIControlEventTouchUpOutside];

        if (isSwipeable) {
            UIPanGestureRecognizer *panRecognizerButton = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(executebtn_swipe:)];
            panRecognizerButton.delegate = self;
            [button addGestureRecognizer:panRecognizerButton];
            [self.swipeableButtons addObject:button];
        }
    }

    [self updateControlHiddenState:self.toggleHidden];

    if (menuButton) {
        NSMutableArray *items = [NSMutableArray new];
        for (int i = 0; i < self.menuArray.count; i++) {
            UIAction *item = [UIAction actionWithTitle:localize(self.menuArray[i], nil) image:nil identifier:nil
                handler:^(id action) {[self didSelectMenuItem:i];}];
            [items addObject:item];
        }
        menuButton.menu = [UIMenu menuWithTitle:@"" image:nil identifier:nil
            options:UIMenuOptionsDisplayInline children:items];
        menuButton.showsMenuAsPrimaryAction = YES;
        self.edgeGesture.enabled = NO;
    }
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        self.rootView.bounds = CGRectMake(0, 0, size.width + 30.0, size.height);

        CGRect frame = self.view.frame;
        frame.size = size;
        self.touchView.frame = frame;
        self.inputTextField.frame = CGRectMake(0, -32.0, size.width, 30.0);
        [self viewWillTransitionToSize_LogView:frame];
        [self viewWillTransitionToSize_Navigation:frame];
        self.ctrlView.frame = getSafeArea(self.view.frame);
        [self.ctrlView.subviews makeObjectsPerformSelector:@selector(update)];
        [self updateSavedResolution];
        [GyroInput updateOrientation];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        virtualMouseFrame = self.mousePointerView.frame;
    }];
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}

#pragma mark - Input: send touch utilities

- (BOOL)isTouchInactive:(UITouch *)touch {
    return touch == nil || touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled;
}

- (void)sendTouchPoint:(CGPoint)location withEvent:(int)event
{
    CGFloat screenScale = self.screenScale;
    if (!isGrabbing) {
        screenScale *= resolutionScale;
        if (virtualMouseEnabled) {
            if (event == ACTION_MOVE) {
                virtualMouseFrame.origin.x += (location.x - lastVirtualMousePoint.x) * self.mouseSpeed;
                virtualMouseFrame.origin.y += (location.y - lastVirtualMousePoint.y) * self.mouseSpeed;
            } else if (event == ACTION_MOVE_MOTION) {
                event = ACTION_MOVE;
                virtualMouseFrame.origin.x += location.x * self.mouseSpeed;
                virtualMouseFrame.origin.y += location.y * self.mouseSpeed;
            }
            virtualMouseFrame.origin.x = clamp(virtualMouseFrame.origin.x, 0, self.surfaceView.frame.size.width);
            virtualMouseFrame.origin.y = clamp(virtualMouseFrame.origin.y, 0, self.surfaceView.frame.size.height);
            lastVirtualMousePoint = location;
            self.mousePointerView.frame = virtualMouseFrame;
            CallbackBridge_nativeSendCursorPos(event, virtualMouseFrame.origin.x * screenScale, virtualMouseFrame.origin.y * screenScale);
            return;
        }
        lastVirtualMousePoint = location;
    }
    CallbackBridge_nativeSendCursorPos(event, location.x * screenScale, location.y * screenScale);
}

#pragma mark - Input: on-surface functions

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)keyboardGesture:(UIGestureRecognizer*)gestureRecognizer {
    // [ä¿®æ­£] æ·»å äºå¯¹è®¾ç½®é¡¹ control.two_finger_keyboard çæ£æ¥
    if (!getPrefBool(@"control.two_finger_keyboard")) {
        return;
    }

    if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
        if (self.inputTextField.isFirstResponder) {
            [self.inputTextField resignFirstResponder];
            self.inputTextField.alpha = 1.0f;
        } else {
            [self.inputTextField becomeFirstResponder];
            self.inputTextField.text = @" ";
        }
    }
}

- (void)sendTouchEvent:(UITouch *)touchEvent withUIEvent:(UIEvent *)uievent withEvent:(int)event
{
    CGPoint locationInView = [touchEvent locationInView:self.rootView];
    switch (event) {
        case ACTION_DOWN:
            self.clickRange = CGRectMake(locationInView.x - 2, locationInView.y - 2, 5, 5);
            self.shouldTriggerClick = YES;
            break;
        case ACTION_MOVE:
            if (self.shouldTriggerClick && !CGRectContainsPoint(self.clickRange, locationInView)) {
                self.shouldTriggerClick = NO;
            }
            break;
    }

    if (touchEvent == self.hotbarTouch && self.slideableHotbar && ![self isTouchInactive:self.hotbarTouch]) {
        CGFloat screenScale = [[UIScreen mainScreen] scale];
        int slot = self.enableHotbarGestures ?
        callback_SurfaceViewController_touchHotbar(locationInView.x * screenScale, locationInView.y * screenScale) : -1;
        if (slot != -1 && currentHotbarSlot != slot && (event == ACTION_DOWN || currentHotbarSlot != -1)) {
            currentHotbarSlot = slot;
            CallbackBridge_nativeSendKey(slot, 0, 1, 0);
            CallbackBridge_nativeSendKey(slot, 0, 0, 0);
            return;
        }
        if (event == ACTION_DOWN && slot == -1) {
            currentHotbarSlot = -1;
        }
        return;
    }

    if (touchEvent == self.primaryTouch) {
        if ([self isTouchInactive:self.primaryTouch] && event != ACTION_UP) return; 
        if (event == ACTION_MOVE && isGrabbing) {
            event = ACTION_MOVE_MOTION;
            CGPoint prevLocationInView = [touchEvent previousLocationInView:self.rootView];
            locationInView.x -= prevLocationInView.x;
            locationInView.y -= prevLocationInView.y;
        }
        [self sendTouchPoint:locationInView withEvent:event];
    }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *press in presses) {
        if (press.key != nil) {
            [KeyboardInput sendKeyEvent:press.key down:YES];
        }
    }
    // Forward to SDL view for MC 26.3 (SDL3 input)
    UIView *sdlView = findSDL_uikitview(self.view);
    if (sdlView) [sdlView pressesBegan:presses withEvent:event];
    // Always call super so that inputTextField (UITextInput) can receive
    // key events for text input (e.g., Minecraft chat).
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *press in presses) {
        if (press.key != nil) {
            [KeyboardInput sendKeyEvent:press.key down:NO];
        }
    }
    // Forward to SDL view for MC 26.3 (SDL3 input)
    UIView *sdlView = findSDL_uikitview(self.view);
    if (sdlView) [sdlView pressesEnded:presses withEvent:event];
    // Always call super so that inputTextField (UITextInput) can receive
    // key-up events properly.
    [super pressesEnded:presses withEvent:event];
}

- (BOOL)prefersPointerLocked {
    return GCMouse.mice.count > 0 && (isGrabbing || virtualMouseEnabled);
}

- (void)registerMouseCallbacks:(GCMouse *)mouse {
    NSLog(@"Input: Got mouse %@", mouse);
    mouse.mouseInput.mouseMovedHandler = ^(GCMouseInput * _Nonnull mouse, float deltaX, float deltaY) {
        // Always forward mouse movement to the game.
        // When pointer is locked (in-game grabbing), deltaX/deltaY are true deltas.
        // When pointer is NOT locked (menu, or Bluetooth mouse before lock activates),
        // we still send the delta so the virtual mouse or cursor can move.
        [self sendTouchPoint:CGPointMake(deltaX, -deltaY) withEvent:ACTION_MOVE_MOTION];
    };

    mouse.mouseInput.leftButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, pressed, 0);
    };
    mouse.mouseInput.middleButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_MIDDLE, pressed, 0);
    };
    mouse.mouseInput.rightButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_RIGHT, pressed, 0);
    };
    for (int i = 0; i < MIN(mouse.mouseInput.auxiliaryButtons.count, 5); i++) {
        mouse.mouseInput.auxiliaryButtons[i].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
            CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_4 + i, pressed, 0);
        };
    }

    mouse.mouseInput.scroll.xAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
        CallbackBridge_nativeSendScroll(value, value);
    };
    mouse.mouseInput.scroll.yAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
        CallbackBridge_nativeSendScroll(-value, -value);
    };

    if (getPrefBool(@"control.hardware_hide")) {
        self.ctrlView.hidden = YES;
    }
}

- (void)surfaceOnClick:(UITapGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateBegan || sender.state == UIGestureRecognizerStateEnded){
        if(self.shouldTriggerHaptic) {
            [self.lightHaptic impactOccurred];
        }
    }
    if (!self.shouldTriggerClick) return;

    if (sender.state == UIGestureRecognizerStateRecognized) {
        if (currentHotbarSlot == -1) {
            if (!self.enableMouseGestures) return;
            CallbackBridge_nativeSendMouseButton(isGrabbing == JNI_TRUE ?
                GLFW_MOUSE_BUTTON_RIGHT : GLFW_MOUSE_BUTTON_LEFT, 1, 0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 33 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                CallbackBridge_nativeSendMouseButton(isGrabbing == JNI_TRUE ?
                    GLFW_MOUSE_BUTTON_RIGHT : GLFW_MOUSE_BUTTON_LEFT, 0, 0);
            });
        } else {
            CallbackBridge_nativeSendKey(currentHotbarSlot, 0, 1, 0);
            CallbackBridge_nativeSendKey(currentHotbarSlot, 0, 0, 0);
        }
    }
}

- (void)surfaceOnDoubleClick:(UITapGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateBegan || sender.state == UIGestureRecognizerStateEnded){
        if(self.shouldTriggerHaptic) {
            [self.lightHaptic impactOccurred];
        }
    }
    if (sender.state == UIGestureRecognizerStateRecognized && isGrabbing) {
        CGFloat screenScale = [[UIScreen mainScreen] scale];
        CGPoint point = [sender locationInView:self.rootView];
        int hotbarSlot = self.enableHotbarGestures ?
            callback_SurfaceViewController_touchHotbar(point.x * screenScale, point.y * screenScale) : -1;
        if (hotbarSlot != -1 && currentHotbarSlot == hotbarSlot) {
            CallbackBridge_nativeSendKey(GLFW_KEY_F, 0, 1, 0);
            CallbackBridge_nativeSendKey(GLFW_KEY_F, 0, 0, 0);
        }
    }
}

- (void)surfaceOnHover:(UIGestureRecognizer *)sender {
    if (isGrabbing) return;
    CGPoint point = [sender locationInView:self.rootView];
    switch (sender.state) {
        case UIGestureRecognizerStateBegan:
            [self sendTouchPoint:point withEvent:ACTION_DOWN];
            break;
        case UIGestureRecognizerStateChanged:
            [self sendTouchPoint:point withEvent:ACTION_MOVE];
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
            [self sendTouchPoint:point withEvent:ACTION_UP];
            break;
        default:
            break;
    }
}

-(void)surfaceOnLongpress:(UILongPressGestureRecognizer *)sender
{
    if (sender.state == UIGestureRecognizerStateBegan || sender.state == UIGestureRecognizerStateEnded){
        if(self.shouldTriggerHaptic) {
            [self.mediumHaptic impactOccurred];
        }
    }

    if (!self.slideableHotbar) {
        CGPoint location = [sender locationInView:self.rootView];
        CGFloat screenScale = UIScreen.mainScreen.scale;
        currentHotbarSlot = self.enableHotbarGestures ?
            callback_SurfaceViewController_touchHotbar(location.x * screenScale, location.y * screenScale) : -1;
    }
    if (sender.state == UIGestureRecognizerStateBegan) {
        self.shouldTriggerClick = NO;
        if (currentHotbarSlot == -1) {

            if (self.enableMouseGestures)
                CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, 1, 0);
        } else {
            CallbackBridge_nativeSendKey(GLFW_KEY_Q, 0, 1, 0);
        }
    } else if (sender.state == UIGestureRecognizerStateChanged) {
    } else if (sender.state == UIGestureRecognizerStateCancelled
        || sender.state == UIGestureRecognizerStateFailed
            || sender.state == UIGestureRecognizerStateEnded)
    {
        if (currentHotbarSlot == -1) {
            if (self.enableMouseGestures)
                CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, 0, 0);
        } else {
            CallbackBridge_nativeSendKey(GLFW_KEY_Q, 0, 0, 0);
        }
    }
}

- (void)surfaceOnTouchesScroll:(UIPanGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateBegan || sender.state == UIGestureRecognizerStateEnded){
        if(self.shouldTriggerHaptic) {
            [self.lightHaptic impactOccurred];
        }
    }

    if (isGrabbing) return;
    if (sender.state == UIGestureRecognizerStateBegan ||
        sender.state == UIGestureRecognizerStateChanged ||
        sender.state == UIGestureRecognizerStateEnded) {
        CGPoint velocity = [sender velocityInView:self.rootView];
        if (velocity.x != 0.0f || velocity.y != 0.0f) {
            CallbackBridge_nativeSendScroll(velocity.x/self.view.frame.size.width, velocity.y/self.view.frame.size.height);
        }
    }
}

#pragma mark - Input view stuff

-(BOOL)textFieldShouldReturn:(UITextField *)textField {
    CallbackBridge_nativeSendKey(GLFW_KEY_ENTER, 0, 1, 0);
    CallbackBridge_nativeSendKey(GLFW_KEY_ENTER, 0, 0, 0);
    textField.text = @" ";
    return YES;
}

#pragma mark - On-screen button functions

- (void)executebtn:(ControlButton *)sender withAction:(int)action {
    int held = action == ACTION_DOWN;
    for (int i = 0; i < 4; i++) {
        int keycode = ((NSNumber *)sender.properties[@"keycodes"][i]).intValue;
        if (keycode < 0) {
            switch (keycode) {
                case SPECIALBTN_KEYBOARD:
                    if (held == 0) {
                        if (self.inputTextField.isFirstResponder) {
                            [self.inputTextField resignFirstResponder];
                            self.inputTextField.alpha = 1.0f;
                        } else {
                            [self.inputTextField becomeFirstResponder];
                            self.inputTextField.text = @" ";
                        }
                    }
                    break;
                case SPECIALBTN_MOUSEPRI:
                    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, held, 0);
                    break;
                case SPECIALBTN_MOUSESEC:
                    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_RIGHT, held, 0);
                    break;
                case SPECIALBTN_MOUSEMID:
                    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_MIDDLE, held, 0);
                    break;
                case SPECIALBTN_TOGGLECTRL:
                    [self executebtn_special_togglebtn:held];
                    break;
                case SPECIALBTN_SCROLLDOWN:
                    if (!held) { CallbackBridge_nativeSendScroll(0.0, 1.0); }
                    break;
                case SPECIALBTN_SCROLLUP:
                    if (!held) { CallbackBridge_nativeSendScroll(0.0, -1.0); }
                    break;
                case SPECIALBTN_VIRTUALMOUSE:
                    if (!isGrabbing && !held) {
                        virtualMouseEnabled = !virtualMouseEnabled;
                        self.mousePointerView.hidden = !virtualMouseEnabled;
                        setPrefBool(@"control.virtmouse_enable", virtualMouseEnabled);
                        [self setNeedsUpdateOfPrefersPointerLocked];
                    }
                    break;
                case SPECIALBTN_MENU:
                    if (!held) { [self actionOpenNavigationMenu]; }
                    break;
                default:
                    NSLog(@"Warning: button %@ sent unknown special keycode: %d", sender.titleLabel.text, keycode);
                    break;
            }
        } else if (keycode > 0) {
            CallbackBridge_nativeSendKey(keycode, 0, held, 0);
            // Task83：按钮键盘打字支持。custom 布局“键盘图标”抽屉里的
            // 字母/数字/符号按钮只发 key 事件，而 MC 1.13+ 聊天框只消费
            // charTyped（text-input）事件 → 此前完全打不了字。按下时补发
            // 字符；Ctrl/Alt 按住时由助手抑制（快捷键语义，组合键不灌字符）。
            if (held) {
                CallbackBridge_buttonKeySynthesizeText(keycode);
            }
        }
    }
}

- (void)executebtn_down:(ControlButton *)sender
{
    if(self.shouldTriggerHaptic) { [self.lightHaptic impactOccurred]; }
    if (sender.savedBackgroundColor == nil) { [self executebtn:sender withAction:ACTION_DOWN]; }
    if ([self.swipeableButtons containsObject:sender]) { self.swipingButton = sender; }
}

- (void)executebtn_swipe:(UIPanGestureRecognizer *)sender
{
    if (sender.state == UIGestureRecognizerStateCancelled || sender.state == UIGestureRecognizerStateEnded) {
        [self executebtn_up:self.swipingButton isOutside:NO];
        return;
    }
    CGPoint location = [sender locationInView:self.ctrlView];
    for (ControlButton *button in self.swipeableButtons) {
        if (CGRectContainsPoint(button.frame, location) && (ControlButton *)self.swipingButton != button) {
            [self executebtn_up:self.swipingButton isOutside:NO];
            self.swipingButton = (ControlButton *)button;
            [self executebtn:self.swipingButton withAction:ACTION_DOWN];
            break;
        }
    }
}

- (void)executebtn_up:(ControlButton *)sender isOutside:(BOOL)isOutside
{
    if (self.swipingButton == sender) {
        [self executebtn:self.swipingButton withAction:ACTION_UP];
        self.swipingButton = nil;
    } else if (sender.savedBackgroundColor == nil) {
        [self executebtn:sender withAction:ACTION_UP];
        return;
    }

    if (isOutside || sender.savedBackgroundColor == nil) { return; }

    sender.isToggleOn = !sender.isToggleOn;
    if (sender.isToggleOn) {
        sender.backgroundColor = [self.view.tintColor colorWithAlphaComponent:CGColorGetAlpha(sender.savedBackgroundColor.CGColor)];
        [self executebtn:sender withAction:ACTION_DOWN];
    } else {
        sender.backgroundColor = sender.savedBackgroundColor;
        [self executebtn:sender withAction:ACTION_UP];
    }

    if(self.shouldTriggerHaptic) { [self.lightHaptic impactOccurred]; }
}

- (void)executebtn_up_inside:(ControlButton *)sender { [self executebtn_up:sender isOutside:NO]; }
- (void)executebtn_up_outside:(ControlButton *)sender { [self executebtn_up:sender isOutside:YES]; }

- (void)executebtn_special_togglebtn:(int)held {
    if (held) return;
    self.toggleHidden = !self.toggleHidden;
    [self updateControlHiddenState:self.toggleHidden];
}

#pragma mark - Input: On-screen touch events (TouchController Mod Integration)

static int32_t s_fingerIdCounter = 0;
static NSMutableDictionary *s_touchToFingerIdMap = nil;

- (int32_t)getFingerId:(UITouch *)touch {
    // Lazy initialize the map
    if (!s_touchToFingerIdMap) {
        s_touchToFingerIdMap = [NSMutableDictionary dictionary];
    }
    
    // Use touch pointer address as key (UITouch doesn't support NSCopying)
    NSString *touchKey = [NSString stringWithFormat:@"%p", touch];
    
    // Check if we already have a finger ID for this touch
    NSNumber *fingerIdNum = [s_touchToFingerIdMap objectForKey:touchKey];
    if (fingerIdNum) {
        return [fingerIdNum intValue];
    }
    
    // Generate a new unique finger ID
    s_fingerIdCounter = (s_fingerIdCounter + 1) % 100000;
    int32_t newFingerId = s_fingerIdCounter;
    
    // Store the mapping
    [s_touchToFingerIdMap setObject:@(newFingerId) forKey:touchKey];
    
    return newFingerId;
}

// Clear the touch to finger ID map when touches end
- (void)clearTouchToFingerIdMapForTouches:(NSSet *)touches {
    if (!s_touchToFingerIdMap) return;
    
    for (UITouch *touch in touches) {
        NSString *touchKey = [NSString stringWithFormat:@"%p", touch];
        [s_touchToFingerIdMap removeObjectForKey:touchKey];
    }
}

// Clear all touch to finger ID mappings
- (void)clearAllTouchToFingerIdMappings {
    if (s_touchToFingerIdMap) {
        [s_touchToFingerIdMap removeAllObjects];
    }
}

// Find the embedded SDL_uikitview (MC 26.3 uses SDL3 for input).
static UIView *findSDL_uikitview(UIView *root) {
    static Class sdlCls = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ sdlCls = NSClassFromString(@"SDL_uikitview"); });
    if (!sdlCls) return nil;
    if ([root isKindOfClass:sdlCls]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = findSDL_uikitview(sub);
        if (found) return found;
    }
    return nil;
}

#pragma mark - SDL3 渲染层（MC 26.3+ OpenGL 后端黑屏修复）

// libSDL3 的嵌入逻辑（Amethyst_EmbedSDLViewIntoHostWindow）在把 SDL 视图挂进
// 启动器层级时，会执行 gameSurface.hidden = YES —— gameSurface 就是从
// rootViewController 往下找到的第一个 GameSurfaceView，也就是 self.surfaceView
// （= pojavWindow = +[SurfaceViewController surface]）。
//
// 这对 Vulkan 后端是正确的（它走 SDL 自带的 metalview 呈现），但对 OpenGL 后端
// 是致命的：gl_bridge 的 gl_init_context() 把 EGL surface 绑在
// SurfaceViewController.surface.layer 上，宿主 view 一隐藏，ANGLE 渲染出来的画面
// 就无处呈现 —— 表现为画面全黑，而输入、声音、资源加载全部正常。
//
// 下面两个函数供 gl_bridge 在建 EGL surface 前调用。它们都只在能找到
// SDL_uikitview 时才动作，因此 GLFW 路径（1.21.1 及更低版本）完全不受影响：
// 那里根本没有 SDL 视图，函数直接返回 NO / nil，gl_bridge 沿用原逻辑。

// 找到当前嵌入的 SDL 视图；非 SDL3 路径返回 nil。
static UIView *Amethyst_FindSDLView(void) {
    UIWindow *host = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive ||
                ![scene isKindOfClass:UIWindowScene.class]) {
                continue;
            }
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (!w.hidden && w.rootViewController != nil) { host = w; break; }
            }
            if (host) break;
        }
    }
    if (!host) host = UIApplication.sharedApplication.keyWindow;

    UIView *root = host.rootViewController.view;
    if (!root && pojavWindow != nil) root = pojavWindow.window.rootViewController.view;
    if (!root) return nil;
    return findSDL_uikitview(root);
}

// 供 egl_bridge 的呈现层卫兵使用（Amethyst_FindSDLView 是文件内 static）。
// 非 SDL3 路径返回 nil。
UIView *Amethyst_FindEmbeddedSDLView(void) {
    return Amethyst_FindSDLView();
}

#pragma mark - SDL3 黑屏：让 SDL 嵌入视图透明

// 现象：输入、声音、资源加载与渲染全部正常（MG 甚至打出 First frame
// rendered），但屏幕全黑；且调整分辨率无效 —— 因为分辨率既改不了 z 序，
// 也改不了不透明。
//
// 成因：SDL3 的嵌入逻辑（预编译 libSDL3.dylib 内）在每次真实
// SDL_CreateWindow 后把自己 re-front 到最前（日志 "ShowWindow: re-fronting
// embedded view"）。该视图内部的 SDL_uikitmetalview 的 CAMetalLayer 默认
// opaque=1，于是一整块不透明黑层盖在 GameSurfaceView 之上。
//
// Air（Task 52）把这层设成透明，前提是它能从源码构建 SDL。本仓库不能改
// SDL 源码，但可以在运行时拿到这个 UIView 实例直接设属性 —— 改不了源码
// 不等于改不了实例。
//
// 刻意不做的事：
//   * 不动 alpha（保持触摸命中，SDL 视图在最前正是输入正常的原因）；
//   * 不重排 z 序（周期性 bringSubviewToFront 会盖住虚拟鼠标与控制按钮）。
// 只处理根视图与 CAMetalLayer 子视图，避免误伤 SDL 的文本输入等子视图。

// 回退开关：AMETHYST_KEEP_SDL_METAL=1 时保留 SDL 的金属子层（仅透明化，
// 不隐藏）。默认隐藏 —— EGL 路径下真正的呈现面是 GameSurfaceView 的
// CAMetalLayer，SDL 的金属层不是渲染目标，留着只会整块盖住画面。
static BOOL ame_keepSDLMetalLayer(void) {
    static int cached = -1;
    if (cached < 0) {
        const char *e = getenv("AMETHYST_KEEP_SDL_METAL");
        cached = (e != NULL && atoi(e) == 1) ? 1 : 0;
    }
    return cached == 1;
}

static BOOL ame_applyTransparentRecursive(UIView *v, BOOL isRoot) {
    if (v == nil) return NO;
    BOOL changed = NO;
    BOOL isMetal = [v.layer isKindOfClass:CAMetalLayer.class];
    if (isRoot || isMetal) {
        if (v.opaque) { v.opaque = NO; changed = YES; }
        if (v.layer.opaque) { v.layer.opaque = NO; changed = YES; }
        if (v.backgroundColor != nil &&
            CGColorGetAlpha(v.backgroundColor.CGColor) > 0.0) {
            v.backgroundColor = UIColor.clearColor;
            changed = YES;
        }
    }
    // 预编译 libSDL3.dylib 在 SDL 视图内额外建了 SDL_uikitmetalview 子层
    //（Air 从源码构建 SDL3，不存在这层）。它的 CAMetalLayer 默认 opaque=1
    // 且 drawableSize 为全屏像素：即便把 opaque 置 NO，只要有内容仍会整块
    // 盖住画面。EGL 路径下它不是渲染目标，直接移出合成最稳妥（可用
    // AMETHYST_KEEP_SDL_METAL=1 回退为仅透明化）。
    if (isMetal && !isRoot && !ame_keepSDLMetalLayer()) {
        if (!v.hidden) { v.hidden = YES; changed = YES; }
    }
    for (UIView *sub in v.subviews) {
        if (ame_applyTransparentRecursive(sub, NO)) changed = YES;
    }
    return changed;
}

BOOL Amethyst_MakeSDLRenderTransparent(void) {
    UIView *sdl = Amethyst_FindSDLView();
    if (sdl == nil) return NO;                 // 非 SDL3 路径：不改动任何状态
    return ame_applyTransparentRecursive(sdl, YES);
}

// Air Task 32（黑屏根治）+ Task 52（呈现面被隐藏的根治）。
//
// 黑屏的两个遮挡源，缺一不可：
//   (a) SDL 自己的 UIWindow：原生 SDL3 的 UIKit_ShowWindow 会对它
//       makeKeyAndVisible。它是一个独立的 UIWindow，浮在整个宿主窗口之上——
//       touchView 内部的 z 序再怎么排也救不了。Air 原话：“原生
//       makeKeyAndVisible 的空窗口会盖住 GameSurfaceView = 黑屏”。
//   (b) 供应商 libSDL3.dylib 的 Zalith 同源嵌入补丁（反汇编实锤 @0x152e6c）
//       按类名找到 GameSurfaceView 并执行 [GameSurfaceView setHidden:YES]
//       （Zalith 架构里 SDL 的 metal view 才是渲染目标）。但本启动器 GL 与
//       Vulkan 的渲染目标恰恰是 GameSurfaceView 的 CAMetalLayer：帧全部呈现
//       进一个被隐藏的 layer = 渲染指标全绿 + 永久黑屏。该 NSLog 是真 NSLog，
//       在 latestlog 里完全不可见，所以此前无从察觉。
//
// 必须周期性重跑：每次真实 SDL_CreateWindow / SDL_ShowWindow 都可能复发。
// 一次性诊断：把「谁在谁上面」完整 dump 出来。
// 黑屏已反复猜测多轮，这里把决定性事实一次打全：
//   * 所有 UIWindow（含 SDL 自建空窗 —— 空窗浮在宿主之上就是整块黑盖子）
//   * 呈现面 GameSurfaceView 与 SDL 嵌入视图的可见性 / 不透明 / 几何 / z 序
// 只在检测到异常时打印，且总预算有限，避免高频执法刷屏。
static void ame_dumpPresentationState(const char *reason) {
    static int budget = 6;
    if (budget <= 0) return;
    budget--;

    NSMutableString *m = [NSMutableString string];
    [m appendFormat:@"[Amethyst][diag] presentation dump (%s)\n", reason];

    NSArray *wins = [UIApplication sharedApplication].windows;
    [m appendFormat:@"  windows=%lu\n", (unsigned long)wins.count];
    for (UIWindow *w in wins) {
        [m appendFormat:@"    win=%@ rc=%@ hidden=%d level=%.0f key=%d frame=%@\n",
            NSStringFromClass(w.class),
            w.rootViewController ? NSStringFromClass(w.rootViewController.class) : @"(nil)",
            (int)w.hidden, w.windowLevel, (int)w.isKeyWindow,
            NSStringFromCGRect(w.frame)];
    }

    UIView *gs = pojavWindow;
    if (gs) {
        CALayer *l = gs.layer;
        NSString *ds = @"(n/a)";
        if ([l isKindOfClass:CAMetalLayer.class]) {
            CGSize sz = ((CAMetalLayer *)l).drawableSize;
            ds = [NSString stringWithFormat:@"%.0fx%.0f", sz.width, sz.height];
        }
        [m appendFormat:@"  gameSurface=%@ hidden=%d layerHidden=%d layer=%@ layerOpaque=%d "
                        @"scale=%.2f drawable=%@ frame=%@ window=%@\n",
            NSStringFromClass(gs.class), (int)gs.hidden, (int)l.hidden,
            NSStringFromClass(l.class), (int)l.opaque, l.contentsScale, ds,
            NSStringFromCGRect(gs.frame),
            gs.window ? NSStringFromClass(gs.window.class) : @"(nil)"];
    } else {
        [m appendString:@"  gameSurface=(nil)\n"];
    }

    UIView *sdl = Amethyst_FindSDLView();
    if (sdl) {
        CALayer *l = sdl.layer;
        NSString *ds = @"(n/a)";
        if ([l isKindOfClass:CAMetalLayer.class]) {
            CGSize sz = ((CAMetalLayer *)l).drawableSize;
            ds = [NSString stringWithFormat:@"%.0fx%.0f", sz.width, sz.height];
        }
        [m appendFormat:@"  sdlView=%@ hidden=%d opaque=%d layer=%@ layerOpaque=%d "
                        @"scale=%.2f drawable=%@ frame=%@ window=%@\n",
            NSStringFromClass(sdl.class), (int)sdl.hidden, (int)sdl.opaque,
            NSStringFromClass(l.class), (int)l.opaque, l.contentsScale, ds,
            NSStringFromCGRect(sdl.frame),
            sdl.window ? NSStringFromClass(sdl.window.class) : @"(nil)"];
    } else {
        [m appendString:@"  sdlView=(not found)\n"];
    }

    UIView *container = gs ? gs.superview : nil;
    if (container) {
        NSMutableArray *order = [NSMutableArray array];
        for (UIView *v in container.subviews) {
            [order addObject:[NSString stringWithFormat:@"%@(h=%d,op=%d,lo=%d)",
                NSStringFromClass(v.class), (int)v.hidden, (int)v.opaque, (int)v.layer.opaque]];
        }
        [m appendFormat:@"  container=%@ subviews(bottom->top)=%@\n",
            NSStringFromClass(container.class),
            [order componentsJoinedByString:@" | "]];
    }
    NSLog(@"%@", m);
}

// Air Task 32（空窗黑盖子）+ Task 52（呈现面被隐藏）+ SDL 层不透明。
//
// 三个遮挡源，任何一处漏掉都还是黑：
//   (a) SDL 自建 UIWindow：原生 UIKit_ShowWindow 会对它 makeKeyAndVisible。
//       它是独立 UIWindow，浮在整个宿主窗口之上 —— touchView 内部 z 序再怎么
//       排都救不了。每次真实建窗都会重演，故必须周期性执法。
//   (b) 供应商 libSDL3.dylib 的 Zalith 同源嵌入补丁按类名找到 GameSurfaceView
//       并 setHidden:YES。但 GL/Vulkan 的真正呈现面正是它的 CAMetalLayer。
//   (c) SDL 嵌入视图的 CAMetalLayer 默认 opaque=1，整块盖住画面。
//
// 安全保障（不引入新 bug 的优先级高于修好黑屏）：
//   * 只在确认存在另一个可见宿主 window 时才隐藏 SDL window —— 绝不把
//     唯一可见窗口藏掉；
//   * z 序调整前先确认 SDL 的 layer 已真正透明，否则宁可维持现状
//     （画面层在上）也不下压 —— 下压到不透明层下面只会更黑；
//   * 全程 @try，任何异常都吞掉并记录，不影响游戏进程。
BOOL Amethyst_EnforceSDL3Presentation(void) {
    if (pojavWindow == nil) return NO;
    UIView *gs = pojavWindow;
    UIView *sdlView = Amethyst_FindSDLView();
    UIView *container = gs.superview;
    if (container == nil) return NO;

    @try {
        BOOL fixed = NO;

        // 1) SDL 自建 UIWindow 永远隐藏，并把 key window 还给宿主。
        //    安全条件：必须存在另一个可见的、非 SDL 的 window 才动手。
        NSArray *allWindows = [UIApplication sharedApplication].windows;
        for (UIWindow *w in allWindows) {
            UIViewController *rc = w.rootViewController;
            if (rc == nil) continue;
            if ([NSStringFromClass(rc.class) rangeOfString:@"SDL_uikitviewcontroller"]
                    .location == NSNotFound) continue;
            if (w.hidden) continue;

            // 安全：确认有替身 host window 可见，且该 host 不是 SDL 自己的
            UIWindow *hostWin = nil;
            for (UIWindow *w2 in allWindows) {
                if (w2 == w || w2.hidden || w2.rootViewController == nil) continue;
                if ([NSStringFromClass(w2.rootViewController.class) rangeOfString:
                        @"SDL_uikitviewcontroller"].location != NSNotFound) continue;
                hostWin = w2;
                break;
            }
            if (hostWin == nil) {
                ame_dumpPresentationState("SDL window found but NO host window to fall back");
                continue;   // 绝不把唯一可见窗口藏掉
            }

            w.hidden = YES;
            [hostWin makeKeyWindow];
            fixed = YES;
            NSLog(@"[Amethyst] Task32: SDL UIWindow re-hidden (empty key+visible window "
                  @"covers GameSurfaceView = black screen); host key window restored");
            ame_dumpPresentationState("SDL own UIWindow was visible (black cover)");
        }

        // 2) 揭开真正的渲染呈现面。
        if (gs.hidden || gs.layer.hidden) {
            gs.hidden = NO;
            gs.layer.hidden = NO;
            fixed = YES;
            NSLog(@"[Amethyst] Task52: GameSurfaceView was HIDDEN by SDL provider embed "
                  @"patch -- UN-HIDDEN (it is our render target)");
            ame_dumpPresentationState("GameSurfaceView was hidden");
        }

        // 3) Air Task 52 原样（参考仓库 Natives/sdl3_hook.m:1050-1051）：
        //    sdlView.backgroundColor = nil; sdlView.opaque = NO;
        //    上一版误判「Air 全仓库不存在透明化代码」，据此把透明化删掉、只留
        //    z 序下压 —— 画面被压到 opaque=1 的全屏金属层之下，等于亲手制造
        //    黑屏。Air 的透明化确实存在（在 sdl3_hook.m 而非 gl_bridge.m），
        //    此处按原样恢复。
        if (sdlView != nil) {
            if (sdlView.opaque) { sdlView.opaque = NO; fixed = YES; }
            if (sdlView.layer.opaque) { sdlView.layer.opaque = NO; fixed = YES; }
            if (sdlView.backgroundColor != nil) {
                sdlView.backgroundColor = nil;
                fixed = YES;
            }
            // 递归处理预编译 SDL 额外建出的金属子层（并令其退出合成）。
            if (Amethyst_MakeSDLRenderTransparent()) fixed = YES;
        }

        // 4. z 序终局（Air Task 52 原样）：其它子视图（虚拟鼠标指针、控制按钮）
        //    压回 SDL 视图之上，GameSurfaceView 紧贴 SDL 触摸视图之下 ——
        //    画面在下、触摸层在上，靠 SDL 视图透明透出画面。
        if (sdlView != nil && sdlView.superview == container) {
            for (UIView *sub in [container.subviews copy]) {
                if (sub != sdlView && sub != gs) [container bringSubviewToFront:sub];
            }
            NSArray *subs = container.subviews;
            NSUInteger gi = [subs indexOfObjectIdenticalTo:gs];
            NSUInteger si = [subs indexOfObjectIdenticalTo:sdlView];
            if (gi != NSNotFound && si != NSNotFound && gi > si) {
                [container insertSubview:gs belowSubview:sdlView];
                NSLog(@"[Amethyst] Task52: GameSurfaceView pinned BELOW SDL touch view "
                      @"(Air Task52: SDL view transparent, frame shows through)");
            }
        }

        return fixed;
    } @catch (NSException *e) {
        NSLog(@"[Amethyst] Task32/52 enforcement exception: %@", e);
        return NO;
    }
}

// 补救方式 (1)（默认）：保持 EGL 绑在 GameSurfaceView 上，仅取消隐藏。
// 分辨率沿用启动器配置的 drawableSize / contentsScale。
// z 序 / SDL 自有 UIWindow 交由 Amethyst_EnforceSDL3Presentation 按 Air 排布处理。
// 返回 YES 表示确实执行了补救（即当前是 SDL3 路径）。
BOOL Amethyst_RestoreGameSurfaceVisibility(void) {
    if (pojavWindow == nil) return NO;
    UIView *sdlView = Amethyst_FindSDLView();
    if (!sdlView) return NO;                 // 非 SDL3 路径：不改动任何状态
    UIView *container = pojavWindow.superview;
    if (!container) return NO;

    pojavWindow.hidden = NO;
    // 不再 bringSubviewToFront：Air 的排布是画面层紧贴 SDL 触摸视图「之下」，
    // 由 Amethyst_EnforceSDL3Presentation 统一执法（SDL 视图已透明）。

    // SDL 嵌入后宿主 view 的 frame 可能被改写/缩小，使其只占屏幕一角，画面于是
    // 缩在左下角并伴随大面积黑边。按启动器已算好的 windowWidth/Height 反推 frame：
    //     windowWidth  = frame.width * screenScale * resolutionScale
    //     contentsScale = screenScale * resolutionScale
    //   => frame.width  = windowWidth / contentsScale
    // 该结果恒等于全屏逻辑尺寸（与分辨率缩放无关），因此无论用户把分辨率设为
    // 多少，view 都铺满屏幕，缩放只体现在渲染像素数上。
    CGFloat hostScale = pojavWindow.layer.contentsScale;
    if (hostScale > 0.0 && windowWidth > 0 && windowHeight > 0) {
        CGSize want = CGSizeMake((CGFloat)windowWidth / hostScale,
                                 (CGFloat)windowHeight / hostScale);
        CGSize cur = pojavWindow.bounds.size;
        if (fabs(cur.width - want.width) > 1.0 || fabs(cur.height - want.height) > 1.0) {
            CGRect f = pojavWindow.frame;
            f.size = want;
            pojavWindow.frame = f;
            NSLog(@"[SurfaceVC] SDL3 path: GameSurfaceView frame corrected "
                  @"%.0fx%.0f -> %.0fx%.0f (scale %.2f -> surface %.0fx%.0f, "
                  @"drawableSize %dx%d)",
                  cur.width, cur.height, want.width, want.height, hostScale,
                  want.width * hostScale, want.height * hostScale,
                  windowWidth, windowHeight);
        }
    }

    // 关键：hidden 期间 UIKit 可能跳过了布局，bounds 仍为 0。
    // gl_bridge 用 layer.bounds * contentsScale 推算 EGLSurface 像素尺寸，
    // bounds 为 0 会建出 1x1 的 surface（画面全黑且不可自愈，因为 surface
    // 只创建一次）。这里强制补一次布局，让 gl_bridge 取到真实尺寸。
    [pojavWindow setNeedsLayout];
    [pojavWindow layoutIfNeeded];
    [container setNeedsLayout];
    [container layoutIfNeeded];

    CGSize bs = pojavWindow.bounds.size;
    CGFloat scale = pojavWindow.layer.contentsScale;
    NSLog(@"[SurfaceVC] SDL3 path: GameSurfaceView unhidden "
          @"(bounds=%.0fx%.0f scale=%.2f -> px %.0fx%.0f)",
          bs.width, bs.height, scale, bs.width * scale, bs.height * scale);
    if (bs.width < 1.0 || bs.height < 1.0) {
        NSLog(@"[SurfaceVC] WARNING: GameSurfaceView bounds still zero after layout; "
              @"gl_bridge will fall back to drawableSize/screen");
    }
    // 隐藏 SDL 自有 UIWindow + 揭开渲染层 + SDL 视图透明 + z 序钉扎（Air Task 32/52）
    (void)Amethyst_EnforceSDL3Presentation();
    return YES;
}

// 补救方式 (2)（AMETHYST_EGL_SURFACE_LAYER=sdl）：直接给出 SDL 自己的可见
// CAMetalLayer，让 EGL surface 绑到它上面。非 SDL3 路径返回 nil。
CALayer *Amethyst_SDL3RenderLayer(void) {
    UIView *sdlView = Amethyst_FindSDLView();
    if (!sdlView) return nil;
    // SDL 的实际呈现层是嵌在 SDL_uikitview 里的 SDL_uikitmetalview
    Class metalCls = NSClassFromString(@"SDL_uikitmetalview");
    if (metalCls) {
        for (UIView *sub in sdlView.subviews) {
            if ([sub isKindOfClass:metalCls]) {
                return sub.layer;
            }
        }
    }
    return sdlView.layer;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{

    [super touchesBegan:touches withEvent:event];

    if (getPrefBool(@"control.mod_touch_enable")) {
        NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];

        if (mode == 1) {  // UDP æ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;

                CGPoint p = [touch locationInView:self.surfaceView];
                float x = p.x / self.surfaceView.frame.size.width;
                float y = p.y / self.surfaceView.frame.size.height;
                // Send Type 1 (Add Pointer)
                [self.touchSender sendType:1 id:[self getFingerId:touch] x:x y:y];
            }
        } else if (mode == 2) {  // éæåºæ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;

                CGPoint p = [touch locationInView:self.surfaceView];
                float x = p.x / self.surfaceView.frame.size.width;
                float y = p.y / self.surfaceView.frame.size.height;
                // Send ProxyMessage: AddPointerMessage
                [self sendTouchControllerProxyMessage:[self getFingerId:touch] x:x y:y isRemove:NO];
            }
        }

        if (isGrabbing == JNI_TRUE) return;
    }


    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypeIndirectPointer) continue;
        CGPoint locationInView = [touch locationInView:self.rootView];
        CGFloat screenScale = [[UIScreen mainScreen] scale];
        currentHotbarSlot = self.enableHotbarGestures ?
            callback_SurfaceViewController_touchHotbar(locationInView.x * screenScale, locationInView.y * screenScale) : -1;
        if ([self isTouchInactive:self.hotbarTouch] && currentHotbarSlot != -1) {
            self.hotbarTouch = touch;
        }
        if ([self isTouchInactive:self.primaryTouch] && currentHotbarSlot == -1) {
            self.primaryTouch = touch;
        }
        [self sendTouchEvent:touch withUIEvent:event withEvent:ACTION_DOWN];
    }
    // NOTE: Touches are NOT forwarded to SDL_uikitview here.
    // Our input_bridge_v3.m handles all mouse injection via SDL_PushEvent.
    // Forwarding to SDL_uikitview would cause duplicate SDL_FINGER + mouse events
    // (SDL internally converts touch→mouse), resulting in hitbox mismatch.
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
    if (getPrefBool(@"control.mod_touch_enable")) {
        NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];

        if (mode == 1) {  // UDP æ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;

                CGPoint p = [touch locationInView:self.surfaceView];
                float x = p.x / self.surfaceView.frame.size.width;
                float y = p.y / self.surfaceView.frame.size.height;
                // Send Type 1 (Move Pointer)
                [self.touchSender sendType:1 id:[self getFingerId:touch] x:x y:y];
            }
        } else if (mode == 2) {  // éæåºæ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;

                CGPoint p = [touch locationInView:self.surfaceView];
                float x = p.x / self.surfaceView.frame.size.width;
                float y = p.y / self.surfaceView.frame.size.height;
                // Send ProxyMessage: AddPointerMessage (Move is also Add with new position)
                [self sendTouchControllerProxyMessage:[self getFingerId:touch] x:x y:y isRemove:NO];
            }
        }

        if (isGrabbing == JNI_TRUE) return;
    }

    [super touchesMoved:touches withEvent:event];

    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypeIndirectPointer) {
            if (!isGrabbing && !virtualMouseEnabled) {
                CGPoint point = [touch locationInView:self.rootView];
                [self sendTouchPoint:point withEvent:ACTION_MOVE];
            }
            continue;
        }
        if (self.hotbarTouch != touch && [self isTouchInactive:self.primaryTouch]) {
            self.primaryTouch = touch;
            [self sendTouchEvent:touch withUIEvent:event withEvent:ACTION_DOWN];
        }
        [self sendTouchEvent:touch withUIEvent:event withEvent:ACTION_MOVE];
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
    if (getPrefBool(@"control.mod_touch_enable")) {
        NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];

        if (mode == 1) {  // UDP æ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;
                // Send Type 2 (Remove Pointer) for surfaceView touch ending
                [self.touchSender sendType:2 id:[self getFingerId:touch] x:0 y:0];
            }
        } else if (mode == 2) {  // éæåºæ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;
                // Send ProxyMessage: RemovePointerMessage
                [self sendTouchControllerProxyMessage:[self getFingerId:touch] x:0 y:0 isRemove:YES];
            }
        }

        // Clear the touch to finger ID map for ended touches
        [self clearTouchToFingerIdMapForTouches:touches];

        if (isGrabbing == JNI_TRUE) return;
    }

    [super touchesEnded:touches withEvent:event];
    [self touchesEndedGlobal:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
    if (getPrefBool(@"control.mod_touch_enable")) {
        NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];

        if (mode == 1) {  // UDP æ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;
                [self.touchSender sendType:2 id:[self getFingerId:touch] x:0 y:0];
            }
        } else if (mode == 2) {  // éæåºæ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;
                [self sendTouchControllerProxyMessage:[self getFingerId:touch] x:0 y:0 isRemove:YES];
            }
        }

        // Clear the touch to finger ID map for cancelled touches
        [self clearTouchToFingerIdMapForTouches:touches];

        if (isGrabbing == JNI_TRUE) return;
    }

    [super touchesCancelled:touches withEvent:event];
    [self touchesEndedGlobal:touches withEvent:event];
}

- (void)touchesEndedGlobal:(NSSet *)touches withEvent:(UIEvent *)event
{
    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypeIndirectPointer) {
            continue;
        }
        [self sendTouchEvent:touch withUIEvent:event withEvent:ACTION_UP];
    }
}

+ (BOOL)isRunning {
    return [self currentInstance] != nil;
}

+ (instancetype)currentInstance {
    UIViewController *rootVC = UIWindow.mainWindow.rootViewController;
    // 情况1：rootViewController 就是 SurfaceViewController
    if ([rootVC isKindOfClass:[SurfaceViewController class]]) {
        return (SurfaceViewController *)rootVC;
    }
    // 情况2：SurfaceViewController 以模态方式呈现
    UIViewController *presentedVC = rootVC.presentedViewController;
    if ([presentedVC isKindOfClass:[SurfaceViewController class]]) {
        return (SurfaceViewController *)presentedVC;
    }
    return nil;
}

+ (GameSurfaceView *)surface {
    return pojavWindow;
}

#pragma mark - FPS/内存监控（参照 FCL egl_bridge.c 与 ZL2 MemoryUtils.kt）

- (void)updateGameStats {
    // 1. 读取 native swap buffer 计数器并重置（参照 FCL CallbackBridge.getFps()）
    // pojavGetAndResetFps() 返回自上次调用以来的渲染帧数
    // 采样间隔 1 秒（statsTimer 已改为 1s），所以返回值即为 FPS
    NSInteger fps = (NSInteger)pojavGetAndResetFps();

    // 2. 获取内存占用（phys_footprint）
    // 使用 task_vm_info 的 phys_footprint 字段，这是 iOS 上最准确的进程内存占用指标
    // 包含常驻内存、压缩内存、GPU 内存（UMA 架构下），与 Xcode 内存表盘一致
    // 参照 ZL2 MemoryUtils.kt 的系统级内存统计理念，在 iOS 上用 phys_footprint 等价
    double memoryMB = [self currentPhysFootprintMB];

    // 3. 更新 UI（GameMenuOverlayView 内部会 dispatch 到主线程）
    if ([self.gameMenuOverlay isKindOfClass:[GameMenuOverlayView class]]) {
        [(GameMenuOverlayView *)self.gameMenuOverlay updateFPS:fps memoryUsageMB:memoryMB];
    }
}

- (double)currentPhysFootprintMB {
    // 使用 TASK_VM_INFO flavor 读取 phys_footprint
    // phys_footprint 是 Apple 推荐的进程内存占用指标，包含：
    // - 常驻物理内存（resident_size）
    // - 压缩内存
    // - GPU 内存（iOS UMA 架构下 Metal 缓冲区映射到进程地址空间）
    // 减去通过 mmap 共享的部分，与 Xcode/Memory Graph 显示的值一致
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO,
                                 (task_info_t)&vmInfo, &count);
    if (kr != KERN_SUCCESS) {
        return 0.0;
    }
    // phys_footprint 单位是字节
    return (double)vmInfo.phys_footprint / (1024.0 * 1024.0);
}

- (void)dealloc {
    // 停止 FPS/内存采样定时器与渲染循环
    [self.statsTimer invalidate];
    self.statsTimer = nil;
    [self.statsDisplayLink invalidate];
    self.statsDisplayLink = nil;
    self.statsDisplayLinkTarget = nil;  // 释放 CADisplayLink target

    // 清理启动遮罩层资源
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"PojavFirstFrameRendered" object:nil];
    self.launchOverlayView = nil;
    self.launchGradientLayer = nil;

    // 关键修复（UI 累积异常）：移除 5 个块式通知观察者。
    // 之前只移除了 PojavFirstFrameRendered，未移除以下 5 个块观察者，
    // 导致每次进出游戏都泄漏 5 个观察者 + 5 条对 self 的强引用，
    // 多次进出后多个"已释放"的 VC 同时收到通知操作 UI，造成 UI 行为错乱。
    // 块观察者必须通过 removeObserver: 显式移除（removeObserver:self 无效）。
    id defaultCenter = [NSNotificationCenter defaultCenter];
    if (self.mousePointerUpdatedCallback) {
        [defaultCenter removeObserver:self.mousePointerUpdatedCallback];
        self.mousePointerUpdatedCallback = nil;
    }
    if (self.mouseConnectCallback) {
        [defaultCenter removeObserver:self.mouseConnectCallback];
        self.mouseConnectCallback = nil;
    }
    if (self.mouseDisconnectCallback) {
        [defaultCenter removeObserver:self.mouseDisconnectCallback];
        self.mouseDisconnectCallback = nil;
    }
    if (self.controllerConnectCallback) {
        [defaultCenter removeObserver:self.controllerConnectCallback];
        self.controllerConnectCallback = nil;
    }
    if (self.controllerDisconnectCallback) {
        [defaultCenter removeObserver:self.controllerDisconnectCallback];
        self.controllerDisconnectCallback = nil;
    }

    // LAN 端口检测器已改为手动输入模式，stopDetecting 已移除，无需调用。
    // ZeroTier/Terracotta 联机暂时移除：原 stopAllMultiplayerServices 调用注释掉
    // [[MultiplayerManager sharedManager] stopAllMultiplayerServices];

    //æ¸ç TouchController èµæº
    if (self.touchControllerTransportHandle >= 0) {
        [TouchControllerBridge destroyTransport:self.touchControllerTransportHandle];
        self.touchControllerTransportHandle = -1;
    }
}

@end
