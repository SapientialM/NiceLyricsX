//
//  LRCLIBClient.swift
//  NiceLyricsX
//
//  LRCLIB API 客户端。
//
//  API 文档:https://lrclib.net/docs
//  - 搜索:GET /api/search?q={title}+{artist}     → 返回同步歌词 + 元数据
//  - 签名查询:GET /api/get?artist_name=...&track_name=...&album_name=...&duration=...
//            → 用于精确匹配,避免同名干扰
//
//  本客户端策略:
//  1. 先用关键词搜索,如果返回结果中 artist+title 完全匹配 → 用之
//  2. 否则尝试签名查询
//  3. 解析 → LyricsParser.parse → Lyrics
//
//  全程 async/await,失败抛 `LyricsError`。
//

import Foundation

public enum LyricsError: Error, LocalizedError {
    case network(underlying: Error)
    case http(status: Int)
    case noResult
    case decoding(underlying: Error)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .network(let e): return "网络错误: \(e.localizedDescription)"
        case .http(let s): return "服务器返回 \(s)"
        case .noResult: return "未找到歌词"
        case .decoding(let e): return "解析失败: \(e.localizedDescription)"
        case .invalidResponse: return "服务器响应无效"
        }
    }
}

public struct LRCLIBClient: Sendable {

    public let baseURL: URL
    public let session: URLSession

    public init(
        baseURL: URL = URL(string: "https://lrclib.net")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Public API

    /// 搜索歌词。优先用关键词 + (可选)签名前缀。
    ///
    /// - Parameter trackKey: 缓存用的 key(如 "title|artist|duration")。
    public func searchLyrics(
        title: String,
        artist: String,
        duration: TimeInterval? = nil,
        trackKey: String? = nil
    ) async throws -> Lyrics {
        // 1. 关键词搜索
        let results = try await fetchSearchResults(
            title: title,
            artist: artist
        )

        // 2. 在结果里挑最匹配的
        let best = pickBestMatch(
            from: results,
            targetTitle: title,
            targetArtist: artist,
            targetDuration: duration
        )

        if let best {
            return try parseLyricsRecord(best, trackKey: trackKey)
        }

        // 3. fallback:签名查询(用 album 也行,但 LRCLIB get 接口需要 album_name)
        if let duration, duration > 0 {
            let signed = try await fetchGetResult(
                title: title,
                artist: artist,
                duration: duration
            )
            if let signed {
                return try parseLyricsRecord(signed, trackKey: trackKey)
            }
        }

        throw LyricsError.noResult
    }

    // MARK: - /api/search

    private func fetchSearchResults(title: String, artist: String) async throws -> [LRCLIBRecord] {
        let query = "\(title) \(artist)".trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        guard var components = URLComponents(url: baseURL.appendingPathComponent("/api/search"),
                                             resolvingAgainstBaseURL: false) else {
            throw LyricsError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { throw LyricsError.invalidResponse }

        var req = URLRequest(url: url)
        req.setValue("NiceLyricsX/1.0 (https://github.com/local/NiceLyricsX)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw LyricsError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw LyricsError.http(status: http.statusCode)
            }
            do {
                return try JSONDecoder().decode([LRCLIBRecord].self, from: data)
            } catch {
                throw LyricsError.decoding(underlying: error)
            }
        } catch let error as LyricsError {
            throw error
        } catch {
            throw LyricsError.network(underlying: error)
        }
    }

    // MARK: - /api/get

    private func fetchGetResult(title: String, artist: String, duration: TimeInterval) async throws -> LRCLIBRecord? {
        var components = URLComponents(url: baseURL.appendingPathComponent("/api/get"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded())))
        ]
        guard let url = components.url else { throw LyricsError.invalidResponse }

        var req = URLRequest(url: url)
        req.setValue("NiceLyricsX/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw LyricsError.invalidResponse }
            if http.statusCode == 404 {
                return nil  // signed get 找不到不算异常
            }
            guard (200..<300).contains(http.statusCode) else {
                throw LyricsError.http(status: http.statusCode)
            }
            return try JSONDecoder().decode(LRCLIBRecord.self, from: data)
        } catch let error as LyricsError {
            throw error
        } catch {
            throw LyricsError.network(underlying: error)
        }
    }

    // MARK: - 选最匹配的

    private func pickBestMatch(
        from records: [LRCLIBRecord],
        targetTitle: String,
        targetArtist: String,
        targetDuration: TimeInterval?
    ) -> LRCLIBRecord? {
        // 完全相等且有时长匹配 → 立刻返回
        if let targetDuration, targetDuration > 0 {
            if let exact = records.first(where: { rec in
                rec.trackName.caseInsensitiveCompare(targetTitle) == .orderedSame
                && rec.artistName.caseInsensitiveCompare(targetArtist) == .orderedSame
                && abs(rec.duration - targetDuration) < 5
            }) {
                return exact
            }
        }

        // 仅 title + artist 匹配
        if let exact = records.first(where: { rec in
            rec.trackName.caseInsensitiveCompare(targetTitle) == .orderedSame
            && rec.artistName.caseInsensitiveCompare(targetArtist) == .orderedSame
        }) {
            return exact
        }

        // 只要 title 匹配
        if let partial = records.first(where: { rec in
            rec.trackName.caseInsensitiveCompare(targetTitle) == .orderedSame
        }) {
            return partial
        }

        // 都没有 → 用第一个(如果存在)
        return records.first
    }

    private func parseLyricsRecord(_ record: LRCLIBRecord, trackKey: String?) throws -> Lyrics {
        let text = record.plainLyrics ?? record.syncedLyrics ?? ""
        guard !text.isEmpty else { throw LyricsError.noResult }
        return LyricsParser.parse(lrcText: text, trackKey: trackKey)
    }
}

// MARK: - LRCLIB 数据模型

/// LRCLIB API 返回的记录结构。
/// 字段命名遵循 LRCLIB 官方文档。
public struct LRCLIBRecord: Codable, Sendable {
    public let id: Int
    public let trackName: String
    public let artistName: String
    public let albumName: String?
    public let duration: TimeInterval
    public let instrumental: Bool
    public let plainLyrics: String?
    public let syncedLyrics: String?

    enum CodingKeys: String, CodingKey {
        case id
        case trackName = "trackName"
        case artistName = "artistName"
        case albumName = "albumName"
        case duration
        case instrumental
        case plainLyrics = "plainLyrics"
        case syncedLyrics = "syncedLyrics"
    }
}