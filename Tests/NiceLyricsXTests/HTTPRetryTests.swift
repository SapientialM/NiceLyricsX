//
//  HTTPRetryTests.swift
//  NiceLyricsXTests
//
//  503 重试的回归测试。
//
//  背景:LRCLIB / 网易云偶发 503,旧实现直接把「服务器返回 503」丢给用户。
//  这里用 URLProtocol 打桩,验证:
//  - 503 / 502 / 429 会退避重试,并且在第 N 次成功时能拿到结果
//  - 重试用尽后抛出最后一次的 HTTP 状态
//  - 404 / 4xx 不重试(重试没有意义,只会让用户多等)
//  - 超时等瞬时网络错误会重试
//  - 不可重试的网络错误(取消失败)立刻抛
//

import XCTest
@testable import NiceLyricsX

// MARK: - URLProtocol 打桩

final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    struct Step {
        var statusCode: Int = 200
        var body: Data = Data()
        var headers: [String: String] = [:]
        var error: URLError?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var steps: [Step] = []
    nonisolated(unsafe) private static var requestCount = 0

    static func script(_ steps: [Step]) {
        lock.lock()
        self.steps = steps
        requestCount = 0
        lock.unlock()
    }

    static var attempts: Int {
        lock.lock(); defer { lock.unlock() }
        return requestCount
    }

    private static func nextStep() -> Step? {
        lock.lock(); defer { lock.unlock() }
        requestCount += 1
        guard !steps.isEmpty else { return nil }
        return steps.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let step = Self.nextStep() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let error = step.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: step.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: step.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: step.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - 测试

final class HTTPRetryTests: XCTestCase {

    /// 重试间隔压到毫秒级,不然测试要等好几秒
    private let fastBase: TimeInterval = 0.01

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeRequest() -> URLRequest {
        URLRequest(url: URL(string: "https://example.com/api/search?q=x")!)
    }

    // MARK: 重试成功

    func testRetriesOn503ThenSucceeds() async throws {
        StubURLProtocol.script([
            .init(statusCode: 503),
            .init(statusCode: 503),
            .init(statusCode: 200, body: Data("ok".utf8))
        ])
        let (data, http) = try await makeSession()
            .retryingData(for: makeRequest(), baseDelay: fastBase)

        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
        XCTAssertEqual(StubURLProtocol.attempts, 3)
    }

    func testRetriesOn502And429() async throws {
        for status in [502, 429] {
            StubURLProtocol.script([
                .init(statusCode: status),
                .init(statusCode: 200, body: Data())
            ])
            let (_, http) = try await makeSession()
                .retryingData(for: makeRequest(), baseDelay: fastBase)
            XCTAssertEqual(http.statusCode, 200, "status \(status) 应该被重试")
            XCTAssertEqual(StubURLProtocol.attempts, 2)
        }
    }

    // MARK: 重试用尽

    func testGivesUpAfterMaxAttemptsAndReturnsLastResponse() async throws {
        StubURLProtocol.script([
            .init(statusCode: 503),
            .init(statusCode: 503),
            .init(statusCode: 503)
        ])
        let (_, http) = try await makeSession()
            .retryingData(for: makeRequest(), maxAttempts: 3, baseDelay: fastBase)

        // 最后一次的响应原样返回,由调用方抛 LyricsError.http(503)
        XCTAssertEqual(http.statusCode, 503)
        XCTAssertEqual(StubURLProtocol.attempts, 3)
    }

    func testCustomMaxAttemptsIsHonored() async throws {
        StubURLProtocol.script([.init(statusCode: 503), .init(statusCode: 503)])
        _ = try await makeSession()
            .retryingData(for: makeRequest(), maxAttempts: 1, baseDelay: fastBase)
        XCTAssertEqual(StubURLProtocol.attempts, 1, "maxAttempts=1 时不应该有任何重试")
    }

    // MARK: 不该重试的

    func testDoesNotRetry404() async throws {
        StubURLProtocol.script([.init(statusCode: 404)])
        let (_, http) = try await makeSession()
            .retryingData(for: makeRequest(), baseDelay: fastBase)
        XCTAssertEqual(http.statusCode, 404)
        XCTAssertEqual(StubURLProtocol.attempts, 1)
    }

    func testDoesNotRetry400() async throws {
        StubURLProtocol.script([.init(statusCode: 400)])
        _ = try await makeSession().retryingData(for: makeRequest(), baseDelay: fastBase)
        XCTAssertEqual(StubURLProtocol.attempts, 1)
    }

    // MARK: 网络层错误

    func testRetriesOnTimeout() async throws {
        StubURLProtocol.script([
            .init(error: URLError(.timedOut)),
            .init(statusCode: 200, body: Data("ok".utf8))
        ])
        let (data, http) = try await makeSession()
            .retryingData(for: makeRequest(), baseDelay: fastBase)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
        XCTAssertEqual(StubURLProtocol.attempts, 2)
    }

    func testTimeoutExhaustedBecomesLyricsErrorNetwork() async throws {
        StubURLProtocol.script([
            .init(error: URLError(.timedOut)),
            .init(error: URLError(.timedOut)),
            .init(error: URLError(.timedOut))
        ])
        do {
            _ = try await makeSession()
                .retryingData(for: makeRequest(), maxAttempts: 3, baseDelay: fastBase)
            XCTFail("应该抛出错误")
        } catch let error as LyricsError {
            guard case .network = error else {
                XCTFail("期望 .network,实际 \(error)")
                return
            }
        }
        XCTAssertEqual(StubURLProtocol.attempts, 3)
    }

    func testDoesNotRetryCancelled() async throws {
        StubURLProtocol.script([.init(error: URLError(.cancelled))])
        do {
            _ = try await makeSession().retryingData(for: makeRequest(), baseDelay: fastBase)
            XCTFail("应该抛出错误")
        } catch let error as LyricsError {
            guard case .network = error else {
                XCTFail("期望 .network,实际 \(error)")
                return
            }
        }
        XCTAssertEqual(StubURLProtocol.attempts, 1, "取消不应该重试")
    }
}

// MARK: - 纯策略测试

final class RetryPolicyTests: XCTestCase {

    func testRetryableStatuses() {
        XCTAssertTrue(RetryPolicy.isRetryable(status: 429))
        XCTAssertTrue(RetryPolicy.isRetryable(status: 500))
        XCTAssertTrue(RetryPolicy.isRetryable(status: 502))
        XCTAssertTrue(RetryPolicy.isRetryable(status: 503))
        XCTAssertTrue(RetryPolicy.isRetryable(status: 504))
        XCTAssertFalse(RetryPolicy.isRetryable(status: 400))
        XCTAssertFalse(RetryPolicy.isRetryable(status: 403))
        XCTAssertFalse(RetryPolicy.isRetryable(status: 404))
        XCTAssertFalse(RetryPolicy.isRetryable(status: 200))
    }

    func testRetryableNetworkErrors() {
        XCTAssertTrue(RetryPolicy.isRetryable(networkError: URLError(.timedOut)))
        XCTAssertTrue(RetryPolicy.isRetryable(networkError: URLError(.networkConnectionLost)))
        XCTAssertTrue(RetryPolicy.isRetryable(networkError: URLError(.cannotConnectToHost)))
        XCTAssertTrue(RetryPolicy.isRetryable(networkError: URLError(.notConnectedToInternet)))
        XCTAssertFalse(RetryPolicy.isRetryable(networkError: URLError(.cancelled)))
    }

    func testDelayGrowsExponentially() {
        // 抖动是 ±25%,所以断言范围而不是精确值
        let first = RetryPolicy.delay(attempt: 1, base: 1.0, cap: 100)
        XCTAssertTrue((0.75...1.25).contains(first), "第一次约 1s,实际 \(first)")

        let second = RetryPolicy.delay(attempt: 2, base: 1.0, cap: 100)
        XCTAssertTrue((1.5...2.5).contains(second), "第二次约 2s,实际 \(second)")

        let third = RetryPolicy.delay(attempt: 3, base: 1.0, cap: 100)
        XCTAssertTrue((3.0...5.0).contains(third), "第三次约 4s,实际 \(third)")
    }

    func testDelayHonorsRetryAfterButClampsIt() {
        let honored = RetryPolicy.delay(attempt: 1, retryAfter: 2, base: 0.5, cap: 10)
        XCTAssertEqual(honored, 2)

        // 服务端说 300 秒,不能真让用户等 —— clamp 到 cap
        let clamped = RetryPolicy.delay(attempt: 1, retryAfter: 300, base: 0.5, cap: 6)
        XCTAssertEqual(clamped, 6)
    }

    func testDelayNeverExceedsCap() {
        for attempt in 1...10 {
            let d = RetryPolicy.delay(attempt: attempt, base: 1, cap: 3)
            XCTAssertLessThanOrEqual(d, 3)
        }
    }
}

// MARK: - Retry-After 解析

final class RetryAfterHeaderTests: XCTestCase {

    private func response(headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 503,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    func testParsesSeconds() {
        XCTAssertEqual(response(headers: ["Retry-After": "5"]).retryAfterSeconds, 5)
        XCTAssertEqual(response(headers: ["Retry-After": " 2 "]).retryAfterSeconds, 2)
    }

    func testParsesHTTPDate() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let future = formatter.string(from: Date().addingTimeInterval(30))
        let parsed = response(headers: ["Retry-After": future]).retryAfterSeconds
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!, 30, accuracy: 2)
    }

    func testNilWhenAbsentOrGarbage() {
        XCTAssertNil(response(headers: [:]).retryAfterSeconds)
        XCTAssertNil(response(headers: ["Retry-After": "soon"]).retryAfterSeconds)
        XCTAssertNil(response(headers: ["Retry-After": ""]).retryAfterSeconds)
    }
}
