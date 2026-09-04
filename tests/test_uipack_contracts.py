from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
NATIVES = ROOT / "Natives"
CMAKE = (NATIVES / "CMakeLists.txt").read_text()
UI_PACK_MANAGER = (NATIVES / "PLUIPackManager.m").read_text()
UI_PACK_HEADER = (NATIVES / "PLUIPackManager.h").read_text()
THEME_MANAGER = (NATIVES / "PLThemeManager.m").read_text()
LUA_RUNTIME = (NATIVES / "PLLuaRuntime.m").read_text()
LUA_RUNTIME_H = (NATIVES / "PLLuaRuntime.h").read_text()
NODE_VIEW = (NATIVES / "PLUINodeView.m").read_text()
LAYOUT_ENGINE = (NATIVES / "PLUILayoutEngine.m").read_text()
LAYOUT_ENGINE_H = (NATIVES / "PLUILayoutEngine.h").read_text()
LINIT = (NATIVES / "external/lua/linit.c").read_text()
LUA_DIR = NATIVES / "external/lua"
SHELL_VC = (NATIVES / "PLUIShellViewController.m").read_text()
ACTION_ROUTER = (NATIVES / "PLUIActionRouter.m").read_text()
SCENE_DELEGATE = (NATIVES / "SceneDelegate.m").read_text()
PREFERENCES = (NATIVES / "PLPreferences.m").read_text()
PREF_VC = (NATIVES / "LauncherPreferencesViewController.m").read_text()
PACK_ROOT = NATIVES / "resources/themes/pcl-classic"
MAIN_LUA = (PACK_ROOT / "main.lua").read_text()
PACK_MANIFEST = (PACK_ROOT / "manifest.json").read_text()


