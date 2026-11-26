import XCTest
import RoomwaveCreator
@testable import Roomwave

final class XActivityClientTests: XCTestCase {
    @MainActor
    func testDelayedOld401CannotRenewAReplacementSession() async throws {
        let requestOperation = UUID()
        var currentOperation = requestOperation
        var storedAccessToken = "old-access"
        var renewals: [Bool] = []
        var reads: [String] = []
        do {
            _ = try await XAuthorizedRead.perform(isCurrent: { currentOperation == requestOperation }, renew: { force in
                renewals.append(force)
                return storedAccessToken
            }, read: { token in
                reads.append(token)
                await Task.yield()
                // Model disconnect + successful new authorization while the old
                // transport response is suspended. No real Keychain or HTTP.
                currentOperation = UUID()
                storedAccessToken = "new-session-access"
                throw XActivityError.unauthorized
            })
            XCTFail("The old operation must be cancelled")
        } catch is CancellationError {}
        XCTAssertEqual(renewals, [false], "The late 401 must not rotate the new session's refresh token")
        XCTAssertEqual(reads, ["old-access"])
        XCTAssertEqual(storedAccessToken, "new-session-access")
    }

    @MainActor
    func testReplacementDuringRenewalPreventsTheOldRead() async throws {
        let requestOperation = UUID()
        var currentOperation = requestOperation
        var readCount = 0
        do {
            _ = try await XAuthorizedRead.perform(isCurrent: { currentOperation == requestOperation }, renew: { _ in
                await Task.yield()
                currentOperation = UUID()
                return "obsolete-access"
            }, read: { _ in
                readCount += 1
                return Data()
            })
            XCTFail("A replacement session must invalidate the suspended renewal")
        } catch is CancellationError {}
        XCTAssertEqual(readCount, 0)
    }

    @MainActor
    func testCurrentSession401RetriesExactlyOnce() async throws {
        for secondReadSucceeds in [true, false] {
            var renewals: [Bool] = []
            var reads: [String] = []
            do {
                let data = try await XAuthorizedRead.perform(isCurrent: { true }, renew: { force in
                    renewals.append(force)
                    return force ? "renewed-access" : "initial-access"
                }, read: { token in
                    reads.append(token)
                    guard token == "renewed-access", secondReadSucceeds else { throw XActivityError.unauthorized }
                    return Data("observed-response".utf8)
                })
                XCTAssertTrue(secondReadSucceeds)
                XCTAssertEqual(data, Data("observed-response".utf8))
            } catch XActivityError.unauthorized {
                XCTAssertFalse(secondReadSucceeds)
            }
            XCTAssertEqual(renewals, [false, true])
            XCTAssertEqual(reads, ["initial-access", "renewed-access"])
        }
    }

    func testCommunityQueryRejectsOversizedCombiningClustersBeforeEncoding() throws {
        XCTAssertEqual(try XCommunityQuery.normalized("  #Roomwave OR #TwitterSurfer  "), "#Roomwave OR #TwitterSurfer")
        XCTAssertEqual(try XCommunityQuery.normalized(String(repeating: "a", count: 256)).count, 256)
        let oneCluster = "a" + String(repeating: "\u{0301}", count: 256)
        XCTAssertEqual(oneCluster.count, 1, "A grapheme limit alone does not bound a request")
        XCTAssertThrowsError(try XCommunityQuery.normalized(oneCluster))
        XCTAssertThrowsError(try XCommunityQuery.normalized(String(repeating: " ", count: 1_025) + "x"))
        XCTAssertThrowsError(try XCommunityQuery.normalized("a\nb"))
        XCTAssertThrowsError(try XCommunityQuery.normalized("   "))
    }

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
