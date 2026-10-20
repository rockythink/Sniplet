import Foundation

nonisolated struct CaptureRevision: Hashable, Sendable {
    let id: UUID
    let revision: UInt64

    init(id: UUID, revision: UInt64) {
        self.id = id
        self.revision = revision
    }

    init(_ capture: RenderedCapture) {
        id = capture.id
        revision = capture.revision
    }
}

nonisolated struct OCRTicket: Equatable, Sendable {
    let capture: CaptureRevision
    let requestID = UUID()
}
