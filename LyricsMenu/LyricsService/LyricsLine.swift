//
//  LyricsLine.swift
//  NiceLyricsX
//
//  单行歌词数据模型。
//
//  设计要点:
//  - `Lyrics` 是一个有序的 `LyricsLine` 集合,实现 `RandomAccessCollection`
//    以便二分搜索当前行(参考 LyricsX `Lyrics.swift` 的 `searchLine(at:)`)
//  - 行支持 inline translation(同时间戳的另一种语言)
//  - `timeDelay` 是用户配置的全局偏移(单位:秒),由 `LyricsEngine` 在切行前加上
//

import Foundation

// MARK: - LyricsLine

/// 单行歌词(带时间戳 + 可选翻译)。
public struct LyricsLine: Sendable, Equatable, Hashable, Identifiable {
    /// 唯一 ID(用 index 即可,因为 lines 是有序集合)。
    public var id: Int { index }

    /// 原始 LRC 里的行号(从 0 开始)。
    public let index: Int

    /// 该行的播放时间(秒)。
    public let position: TimeInterval

    /// 主要歌词文本。
    public let content: String

    /// 翻译(可选)。
    public let translation: String?

    public init(index: Int, position: TimeInterval, content: String, translation: String? = nil) {
        self.index = index
        self.position = position
        self.content = content
        self.translation = translation
    }
}

// MARK: - Lyrics

/// 完整歌词文档。实现 `RandomAccessCollection`,可直接 for-in 或下标访问。
public struct Lyrics: Sendable, Equatable, Hashable, RandomAccessCollection {

    public typealias Element = LyricsLine

    /// 有序歌词行集合。
    public let lines: [LyricsLine]

    /// 全局偏移(秒),由用户调整写入,影响切行匹配。
    public let timeDelay: TimeInterval

    /// 歌词来源标识(LRCLIB / Cache / Manual)。
    public let source: String

    /// 关联的曲目信息(便于 cache 复用)。
    public let trackKey: String?

    public init(
        lines: [LyricsLine],
        timeDelay: TimeInterval = 0,
        source: String = "",
        trackKey: String? = nil
    ) {
        self.lines = lines.sorted { $0.position < $1.position }
        self.timeDelay = timeDelay
        self.source = source
        self.trackKey = trackKey
    }

    // MARK: - RandomAccessCollection

    public var startIndex: Int { lines.startIndex }
    public var endIndex: Int { lines.endIndex }
    public subscript(position: Int) -> LyricsLine { lines[position] }

    public var count: Int { lines.count }
    public var isEmpty: Bool { lines.isEmpty }

    // MARK: - 二分查找

    /// 给定播放进度,返回应该高亮的行索引。
    ///
    /// - Returns: 最接近且 `position <= time` 的行(lower_bound - 1)。
    ///           如果所有行都晚于 `time`,返回 nil。
    ///
    /// 这是 LyricsX `Lyrics.lineIndex(at:)` 的简化版(无 inline timetag)。
    public func lineIndex(at time: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        let adjusted = time + timeDelay

        // 二分查找第一个 position > adjusted 的位置
        var lo = 0
        var hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].position <= adjusted {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo > 0 ? lo - 1 : nil
    }

    /// 给定行索引,返回"下一行还有多久"。
    /// 返回 `nil` 表示已是最后一行。
    public func timeToNextLine(from index: Int) -> TimeInterval? {
        guard index >= 0, index + 1 < lines.count else { return nil }
        return lines[index + 1].position - lines[index].position
    }

    /// 给定播放进度,返回 `(currentIndex, nextIndex, timeToNext)` 三元组。
    /// - currentIndex: 当前行(可为 nil,如果 `time` 比第一行还早)
    /// - nextIndex: 下一行(可为 nil)
    /// - timeToNext: 距离下一行的秒数
    public func progress(at time: TimeInterval) -> (current: Int?, next: Int?, timeToNext: TimeInterval?) {
        let current = lineIndex(at: time)
        let next = current.flatMap { $0 + 1 < lines.count ? $0 + 1 : nil }
        let adjusted = time + timeDelay
        let timeToNext: TimeInterval? = next.map { lines[$0].position - adjusted }
        return (current, next, timeToNext)
    }

    /// 当前行 + 下一行 + 上一行的"上下文窗口",用于 UI 上三行展示。
    public func context(at time: TimeInterval) -> (previous: LyricsLine?, current: LyricsLine?, next: LyricsLine?) {
        let cur = lineIndex(at: time)
        let prev = cur.flatMap { $0 > 0 ? lines[$0 - 1] : nil }
        let next = cur.flatMap { $0 + 1 < lines.count ? lines[$0 + 1] : nil }
        let curLine = cur.map { lines[$0] }
        return (prev, curLine, next)
    }

    /// 缓存键 —— 用 "title|artist|duration" 拼出来的稳定字符串。
    public static func trackKey(title: String, artist: String, duration: TimeInterval) -> String {
        let dur = Int(duration.rounded())
        return "\(title.lowercased())|\(artist.lowercased())|\(dur)"
    }
}

// MARK: - 空占位

extension Lyrics {
    public static let empty = Lyrics(lines: [], source: "")
}