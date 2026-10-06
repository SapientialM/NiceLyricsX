//
//  MenuBarView.swift
//  NiceLyricsX
//
//  菜单栏 status item + SwiftUI 下拉面板。
//
//  设计要点(参考 LyricsX MenuBarLyricsController):
//  - 单个 NSStatusItem,点击切换 SwiftUI Popover
//  - 可选在菜单栏图标旁直接显示当前歌词(`menubarLyricsEnabled`)
//  - 面板包含:曲目信息 + 封面、当前 / 上 / 下一行 + 翻译、状态、
//    歌词偏移、外观(字号 / 不透明度)、行为开关、维护动作
//  - 设置统一走 `AppSettingsStore`,视图里不再有"改了不生效"的死开关
//

import SwiftUI
import Combine
import AppKit

@MainActor
final class MenuBarController: NSObject, ObservableObject {

    private let lyricsEngine: LyricsEngine
    private let settings: AppSettingsStore
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables: Set<AnyCancellable> = []

    init(
        lyricsEngine: LyricsEngine,
        settings: AppSettingsStore,
        onResetDesktopPosition: @escaping () -> Void
    ) {
        self.lyricsEngine = lyricsEngine
        self.settings = settings
        super.init()
        setupStatusItem(onResetDesktopPosition: onResetDesktopPosition)
        observeEngine()
    }

    deinit {
        // popover 会在 dealloc 时自动关闭
    }

    nonisolated func cleanup() {
        Task { @MainActor in
            if let item = self.statusItem {
                NSStatusBar.system.removeStatusItem(item)
                self.statusItem = nil
            }
            self.popover?.close()
            self.popover = nil
        }
    }

    // MARK: - Setup

