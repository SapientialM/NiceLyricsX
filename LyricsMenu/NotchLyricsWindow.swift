//
//  NotchLyricsWindow.swift
//  NiceLyricsX
//
//  刘海面板 —— 把当前歌词 + 播放控制投到 MacBook 刘海的"下一格"。
//
//  为什么放在菜单栏下方而不是刘海两翼:
//  刘海左右那两条"翼"就是菜单栏本体(左边是 app 菜单,右边是状态栏图标 + 时钟),
//  把常驻内容画在那里会和菜单栏项正面打架。所以这个窗口挂在**菜单栏下沿、
//  水平居中于刘海**的位置 —— 视觉上像是从刘海往下长出来的一块,但完全不侵占
//  菜单栏。物理刘海本身是摄像头黑边,画不了东西,所以"岛"的延伸只能是向下。
//
//  三档展示状态:
//  - `.hidden` 收起(内容被裁到菜单栏上方,视觉上"缩回刘海")
//  - `.bar`    细条:当前行 + 下一句
//  - `.panel`  悬停展开:封面 + 曲目信息 + 大字歌词 + 进度条(可拖) + 切歌控制
//
//  窗口本身:
//  - 画布固定成面板大小,内容靠 SwiftUI 在画布内做高度/位移动画
//  - `canBecomeKey = false` —— 这样按钮**能收到点击**但窗口永远不会抢键盘焦点,
//    也不会把当前 app 切走(点一下刘海不该让你正在打字的编辑器失焦)
//  - `ignoresMouseEvents` 只在 `.panel` 时为 false:其它状态鼠标事件全部穿透
//  - 悬停检测用 `NSEvent.mouseLocation` 轮询(鼠标事件不需要辅助功能权限)
//

import SwiftUI
import AppKit
import Combine

// MARK: - 展示状态

enum NotchPresentation: Equatable {
    case hidden
    case bar
    case panel
}

/// 尺寸常量。
enum NotchMetrics {
    static let barHeight: CGFloat = 52
    static let panelHeight: CGFloat = 212
    static let barCornerRadius: CGFloat = 18
    static let panelCornerRadius: CGFloat = 22
}

// MARK: - 可观察状态

@MainActor
final class NotchLyricsState: ObservableObject {
    @Published var presentation: NotchPresentation = .hidden
    @Published var width: CGFloat = 560
    @Published var hasPhysicalNotch = false

    var contentHeight: CGFloat {
        presentation == .panel ? NotchMetrics.panelHeight : NotchMetrics.barHeight
    }

    var cornerRadius: CGFloat {
        presentation == .panel ? NotchMetrics.panelCornerRadius : NotchMetrics.barCornerRadius
    }

    var isExpanded: Bool { presentation == .panel }
}

// MARK: - 窗口

/// 刻意不让它能变成 key window。
///
/// 这是个反直觉但关键的点:窗口**能**成为 key 时,第一次点击会被系统吃掉
/// (用来"激活"窗口),按钮要点两下才生效;而一个**永远不能**成为 key 的窗口,
/// 鼠标事件会直接送到 SwiftUI 的按钮上 —— 既一击必中,又不会抢走键盘焦点。
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Window Controller

@MainActor
final class NotchLyricsWindowController {

    private let lyricsEngine: LyricsEngine
    private let settings: AppSettingsStore
    let state = NotchLyricsState()

    private var panel: NotchPanel?
    private var geometry: NotchGeometry?
    private var cancellables: Set<AnyCancellable> = []
    private var hoverTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?

    /// peek 模式下细条停留多久后收回。
    private let peekDuration: TimeInterval = 3.5
    /// 收回动画时长(动画结束后再把窗口 orderOut)。
    private let collapseAnimation: TimeInterval = 0.45
    /// 悬停轮询间隔。
    private let hoverInterval: UInt64 = 150_000_000

    /// 鼠标当前是否停在刘海/面板上 —— 只在状态翻转时动作,
    /// 否则每 150ms 重排一次收起任务,永远也收不回去。
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
        state.width = geometry.barWidth()

