//
//  PlaybackControls.swift
//  NiceLyricsX
//
//  播放控制的可复用组件 —— 刘海面板和菜单栏面板共用。
//
//  两个组件都刻意"自己画"而不是用 AppKit/SwiftUI 的默认控件:
//  - 刘海面板是纯黑背景,默认按钮/Slider 的浅色描边在上面很违和
//  - 需要一个精细的拖动跳转手感(细线 + 拖动 + 放手后等服务端回读)
//

import SwiftUI

// MARK: - 进度条

/// 可拖拽跳转的播放进度条。
struct PlaybackProgressBar: View {

    let position: TimeInterval
    let duration: TimeInterval
    var tint: Color = .primary
    var trackTint: Color = Color.secondary.opacity(0.25)
    var labelColor: Color = .secondary
    let onSeek: (TimeInterval) -> Void

    /// 拖动中的比例。非 nil 时优先于真实播放位置。
    @State private var dragFraction: Double?

    private var safeDuration: TimeInterval {
        duration.isFinite && duration > 0 ? duration : 0
    }

    private var fraction: Double {
        if let dragFraction { return dragFraction }
        guard safeDuration > 0 else { return 0 }
        return min(max(position / safeDuration, 0), 1)
    }

    /// 拖动中显示拖到的位置,否则显示真实位置(不知道总时长时至少显示已播秒数)。
    private var elapsed: TimeInterval {
        if let dragFraction, safeDuration > 0 { return dragFraction * safeDuration }
        if safeDuration > 0 { return min(max(position, 0), safeDuration) }
        return max(position, 0)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.timeLabel(elapsed))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(labelColor)
                .frame(width: 34, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(trackTint)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(0, geo.size.width * fraction))
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard safeDuration > 0, geo.size.width > 0 else { return }
                            dragFraction = min(max(value.location.x / geo.size.width, 0), 1)
                        }
                        .onEnded { _ in
                            guard let target = dragFraction, safeDuration > 0 else { return }
                            onSeek(target * safeDuration)
                            // 放手后先保持拖到的位置,等服务端回读再交还控制权;
                            // 否则进度条会先弹回旧位置再跳到新位置,看着像闪了一下
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
                .foregroundStyle(labelColor)
                .frame(width: 34, alignment: .trailing)
        }
        .opacity(safeDuration > 0 ? 1 : 0.5)
    }

    static func timeLabel(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 切歌按钮

/// ⏮ ⏯ ⏭
struct TransportControls: View {

    let isPlaying: Bool
    var tint: Color = .primary
    var buttonBackground: Color = Color.secondary.opacity(0.15)
    var buttonSize: CGFloat = 30
    let onPrevious: () -> Void
    let onTogglePlayPause: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            button("backward.fill", size: buttonSize, action: onPrevious)
            button(isPlaying ? "pause.fill" : "play.fill", size: buttonSize * 1.2, action: onTogglePlayPause)
            button("forward.fill", size: buttonSize, action: onNext)
        }
    }

    private func button(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(buttonBackground))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(helpText(for: symbol))
    }

    private func helpText(for symbol: String) -> String {
        switch symbol {
        case "backward.fill": return "上一首"
        case "forward.fill": return "下一首"
        default: return isPlaying ? "暂停" : "播放"
        }
    }
}

// MARK: - 组合:控制行 + 进度条

/// 切歌按钮 + 进度条。进度用 `TimelineView` 自己驱动重绘 ——
/// `LyricsEngine.playbackPosition` 是基于墙钟实时算的,不需要等轮询。
struct PlaybackControlsRow: View {

    let lyricsEngine: LyricsEngine
    var tint: Color = .primary
    var buttonBackground: Color = Color.secondary.opacity(0.15)
    var trackTint: Color = Color.secondary.opacity(0.25)
    var labelColor: Color = .secondary

    var body: some View {
        VStack(spacing: 10) {
            TransportControls(
                isPlaying: lyricsEngine.isPlaying,
                tint: tint,
                buttonBackground: buttonBackground,
                onPrevious: { lyricsEngine.perform(.previous) },
                onTogglePlayPause: { lyricsEngine.perform(.togglePlayPause) },
                onNext: { lyricsEngine.perform(.next) }
            )
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                PlaybackProgressBar(
                    position: lyricsEngine.playbackPosition,
                    duration: lyricsEngine.playbackDuration,
                    tint: tint,
                    trackTint: trackTint,
                    labelColor: labelColor,
                    onSeek: { lyricsEngine.perform(.seek(to: $0)) }
                )
            }
        }
    }
}
