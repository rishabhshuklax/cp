import XCTest
@testable import CpKit

final class PrivacyFilterTests: XCTestCase {

    func testDetectsKnownTokenPrefixes() {
        XCTAssertTrue(PrivacyFilter.looksLikeSecret("ghp_1234567890abcdefghijklmnop"))
        XCTAssertTrue(PrivacyFilter.looksLikeSecret("sk-proj-abcdefghijklmnopqrstuvwxyz"))
        XCTAssertTrue(PrivacyFilter.looksLikeSecret("xoxb-123456789012-abcdefghijkl"))
        XCTAssertTrue(PrivacyFilter.looksLikeSecret("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertTrue(PrivacyFilter.looksLikeSecret("glpat-abcdefghijklmnopqrst"))
    }

    func testDetectsPrivateKeyBlocks() {
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----"
        XCTAssertTrue(PrivacyFilter.looksLikeSecret(pem))
    }

    func testDetectsJWTs() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r"
        XCTAssertTrue(PrivacyFilter.looksLikeSecret(jwt))
    }

    /// The precision half of the bargain. Flagging every base64-ish string would
    /// conceal a large slice of a developer's real history, which is worse than
    /// missing the occasional bespoke token format.
    func testDoesNotFlagOrdinaryContent() {
        XCTAssertFalse(PrivacyFilter.looksLikeSecret("hello world"))
        XCTAssertFalse(PrivacyFilter.looksLikeSecret("https://github.com/org/repo"))
        XCTAssertFalse(PrivacyFilter.looksLikeSecret("short"))
        XCTAssertFalse(PrivacyFilter.looksLikeSecret("a sentence with several words in it"))
        XCTAssertFalse(PrivacyFilter.looksLikeSecret("d3adb33fd3adb33fd3adb33fd3adb33f"))
    }

    func testPasswordManagersAreIgnoredByDefault() {
        XCTAssertTrue(PrivacyFilter.defaultIgnoredBundleIDs.contains("com.agilebits.onepassword"))
        XCTAssertTrue(PrivacyFilter.defaultIgnoredBundleIDs.contains("com.bitwarden.desktop"))
        XCTAssertTrue(PrivacyFilter.defaultIgnoredBundleIDs.contains("org.keepassxc.keepassxc"))
    }
}
