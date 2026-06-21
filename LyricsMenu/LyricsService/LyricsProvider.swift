//
//  LyricsProvider.swift
//  NiceLyricsX
//
//  歌词提供器 —— 协调"在线搜索 + 本地缓存 + 失败兜底"的统一入口。
//
//  借鉴 LyricsX 的二段式 Provider + 流式竞价思想:
//  - `loadLyrics(for: PlaybackInfo)` 是对外唯一入口
//  - 内部:先查缓存 → 没命中则 LRCLIB → 命中后写缓存
//  - 用单次串行 await(简化版,后续可扩展为流式多源竞价)
//
//  本类也是 `LyricsEngine` 用来真正"加载歌词"的部分;
//  `LyricsEngine` 持有它,并负责切行匹配 + 当前行计算。
//

import Foundation
import OSLog

public actor LyricsProvider {

    private let client: LRCLIBClient
    private let netEaseClient: NetEaseClient
    private let cache: LyricsCache
    private let logger = Logger(subsystem: "com.local.NiceLyricsX", category: "LyricsProvider")

    public init(
        client: LRCLIBClient = LRCLIBClient(),
        netEaseClient: NetEaseClient = NetEaseClient(),
        cache: LyricsCache = .shared
    ) {
        self.client = client
        self.netEaseClient = netEaseClient
        self.cache = cache
    }

    // MARK: - 公开 API

    /// 给定播放信息,加载歌词。
    /// 优先本地缓存,失败则 LRCLIB 在线搜索,再失败则 NetEase 网易云 fallback。
    public func loadLyrics(for info: PlaybackInfo) async throws -> Lyrics {
        guard !info.title.isEmpty, !info.artist.isEmpty else {
            throw LyricsError.noResult
        }

        let trackKey = Lyrics.trackKey(
            title: info.title,
            artist: info.artist,
            duration: info.duration
        )

        // 1. 本地缓存
        if let cached = await cache.load(trackKey: trackKey),
           !cached.lines.isEmpty {
            logger.debug("歌词命中缓存: \(trackKey, privacy: .public)")
            return cached
        }

        // 2. LRCLIB 搜索(英文 / 海外流行华语覆盖最好)
        do {
            logger.debug("歌词在线搜索 LRCLIB: title=\(info.title, privacy: .public) artist=\(info.artist, privacy: .public)")
            let lyrics = try await client.searchLyrics(
                title: info.title,
                artist: info.artist,
                duration: info.duration > 0 ? info.duration : nil,
                trackKey: trackKey
            )
            cacheSave(lyrics: lyrics, trackKey: trackKey)
            return lyrics
        } catch let lErr as LyricsError {
            if case .noResult = lErr {
                // LRCLIB 没结果,继续走 NetEase
                FileHandle.standardError.write(Data("[LyricsProvider] LRCLIB miss, falling through to NetEase\n".utf8))
            } else {
                // 其他错误(网络/解析)直接抛,不再 fallback
                throw lErr
            }
        }

        // 3. NetEase 网易云 fallback(中文 / 抖音 / 网络新歌)
        let lyrics = try await netEaseClient.searchLyrics(
            title: info.title,
            artist: info.artist,
            duration: info.duration > 0 ? info.duration : nil,
            trackKey: trackKey
        )
        cacheSave(lyrics: lyrics, trackKey: trackKey)
        return lyrics
    }

    private func cacheSave(lyrics: Lyrics, trackKey: String) {
        Task.detached(priority: .background) { [cache] in
            await cache.save(lyrics: lyrics, trackKey: trackKey)
        }
    }

    /// 预取(不强求成功,只用于后台刷新)。
    public func prefetch(for info: PlaybackInfo) async {
        do {
            _ = try await loadLyrics(for: info)
        } catch {
            logger.debug("预取失败: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - 本地缓存

/// 歌词本地缓存 —— 写入 `~/Library/Application Support/NiceLyricsX/lyrics/{trackKey}.json`
public actor LyricsCache {

    public static let shared = LyricsCache()

    private let directory: URL
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "com.local.NiceLyricsX", category: "LyricsCache")

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            // 默认路径
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? FileManager.default.temporaryDirectory
            self.directory = base
                .appendingPathComponent("NiceLyricsX", isDirectory: true)
                .appendingPathComponent("lyrics", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public func load(trackKey: String) -> Lyrics? {
        let url = fileURL(for: trackKey)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let dto = try JSONDecoder().decode(CachedLyricsDTO.self, from: data)
            return dto.toLyrics()
        } catch {
            logger.warning("缓存反序列化失败: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public func save(lyrics: Lyrics, trackKey: String) {
        let dto = CachedLyricsDTO(from: lyrics)
        let url = fileURL(for: trackKey)
        do {
            let data = try JSONEncoder().encode(dto)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.warning("缓存写入失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func clear() {
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in contents {
            try? fileManager.removeItem(at: url)
        }
    }

    private func fileURL(for trackKey: String) -> URL {
        // 缓存 key 不能含 / 或空格,简单 hash 一下
        let safe = trackKey
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "|", with: "_")
        return directory.appendingPathComponent("\(safe).json")
    }
}

// MARK: - 缓存 DTO

private struct CachedLyricsDTO: Codable {
    let source: String
    let timeDelay: TimeInterval
    let trackKey: String?
    let lines: [Line]

    struct Line: Codable {
        let index: Int
        let position: TimeInterval
        let content: String
        let translation: String?
    }

    init(from lyrics: Lyrics) {
        self.source = lyrics.source
        self.timeDelay = lyrics.timeDelay
        self.trackKey = lyrics.trackKey
        self.lines = lyrics.lines.map {
            Line(index: $0.index, position: $0.position, content: $0.content, translation: $0.translation)
        }
    }

    func toLyrics() -> Lyrics {
        let lyricLines = lines.map {
            LyricsLine(index: $0.index, position: $0.position, content: $0.content, translation: $0.translation)
        }
        return Lyrics(lines: lyricLines, timeDelay: timeDelay, source: source, trackKey: trackKey)
    }
}