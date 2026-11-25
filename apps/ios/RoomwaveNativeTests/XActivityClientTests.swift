import XCTest
import RoomwaveCreator
@testable import Roomwave

final class XActivityClientTests: XCTestCase {
    func testOAuthUsesS256PKCEAndReadOnlyScopes() throws {
        let verifier = String(repeating: "a", count: 43)
        let url = try XOAuth.authorizationURL(clientID: "public-client", state: "state", verifier: verifier)
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(parts.queryItems)
        XCTAssertEqual(parts.scheme, "https")
        XCTAssertEqual(parts.host, "x.com")
        XCTAssertEqual(items.first(where: { $0.name == "redirect_uri" })?.value, "twitter-surfer://oauth/callback")
        XCTAssertEqual(items.first(where: { $0.name == "code_challenge_method" })?.value, "S256")
        XCTAssertEqual(items.first(where: { $0.name == "code_challenge" })?.value, "ZtNPunH49FD35FWYhT5Tv8I7vRKQJ8uxMaL0_9eHjNA")
        XCTAssertEqual(Set((items.first(where: { $0.name == "scope" })?.value ?? "").split(separator: " ")),
                       Set(["tweet.read", "users.read", "offline.access"]))
        XCTAssertNil(items.first(where: { $0.name == "client_secret" }))
    }

    func testCallbackRequiresExactOriginPathAndUniqueMatchingState() throws {
        let valid = try XCTUnwrap(URL(string: "twitter-surfer://oauth/callback?state=expected&code=valid-code"))
        XCTAssertEqual(try XOAuth.authorizationCode(from: valid, expectedState: "expected"), "valid-code")
        for raw in [
            "twitter-surfer://oauth/callback?state=wrong&code=valid",
            "twitter-surfer://oauth/callback?state=expected&state=wrong&code=valid",
            "twitter-surfer://oauth/callback?state=expected&code=a&code=b",
            "twitter-surfer://oauth/other?state=expected&code=valid",
            "twitter-surfer://attacker@oauth/callback?state=expected&code=valid",
            "twitter-surfer://oauth:443/callback?state=expected&code=valid",
            "twitter-surfer://oauth/callback?state=expected&code=valid#fragment",
            "https://oauth/callback?state=expected&code=valid"
        ] {
            XCTAssertThrowsError(try XOAuth.authorizationCode(from: XCTUnwrap(URL(string: raw)), expectedState: "expected"), raw)
        }
    }

    func testDeniedAuthorizationNeverBecomesACode() throws {
        let url = try XCTUnwrap(URL(string: "twitter-surfer://oauth/callback?state=expected&error=access_denied&error_description=private"))
        XCTAssertThrowsError(try XOAuth.authorizationCode(from: url, expectedState: "expected")) { error in
            guard let failure = error as? XActivityError, case .authorizationDenied = failure else { return XCTFail("Expected denied authorization") }
        }
    }

    func testMetricDecoderRejectsMissingNegativeDuplicateAndOversizedData() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let good = Data(#"{"data":[{"id":"123","public_metrics":{"like_count":10,"retweet_count":2,"reply_count":3,"quote_count":1}}]}"#.utf8)
        let posts = try XSnapshotDecoder.decode(good, sampledAt: now)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts[0].id, "123")
        XCTAssertEqual(posts[0].sampledAt, now)
        XCTAssertEqual(posts[0].metrics, XPostMetrics(likes: 10, reposts: 2, replies: 3, quotes: 1))
        for raw in [
            #"{"data":[{"id":"123"}]}"#,
            #"{"data":[{"id":"123","public_metrics":{"like_count":-1,"retweet_count":0,"reply_count":0,"quote_count":0}}]}"#,
            #"{"data":[{"id":"123","public_metrics":{"like_count":0,"retweet_count":0,"reply_count":0,"quote_count":0}},{"id":"123","public_metrics":{"like_count":0,"retweet_count":0,"reply_count":0,"quote_count":0}}]}"#
        ] { XCTAssertThrowsError(try XSnapshotDecoder.decode(Data(raw.utf8), sampledAt: now)) }
        XCTAssertThrowsError(try XSnapshotDecoder.decode(Data(repeating: 32, count: XSnapshotDecoder.maximumBytes + 1), sampledAt: now))
    }

    func testFormEncodingCannotInjectAnotherParameter() throws {
        let body = XOAuth.formBody(["code": "a+b&client_secret=bad", "client_id": "public"])
        let value = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(value.contains("code=a%2Bb%26client_secret%3Dbad"))
        XCTAssertEqual(value.filter { $0 == "&" }.count, 1)
    }
}
