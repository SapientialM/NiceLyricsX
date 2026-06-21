//
//  MenuBarView.swift
//  NiceLyricsX
//
//  菜单栏 status item + SwiftUI 下拉面板。
//
//  设计要点(参考 LyricsX MenuBarLyricsController):
//  - 单个 NSStatusItem,点击切换 SwiftUI Popover
//  - SwiftUI 面板包含:当前曲目信息、当前/下一行歌词、状态指示、偏移调节按钮、开关
//  - 下拉内容用 `MenuBarExtra` SwiftUI 14+ 实现,跨平台一致
//
//  macOS 16+ 适配:用 `MenuBarExtra` SwiftUI Scene,替代旧版 NSStatusItem.menu = NSMenu 模式。
//  这样可以享受 SwiftUI 的声明式 UI + 自动适配 Light/Dark 模式。
//

import SwiftUI
import Combine
import AppKit

@MainActor
final class MenuBarController: NSObject, ObservableObject {

    private let lyricsEngine: LyricsEngine
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables: Set<AnyCancellable> = []

    init(lyricsEngine: LyricsEngine) {
        self.lyricsEngine = lyricsEngine
        super.init()
        setupStatusItem()
        observeEngine()
    }

    deinit {
        // popover 会在 dealloc 时自动关闭
        // 不主动调 close() 因为它需要 main actor
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

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "NiceLyricsX")
            button.image?.isTemplate = true
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 480)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContent(lyricsEngine: lyricsEngine, onClose: { [weak self] in
                self?.popover?.performClose(nil)
            })
        )
        self.popover = popover
    }

    private func observeEngine() {
        // 状态变化时,如果 statusItem 标题被占用,更新 SF Symbol 显示
        lyricsEngine.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.updateStatusItemAppearance(for: status)
            }
            .store(in: &cancellables)
    }

    private func updateStatusItemAppearance(for status: LyricsStatus) {
        guard let button = statusItem?.button else { return }
        switch status {
        case .searching:
            button.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "搜索中")
            button.image?.isTemplate = true
        case .notFound:
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "无歌词")
            button.image?.isTemplate = true
        case .failed:
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "错误")
            button.image?.isTemplate = true
        default:
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "NiceLyricsX")
            button.image?.isTemplate = true
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

// MARK: - 下拉内容 SwiftUI

struct MenuBarContent: View {

    @ObservedObject var lyricsEngine: LyricsEngine
    var onClose: () -> Void

    @State private var desktopEnabled: Bool = AppSettings.desktopLyricsEnabled
    @State private var autoOpen: Bool = AppSettings.desktopLyricsAutoOpen
    @State private var clickThrough: Bool = AppSettings.clickThrough

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            trackInfo
            Divider()
            lyricsView
            Divider()
            offsetControls
            Divider()
            toggleControls
        }
        .padding(16)
        .frame(width: 360)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Image(systemName: "music.note.list")
                .font(.title2)
            VStack(alignment: .leading) {
                Text("NiceLyricsX").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusText: String {
        switch lyricsEngine.status {
        case .idle: return "等待播放"
        case .searching: return "搜索歌词…"
        case .loaded(let n): return "已加载 \(n) 行"
        case .notFound: return "未找到歌词"
        case .failed(let msg): return "错误: \(msg)"
        }
    }

    // MARK: 当前曲目

    @ViewBuilder
    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .loaded = lyricsEngine.status {
                HStack {
                    Image(systemName: "music.quarternote.3")
                    Text("歌词已就绪")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Image(systemName: "hourglass")
                    Text("启动 Apple Music 并播放歌曲后会自动加载歌词")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 当前 / 上一行 / 下一行歌词预览

    private var lyricsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let lyrics = lyricsEngine.currentLyrics, !lyrics.isEmpty {
                // 用 lastPlaybackTime 取上下文(我们没有直接暴露,通过 Lyrics 自己算)
                // 这里直接显示当前行 + 下一行
                if let idx = lyricsEngine.currentLineIndex {
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
                    if idx + 1 < lyrics.lines.count {
                        Text(lyrics[idx + 1].content)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("未到第一句")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("暂无歌词")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: 偏移调节

    private var offsetControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("歌词偏移: \(formattedDelay)")
                .font(.subheadline)
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

    // MARK: 开关

    private var toggleControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("桌面歌词", isOn: $desktopEnabled)
                .onChange(of: desktopEnabled) { _, newValue in
                    AppSettings.desktopLyricsEnabled = newValue
                    NotificationCenter.default.post(
                        name: .desktopLyricsEnabledChanged, object: newValue
                    )
                }
            Toggle("启动时自动打开", isOn: $autoOpen)
                .onChange(of: autoOpen) { _, newValue in
                    AppSettings.desktopLyricsAutoOpen = newValue
                }
            Toggle("鼠标穿透(歌词不阻挡点击)", isOn: $clickThrough)
                .onChange(of: clickThrough) { _, newValue in
                    AppSettings.clickThrough = newValue
                    NotificationCenter.default.post(
                        name: .desktopLyricsClickThroughChanged, object: newValue
                    )
                }
            HStack {
                Spacer()
                Button("退出") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
    }
}

// MARK: - 通知名

extension Notification.Name {
    static let desktopLyricsEnabledChanged = Notification.Name("NiceLyricsX.desktopLyricsEnabledChanged")
    static let desktopLyricsClickThroughChanged = Notification.Name("NiceLyricsX.desktopLyricsClickThroughChanged")
    static let desktopLyricsPositionChanged = Notification.Name("NiceLyricsX.desktopLyricsPositionChanged")
}