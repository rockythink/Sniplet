import Foundation

/// Which one-time sheet a launch shows: the introduction for new users, or a short
/// "what's new" for users upgrading past a release whose notes they have not seen.
nonisolated enum LaunchGuidance: Equatable {
    case introduction, whatsNew, none

    /// Bump with each release that has notes worth one alert; earlier builds stored nothing (0).
    static let notesRevision = 3
    static let introductionKey = "app.hasShownIntroduction"
    static let notesKey = "app.seenWhatsNewRevision"

    static func next(hasShownIntroduction: Bool, seenNotesRevision: Int) -> Self {
        if !hasShownIntroduction { return .introduction }
        return seenNotesRevision < notesRevision ? .whatsNew : .none
    }

    static func next(in defaults: UserDefaults) -> Self {
        next(hasShownIntroduction: defaults.bool(forKey: introductionKey),
             seenNotesRevision: defaults.integer(forKey: notesKey))
    }

    /// The introduction already covers everything, so both sheets mark the notes as seen.
    static func markShown(in defaults: UserDefaults) {
        defaults.set(true, forKey: introductionKey)
        defaults.set(notesRevision, forKey: notesKey)
    }

    static let whatsNewTitle = "Sniplet 有这些新变化"
    static let whatsNewText = """
        · 支持自动更新：菜单栏「检查更新…」，或在设置 → 更新里打开自动检查。联网只用于检查和下载更新，不上传任何内容
        · 先选区域（框选、窗口或整屏），工具栏里多了两个功能：
          录制这块区域：直接录成 MP4，点红框旁的「停止」或再按 ⇧⌘A 结束，录完可预览
          延迟截图：选 3、5、10 秒，选框留在原处、中间倒计时，这期间照常操作其他 App，时间到自动截好
        · ⌘S 直接存到选定的文件夹，不再弹窗；⇧⌘S 另存为
        · 美化可加纯色或渐变背景，发微信不再出现白边

        快捷键可在设置 → 快捷键中修改。
        """
}
