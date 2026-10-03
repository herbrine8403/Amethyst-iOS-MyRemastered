#import "customcontrols/ControlLayout.h"
#import "customcontrols/CustomControlsUtils.h"
#import "JavaGUIViewController.h"
#import "JavaLauncher.h"
#import "PLCrashView.h"
#import "LauncherPreferences.h"
#import "PLLogOutputView.h"
#import "TrackedTextField.h"
#import "UnzipKit.h"
#import "ios_uikit_bridge.h"
#import "BackgroundManager.h"
#include "glfw_keycodes.h"
#include "utils.h"

#define SPECIALBTN_LOGOUTPUT -100

static BOOL shouldHitEnterAfterWindowShown;
static SurfaceView* surfaceView;

static jclass class_CTCAndroidInput;
static jmethodID method_ReceiveInput;

void AWTInputBridge_nativeSendData(int type, int i1, int i2, int i3, int i4) {
    if (!runtimeJNIEnvPtr) {
        return;
    }

    if (!method_ReceiveInput) {
        class_CTCAndroidInput = (*runtimeJNIEnvPtr)->FindClass(runtimeJNIEnvPtr, "net/java/openjdk/cacio/ctc/CTCAndroidInput");
        if ((*runtimeJNIEnvPtr)->ExceptionCheck(runtimeJNIEnvPtr) == JNI_TRUE) {
            (*runtimeJNIEnvPtr)->ExceptionClear(runtimeJNIEnvPtr);
            class_CTCAndroidInput = (*runtimeJNIEnvPtr)->FindClass(runtimeJNIEnvPtr, "com/github/caciocavallosilano/cacio/ctc/CTCAndroidInput");
        }
        assert(class_CTCAndroidInput != NULL);
        method_ReceiveInput = (*runtimeJNIEnvPtr)->GetStaticMethodID(runtimeJNIEnvPtr, class_CTCAndroidInput, "receiveData", "(IIIII)V");
        assert(method_ReceiveInput != NULL);
    }

    (*runtimeJNIEnvPtr)->CallStaticVoidMethod(
        runtimeJNIEnvPtr,
        class_CTCAndroidInput,
        method_ReceiveInput,
        type, i1, i2, i3, i4
    );
}

void AWTInputBridge_sendChar(jchar keychar) {
    AWTInputBridge_nativeSendData(EVENT_TYPE_CHAR, (unsigned int)keychar, 0, 0, 0);
}

void AWTInputBridge_sendKey(int keycode) {
    // TODO: iOS -> AWT keycode mapping
    AWTInputBridge_nativeSendData(EVENT_TYPE_KEY, ' ', keycode, 1, 0);
    AWTInputBridge_nativeSendData(EVENT_TYPE_KEY, ' ', keycode, 0, 0);
}

@interface SurfaceView() {
    JNIEnv *surfaceJNIEnv;
    jclass class_CTCScreen;
    jmethodID method_GetRGB;
    int *rgbArray; 
}
@property(nonatomic) CGColorSpaceRef colorSpace;
@end