class UIPackContracts(unittest.TestCase):
    """M3 UI 材质包契约：包管理器、Lua 沙箱、manifest 版本放宽。"""

    def test_ui_pack_manager_is_built(self):
        self.assertIn("PLUIPackManager.m", CMAKE)
        self.assertTrue((NATIVES / "PLUIPackManager.h").exists())
        self.assertTrue((NATIVES / "PLUIPackManager.m").exists())

    def test_lua_engine_is_vendored_and_built(self):
        # 引擎核心源码必须 vendored 且进入 CMake 构建
        for header in ("lua.h", "luaconf.h", "lualib.h", "lauxlib.h", "ljumptab.h"):
            self.assertTrue((LUA_DIR / header).exists(), f"missing {header}")
        self.assertIn("add_library(lua STATIC", CMAKE)
        self.assertIn("external/lua/linit.c", CMAKE)

    def test_lua_sandbox_drops_unsafe_libraries(self):
        # 编译期裁剪：脚本层永远无法触达 os/io/package/debug
        for forbidden in ("luaopen_os", "luaopen_io", "luaopen_package", "luaopen_debug"):
            self.assertNotIn(forbidden, LINIT)
        for allowed in ("luaopen_base", "luaopen_coroutine", "luaopen_table",
                        "luaopen_string", "luaopen_math", "luaopen_utf8"):
            self.assertIn(allowed, LINIT)

    def test_theme_manifest_accepts_ui_packs(self):
        # schemaVersion 2 = UI 材质包；纯颜色包（1）保持兼容
        self.assertIn("PLThemeMaxManifestVersion", THEME_MANAGER)
        self.assertIn("version > PLThemeMaxManifestVersion", THEME_MANAGER)
        self.assertIn('@"schemaVersion"', THEME_MANAGER)

    def test_entry_script_is_sandboxed(self):
        # 入口脚本只允许包根下的单段文件名，且限 256KB
        self.assertIn("PLUIPackMaxScriptBytes = 256 * 1024", UI_PACK_MANAGER)
        self.assertIn('isEqualToString:entry.lastPathComponent', UI_PACK_MANAGER)
        self.assertIn('containsString:@".."', UI_PACK_MANAGER)
        self.assertIn("PLUIPackSchemaVersion = 2", UI_PACK_MANAGER)

    def test_pack_discovery_reuses_theme_roots(self):
        # UI 包与主题包共用 themes/ 目录解析规则，不另起炉灶
        self.assertIn("rootForIdentifier", UI_PACK_MANAGER)
        self.assertIn("rootForIdentifier", (NATIVES / "PLThemeManager.h").read_text())

    def test_colors_only_pack_is_valid_state(self):
        # 纯颜色包（schemaVersion 1）→ activePack 为 nil 是合法状态而非错误
        self.assertIn("@property (nonatomic, nullable, readonly) PLUIPack *activePack", UI_PACK_HEADER)

    def test_lua_runtime_is_built(self):
        self.assertIn("PLLuaRuntime.m", CMAKE)
        # 主 target 必须链接 lua 静态库
        self.assertRegex(CMAKE, r"target_link_libraries\(AngelAuraAmethyst[^)]*lua")

    def test_runtime_has_no_file_or_network_bridges(self):
        # 沙箱契约：脚本运行时不得出现文件/网络 API，脚本层无法触达
        for forbidden in ("NSFileManager", "NSURLSession", "dataWithContentsOfFile", "NSURL"):
            self.assertNotIn(forbidden, LUA_RUNTIME, f"PLLuaRuntime.m must not use {forbidden}")

    def test_runtime_has_budgets_and_limits(self):
        # 内存限额 + 指令钩子超时 + 默认预算
        self.assertIn("PLLuaRuntimeMemoryCap", LUA_RUNTIME)
        self.assertIn("lua_sethook", LUA_RUNTIME)
        self.assertIn("buildTimeout", LUA_RUNTIME_H)
        self.assertIn("eventTimeout", LUA_RUNTIME_H)

    def test_launcher_api_surface(self):
        # 脚本可用的 view 句柄命令与动作回调
        self.assertIn("viewCommandHandler", LUA_RUNTIME_H)
        self.assertIn("actionHandler", LUA_RUNTIME_H)
        self.assertIn("dispatchEvent", LUA_RUNTIME_H)
        for cmd in ("setText", "setTextColor", "setImage", "setVisible", "setEnabled", "getText"):
            self.assertIn(cmd, LUA_RUNTIME)
        # prelude 必须提供全部节点构建器与 launcher 封装
        for kind in ("'row'", "'column'", "'button'", "'text'", "'image'", "'spacer'",
                     "'divider'", "'content'", "'nav'", "'panel'", "'tileGrid'"):
            self.assertIn(kind, LUA_RUNTIME)
        for name in ("ui.dimen", "launcher.view", "launcher.action", "launcher.log"):
            self.assertIn(name, LUA_RUNTIME)

    def test_layout_engine_is_built(self):
        self.assertIn("PLUINodeView.m", CMAKE)
        self.assertIn("PLUILayoutEngine.m", CMAKE)

    def test_tree_validation_limits(self):
        # 节点数 ≤ 500、深度 ≤ 12、恰好一个 content 挂载点
        self.assertIn("PLUILayoutMaxNodes = 500", LAYOUT_ENGINE)
        self.assertIn("PLUILayoutMaxDepth = 12", LAYOUT_ENGINE)
        self.assertIn("contentCount != 1", LAYOUT_ENGINE)

    def test_bad_tree_falls_back_to_default(self):
        # 回退链最后一环：程序化默认三栏树
        self.assertIn("defaultTree", LAYOUT_ENGINE_H)
        self.assertIn('@"content"', LAYOUT_ENGINE)
        self.assertIn('@"kind"', LAYOUT_ENGINE)

    def test_weighted_stack_layout(self):
        # 权重分配在容器 layoutSubviews 中完成，不依赖 UIStackView
        self.assertIn("layoutSubviews", NODE_VIEW)
        self.assertIn("weightSum", NODE_VIEW)
        self.assertIn("weightedAvail", NODE_VIEW)

    def test_corner_mask_outer_propagation(self):
        # cornerMask=outer：父容器递归传递外沿边，只圆贴外的角
        self.assertIn("outerEdges", NODE_VIEW)
        self.assertIn("maskedCorners", NODE_VIEW)
        self.assertIn("kCALayerMinXMinYCorner", NODE_VIEW)

    def test_value_refs_resolved(self):
        for ref in ("$color:", "$image:", "$i18n:", "sf:"):
            self.assertIn(ref, NODE_VIEW)

    def test_responsive_and_visibility(self):
        # responsive.phone 覆盖 + visibleWhen 条件显隐
        self.assertIn('@"responsive"', NODE_VIEW)
        self.assertIn('@"visibleWhen"', NODE_VIEW)
        self.assertIn('@"phone"', NODE_VIEW)


