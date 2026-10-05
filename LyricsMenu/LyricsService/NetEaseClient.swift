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

        // 2. 取歌词(正文 + 翻译)
        let payload = try await fetchLyrics(songId: best.id)
        guard !payload.lrc.isEmpty else {
            throw LyricsError.noResult
        }

        var lyrics = LyricsParser.parse(lrcText: payload.lrc, trackKey: trackKey, source: "NetEase")

        // 3. 合并 tlyric 翻译(网易云把翻译放在独立的 LRC 里,时间戳对齐)。
        //    注意 tlyric 经常存在但内容为空 / 时间戳对不上 —— 只有真的合上了
        //    才改 source,不然 UI 会显示"有翻译"却一行都看不到。
        lyrics = Self.mergingTranslation(into: lyrics, tlyric: payload.translation)

        let translatedCount = lyrics.lines.filter { $0.translation?.isEmpty == false }.count
        FileHandle.standardError.write(Data("[NetEase] parsed \(lyrics.count) lines, translated=\(translatedCount)\n".utf8))
        return lyrics
    }

    /// 把网易云的 tlyric 合进正文歌词。
    /// 只有确实有行被翻译到了,才把 source 标成 `NetEase + 翻译`。可单测。
    public static func mergingTranslation(into lyrics: Lyrics, tlyric: String?) -> Lyrics {
        guard let tlyric, !tlyric.isEmpty else { return lyrics }
        let table = translationTable(fromLRC: tlyric)
        guard !table.isEmpty else { return lyrics }

        let merged = lyrics.applyingTranslations(table)
        guard merged.lines.contains(where: { $0.translation?.isEmpty == false }) else {
            return merged
        }
        return Lyrics(
            lines: merged.lines,
            timeDelay: merged.timeDelay,
            source: "NetEase + 翻译",
            trackKey: merged.trackKey
        )
    }

    /// 把网易云的 tlyric 文本转成 `[毫秒key: 译文]` 查表。可单测。
    public static func translationTable(fromLRC text: String) -> [Int: String] {
        let parsed = LyricsParser.parse(lrcText: text, source: "NetEaseTranslation")
        var table: [Int: String] = [:]
        for line in parsed.lines where !line.content.isEmpty {
            table[Lyrics.translationKey(for: line.position)] = line.content
        }
        return table
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
            // 429 / 5xx 会自动退避重试(见 HTTPRetry.swift)
            let (data, http) = try await session.retryingData(for: req)
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

    /// 取歌词。`tv=-1` 时网易云会额外返回 `tlyric`(翻译),这里一并带回。
    private func fetchLyrics(songId: Int) async throws -> LyricPayload {
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
            let (data, http) = try await session.retryingData(for: req)
            guard (200..<300).contains(http.statusCode) else {
                throw LyricsError.http(status: http.statusCode)
            }
            let envelope = try JSONDecoder().decode(NetEaseLyricResponse.self, from: data)
            let lrc = envelope.lrc?.lyric ?? ""
            let translation = envelope.tlyric?.lyric
            return LyricPayload(lrc: lrc, translation: translation)
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

/// `/api/song/lyric` 的正文 + 翻译载荷。
struct LyricPayload: Sendable, Equatable {
    let lrc: String
    let translation: String?
}

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
