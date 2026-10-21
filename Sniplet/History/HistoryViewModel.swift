import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class HistoryViewModel {
    private let store: HistoryStore
    var query = "" { didSet { scheduleSearch() } }
    var selection: UUID? { didSet { if selection != oldValue { loadSelection() } } }
    private(set) var summaries: [HistorySummary] = []
    private(set) var selectedCapture: RenderedCapture?
    private(set) var isLoading = false
    private(set) var isLoadingImage = false
    private(set) var errorMessage: String?
    private(set) var storageStatus = HistoryStorageStatus(recoveryMessages: [], cleanupError: nil)
    private(set) var thumbnails: [UUID: CGImage] = [:]
    private var thumbnailOrder: [UUID] = []
    private(set) var thumbnailBytes = 0
    private let thumbnailLimit = 32 * 1024 * 1024
    private var querySequence: UInt64 = 0
    private var selectionSequence: UInt64 = 0
    private var searchTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var changesTask: Task<Void, Never>?
    private var loadingThumbnails: Set<UUID> = []

    init(store: HistoryStore) { self.store = store }

    isolated deinit {
        changesTask?.cancel()
        searchTask?.cancel()
        selectionTask?.cancel()
    }

    func start() {
        guard changesTask == nil else { return }
        loadSelection()
        changesTask = Task { [weak self, store] in
            let changes = await store.changes()
            for await _ in changes {
                guard !Task.isCancelled else { break }
                self?.scheduleSearch(debounce: false)
            }
        }
    }

    func stop() {
        querySequence &+= 1
        selectionSequence &+= 1
        changesTask?.cancel()
        searchTask?.cancel()
        selectionTask?.cancel()
        changesTask = nil
        selectedCapture = nil
        thumbnails.removeAll()
        thumbnailOrder.removeAll()
        thumbnailBytes = 0
    }

    func refresh() { scheduleSearch(debounce: false) }

    func retryRead() {
        errorMessage = nil
        refresh()
    }

    private func scheduleSearch(debounce: Bool = true) {
        querySequence &+= 1
        let sequence = querySequence
        let query = query
        searchTask?.cancel()
        searchTask = Task { [weak self, store] in
            do {
                if debounce { try await Task.sleep(for: .milliseconds(150)) }
                try Task.checkCancellation()
                self?.isLoading = true
                let summaries = try await store.summaries(matching: query)
                let status = await store.status()
                guard !Task.isCancelled, let self, self.querySequence == sequence else { return }
                self.summaries = summaries
                self.storageStatus = status
                self.isLoading = false
                let ids = Set(summaries.map(\.id))
                self.removeThumbnails(except: ids)
                if let selection = self.selection, !ids.contains(selection) {
                    self.selection = nil
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.querySequence == sequence else { return }
                self.errorMessage = "无法读取本地历史，请检查磁盘可用空间和访问权限。"
                self.isLoading = false
            }
        }
    }

    /// The selected final image as stored, for dragging it out of the history window.
    func encodedSelection() async throws -> EncodedCapture {
        guard let capture = selectedCapture else { throw CancellationError() }
        let data = try await store.pngData(for: capture.id)
        try Task.checkCancellation()
        return EncodedCapture(capture: capture, pngData: data)
    }

    func reportDragFailure(_ message: String) { errorMessage = message }

    private func loadSelection() {
        selectionSequence &+= 1
        let sequence = selectionSequence
        selectionTask?.cancel()
        selectedCapture = nil
        guard let id = selection else { isLoadingImage = false; return }
        isLoadingImage = true
        selectionTask = Task { [weak self, store] in
            do {
                let capture = try await store.loadImage(id)
                guard !Task.isCancelled, let self, self.selectionSequence == sequence, self.selection == id else { return }
                self.selectedCapture = capture
                self.isLoadingImage = false
            } catch {
                guard !Task.isCancelled, let self, self.selectionSequence == sequence else { return }
                self.errorMessage = "无法读取选中的最终图片。图片可能已删除或损坏。"
                self.isLoadingImage = false
            }
        }
    }

    func loadThumbnail(_ id: UUID) async {
        if thumbnails[id] != nil {
            thumbnailOrder.removeAll { $0 == id }
            thumbnailOrder.append(id)
            return
        }
        guard loadingThumbnails.insert(id).inserted else { return }
        defer { loadingThumbnails.remove(id) }
        do {
            let image = try await store.thumbnailImage(for: id)
            guard !Task.isCancelled, summaries.contains(where: { $0.id == id }) else { return }
            let cost = image.bytesPerRow * image.height
            guard cost <= thumbnailLimit else { return }
            while thumbnailBytes + cost > thumbnailLimit, let oldest = thumbnailOrder.first {
                evictThumbnail(oldest)
            }
            thumbnails[id] = image
            thumbnailOrder.append(id)
            thumbnailBytes += cost
        } catch {
            if !Task.isCancelled { errorMessage = "部分缩略图无法读取；重新打开应用可尝试从最终图片恢复。" }
        }
    }

    private func evictThumbnail(_ id: UUID) {
        if let image = thumbnails.removeValue(forKey: id) { thumbnailBytes -= image.bytesPerRow * image.height }
        thumbnailOrder.removeAll { $0 == id }
    }

    private func removeThumbnails(except ids: Set<UUID>) {
        for id in Array(thumbnails.keys) where !ids.contains(id) { evictThumbnail(id) }
    }

    func delete(_ id: UUID) async {
        do {
            try await store.delete(id)
            if selection == id { selection = nil }
            refresh()
        } catch {
            storageStatus = await store.status()
            errorMessage = "历史删除未完全完成。元数据可能已移除，但部分文件仍待清理；请重试清理。"
            refresh()
        }
    }

    func clear() async {
        do {
            try await store.clear()
            selection = nil
            refresh()
        } catch {
            storageStatus = await store.status()
            errorMessage = "历史清空未完全完成。部分文件可能仍待清理；请重试清理。"
            refresh()
        }
    }

    func retryCleanup() async {
        do {
            try await store.retryCleanup()
            errorMessage = nil
        } catch {
            errorMessage = "仍无法完成历史文件清理，新增历史继续暂停。请检查磁盘与文件权限。"
        }
        storageStatus = await store.status()
        refresh()
    }
}
