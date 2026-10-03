// ★ [GAP-SYNC] Imported verbatim from Gsjsjzhznsz/Air-Minecraft-iOS-Launcher @ ui/e-design-1 (intentprobe/). See tree510/COMPETITOR_GAP_PROVENANCE.md.
import AppIntents
import Foundation

enum RendererOption: String, AppEnum {
    case metal, mobileglues, auto
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Renderer")
    static var caseDisplayRepresentations: [RendererOption: DisplayRepresentation] = [
        .metal: "Metal", .mobileglues: "MobileGlues", .auto: "Auto"
    ]
}

struct LaunchVersionIntent: AppIntent {
    static let title: LocalizedStringResource = "Launch Amethyst Version"
    static let description = IntentDescription("Launch Amethyst with a specific version")
    static var openAppWhenRun: Bool = true
    @Parameter(title: "Version")
    var version: String
    init() { self.version = "26.1" }
    init(version: String) { self.version = version }
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        UserDefaults.standard.set(version, forKey: "amethyst.pendingVersion")
        return .result(value: "requested " + version)
    }
}

struct SetRendererIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Amethyst Renderer"
    static let description = IntentDescription("Set the graphics renderer")
    static var openAppWhenRun: Bool = true
    @Parameter(title: "Renderer")
    var renderer: RendererOption
    init() { self.renderer = .metal }
    init(renderer: RendererOption) { self.renderer = renderer }
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        UserDefaults.standard.set(renderer.rawValue, forKey: "amethyst.renderer")
        return .result(value: "renderer=" + renderer.rawValue)
    }
}

struct AmethystShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LaunchVersionIntent(), phrases: ["Launch Amethyst version"], shortTitle: "Launch", systemImageName: "play.fill")
        AppShortcut(intent: SetRendererIntent(), phrases: ["Set Amethyst renderer"], shortTitle: "Renderer", systemImageName: "cpu")
    }
}
