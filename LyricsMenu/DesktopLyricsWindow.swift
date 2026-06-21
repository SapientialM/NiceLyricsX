//
//  DesktopLyricsWindow.swift
//  NiceLyricsX
//
//  桌面歌词悬浮窗口 —— 无边框、置顶、半透明、可拖动、可穿透。
//
//  设计要点(借鉴 LyricsX `KaraokeLyricsController` + 现代 SwiftUI):
//  - 用 `NSPanel` + SwiftUI `NSHostingView` 作为根视图(NSPanel 比 NSWindow 更适合 utility UI)
//  - `.borderless` + `.titled` 关闭 + `isOpaque = false` + `backgroundColor = .clear`
//  - `level = .floating` 浮在普通窗口之上;`.canJoinAllSpaces + .stationary` 跨 Space 跟随
//  - 拖动:自己处理 `mouseDown` / `mouseDragged`(参考 LyricsX 的 SnapKit 实现)
//  - 位置用 `[0,1]` 比例因子持久化(多屏切换不破相)
//  - 鼠标穿透:`ignoresMouseEvents` 直接生效(无内部交互需要)
//  - 内容用 SwiftUI `Canvas` 渲染,支持卡拉 OK 风格高亮
//

import SwiftUI
import AppKit
import Combine

// MARK: - Window Controller

@MainActor
final class DesktopLyricsWindowController: NSObject, NSWindowDelegate {

    private let lyricsEngine: LyricsEngine
    private var panel: NSPanel!
    private var hostingView: NSHostingView<DesktopLyricsView>!
    private var cancellables: Set<AnyCancellable> = []
    private var dragStartLocation: NSPoint?

    init(lyricsEngine: LyricsEngine) {
        self.lyricsEngine = lyricsEngine
        super.init()
        setupPanel()
        observeSettings()
    }

    deinit {
        // deinit 在 actor 外,只做最少清理
        // 实际关闭在 stop() / close() 里
    }

    // MARK: - Public

    func show() {
        if !AppSettings.desktopLyricsEnabled { return }
        positionPanelByStoredFactor()
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }

    func toggle() {
        if panel.isVisible { close() } else { show() }
    }

    // MARK: - Setup

    private func setupPanel() {
        let initialSize = NSSize(width: 720, height: 120)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )

        panel.title = "NiceLyricsX Desktop Lyrics"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = AppSettings.clickThrough
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self

        // 位置初始化
        positionPanelByStoredFactor()

        let host = NSHostingView(
            rootView: DesktopLyricsView(lyricsEngine: lyricsEngine)
        )
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(origin: .zero, size: initialSize)
        panel.contentView = host

        self.panel = panel
        self.hostingView = host

        // 监听设置变化
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleClickThroughChanged(_:)),
            name: .desktopLyricsClickThroughChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleEnabledChanged(_:)),
            name: .desktopLyricsEnabledChanged, object: nil
        )

        // 拖动监听
        installDragHandlers()
    }

    private func observeSettings() {
        // 引擎 currentLineIndex / currentLyrics 变化由 SwiftUI 内部订阅,这里不需要桥接
    }

    // MARK: - Position

    private func positionPanelByStoredFactor() {
        let x = AppSettings.desktopLyricsXFactor
        let y = AppSettings.desktopLyricsYFactor
        let size = panel.frame.size
        let point = NSScreen.pointFromFactor(xFactor: x, yFactor: y, size: size)
        panel.setFrameOrigin(point)
    }

    private func saveCurrentPositionFactor() {
        guard panel.screen != nil else { return }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        guard let factor = NSScreen.positionFactor(for: center) else { return }
        AppSettings.desktopLyricsXFactor = factor.x
        AppSettings.desktopLyricsYFactor = factor.y
    }

    // MARK: - Drag

    private func installDragHandlers() {
        // 用本地事件监视器监听鼠标拖动
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            guard event.window === self.panel else { return event }

            switch event.type {
            case .leftMouseDown:
                self.dragStartLocation = event.locationInWindow
            case .leftMouseDragged:
                guard let start = self.dragStartLocation else { return event }
                let current = event.locationInWindow
                let dx = current.x - start.x
                let dy = current.y - start.y
                var origin = self.panel.frame.origin
                origin.x += dx
                origin.y += dy
                self.panel.setFrameOrigin(origin)
                self.dragStartLocation = current  // 增量方式,避免漂移
            case .leftMouseUp:
                self.dragStartLocation = nil
                self.saveCurrentPositionFactor()
            default:
                break
            }
            return event
        }
    }

    // MARK: - Settings

    @objc private func handleClickThroughChanged(_ note: Notification) {
        let value = (note.object as? Bool) ?? AppSettings.clickThrough
        panel.ignoresMouseEvents = value
    }

    @objc private func handleEnabledChanged(_ note: Notification) {
        let value = (note.object as? Bool) ?? AppSettings.desktopLyricsEnabled
        if value {
            show()
        } else {
            close()
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        saveCurrentPositionFactor()
    }
}

// MARK: - SwiftUI Content

struct DesktopLyricsView: View {

    @ObservedObject var lyricsEngine: LyricsEngine

    var body: some View {
        ZStack {
            // 背景:全透明,允许点击穿透(但 NSPanel.ignoresMouseEvents 已经控制)
            Color.clear

            VStack(spacing: 8) {
                if let lyrics = lyricsEngine.currentLyrics, !lyrics.isEmpty {
                    lyricStack(lyrics: lyrics)
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .background(
            VisualEffectBackground()
                .opacity(AppSettings.desktopLyricsOpacity)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func lyricStack(lyrics: Lyrics) -> some View {
        if let idx = lyricsEngine.currentLineIndex {
            // 上 1 行
            if idx > 0 {
                Text(lyrics[idx - 1].content)
                    .font(.system(size: AppSettings.desktopLyricsFontSize * 0.7))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineLimit(1)
                    .transition(.opacity)
            }

            // 当前行
            Text(lyrics[idx].content)
                .font(.system(size: AppSettings.desktopLyricsFontSize, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

            // 下 1 行
            if idx + 1 < lyrics.lines.count {
                Text(lyrics[idx + 1].content)
                    .font(.system(size: AppSettings.desktopLyricsFontSize * 0.7))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineLimit(1)
                    .transition(.opacity)
            }
        } else if !lyrics.isEmpty {
            // 还没到第一句
            Text(lyrics[0].content)
                .font(.system(size: AppSettings.desktopLyricsFontSize * 0.8))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            switch lyricsEngine.status {
            case .searching:
                ProgressView()
                    .controlSize(.small)
                Text("正在搜索歌词…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .notFound:
                Image(systemName: "music.note.list")
                Text("未找到歌词")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle")
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
            default:
                Image(systemName: "music.note")
                Text("等待播放…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 背景视觉

/// 半透明背景 —— 用 NSVisualEffectView 包出 macOS 原生毛玻璃。
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material = .hudWindow
    let state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.state = state
        v.blendingMode = .behindWindow
        v.isEmphasized = true
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.state = state
    }
}