class ShellContracts(unittest.TestCase):
    """M3e/M3f 双轨壳契约：新壳、动作白名单、SceneDelegate 杀开关、内置包。"""

    def test_shell_and_router_are_built(self):
        for source in ("PLUIShellViewController.m", "PLUIActionRouter.m"):
            self.assertIn(source, CMAKE)
            self.assertTrue((NATIVES / source).exists())

    def test_shell_takes_over_show_notifications(self):
        # 新壳完整接管 13 个 Show* 通知
        for name in ("ShowHomePage", "ShowDownloadPage", "ShowVersionManager",
                     "ShowProfileEditor", "ShowSettings", "ShowAIPage",
                     "ShowMultiplayer", "ShowZeroTier", "ShowModsManager",
                     "ShowShadersManager", "ShowModpackImport",
                     "ShowGameDirectory", "ShowAccountManager"):
            self.assertIn(f'@"{name}"', SHELL_VC)

    def test_shell_preserves_historical_fixes(self):
        # 从旧壳搬迁的三处历史修复必须保留
        self.assertIn("viewController == self.contentViewController", SHELL_VC)  # 同实例跳过
        self.assertIn("deactivateConstraints", SHELL_VC)  # 约束先 deactivate
        self.assertIn("UIViewAnimationOptionTransitionCrossDissolve", SHELL_VC)  # 单 transition

    def test_shell_reload_chain_falls_back(self):
        # 回退链：选中包 → 程序化默认树；引擎建根失败抛异常给 SceneDelegate 兜底
        self.assertIn("buildTreeWithError", SHELL_VC)
        self.assertIn("PLUIShellBuildFailed", SHELL_VC)
        self.assertIn("engineWithTree", SHELL_VC)

    def test_shell_wires_runtime_events(self):
        for wire in ("viewCommandHandler", "actionHandler", "dispatchEvent:@\"onReady\""):
            self.assertIn(wire, SHELL_VC)

    def test_action_router_is_whitelist_only(self):
        # 绝不动态方法调用：白名单映射 + 未知动作 log 后 no-op
        self.assertIn("PLUIActionNotificationMap", ACTION_ROUTER)
        self.assertNotIn("NSSelectorFromString", ACTION_ROUTER)
        self.assertIn("unknown action ignored", ACTION_ROUTER)

    def test_action_router_covers_open_actions(self):
        for action in ("open:home", "open:download", "open:versionManager",
                       "open:settings", "open:ai", "open:mods", "open:shaders",
                       "open:modpackImport", "open:gameDirectory",
                       "open:accountManager", "open:profileEditor"):
            self.assertIn(f'@"{action}"', ACTION_ROUTER)

    def test_scene_delegate_has_kill_switch(self):
        # 双轨开关：engine 壳构建异常时写回 legacy 换回旧壳
        self.assertIn("PLUIShellViewController", SCENE_DELEGATE)
        self.assertIn("@try", SCENE_DELEGATE)
        self.assertIn('setPrefObject(@"general.ui_shell", @"legacy")', SCENE_DELEGATE)
        self.assertIn("UIShellChanged", SCENE_DELEGATE)

    def test_ui_shell_defaults_to_legacy(self):
        self.assertIn('@"ui_shell": @"legacy"', PREFERENCES)

    def test_settings_offer_shell_and_pack_pickers(self):
        self.assertIn('@"key": @"ui_shell"', PREF_VC)
        self.assertIn('@"key": @"theme_pack"', PREF_VC)
        self.assertIn("applyThemeIdentifier", PREF_VC)

    def test_builtin_pack_is_colors_only(self):
        # pcl-classic 保持纯颜色包（schemaVersion 1）：新引擎默认显示欢迎界面，
        # 内置 main.lua 仅作为脚本模板保留（导入到 uipack/active 才作为 UI 包生效）。
        self.assertIn('"schemaVersion": 1', PACK_MANIFEST)
        self.assertTrue((PACK_ROOT / "colors.json").exists())

    def test_welcome_screen_when_no_pack(self):
        # 无导入包 → 欢迎界面（不渲染引擎）；引擎异常也在壳内回欢迎界面，不再冒泡闪退
        self.assertIn("buildWelcomeView", SHELL_VC)
        self.assertIn("@try", SHELL_VC)
        self.assertIn("@catch", SHELL_VC)

    def test_welcome_screen_components(self):
        # 左：app 图标 + 标题；右：导入 / 获取 /（切旧引擎 | 反馈）
        self.assertIn("PLUIWelcomeAppIcon", SHELL_VC)
        self.assertIn("uipack.welcome.title", SHELL_VC)
        self.assertIn("uipack.welcome.import", SHELL_VC)
        self.assertIn("uipack.welcome.get", SHELL_VC)
        self.assertIn("uipack.welcome.legacy", SHELL_VC)
        self.assertIn("uipack.welcome.feedback", SHELL_VC)

    def test_welcome_actions(self):
        # 切旧引擎：写偏好 + UIShellChanged；反馈：pear issues；导入：文档选择器
        self.assertIn('setPrefObject(@"general.ui_shell", @"legacy")', SHELL_VC)
        self.assertIn("github.com/twoyears666/pear/issues", SHELL_VC)
        self.assertIn("UIDocumentPickerViewController", SHELL_VC)
        self.assertIn("importPackFromURL", SHELL_VC)

    def test_import_pack_contract(self):
        # 导入目标 uipack/active：staging 校验 → 原子替换；zip 先拷贝到 tmp 再解压
        self.assertIn("importPackFromURL", UI_PACK_HEADER)
        self.assertIn('stringByAppendingPathComponent:@"uipack/active"', UI_PACK_MANAGER)
        self.assertIn("active-staging", UI_PACK_MANAGER)
        self.assertIn("hoistWrappedRootDirectoryIfNeeded", UI_PACK_MANAGER)
        self.assertIn("validateImportedPackAtRoot", UI_PACK_MANAGER)
        self.assertIn("startAccessingSecurityScopedResource", UI_PACK_MANAGER)

    def test_imported_pack_takes_priority(self):
        # reload 优先级：导入包（uipack/active，不校验目录名）→ theme_pack 指向的 UI 包
        self.assertIn("loadPackAtRoot", UI_PACK_MANAGER)
        self.assertIn("expectedIdentifier:nil", UI_PACK_MANAGER)

    def test_builtin_pack_lua_contract(self):
        # 入口脚本：describe + build(ui)，恰好一个 content 挂载点，含事件函数
        self.assertIn("function describe()", MAIN_LUA)
        self.assertIn("function build(ui)", MAIN_LUA)
        self.assertEqual(MAIN_LUA.count("ui.content {"), 1)
        for handler in ("function onReady()", "function onAccountChange("):
            self.assertIn(handler, MAIN_LUA)
        # 脚本限额 256KB
        self.assertLessEqual(len(MAIN_LUA.encode("utf-8")), 256 * 1024)

    def test_builtin_pack_uses_only_whitelisted_actions(self):
        # main.lua 中引用的 action 必须全部在路由器白名单内
        import re
        actions = set(re.findall(r'action = "([^"]+)"', MAIN_LUA))
        self.assertTrue(actions, "main.lua should reference at least one action")
        for action in actions:
            self.assertIn(f'@"{action}"', ACTION_ROUTER, f"action {action} not whitelisted")