        // 画布始终按面板高度给足 —— 展开/收起只在 SwiftUI 内部做动画,
        // 窗口 frame 不动(动 frame 会和 SwiftUI 动画打架,还会闪)
        let frame = geometry.barFrame(width: state.width, height: NotchMetrics.panelHeight)
        if let panel {
            panel.setFrame(frame, display: true)
        } else {
            panel = makePanel(frame: frame)
        }
        FileHandle.standardError.write(Data(
            ("[Notch] 刘海=\(Int(geometry.notchWidth))x\(Int(geometry.notchHeight)) " +
             "菜单栏高=\(Int(geometry.menuBarHeight)) 物理刘海=\(geometry.hasPhysicalNotch) " +
             "画布=\(Int(frame.width))x\(Int(frame.height))@(\(Int(frame.minX)),\(Int(frame.minY))) " +
             "level=\(panel?.level.rawValue ?? -1)\n").utf8
        ))
        applyMode()
    }

    private func makePanel(frame: CGRect) -> NotchPanel {
        let panel = NotchPanel(
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
        // 但不能用私有 CGSSpace 那种"把 level 拉满"的做法。
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // 初始是收起的,鼠标事件全部穿透
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
            setPresentation(.hidden)
            panel?.orderOut(nil)

        case .peek:
            if isHovering {
                setPresentation(.panel)
            } else if state.presentation == .panel {
                setPresentation(.bar)
                scheduleCollapse()
            } else if state.presentation != .hidden {
                scheduleCollapse()
            }

        case .always:
            collapseTask?.cancel()
            collapseTask = nil
            setPresentation(isHovering ? .panel : .bar)
        }
    }

    /// 切歌时的冒头。
    private func peek() {
        guard settings.notchLyricsMode == .peek, !isHovering else { return }
        setPresentation(.bar)
        scheduleCollapse()
    }

    private func setPresentation(_ next: NotchPresentation) {
        if next != .hidden {
            panel?.orderFrontRegardless()
        }
        state.presentation = next
        // 只有展开面板才需要鼠标事件(要能点按钮、拖进度条)
        panel?.ignoresMouseEvents = (next != .panel)
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
        guard settings.notchLyricsMode == .peek, !isHovering else { return }
        setPresentation(.hidden)
        // 等收回动画播完再把窗口撤掉,不然会看到内容"啪"一下消失
        try? await Task.sleep(nanoseconds: UInt64(collapseAnimation * 1_000_000_000))
        guard !Task.isCancelled, !isHovering,
              state.presentation == .hidden,
              settings.notchLyricsMode == .peek else { return }
        panel?.orderOut(nil)
    }

    // MARK: 悬停

    private func startHoverTracking() {
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.hoverInterval ?? 150_000_000)
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
        // 热区要用**当前**高度:展开后热区必须跟着变高,
        // 否则鼠标一往面板里移就被判定成"离开",面板立刻收回去
        let region = geometry.hoverRegion(
            width: state.width,
            height: state.presentation == .panel ? NotchMetrics.panelHeight : NotchMetrics.barHeight
        )
        let inside = region.contains(NSEvent.mouseLocation)
        guard inside != isHovering else { return }
        isHovering = inside

        if inside {
            collapseTask?.cancel()
            collapseTask = nil
            setPresentation(.panel)
        } else {
            // 离开 → 先缩回细条,再按模式决定是否继续收起
            setPresentation(.bar)
            if settings.notchLyricsMode == .peek {
                scheduleCollapse()
            }
        }
    }
}

// MARK: - SwiftUI 内容

struct NotchLyricsView: View {

    @ObservedObject var lyricsEngine: LyricsEngine
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var state: NotchLyricsState

    @StateObject private var artwork = ArtworkStore()

