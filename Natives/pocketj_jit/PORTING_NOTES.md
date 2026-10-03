# PocketJ 内置 JIT(StikJIT + Helper 扩展 + XPC)移植说明

参考:EricoEC/PocketJLauncher · `Vendor/StikJIT/INTEGRATION.md`、`Vendor/StikJIT/Sources/*.swift`、
`JITIntegration/{Host,Helper,Shared}/*.swift`、`project.yml`、`XcodeRunner/PocketJLauncher.entitlements`。

评估报告(带行号的全景 + 逐项差异表)在仓库外:`D:\CTF\_POCKETJ_JIT_REPORT.md`。
本文件只留"在仓库里做事时最需要知道的那几条"。

---

## 1. 一句话结论

PocketJ 的"内置 JIT"不是把 StikDebug 的代码搬进宿主 App —— 它**必须是两个进程**:
宿主 App + 一个 **App Extension(Helper)**。宿主把 `targetPID + 配对文件 Data` 经 **XPC**
发给 Helper,Helper 内跑 StikJIT(idevice FFI)去 attach 目标的
debugserver 并执行 `universal.js`。

**进程不能给自己附加调试器**(`vAttach` 成功的瞬间自己被挂起,随后发不出 `D`)。
PocketJ 自己的 `Natives/stikdebug/StikDebugEngine.m` 里把这段 in-process attach 代码
整段 `#if 0` 掉并直接 `return NO`,注释原文:"不能在 PocketJ Launcher 进程内附加它自己。
请使用独立 JIT 执行进程。" —— 所以"把 JIT 获取改成本进程内联"这条路是死的,别走。

## 2. 我们已经有的(不用动)

| 能力 | 位置 |
|---|---|
| universal 协议 4 个裸函数 `PrepareRegion(1)` / `SendJITScript(2)` / `SetDetachAfterFirstBr(3)` / `PrepareRegionForPatching(4)` | `utils.m` |
| **`JIT26Detach`(x16=0)** `brk #0xf00d` | 本次补上(见 §4) |
| `brk #0x69` legacy + SIGTRAP 安全网 `JIT26CreateRegionLegacySafe` | `utils.m` |
| 调试器存活探针 `JIT26IsLikelyDebuggerKeepAttached` 等 | `utils.m` |
| JS 脚本 `UniversalJIT26.js` / `UniversalJIT26Extension.js` | `Natives/resources/`(与 PocketJ 的 universal.js **同源同内容**,仅日期头不同) |
| JIT 获取 URL 打开(auto/stikjit/sidestore/stosdebug/jitstreamer/trollstore/manual) | `JavaLauncher.m: ame139_requestJIT` |

## 3. 我们还没有的(内置 StikJIT 差什么)

1. **Vendor/StikJIT**(Swift framework):12 个 `Sources/*.swift` + `Resources/{universal,legacy}.js`
   + `idevice/libidevice_ffi.a`(需 `-force_load`)+ `iokit/StikJITIOKit.h`。
   链接 JavaScriptCore / Network / Security / CFNetwork / SystemConfiguration / IOKit。目标 iOS 17.4+。
   ⚠ 上游是 **AGPL-3.0**(`THIRD_PARTY_LICENSES/StikDebug-AGPL-3.0.txt`),混入本仓库前先确认许可口径。
2. **Helper 扩展**:`JITIntegration/Helper/PocketJJITHelper.swift`(`@main struct: AppExtension`)+
   自己的 `Info.plist`(`CFBundlePackageType=XPC!` + `EXAppExtensionAttributes/EXExtensionPointIdentifier`)。
   这是 **ExtensionKit 扩展**(不是老的 NSExtension),PocketJ 用 xcodegen 的
   `type: extensionkit-extension`,并在宿主 target 上开 `EX_ENABLE_EXTENSION_POINT_GENERATION=YES`。
3. **Host 协调层**:`PocketJJITCoordinator.swift`(iOS **26+** `AppExtensionProcess` + `XPCSession`)
   + `PocketJJITExtensionPoint.swift`(`@Definition static var pocketJJITHelper`)。
4. **XPC 协议**:`PocketJJITXPC.swift` —— `{targetPID:Int32, pairingData:Data}` →
   `{success:Bool, message:String}`;`@objc protocol PocketJJITXPCProtocol`。