if __name__ == "__main__":
    unittest.main()


class UINodeLayoutContracts(unittest.TestCase):
    """节点布局引擎契约：文字按钮铺满节点、嵌套容器可测量（PCL2 包前置修复）。"""

    def test_button_fills_node_bounds(self):
        # 此前按钮按 min(宽,高) 居中成正方形，宽文字按钮（启动按钮）文字被裁切
        self.assertIn("if (self.button) self.button.frame = self.bounds;", NODE_VIEW)
        self.assertNotIn("CGFloat side = MIN(self.bounds.size.width, self.bounds.size.height);", NODE_VIEW)

    def test_nested_container_autosize(self):
        # 嵌套 row/column 在父栈中必须能测出聚合首选尺寸，否则高度塌为 0
        self.assertIn("if (self.horizontalStack || self.verticalStack) {", NODE_VIEW)
        self.assertIn("main += self.spacing * (CGFloat)(count - 1);", NODE_VIEW)

    def test_image_intrinsic_query_guard(self):
        # 固有尺寸查询（双向 CGFLOAT_MAX）时直接返回原始尺寸，避免 aspect-fit 比例溢出
        self.assertIn("if (size.width >= CGFLOAT_MAX && size.height >= CGFLOAT_MAX) return s;", NODE_VIEW)


class UIPackCrashRegressionContracts(unittest.TestCase):
    """启动闪退回归：activePack copy 崩溃 + dispatch_once 内异常不可捕获（Amethyst 5.0.0 实机日志）。"""

    def test_active_pack_property_is_strong(self):
        # PLUIPack 未实现 NSCopying：copy 修饰的 activePack 在 reload 赋值时
        # 调 copyWithZone: 必崩（默认主题 pcl-classic 即 schemaVersion 2，启动必触发）
        self.assertIn("@property (nonatomic, nullable, strong, readwrite) PLUIPack *activePack", UI_PACK_MANAGER)
        self.assertNotIn("copy, readwrite) PLUIPack *activePack", UI_PACK_MANAGER)

    def test_shared_manager_init_has_no_side_effects(self):
        # dispatch_once 块内抛出的 ObjC 异常无法被调用方 @try 捕获，
        # 会击穿欢迎界面兜底直接闪退：单例初始化只允许纯 new，reload 由壳显式调用
        self.assertIn("manager = [PLUIPackManager new];", UI_PACK_MANAGER)
        self.assertNotIn("[manager reload]", UI_PACK_MANAGER)
        # 壳在 @try 内先 reload 再取 activePack（异常 → 欢迎界面兜底）
        self.assertIn("[PLUIPackManager.sharedManager reload];", SHELL_VC)
