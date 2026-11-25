import Foundation
import Combine
import AuthenticationServices
import CryptoKit
import Security
import UIKit
import RoomwaveCreator

enum XActivityError: Error {
    case unavailable, invalidCallback, authorizationDenied, cancelled, random, invalidResponse
    case oversizedResponse, unauthorized, forbidden, rateLimited(String?), network, storage, invalidQuery, noPosts

    var message: String {
        switch self {
        case .unavailable: "X connection is unavailable in this build. The developer must configure an X native app client ID and callback. You can still play and create with LiDAR."
        case .invalidCallback: "X returned an invalid sign-in callback. Start Connect X again."
        case .authorizationDenied: "X access was not granted. You can continue playing without it."
        case .cancelled: "X sign-in was cancelled."
        case .random: "Secure sign-in could not start. Try again."
        case .invalidResponse: "X returned data this build cannot use. Try again later."
        case .oversizedResponse: "X returned more data than this app can safely accept."
        case .unauthorized: "Your X session expired or was revoked. Disconnect and connect X again."
        case .forbidden: "X denied this read. Check the app's X API plan, permissions and account access."
        case .rateLimited(let reset): "X's read limit was reached. " + (reset.map { "Try again after \($0)." } ?? "Wait before refreshing again.")
        case .network: "Could not reach X securely. Check your connection and try again."
        case .storage: "The device could not securely save or remove X credentials. Unlock the device and try again."
        case .invalidQuery: "Enter a community query of 1–256 characters without control characters."
        case .noPosts: "X returned no usable posts for this selection. Try another query or refresh later."
        }
    }
}

enum XOAuth {
    static let callback = "twitter-surfer://oauth/callback"
    static let scopes = "tweet.read users.read offline.access"