5. **门禁 + 配对文件**:iOS ≥17.4、宿主 `get-task-allow`、`Documents/StikJIT/pairingFile.plist`。
   —— 本次已把门禁探测函数加进 `utils.m`(见 §4),配对文件位置也对齐了 PocketJ。

## 4. 本次改动(commit 里能看到的)

- `utils.m` / `utils.h`:
  - 新增 `JIT26Detach(void)` —— universal 协议第 0 号调用 `mov x16,#0; brk #0xf00d; ret`。
  - 新增 `JIT26DetachSafe(void)` —— 与 `JIT26CreateRegionLegacySafe` 同款 SIGTRAP 安全网。
  - 新增门禁:`AMEJITDeviceSupportsBuiltInStikJIT` / `AMEJITHasGetTaskAllow` /
    `AMEJITPairingFilePath` / `AMEJITHasPairingFile` / `AMEJITLogPocketJReadiness`。
- `JavaLauncher.m`: `ame139_requestJIT` 里(1)加门禁日志;(2)新增 `stikdebug` 使能方式
  → `stikdebug://enable-jit?bundle-id=..&pid=..&script-name=universal.js`(PocketJ INTEGRATION.md 的 StikDebug 形式)。
- `LauncherPreferencesViewController.m` + `en.lproj/Localizable.strings`: 新增 `stikdebug` 选项。
- `Info.plist`: `LSApplicationQueriesSchemes` 补 `stikdebug/stikjit/sidestore/trollstore/stosdebug`。

**没有**改 `CMakeLists.txt` / `Makefile` / CI —— 因为本次没有新增 `.m/.c/.swift` 源文件。
Helper 扩展 target **故意不做**(见 §5)。

## 5. ⚠ 为什么故意不做 CMake/CI 的 Helper 扩展 target

盲改风险太高,列清"差什么、怎么验":

- **构建系统**:本仓库是纯 CMake + Makefile(没有可用的 xcodeproj),而 ExtensionKit 扩展依赖
  Xcode 的 `extensionkit-extension` 产物类型与 `EX_ENABLE_EXTENSION_POINT_GENERATION`。
  CMake 里怎么产出 `.appex`(入口符号、`PlugIns/` 布局、`EXAppExtensionAttributes`)没有官方文档,
  本地无 Xcode 无法验证。
- **Swift 宏**:`PocketJJITHelper.swift` 用了 ExtensionFoundation 的 `@main: AppExtension`、
  `@AppExtensionPoint.Bind`、`@Definition`、`ConnectionHandler` —— 都是 **Swift 宏**,需要给
  `swiftc` 配 `-plugin-path`(SDK 的 `usr/lib/swift/host/plugins`)等。本仓库现有的
  `AmeTabBar.swift` 只用 `swiftc -parse-as-library -emit-object`,**不含宏**,不能照抄。
- **签名**:扩展是独立可执行体,要单独签名并嵌进 `PlugIns/`。本仓库用 `ldid` 单签名(`payload` 里
  `ldid -S ...app`),是否覆盖嵌套 appex、以及无 provisioning 的 TrollStore/侧载下 ExtensionKit
  是否肯加载,只能真机验。
- **二进制**:`libidevice_ffi.a` 要从 PocketJ 仓库取(未 vendored),大小/架构未核。

**建议做法**:先在 **有 Xcode 的机器**上用一份最小 xcodegen/xcodeproj 把 PocketJ 的
`StikJIT` + `PocketJJITHelper` + `PocketJJITCoordinator` 三个 target 编出来、跑通一次真机 attach,
再把它们的编译/链接参数(swiftc flags、`-force_load`、framework 列表、扩展入口)如实抄进 CMake。
在此之前不要动 CI。

## 6. 真机待验证清单

- [ ] 用 **StikDebug**(只注册 `stikdebug://` 的版本)走新 `stikdebug` 选项:`script-name=universal.js`
      能否被认到;认不到就说明 StikDebug 期望内联 `script-data`(那就继续用 `stikjit` 选项)。
- [ ] `AMEJITLogPocketJReadiness` 的日志在真机是否符合预期(`get-task-allow` 在 TrollStore/侧载下应为 YES)。
- [ ] `JIT26Detach` 尚未接进启动路径 —— 若要让"显式脱离"上线,必须先确认所有初始 RX 区
      都在脱离前完成 `PrepareRegion`(见 `utils.m` 内注释),否则 `dyld_bypass_validation.m`
      里裸 `brk` 会 SIGTRAP 崩。
