#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <libgen.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "utils.h"

#import "ios_uikit_bridge.h"
#import "JavaLauncher.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "authenticator/BaseAuthenticator.h"
#import "authenticator/ThirdPartyAuthenticator.h"

#define fm NSFileManager.defaultManager

extern char **environ;

// Parse version string into components for comparison
NSArray* parseVersionString(NSString *version) {
    // Handle snapshot versions like "21w19a" by splitting on non-numeric characters
    if ([version rangeOfString:@"w"].location != NSNotFound) {
        // Split on 'w' to get year and week parts
        NSArray *parts = [version componentsSeparatedByString:@"w"];
        if (parts.count == 2) {
            // Return as [year, week + suffix (like 'a' or 'b')]
            NSString *weekPart = parts[1];
            // Extract numeric part of week and any suffix
            NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
            NSRange range = [weekPart rangeOfCharacterFromSet:nonDigits];
            if (range.location != NSNotFound) {
                NSString *weekNum = [weekPart substringToIndex:range.location];
                NSString *suffix = [weekPart substringFromIndex:range.location];
                return @[@([parts[0] integerValue]), @([weekNum integerValue]), suffix];
            } else {
                return @[@([parts[0] integerValue]), @([weekPart integerValue])];
            }
        }
    } else if ([version rangeOfString:@"-pre"].location != NSNotFound) {
        // Handle pre-release versions like "1.18-pre2"
        NSArray *parts = [version componentsSeparatedByString:@"-pre"];
        if (parts.count == 2) {
            NSArray *mainParts = [parts[0] componentsSeparatedByString:@"."];
            NSMutableArray *result = [NSMutableArray arrayWithArray:mainParts];
            [result addObject:@(-1)]; // pre-release indicator
            [result addObject:@([parts[1] integerValue])]; // pre-release number
            return [result copy];
        }
    } else if ([version rangeOfString:@"-rc"].location != NSNotFound) {
        // Handle release candidate versions like "1.17-rc1"
        NSArray *parts = [version componentsSeparatedByString:@"-rc"];
        if (parts.count == 2) {
            NSArray *mainParts = [parts[0] componentsSeparatedByString:@"."];
            NSMutableArray *result = [NSMutableArray arrayWithArray:mainParts];
            [result addObject:@(-2)]; // rc indicator
            [result addObject:@([parts[1] integerValue])]; // rc number
            return [result copy];
        }
    } else {
        // Handle regular version like "1.17.1"
        return [version componentsSeparatedByString:@"."];
    }
    return @[];
}

// Compare Minecraft versions - returns true if version1 is greater than or equal to version2
BOOL minecraftVersionIsGreaterOrEqualTo(NSString *version1, NSString *version2) {
    NSArray *ver1Parts = parseVersionString(version1);
    NSArray *ver2Parts = parseVersionString(version2);
    
    if (ver1Parts.count == 0 || ver2Parts.count == 0) {
        return NO; // Can't compare invalid versions
    }
    
    // Compare each component numerically
    NSInteger maxCount = MAX(ver1Parts.count, ver2Parts.count);
    for (NSInteger i = 0; i < maxCount; i++) {
        NSInteger val1 = 0, val2 = 0;
        NSString *str1 = (i < ver1Parts.count) ? ver1Parts[i] : @"0";
        NSString *str2 = (i < ver2Parts.count) ? ver2Parts[i] : @"0";
        
        // Handle string values (like suffixes in snapshots) by using a special ordering
        if ([str1 isKindOfClass:[NSString class]] && ![str1 isKindOfClass:[NSNumber class]]) {
            if ([str1 rangeOfString:@"w"].location != NSNotFound || [str1 rangeOfString:@"-pre"].location != NSNotFound || [str1 rangeOfString:@"-rc"].location != NSNotFound) {
                // This is handled in parseVersionString, so str1 should be numeric here
                val1 = [str1 integerValue];
            } else {
                // For string suffixes like 'a', 'b', etc., convert to numeric values for comparison
                if ([str1 isEqualToString:@"a"]) val1 = 1;
                else if ([str1 isEqualToString:@"b"]) val1 = 2;
                else val1 = [str1 integerValue];
            }
        } else {
            val1 = [str1 integerValue];
        }
        
        if ([str2 isKindOfClass:[NSString class]] && ![str2 isKindOfClass:[NSNumber class]]) {
            if ([str2 rangeOfString:@"w"].location != NSNotFound || [str2 rangeOfString:@"-pre"].location != NSNotFound || [str2 rangeOfString:@"-rc"].location != NSNotFound) {
                val2 = [str2 integerValue];
            } else {
                // For string suffixes like 'a', 'b', etc., convert to numeric values for comparison
                if ([str2 isEqualToString:@"a"]) val2 = 1;
                else if ([str2 isEqualToString:@"b"]) val2 = 2;
                else val2 = [str2 integerValue];
            }
        } else {
            val2 = [str2 integerValue];
        }
        
        if (val1 > val2) return YES;
        if (val1 < val2) return NO;
    }
    
    return YES; // Equal versions
}