    private func setupStatusItem(onResetDesktopPosition: @escaping () -> Void) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "NiceLyricsX")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 580)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContent(
                lyricsEngine: lyricsEngine,
                settings: settings,
                onResetDesktopPosition: onResetDesktopPosition
            )
        )
        self.popover = popover
    }

    private func observeEngine() {
        // 图标形态跟着加载状态走
        lyricsEngine.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.updateStatusItemAppearance(for: status)
            }
            .store(in: &cancellables)

        // 菜单栏歌词文本:当前行 / 歌词整体 / 开关变化时刷新
        lyricsEngine.$currentLineIndex
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItemTitle() }
            .store(in: &cancellables)

        lyricsEngine.$currentLyrics
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItemTitle() }
            .store(in: &cancellables)

        settings.$menubarLyricsEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItemTitle() }
            .store(in: &cancellables)
    }

    private func updateStatusItemAppearance(for status: LyricsStatus) {
        guard let button = statusItem?.button else { return }
        let symbol: String
        let description: String
        switch status {
        case .searching:
            symbol = "ellipsis.circle"
            description = "搜索中"
        case .notFound:
            symbol = "music.note"
            description = "无歌词"
        case .failed:
            symbol = "exclamationmark.triangle"
            description = "错误"
        default:
            symbol = "music.note"
            description = "NiceLyricsX"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.image?.isTemplate = true
    }

    /// 菜单栏图标旁显示当前歌词行(可选功能)。
    private func updateStatusItemTitle() {
        guard let button = statusItem?.button else { return }

        var rendered = ""
        if settings.menubarLyricsEnabled,
           let lyrics = lyricsEngine.currentLyrics,
           let index = lyricsEngine.currentLineIndex,
           index < lyrics.lines.count {
            let content = lyrics.lines[index].content
            let trimmed = content.count > 26 ? String(content.prefix(25)) + "…" : content
            rendered = " " + trimmed
        }

        if button.title != rendered {
            button.title = rendered
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

// MARK: - 封面加载

/// 面板里的专辑封面。`PlaybackInfo.artworkURL` 通常为空(MediaRemote 已禁用),
/// 所以这里用 iTunes Search API 反查一次,结果缓存在 `ArtworkService` 里。
@MainActor
final class ArtworkStore: ObservableObject {

    @Published private(set) var url: URL?

    private var currentKey: String?
    private var task: Task<Void, Never>?

    func load(for info: PlaybackInfo) {
        let key = ArtworkService.cacheKey(title: info.title, artist: info.artist)
        guard key != currentKey else { return }
        currentKey = key
        task?.cancel()
        url = info.artworkURL

        guard !key.isEmpty, url == nil else { return }
        task = Task { [weak self] in
            let found = await ArtworkService.shared.artworkURL(title: info.title, artist: info.artist)
            guard !Task.isCancelled else { return }
            self?.url = found
        }
    }
}

// MARK: - 下拉内容 SwiftUI

struct MenuBarContent: View {

    @ObservedObject var lyricsEngine: LyricsEngine
    @ObservedObject var settings: AppSettingsStore
    var onResetDesktopPosition: () -> Void

    @StateObject private var artwork = ArtworkStore()
    @State private var automationStatus: AutomationPermission.Status = .notDetermined
    @State private var toast: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if automationStatus.needsAttention {
                        permissionWarning
                    }
                    trackCard
                    lyricsCard
                    transportSection
                    offsetSection
                    appearanceSection
                    notchSection
                    behaviorSection
                    maintenanceSection
                }
                .padding(16)
            }
        }
        .frame(width: 360)
        .onAppear {
            artwork.load(for: lyricsEngine.currentTrack)
            automationStatus = AutomationPermission.status()
        }
        .onChange(of: lyricsEngine.currentTrack) { _, track in
            artwork.load(for: track)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("NiceLyricsX").font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
            Spacer()
            Circle()
                .fill(lyricsEngine.isPlaying ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusText: String {
        switch lyricsEngine.status {
        case .idle: return lyricsEngine.currentTrack.title.isEmpty ? "等待播放" : "已停止"
        case .searching: return "搜索歌词…"
        case .loaded(let n): return "已加载 \(n) 行"
        case .notFound: return "未找到歌词"
        case .failed(let msg): return "错误: \(msg)"
        }
    }

    private var statusColor: Color {
        if case .failed = lyricsEngine.status { return .red }
        if case .notFound = lyricsEngine.status { return .orange }
        return .secondary
    }

    // MARK: 曲目信息

    private var trackCard: some View {
        HStack(alignment: .top, spacing: 10) {
            artworkThumbnail

            VStack(alignment: .leading, spacing: 2) {
                if lyricsEngine.currentTrack.title.isEmpty {
                    Text("没有正在播放的曲目")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(lyricsEngine.currentTrack.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(artistAlbumText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let source = lyricSourceText {
                        Text(source)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var artistAlbumText: String {
        let artist = lyricsEngine.currentTrack.artist
        let album = lyricsEngine.currentTrack.album
        if artist.isEmpty { return album }
        if album.isEmpty { return artist }
        return "\(artist) — \(album)"
    }

    private var lyricSourceText: String? {
        guard let lyrics = lyricsEngine.currentLyrics, !lyrics.source.isEmpty else { return nil }
        return "歌词来源:\(lyrics.source)"
    }

    @ViewBuilder
    private var artworkThumbnail: some View {
        Group {
            if let url = artwork.url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        artworkPlaceholder
                    }
                }
            } else {
                artworkPlaceholder
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var artworkPlaceholder: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.15))
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 歌词预览

    private var lyricsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let lyrics = lyricsEngine.currentLyrics, !lyrics.isEmpty,
               let idx = lyricsEngine.currentLineIndex, idx < lyrics.lines.count {
                if idx > 0 {
                    Text(lyrics[idx - 1].content)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(lyrics[idx].content)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                if settings.showTranslation,
                   let translation = lyrics[idx].translation, !translation.isEmpty {
                    Text(translation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if idx + 1 < lyrics.lines.count {
                    Text(lyrics[idx + 1].content)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if let lyrics = lyricsEngine.currentLyrics, !lyrics.isEmpty {
                Text("即将开始…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(lyrics[0].content)
                    .font(.title3)
                    .lineLimit(2)
            } else {
                Text(lyricsStatusPlaceholder)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var lyricsStatusPlaceholder: String {
        switch lyricsEngine.status {
        case .searching: return "正在搜索歌词…"
        case .notFound: return "未找到歌词"
        case .failed(let msg): return msg
        default: return "打开 Apple Music 播放歌曲后会自动加载歌词"
        }
    }

    // MARK: 播放控制

    /// 切歌 + 进度跳转。进度条用 `TimelineView` 自己驱动重绘 ——
    /// `LyricsEngine.playbackPosition` 基于墙钟实时算,不用等 2 秒轮询。
    private var transportSection: some View {
        PlaybackControlsRow(lyricsEngine: lyricsEngine)
            .disabled(lyricsEngine.currentTrack.title.isEmpty)
            .opacity(lyricsEngine.currentTrack.title.isEmpty ? 0.5 : 1)
    }

    // MARK: 偏移

    private var offsetSection: some View {
        section("歌词偏移") {
            HStack {
                Text(formattedDelay)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 56, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { lyricsEngine.timeDelay },
                        set: { lyricsEngine.timeDelay = $0 }
                    ),
                    in: -10...10,
                    step: 0.1
                )
            }
            HStack(spacing: 8) {
                Button("-1s") { lyricsEngine.adjustTimeDelay(by: -1) }
                Button("-0.1s") { lyricsEngine.adjustTimeDelay(by: -0.1) }
                Spacer()
                Button("重置") { lyricsEngine.timeDelay = 0 }
                Spacer()
                Button("+0.1s") { lyricsEngine.adjustTimeDelay(by: 0.1) }
                Button("+1s") { lyricsEngine.adjustTimeDelay(by: 1) }
            }
            .controlSize(.small)
        }
    }

    private var formattedDelay: String {
        let d = lyricsEngine.timeDelay
        if d == 0 { return "0.0s" }
        return String(format: "%+.1fs", d)
    }

    // MARK: 外观

    private var appearanceSection: some View {
        section("外观") {
            sliderRow(
                title: "字号",
                value: $settings.fontSize,
                range: AppSettings.desktopLyricsFontSizeRange,
                step: 1,
                display: "\(Int(settings.fontSize)) pt"
            )
            sliderRow(
                title: "不透明度",
                value: $settings.opacity,
                range: AppSettings.desktopLyricsOpacityRange,
                step: 0.05,
                display: "\(Int((settings.opacity * 100).rounded()))%"
            )
        }
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        display: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline)
                .frame(width: 56, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(display)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    // MARK: 刘海歌词

    private var notchSection: some View {
        section("刘海歌词") {
            Picker("", selection: $settings.notchLyricsMode) {
                ForEach(NotchLyricsMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(notchHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @MainActor
    private var notchHint: String {
        let notchState = NotchGeometry.notchedScreen() != nil
            ? "已识别到刘海"
            : "这台机器没有物理刘海,会用一块虚拟岛"
        switch settings.notchLyricsMode {
        case .off:
            return "\(notchState)。开启后歌词会挂在菜单栏下沿、水平居中于刘海。"
        case .peek:
            return "\(notchState)。切歌时出现约 3.5 秒;鼠标移到刘海或歌词条上会保持展开。"
        case .always:
            return "\(notchState)。歌词常驻在刘海正下方 —— 占的是菜单栏下面那一条,不动菜单栏本身。"
        }
    }

    // MARK: 行为开关

    private var behaviorSection: some View {
        section("行为") {
            Toggle("桌面歌词", isOn: $settings.desktopLyricsEnabled)
            Toggle("鼠标穿透(歌词不阻挡点击)", isOn: $settings.clickThrough)
            Toggle("显示翻译", isOn: $settings.showTranslation)
            Toggle("启动时自动打开桌面歌词", isOn: $settings.desktopLyricsAutoOpen)
            Toggle("菜单栏显示当前歌词", isOn: $settings.menubarLyricsEnabled)
            Toggle("登录时启动", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { settings.setLaunchAtLogin($0) }
            ))
            if let error = settings.launchAtLoginError {
                Text("登录项设置失败:\(error)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    // MARK: 维护

    private var maintenanceSection: some View {
        section("维护") {
            HStack(spacing: 8) {
                Button("重新搜索歌词") {
                    lyricsEngine.reloadCurrent()
                    showToast("正在重新搜索…")
                }
                Button("重置窗口位置") {
                    onResetDesktopPosition()
                    showToast("桌面歌词窗口已回到默认位置")
                }
            }
            .controlSize(.small)

            HStack(spacing: 8) {
                Button("清除歌词缓存") {
                    Task {
                        await lyricsEngine.clearCacheAndReload()
                        showToast("缓存已清除")
                    }
                }
                .controlSize(.small)

                Spacer()

                Button("退出") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
                .controlSize(.small)
            }

            if let toast {
                Text(toast)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toast == message { toast = nil }
        }
    }

    // MARK: 权限提示

    private var permissionWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("自动化权限被拒绝,读不到 Apple Music", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Text("系统设置 → 隐私与安全性 → 自动化 → NiceLyricsX → 勾选 Music")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("打开系统设置") { AutomationPermission.openSystemSettings() }
                Button("重新检查") { automationStatus = AutomationPermission.status() }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }

    // MARK: 布局工具

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            content()
        }
    }
}