@implementation SurfaceView
- (void)refreshBuffer {
    if (!runtimeJavaVMPtr) {
        // JVM is not ready yet
        return;
    } else if (!surfaceJNIEnv) {
        // Obtain JNIEnvs
        (*runtimeJavaVMPtr)->AttachCurrentThread(runtimeJavaVMPtr, &surfaceJNIEnv, NULL);
        assert(surfaceJNIEnv);
        dispatch_async(dispatch_get_main_queue(), ^{
            (*runtimeJavaVMPtr)->AttachCurrentThread(runtimeJavaVMPtr, &runtimeJNIEnvPtr, NULL);
            assert(runtimeJNIEnvPtr);
        });

        // Obtain CTCScreen.getCurrentScreenRGB()
        class_CTCScreen = (*surfaceJNIEnv)->FindClass(surfaceJNIEnv, "net/java/openjdk/cacio/ctc/CTCScreen");
        if ((*surfaceJNIEnv)->ExceptionCheck(surfaceJNIEnv) == JNI_TRUE) {
            (*surfaceJNIEnv)->ExceptionClear(surfaceJNIEnv);
            class_CTCScreen = (*surfaceJNIEnv)->FindClass(surfaceJNIEnv, "com/github/caciocavallosilano/cacio/ctc/CTCScreen");
        }
        assert(class_CTCScreen != NULL);
        method_GetRGB = (*surfaceJNIEnv)->GetStaticMethodID(surfaceJNIEnv, class_CTCScreen, "getCurrentScreenRGB", "()[I");
        assert(method_GetRGB != NULL);
        rgbArray = calloc(4, (size_t) (windowWidth * windowHeight));
    }

    jintArray jreRgbArray = (jintArray) (*surfaceJNIEnv)->CallStaticObjectMethod(
        surfaceJNIEnv,
        class_CTCScreen,
        method_GetRGB
    );
    if (!jreRgbArray) {
        return;
    }
    int *tmpArray = (*surfaceJNIEnv)->GetIntArrayElements(surfaceJNIEnv, jreRgbArray, 0);
    memcpy(rgbArray, tmpArray, windowWidth * windowHeight * 4);
    (*surfaceJNIEnv)->ReleaseIntArrayElements(surfaceJNIEnv, jreRgbArray, tmpArray, JNI_ABORT);
    dispatch_async(dispatch_get_main_queue(), ^{
        [surfaceView displayLayer];
    });

    // Wait until something renders at the middle
    if (shouldHitEnterAfterWindowShown && rgbArray[windowWidth/2 + windowWidth*windowHeight/2] != 0) {
        shouldHitEnterAfterWindowShown = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^(void){
            // Auto hit Enter to install immediately
            AWTInputBridge_sendKey('\n');
        });
    }
}

- (void)displayLayer {
    CGDataProviderRef bitmapProvider = CGDataProviderCreateWithData(NULL, rgbArray, windowWidth * windowHeight * 4, NULL);
    CGImageRef bitmap = CGImageCreate(windowWidth, windowHeight, 8, 32, 4 * windowWidth, _colorSpace, kCGImageAlphaFirst | kCGBitmapByteOrder32Little, bitmapProvider, NULL, FALSE, kCGRenderingIntentDefault);

    self.layer.contents = (__bridge id) bitmap;
    CGImageRelease(bitmap);
    CGDataProviderRelease(bitmapProvider);
   //  CGColorSpaceRelease(colorSpace);
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    self.layer.opaque = YES;
    self.colorSpace = CGColorSpaceCreateDeviceRGB();
    return self;
}
@end

@interface ScrollableSurfaceView<UIScrollViewDelegate> : UIScrollView
@property CGRect clickRange, virtualMouseFrame;
@property(nonatomic) UIImageView* mousePointerView;
@property BOOL shouldTriggerClick;
@end

@implementation ScrollableSurfaceView

