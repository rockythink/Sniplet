import Foundation
import Observation

@Observable
final class AppPreferences {
    private let defaults: UserDefaults
    var historyEnabled: Bool {
        didSet { defaults.set(historyEnabled, forKey: "history.enabled") }
    }
    var ocrEnabled: Bool {
        didSet { defaults.set(ocrEnabled, forKey: "features.ocrEnabled") }
    }
    /// Marks copies as transient so clipboard managers (Copyla by default) skip them.
    var transientCopyEnabled: Bool {
        didSet {
            defaults.set(transientCopyEnabled, forKey: "copy.transient")
            ClipboardService.marksCopiesTransient = transientCopyEnabled
        }
    }
    var defaultCaptureStyle: CaptureStyle {
        didSet {
            if let data = try? JSONEncoder().encode(defaultCaptureStyle.normalized) {
                defaults.set(data, forKey: "capture.defaultStyle")
            }
        }
    }
    var selectionAppearance: CaptureSelectionAppearance {
        didSet {
            if let data = try? JSONEncoder().encode(selectionAppearance.normalized) {
                defaults.set(data, forKey: "capture.selectionAppearance")
            }
        }
    }

    var lastCaptureRegion: CaptureRegionMemory? {
        didSet {
            if let data = try? JSONEncoder().encode(lastCaptureRegion) {
                defaults.set(data, forKey: "capture.lastRegion")
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        historyEnabled = defaults.object(forKey: "history.enabled") as? Bool ?? true
        ocrEnabled = defaults.object(forKey: "features.ocrEnabled") as? Bool ?? true
        transientCopyEnabled = defaults.object(forKey: "copy.transient") as? Bool ?? false
        defaultCaptureStyle = defaults.data(forKey: "capture.defaultStyle")
            .flatMap { try? JSONDecoder().decode(CaptureStyle.self, from: $0) }?.normalized ?? .plain
        selectionAppearance = defaults.data(forKey: "capture.selectionAppearance")
            .flatMap { try? JSONDecoder().decode(CaptureSelectionAppearance.self, from: $0) }?.normalized ?? .standard
        lastCaptureRegion = defaults.data(forKey: "capture.lastRegion")
            .flatMap { try? JSONDecoder().decode(CaptureRegionMemory?.self, from: $0) } ?? nil
        ClipboardService.marksCopiesTransient = transientCopyEnabled
    }
}
