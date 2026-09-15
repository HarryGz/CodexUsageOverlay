import Foundation
import XCTest
@testable import CodexUsageCore

final class AppServerClientTests: XCTestCase {
    func testProtocolRequestsUseTheReadOnlyAppServerContract() {
        let initialization = AppServerClient.initializationRequest
        XCTAssertEqual(initialization["id"] as? Int, 1)
        XCTAssertEqual(initialization["method"] as? String, "initialize")
        let params = initialization["params"] as? [String: Any]
        XCTAssertEqual((params?["clientInfo"] as? [String: Any])?["name"] as? String, "codex-usage-overlay")
        XCTAssertEqual((params?["clientInfo"] as? [String: Any])?["version"] as? String, "0.1.0")
        XCTAssertEqual((params?["capabilities"] as? [String: Any])?["experimentalApi"] as? Bool, true)

        let followUps = AppServerClient.postInitializationRequests
        XCTAssertEqual(followUps.map { $0["method"] as? String }, ["initialized", "account/read", "account/rateLimits/read"])
        XCTAssertEqual(followUps[1]["id"] as? Int, 2)
        XCTAssertEqual((followUps[1]["params"] as? [String: Any])?["refreshToken"] as? Bool, false)
        XCTAssertEqual(followUps[2]["id"] as? Int, 3)
        XCTAssertTrue(followUps[2]["params"] is NSNull)
    }
}
