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
//  - 设置变化全部走 `AppSettingsStore` 的 Combine 订阅,不再用 NotificationCenter
//    (旧实现里字号 / 不透明度改了窗口既不重绘也不改尺寸)
//

import SwiftUI
import AppKit
import Combine

// MARK: - Window Controller

@MainActor
final class DesktopLyricsWindowController: NSObject, NSWindowDelegate {

    private let lyricsEngine: LyricsEngine
    private let settings: AppSettingsStore

    private var panel: NSPanel!
    private var hostingView: NSHostingView<DesktopLyricsView>!
    private var cancellables: Set<AnyCancellable> = []
    private var dragStartLocation: NSPoint?
    private var localEventMonitor: Any?

    init(lyricsEngine: LyricsEngine, settings: AppSettingsStore) {
        self.lyricsEngine = lyricsEngine
        self.settings = settings
        super.init()
        setupPanel()
        observeSettings()
    }

    deinit {
        // deinit 在 actor 外,只做最少清理;窗口/监视器的正常拆除走 teardown()
    }

    // MARK: - Public

    func show() {
        if !settings.desktopLyricsEnabled { return }
        applyPanelSize()
        positionPanelByStoredFactor()
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }

    func toggle() {
        if panel.isVisible { close() } else { show() }
    }

    /// 把窗口挪回存储的位置因子处(菜单栏「重置位置」用)。
    func resetPosition() {
        AppSettings.desktopLyricsXFactor = 0.5
        AppSettings.desktopLyricsYFactor = 0.85
        applyPanelSize()
        positionPanelByStoredFactor()
        saveCurrentPositionFactor()
    }

    /// 应用退出时拆除事件监视器(本地监视器不注销会一直挂在 app 上)。
    func teardown() {
        removeLocalEventMonitor()
    }

    // MARK: - Setup

    private func setupPanel() {
        let initialSize = Self.panelSize(
            fontSize: settings.fontSize,
            showTranslation: settings.showTranslation
        )

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

        // 必须先把 self.panel 赋值,再调 positionPanelByStoredFactor。
        // 后面 setFrameOrigin 会触发 windowDidMove → saveCurrentPositionFactor,
        // 这两条路径都依赖 self.panel!。如果顺序反了,会 Swift runtime
        // trap: "found nil while implicitly unwrapping an Optional value"
        self.panel = panel

        // 位置初始化
        positionPanelByStoredFactor()

        let host = NSHostingView(
            rootView: DesktopLyricsView(lyricsEngine: lyricsEngine, settings: settings)
        )
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(origin: .zero, size: initialSize)
        panel.contentView = host

        self.hostingView = host

        installDragHandlers()
    }

    /// 字号 / 翻译开关变化时,窗口要跟着变高,否则大字会被裁掉。
    private func observeSettings() {
        settings.$clickThrough
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.panel.ignoresMouseEvents = value
            }
            .store(in: &cancellables)

        settings.$desktopLyricsEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.show() } else { self.close() }
            }
            .store(in: &cancellables)

        settings.$fontSize
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyPanelSize()
            }
            .store(in: &cancellables)

        settings.$showTranslation
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyPanelSize()
            }
            .store(in: &cancellables)
    }

    // MARK: - Size

    /// 根据字号 + 是否显示翻译算出窗口尺寸。
    /// 内容最多是:上一行(0.7x)+ 当前行(最多 2 行 = 2x)+ 翻译(0.6x)+ 下一行(0.7x)。
    static func panelSize(fontSize: Double, showTranslation: Bool) -> NSSize {
        let width: CGFloat = 720
        let factor: Double = showTranslation ? 4.4 : 3.6
        let height = max(140, min(440, fontSize * factor + 40))
        return NSSize(width: width, height: CGFloat(height))
    }

    private func applyPanelSize() {
        guard panel != nil else { return }
        let newSize = Self.panelSize(
            fontSize: settings.fontSize,
            showTranslation: settings.showTranslation
        )
        guard panel.frame.size != newSize else { return }

        // 以窗口中心为锚点缩放,避免窗口从左上角"长出去"
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        var frame = panel.frame
        frame.size = newSize
        frame.origin = NSPoint(
            x: center.x - newSize.width / 2,
            y: center.y - newSize.height / 2
        )
        panel.setFrame(frame, display: true, animate: false)
    }

    // MARK: - Position

    /// 用存储的 [0,1] 比例因子把 panel 放到对应的屏幕坐标。
    /// 前提:`self.panel` 已经被赋值(见 `setupPanel` 顶部)—— 否则
    /// `self.panel!.frame` 会触发 Swift runtime trap。
    private func positionPanelByStoredFactor() {
        let x = AppSettings.desktopLyricsXFactor
        let y = AppSettings.desktopLyricsYFactor
        let size = panel.frame.size
        let resolved = NSScreen.pointFromFactor(xFactor: x, yFactor: y, size: size)
        // AppKit 启动早期 NSScreen.screens 可能为空(LSUIElement accessory app
        // 的 applicationDidFinishLaunching 触发期),此时退化到 origin = 0,0,
        // 让 NSWindow 自己后续在 NSApplicationDidFinishLaunchingNotification
        // 之后再由 windowDidMove 矫正。
        guard resolved.target != nil else {
            panel.setFrameOrigin(.zero)
            return
        }
        panel.setFrameOrigin(resolved.point)
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
        guard localEventMonitor == nil else { return }
        // 用本地事件监视器监听鼠标拖动
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            guard event.window === panel else { return event }

            switch event.type {
            case .leftMouseDown:
                self.dragStartLocation = event.locationInWindow
            case .leftMouseDragged:
                guard let start = self.dragStartLocation else { return event }
                let current = event.locationInWindow
                let dx = current.x - start.x
                let dy = current.y - start.y
                var origin = panel.frame.origin
                origin.x += dx
                origin.y += dy
                panel.setFrameOrigin(origin)
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

    private func removeLocalEventMonitor() {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
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
    @ObservedObject var settings: AppSettingsStore

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
                .opacity(settings.opacity)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func lyricStack(lyrics: Lyrics) -> some View {
        if let idx = lyricsEngine.currentLineIndex, idx < lyrics.lines.count {
            // 上 1 行
            if idx > 0 {
                Text(lyrics[idx - 1].content)
                    .font(.system(size: settings.fontSize * 0.7))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineLimit(1)
                    .transition(.opacity)
            }

            // 当前行
            Text(lyrics[idx].content)
                .font(.system(size: settings.fontSize, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

            // 翻译(可选)
            if settings.showTranslation, let translation = lyrics[idx].translation, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: settings.fontSize * 0.6))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }

            // 下 1 行
            if idx + 1 < lyrics.lines.count {
                Text(lyrics[idx + 1].content)
                    .font(.system(size: settings.fontSize * 0.7))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineLimit(1)
                    .transition(.opacity)
            }
        } else if !lyrics.isEmpty {
            // 还没到第一句
            Text(lyrics[0].content)
                .font(.system(size: settings.fontSize * 0.8))
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