// Check if a version is a snapshot version and is greater than or equal to a specific comparator
BOOL isSnapshotVersionGreaterOrEqualTo(NSString *version, NSString *comparator) {
    // Check if this is a snapshot version (contains 'w' or 'pre' or 'rc')
    if ([version rangeOfString:@"w"].location != NSNotFound || [version rangeOfString:@"-pre"].location != NSNotFound || [version rangeOfString:@"-rc"].location != NSNotFound) {
        return minecraftVersionIsGreaterOrEqualTo(version, comparator);
    }
    return NO;
}

BOOL validateVirtualMemorySpace(int size) {
    size <<= 20; // convert to MB
    void *map = mmap(0, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    // check if process successfully maps and unmaps a contiguous range
    if(map == MAP_FAILED || munmap(map, size) != 0)
        return NO;
    return YES;
}

void init_loadDefaultEnv() {
    /* Define default env */

    // Silent Caciocavallo NPE error in locating Android-only lib
    setenv("LD_LIBRARY_PATH", "", 1);

    // Ignore mipmap for performance(?) seems does not affect iOS
    //setenv("LIBGL_MIPMAP", "3", 1);

    // Disable overloaded functions hack for Minecraft 1.17+
    setenv("LIBGL_NOINTOVLHACK", "1", 1);

    // Fix white color on banner and sheep, since GL4ES 1.1.5
    setenv("LIBGL_NORMALIZE", "1", 1);

    // Override OpenGL version to 4.1 for Zink
    setenv("MESA_GL_VERSION_OVERRIDE", "4.1", 1);

    // Runs JVM in a separate thread
    setenv("HACK_IGNORE_START_ON_FIRST_THREAD", "1", 1);
}

void init_loadCustomEnv() {
    NSString *envvars = getPrefObject(@"java.env_variables");
    if (envvars == nil) return;
    NSLog(@"[JavaLauncher] Reading custom environment variables");
    for (NSString *line in [envvars componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (![line containsString:@"="]) {
            NSLog(@"[JavaLauncher] Warning: skipped empty value custom env variable: %@", line);
            continue;
        }
        NSRange range = [line rangeOfString:@"="];
        NSString *key = [line substringToIndex:range.location];
        NSString *value = [line substringFromIndex:range.location+range.length];
        setenv(key.UTF8String, value.UTF8String, 1);
        NSLog(@"[JavaLauncher] Added custom env variable: %@", line);
    }
}

void init_loadCustomJvmFlags(int* argc, const char** argv) {
    NSString *jvmargs = [PLProfiles resolveKeyForCurrentProfile:@"javaArgs"];
    if (jvmargs == nil) return;
    // Make the separator happy
    jvmargs = [jvmargs stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    jvmargs = [@" " stringByAppendingString:jvmargs];

    NSLog(@"[JavaLauncher] Reading custom JVM flags");
    NSArray *argsToPurge = @[@"Xms", @"Xmx", @"d32", @"d64"];
    for (NSString *arg in [jvmargs componentsSeparatedByString:@" -"]) {
        NSString *jvmarg = [arg stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (jvmarg.length == 0) continue;
        BOOL ignore = NO;
        for (NSString *argToPurge in argsToPurge) {
            if ([jvmarg hasPrefix:argToPurge]) {
                NSLog(@"[JavaLauncher] Ignored JVM flag: -%@", jvmarg);
                ignore = YES;
                break;
            }
        }
        if (ignore) continue;

        ++*argc;
        argv[*argc] = [@"-" stringByAppendingString:jvmarg].UTF8String;

        NSLog(@"[JavaLauncher] Added custom JVM flag: %s", argv[*argc]);
    }
}

int launchJVM(NSString *username, id launchTarget, int width, int height, int minVersion) {
    NSLog(@"[JavaLauncher] Beginning JVM launch");

    if ([NSFileManager.defaultManager fileExistsAtPath:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"]]) {
        NSDebugLog(@"[JavaLauncher] Running in LiveContainer, skipping dyld patch");
    } else {
        if(@available(iOS 19.0, *)) {
            // Disable Library Validation bypass for iOS 26 because of stricter JIT
        } else {
            // Activate Library Validation bypass for external runtime and dylibs (JNA, etc)
            init_bypassDyldLibValidation();
        }
    }


    init_loadDefaultEnv();
    init_loadCustomEnv();
    
    // --- [新增] TouchController UDP 协议环境变量 ---
    // 检查是否启用了 UDP 协议开关
    if (getPrefBool(@"control.mod_touch_udp")) {
        setenv("TOUCH_CONTROLLER_PROXY", "12450", 1);
        NSLog(@"[JavaLauncher] Enabled TOUCH_CONTROLLER_PROXY=12450");
    }
    // ------------------------------------------

    BOOL launchJar = NO;
    NSString *gameDir;
    NSString *defaultJRETag;
    int preferredJavaVersion; // Declare outside the block to make it available throughout the scope
    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        // Get preferred Java version from current profile
        preferredJavaVersion = [PLProfiles resolveKeyForCurrentProfile:@"javaVersion"].intValue;
        if (preferredJavaVersion > 0) {
            if (minVersion > preferredJavaVersion) {
                NSLog(@"[JavaLauncher] Profile's preferred Java version (%d) does not meet the minimum version (%d), dropping request", preferredJavaVersion, minVersion);
            } else {
                NSDebugLog(@"[PLProfiles] Applying javaVersion");
                minVersion = preferredJavaVersion;
            }
        }
        
        // Apply Minecraft version-specific Java requirements
        NSString *minecraftVersion = launchTarget[@"id"];
        int requiredJavaVersion = minVersion;
        
        // Check Minecraft version and set appropriate Java version requirement
        if (minecraftVersion) {
            // From 1.12 (17w13a) onwards, Java 8 is minimum requirement
            if (minecraftVersionIsGreaterOrEqualTo(minecraftVersion, @"1.12") || isSnapshotVersionGreaterOrEqualTo(minecraftVersion, @"17w13a")) {
                requiredJavaVersion = MAX(requiredJavaVersion, 8);
            }
            
            // From 1.17 (21w19a) onwards, Java 16 is minimum requirement
            if (minecraftVersionIsGreaterOrEqualTo(minecraftVersion, @"1.17") || isSnapshotVersionGreaterOrEqualTo(minecraftVersion, @"21w19a")) {
                requiredJavaVersion = MAX(requiredJavaVersion, 16);
            }
            
            // From 1.18 (1.18-pre2) onwards, Java 17 is minimum requirement
            if (minecraftVersionIsGreaterOrEqualTo(minecraftVersion, @"1.18") || isSnapshotVersionGreaterOrEqualTo(minecraftVersion, @"1.18-pre2")) {
                requiredJavaVersion = MAX(requiredJavaVersion, 17);
            }
            
            // From 1.20.5 (24w14a) onwards, Java 21 is minimum requirement
            if (minecraftVersionIsGreaterOrEqualTo(minecraftVersion, @"1.20.5") || isSnapshotVersionGreaterOrEqualTo(minecraftVersion, @"24w14a")) {
                requiredJavaVersion = MAX(requiredJavaVersion, 21);
            }
        }
        
        // If the calculated required version is higher than the minVersion, use it
        // Only adjust if user hasn't explicitly selected a higher version
        // preferredJavaVersion already contains the value from earlier assignment
        if (requiredJavaVersion > minVersion && preferredJavaVersion <= 0) {
            // Only auto-adjust if user hasn't made an explicit Java version choice
            minVersion = requiredJavaVersion;
            NSLog(@"[JavaLauncher] Auto-adjusted Java version requirement for Minecraft %@ to Java %d", minecraftVersion, minVersion);
        } else if (requiredJavaVersion > minVersion && preferredJavaVersion > 0) {
            // If user has made an explicit choice but it's too low for this MC version, warn them
            if (preferredJavaVersion < requiredJavaVersion) {
                minVersion = requiredJavaVersion;
                NSLog(@"[JavaLauncher] Adjusted Java version requirement for Minecraft %@ from user's setting (Java %d) to required Java %d", minecraftVersion, preferredJavaVersion, minVersion);
            } else {
                // User has selected a sufficient version, keep their choice
                minVersion = preferredJavaVersion;
                NSLog(@"[JavaLauncher] Using user's selected Java version %d for Minecraft %@", minVersion, minecraftVersion);
            }
        }
        
        if (minVersion <= 8) {
            defaultJRETag = @"1_16_5_older";
        } else {
            defaultJRETag = @"1_17_newer";
        }

                // Setup AMETHYST_RENDERER
        NSString *renderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
        
        // Apply Minecraft version-specific renderer requirements
        if (minecraftVersion) {
            // From Minecraft 1.21.5 onwards, only MobileGlues renderer works properly
            if (minecraftVersionIsGreaterOrEqualTo(minecraftVersion, @"1.21.5") || isSnapshotVersionGreaterOrEqualTo(minecraftVersion, @"24w35a")) {
                // Force MobileGlues renderer for Minecraft 1.21.5+
                renderer = @ RENDERER_NAME_MOBILEGLUES;
                NSLog(@"[JavaLauncher] Forcing MobileGlues renderer for Minecraft %@ (1.21.5+)", minecraftVersion);
            }
        }
        
        NSLog(@"[JavaLauncher] RENDERER is set to %@\n", renderer);
        setenv("AMETHYST_RENDERER", renderer.UTF8String, 1);
        // Setup gameDir
        gameDir = [NSString stringWithFormat:@"%s/instances/%@/%@",
            getenv("POJAV_HOME"), getPrefObject(@"general.game_directory"),
            [PLProfiles resolveKeyForCurrentProfile:@"gameDir"]]
            .stringByStandardizingPath;
    } else {
        defaultJRETag = @"execute_jar";
        gameDir = @(getenv("POJAV_GAME_DIR"));
        launchJar = YES;
    }
    NSLog(@"[JavaLauncher] Looking for Java %d or later", minVersion);
    NSString *javaHome = getSelectedJavaHome(defaultJRETag, minVersion);

    if (javaHome == nil) {
        UIKit_returnToSplitView();
        BOOL isExecuteJar = [defaultJRETag isEqualToString:@"execute_jar"];
        showDialog(localize(@"Error", nil), [NSString stringWithFormat:localize(@"java.error.missing_runtime", nil),
            isExecuteJar ? [launchTarget lastPathComponent] : PLProfiles.current.selectedProfile[@"lastVersionId"], minVersion]);
        return 1;
    } else if ([javaHome hasPrefix:@(getenv("POJAV_HOME"))]) {
        // Symlink libawt_xawt.dylib
        NSString *dest = [NSString stringWithFormat:@"%@/lib/libawt_xawt.dylib", javaHome];
        NSString *source = [NSString stringWithFormat:@"%@/Frameworks/libawt_xawt.dylib", NSBundle.mainBundle.bundlePath];
        NSError *error;
        [fm createSymbolicLinkAtPath:dest withDestinationPath:source error:&error];
        if (error) {
            NSLog(@"[JavaLauncher] Symlink libawt_xawt.dylib failed: %@", error.localizedDescription);
        }
    }

    setenv("JAVA_HOME", javaHome.UTF8String, 1);
    NSLog(@"[JavaLauncher] JAVA_HOME has been set to %@", javaHome);

    int allocmem;
    if (getPrefBool(@"java.auto_ram")) {
        CGFloat autoRatio = getEntitlementValue(@"com.apple.private.memorystatus") ? 0.4 : 0.25;
        allocmem = roundf((NSProcessInfo.processInfo.physicalMemory >> 20) * autoRatio);
    } else {
        allocmem = getPrefInt(@"java.allocated_memory");
    }
    NSLog(@"[JavaLauncher] Max RAM allocation is set to %d MB", allocmem);
    if (!validateVirtualMemorySpace(allocmem)) {
        UIKit_returnToSplitView();
        showDialog(localize(@"Error", nil), @"Insufficient contiguous virtual memory space. Lower memory allocation and try again.");
        return 1;
    }

    int margc = -1;
    const char *margv[1000];

    margv[++margc] = [NSString stringWithFormat:@"%@/bin/java", javaHome].UTF8String;
    margv[++margc] = "-XstartOnFirstThread";
    if (!launchJar) {
        margv[++margc] = "-Djava.system.class.loader=net.kdt.pojavlaunch.PojavClassLoader";
    }
    margv[++margc] = "-Xms128M";
    margv[++margc] = [NSString stringWithFormat:@"-Xmx%dM", allocmem].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Djava.library.path=%@/Frameworks", NSBundle.mainBundle.bundlePath].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.dir=%@", gameDir].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.home=%s", getenv("POJAV_HOME")].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.timezone=%@", NSTimeZone.localTimeZone.name].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-DUIScreen.maximumFramesPerSecond=%d", (int)UIScreen.mainScreen.maximumFramesPerSecond].UTF8String;
    margv[++margc] = "-Dorg.lwjgl.glfw.checkThread0=false";
    margv[++margc] = "-Dorg.lwjgl.system.allocator=system";
    //margv[++margc] = "-Dorg.lwjgl.util.NoChecks=true";
    margv[++margc] = "-Dlog4j2.formatMsgNoLookups=true";

    // Preset OpenGL libname
    const char *glLibName = getenv("AMETHYST_RENDERER");
    if (glLibName) {
        if (!strcmp(glLibName, "auto")) {
            // workaround only applies to 1.20.2+
            glLibName = RENDERER_NAME_MTL_ANGLE;
        }
        margv[++margc] = [NSString stringWithFormat:@"-Dorg.lwjgl.opengl.libname=%s", glLibName].UTF8String;
    }

    NSString *librariesPath = [NSString stringWithFormat:@"%@/libs", NSBundle.mainBundle.bundlePath];
    margv[++margc] = [NSString stringWithFormat:@"-javaagent:%@/patchjna_agent.jar=", librariesPath].UTF8String;
    if(getPrefBool(@"general.cosmetica")) {
        margv[++margc] = [NSString stringWithFormat:@"-javaagent:%@/arc_dns_injector.jar=23.95.137.176", librariesPath].UTF8String;
    }

    // 添加authlib-injector参数以支持第三方认证账户的皮肤显示
    if ([username length] > 0 && [BaseAuthenticator.current isKindOfClass:[ThirdPartyAuthenticator class]]) {
        BaseAuthenticator *currentAuth = BaseAuthenticator.current;
        if (currentAuth.authData[@"authserver"] != nil) {
            NSLog(@"[JavaLauncher] Adding authlib-injector arguments for third party account");
            NSArray *authlibArgs = [(ThirdPartyAuthenticator *)currentAuth getJvmArgsForAuthlib];
            if (authlibArgs.count > 0) {
                for (NSString *arg in authlibArgs) {
                    margv[++margc] = arg.UTF8String;
                    NSLog(@"[JavaLauncher] Added authlib-injector arg: %s", arg.UTF8String);
                }
            } else {
                NSLog(@"[JavaLauncher] Warning: No authlib-injector arguments available");
            }
        }
    }

    // Workaround random stack guard allocation crashes
    margv[++margc] = "-XX:+UnlockExperimentalVMOptions";
    margv[++margc] = "-XX:+DisablePrimordialThreadGuardPages";

    // Disable Forge 1.16.x early progress window
    margv[++margc] = "-Dfml.earlyprogresswindow=false";

    // Load java
    NSString *libjlipath8 = [NSString stringWithFormat:@"%@/lib/jli/libjli.dylib", javaHome]; // java 8
    NSString *libjlipath11 = [NSString stringWithFormat:@"%@/lib/libjli.dylib", javaHome]; // java 11+
    BOOL isJava8 = [fm fileExistsAtPath:libjlipath8];
    setenv("INTERNAL_JLI_PATH", (isJava8 ? libjlipath8 : libjlipath11).UTF8String, 1);
    void* libjli = dlopen(getenv("INTERNAL_JLI_PATH"), RTLD_GLOBAL);

    if (!libjli) {
        const char *error = dlerror();
        NSLog(@"[Init] JLI lib = NULL: %s", error);
        UIKit_returnToSplitView();
        showDialog(localize(@"Error", nil), @(error));
        return 1;
    }

    // Setup Caciocavallo
    margv[++margc] = "-Djava.awt.headless=false";
    margv[++margc] = "-Dcacio.font.fontmanager=sun.awt.X11FontManager";
    margv[++margc] = "-Dcacio.font.fontscaler=sun.font.FreetypeFontScaler";
    margv[++margc] = [NSString stringWithFormat:@"-Dcacio.managed.screensize=%dx%d", width, height].UTF8String;
    margv[++margc] = "-Dswing.defaultlaf=javax.swing.plaf.metal.MetalLookAndFeel";
    if (isJava8) {
        // Setup Caciocavallo
        margv[++margc] = "-Dawt.toolkit=net.java.openjdk.cacio.ctc.CTCToolkit";
        margv[++margc] = "-Djava.awt.graphicsenv=net.java.openjdk.cacio.ctc.CTCGraphicsEnvironment";
    } else {
        // Required by Cosmetica to inject DNS
        margv[++margc] = "--add-opens=java.base/java.net=ALL-UNNAMED";

        // Setup Caciocavallo
        margv[++margc] = "-Dawt.toolkit=com.github.caciocavallosilano.cacio.ctc.CTCToolkit";
        margv[++margc] = "-Djava.awt.graphicsenv=com.github.caciocavallosilano.cacio.ctc.CTCGraphicsEnvironment";

        // Required by Caciocavallo17 to access internal API
        margv[++margc] = "--add-exports=java.desktop/java.awt=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/java.awt.peer=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.awt.image=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.java2d=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/java.awt.dnd.peer=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.awt=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.awt.event=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.awt.datatransfer=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.font=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.base/sun.security.action=ALL-UNNAMED";
        margv[++margc] = "--add-opens=java.base/java.util=ALL-UNNAMED";
        margv[++margc] = "--add-opens=java.desktop/java.awt=ALL-UNNAMED";
        margv[++margc] = "--add-opens=java.desktop/sun.font=ALL-UNNAMED";
        margv[++margc] = "--add-opens=java.desktop/sun.java2d=ALL-UNNAMED";
        margv[++margc] = "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED";

        // TODO: workaround, will be removed once the startup part works without PLaunchApp
        margv[++margc] = "--add-exports=cpw.mods.bootstraplauncher/cpw.mods.bootstraplauncher=ALL-UNNAMED";
    }

    // Add Caciocavallo bootclasspath
    NSString *cacio_classpath = [NSString stringWithFormat:@"-Xbootclasspath/%s", isJava8 ? "p" : "a"];
    NSString *cacio_libs_path = [NSString stringWithFormat:@"%@/libs_caciocavallo%s", NSBundle.mainBundle.bundlePath, isJava8 ? "" : "17"];
    NSArray *files = [fm contentsOfDirectoryAtPath:cacio_libs_path error:nil];
    for(NSString *file in files) {
        if ([file hasSuffix:@".jar"]) {
            cacio_classpath = [NSString stringWithFormat:@"%@:%@/%@", cacio_classpath, cacio_libs_path, file];
        }
    }
    margv[++margc] = cacio_classpath.UTF8String;

    if (!getEntitlementValue(@"com.apple.developer.kernel.extended-virtual-addressing")) {
        // In jailed environment, where extended virtual addressing entitlement isn't
        // present (for free dev account), allocating compressed space fails.
        // FIXME: does extended VA allow allocating compressed class space?
        margv[++margc] = "-XX:-UseCompressedClassPointers";
    }

    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        for (NSString *arg in launchTarget[@"arguments"][@"jvm_processed"]) {
            margv[++margc] = arg.UTF8String;
        }
    }

    init_loadCustomJvmFlags(&margc, (const char **)margv);
    NSLog(@"[Init] Found JLI lib");

    NSString *classpath = [NSString stringWithFormat:@"%@/*", librariesPath];
    if (launchJar) {
        classpath = [classpath stringByAppendingFormat:@":%@", launchTarget];
    }
    margv[++margc] = "-cp";
    margv[++margc] = classpath.UTF8String;
    margv[++margc] = "net.kdt.pojavlaunch.PojavLauncher";

    if (launchJar) {
        margv[++margc] = "-jar";
    } else {
        margv[++margc] = username.UTF8String;
    }

    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        margv[++margc] = [launchTarget[@"id"] UTF8String];
    } else {
        margv[++margc] = [launchTarget UTF8String];
    }
    //margv[++margc] = "ghidra.GhidraRun";

    pJLI_Launch = (JLI_Launch_func *)dlsym(libjli, "JLI_Launch");

    if (NULL == pJLI_Launch) {
        NSLog(@"[Init] JLI_Launch = NULL");
        return -2;
    }

    NSLog(@"[Init] Calling JLI_Launch");

    // Cr4shed known issue: exit after crash dump,
    // reset signal handler so that JVM can catch them
    signal(SIGSEGV, SIG_DFL);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGBUS, SIG_DFL);
    signal(SIGILL, SIG_DFL);
    signal(SIGFPE, SIG_DFL);

    // Free split VC
    tmpRootVC = nil;

    return pJLI_Launch(++margc, margv,
                   0, NULL, // sizeof(const_jargs) / sizeof(char *), const_jargs,
                   0, NULL, // sizeof(const_appclasspath) / sizeof(char *), const_appclasspath,
                   // These values are ignored in Java 17, so keep it anyways
                   "1.8.0-internal",
                   "1.8",

                   "java", "openjdk",
                   /* (const_jargs != NULL) ? JNI_TRUE : */ JNI_FALSE,
                   JNI_TRUE, JNI_FALSE, JNI_TRUE);
}
