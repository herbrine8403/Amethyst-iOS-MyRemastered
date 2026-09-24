#import "TrackedTextField.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#include "glfw_keycodes.h"
#include <mach/mach_time.h>

extern bool isUseStackQueueCall;

// There are private functions that we are unable to find public replacements
// (Both are found by placing breakpoints)
@interface UITextField(private)
- (NSRange)insertFilteredText:(NSString *)text;
- (id) replaceRangeWithTextWithoutClosingTyping:(UITextRange *)range replacementText:(NSString *)text;
@end

@interface TrackedTextField()
@property(nonatomic) int lastTextPos;
@property(nonatomic) CGFloat lastPointX;
// Task156：最近一次经私有路径（insertFilteredText:/replaceRangeWithText-
// WithoutClosingTyping:/paste:）送达游戏的文本 + 时间戳——公有 insertText:
// 兑底路径用它做短窗去重，避免同一次提交被双发。
@property(nonatomic, copy, nullable) NSString *ame156_lastDeliveredText;
@property(nonatomic) uint64_t ame156_lastDeliveredTick;
@end

static uint64_t ame156_mach_ms(void) {
    static mach_timebase_info_data_t tb;
    static BOOL inited = NO;
    if (!inited) {
        mach_timebase_info(&tb);
        inited = YES;
    }
    return mach_absolute_time() * tb.numer / tb.denom / 1000000ull;
}

@implementation TrackedTextField

- (void)sendMultiBackspaces:(int)times {
    for (int i = 0; i < times; i++) {
        self.sendKey(GLFW_KEY_BACKSPACE, 0, 1, 0);
        self.sendKey(GLFW_KEY_BACKSPACE, 0, 0, 0);
    }
}

// workaround pasted text not being caught
- (void)paste:(id)sender {
    [super paste:sender];
    [self sendText:UIPasteboard.generalPasteboard.string];
}

// Task156：短窗去重记录——私有路径送达后登记；公有 insertText: 兑底在
// 80ms 内遇到同文本则跳过（同一提交不会被双发，不同键击间隔远大于 80ms）。
- (void)ame156_recordDelivery:(NSString *)text {
    self.ame156_lastDeliveredText = text;
    self.ame156_lastDeliveredTick = ame156_mach_ms();
}

- (BOOL)ame156_recentlyDelivered:(NSString *)text {
    if (self.ame156_lastDeliveredText == nil) return NO;
    uint64_t now = ame156_mach_ms();
    if (now < self.ame156_lastDeliveredTick ||
        now - self.ame156_lastDeliveredTick > 80) {
        return NO;
    }
    return [self.ame156_lastDeliveredText isEqualToString:text];
}

- (void)sendText:(NSString *)text {
    for (int i = 0; i < text.length; i++) {
        // Directly convert unichar to jchar since both are in UTF-16 encoding.
        unichar theChar = [text characterAtIndex:i];
        // 关键修复（虚拟键盘输入无反应）：
        //   之前用 if-else 二选一：isUseStackQueueCall=true 时只调用 sendCharMods，
        //   不调用 sendChar。但 MC 1.13+ 已废弃 glfwSetCharModsCallback，只注册
        //   glfwSetCharCallback，故 GLFW_invoke_CharMods 为 NULL，
        //   CallbackBridge_nativeSendCharMods 在 `if (GLFW_invoke_CharMods && isInputReady)`
        //   处直接返回 NO，字符被静默丢弃 → 虚拟键盘输入完全无反应。
        //
        //   与硬件键盘（input/KeyboardInput.m:162-163）行为对齐：同时发送 CharMods
        //   和 Char。MC 实际只会响应其注册的那个回调（Char 或 CharMods），
        //   不会出现重复字符。这样：
        //   - MC 1.13+（仅 Char）→ sendChar 生效，sendCharMods 静默失败
        //   - MC pre-1.13（仅 CharMods）→ sendCharMods 生效，sendChar 静默失败
        //   - 任何 GLFW 后端版本都能正确传递字符
        if (self.sendCharMods != nil) {
            self.sendCharMods(theChar, 0);
        }
        if (self.sendChar != nil) {
            self.sendChar(theChar);
        }
    }
}

- (void)beginFloatingCursorAtPoint:(CGPoint)point {
    [super beginFloatingCursorAtPoint:point];
    self.lastPointX = point.x;
}

// Handle cursor movement in the empty space
- (void)updateFloatingCursorAtPoint:(CGPoint)point {
    [super updateFloatingCursorAtPoint:point];

    if (self.lastPointX == 0 || (self.lastTextPos > 0 && self.lastTextPos < self.text.length)) {
        // This is handled in -[TrackedTextField closestPositionToPoint:]
        return;
    }

    CGFloat diff = point.x - self.lastPointX;
    if (ABS(diff) < 8) {
        return;
    }
    self.lastPointX = point.x;

    int key = (diff > 0) ? GLFW_KEY_DPAD_RIGHT : GLFW_KEY_DPAD_LEFT;
    self.sendKey(key, 0, 1, 0);
    self.sendKey(key, 0, 0, 0);
}

