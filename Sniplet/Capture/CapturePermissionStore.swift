import AppKit
import CoreGraphics
import Observation

@Observable
final class CapturePermissionStore {
    private(set) var isAvailable = false
    private(set) var settingsOpenFailed = false

    func refresh() {
        isAvailable = CGPreflightScreenCaptureAccess()
    }

    func authorizeForCapture() -> Bool {
        refresh()
        if isAvailable { return true }
        let explanation = NSAlert()
        explanation.messageText = "允许 Sniplet 截图？"
        explanation.informativeText = "Sniplet 需要屏幕录制权限来截图和录屏；只在你主动开始录屏时录视频，不录声音，内容仅在本机处理。"
        if UserDefaults.standard.bool(forKey: "capture.hasRequestedAccess") {
            explanation.informativeText += "\n\n如果系统不再询问，请打开系统设置 → 隐私与安全性 → 屏幕录制（或屏幕与系统音频录制）。开启后请重试；必要时退出并手动重新打开 Sniplet。"
        }
        explanation.addButton(withTitle: "允许截图")
        explanation.addButton(withTitle: "打开系统设置")
        explanation.addButton(withTitle: "取消")
        switch explanation.runForSniplet() {
        case .alertFirstButtonReturn:
            UserDefaults.standard.set(true, forKey: "capture.hasRequestedAccess")
            _ = CGRequestScreenCaptureAccess()
            refresh()
            if !isAvailable {
                let guidance = NSAlert()
                guidance.messageText = "屏幕录制权限尚不可用"
                guidance.informativeText = "本次截图已结束，没有创建图像。请到系统设置 → 隐私与安全性 → 屏幕录制开启 Sniplet，然后重试。若已开启但仍不可用，请退出并手动重新打开 Sniplet。"
                guidance.addButton(withTitle: "打开系统设置")
                guidance.addButton(withTitle: "稍后")
                if guidance.runForSniplet() == .alertFirstButtonReturn { openSystemSettings() }
            }
            return isAvailable
        case .alertSecondButtonReturn:
            openSystemSettings()
            return false
        default:
            return false
        }
    }

    func openSystemSettings() {
        // The deep link is a best-effort convenience, not a public API contract.
        let deepLink = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        if NSWorkspace.shared.open(deepLink) {
            settingsOpenFailed = false
        } else {
            settingsOpenFailed = !NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
}