- (instancetype)initWithFrame:(CGRect)frame {
    surfaceView = [[SurfaceView alloc] initWithFrame:frame];
    self = [super initWithFrame:frame];
    [self addSubview:surfaceView];
    self.delegate = (id)self;

    self.virtualMouseFrame = CGRectMake(frame.size.width / 2, frame.size.height / 2, 18, 27);
    self.mousePointerView = [[UIImageView alloc] initWithFrame:self.virtualMouseFrame];
    self.mousePointerView.hidden = !virtualMouseEnabled;
    self.mousePointerView.image = [UIImage imageNamed:@"MousePointer"];
    [surfaceView addSubview:self.mousePointerView];

    return self;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    CGPoint location = [touches.anyObject locationInView:self];
    self.clickRange = CGRectMake(location.x - 2, location.y - 2, 5, 5);
    self.shouldTriggerClick = YES;
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    UITouch *touchEvent = touches.anyObject;
    CGPoint location = [touchEvent locationInView:self];
    if (self.shouldTriggerClick && !CGRectContainsPoint(self.clickRange, location)) {
        self.shouldTriggerClick = NO;
    }

    if (virtualMouseEnabled) {
        CGPoint prevLocation = [touchEvent previousLocationInView:self];
        // Calculate delta
        location.x = (location.x - prevLocation.x) / self.zoomScale;
        location.y = (location.y - prevLocation.y) / self.zoomScale;
        // Update cursor's origin
        _virtualMouseFrame.origin.x = clamp(self.virtualMouseFrame.origin.x + location.x, 0, self.frame.size.width * self.zoomScale);
        _virtualMouseFrame.origin.y = clamp(self.virtualMouseFrame.origin.y + location.y, 0, self.frame.size.height * self.zoomScale);
        self.mousePointerView.frame = self.virtualMouseFrame;
        location = self.virtualMouseFrame.origin;

        CGPoint minimumContentOffset = CGPointMake(-self.contentInset.left, -self.contentInset.top);
        CGPoint maximumContentOffset = CGPointMake(
            MAX(minimumContentOffset.x, self.contentSize.width + self.contentInset.right - self.frame.size.width),
            MAX(minimumContentOffset.y, self.contentSize.height + self.contentInset.bottom - self.frame.size.height));
        // Focus scroll view's content area on virtual mouse
        self.contentOffset = CGPointMake(
            clamp(self.virtualMouseFrame.origin.x * self.zoomScale - self.center.x, minimumContentOffset.x, maximumContentOffset.x),
            clamp(self.virtualMouseFrame.origin.y * self.zoomScale - self.center.y, minimumContentOffset.y, maximumContentOffset.y));
    }

    // Send cursor position to AWT
    CGFloat screenScale = UIScreen.mainScreen.scale * getPrefFloat(@"video.resolution") / 100.0;
    AWTInputBridge_nativeSendData(EVENT_TYPE_CURSOR_POS, (int)(location.x * screenScale), (int)(location.y * screenScale), 0, 0);
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    if (virtualMouseEnabled) {
        // Keep virtual mouse in the middle of screen while zooming
        _virtualMouseFrame.origin.x = (self.contentOffset.x + self.center.x) / self.zoomScale;
        _virtualMouseFrame.origin.y = (self.contentOffset.y + self.center.y) / self.zoomScale;
        self.mousePointerView.frame = self.virtualMouseFrame;
        // Send cursor position to AWT
        CGFloat screenScale = UIScreen.mainScreen.scale * getPrefFloat(@"video.resolution") / 100.0;
        AWTInputBridge_nativeSendData(EVENT_TYPE_CURSOR_POS, (int)(_virtualMouseFrame.origin.x * screenScale), (int)(_virtualMouseFrame.origin.y * screenScale), 0, 0);
    }
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)view {
    return surfaceView;
}

@end

@interface JavaGUIViewController ()<UIGestureRecognizerDelegate, UITextFieldDelegate>

@property(nonatomic) TrackedTextField* inputTextField;
@property(nonatomic) ControlLayout* ctrlView;
@property(nonatomic) PLLogOutputView* logOutputView;
@property(nonatomic) ScrollableSurfaceView* surfaceScrollView;
// 关键修复（UI 累积异常）：CADisplayLink 与其所在线程的 runloop 之前未持有引用，
// 无法在 dealloc 中 invalidate，导致每次进入 JavaGUI 界面都泄漏一条线程 +
// 一个 CADisplayLink + 对 surfaceView 的强引用。多次进入后线程数累积，UI 卡顿。
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic, strong) NSThread *displayLinkThread;

@end

