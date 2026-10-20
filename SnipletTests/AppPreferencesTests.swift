import CoreGraphics
import Foundation
import Testing
@testable import Sniplet

@MainActor struct AppPreferencesTests {
    @Test func featureTogglesDefaultToEnabledOCRAndPlainCopies() {
        let suite = "Sniplet.Prefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.ocrEnabled)
        #expect(!preferences.transientCopyEnabled)
        #expect(!ClipboardService.marksCopiesTransient)
    }

    @Test func togglesPersistAndTransientFlagFollowsPreference() {
        let suite = "Sniplet.Prefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            ClipboardService.marksCopiesTransient = false
        }
        let preferences = AppPreferences(defaults: defaults)
        preferences.ocrEnabled = false
        preferences.transientCopyEnabled = true
        #expect(ClipboardService.marksCopiesTransient)
        let reloaded = AppPreferences(defaults: defaults)
        #expect(!reloaded.ocrEnabled)
        #expect(reloaded.transientCopyEnabled)
        #expect(ClipboardService.marksCopiesTransient)
        preferences.transientCopyEnabled = false
        #expect(!ClipboardService.marksCopiesTransient)
    }

    @Test(arguments: CaptureSelectionAppearance.LineStyle.allCases)
    func customSelectionAppearancePersists(lineStyle: CaptureSelectionAppearance.LineStyle) throws {
        let suite = "Sniplet.Prefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let appearance = CaptureSelectionAppearance(
            color: AnnotationColor(red: 0.13, green: 0.47, blue: 0.91), lineStyle: lineStyle)
        preferences.selectionAppearance = appearance

        let data = try #require(defaults.data(forKey: "capture.selectionAppearance"))
        #expect(try JSONDecoder().decode(CaptureSelectionAppearance.self, from: data) == appearance)
        #expect(AppPreferences(defaults: defaults).selectionAppearance == appearance)
    }

    @Test func missingSelectionAppearanceUsesStandard() {
        let suite = "Sniplet.Prefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppPreferences(defaults: defaults).selectionAppearance == .standard)
    }

    @Test(arguments: [
        Data("not JSON".utf8),
        Data(#"{"color":{"red":0.1,"green":0.2,"blue":0.3,"alpha":1},"lineStyle":"unknown"}"#.utf8),
        Data(#"{"lineStyle":"solid"}"#.utf8)
    ])
    func corruptSelectionAppearanceRecoversAndCanBeReplaced(data: Data) {
        let suite = "Sniplet.Prefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(data, forKey: "capture.selectionAppearance")
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.selectionAppearance == .standard)
        let replacement = CaptureSelectionAppearance(color: .blue, lineStyle: .solid)
        preferences.selectionAppearance = replacement
        #expect(AppPreferences(defaults: defaults).selectionAppearance == replacement)
    }

    @Test func selectionAppearanceNormalizesLoadedAndSavedValues() throws {
        let suite = "Sniplet.Prefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let outsideBounds = CaptureSelectionAppearance(
            color: AnnotationColor(red: -0.5, green: 1.5, blue: 0.4, alpha: 0),
            lineStyle: .dotted)
        defaults.set(try JSONEncoder().encode(outsideBounds), forKey: "capture.selectionAppearance")
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.selectionAppearance == outsideBounds.normalized)
        #expect(preferences.selectionAppearance.color == AnnotationColor(red: 0, green: 1, blue: 0.4))

        let nonfinite = CaptureSelectionAppearance(
            color: AnnotationColor(red: .nan, green: .infinity, blue: -.infinity, alpha: .nan),
            lineStyle: .solid)
        preferences.selectionAppearance = nonfinite
        let saved = try #require(defaults.data(forKey: "capture.selectionAppearance"))
        #expect(try JSONDecoder().decode(CaptureSelectionAppearance.self, from: saved) == nonfinite.normalized)
        #expect(AppPreferences(defaults: defaults).selectionAppearance == nonfinite.normalized)
    }

    @Test func selectionAppearanceChangesAndResetPreserveOtherPreferences() {
        let suite = "Sniplet.Prefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let captureStyle = CaptureStyle(cornerRadius: 17, shadow: .medium, borderWidth: 3, borderColor: .blue)
        preferences.defaultCaptureStyle = captureStyle
        preferences.historyEnabled = false
        preferences.ocrEnabled = false
        let originalStyleData = defaults.data(forKey: "capture.defaultStyle")
        preferences.selectionAppearance = CaptureSelectionAppearance(color: .red, lineStyle: .dotted)
        preferences.selectionAppearance = .standard

        let reloaded = AppPreferences(defaults: defaults)
        #expect(reloaded.selectionAppearance == .standard)
        #expect(reloaded.defaultCaptureStyle == captureStyle)
        #expect(defaults.data(forKey: "capture.defaultStyle") == originalStyleData)
        #expect(!reloaded.historyEnabled)
        #expect(!reloaded.ocrEnabled)
        #expect(!reloaded.transientCopyEnabled)
    }
}

struct CaptureSelectionAppearanceTests {
    @Test func normalizationClampsFiniteComponentsAndPreservesValidBoundaries() {
        let outside = CaptureSelectionAppearance(
            color: AnnotationColor(red: -1, green: 2, blue: 0.5, alpha: 0.2), lineStyle: .dotted)
        let normalized = outside.normalized
        #expect(normalized.color == AnnotationColor(red: 0, green: 1, blue: 0.5))
        #expect(normalized.lineStyle == .dotted)
        #expect(normalized.normalized == normalized)
    }

    @Test(arguments: [CGFloat.nan, .infinity, -.infinity])
    func normalizationRecoversNonfiniteComponents(value: CGFloat) {
        let appearance = CaptureSelectionAppearance(
            color: AnnotationColor(red: value, green: value, blue: value, alpha: value),
            lineStyle: .solid).normalized
        #expect(appearance.color == CaptureSelectionAppearance.standard.color)
        #expect(appearance.color.alpha == 1)
        #expect(appearance.lineStyle == .solid)
    }

}

@MainActor struct DisabledOCRSessionTests {
    @Test func disabledOCRReportsSettingInsteadOfRecognizing() throws {
        let session = EditorSession(capture: try SessionTestSupport.capture(),
                                    services: SessionTestSupport.services(ocrEnabled: false))
        #expect(!session.isOCREnabled)
        session.copyRecognizedText()
        #expect(!session.isRecognizing)
        #expect(session.ocrResult == nil)
    }
}
