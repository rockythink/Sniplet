import CoreGraphics
import Foundation

nonisolated enum CaptureMode: String, Sendable {
    /// `previousRegion` is a request only: it captures the remembered region and yields `.region` images.
    case region, window, fullScreen, previousRegion
}

/// The last region selection in global AppKit points, kept so it can be captured again directly.
nonisolated struct CaptureRegionMemory: Codable, Equatable, Sendable {
    var rect: CGRect
}

nonisolated struct CapturedImage: Sendable {
    let id: UUID
    let createdAt: Date
    let mode: CaptureMode
    let image: CGImage
    let sourceScale: CGFloat
    let displayID: CGDirectDisplayID
}

/// A finalized pixel snapshot. It deliberately has no live display/session reference.
nonisolated struct RenderedCapture: Sendable {
    let id: UUID
    let revision: UInt64
    let createdAt: Date
    let mode: CaptureMode
    let image: CGImage
    let sourceScale: CGFloat
}

nonisolated enum CaptureError: LocalizedError {
    case permissionUnavailable
    case displayUnavailable
    case applicationUnavailable
    case invalidDimensions
    case windowUnavailable
    case cropFailed

    var errorDescription: String? {
        switch self {
        case .permissionUnavailable:
            "屏幕录制权限尚不可用。请在系统设置中开启；如果已开启，请退出并手动重新打开 Sniplet。"
        case .displayUnavailable:
            "目标显示器已断开或布局已改变，请重新截图。"
        case .applicationUnavailable:
            "无法建立排除 Sniplet 自身窗口的截图过滤器，请重试。"
        case .invalidDimensions:
            "系统返回了无效的截图尺寸，请重试。"
        case .windowUnavailable:
            "目标窗口已关闭或不再可捕获，请重新选择。"
        case .cropFailed:
            "无法裁剪所选区域，请重新截图。"
        }
    }
}
