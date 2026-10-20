import Foundation
import Observation

@MainActor
@Observable
final class HistoryIndexer {
    private let store: HistoryStore
    private let ocr: OCRService
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private(set) var isRunning = false
    private(set) var activeID: UUID?
    private(set) var errorMessage: String?
    private(set) var enabled = false

    init(store: HistoryStore, ocr: OCRService) {
        self.store = store
        self.ocr = ocr
    }

    isolated deinit { task?.cancel() }

    func start() {
        enabled = true
        guard task == nil else { return }
        generation &+= 1
        let generation = generation
        errorMessage = nil
        isRunning = true
        task = Task { [weak self, store, ocr] in
            let changes = await store.changes()
            do {
                for await _ in changes {
                    try Task.checkCancellation()
                    while !Task.isCancelled {
                        guard let work = try await store.nextPendingOCR() else { break }
                        guard let owner = self, owner.generation == generation else {
                            await store.releaseOCR(work)
                            return
                        }
                        owner.activeID = work.id
                        let text: String?
                        let failed: Bool
                        do {
                            text = try await ocr.recognize(work.image).text
                            failed = false
                        } catch is CancellationError {
                            await store.releaseOCR(work)
                            throw CancellationError()
                        } catch {
                            text = nil
                            failed = true
                        }
                        guard !Task.isCancelled, self?.generation == generation else {
                            await store.releaseOCR(work)
                            throw CancellationError()
                        }
                        // Store validates its lease and existence again: deletion never resurrects a record.
                        try await store.completeOCR(work, text: text, failed: failed)
                        self?.activeID = nil
                    }
                }
            } catch is CancellationError {
                // A pending record remains pending, so a later explicit start can resume it.
            } catch {
                if self?.generation == generation {
                    self?.errorMessage = "历史文字索引已暂停，保存索引或读取图片失败。请检查磁盘后重试。"
                }
            }
            if self?.generation == generation {
                self?.activeID = nil
                self?.isRunning = false
                self?.task = nil
            }
        }
    }

    func stop() {
        enabled = false
        generation &+= 1
        task?.cancel()
        task = nil
        activeID = nil
        isRunning = false
    }

    func retry(_ id: UUID) {
        guard enabled else {
            errorMessage = "历史已停用。重新开启历史后可以重试文字识别；已有图片仍可查看和导出。"
            return
        }
        Task { [weak self, store] in
            do {
                try await store.retryOCR(id)
                self?.start()
            } catch {
                self?.errorMessage = "无法保存重试状态，请检查磁盘后重试。"
            }
        }
    }
}
