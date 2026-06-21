//
//  PlaybackInfo.swift
//  NiceLyricsX
//
//  数据模型层 —— 当前播放曲目与播放器状态。
//
//  设计要点(借鉴 LyricsX 的 Player 状态机):
//  - `PlaybackState.playing` 用 wall-clock 起播时间表达,而非累计时长。
//    这样 `state.time` 可以零延迟算出当前进度,且不需要内部维护计时器。
//  - `PlaybackInfo` 是不可变值类型(`Sendable`),便于跨 actor 传递。
//  - `currentLineIndex` 由 `LyricsEngine` 推算,这里只持有,不参与匹配。
//

import Foundation

// MARK: - PlaybackState

/// 播放器状态枚举(值语义,可跨 actor 安全传递)。
///
/// - `.playing(start: Date)` — 播放中,`start` 为起播时刻(系统墙钟)。
///   实际播放进度 = `Date.now.timeIntervalSince(start)`,误差为 0,
///   且无需 player 内部维护计时器。
/// - `.paused(time: TimeInterval)` — 暂停,记录最后一次播放进度。
/// - `.stopped` — 已停止或无曲目。
public enum PlaybackState: Sendable, Equatable, Hashable {
    case stopped
    case playing(start: Date)
    case paused(time: TimeInterval)

    public var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    public var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    /// 当前播放进度(秒)。playing 时实时计算,paused 时取冻结值。
    public var time: TimeInterval {
        switch self {
        case .stopped:
            return 0
        case .playing(let start):
            return Date.now.timeIntervalSince(start)
        case .paused(let t):
            return max(0, t)
        }
    }

    /// 容差比较 —— 1.5 秒内的状态变更视为"同一状态",吃掉通知抖动。
    public func approximateEqual(to other: PlaybackState, tolerate: TimeInterval = 1.5) -> Bool {
        switch (self, other) {
        case (.stopped, .stopped):
            return true
        case (.paused(let a), .paused(let b)):
            return abs(a - b) < tolerate
        case (.playing(let a), .playing(let b)):
            return abs(a.timeIntervalSince(b)) < tolerate
        default:
            return false
        }
    }
}

// MARK: - PlaybackInfo

/// 当前播放曲目的不可变快照。
///
/// 当曲目或播放进度发生显著变化时,`MusicPlayer` 会广播一个新的 `PlaybackInfo`。
/// `LyricsEngine` 监听此流,自动重新搜索歌词。
public struct PlaybackInfo: Sendable, Equatable, Hashable {

    /// 曲目在播放器内部的稳定标识(用于本地歌词缓存匹配)。
    public let trackID: String?

    /// 曲名(已 trim)。
    public let title: String

    /// 艺人(已 trim)。
    public let artist: String

    /// 专辑。
    public let album: String

    /// 曲目总时长(秒)。未知时为 0。
    public let duration: TimeInterval

    /// 当前播放器状态。
    public let state: PlaybackState

    /// 播放器源标识("Apple Music" / "iTunes" / "Spotify" 等)。
    public let source: String

    /// 曲目封面 URL(可选)。Apple Music 用 `mrmusic.itunes.apple.com` 的 artwork。
    public let artworkURL: URL?

    public init(
        trackID: String? = nil,
        title: String,
        artist: String,
        album: String = "",
        duration: TimeInterval = 0,
        state: PlaybackState = .stopped,
        source: String = "Unknown",
        artworkURL: URL? = nil
    ) {
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.state = state
        self.source = source
        self.artworkURL = artworkURL
    }

    /// 当前播放进度(秒)的便捷访问。
    public var playbackTime: TimeInterval { state.time }

    /// 是否处于"正在播放"状态。
    public var isPlaying: Bool { state.isPlaying }

    /// 用于搜索关键词的拼接 —— "title artist"。
    public var searchQuery: String {
        [title, artist].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// 空曲目占位(无播放 / 未启动)。
    public static let empty = PlaybackInfo(
        title: "",
        artist: "",
        album: "",
        duration: 0,
        state: .stopped,
        source: ""
    )
}

// MARK: - LyricsStatus

/// 歌词引擎对外的状态机 —— UI 层订阅它来显示状态文案。
public enum LyricsStatus: Sendable, Equatable {
    case idle
    case searching
    case loaded(lineCount: Int)
    case notFound
    case failed(message: String)

    public var displayText: String {
        switch self {
        case .idle:
            return "等待播放"
        case .searching:
            return "正在搜索歌词…"
        case .loaded(let n):
            return "歌词已加载 (\(n) 行)"
        case .notFound:
            return "未找到歌词"
        case .failed(let msg):
            return "错误: \(msg)"
        }
    }
}