@implementation JavaGUIViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    // 关键修复（二次执行 jar 卡死）：iOS 进程内 JVM 只能创建一次
    // （gJVMUsedInProcess，第二次 JLI_Launch 会崩溃）。若入口未拦截（如未来新增
    // 直接 alloc 本 VC 的调用方），此处兜底：已创建过 JVM 时立即退出界面并提示，
    // 避免黑屏卡死。必须放在任何界面副作用（displayLink 线程等）之前。
    if (JVMUsedInProcess()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_214", nil)
                                                                           message:localize(@"i18n_str_1143", nil)
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_216", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [PLCrashView restartLauncher];
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_217", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
                [self dismissViewControllerAnimated:YES completion:nil];
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        });
        return;
    }

    // 适配自定义启动器背景：将当前视图控制器透明化，使全局背景壁纸能够透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.view.backgroundColor = UIColor.blackColor;
    [self.navigationController setNavigationBarHidden:YES animated:NO];
    [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    virtualMouseEnabled = getPrefBool(@"control.virtmouse_enable");

    CGRect screenBounds = self.view.bounds;
    CGFloat screenScale = UIScreen.mainScreen.scale * getPrefFloat(@"video.resolution") / 100.0;
    windowWidth = roundf(screenBounds.size.width * screenScale);
    windowHeight = roundf(screenBounds.size.height * screenScale);
    // Resolution should not be odd
    if ((windowWidth % 2) != 0) {
        --windowWidth;
    }
    if ((windowHeight % 2) != 0) {
        --windowHeight;
    }

    self.surfaceScrollView = [[ScrollableSurfaceView alloc] initWithFrame:self.view.frame];
    self.surfaceScrollView.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    self.surfaceScrollView.minimumZoomScale = 1;
    self.surfaceScrollView.maximumZoomScale = 5;
    self.surfaceScrollView.scrollEnabled = NO;
    [self.view addSubview:self.surfaceScrollView];

    self.inputTextField = [[TrackedTextField alloc] initWithFrame:CGRectMake(0, -32.0, self.view.frame.size.width, 30.0)];
    self.inputTextField.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.inputTextField.delegate = self;
    self.inputTextField.font = [UIFont fontWithName:@"Menlo-Regular" size:20];
    self.inputTextField.clearsOnBeginEditing = YES;
    self.inputTextField.textAlignment = NSTextAlignmentCenter;
    self.inputTextField.sendChar = ^(jchar keychar){
        AWTInputBridge_sendChar(keychar);
    };
    self.inputTextField.sendKey = ^(int key, int scancode, int action, int mods) {
        if (action == 0) return;
        switch (key) {
            case GLFW_KEY_BACKSPACE:
                AWTInputBridge_sendKey('\b'); // VK_BACK_SPACE
                break;
            case GLFW_KEY_ENTER:
                AWTInputBridge_sendKey('\n'); // VK_ENTER;
                break;
            case GLFW_KEY_DPAD_LEFT:
                AWTInputBridge_sendKey(0xE2); // VK_KP_LEFT;
                break;
            case GLFW_KEY_DPAD_RIGHT:
                AWTInputBridge_sendKey(0xE3); // VK_KP_RIGHT;
                break;
        }
    };
    [self.view addSubview:self.inputTextField];

    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(surfaceOnClick:)];
    tapGesture.delegate = self;
    tapGesture.numberOfTapsRequired = 1;
    tapGesture.numberOfTouchesRequired = 1;
    tapGesture.cancelsTouchesInView = NO;
    [surfaceView addGestureRecognizer:tapGesture];

    // Borrowing custom controls, might be useful later (full-blown jar launcher with control support?)
    self.ctrlView = [[ControlLayout alloc] initWithFrame:UIEdgeInsetsInsetRect(self.view.frame, self.view.safeAreaInsets)];
    [self.view addSubview:self.ctrlView];
    [self loadCustomControls];

    self.logOutputView = [[PLLogOutputView alloc] initWithFrame:self.view.frame];
    self.logOutputView.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.logOutputView];

    setenv("POJAV_SKIP_JNI_GLFW", "1", 1);

    // Register the display loop
    // 关键修复（UI 累积异常）：之前用 dispatch_async + [NSRunLoop.currentRunLoop run] 永久阻塞线程，
    // CADisplayLink 无法被 invalidate，每次进入 JavaGUI 界面都泄漏一条线程 + displayLink + surfaceView。
    // 现改用 NSThread，在 dealloc 中通过 CFRunLoopStop 停止 runloop 并 invalidate displayLink。
    __weak typeof(self) weakSelf = self;
    NSThread *dlThread = [[NSThread alloc] initWithBlock:^{
        CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:surfaceView selector:@selector(refreshBuffer)];
        if (@available(iOS 15.0, tvOS 15.0, *)) {
            // max_framerate 选项已移除：始终采用 30-120Hz 自适应范围。
            // 屏幕硬件决定实际帧率（60Hz 设备仍为 60，120Hz ProMotion 设备可达 120），
            // 不再人为限制在 60FPS。配合 disable_game_vsync 完整解锁 VSync 后帧率可超过屏幕刷新率。
            dl.preferredFrameRateRange = CAFrameRateRangeMake(30, 120, 120);
        }
        [dl addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
        // 存到 self 属性供 dealloc invalidate。weak self 在线程 block 内安全。
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf.displayLink = dl;
        }
        // runloop 会阻塞直到外部调用 CFRunLoopStop 停止它
        CFRunLoopRun();
        // runloop 停止后清理 displayLink
        [dl invalidate];
    }];
    self.displayLinkThread = dlThread;
    [dlThread start];

    
dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 走 getter 兜底：若调用方未触发预解析，getter 会现场解析 manifest
        // 避免 ivar=0 时 launchJVM 用 minVersion=0 匹配到错误的 JRE（如 Java 8 跑 NeoForge installer）
        int javaVer = self.requiredJavaVersion;
        if (javaVer <= 0) {
            // 解析失败，getter 已弹错误提示，回主线程 dismiss VC 避免黑屏
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
            });
            return;
        }
        launchJVM(nil, self.filepath, windowWidth, windowHeight, javaVer);
        _requiredJavaVersion = 0;
    });

    // 监听背景 UI 效果变化通知，当用户切换背景效果（半透明/毛玻璃）时重新应用透明化
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

/// 背景效果改变时重新应用透明化（由 BackgroundUIEffectChanged 通知触发）
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    // 关键修复（UI 累积异常）：停止 displayLink 线程及其 runloop。
    // 之前未 invalidate displayLink，且 runloop 用 [NSRunLoop run] 永久阻塞，
    // 导致每次进入 JavaGUI 界面都泄漏一条线程 + displayLink + surfaceView 强引用。
    //
    // 清理步骤：
    // 1. invalidate displayLink（从 runloop 移除该源）
    // 2. 在 displayLinkThread 上执行 CFRunLoopStop，让 CFRunLoopRun() 返回，线程 block 结束
    // 3. 清理静态 surfaceView 引用
    [self.displayLink invalidate];
    self.displayLink = nil;
    if (self.displayLinkThread) {
        // 在子线程上执行 CFRunLoopStop(CFRunLoopGetCurrent())，让 CFRunLoopRun() 返回
        [self performSelector:@selector(_stopDisplayLinkRunLoop)
                     onThread:self.displayLinkThread
                   withObject:nil
                waitUntilDone:NO];
        self.displayLinkThread = nil;
    }
    @try {
        surfaceView = nil;
    } @catch (NSException *e) {}
}

/// 在 displayLinkThread 上执行，停止该线程的 runloop
- (void)_stopDisplayLinkRunLoop {
    CFRunLoopStop(CFRunLoopGetCurrent());
}

