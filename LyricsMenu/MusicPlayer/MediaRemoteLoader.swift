//
//  MediaRemoteLoader.swift
//  NiceLyricsX
//
//  MediaRemote 私有 framework 动态加载器。
//
//  背景:
//  - MediaRemote.framework 是 macOS 私有 API,但提供了"系统级当前播放信息"读取能力
//  - macOS 14+ 配合 `NSNowPlayingInfoCenter` / `MRNowPlayingInfo`,可以做到
//    "一次调用拿全所有播放器的信息",且不需要 ScriptingBridge 反射
//  - 直接 import MediaRemote 会让 App Store 审核失败,所以这里用 dlopen + dlsym
//    按需加载(借鉴 LyricsX 的 MRPrivateLoader.m 思路)
//  - macOS 16+ 上,Apple 已经把部分 NowPlaying API 公开化,这里同时支持两条路径
//

import Foundation
import Darwin

/// MediaRemote 符号加载器。
///
/// 使用方式:
/// ```swift
/// if let mr = MediaRemoteLoader.shared {
///     let info = mr.getNowPlayingInfo()
/// }
/// ```
///
/// 所有符号按需 dlsym,加载失败时不崩溃,只返回 nil,UI 层会 fallback 到 Apple Script 路径。
public final class MediaRemoteLoader: @unchecked Sendable {

    public static let shared: MediaRemoteLoader? = {
        return MediaRemoteLoader()
    }()

    private let handle: UnsafeMutableRawPointer?
    private let isAvailable: Bool

    // 函数指针
    private let _MRMediaRemoteGetNowPlayingInfo: MRMediaRemoteGetNowPlayingInfo?
    private let _MRMediaRemoteSetElapsedTime: MRMediaRemoteSetElapsedTime?
    private let _MRMediaRemoteSendCommand: MRMediaRemoteSendCommand?
    private let _MRMediaRemoteRegisterForNowPlayingNotifications: MRMediaRemoteRegisterForNowPlayingNotifications?
    private let _MRMediaRemoteUnregisterForNowPlayingNotifications: MRMediaRemoteUnregisterForNowPlayingNotifications?
    private let _MRNowPlayingClientGetBundleIdentifier: MRNowPlayingClientGetBundleIdentifier?
    private let _MRNowPlayingClientGetDisplayName: MRNowPlayingClientGetDisplayName?
    private let _MRNowPlayingClientGetParentAppBundleIdentifier: MRNowPlayingClientGetParentAppBundleIdentifier?

    private init?() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let h = dlopen(path, RTLD_LAZY) else {
            return nil
        }
        self.handle = h
        self.isAvailable = true

