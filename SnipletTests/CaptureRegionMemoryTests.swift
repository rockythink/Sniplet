import CoreGraphics
import Foundation
import Testing
@testable import Sniplet

@MainActor struct CaptureRegionMemoryTests {
    @Test func lastRegionStartsEmptyAndPersists() {
        let suite = "Sniplet.Prefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.lastCaptureRegion == nil)
        let memory = CaptureRegionMemory(rect: CGRect(x: -1200.5, y: 80, width: 640, height: 360))
        preferences.lastCaptureRegion = memory
        #expect(AppPreferences(defaults: defaults).lastCaptureRegion == memory)
        defaults.set(Data("garbage".utf8), forKey: "capture.lastRegion")
        #expect(AppPreferences(defaults: defaults).lastCaptureRegion == nil)
    }

    @Test(arguments: [CGFloat(1), 2, 1.5])
    func rememberedRegionCropsTheSamePixelsAgain(scale: CGFloat) throws {
        let screenFrame = CGRect(x: -800, y: 100, width: 800, height: 500)
        let context = try AnnotationCompositor.bitmap(width: Int(screenFrame.width * scale),
                                                      height: Int(screenFrame.height * scale))
        let image = try #require(context.makeImage())
        let source = CapturedImage(id: UUID(), createdAt: Date(), mode: .fullScreen,
                                   image: image, sourceScale: scale, displayID: 1)
        let first = try #require(CaptureRegionSelection(source: source, screenFrame: screenFrame,
                                                        selectionRect: CGRect(x: -613.3, y: 222.7, width: 301.9, height: 97.4)))
        // A later capture of the same display gets a new frozen image with the same geometry.
        let again = CapturedImage(id: UUID(), createdAt: Date(), mode: .fullScreen,
                                  image: image, sourceScale: scale, displayID: 1)
        let repeated = try #require(CaptureRegionSelection(source: again, screenFrame: screenFrame,
                                                           selectionRect: first.screenRect))
        #expect(repeated.pixelRect == first.pixelRect)
        #expect(try repeated.croppedCapture().mode == .region)
    }

    @Test func everyCaptureActionHasADistinctValidDefaultShortcut() {
        let defaults = GlobalHotKeyManager.modes.map(ShortcutBinding.defaultBinding(for:))
        #expect(Set(defaults).count == GlobalHotKeyManager.modes.count)
        for (index, binding) in defaults.enumerated() {
            var others = defaults
            others.remove(at: index)
            #expect(ShortcutPolicy.validationError(binding, otherBindings: others,
                                                   systemBindings: [], menuBindings: []) == nil)
        }
    }
}
