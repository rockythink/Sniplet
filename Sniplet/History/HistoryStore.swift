import CoreGraphics
import Foundation
import ImageIO
import SwiftData

nonisolated enum HistoryStoreFactory {
    @concurrent
    static func make(rootURL: URL, limits: HistoryLimits = .production) async throws -> HistoryStore {
        guard limits.maxCount > 0, limits.maxBytes > 0 else { throw HistoryError.invalidLimits }
        let files = FileManager.default
        try files.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let schema = Schema([HistoryRecord.self])
        let configuration = ModelConfiguration(
            "SnipletHistory", schema: schema,
            url: rootURL.appendingPathComponent("history.store"),
            allowsSave: true, cloudKitDatabase: .none
        )
        // Failure here must never run file recovery or replace an existing database.
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = HistoryStore(modelContainer: container)
        try await store.prepare(rootURL: rootURL, limits: limits)
        return store
    }
}

@ModelActor
actor HistoryStore {
    private var root: URL?
    private var limits = HistoryLimits.production
    private let encoder = ImageEncoder()
    private var cleanupIDs: Set<UUID> = []
    private var cleanupError: String?
    private var recoveryMessages: [String] = []
    private var claims: [UUID: UUID] = [:]
    private var thumbnailTasks: [UUID: Task<Data, any Error>] = [:]
    private var mutationGeneration: UInt64 = 0
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    private var directory: URL {
        guard let root else { preconditionFailure("HistoryStore must be created with HistoryStoreFactory") }
        return root
    }
    private var ledgerURL: URL { directory.appendingPathComponent("cleanup.json") }
    private func imageURL(_ id: UUID) -> URL { directory.appendingPathComponent("images/\(id.uuidString).png") }
    private func thumbnailURL(_ id: UUID) -> URL { directory.appendingPathComponent("thumbnails/\(id.uuidString).png") }
    private func stagedImageURL(_ id: UUID) -> URL { directory.appendingPathComponent("staging/\(id.uuidString).png") }
    private func stagedThumbnailURL(_ id: UUID) -> URL { directory.appendingPathComponent("staging/\(id.uuidString)-thumb.png") }

    fileprivate func prepare(rootURL: URL, limits: HistoryLimits) async throws {
        root = rootURL
        self.limits = limits
        modelContext.autosaveEnabled = false
        // Fetch the complete database BEFORE examining/removing any image files.
        let records = try allRecords()
        for name in ["images", "thumbnails", "staging"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        var canCleanFiles = true
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            do { cleanupIDs = Set(try JSONDecoder().decode([UUID].self, from: Data(contentsOf: ledgerURL))) }
            catch {
                cleanupError = "历史清理记录无法读取，未删除任何图片；已暂停新增历史。"
                canCleanFiles = false
            }
        }
        let liveIDs = Set(records.map(\.id))
        // A crash before metadata save may leave a cleanup intent for a still-live record.
        cleanupIDs.subtract(liveIDs)
        cleanupIDs.formUnion(try orphanIDs(excluding: liveIDs))
        do { try removeMissingFinals(from: records) }
        catch {
            cleanupError = HistoryError.cleanupRequired.localizedDescription
            return
        }
        guard canCleanFiles else { return }
        do {
            try persistCleanupIDs()
            try performCleanup()
            // Staging is owned exclusively by this store and contains no committed data.
            for url in try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("staging"), includingPropertiesForKeys: nil) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            cleanupError = HistoryError.cleanupRequired.localizedDescription
            return
        }
        var rebuiltCount = 0
        var unreadableCount = 0
        var thumbnailFailureCount = 0
        for record in try allRecords() {
            guard !FileManager.default.fileExists(atPath: thumbnailURL(record.id).path) else { continue }
            let image: CGImage
            do { image = try decode(Data(contentsOf: imageURL(record.id))) }
            catch {
                // Preserve the final file and its row for explicit user recovery/deletion.
                record.ocrStatusRawValue = HistoryOCRStatus.failed.rawValue
                record.ocrText = ""
                unreadableCount += 1
                continue
            }
            do {
                let data = try await encoder.thumbnail(image, maxPixelSize: 320)
                try data.write(to: thumbnailURL(record.id), options: .atomic)
                record.byteCount = try diskByteCount(record.id)
                rebuiltCount += 1
            } catch {
                thumbnailFailureCount += 1
            }
        }
        if rebuiltCount > 0 { recoveryMessages.append("已从最终图片重建 \(rebuiltCount) 张缺失的缩略图。") }
        if unreadableCount > 0 { recoveryMessages.append("有 \(unreadableCount) 张最终图片无法读取；文件和记录已保留，其余历史仍可使用。") }
        if thumbnailFailureCount > 0 { recoveryMessages.append("有 \(thumbnailFailureCount) 张缩略图暂时无法重建；最终图片已保留，重启时将重试。") }
        try modelContext.save()
        do { try enforceLimits() }
        catch { cleanupError = HistoryError.cleanupRequired.localizedDescription }
    }

    func status() -> HistoryStorageStatus {
        HistoryStorageStatus(recoveryMessages: recoveryMessages, cleanupError: cleanupError)
    }

    func changes() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func notify() { for observer in observers.values { observer.yield(()) } }

    func insert(_ capture: RenderedCapture, pngData: Data) async throws {
        guard cleanupError == nil, cleanupIDs.isEmpty else { throw HistoryError.cleanupRequired }
        if try record(capture.id) != nil { return }
        let generation = mutationGeneration
        let thumbnailTask: Task<Data, any Error>
        if let existing = thumbnailTasks[capture.id] {
            thumbnailTask = existing
        } else {
            thumbnailTask = Task { [encoder, image = capture.image] in
                try await encoder.thumbnail(image, maxPixelSize: 320)
            }
            thumbnailTasks[capture.id] = thumbnailTask
        }
        defer { thumbnailTasks.removeValue(forKey: capture.id) }
        let thumbnail = try await thumbnailTask.value
        try Task.checkCancellation()
        guard generation == mutationGeneration else { throw HistoryError.changedDuringInsert }
        guard cleanupError == nil, cleanupIDs.isEmpty else { throw HistoryError.cleanupRequired }
        if try record(capture.id) != nil { return }
        let (bytes, overflow) = Int64(pngData.count).addingReportingOverflow(Int64(thumbnail.count))
        guard !overflow, bytes <= limits.maxBytes else { throw HistoryError.itemTooLarge }
        // Nothing becomes searchable until BOTH final files exist and save succeeds.
        do {
            try pngData.write(to: stagedImageURL(capture.id), options: .atomic)
            try thumbnail.write(to: stagedThumbnailURL(capture.id), options: .atomic)
            try FileManager.default.moveItem(at: stagedImageURL(capture.id), to: imageURL(capture.id))
            try FileManager.default.moveItem(at: stagedThumbnailURL(capture.id), to: thumbnailURL(capture.id))
            modelContext.insert(HistoryRecord(capture: capture, byteCount: bytes))
            try modelContext.save()
        } catch {
            modelContext.rollback()
            cleanupIDs.insert(capture.id)
            do { try persistCleanupIDs(); try performCleanup() }
            catch { cleanupError = HistoryError.cleanupRequired.localizedDescription }
            notify()
            throw error
        }
        notify()
        do { try enforceLimits() }
        catch {
            cleanupError = HistoryError.cleanupRequired.localizedDescription
            notify()
            throw error
        }
    }

    func summaries(matching query: String = "") throws -> [HistorySummary] {
        try allRecords().map(summary).filter { $0.matches(query) }
    }

    func loadImage(_ id: UUID) throws -> RenderedCapture {
        guard let record = try record(id), let mode = CaptureMode(rawValue: record.modeRawValue) else {
            throw HistoryError.missingRecord
        }
        let image = try decode(Data(contentsOf: imageURL(id)))
        return RenderedCapture(id: id, revision: 0, createdAt: record.createdAt, mode: mode, image: image, sourceScale: 1)
    }

    func pngData(for id: UUID) throws -> Data {
        guard try record(id) != nil else { throw HistoryError.missingRecord }
        return try Data(contentsOf: imageURL(id))
    }

    func thumbnailData(for id: UUID) throws -> Data {
        guard try record(id) != nil else { throw HistoryError.missingRecord }
        return try Data(contentsOf: thumbnailURL(id))
    }

    func thumbnailImage(for id: UUID) throws -> CGImage {
        try decode(thumbnailData(for: id))
    }

    func delete(_ id: UUID) throws {
        mutationGeneration &+= 1
        claims.removeValue(forKey: id)
        if cleanupError != nil { try retryCleanup() }
        guard let record = try record(id) else { return }
        try removeRecords([record])
    }

    func clear() throws {
        mutationGeneration &+= 1
        claims.removeAll()
        if cleanupError != nil { try retryCleanup() }
        try removeRecords(allRecords())
    }

    func retryCleanup() throws {
        // The database, never a damaged manifest, is the authority for live files.
        let records = try allRecords()
        let liveIDs = Set(records.map(\.id))
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            do {
                cleanupIDs.formUnion(try JSONDecoder().decode([UUID].self, from: Data(contentsOf: ledgerURL)))
            } catch {
                recoveryMessages.append("清理记录损坏，已按完整历史记录重新核对待清理文件。")
            }
        }
        cleanupIDs.subtract(liveIDs)
        cleanupIDs.formUnion(try orphanIDs(excluding: liveIDs))
        do {
            try removeMissingFinals(from: records)
            try persistCleanupIDs()
            try performCleanup()
            for url in try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("staging"), includingPropertiesForKeys: nil) {
                try FileManager.default.removeItem(at: url)
            }
            cleanupError = nil
            try enforceLimits()
            notify()
        } catch {
            cleanupError = HistoryError.cleanupRequired.localizedDescription
            notify()
            throw error
        }
    }

    func nextPendingOCR() throws -> HistoryOCRWork? {
        guard cleanupError == nil else { throw HistoryError.cleanupRequired }
        guard let record = try allRecords().reversed().first(where: {
            $0.ocrStatusRawValue == HistoryOCRStatus.pending.rawValue && claims[$0.id] == nil
        }) else { return nil }
        let image: CGImage
        do { image = try loadImage(record.id).image }
        catch {
            record.ocrStatusRawValue = HistoryOCRStatus.failed.rawValue
            record.ocrText = ""
            do { try modelContext.save() }
            catch { modelContext.rollback(); throw error }
            notify()
            throw HistoryError.invalidImage
        }
        let token = UUID()
        claims[record.id] = token
        return HistoryOCRWork(id: record.id, token: token, image: image)
    }

    func releaseOCR(_ work: HistoryOCRWork) {
        if claims[work.id] == work.token {
            claims.removeValue(forKey: work.id)
            notify()
        }
    }

    func completeOCR(_ work: HistoryOCRWork, text: String?, failed: Bool) throws {
        guard claims[work.id] == work.token else { return }
        defer { claims.removeValue(forKey: work.id) }
        guard let record = try record(work.id), record.ocrStatusRawValue == HistoryOCRStatus.pending.rawValue else { return }
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        record.ocrText = failed ? "" : text
        record.ocrStatusRawValue = (failed ? HistoryOCRStatus.failed : (text.isEmpty ? .empty : .ready)).rawValue
        do { try modelContext.save() }
        catch { modelContext.rollback(); throw error }
        notify()
    }

    func retryOCR(_ id: UUID) throws {
        guard let record = try record(id), record.ocrStatusRawValue == HistoryOCRStatus.failed.rawValue else { return }
        record.ocrStatusRawValue = HistoryOCRStatus.pending.rawValue
        record.ocrText = ""
        do { try modelContext.save() }
        catch { modelContext.rollback(); throw error }
        notify()
    }

    private func allRecords() throws -> [HistoryRecord] {
        let records = try modelContext.fetch(FetchDescriptor<HistoryRecord>())
        return records.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString > $1.id.uuidString
        }
    }

    private func removeMissingFinals(from records: [HistoryRecord]) throws {
        let missing = records.filter { !FileManager.default.fileExists(atPath: imageURL($0.id).path) }
        guard !missing.isEmpty else { return }
        cleanupIDs.formUnion(missing.map(\.id))
        try persistCleanupIDs()
        for record in missing {
            claims.removeValue(forKey: record.id)
            modelContext.delete(record)
        }
        do { try modelContext.save() }
        catch { modelContext.rollback(); throw error }
        recoveryMessages.append("已移除 \(missing.count) 条缺少最终图片的不可用历史。")
    }

    private func record(_ id: UUID) throws -> HistoryRecord? {
        var descriptor = FetchDescriptor<HistoryRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func summary(_ record: HistoryRecord) throws -> HistorySummary {
        guard let mode = CaptureMode(rawValue: record.modeRawValue),
              let status = HistoryOCRStatus(rawValue: record.ocrStatusRawValue) else {
            throw HistoryError.invalidMetadata
        }
        return HistorySummary(id: record.id, createdAt: record.createdAt, mode: mode,
                              pixelWidth: record.pixelWidth, pixelHeight: record.pixelHeight, byteCount: record.byteCount,
                              ocrStatus: status, ocrText: record.ocrText)
    }

    private func enforceLimits() throws {
        let records = try allRecords()
        var count = records.count
        var bytes = records.reduce(Int64(0)) { $0 + $1.byteCount }
        var victims: [HistoryRecord] = []
        for record in records.reversed() {
            guard count > limits.maxCount || bytes > limits.maxBytes else { break }
            victims.append(record)
            count -= 1
            bytes -= record.byteCount
        }
        if !victims.isEmpty { try removeRecords(victims) }
    }

    private func removeRecords(_ records: [HistoryRecord]) throws {
        guard !records.isEmpty else { return }
        cleanupIDs.formUnion(records.map(\.id))
        // Write-ahead cleanup intent survives termination between metadata save and unlink.
        do { try persistCleanupIDs() }
        catch {
            cleanupError = HistoryError.cleanupRequired.localizedDescription
            notify()
            throw error
        }
        for record in records {
            claims.removeValue(forKey: record.id)
            modelContext.delete(record)
        }
        do { try modelContext.save() }
        catch {
            modelContext.rollback()
            cleanupIDs.subtract(records.map(\.id))
            do { try persistCleanupIDs() }
            catch { cleanupError = HistoryError.cleanupRequired.localizedDescription }
            throw error
        }
        notify()
        do { try performCleanup() }
        catch {
            cleanupError = HistoryError.cleanupRequired.localizedDescription
            notify()
            throw HistoryError.cleanupRequired
        }
    }

    private func orphanIDs(excluding liveIDs: Set<UUID>) throws -> Set<UUID> {
        var result: Set<UUID> = []
        for name in ["images", "thumbnails"] {
            let entries = try FileManager.default.contentsOfDirectory(
                at: directory.appendingPathComponent(name), includingPropertiesForKeys: nil
            )
            for url in entries where url.pathExtension == "png" {
                if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !liveIDs.contains(id) {
                    result.insert(id)
                }
            }
        }
        return result
    }

    private func persistCleanupIDs() throws {
        let data = try JSONEncoder().encode(cleanupIDs.sorted { $0.uuidString < $1.uuidString })
        try data.write(to: ledgerURL, options: .atomic)
    }

    private func performCleanup() throws {
        for id in cleanupIDs {
            for url in [imageURL(id), thumbnailURL(id), stagedImageURL(id), stagedThumbnailURL(id)] {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
        }
        cleanupIDs.removeAll()
        try persistCleanupIDs()
    }

    private func diskByteCount(_ id: UUID) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey]
        let image = try imageURL(id).resourceValues(forKeys: keys).fileSize ?? 0
        let thumbnail = try thumbnailURL(id).resourceValues(forKeys: keys).fileSize ?? 0
        return Int64(image) + Int64(thumbnail)
    }

    private func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw HistoryError.invalidImage
        }
        return image
    }
}
