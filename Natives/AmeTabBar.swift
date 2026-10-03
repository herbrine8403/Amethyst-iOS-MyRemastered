// ===========================================================================
//  ★ [SWIFT-BAR] AmeTabBar.swift —— 底部标签栏(系统 SwiftUI TabView)
//  ---------------------------------------------------------------------------
//  为什么要用 SwiftUI(前三轮的实测结论,见 _uibuild/TABC_REPORT.md、
//  _uibuild/SYS_TABBAR_REPORT.md):
//    · v1 裸 UITabBar(游离在 UITabBarController 之外)在 iOS 26 上【不给文字】;
//    · v2 真 UITabBarController + UITabBarAppearance(stacked) 会把标题摆到图标
//      【右边】(inline 版式),容器 68→92 也救不回来(截图 md5 与 ② 完全相同);
//    · 参考对象 LiveContainer(LiveContainerSwiftUI/Views/LCTabView.swift)其实
//      只有一句 `TabView { … .tabItem { Label(…) } }`,没有任何自绘 / appearance。
//  ⇒ 本文件照它的做法:纯 SwiftUI TabView + 5 个 .tabItem { Label },
//    **外观一个字节都不自定义**(玻璃 / 圆角 / 图标在上中文在下的版式全交给系统),
//    只负责三件事:
//      ① 5 项菜单(★ 已按用户指示删掉「多人游戏」);
//      ② 选中时广播 ObjC 通知 AmeTabSelected(userInfo = @{@"index": @(v)});
//      ③ 暴露 setIconSize: / setHeight: / setStyle: 三个可调口(UserDefaults 键)。
//
//  与 ObjC 的边界(只有两条):
//    入口 = +[AmeTabBarHost makeHostWithTag:] → 一个 UIViewController(当子 VC 用)
//    出口 = NSNotificationCenter 通知名 "AmeTabSelected"
//    ObjC 侧(LauncherMenuViewController.m)只做:
//      挂子 VC → 四边铺满容器 → 监听通知 → handleMenuSelection:(导航语义不变)。
// ===========================================================================
import SwiftUI
import UIKit

// MARK: - ★ 约定:通知名 / UserDefaults 键

/// 选中标签时广播的通知名。ObjC 侧用
/// [[NSNotificationCenter defaultCenter] addObserver:… name:@"AmeTabSelected"]
/// 监听;userInfo = @{@"index": @(v)}(v 是 0…4 的菜单下标)。
/// 注意:Swift 的 NotificationCenter.default 就是 ObjC 的 defaultCenter,名字逐字一致。
let AmeTabSelectedNotificationName = "AmeTabSelected"

/// ★ 三个可调项的 UserDefaults 键(设置页 LauncherPreferencesViewController 的接线点),
/// 也是 ObjC 侧 +[AmeTabBarHost setXxx:] 写入的键:
///   ameTabStyle    : 0 = 悬浮胶囊(默认) / 1 = 满宽
///   ameTabHeight   : 56…96,默认 83
///   ameTabIconSize : 20…44,默认 34(SF Symbol pointSize)
enum AmeTabBarPrefKey {
    static let style    = "ameTabStyle"
    static let height   = "ameTabHeight"
    static let iconSize = "ameTabIconSize"
}

// MARK: - 菜单定义(★ 5 项;id == tag == ObjC menuItems 下标,一一对应)

struct AmeTabItem: Identifiable {
    let id: Int          // == menuItems 下标
    let title: String    // 中文短名(标签栏宽度有限,统一两字 / AI)
    let symbol: String   // SF Symbol
}

/// ★ 5 项,与 LauncherMenuViewController.m 的 menuItems 顺序严格一致(无「多人游戏」):
///   0 实例 · 1 下载 · 2 AI · 3 资源 · 4 设置
let AmeTabItems: [AmeTabItem] = [
    AmeTabItem(id: 0, title: "主页", symbol: "house.fill"),
    AmeTabItem(id: 1, title: "下载", symbol: "arrow.down.circle.fill"),
    AmeTabItem(id: 2, title: "AI",   symbol: "sparkles"),
    AmeTabItem(id: 3, title: "实例", symbol: "square.stack.3d.up.fill"),
    AmeTabItem(id: 4, title: "设置", symbol: "gearshape.fill"),
]

// MARK: - 状态

/// 宿主持有的选中态。@Published 让 SwiftUI 重新渲染;真正的“广播”在 AmeBar 的
/// 自定义 Binding 里做(只有用户点击才会走 setter ⇒ 不会误发通知)。
final class AmeBarModel: ObservableObject {
    @Published var selection: Int = 0
}

