//
//  NotchLyricsWindow.swift
//  NiceLyricsX
//
//  刘海歌词 —— 把当前歌词投到 MacBook 刘海的"下一格"。
//
//  为什么放在菜单栏下方而不是刘海两翼:
//  刘海左右那两条"翼"就是菜单栏本体(左边是 app 菜单,右边是状态栏图标 + 时钟),
//  把常驻内容画在那里会和菜单栏项正面打架。所以这个窗口挂在**菜单栏下沿、
//  水平居中于刘海**的位置 —— 视觉上像是从刘海往下长出来的一块,但完全不侵占
//  菜单栏。物理刘海本身是摄像头黑边,画不了东西,所以"岛"的延伸只能是向下。
//
//  两种模式:
//  - `.peek`   切歌时冒头,几秒后收回刘海;鼠标移到刘海/歌词条上会保持展开
//  - `.always` 常驻
//
//  窗口本身是纯展示:`ignoresMouseEvents = true`,不抢焦点、不拦点击;
//  悬停检测用 `NSEvent.mouseLocation` 轮询(鼠标事件不需要辅助功能权限)。
//

import SwiftUI
import AppKit
import Combine

// MARK: - 可观察状态

@MainActor
final class NotchLyricsState: ObservableObject {
    /// 是否展开(收起时内容被裁到菜单栏上方,视觉上"缩回刘海")。
    @Published var expanded = false
    @Published var barWidth: CGFloat = 560
    @Published var barHeight: CGFloat = 52
    @Published var hasPhysicalNotch = false
}

// MARK: - Window Controller

@MainActor
final class NotchLyricsWindowController {

    private let lyricsEngine: LyricsEngine
    private let settings: AppSettingsStore
    let state = NotchLyricsState()

    private var panel: NSPanel?
    private var geometry: NotchGeometry?
    private var cancellables: Set<AnyCancellable> = []
    private var hoverTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?

    /// peek 模式下展开多久后自动收回。
    private let peekDuration: TimeInterval = 3.5
    /// 收回动画时长(动画结束后再把窗口 orderOut)。
    private let collapseAnimation: TimeInterval = 0.45

    /// 鼠标当前是否停在刘海/歌词条上 —— 只在状态翻转时动作,
    /// 否则每 0.2 秒重排一次收起任务,永远也收不回去。
    private var isHovering = false

    init(lyricsEngine: LyricsEngine, settings: AppSettingsStore) {
        self.lyricsEngine = lyricsEngine
        self.settings = settings
    }

    // MARK: 生命周期

