import SwiftUI

struct HistoryView: View {
    @State private var model: HistoryViewModel
    @Bindable private var indexer: HistoryIndexer
    private let onCopy: (UUID) -> Void
    private let onSave: (UUID) -> Void
    private let onPin: (UUID) -> Void
    @State private var deletion: HistoryDeletion?

    init(store: HistoryStore, indexer: HistoryIndexer,
         onCopy: @escaping (UUID) -> Void, onSave: @escaping (UUID) -> Void, onPin: @escaping (UUID) -> Void) {
        _model = State(initialValue: HistoryViewModel(store: store))
        self.indexer = indexer
        self.onCopy = onCopy
        self.onSave = onSave
        self.onPin = onPin
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                if model.summaries.isEmpty {
                    ContentUnavailableView(
                        model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无历史" : "没有搜索结果",
                        systemImage: "clock",
                        description: Text(model.query.isEmpty ? "截图完成后会出现在这里" : "试试日期、文件名或图片中的文字")
                    )
                } else {
                    List(selection: $model.selection) {
                        ForEach(model.summaries) { summary in
                            historyRow(summary)
                                .tag(summary.id)
                                .contextMenu {
                                    Button("复制图像") { onCopy(summary.id) }
                                    Button("保存…") { onSave(summary.id) }
                                    Button("钉图") { onPin(summary.id) }
                                    if summary.ocrStatus == .failed {
                                        Button("重试识别") { indexer.retry(summary.id) }.disabled(!indexer.enabled)
                                    }
                                    Divider()
                                    Button("删除…", role: .destructive) { deletion = .record(summary.id) }
                                }
                        }
                    }
                    .listStyle(.sidebar)
                    .onDeleteCommand {
                        if let id = model.selection { deletion = .record(id) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            VStack(spacing: 0) {
                statusMessages
                if let capture = model.selectedCapture {
                    Image(decorative: capture.image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("选中的最终截图，\(capture.image.width) 乘 \(capture.image.height) 像素")
                } else if model.isLoadingImage {
                    ProgressView("正在读取图片…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("选择一张截图", systemImage: "photo", description: Text("历史保存最终图片，不保留原图或可编辑图层。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let selected = model.summaries.first(where: { $0.id == model.selection }) {
                    Divider()
                    HStack(spacing: 12) {
                        Text("\(selected.pixelWidth) × \(selected.pixelHeight) 像素")
                        Spacer()
                        Text(selected.ocrStatus.label)
                        if selected.ocrStatus == .failed {
                            Button("重试识别") { indexer.retry(selected.id) }.disabled(!indexer.enabled)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                }
            }
        }
        .navigationTitle("截图历史")
        .searchable(text: $model.query, placement: .toolbar, prompt: "搜索日期、文件名或文字")
        .toolbar {
            ToolbarItemGroup {
                Button { if let id = model.selection { onCopy(id) } } label: { Label("复制图像", systemImage: "doc.on.doc") }
                    .help("复制最终图像（⌘C）")
                    .keyboardShortcut("c", modifiers: .command)
                    .disabled(model.selectedCapture == nil)
                Button { if let id = model.selection { onSave(id) } } label: { Label("保存…", systemImage: "square.and.arrow.down") }
                    .help("保存 PNG（⌘S）")
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.selectedCapture == nil)
                Button { if let id = model.selection { onPin(id) } } label: { Label("钉图", systemImage: "pin") }
                    .help("将最终图片钉在桌面")
                    .disabled(model.selectedCapture == nil)
                Button { deletion = .all } label: { Label("清空历史…", systemImage: "trash") }
                    .help("清空所有本地历史；不会关闭已钉的图片")
            }
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 460, idealHeight: 600)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .alert(item: $deletion) { deletion in
            Alert(
                title: Text(deletion.isAll ? "清空所有历史？" : "删除这张截图？"),
                message: Text("删除本地最终图片、缩略图与文字索引，无法撤销。已钉在桌面的图片需单独关闭。"),
                primaryButton: .destructive(Text(deletion.isAll ? "清空历史" : "删除")) {
                    Task {
                        if case .record(let id) = deletion { await model.delete(id) }
                        else { await model.clear() }
                    }
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    private func historyRow(_ summary: HistorySummary) -> some View {
        HStack(spacing: 10) {
            Group {
                if let image = model.thumbnails[summary.id] {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 72, height: 54)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.createdAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.body)
                Text("\(summary.pixelWidth) × \(summary.pixelHeight) · \(summary.ocrStatus.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .task(id: summary.id) { await model.loadThumbnail(summary.id) }
    }

    @ViewBuilder
    private var statusMessages: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                Button("重新读取") { model.retryRead() }
            }
            if let error = model.storageStatus.cleanupError {
                Label(error, systemImage: "externaldrive.badge.exclamationmark")
                Button("重试清理") { Task { await model.retryCleanup() } }
            }
            if let error = indexer.errorMessage {
                Label(error, systemImage: "text.magnifyingglass")
                if indexer.enabled { Button("重试索引") { indexer.start() } }
            }
            if !indexer.enabled {
                Text("历史新增与后台识别已停用；已有截图仍可查看、复制、保存或钉图。")
            } else if indexer.activeID != nil {
                HStack { ProgressView().controlSize(.small); Text("正在本机识别历史文字…") }
            }
            ForEach(Array(model.storageStatus.recoveryMessages.enumerated()), id: \.offset) { _, message in
                Label(message, systemImage: "info.circle")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .accessibilityElement(children: .contain)
    }
}

private enum HistoryDeletion: Identifiable {
    case record(UUID), all
    var id: String { if case .record(let id) = self { id.uuidString } else { "all" } }
    var isAll: Bool { if case .all = self { true } else { false } }
}
