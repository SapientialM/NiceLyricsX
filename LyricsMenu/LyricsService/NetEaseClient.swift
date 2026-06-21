//
//  NetEaseClient.swift
//  NiceLyricsX
//
//  网易云音乐 (music.163.com) 歌词客户端 —— LRCLIB fallback。
//
//  为什么需要:
//  LRCLIB 数据库以英文 + 海外流行华语为主,大量抖音 / 网络新歌 / 翻唱
//  都搜不到(实测 track "海底" by "安卿尘 & 十三寻" LRCLIB 0 hit)。
//  网易云是中文 / 独立音乐 / 翻唱最全的来源,公开 API 不用鉴权。
//
//  流程:
//  1. 搜索:GET https://music.163.com/api/search/get?s={q}&type=1&limit=5
//     → 取 songs[0..n],按 title/artist/duration 选最匹配的 songId
//  2. 歌词:GET https://music.163.com/api/song/lyric?id={songId}&lv=1&kv=1&tv=-1
//     → 返回 lrc.lyric 是 LRC 格式,直接喂给 LyricsParser
//
//  注意事项:
//  - 网易云对 Referer / User-Agent 敏感,必须带
//  - 部分歌曲 lrc.lyric 存在但 content 为空,要 fallback 到空
//  - 全部走 async/await + URLSession,跟 LRCLIBClient 风格一致
//

import Foundation
import OSLog

public struct NetEaseClient: Sendable {

    public let session: URLSession
    private let logger = Logger(subsystem: "com.local.NiceLyricsX", category: "NetEase")

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - 公开 API

    /// 搜索 + 取歌词的合并入口。LRCLIB 没结果时调这个。
    public func searchLyrics(
        title: String,
        artist: String,
        duration: TimeInterval? = nil,
        trackKey: String? = nil
    ) async throws -> Lyrics {
        FileHandle.standardError.write(Data("[NetEase] search title=\(title) artist=\(artist)\n".utf8))

        // 1. 搜索:网易云搜中文时 title 比 q=更精准;q 是"title+artist"
        let query = "\(title) \(artist)"
        let results = try await fetchSearchResults(query: query)
        FileHandle.standardError.write(Data("[NetEase] got \(results.count) candidates\n".utf8))

        guard let best = pickBestMatch(
            from: results,
            targetTitle: title,
            targetArtist: artist,
            targetDuration: duration
        ) else {
            throw LyricsError.noResult
        }
        FileHandle.standardError.write(Data("[NetEase] best: \(best.name) - \(best.artistsName) dur=\(best.duration) id=\(best.id)\n".utf8))

        // 2. 取歌词
        let lyricText = try await fetchLyrics(songId: best.id)
        guard !lyricText.isEmpty else {
            throw LyricsError.noResult
        }

        return LyricsParser.parse(lrcText: lyricText, trackKey: trackKey, source: "NetEase")
    }

    // MARK: - /api/search/get

    private func fetchSearchResults(query: String) async throws -> [NetEaseSong] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://music.163.com/api/search/get")!
        components.queryItems = [
            URLQueryItem(name: "s", value: trimmed),
            URLQueryItem(name: "type", value: "1"),   // 1 = 单曲
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "offset", value: "0")
        ]
        guard let url = components.url else { throw LyricsError.invalidResponse }

        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
                      forHTTPHeaderField: "User-Agent")
        // 网易云对外 API 需要 Referer 否则 403
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw LyricsError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                FileHandle.standardError.write(Data("[NetEase] search HTTP \(http.statusCode)\n".utf8))
                throw LyricsError.http(status: http.statusCode)
            }
            let envelope = try JSONDecoder().decode(NetEaseSearchResponse.self, from: data)
            return envelope.result.songs
        } catch let error as LyricsError {
            throw error
        } catch {
            throw LyricsError.network(underlying: error)
        }
    }

    // MARK: - /api/song/lyric

    private func fetchLyrics(songId: Int) async throws -> String {
        var components = URLComponents(string: "https://music.163.com/api/song/lyric")!
        components.queryItems = [
            URLQueryItem(name: "id", value: String(songId)),
            URLQueryItem(name: "lv", value: "1"),
            URLQueryItem(name: "kv", value: "1"),
            URLQueryItem(name: "tv", value: "-1")
        ]
        guard let url = components.url else { throw LyricsError.invalidResponse }

        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
                      forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw LyricsError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw LyricsError.http(status: http.statusCode)
            }
            let envelope = try JSONDecoder().decode(NetEaseLyricResponse.self, from: data)
            return envelope.lrc?.lyric ?? ""
        } catch let error as LyricsError {
            throw error
        } catch {
            throw LyricsError.network(underlying: error)
        }
    }

    // MARK: - 选最匹配

    private func pickBestMatch(
        from songs: [NetEaseSong],
        targetTitle: String,
        targetArtist: String,
        targetDuration: TimeInterval?
    ) -> NetEaseSong? {
        // 完全相等 + 时长匹配
        if let d = targetDuration, d > 0 {
            if let exact = songs.first(where: { song in
                song.name.caseInsensitiveCompare(targetTitle) == .orderedSame
                && song.artistsName.caseInsensitiveCompare(targetArtist) == .orderedSame
                && abs(song.durationSeconds - d) < 5
            }) {
                return exact
            }
        }

        // title + artist
        if let exact = songs.first(where: { song in
            song.name.caseInsensitiveCompare(targetTitle) == .orderedSame
            && song.artistsName.caseInsensitiveCompare(targetArtist) == .orderedSame
        }) {
            return exact
        }

        // 只 title
        if let partial = songs.first(where: { song in
            song.name.caseInsensitiveCompare(targetTitle) == .orderedSame
        }) {
            return partial
        }

        // 都没有 → 第一个
        return songs.first
    }
}

// MARK: - 数据模型

private struct NetEaseSearchResponse: Codable {
    let result: Result
    let code: Int

    struct Result: Codable {
        let songs: [NetEaseSong]
    }
}

public struct NetEaseSong: Codable {
    public let id: Int
    public let name: String
    public let duration: Int  // ms
    public let artists: [Artist]
    public let album: Album?

    public var artistsName: String {
        artists.map(\.name).joined(separator: " / ")
    }

    public var durationSeconds: TimeInterval {
        TimeInterval(duration) / 1000.0
    }

    public struct Artist: Codable {
        public let id: Int
        public let name: String
    }

    public struct Album: Codable {
        public let id: Int
        public let name: String
    }
}

private struct NetEaseLyricResponse: Codable {
    let code: Int
    let lrc: Lyric?
    let tlyric: Lyric?

    struct Lyric: Codable {
        let version: Int?
        let lyric: String?
    }
}
