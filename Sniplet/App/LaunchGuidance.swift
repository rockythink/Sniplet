import Foundation

/// Which one-time sheet a launch shows: the introduction for new users, or a short
/// "what's new" for users upgrading past a release whose notes they have not seen.
nonisolated enum LaunchGuidance: Equatable {
    case introduction, whatsNew, none

    /// Bump with each release that has notes worth one alert; earlier builds stored nothing (0).
    static let notesRevision = 1
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
        · 重复上次区域（⌃⌥⌘4）：不用重新框选，直接截同一块区域
        · 截图历史：选中后把大图直接拖到聊天窗口或 Finder
        · 序号标注（N）：点一下放一个 ①②③，删除后自动补位
        · 文字可调字号、加粗（⌘B、⌘+/⌘−），还能加一块底色
        · 保存与拖出合成一个按钮：单击保存，按住拖出

        快捷键可在设置 → 快捷键中修改。
        """
}
