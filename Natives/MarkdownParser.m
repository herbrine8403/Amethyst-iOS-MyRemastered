#import "utils.h"
//
//  MarkdownParser.m
//  Amethyst
//

#import "MarkdownParser.h"

/// 私有方法前向声明（避免同文件内类方法调用产生"找不到方法"警告）
@interface MarkdownParser ()
+ (void)appendHeaderToResult:(NSMutableAttributedString *)result
                        text:(NSString *)text
                        font:(UIFont *)font
                   baseFont:(UIFont *)baseFont
                  textColor:(UIColor *)textColor
                  linkColor:(UIColor *)linkColor
                 codeBgColor:(UIColor *)codeBgColor;
+ (NSAttributedString *)parseInline:(NSString *)text
                           baseFont:(UIFont *)baseFont
                          textColor:(UIColor *)textColor
                          linkColor:(UIColor *)linkColor
                         codeBgColor:(UIColor *)codeBgColor;
@end

@implementation MarkdownParser

+ (NSAttributedString *)parseMarkdown:(NSString *)markdown {
    return [self parseMarkdown:markdown baseFont:[UIFont systemFontOfSize:15]];
}

+ (NSAttributedString *)parseMarkdown:(NSString *)markdown baseFont:(UIFont *)baseFont {
    if (markdown.length == 0) {
        return [[NSAttributedString alloc] initWithString:@""];
    }
    if (!baseFont) {
        baseFont = [UIFont systemFontOfSize:15];
    }

    // 各级标题字体
    UIFont *h1Font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    UIFont *h2Font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    UIFont *h3Font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];

    UIColor *textColor = [UIColor labelColor];
    UIColor *secondaryColor = [UIColor secondaryLabelColor];
    UIColor *linkColor = [UIColor systemBlueColor];
    UIColor *codeBgColor = [UIColor secondarySystemBackgroundColor];
    UIColor *separatorColor = [UIColor separatorColor];

    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
    NSArray *lines = [markdown componentsSeparatedByString:@"\n"];

    NSUInteger i = 0;
    while (i < lines.count) {
        NSString *line = lines[i];
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        // 围栏代码块 ``` 或 ~~~
        if ([trimmed hasPrefix:@"```"] || [trimmed hasPrefix:@"~~~"]) {
            NSString *fence = [trimmed substringToIndex:3]; // ``` 或 ~~~
            NSUInteger codeStart = i + 1;
            NSUInteger codeEnd = codeStart;
            BOOL foundClosing = NO;
            // 找到闭合围栏
            for (NSUInteger j = codeStart; j < lines.count; j++) {
                NSString *codeTrimmed = [lines[j] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if ([codeTrimmed hasPrefix:fence]) {
                    codeEnd = j;
                    foundClosing = YES;
                    break;
                }
            }
            if (!foundClosing) {
                codeEnd = lines.count; // 未闭合则到末尾
            }
            // 拼接代码块内容
            NSMutableArray *codeLines = [NSMutableArray array];
            for (NSUInteger j = codeStart; j < codeEnd; j++) {
                [codeLines addObject:lines[j]];
            }
            NSString *codeContent = [codeLines componentsJoinedByString:@"\n"];
            UIFont *codeFont = [UIFont fontWithName:@"Menlo" size:baseFont.pointSize - 1];
            if (!codeFont) {
                codeFont = [UIFont monospacedSystemFontOfSize:baseFont.pointSize - 1 weight:UIFontWeightRegular];
            }
            NSMutableParagraphStyle *codePara = [[NSMutableParagraphStyle alloc] init];
            codePara.headIndent = 8;
            codePara.firstLineHeadIndent = 8;
            codePara.tailIndent = -8;
            codePara.paragraphSpacingBefore = 4;
            codePara.paragraphSpacing = 4;
            NSAttributedString *codeBlock = [[NSAttributedString alloc] initWithString:codeContent
                                                                              attributes:@{
                                                                                  NSFontAttributeName: codeFont,
                                                                                  NSForegroundColorAttributeName: textColor,
                                                                                  NSBackgroundColorAttributeName: codeBgColor,
                                                                                  NSParagraphStyleAttributeName: codePara
                                                                              }];
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                                                                            attributes:@{NSFontAttributeName: baseFont}]];
            [result appendAttributedString:codeBlock];
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                                                                            attributes:@{NSFontAttributeName: baseFont}]];
            i = foundClosing ? codeEnd + 1 : codeEnd;
            continue;
        }

        // 空行 → 段落间距（跳过，避免堆积过多换行）
        if (trimmed.length == 0) {
            if (result.length > 0) {
                [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                                                                                attributes:@{NSFontAttributeName: baseFont}]];
            }
            i++;
            continue;
        }

        // 分隔线 --- / *** / ___
        if ([trimmed isEqualToString:@"---"] || [trimmed isEqualToString:@"***"] || [trimmed isEqualToString:@"___"]) {
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                                                                            attributes:@{NSFontAttributeName: baseFont}]];
            NSAttributedString *hr = [[NSAttributedString alloc] initWithString:@"────────────────────"
                                                                       attributes:@{
                                                                           NSFontAttributeName: baseFont,
                                                                           NSForegroundColorAttributeName: separatorColor
                                                                       }];
            [result appendAttributedString:hr];
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                                                                            attributes:@{NSFontAttributeName: baseFont}]];
            i++;
            continue;
        }

        // 标题：### 优先于 ## 优先于 #
        if ([trimmed hasPrefix:@"### "]) {
            [self appendHeaderToResult:result
                                  text:[trimmed substringFromIndex:4]
                                  font:h3Font
                                  baseFont:baseFont
                             textColor:textColor
                             linkColor:linkColor
                            codeBgColor:codeBgColor];
            i++;
            continue;
        }
        if ([trimmed hasPrefix:@"## "]) {
            [self appendHeaderToResult:result
                                  text:[trimmed substringFromIndex:3]
                                  font:h2Font
                                  baseFont:baseFont
                             textColor:textColor
                             linkColor:linkColor
                            codeBgColor:codeBgColor];
            i++;
            continue;
        }
        if ([trimmed hasPrefix:@"# "]) {
            [self appendHeaderToResult:result
                                  text:[trimmed substringFromIndex:2]
                                  font:h1Font
                                  baseFont:baseFont
                             textColor:textColor
                             linkColor:linkColor
                            codeBgColor:codeBgColor];
            i++;
            continue;
        }

        // 引用块 > text
        if ([trimmed hasPrefix:@"> "]) {
            NSString *content = [trimmed substringFromIndex:2];
            NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
            para.headIndent = 16;
            para.firstLineHeadIndent = 16;
            para.tailIndent = -8;
            UIFont *quoteFont = [UIFont italicSystemFontOfSize:baseFont.pointSize];
            NSAttributedString *inlineText = [self parseInline:content
                                                  baseFont:quoteFont
                                                 textColor:secondaryColor
                                                 linkColor:linkColor
                                                codeBgColor:codeBgColor];
            NSMutableAttributedString *mutableQuote = [inlineText mutableCopy];
            [mutableQuote addAttribute:NSParagraphStyleAttributeName value:para range:NSMakeRange(0, mutableQuote.length)];
            // 左侧条：用首字符背景色模拟（仅作视觉提示）
            if (mutableQuote.length > 0) {
                [mutableQuote addAttribute:NSBackgroundColorAttributeName value:separatorColor range:NSMakeRange(0, 1)];
            }
            [result appendAttributedString:mutableQuote];
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                                                                            attributes:@{NSFontAttributeName: baseFont}]];
            i++;
            continue;
        }

        // 无序列表 - item / * item
        if ([trimmed hasPrefix:@"- "] || [trimmed hasPrefix:@"* "]) {
            NSString *content = [trimmed substringFromIndex:2];
            NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
            para.headIndent = 16;
            para.firstLineHeadIndent = 0;
            para.tailIndent = 0;
            NSAttributedString *bullet = [[NSAttributedString alloc] initWithString:@"•  "
                                                                          attributes:@{
                                                                              NSFontAttributeName: baseFont,
                                                                              NSForegroundColorAttributeName: textColor
                                                                          }];
            NSAttributedString *inlineContent = [self parseInline:content
                                                         baseFont:baseFont
                                                        textColor:textColor
                                                        linkColor:linkColor
                                                       codeBgColor:codeBgColor];
            NSMutableAttributedString *listItem = [[NSMutableAttributedString alloc] init];
            [listItem appendAttributedString:bullet];
            [listItem appendAttributedString:inlineContent];
            [listItem addAttribute:NSParagraphStyleAttributeName value:para range:NSMakeRange(0, listItem.length)];
            [result appendAttributedString:listItem];
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                                                                            attributes:@{NSFontAttributeName: baseFont}]];
            i++;
            continue;
        }

        // 有序列表 1. item / 2. item / ...
        NSRange orderedRange = [trimmed rangeOfString:@"^\\d+\\.\\s" options:NSRegularExpressionSearch];
        if (orderedRange.location == 0 && orderedRange.length > 0) {
            NSString *prefix = [trimmed substringToIndex:orderedRange.length];
            NSString *content = [trimmed substringFromIndex:orderedRange.length];
            NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
            para.headIndent = 20;
            para.firstLineHeadIndent = 0;
            para.tailIndent = 0;
            NSAttributedString *number = [[NSAttributedString alloc] initWithString:prefix
                                                                          attributes:@{
                                                                              NSFontAttributeName: baseFont,
                                                                              NSForegroundColorAttributeName: textColor
                                                                          }];
            NSAttributedString *inlineContent = [self parseInline:content
                                                         baseFont:baseFont
                                                        textColor:textColor
                                                        linkColor:linkColor
                                                       codeBgColor:codeBgColor];
            NSMutableAttributedString *listItem = [[NSMutableAttributedString alloc] init];
            [listItem appendAttributedString:number];
            [listItem appendAttributedString:inlineContent];
            [listItem addAttribute:NSParagraphStyleAttributeName value:para range:NSMakeRange(0, listItem.length)];
            [result appendAttributedString:listItem];
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                                                                            attributes:@{NSFontAttributeName: baseFont}]];
            i++;
            continue;
        }

        // 图片 ![alt](url) — 在行内解析中处理为带链接的占位文本
        if ([trimmed hasPrefix:@"!["]) {
            NSRange closeBracket = [trimmed rangeOfString:@"]("];
            if (closeBracket.location != NSNotFound) {
                NSRange endParen = [trimmed rangeOfString:@")" options:NSBackwardsSearch];
                if (endParen.location != NSNotFound && endParen.location > closeBracket.location) {
                    NSString *altText = [trimmed substringWithRange:NSMakeRange(2, closeBracket.location - 2)];
                    NSString *imgURL = [trimmed substringWithRange:NSMakeRange(NSMaxRange(closeBracket), endParen.location - NSMaxRange(closeBracket))];
                    // 显示 [图片: altText] 作为占位（iOS UITextView 远程图片加载需额外处理）
                    NSString *placeholder = altText.length > 0 ? [NSString stringWithFormat:localize(@"i18n_str_441", nil), altText] : localize(@"i18n_str_442", nil);
                    NSURL *url = [NSURL URLWithString:imgURL];
                    NSMutableDictionary *attrs = [@{
                        NSFontAttributeName: [UIFont italicSystemFontOfSize:baseFont.pointSize],
                        NSForegroundColorAttributeName: secondaryColor
                    } mutableCopy];
                    if (url) attrs[NSLinkAttributeName] = url;
                    [result appendAttributedString:[[NSAttributedString alloc] initWithString:placeholder
                                                                                   attributes:attrs]];
                    [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                                                                                   attributes:@{NSFontAttributeName: baseFont}]];
                    i++;
                    continue;
                }
            }
        }

        // 普通段落
        NSAttributedString *para = [self parseInline:trimmed
                                            baseFont:baseFont
                                           textColor:textColor
                                           linkColor:linkColor
                                          codeBgColor:codeBgColor];
        [result appendAttributedString:para];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                                                                        attributes:@{NSFontAttributeName: baseFont}]];
        i++;
    }

    return [result copy];
}