    var body: some View {
        ZStack(alignment: .top) {
            card
        }
        .frame(width: state.width, height: NotchMetrics.panelHeight, alignment: .top)
        .clipped()
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: state.presentation)
        .onAppear { artwork.load(for: lyricsEngine.currentTrack) }
        .onChange(of: lyricsEngine.currentTrack) { _, track in
            artwork.load(for: track)
        }
    }

    private var card: some View {
        content
            .frame(width: state.width, height: state.contentHeight, alignment: .top)
            .background(
                // 上沿贴住菜单栏,所以只圆下面两个角 —— 看起来像从刘海长出来的
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: state.cornerRadius,
                    bottomTrailingRadius: state.cornerRadius,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                .fill(Color.black.opacity(0.94))
            )
            .offset(y: state.presentation == .hidden ? -(state.contentHeight + 4) : 0)
            .opacity(state.presentation == .hidden ? 0 : 1)
    }

    @ViewBuilder
    private var content: some View {
        if state.presentation == .panel {
            panelContent
        } else {
            barContent
        }
    }

    // MARK: 细条

    private var barContent: some View {
        HStack(spacing: 10) {
            Image(systemName: lyricsEngine.isPlaying ? "music.note" : "pause.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(currentLineText ?? statusText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let secondary = secondaryLineText {
                    Text(secondary)
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

    // MARK: 展开面板

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            trackRow
            lyricsBlock
            PlaybackControlsRow(
                lyricsEngine: lyricsEngine,
                tint: .white,
                buttonBackground: Color.white.opacity(0.14),
                trackTint: Color.white.opacity(0.16),
                labelColor: Color.white.opacity(0.45)
            )
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var trackRow: some View {
        HStack(spacing: 12) {
            artworkThumbnail

            VStack(alignment: .leading, spacing: 2) {
                Text(lyricsEngine.currentTrack.title.isEmpty ? "没有正在播放的曲目" : lyricsEngine.currentTrack.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !artistAlbumText.isEmpty {
                    Text(artistAlbumText)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
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

    @ViewBuilder
    private var artworkThumbnail: some View {
        Group {
            if let url = artwork.url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: artworkPlaceholder
                    }
                }
            } else {
                artworkPlaceholder
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var artworkPlaceholder: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.1))
            Image(systemName: "music.note")
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private var lyricsBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(currentLineText ?? statusText)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let secondary = secondaryLineText {
                Text(secondary)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    // MARK: 文案

    private var currentLineText: String? {
        guard let lyrics = lyricsEngine.currentLyrics,
              let index = lyricsEngine.currentLineIndex,
              index < lyrics.lines.count else { return nil }
        return lyrics.lines[index].content
    }

    /// 第二行:优先显示当前行的翻译,没有翻译就显示下一句。
    private var secondaryLineText: String? {
        guard let lyrics = lyricsEngine.currentLyrics,
              let index = lyricsEngine.currentLineIndex,
              index < lyrics.lines.count else { return nil }
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

// MARK: - 进度条(可拖)

/// 面板里的进度条。自己画而不是用 `Slider` —— 默认 Slider 在纯黑面板上
/// 白底样式很突兀,而且这里要的是"细线 + 拖动跳转"的手感。
private struct NotchProgressBar: View {

    let position: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @State private var dragFraction: Double?

    private var safeDuration: TimeInterval {
        duration > 0 ? duration : 0
    }

    private var fraction: Double {
        if let dragFraction { return dragFraction }
        guard safeDuration > 0 else { return 0 }
        return min(max(position / safeDuration, 0), 1)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.timeLabel(elapsed))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 34, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16))
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: max(0, geo.size.width * fraction))
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard safeDuration > 0 else { return }
                            dragFraction = min(max(value.location.x / geo.size.width, 0), 1)
                        }
                        .onEnded { _ in
                            guard let target = dragFraction, safeDuration > 0 else { return }
                            onSeek(target * safeDuration)
                            // 放手后先保持拖到的位置,等服务端回读再交还控制权,
                            // 否则进度条会先弹回旧位置再跳过去
                            Task {
                                try? await Task.sleep(nanoseconds: 700_000_000)
                                dragFraction = nil
                            }
                        }
                )
            }
            .frame(height: 12)

            Text(Self.timeLabel(safeDuration))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var elapsed: TimeInterval {
        if let dragFraction, safeDuration > 0 { return dragFraction * safeDuration }
        return min(max(position, 0), safeDuration > 0 ? safeDuration : position)
    }

    static func timeLabel(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
