import Foundation
import Testing
@testable import Sniplet

/// The test host is the app itself, so these read the Info.plist that ships.
struct UpdaterConfigurationTests {
    private let info = Bundle.main.infoDictionary ?? [:]

    @Test func updatesComeFromTheSignedHTTPSAppcast() throws {
        let feed = try #require((info["SUFeedURL"] as? String).flatMap(URL.init(string:)))
        #expect(feed.scheme == "https" && feed.host == "sniplet.elazer.wang" && feed.path == "/appcast.xml")
        let key = try #require(info["SUPublicEDKey"] as? String)
        #expect(Data(base64Encoded: key)?.count == 32)
    }

    @Test func sandboxedInstallationIsEnabled() {
        #expect(info["SUEnableInstallerLauncherService"] as? Bool == true)
        // Sparkle asks on the second launch instead of a hard-coded default.
        #expect(info["SUEnableAutomaticChecks"] == nil)
    }
}
