import Foundation

nonisolated enum AppRuntime {
    static var isUnitTesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SNIPLET_UNIT_TESTS"] == "1"
        #else
        false
        #endif
    }
}