- (void)endFloatingCursor {
    [super endFloatingCursor];
    self.lastPointX = 0;
}

- (UITextPosition *)closestPositionToPoint:(CGPoint)point {
    // Handle cursor movement between characters
    UITextPosition *position = [super closestPositionToPoint:point];
    int start = [self offsetFromPosition:self.beginningOfDocument toPosition:position];
    if (start - self.lastTextPos != 0) {
        int key = (start - self.lastTextPos > 0) ? GLFW_KEY_DPAD_RIGHT : GLFW_KEY_DPAD_LEFT;
        self.sendKey(key, 0, 1, 0);
        self.sendKey(key, 0, 0, 0);
    }
    self.lastTextPos = start;
    return position;
}

- (void)deleteBackward {
    if (self.text.length > 1) {
        // Keep the first character (a space)
        [super deleteBackward];
    } else {
        self.text = @" ";
    }
    self.lastTextPos = [super offsetFromPosition:self.beginningOfDocument toPosition:self.selectedTextRange.start];

    [self sendMultiBackspaces:1];
}

- (BOOL)hasText {
    self.lastTextPos = MAX(self.lastTextPos, 1);
    return YES;
}

// Old name: insertText
- (NSRange)insertFilteredText:(NSString *)text {
    int cursorPos = [super offsetFromPosition:self.beginningOfDocument toPosition:self.selectedTextRange.start];

    int off = self.lastTextPos - cursorPos;
    if (off > 0) {
        // Handle text markup by first deleting N amount of characters equal to the replaced text
        [self sendMultiBackspaces:off];
    }
    // What else is done by past-autocomplete (insert a space after autocompletion)
    // See -[TrackedTextField replaceRangeWithTextWithoutClosingTyping:replacementText:]

    self.lastTextPos = cursorPos + text.length;

    [self sendText:text];
    [self ame156_recordDelivery:text];

    NSRange range = [super insertFilteredText:text];
    return range;
}

- (id)replaceRangeWithTextWithoutClosingTyping:(UITextRange *)range replacementText:(NSString *)text
{
    int oldLength = [super offsetFromPosition:range.start toPosition:range.end];

    // Delete the range of needs for autocompletion
    [self sendMultiBackspaces:oldLength];

    // Insert the autocompleted text
    [self sendText:text];
    [self ame156_recordDelivery:text];
    self.lastTextPos += text.length - oldLength;

    return [super replaceRangeWithTextWithoutClosingTyping:range replacementText:text];
}

// ============================================================================
// Task 156：iOS 27 输入法兼容兑底（公有 UIKeyInput 路径）。
//
// 病历：设备 iPadOS 27.0（24A437）报告“输入法无法正常输入”。本类的字符
// 送达链全部建筑在 UIKit 私有 API 上（insertFilteredText: /
// replaceRangeWithTextWithoutClosingTyping: / setAttributedMarkedText:）
// ——多年版本一直回肩，但 iOS 26+ 引入 UIAsyncTextInput 异步输入管线后，
// 部分键盘提交不再经过这些私有入口，直接走公有 UIKeyInput.insertText:，
// 于是提交文本（拼音候选上屏、联想词、普通键入）永远到不了游戏。
//
// 兑底策略：override 公有 insertText:（UIKit 对 first responder 的键入
// 提交路径）——私有路径未在短窗内送过同文本时补发。两路径共存时
// 80ms 同文本去重防双发；私有路径已死时这里是唯一送达通道。
// marked text（拼音组字）不走 insertText:，仍由 setAttributedMarkedText:
// 镜像（见下方 Task156 加固）。
// ============================================================================
- (void)insertText:(NSString *)text {
    if (text.length > 0 && ![self ame156_recentlyDelivered:text]) {
        [self sendText:text];
        [self ame156_recordDelivery:text];
    }
    [super insertText:text];
}

- (void)setAttributedMarkedText:(NSAttributedString *)markedText selectedRange:(NSRange)selectedRange {
    // Task156 加固：markedTextRange 可能为 nil（首次组字/输入法重置后），
    // offsetFromPosition:toPosition: 对 nil 位置的返回值在 iOS 27 上不再
    // 可靠（NSNotFound → 百万级退格风暴，IME 输入直接异常）。先判空、
    // 再把长度夹到当前文本长度内。
    NSInteger markedLength = 0;
    if (self.markedTextRange != nil) {
        markedLength = [self offsetFromPosition:self.markedTextRange.start
                                     toPosition:self.markedTextRange.end];
        if (markedLength < 0 || (NSUInteger)markedLength > self.text.length) {
            markedLength = 0;
        }
    }
    [self sendMultiBackspaces:markedLength];

    [super setAttributedMarkedText:markedText selectedRange:selectedRange];

    // Insert the new text
    [self sendText:markedText.string];
    self.lastTextPos = self.text.length;
}

- (void)setText:(NSString *)text {
    [super setText:text];
    self.lastTextPos = text.length;
}

@end
