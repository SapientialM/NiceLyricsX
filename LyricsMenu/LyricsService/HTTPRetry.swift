//
//  HTTPRetry.swift
//  NiceLyricsX
//
//  网络请求的退避重试 —— 只对「下一秒可能就好了」的失败重试。
//
//  背景:
//  歌词源(LRCLIB / 网易云)是社区 / 第三方服务,偶发 503、502、429 很常见。
//  旧实现一次失败就直接把 `服务器返回 503` 丢到 UI 上,用户只能手动点
//  「重新搜索歌词」。这里给所有出网请求加上指数退避重试。
//
//  重试范围(刻意收窄):
//  - HTTP 429(限流)和 5xx(服务端 / 网关临时故障)
//  - URLSession 层的瞬时错误:超时、连接中断、DNS 暂时失败、网络不可达
//  不重试:
//  - 4xx(除 429):请求本身有问题,重试一百次也一样
//  - 解码失败:数据坏了就是坏了
//  - 任务取消:必须立刻冒泡出去,否则切歌时旧请求会拖住新请求
//
//  `Retry-After` 头会被尊重,但会被 clamp 到一个上限 —— 歌词是交互式等待的,
//  服务端说「30 秒后再来」我们不能真让用户干等 30 秒。
//

import Foundation

// MARK: - 策略

public enum RetryPolicy {

    /// 最多尝试几次(含首次)。
    public static let maxAttempts = 3

    /// 首次重试前的等待秒数,之后翻倍。
    public static let baseDelay: TimeInterval = 0.6

    /// 单次等待的上限。
    public static let maxDelay: TimeInterval = 6

    /// 这个状态码值不值得重试。
    public static func isRetryable(status: Int) -> Bool {
        if status == 429 { return true }
        return (500...599).contains(status)
    }

    /// URLSession 抛出的网络错误里,哪些是瞬时的。
    public static func isRetryable(networkError error: Error) -> Bool {
        guard let urlError = error as? URLError else {
            // 非 URLError(例如系统层其它错误)保守起见当作可重试
            return true
        }
        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .resourceUnavailable,
             .badServerResponse,
             .secureConnectionFailed:
            return true
        default:
            // .cancelled 等一律不重试
            return false
        }
    }

    /// 第 `attempt` 次尝试(1 起)失败后应该等多久。
    /// 指数退避 + ±25% 抖动,避免多个请求同时重试又同时打过去。
    public static func delay(
        attempt: Int,
        retryAfter: TimeInterval? = nil,
        base: TimeInterval = RetryPolicy.baseDelay,
        cap: TimeInterval = RetryPolicy.maxDelay
    ) -> TimeInterval {
        if let retryAfter, retryAfter > 0 {
            return min(retryAfter, cap)
        }
        let exponential = base * pow(2, Double(max(0, attempt - 1)))
        // 抖动:0.75x ~ 1.25x
        let jitter = Double.random(in: 0.75...1.25)
        return min(exponential * jitter, cap)
    }
}

// MARK: - URLSession 扩展

extension URLSession {

    /// 带退避重试的 `data(for:)`。
    ///
    /// - Returns: 原始 `Data` 和 `HTTPURLResponse`。**HTTP 状态码不做判定** ——
    ///   调用方自己决定 404 是「没找到」还是别的;重试只处理"临时故障"。
    /// - Throws: `LyricsError.network`(网络层失败)或 `LyricsError.invalidResponse`。
    ///   不可重试的 HTTP 状态码会带着响应原样返回,由调用方抛 `LyricsError.http`。
    public func retryingData(
        for request: URLRequest,
        maxAttempts: Int = RetryPolicy.maxAttempts,
        baseDelay: TimeInterval = RetryPolicy.baseDelay
    ) async throws -> (Data, HTTPURLResponse) {

        let attempts = max(1, maxAttempts)
        var lastError: Error?

        for attempt in 1...attempts {
            do {
                let (data, response) = try await data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw LyricsError.invalidResponse
                }

                let isLast = attempt == attempts
                if RetryPolicy.isRetryable(status: http.statusCode), !isLast {
                    let wait = RetryPolicy.delay(
                        attempt: attempt,
                        retryAfter: http.retryAfterSeconds,
                        base: baseDelay
                    )
                    FileHandle.standardError.write(Data(
                        "[HTTPRetry] \(http.statusCode) from \(request.url?.host ?? "?") — 第 \(attempt)/\(attempts) 次,\(String(format: "%.1f", wait))s 后重试\n".utf8
                    ))
                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    continue
                }
                return (data, http)

            } catch let error as LyricsError {
                // 我们自己抛的(invalidResponse),不是瞬时故障
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let isLast = attempt == attempts
                guard !isLast, RetryPolicy.isRetryable(networkError: error) else {
                    throw LyricsError.network(underlying: error)
                }
                lastError = error
                let wait = RetryPolicy.delay(attempt: attempt, base: baseDelay)
                FileHandle.standardError.write(Data(
                    "[HTTPRetry] \(error.localizedDescription) — 第 \(attempt)/\(attempts) 次,\(String(format: "%.1f", wait))s 后重试\n".utf8
                ))
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }

        throw LyricsError.network(underlying: lastError ?? URLError(.unknown))
    }
}

// MARK: - Retry-After

extension HTTPURLResponse {

    /// 解析 `Retry-After`(规范允许「秒数」或「HTTP 日期」两种写法)。
    public var retryAfterSeconds: TimeInterval? {
        guard let raw = value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(raw) {
            return max(0, seconds)
        }
        // HTTP-date 形式
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}