    func start() {
        rebuildForCurrentScreen()
        observe()
        startHoverTracking()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildForCurrentScreen() }
        }
    }

    func teardown() {
        hoverTask?.cancel()
        hoverTask = nil
        collapseTask?.cancel()
        collapseTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: 屏幕 / 面板

    private func rebuildForCurrentScreen() {
        guard let geometry = NotchGeometry.current() else { return }
        self.geometry = geometry

        state.hasPhysicalNotch = geometry.hasPhysicalNotch
        state.barWidth = geometry.barWidth()
        state.barHeight = 52

        let frame = geometry.barFrame(width: state.barWidth, height: state.barHeight)
        if let panel {
            panel.setFrame(frame, display: true)
        } else {
            panel = makePanel(frame: frame)
        }
        FileHandle.standardError.write(Data(
            ("[NotchLyrics] 刘海=\(Int(geometry.notchWidth))x\(Int(geometry.notchHeight)) " +
             "菜单栏高=\(Int(geometry.menuBarHeight)) 物理刘海=\(geometry.hasPhysicalNotch) " +
             "条=\(Int(frame.width))x\(Int(frame.height))@(\(Int(frame.minX)),\(Int(frame.minY))) " +
             "level=\(panel?.level.rawValue ?? -1)\n").utf8
        ))
        applyMode()
    }

    private func makePanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // 菜单栏本身是 .mainMenu(24),+3 就能画在它上面;
        // 但不能用私有 CGSSpace 那种"拉满 level"的做法。
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // 纯展示:不接收任何鼠标事件,菜单栏照常可点
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(
            rootView: NotchLyricsView(
                lyricsEngine: lyricsEngine,
                settings: settings,
                state: state
            )
        )
        return panel
    }

    // MARK: 模式

    private func observe() {
        settings.$notchLyricsMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyMode() }
            .store(in: &cancellables)

        // 切歌 → peek(只在歌名真正变化时触发,进度更新不触发)
        lyricsEngine.$currentTrack
            .receive(on: RunLoop.main)
            .map(\.title)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] title in
                guard let self, !title.isEmpty else { return }
                self.peek()
            }
            .store(in: &cancellables)
    }

    private func applyMode() {
        switch settings.notchLyricsMode {
        case .off:
            collapseTask?.cancel()
            collapseTask = nil
            state.expanded = false
            panel?.orderOut(nil)

        case .peek:
            // 进入 peek 模式时不立刻弹,等下一次切歌(或鼠标移到刘海)
            if state.expanded { scheduleCollapse() }

        case .always:
            collapseTask?.cancel()
            collapseTask = nil
            show()
            state.expanded = true
        }
    }

    /// 切歌时的冒头。
    private func peek() {
        guard settings.notchLyricsMode == .peek else { return }
        show()
        state.expanded = true
        scheduleCollapse()
    }

    private func show() {
        guard settings.notchLyricsMode != .off, let panel else { return }
        panel.orderFrontRegardless()
    }

    private func scheduleCollapse(after delay: TimeInterval? = nil) {
        collapseTask?.cancel()
        guard settings.notchLyricsMode == .peek else { return }

        let wait = delay ?? peekDuration
        collapseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.collapseIfIdle()
        }
    }

    private func collapseIfIdle() async {
        guard settings.notchLyricsMode == .peek else { return }
        guard !isHovering else { return }   // 鼠标还在上面,不收

        state.expanded = false
        // 等收回动画播完再把窗口撤掉,不然会看到内容"啪"一下消失
        try? await Task.sleep(nanoseconds: UInt64(collapseAnimation * 1_000_000_000))
        guard !Task.isCancelled, !state.expanded, !isHovering,
              settings.notchLyricsMode == .peek else { return }
        panel?.orderOut(nil)
    }

    // MARK: 悬停

    private func startHoverTracking() {
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, !Task.isCancelled else { return }
                self.pollHover()
            }
        }
    }

    private func pollHover() {
        guard settings.notchLyricsMode != .off, let geometry else {
            isHovering = false
            return
        }
        let region = geometry.hoverRegion(
            barWidth: state.barWidth,
            barHeight: state.barHeight
        )
        let inside = region.contains(NSEvent.mouseLocation)
        guard inside != isHovering else { return }
        isHovering = inside

        if inside {
            // 鼠标贴到刘海/歌词条上 → 展开并保持
            collapseTask?.cancel()
            collapseTask = nil
            show()
            state.expanded = true
        } else if settings.notchLyricsMode == .peek {
            scheduleCollapse()
        }
    }
}

// MARK: - SwiftUI 内容

struct NotchLyricsView: View {

    @ObservedObject var lyricsEngine: LyricsEngine
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var state: NotchLyricsState

    var body: some View {
        ZStack(alignment: .top) {
            bar
                .frame(width: state.barWidth, height: state.barHeight)
                .background(
                    // 上沿贴住菜单栏,所以只圆下面两个角 —— 看起来像从刘海长出来的
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 18,
                        bottomTrailingRadius: 18,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                    .fill(Color.black.opacity(0.93))
                )
                .offset(y: state.expanded ? 0 : -(state.barHeight + 2))
                .opacity(state.expanded ? 1 : 0)
        }
        .frame(width: state.barWidth, height: state.barHeight, alignment: .top)
        .clipped()
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: state.expanded)
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Image(systemName: lyricsEngine.isPlaying ? "music.note" : "pause.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(primaryText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let secondaryText {
                    Text(secondaryText)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: 文案

    private var primaryText: String {
        guard let lyrics = lyricsEngine.currentLyrics,
              let index = lyricsEngine.currentLineIndex,
              index < lyrics.lines.count else {
            return statusText
        }
        return lyrics.lines[index].content
    }

    /// 第二行:优先显示当前行的翻译,没有翻译就显示下一句。
    private var secondaryText: String? {
        guard let lyrics = lyricsEngine.currentLyrics,
              let index = lyricsEngine.currentLineIndex,
              index < lyrics.lines.count else {
            return nil
        }
        if settings.showTranslation,
           let translation = lyrics.lines[index].translation,
           !translation.isEmpty {
            return translation
        }
        guard index + 1 < lyrics.lines.count else { return nil }
        let next = lyrics.lines[index + 1].content
        return next.isEmpty ? nil : next
    }

    private var statusText: String {
        switch lyricsEngine.status {
        case .searching: return "正在搜索歌词…"
        case .notFound: return "未找到歌词"
        case .failed(let message): return message
        case .idle: return lyricsEngine.currentTrack.title.isEmpty ? "等待播放…" : "已停止"
        case .loaded: return "即将开始…"
        }
    }
}
