import CoreGraphics
import Foundation
import Observation

/// One-time hints beside the editor toolbar during the first captures.
nonisolated enum EditorTip: String, CaseIterable, Sendable {
    case output, tools, style, areaActions, repeatAndHistory
}

/// In order, each tip at most once, skipping what the user already found on their own.
nonisolated struct EditorTipLedger: Equatable, Sendable {
    var shown: Set<EditorTip> = []
    var discovered: Set<EditorTip> = []

    var next: EditorTip? {
        EditorTip.allCases.first { !shown.contains($0) && !discovered.contains($0) }
    }
}

@Observable final class EditorTips {
    private let defaults: UserDefaults
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }
    private(set) var ledger: EditorTipLedger {
        didSet {
            defaults.set(ledger.shown.map(\.rawValue).sorted(), forKey: Self.shownKey)
            defaults.set(ledger.discovered.map(\.rawValue).sorted(), forKey: Self.discoveredKey)
        }
    }
    private static let enabledKey = "tips.enabled"
    private static let shownKey = "tips.shown"
    private static let discoveredKey = "tips.discovered"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        func tips(_ key: String) -> Set<EditorTip> {
            Set((defaults.stringArray(forKey: key) ?? []).compactMap(EditorTip.init(rawValue:)))
        }
        ledger = EditorTipLedger(shown: tips(Self.shownKey), discovered: tips(Self.discoveredKey))
    }

    /// The tip for a capture that is about to open, if any is still due.
    var next: EditorTip? { isEnabled ? ledger.next : nil }

    func markShown(_ tip: EditorTip) {
        guard !ledger.shown.contains(tip) else { return }
        ledger.shown.insert(tip)
    }

    func discovered(_ tip: EditorTip) {
        guard !ledger.discovered.contains(tip) else { return }
        ledger.discovered.insert(tip)
    }

    func reset() {
        ledger = EditorTipLedger()
        isEnabled = true
    }
}

extension EditorTip {
    /// Shortcut names come from the user's bindings, as in the guide.
    nonisolated func message(regionShortcut: String?, previousRegionShortcut: String?) -> String {
        switch self {
        case .output:
            "Return 或 ⌘C 复制并关闭 · ⌘S 存到文件夹 · 按住右侧保存按钮可以直接拖出"
        case .tools:
            "按字母键切换工具：A 箭头 · R 矩形 · T 文字 · M 马赛克 · 按 ? 查看全部快捷键"
        case .style:
            "工具条上的 ✨ 美化可以加圆角、阴影和背景；右侧的钉图会把截图留在屏幕最上层"
        case .areaActions:
            "右侧工具条可以改为录制这块区域，或延迟 3、5、10 秒再截"
                + (regionShortcut.map { "；录屏时再按 \($0) 停止" } ?? "")
        case .repeatAndHistory:
            (previousRegionShortcut.map { "\($0) 直接重复上次区域" } ?? "菜单栏「重复上次区域」不用重新框选")
                + "；菜单栏「截图历史…」可以按文字搜索以前的截图"
        }
    }
}

/// Places the tip beside the primary toolbar, on the side away from the capture when it
/// fits; a toolbar already inside the capture (full-screen shots) lets the tip follow it.
nonisolated enum EditorTipPlacement {
    static let gap: CGFloat = 8

    static func frame(size: CGSize, primary: CGRect, side: CGRect, capture: CGRect, in safe: CGRect) -> CGRect? {
        let width = min(size.width, safe.width - 2 * gap)
        guard width > 0, size.height > 0 else { return nil }
        let x = min(max(primary.minX, safe.minX + gap), safe.maxX - gap - width)
        let below = CGRect(x: x, y: primary.minY - gap - size.height, width: width, height: size.height)
        let above = CGRect(x: x, y: primary.maxY + gap, width: width, height: size.height)
        // The side of the toolbar farther from the capture comes first.
        let candidates = primary.midY < capture.midY ? [below, above] : [above, below]
        let usable = candidates.filter { safe.contains($0) && !$0.intersects(side) }
        if let clear = usable.first(where: { !$0.intersects(capture) }) { return clear }
        return primary.intersects(capture) ? usable.first : nil
    }
}