// MARK: - 视图

/// 底栏本体。除了 `TabView + .tabItem { Label }` 之外不加任何外观修饰 ——
/// 玻璃与「图标上 / 文字下」的版式全部来自系统,这正是 LiveContainer 的做法。
struct AmeBar: View {
    @Binding var sel: Int

    /// 图标大小(SF Symbol pointSize):默认 34,键 ameTabIconSize(20…44)。
    /// 只作用在图标上,标题保持系统字号(否则 34pt 会把标题也顶到 34pt)。
    @AppStorage("ameTabIconSize") private var iconSize: Double = 34

    /// ★ 选中绑定:用户点标签 → 写 sel 并同步广播 AmeTabSelected。
    ///   用自定义 Binding 而不是 .onChange,保证“一次点击 = 一次广播”,且初值不广播。
    private var ameSelection: Binding<Int> {
        Binding(get: { sel },
                set: { newValue in
                    guard newValue != sel else { return }   // 同值不重复广播
                    sel = newValue
                    NotificationCenter.default.post(
                        name: Notification.Name(AmeTabSelectedNotificationName),
                        object: nil,
                        userInfo: ["index": newValue])
                })
    }

    var body: some View {
        TabView(selection: ameSelection) {
            ForEach(AmeTabItems) { item in
                Color.clear
                    .tabItem {
                        Label {
                            Text(item.title)
                        } icon: {
                            Image(systemName: item.symbol)
                                .font(.system(size: CGFloat(iconSize)))
                        }
                    }
                    .tag(item.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 宿主根视图:把 ObservableObject 投影成 AmeBar 需要的 @Binding。
struct AmeBarRoot: View {
    @ObservedObject var model: AmeBarModel
    var body: some View {
        AmeBar(sel: $model.selection)
    }
}

// MARK: - 宿主控制器(把 SwiftUI view 当子 VC 交给 ObjC 的容器)

final class AmeTabBarHostController: UIViewController {

    private let tag: Int
    private let model = AmeBarModel()
    private var healTimer: Timer?
    private var healTicks = 0

    init(tag: Int) {
        self.tag = tag
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { healTimer?.invalidate() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let hc = UIHostingController(rootView: AmeBarRoot(model: model))
        hc.view.backgroundColor = .clear
        hc.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(hc)
        view.addSubview(hc.view)
        NSLayoutConstraint.activate([
            hc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hc.view.topAnchor.constraint(equalTo: view.topAnchor),
            hc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hc.didMove(toParent: self)

        model.selection = tag          // 初始选中(不广播:只有用户点击才广播)
        applySizeHints()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyUnselectedTint()
        _ = healIcons()                // 冷启首调用竞态:先补一次
        startIconSelfHeal()            // 再交给有界重试(与 ObjC 版旧实现同策略)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyUnselectedTint()          // 原生 tabBar 是懒创建的 ⇒ 每次布局都补一次
    }

    // MARK: 可调项

    /// ameTabHeight:只作为“强烈建议尺寸”报告给上层(preferredContentSize)。
    /// 真正的落点由 ObjC 容器约束决定(竖屏 LauncherRootViewController.m 的 92.0),
    /// 不做硬约束 ⇒ 永远不会和父容器的四边约束打架。
    private func applySizeHints() {
        let raw = UserDefaults.standard.object(forKey: AmeTabBarPrefKey.height) as? Double
        let h = min(max(raw ?? 83, 56), 96)
        preferredContentSize = CGSize(width: UIView.noIntrinsicMetric, height: CGFloat(h))
    }

    /// 未选中项着色(旧 applyCustomAppearance 的能力)。只改 tint,
    /// 不碰 UITabBarAppearance / 背景 ⇒ 系统液态玻璃不受影响。
    func applyUnselectedTint() {
        guard let bar = findTabBar() else { return }
        bar.unselectedItemTintColor = AmeTabBarHost.unselectedTintColor()
    }

    // MARK: 图标自愈(沿用 ObjC 版策略:0.25s × 有界重试,只补 nil 的项)

    private func startIconSelfHeal() {
        guard healTimer == nil else { return }
        healTicks = 0
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.healTicks += 1
            let allLoaded = self.healIcons()
            if (allLoaded && self.healTicks >= 8) || self.healTicks >= 40 {
                timer.invalidate()
                self.healTimer = nil
            }
        }
        RunLoop.main.add(t, forMode: .common)
        healTimer = t
    }

    /// 只补 image == nil 的项(不覆盖系统已经渲染好的图标)。
    @discardableResult
    private func healIcons() -> Bool {
        guard let bar = findTabBar(), let items = bar.items else { return false }
        let raw = UserDefaults.standard.object(forKey: AmeTabBarPrefKey.iconSize) as? Double
        let pt = min(max(raw ?? 34, 20), 44)
        var allLoaded = true
        for (i, item) in items.enumerated() where i < AmeTabItems.count {
            if item.image != nil { continue }
            allLoaded = false
            let cfg = UIImage.SymbolConfiguration(pointSize: CGFloat(pt), weight: .regular)
            if let img = UIImage(systemName: AmeTabItems[i].symbol, withConfiguration: cfg) {
                item.image = img
            }
        }
        return allLoaded
    }

    private func findTabBar() -> UITabBar? { findTabBar(in: view) }

    private func findTabBar(in root: UIView) -> UITabBar? {
        if let bar = root as? UITabBar { return bar }
        for sub in root.subviews {
            if let bar = findTabBar(in: sub) { return bar }
        }
        return nil
    }
}

// MARK: - ★ ObjC 入口(唯一被 ObjC 引用的类)

/// ★ ObjC 侧只用这个类(选择器即 @objc 导出名):
///   UIViewController *bar = [AmeTabBarHost makeHostWithTag:0];
///   [AmeTabBarHost setIconSize:34];
///   [AmeTabBarHost setHeight:83];
///   [AmeTabBarHost setStyle:0];
///   [AmeTabBarHost setUnselectedTintColor:color];   // 可传 nil(回系统默认)
///
/// 本文件不生成 -Swift.h(CMake 直接编 .o,不产 module),所以 ObjC 侧用手写
/// 前向声明(见 LauncherMenuViewController.m),选择器必须与这里逐字一致。
@objc(AmeTabBarHost)
public final class AmeTabBarHost: NSObject {

    /// 活着的宿主(弱引用):setXxx: 能即时作用到已挂上的底栏。
    private static let hosts = NSHashTable<AmeTabBarHostController>.weakObjects()
    private static var tint: UIColor?

    static func unselectedTintColor() -> UIColor? { tint }

    /// 建宿主(返回的子 VC 内部 view 会在自己的 viewDidLoad 里铺满自己的 view;
    /// ObjC 侧拿到后把它的 view 四边钉到容器即可)。tag = 初始选中下标。
    /// 选择器显式写成 makeHostWithTag:,与 ObjC 侧前向声明逐字一致(不靠命名推断)。
    @objc(makeHostWithTag:)
    public static func makeHost(tag: Int) -> UIViewController {
        let vc = AmeTabBarHostController(tag: tag)
        hosts.add(vc)
        return vc
    }

    /// 图标大小(20…44,写 UserDefaults 键 ameTabIconSize)。
    /// @AppStorage 会即时刷新;同时把值钳进区间,避免设置页传进离谱数字。
    @objc(setIconSize:)
    public static func setIconSize(_ size: Double) {
        let v = min(max(size, 20), 44)
        UserDefaults.standard.set(v, forKey: AmeTabBarPrefKey.iconSize)
    }

    /// 底栏高度建议(56…96,写 UserDefaults 键 ameTabHeight)。
    /// 真正落点 = ObjC 容器约束(LauncherRootViewController.m 竖屏 92.0),见报告接线点。
    @objc(setHeight:)
    public static func setHeight(_ height: Double) {
        let v = min(max(height, 56), 96)
        UserDefaults.standard.set(v, forKey: AmeTabBarPrefKey.height)
        for vc in hosts.allObjects {
            vc.preferredContentSize = CGSize(width: UIView.noIntrinsicMetric, height: CGFloat(v))
        }
    }

    /// 版式(0 = 悬浮胶囊 / 1 = 满宽,写 UserDefaults 键 ameTabStyle)。
    @objc(setStyle:)
    public static func setStyle(_ style: Int) {
        UserDefaults.standard.set(style == 1 ? 1 : 0, forKey: AmeTabBarPrefKey.style)
    }

    /// 未选中项着色(旧 applyCustomAppearance 的能力)。
    /// 只改 unselectedItemTintColor,不碰 UITabBarAppearance / 背景 ⇒ 玻璃不受影响。
    /// 未建宿主时也能调用:颜色暂存,建宿主时自动应用。
    @objc(setUnselectedTintColor:)
    public static func setUnselectedTintColor(_ color: UIColor?) {
        tint = color
        for vc in hosts.allObjects { vc.applyUnselectedTint() }
    }
}
