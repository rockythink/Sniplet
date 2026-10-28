import Foundation

/// Which one-time sheet a launch shows: the introduction for new users, or a short
/// "what's new" for users upgrading past a release whose notes they have not seen.
nonisolated enum LaunchGuidance: Equatable {
    case introduction, whatsNew, none

    /// Bump with each release that has notes worth one alert; earlier builds stored nothing (0).
    static let notesRevision = 4
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
        · 新的使用指南：菜单栏「使用指南…」，按主题查看截图、标注、输出、录屏和常见问题；截图时按 ? 可以随时查看编辑快捷键
        · 截图时在桌面、菜单栏或 Dock 等空白处单击，直接截取整个屏幕
        · 设置 → 通用里可以打开「登录时打开 Sniplet」
        · 前几次截图时，工具条旁会出现一条简短提示，看过就不再显示；不需要可以在设置 → 通用里关闭

        快捷键可在设置 → 快捷键中修改。
        """
}