- (void)loadCustomControls {
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    dict[@"version"] = @(4);
    dict[@"scaledAt"] = @(100);
    dict[@"mControlDataList"] = [[NSMutableArray alloc] init];
    //dict[@"mDrawerDataList"] = [[NSMutableArray alloc] init];
    [dict[@"mControlDataList"] addObject:createButton(@"Keyboard",
        (int[]){SPECIALBTN_KEYBOARD,0,0,0},
        @"${margin}", @"${margin}",
        BTN_RECT
    )];
    [dict[@"mControlDataList"] addObject:createButton(localize(@"game.menu.log_output", nil),
        (int[]){SPECIALBTN_LOGOUTPUT,0,0,0},
        @"${right} - ${margin}", @"${margin}",
        BTN_RECT
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"Mouse",
        (int[]){SPECIALBTN_VIRTUALMOUSE,0,0,0},
        @"${right} - ${margin}", @"${margin} * 2 + ${height}",
        BTN_RECT
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"PRI",
        (int[]){SPECIALBTN_MOUSEPRI,0,0,0},
        @"${margin}", @"${bottom} - ${margin}",
        BTN_RECT
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"SEC",
        (int[]){SPECIALBTN_MOUSESEC,0,0,0},
        @"${margin} * 2 + ${width}", @"${bottom} - ${margin}",
        BTN_RECT
    )];
    [self.ctrlView loadControlLayout:dict];

    // Implement a subset of custom controls functionalites enough for few buttons
    for (ControlButton *button in self.ctrlView.subviews) {
        [button addTarget:self action:@selector(executebtn_down:) forControlEvents:UIControlEventTouchDown];
        [button addTarget:self action:@selector(executebtn_up:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    }
}

@synthesize requiredJavaVersion = _requiredJavaVersion;
- (int)requiredJavaVersion {
    if (_requiredJavaVersion) {
        return _requiredJavaVersion;
    }

    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:self.filepath error:&error];
    if (error) {
        [self showErrorMessage:error.localizedDescription];
        return _requiredJavaVersion = 0;
    }

    NSData *manifestData = [archive extractDataFromFile:@"META-INF/MANIFEST.MF" error:&error];
    if (error) {
        [self showErrorMessage:error.localizedDescription];
        return _requiredJavaVersion = 0;
    }

    NSString *manifestStr = [[NSString alloc] initWithData:manifestData encoding:NSUTF8StringEncoding];
    NSArray *manifestLines = [manifestStr componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSString *mainClass;
    for (NSString *line in manifestLines) {
        // 容错：去除行尾 \r（Windows CRLF 换行会残留 \r）和首尾空白
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([trimmed hasPrefix:@"Main-Class:"]) {
            // Main-Class: 后可能有 0~N 个空格，规范允许任意空白
            mainClass = [[trimmed substringFromIndex:@"Main-Class:".length]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            break;
        }
    }
    if (!mainClass || mainClass.length == 0) {
        [self showErrorMessage:[NSString stringWithFormat:
            localize(@"java.error.missing_main_class", nil), self.filepath.lastPathComponent]];
        return _requiredJavaVersion = 0;
    }
    mainClass = [NSString stringWithFormat:@"%@.class",
        [mainClass stringByReplacingOccurrencesOfString:@"." withString:@"/"]];

    NSData *mainClassData = [archive extractDataFromFile:mainClass error:&error];
    if (error) {
        [self showErrorMessage:error.localizedDescription];
        return _requiredJavaVersion = 0;
    }
    // 越界保护：class 文件至少需要 8 字节（magic 4 + minor 2 + major 2）
    if (mainClassData.length < 8) {
        [self showErrorMessage:[NSString stringWithFormat:@"Invalid class file: too small (%lu bytes)", (unsigned long)mainClassData.length]];
        return _requiredJavaVersion = 0;
    }

    // 用 memcpy 读取避免未对齐内存访问（NSData.bytes 不保证 2/4 字节对齐）
    uint32_t magic;
    memcpy(&magic, mainClassData.bytes, sizeof(magic));
    magic = OSSwapConstInt32(magic);
    if (magic != 0xCAFEBABE) {
        [self showErrorMessage:[NSString stringWithFormat:@"Invalid magic number: 0x%x", magic]];
        return _requiredJavaVersion = 0;
    }

    uint16_t minorVer, majorVer;
    memcpy(&minorVer, (const uint8_t *)mainClassData.bytes + sizeof(magic), sizeof(minorVer));
    memcpy(&majorVer, (const uint8_t *)mainClassData.bytes + sizeof(magic) + sizeof(minorVer), sizeof(majorVer));
    minorVer = OSSwapConstInt16(minorVer);
    majorVer = OSSwapConstInt16(majorVer);
    NSLog(@"[ModInstaller] Main class version: %u.%u", majorVer, minorVer);

    // 字节码版本下界保护：class file major version 范围合理值是 45~70+
    // Java 1.0 = 45, Java 8 = 52, Java 17 = 61, Java 21 = 65
    if (majorVer < 45 || majorVer > 70) {
        [self showErrorMessage:[NSString stringWithFormat:@"Invalid class file version: %u.%u", majorVer, minorVer]];
        return _requiredJavaVersion = 0;
    }

    // Class file major version to Java version mapping:
    // Java 8 (version 52) = Minecraft 1.12 and earlier
    // Java 16 (version 60) = Minecraft 1.17 and later
    // Java 17 (version 61) = Minecraft 1.18 and later
    // Java 21 (version 65) = Minecraft 1.20.5 and later
    int javaVersion = MAX(2, majorVer - 44);
    
    // Apply Minecraft version-specific Java requirements
    if (self.filepath) {
        NSString *fileName = [self.filepath lastPathComponent];
        // Extract version from filename if possible
        // This is a simplified approach - in a full implementation you'd extract the version more robustly
        if (fileName) {
            // For .jar files, we might need to determine version differently
        }
    }
    
    return _requiredJavaVersion = javaVersion;
}

- (void)showErrorMessage:(NSString *)message {
    surfaceView = nil;
    showDialog(localize(@"Error", nil), message);
}

- (void)setHitEnterAfterWindowShown:(BOOL)hitEnter {
    shouldHitEnterAfterWindowShown = hitEnter;
}

- (void)executebtn:(ControlButton *)sender withAction:(int)action {
    int held = action == ACTION_DOWN;
    for (int i = 0; i < 4; i++) {
        int keycode = ((NSNumber *)sender.properties[@"keycodes"][i]).intValue;
        if (keycode < 0) {
            switch (keycode) {
                case SPECIALBTN_KEYBOARD:
                    if (held) return;
                    [self toggleSoftKeyboard];
                    break;

                case SPECIALBTN_MOUSEPRI:
                    AWTInputBridge_nativeSendData(EVENT_TYPE_MOUSE_BUTTON, BUTTON1_DOWN_MASK, held, 0, 0);
                    break;

                case SPECIALBTN_MOUSEMID:
                    AWTInputBridge_nativeSendData(EVENT_TYPE_MOUSE_BUTTON, BUTTON2_DOWN_MASK, held, 0, 0);
                    break;

                case SPECIALBTN_MOUSESEC:
                    AWTInputBridge_nativeSendData(EVENT_TYPE_MOUSE_BUTTON, BUTTON3_DOWN_MASK, held, 0, 0);
                    break;

                case SPECIALBTN_VIRTUALMOUSE:
                    if (held) break;
                    virtualMouseEnabled = !virtualMouseEnabled;
                    self.surfaceScrollView.mousePointerView.hidden = !virtualMouseEnabled;
                    setPrefBool(@"control.virtmouse_enable", virtualMouseEnabled);
                    break;

                case SPECIALBTN_LOGOUTPUT:
                    if (held) break;
                    [self.logOutputView actionToggleLogOutput];
                    break;

                default:
                    NSLog(@"Warning: button %@ sent unknown special keycode: %d", sender.titleLabel.text, keycode);
                    break;
            }
        } else if (keycode > 0) {
            // unimplemented
        }
    }
}

- (void)executebtn_down:(ControlButton *)button {
    [self executebtn:button withAction:ACTION_DOWN];
}

- (void)executebtn_up:(ControlButton *)button {
    [self executebtn:button withAction:ACTION_UP];
}

- (void)surfaceOnClick:(UITapGestureRecognizer *)sender {
    if (!self.surfaceScrollView.shouldTriggerClick) return;
    if (sender.state == UIGestureRecognizerStateRecognized) {
        CGFloat screenScale = UIScreen.mainScreen.scale * getPrefFloat(@"video.resolution") / 100.0;
        CGPoint location = virtualMouseEnabled ?
            self.surfaceScrollView.virtualMouseFrame.origin:
            [sender locationInView:sender.view];
        CGFloat x = location.x * screenScale;
        CGFloat y = location.y * screenScale;
        AWTInputBridge_nativeSendData(EVENT_TYPE_CURSOR_POS, (int)x, (int)y, 0, 0);
        AWTInputBridge_nativeSendData(EVENT_TYPE_MOUSE_BUTTON, BUTTON1_DOWN_MASK, 1, 0, 0);
        AWTInputBridge_nativeSendData(EVENT_TYPE_MOUSE_BUTTON, BUTTON1_DOWN_MASK, 0, 0, 0);
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    self.inputTextField.sendKey(GLFW_KEY_ENTER, 0, 1, 0);
    //self.inputTextField.sendKey(GLFW_KEY_ENTER, 0, 0, 0);
    textField.text = @"";
    return YES;
}


- (void)toggleSoftKeyboard {
    if (self.inputTextField.isFirstResponder) {
        [self.inputTextField resignFirstResponder];
    } else {
        [self.inputTextField becomeFirstResponder];
    }
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        self.ctrlView.frame = UIEdgeInsetsInsetRect(self.view.frame, self.view.safeAreaInsets);
        [self.ctrlView.subviews makeObjectsPerformSelector:@selector(update)];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        self.surfaceScrollView.virtualMouseFrame = self.surfaceScrollView.mousePointerView.frame;
    }];
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return UIRectEdgeBottom;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return NO;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

@end