#pragma mark - Helpers

/// 追加标题行
+ (void)appendHeaderToResult:(NSMutableAttributedString *)result
                        text:(NSString *)text
                        font:(UIFont *)font
                   baseFont:(UIFont *)baseFont
                  textColor:(UIColor *)textColor
                  linkColor:(UIColor *)linkColor
                 codeBgColor:(UIColor *)codeBgColor {
    NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
    para.paragraphSpacingBefore = 4;
    para.paragraphSpacing = 2;
    NSAttributedString *header = [self parseInline:text
                                          baseFont:font
                                         textColor:textColor
                                         linkColor:linkColor
                                        codeBgColor:codeBgColor];
    NSMutableAttributedString *mutableHeader = [header mutableCopy];
    [mutableHeader addAttribute:NSParagraphStyleAttributeName value:para range:NSMakeRange(0, mutableHeader.length)];
    [result appendAttributedString:mutableHeader];
    [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                                                                    attributes:@{NSFontAttributeName: baseFont}]];
}

/// 行内格式解析（递归处理粗体/斜体内部）
/// 合并正则一次扫描：行内代码 > 链接 > 粗体 > 斜体
+ (NSAttributedString *)parseInline:(NSString *)text
                           baseFont:(UIFont *)baseFont
                          textColor:(UIColor *)textColor
                          linkColor:(UIColor *)linkColor
                         codeBgColor:(UIColor *)codeBgColor {
    if (text.length == 0) {
        return [[NSAttributedString alloc] initWithString:@""];
    }

    // 合并正则：1=code, 2=link text, 3=link url, 4=bold, 5=italic
    NSString *pattern = @"(?:`([^`]+)`)"
                        @"|(?:\\[([^\\]]+)\\]\\(([^\\)]+)\\))"
                        @"|(?:\\*\\*([^*]+)\\*\\*)"
                        @"|(?:\\*([^*]+)\\*)";
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];

    // 无任何行内标记，直接返回普通文本
    if (matches.count == 0) {
        return [[NSAttributedString alloc] initWithString:text
                                               attributes:@{
                                                   NSFontAttributeName: baseFont,
                                                   NSForegroundColorAttributeName: textColor
                                               }];
    }

    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
    NSUInteger lastEnd = 0;

    for (NSTextCheckingResult *m in matches) {
        // 匹配之前的普通文本
        if (m.range.location > lastEnd) {
            NSString *plain = [text substringWithRange:NSMakeRange(lastEnd, m.range.location - lastEnd)];
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:plain
                                                                           attributes:@{
                                                                               NSFontAttributeName: baseFont,
                                                                               NSForegroundColorAttributeName: textColor
                                                                           }]];
        }

        if ([m rangeAtIndex:1].location != NSNotFound) {
            // 行内代码 `code`
            NSString *code = [text substringWithRange:[m rangeAtIndex:1]];
            UIFont *codeFont = [UIFont fontWithName:@"Menlo" size:baseFont.pointSize];
            if (!codeFont) {
                // iOS 13+ 提供 monospacedSystemFontOfSize:weight:
                codeFont = [UIFont monospacedSystemFontOfSize:baseFont.pointSize weight:UIFontWeightRegular];
            }
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:code
                                                                           attributes:@{
                                                                               NSFontAttributeName: codeFont,
                                                                               NSForegroundColorAttributeName: textColor,
                                                                               NSBackgroundColorAttributeName: codeBgColor
                                                                           }]];
        } else if ([m rangeAtIndex:2].location != NSNotFound) {
            // 链接 [text](url)
            NSString *linkText = [text substringWithRange:[m rangeAtIndex:2]];
            NSString *linkURLStr = [text substringWithRange:[m rangeAtIndex:3]];
            NSURL *url = [NSURL URLWithString:linkURLStr];
            NSMutableDictionary *attrs = [@{
                NSFontAttributeName: baseFont,
                NSForegroundColorAttributeName: linkColor
            } mutableCopy];
            if (url) attrs[NSLinkAttributeName] = url;
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:linkText
                                                                           attributes:attrs]];
        } else if ([m rangeAtIndex:4].location != NSNotFound) {
            // 粗体 **text**
            NSString *boldText = [text substringWithRange:[m rangeAtIndex:4]];
            UIFont *boldFont = [UIFont boldSystemFontOfSize:baseFont.pointSize];
            NSAttributedString *inner = [self parseInline:boldText
                                                baseFont:boldFont
                                               textColor:textColor
                                               linkColor:linkColor
                                              codeBgColor:codeBgColor];
            [result appendAttributedString:inner];
        } else if ([m rangeAtIndex:5].location != NSNotFound) {
            // 斜体 *text*
            NSString *italicText = [text substringWithRange:[m rangeAtIndex:5]];
            UIFont *italicFont = [UIFont italicSystemFontOfSize:baseFont.pointSize];
            NSAttributedString *inner = [self parseInline:italicText
                                                baseFont:italicFont
                                               textColor:textColor
                                               linkColor:linkColor
                                              codeBgColor:codeBgColor];
            [result appendAttributedString:inner];
        }

        lastEnd = m.range.location + m.range.length;
    }

    // 末尾的普通文本
    if (lastEnd < text.length) {
        NSString *plain = [text substringFromIndex:lastEnd];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:plain
                                                                       attributes:@{
                                                                           NSFontAttributeName: baseFont,
                                                                           NSForegroundColorAttributeName: textColor
                                                                       }]];
    }

    return [result copy];
}

@end