    static func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw XActivityError.random }
        return base64URL(Data(bytes))
    }

    static func authorizationURL(clientID: String, state: String, verifier: String) throws -> URL {
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = "x.com"; parts.path = "/i/oauth2/authorize"
        parts.queryItems = [URLQueryItem(name: "response_type", value: "code"),
                            URLQueryItem(name: "client_id", value: clientID),
                            URLQueryItem(name: "redirect_uri", value: callback),
                            URLQueryItem(name: "scope", value: scopes),
                            URLQueryItem(name: "state", value: state),
                            URLQueryItem(name: "code_challenge", value: base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
                            URLQueryItem(name: "code_challenge_method", value: "S256")]
        guard let url = parts.url else { throw XActivityError.invalidResponse }
        return url
    }

    static func authorizationCode(from url: URL, expectedState: String) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "twitter-surfer", parts.host == "oauth", parts.path == "/callback",
              parts.port == nil, parts.user == nil, parts.password == nil, parts.fragment == nil,
              let items = parts.queryItems, items.count <= 5,
              items.filter({ $0.name == "state" }).count == 1,
              let state = items.first(where: { $0.name == "state" })?.value,
              !expectedState.isEmpty, constantEqual(state, expectedState) else { throw XActivityError.invalidCallback }
        if items.contains(where: { $0.name == "error" }) { throw XActivityError.authorizationDenied }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value,
              !code.isEmpty, code.utf8.count <= 2048,
              !code.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw XActivityError.invalidCallback }
        return code
    }

    static func formBody(_ values: [String: String]) -> Data {
        // RFC 3986 unreserved characters only; no '+' ambiguity in form values.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(values.sorted(by: { $0.key < $1.key }).map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" +
            ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func constantEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

enum XSnapshotDecoder {
    static let maximumBytes = 1_048_576

    private struct Envelope: Decodable { let data: [Post]? }
    private struct Post: Decodable {
        let id: String
        let public_metrics: Metrics
    }
    private struct Metrics: Decodable {
        let like_count: Int
        let retweet_count: Int
        let reply_count: Int
        let quote_count: Int
    }

    static func decode(_ data: Data, sampledAt: Date) throws -> [XPostSnapshot] {
        guard data.count <= maximumBytes else { throw XActivityError.oversizedResponse }
        let posts = try JSONDecoder().decode(Envelope.self, from: data).data ?? []
        guard posts.count <= 10, Set(posts.map(\.id)).count == posts.count else { throw XActivityError.invalidResponse }
        return try posts.map { post in
            let counts = [post.public_metrics.like_count, post.public_metrics.retweet_count,
                          post.public_metrics.reply_count, post.public_metrics.quote_count]
            guard validID(post.id), counts.allSatisfy({ (0...ViralCurrentBuilder.maximumCount).contains($0) }) else { throw XActivityError.invalidResponse }
            return XPostSnapshot(id: post.id, sampledAt: sampledAt,
                                 metrics: XPostMetrics(likes: counts[0], reposts: counts[1], replies: counts[2], quotes: counts[3]))
        }
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 20 && value.utf8.first != 48 && value.utf8.allSatisfy { (48...57).contains($0) }
    }
}

private final class XNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class XActivityClient: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var currentlyConnected = false
    @Published private(set) var hasDeviceCredentials = false
    @Published private(set) var isLoading = false
    @Published private(set) var notice: String
    @Published private(set) var current: ViralCurrent?
    let isConfigured: Bool
    private let clientID: String?
    private let http: URLSession
    private var tokens: XOAuthTokens?
    private var authentication: ASWebAuthenticationSession?
    private var operation = UUID()
    private var previous: [String: [XPostSnapshot]] = [:]
    private var currents: [String: ViralCurrent] = [:]
    private var selection = "personal"

    override init() {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "XOAuthClientID") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = configured.flatMap { value -> String? in
            guard !value.isEmpty, value.utf8.count <= 256, !value.contains("$("),
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
            return value
        }
        clientID = valid; isConfigured = valid != nil
        notice = valid == nil ? XActivityError.unavailable.message : "Connect X to read your activity or a community event. Refresh is always your choice."
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        http = URLSession(configuration: config, delegate: XNoRedirects(), delegateQueue: nil)
        super.init()
        do {
            if let saved = try XTokenStore.read() {
                hasDeviceCredentials = true; tokens = saved
                if saved.clientID == valid {
                    currentlyConnected = true
                    notice = "Connected to X. Choose a source, then refresh to read real activity."
                }
            }
        } catch { notice = XActivityError.storage.message }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        Self.activeWindow() ?? ASPresentationAnchor()
    }

    func connect() {
        guard !isLoading else { return }
        guard let clientID else { notice = XActivityError.unavailable.message; return }
        guard Self.activeWindow() != nil else { notice = "Open the app in the foreground before connecting X."; return }
        do {
            let state = try XOAuth.randomString(), verifier = try XOAuth.randomString()
            let url = try XOAuth.authorizationURL(clientID: clientID, state: state, verifier: verifier)
            let id = UUID(); operation = id; isLoading = true
            let auth = ASWebAuthenticationSession(url: url, callbackURLScheme: "twitter-surfer") { [weak self] callback, error in
                Task { @MainActor in
                    guard let self, self.operation == id else { return }
                    defer { if self.operation == id { self.isLoading = false; self.authentication = nil } }
                    do {
                        if let error {
                            let failure = error as NSError
                            if failure.domain == ASWebAuthenticationSessionError.errorDomain,
                               failure.code == ASWebAuthenticationSessionError.canceledLogin.rawValue { throw XActivityError.cancelled }
                            throw XActivityError.authorizationDenied
                        }
                        guard let callback else { throw XActivityError.invalidCallback }
                        let code = try XOAuth.authorizationCode(from: callback, expectedState: state)
                        let result = try await self.exchange(["grant_type": "authorization_code", "code": code,
                                                              "redirect_uri": XOAuth.callback, "client_id": clientID,
                                                              "code_verifier": verifier], previousRefreshToken: nil)
                        guard self.operation == id else { return }
                        try XTokenStore.save(result)
                        // A fresh authorization can select a different account.
                        self.current = nil; self.previous = [:]; self.currents = [:]
                        self.tokens = result; self.hasDeviceCredentials = true; self.currentlyConnected = true
                        self.notice = "Connected to X. Choose a source and explicitly refresh to read activity."
                    } catch { if self.operation == id { self.notice = Self.message(for: error) } }
                }
            }
            auth.presentationContextProvider = self
            auth.prefersEphemeralWebBrowserSession = true
            authentication = auth
            guard auth.start() else { authentication = nil; isLoading = false; notice = "X sign-in could not open. Try again."; return }
        } catch { isLoading = false; notice = Self.message(for: error) }
    }

    func select(kind: ViralFeedKind, query: String = "#TwitterSurfer OR #Roomwave") {
        selection = key(kind: kind, query: query)
        current = currents[selection]
    }

    func refresh(kind: ViralFeedKind, query: String = "#TwitterSurfer OR #Roomwave") async {
        guard !isLoading else { return }
        guard clientID != nil else { notice = XActivityError.unavailable.message; return }
        guard currentlyConnected else { notice = "Connect X before reading activity. The offline game is ready without an account."; return }
        let source = key(kind: kind, query: query)
        selection = source; current = currents[source]
        let id = UUID(); operation = id; isLoading = true
        defer { if operation == id { isLoading = false } }
        do {
            let path: String
            var items: [URLQueryItem]
            switch kind {
            case .personal:
                let me = try await api(path: "/2/users/me", items: [], operationID: id)
                struct Me: Decodable { struct User: Decodable { let id: String }; let data: User }
                let user = try JSONDecoder().decode(Me.self, from: me).data.id
                guard XSnapshotDecoder.validID(user) else { throw XActivityError.invalidResponse }
                path = "/2/users/\(user)/tweets"
                items = [URLQueryItem(name: "max_results", value: "10")]
            case .community:
                let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value.count <= 256,
                      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw XActivityError.invalidQuery }
                path = "/2/tweets/search/recent"
                items = [URLQueryItem(name: "query", value: value), URLQueryItem(name: "max_results", value: "10")]
            }
            items.append(URLQueryItem(name: "tweet.fields", value: "public_metrics"))
            let data = try await api(path: path, items: items, operationID: id)
            let now = Date()
            let posts = try XSnapshotDecoder.decode(data, sampledAt: now)
            guard !posts.isEmpty else { throw XActivityError.noPosts }
            // An old session snapshot must not prevent a new successful read.
            let prior = (previous[source] ?? []).filter {
                let age = now.timeIntervalSince($0.sampledAt)
                return age >= 0 && age <= ViralCurrentBuilder.maximumAge
            }
            let result = try ViralCurrentBuilder.make(posts: posts, previous: prior, kind: kind, now: now)
            guard operation == id else { return }
            // Keep one community query and one personal snapshot, each at most 10 posts.
            if case .community = kind {
                previous = previous.filter { !$0.key.hasPrefix("community:") }
                currents = currents.filter { !$0.key.hasPrefix("community:") }
            }
            previous[source] = posts; currents[source] = result
            if selection == source { current = result }
            notice = "Read \(posts.count) real post metrics from X. Engagement shapes the route; your play earns the score."
        } catch {
            if operation == id {
                notice = Self.message(for: error)
                if let failure = error as? XActivityError, case .unauthorized = failure { currentlyConnected = false }
            }
        }
    }

    func disconnect() async {
        let stored = tokens
        let token = stored?.refreshToken ?? stored?.accessToken
        let revocationClientID = stored?.clientID
        operation = UUID(); authentication?.cancel(); authentication = nil
        isLoading = false
        tokens = nil; currentlyConnected = false; current = nil; previous = [:]; currents = [:]
        do { try XTokenStore.delete() }
        catch {
            tokens = stored // Retain only for a retry; the connection stays disabled.
            hasDeviceCredentials = true
            notice = XActivityError.storage.message; return
        }
        hasDeviceCredentials = false
        guard let token, let revocationClientID else { isLoading = false; notice = "X credentials removed from this device."; return }
        isLoading = true
        let id = operation
        defer { if operation == id { isLoading = false } }
        do {
            _ = try await request(path: "/2/oauth2/revoke", method: "POST", body: XOAuth.formBody(["token": token, "client_id": revocationClientID]))
            if operation == id { notice = "Disconnected. X confirmed token revocation; device credentials were removed." }
        } catch {
            if operation == id { notice = "Disconnected on this device. X revocation could not be confirmed; remove this app in X Settings → Security and account access → Apps and sessions." }
        }
    }

    private func api(path: String, items: [URLQueryItem], operationID: UUID) async throws -> Data {
        try await renewIfNeeded(operationID: operationID)
        guard operation == operationID, let token = tokens?.accessToken else { throw XActivityError.unauthorized }
        do { return try await request(path: path, items: items, bearer: token) }
        catch XActivityError.unauthorized {
            try await renewIfNeeded(force: true, operationID: operationID)
            guard operation == operationID, let replacement = tokens?.accessToken else { throw XActivityError.unauthorized }
            return try await request(path: path, items: items, bearer: replacement)
        }
    }

    private func renewIfNeeded(force: Bool = false, operationID: UUID) async throws {
        guard let stored = tokens, let clientID else { throw XActivityError.unauthorized }
        guard force || stored.expiresAt.timeIntervalSinceNow < 60 else { return }
        guard let refresh = stored.refreshToken else { throw XActivityError.unauthorized }
        let replacement = try await exchange(["grant_type": "refresh_token", "refresh_token": refresh,
                                              "client_id": clientID], previousRefreshToken: refresh)
        guard operation == operationID else { throw CancellationError() }
        do { try XTokenStore.save(replacement) }
        catch { tokens = nil; currentlyConnected = false; throw XActivityError.storage }
        tokens = replacement
        hasDeviceCredentials = true
    }

    private func exchange(_ values: [String: String], previousRefreshToken: String?) async throws -> XOAuthTokens {
        struct Reply: Decodable {
            let token_type: String; let access_token: String; let expires_in: Int
            let refresh_token: String?; let scope: String?
        }
        let data = try await request(path: "/2/oauth2/token", method: "POST", body: XOAuth.formBody(values))
        let value = try JSONDecoder().decode(Reply.self, from: data)
        guard let clientID, value.token_type.lowercased() == "bearer", !value.access_token.isEmpty,
              value.access_token.utf8.count <= 8192,
              !value.access_token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (1...7_776_000).contains(value.expires_in),
              value.refresh_token.map({ !$0.isEmpty && $0.utf8.count <= 8192 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) ?? true else { throw XActivityError.invalidResponse }
        if let scope = value.scope {
            let granted = Set(scope.split(separator: " ").map(String.init))
            guard Set(XOAuth.scopes.split(separator: " ").map(String.init)).isSubset(of: granted) else { throw XActivityError.forbidden }
        }
        return XOAuthTokens(clientID: clientID, accessToken: value.access_token,
                            refreshToken: value.refresh_token ?? previousRefreshToken,
                            expiresAt: Date().addingTimeInterval(TimeInterval(value.expires_in)))
    }

    private func request(path: String, method: String = "GET", items: [URLQueryItem] = [], body: Data? = nil, bearer: String? = nil) async throws -> Data {
        var parts = URLComponents(); parts.scheme = "https"; parts.host = "api.x.com"; parts.path = path
        parts.queryItems = items.isEmpty ? nil : items
        guard let url = parts.url else { throw XActivityError.invalidResponse }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await http.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url?.scheme == "https", response.url?.host == "api.x.com" else { throw XActivityError.invalidResponse }
        switch response.statusCode {
        case 200...299: break
        case 400 where path == "/2/oauth2/token": throw XActivityError.unauthorized
        case 401: throw XActivityError.unauthorized
        case 403: throw XActivityError.forbidden
        case 429:
            let reset = response.value(forHTTPHeaderField: "x-rate-limit-reset").flatMap(TimeInterval.init).flatMap { value -> String? in
                guard value.isFinite, value > Date().timeIntervalSince1970, value < Date().addingTimeInterval(86_400 * 7).timeIntervalSince1970 else { return nil }
                return Date(timeIntervalSince1970: value).formatted(date: .abbreviated, time: .shortened)
            }
            throw XActivityError.rateLimited(reset)
        default: throw XActivityError.invalidResponse
        }
        guard response.expectedContentLength <= Int64(XSnapshotDecoder.maximumBytes) else { throw XActivityError.oversizedResponse }
        var data = Data(); data.reserveCapacity(8192)
        for try await byte in bytes {
            guard data.count < XSnapshotDecoder.maximumBytes else { throw XActivityError.oversizedResponse }
            data.append(byte)
        }
        return data
    }

    private func key(kind: ViralFeedKind, query: String) -> String {
        switch kind {
        case .personal: "personal"
        case .community: "community:" + query.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func activeWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows).first(where: \.isKeyWindow)
    }

    private static func message(for error: Error) -> String {
        if let error = error as? XActivityError { return error.message }
        if error is DecodingError { return XActivityError.invalidResponse.message }
        if error is CancellationError { return "X request cancelled." }
        return XActivityError.network.message
    }
}
