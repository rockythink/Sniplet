import AppKit
import SwiftUI

/// The guide: menu bar「使用指南…」, reopening the app, and the welcome's last hint.
final class GuideWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let selection: GuideSelection

    init(coordinator: AppCoordinator, section: GuideSection) {
        selection = GuideSelection(section: section)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Sniplet 使用指南"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = NSSize(width: 640, height: 420)
        super.init(window: window)
        window.contentView = NSHostingView(rootView: GuideView(coordinator: coordinator, selection: selection))
        window.delegate = self
        if !window.setFrameUsingName("Sniplet.Guide") { window.center() }
        window.setFrameAutosaveName("Sniplet.Guide")
    }

    required init?(coder: NSCoder) { nil }

    func present(section: GuideSection? = nil) {
        if let section { selection.section = section }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        onClose?()
        onClose = nil
    }
}

/// Lets the menu or a reopen jump an already open guide to another section.
@Observable final class GuideSelection {
    var section: GuideSection?
    init(section: GuideSection) { self.section = section }
}

private struct GuideView: View {
    let coordinator: AppCoordinator
    @Bindable var selection: GuideSelection

    var body: some View {
        NavigationSplitView {
            List(GuideSection.allCases, selection: $selection.section) { section in
                Label(section.title, systemImage: section.symbol)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            if let section = selection.section {
                GuideDetail(section: section, content: coordinator.guideContent,
                            showWelcome: { coordinator.showWelcome() })
                    .id(section)
            } else {
                ContentUnavailableView("选择一个主题", systemImage: "book")
            }
        }
    }
}

private struct GuideDetail: View {
    let section: GuideSection
    let content: GuideContent
    let showWelcome: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(section.title).font(.title.weight(.semibold))
                ForEach(content.blocks(for: section), id: \.self) { block in
                    GuideBlockView(block: block)
                }
                if section == .start {
                    Button("重新显示欢迎引导…", action: showWelcome)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct GuideBlockView: View {
    let block: GuideBlock

    var body: some View {
        switch block {
        case let .text(text):
            Text(text).fixedSize(horizontal: false, vertical: true)
        case let .list(items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.element) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                        Text(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case let .shortcuts(title, items):
            VStack(alignment: .leading, spacing: 8) {
                if let title { Text(title).font(.headline) }
                GuideShortcutList(items: items)
            }
        case let .question(question, answer):
            VStack(alignment: .leading, spacing: 4) {
                Text(question).font(.headline)
                Text(answer).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Two aligned columns: keys, then what they do. Shared with the editor's `?` sheet.
struct GuideShortcutList: View {
    let items: [GuideShortcut]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(items, id: \.self) { item in
                GridRow {
                    Text(item.keys)
                        .font(.body.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: .rect(cornerRadius: 4))
                    Text(item.meaning)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