        self._MRMediaRemoteGetNowPlayingInfo = Self.load(h, "MRMediaRemoteGetNowPlayingInfo")
        self._MRMediaRemoteSetElapsedTime = Self.load(h, "MRMediaRemoteSetElapsedTime")
        self._MRMediaRemoteSendCommand = Self.load(h, "MRMediaRemoteSendCommand")
        self._MRMediaRemoteRegisterForNowPlayingNotifications = Self.load(h, "MRMediaRemoteRegisterForNowPlayingNotifications")
        self._MRMediaRemoteUnregisterForNowPlayingNotifications = Self.load(h, "MRMediaRemoteUnregisterForNowPlayingNotifications")
        self._MRNowPlayingClientGetBundleIdentifier = Self.load(h, "MRNowPlayingClientGetBundleIdentifier")
        self._MRNowPlayingClientGetDisplayName = Self.load(h, "MRNowPlayingClientGetDisplayName")
        self._MRNowPlayingClientGetParentAppBundleIdentifier = Self.load(h, "MRNowPlayingClientGetParentAppBundleIdentifier")
    }

    deinit {
        if let h = handle { dlclose(h) }
    }

    public var canUse: Bool { isAvailable }

    // MARK: - Now Playing Info

    /// 调用 `MRMediaRemoteGetNowPlayingInfo` 并把结果字典转成 `PlaybackInfo`。
    /// 失败或无播放器时返回 `.empty`。
    public func getNowPlayingInfo() -> PlaybackInfo {
        guard let info = getNowPlayingDictionary() else { return .empty }
        return parseNowPlayingInfo(info)
    }

    /// 直接拿原始 dictionary(供 artwork 等扩展字段使用)。
    /// 返回 `nil` 表示 MediaRemote 不可用或当前无播放器。
    ///
    /// 真实签名(LyricsX `MRPrivateLoader.m` 用的就是这种):
    /// ```c
    /// CFDictionaryRef MRMediaRemoteGetNowPlayingInfo(void);
    /// ```
    /// 同步调用,直接返回字典(可能是 NULL,表示当前没有播放器在播)。
    public func getNowPlayingDictionary() -> [String: Any]? {
        guard let fn = _MRMediaRemoteGetNowPlayingInfo else { return nil }
        // MediaRemote 在调用方的引用计数约定:
        // 返回的字典是 +1 retain,这里用 takeRetainedValue 平衡。
        let unmanaged = unsafe fn()
        guard let unmanaged else { return nil }
        // CFDictionaryRef (CoreFoundation) 与 NSDictionary 是 toll-free bridged,
        // 这里先取到 CFDictionary,再转成 NSDictionary。
        let cfDict = unmanaged.takeRetainedValue()
        let nsDict = cfDict as NSDictionary
        return nsDict as? [String: Any]
    }

    /// 提取当前播放的 artwork token(用于构造 iTunes 风格封面 URL)。
    public func artworkToken() -> String? {
        guard let dict = getNowPlayingDictionary(),
              let artwork = dict["kMRMediaRemoteNowPlayingInfoArtworkIdentifier"] as? [String: Any],
              let ident = artwork["identifier"] as? String else {
            return nil
        }
        return ident
    }

    /// 把 MR 返回的字典转成 `PlaybackInfo`。
    public func parseNowPlayingInfo(_ dict: [String: Any]) -> PlaybackInfo {
        // 关键字段(参考 MediaRemote.h):
        // kMRMediaRemoteNowPlayingInfoTitle
        // kMRMediaRemoteNowPlayingInfoArtist
        // kMRMediaRemoteNowPlayingInfoAlbum
        // kMRMediaRemoteNowPlayingInfoDuration
        // kMRMediaRemoteNowPlayingInfoElapsedTime
        // kMRMediaRemoteNowPlayingInfoPlaybackRate
        // kMRMediaRemoteNowPlayingInfoIsMusicApp
        // kMRMediaRemoteNowPlayingInfoArtworkData

        let title = (dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String) ?? ""
        let artist = (dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String) ?? ""
        let album = (dict["kMRMediaRemoteNowPlayingInfoAlbum"] as? String) ?? ""
        let duration = (dict["kMRMediaRemoteNowPlayingInfoDuration"] as? Double) ?? 0

        let elapsed = (dict["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double) ?? 0
        let rate = (dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double) ?? 0

        // 用播放速率 + elapsed 推断状态:
        // rate > 0 → playing,且 startTime = now - elapsed
        // rate == 0 → paused
        let state: PlaybackState
        if rate > 0 && elapsed > 0 {
            state = .playing(start: Date(timeIntervalSinceNow: -elapsed))
        } else if elapsed > 0 {
            state = .paused(time: elapsed)
        } else {
            state = .stopped
        }

        let parentBundleID = (dict["kMRMediaRemoteNowPlayingInfoParentApplicationBundleIdentifier"] as? String)
            ?? (dict["kMRMediaRemoteNowPlayingInfoApplicationDisplayName"] as? String)
            ?? "MediaRemote"

        return PlaybackInfo(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
            album: album.trimmingCharacters(in: .whitespacesAndNewlines),
            duration: duration,
            state: state,
            source: parentBundleID
        )
    }

    // MARK: - Notifications

    /// 注册 NowPlaying 变更通知(走 DistributedNotificationCenter)。
    /// 实际监听我们用 NSDistributedNotificationCenter,这里只暴露开关。
    public func registerForNotifications() {
        _MRMediaRemoteRegisterForNowPlayingNotifications?(DispatchQueue.main)
    }

    public func unregisterForNotifications() {
        _MRMediaRemoteUnregisterForNowPlayingNotifications?()
    }

    // MARK: - Internal

    private static func load<T>(_ handle: UnsafeMutableRawPointer, _ symbol: String) -> T? {
        guard let ptr = dlsym(handle, symbol) else { return nil }
        return unsafeBitCast(ptr, to: T.self)
    }
}

// MARK: - C Function Pointer Types

/// `CFDictionaryRef MRMediaRemoteGetNowPlayingInfo(void)`
/// 同步返回当前播放信息字典(可能是 NULL,表示当前没有播放器在播)。
/// 参考 LyricsX `MRPrivateLoader.m` 的实际调用方式。
private typealias MRMediaRemoteGetNowPlayingInfo = @convention(c) () -> Unmanaged<CFDictionary>?

/// `Boolean MRMediaRemoteSetElapsedTime(NSTimeInterval elapsedTime)`
/// macOS 14+ 公开 API 的近似签名;失败时返回 false。
private typealias MRMediaRemoteSetElapsedTime = @convention(c) (Double) -> Bool

/// `void MRMediaRemoteSendCommand(MRCommand command, ...)`
/// 这里的 cmd 是 Int32,LyricsX 用的常量也是 Int32。
private typealias MRMediaRemoteSendCommand = @convention(c) (Int32) -> Void

/// `void MRMediaRemoteRegisterForNowPlayingNotifications(dispatch_queue_t queue)`
/// 注册系统级 Now Playing 变更通知(由 `com.apple.MediaRemote.nowPlayingInfo` 发出)。
private typealias MRMediaRemoteRegisterForNowPlayingNotifications = @convention(c) (DispatchQueue) -> Void

private typealias MRMediaRemoteUnregisterForNowPlayingNotifications = @convention(c) () -> Void

private typealias MRNowPlayingClientGetBundleIdentifier = @convention(c) (UnsafeMutableRawPointer?) -> Unmanaged<CFString>?
private typealias MRNowPlayingClientGetDisplayName = @convention(c) (UnsafeMutableRawPointer?) -> Unmanaged<CFString>?
private typealias MRNowPlayingClientGetParentAppBundleIdentifier = @convention(c) (UnsafeMutableRawPointer?) -> Unmanaged<CFString>?