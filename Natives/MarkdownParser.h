//
//  MarkdownParser.h
//  Amethyst
//
//  轻量 Markdown → NSAttributedString 转换器
//  不依赖第三方库，纯 UIKit 实现。支持：h1-h3、粗体 **text**、斜体 *text*、
//  行内代码 `code`、无序列表 - item、有序列表 1. item、链接 [text](url)、
//  分隔线 ---、段落、引用块 > text。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MarkdownParser : NSObject

/// 将 Markdown 文本转换为 NSAttributedString（基础字体为系统 15pt）
/// @param markdown Markdown 原始文本
+ (NSAttributedString *)parseMarkdown:(NSString *)markdown;

/// 将 Markdown 文本转换为 NSAttributedString
/// @param markdown Markdown 原始文本
/// @param baseFont 基础字体（默认系统 15pt）
+ (NSAttributedString *)parseMarkdown:(NSString *)markdown baseFont:(UIFont *)baseFont;

@end

NS_ASSUME_NONNULL_END
