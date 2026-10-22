import Foundation
import Testing
@testable import Sniplet

struct QuickSaveNamingTests {
    @Test func neverReplacesAnExistingFile() {
        let folder = URL(fileURLWithPath: "/tmp/shots", isDirectory: true)
        let taken: Set<String> = ["Sniplet-1.png", "Sniplet-1 2.png"]
        let url = QuickSaveNaming.availableURL(in: folder, preferredName: "Sniplet-1.png") {
            taken.contains($0.lastPathComponent)
        }
        #expect(url.lastPathComponent == "Sniplet-1 3.png")
        #expect(QuickSaveNaming.availableURL(in: folder, preferredName: "Sniplet-2.png") { _ in false }
            .lastPathComponent == "Sniplet-2.png")
    }

    @Test func writerKeepsBothFilesWhenTheNameRepeats() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quick-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = ExportFileWriter()
        let first = try await writer.write(Data([1]), into: folder, preferredName: "Sniplet-x.png")
        let second = try await writer.write(Data([2]), into: folder, preferredName: "Sniplet-x.png")
        #expect(first.lastPathComponent == "Sniplet-x.png" && second.lastPathComponent == "Sniplet-x 2.png")
        #expect(try Data(contentsOf: first) == Data([1]))
    }

    @MainActor @Test func aChosenFolderIsRememberedAcrossLaunches() throws {
        let suite = "Sniplet.QuickSave.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chosen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(QuickSaveFolder(defaults: defaults).resolve() == nil)
        QuickSaveFolder(defaults: defaults).remember(folder)
        let reopened = QuickSaveFolder(defaults: defaults)
        #expect(reopened.resolve()?.standardizedFileURL.path == folder.standardizedFileURL.path)
        #expect(reopened.displayPath != nil)
        reopened.forget()
        #expect(QuickSaveFolder(defaults: defaults).resolve() == nil)
    }
}

@MainActor struct QuickSaveSessionTests {
    private final class Recorder {
        var saves: [(png: Data, askIfNeeded: Bool)] = []
        var reported: [URL] = []
    }

    private func waitUntilClosed(_ session: EditorSession) async {
        for _ in 0..<400 where session.phase != .closed { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func commandSWritesThePNGAndClosesWithoutADialog() async throws {
        let recorder = Recorder()
        var services = SessionTestSupport.services()
        services.quickSave = { png, _, ask in
            recorder.saves.append((png, ask))
            return URL(fileURLWithPath: "/tmp/shots/Sniplet.png")
        }
        services.quickSaveFinished = { if case let .success(url) = $0 { recorder.reported.append(url) } }
        let session = EditorSession(capture: try SessionTestSupport.capture(), services: services)
        session.output(.quickSave)
        await waitUntilClosed(session)
        #expect(session.phase == .closed)
        #expect(recorder.saves.count == 1 && recorder.saves[0].askIfNeeded)
        #expect(try SessionTestSupport.image(recorder.saves[0].png).width == 32)
        #expect(recorder.reported.map(\.lastPathComponent) == ["Sniplet.png"])
    }

    @Test func dismissingTheFolderChoiceKeepsTheScreenshotOpen() async throws {
        var services = SessionTestSupport.services()
        services.quickSave = { _, _, _ in nil }
        let session = EditorSession(capture: try SessionTestSupport.capture(), services: services)
        let finished = await withCheckedContinuation { continuation in
            session.onFinishAttempt = { continuation.resume(returning: $0) }
            session.output(.quickSave)
        }
        #expect(!finished)
        #expect(session.phase == .editing)
    }

    @Test func autoSaveKeepsACopyOnFinishWithoutEverAskingForAFolder() async throws {
        let recorder = Recorder()
        var services = SessionTestSupport.services(history: true, persist: { _, _ in })
        services.autoSaves = { true }
        services.quickSave = { png, _, ask in
            recorder.saves.append((png, ask))
            return URL(fileURLWithPath: "/tmp/shots/auto.png")
        }
        let session = EditorSession(capture: try SessionTestSupport.capture(), services: services)
        session.output(.finish)
        await waitUntilClosed(session)
        #expect(session.phase == .closed)
        #expect(recorder.saves.count == 1 && !recorder.saves[0].askIfNeeded)
    }
}
