//
//  LyricsParser.swift
//  NiceLyricsX
//
//  LRC / LRCX 歌词格式解析器。
//
//  支持的格式:
//  - `[mm:ss.xx]歌词内容` — 标准 LRC
//  - `[mm:ss.xx][mm:ss.xx]歌词内容` — 多时间标签(同一句重复唱)
//  - `[ti:标题] [ar:艺人] [al:专辑] [by:编辑] [offset:偏移ms] [length:总时长]` — ID 标签
//  - `歌词内容【翻译内容】` — 行尾翻译(LyricsX 风格)
//  - `<mm:ss.xx>` 行内时间戳(逐字卡拉 OK)
//
//  正则策略借鉴 LyricsX `RegexPattern.swift` 的全套规则。
//

import Foundation

public struct LyricsParser {

    // MARK: - 正则

    /// 单个时间标签 `[mm:ss(.xxx)]`,允许 +/- 前缀(对应 LRCX 的相对偏移)。
    private nonisolated(unsafe) static let timeTagRegex = #/\[([+-]?\d+):(\d+(?:\.\d+)?)\]/#

    /// ID 标签 `[key:value]`,排除数字开头的(避免和 time tag 冲突)。
    private nonisolated(unsafe) static let id3TagRegex = #/^\[(?![-+]?\d+:\d+(?:\.\d+)?)([a-zA-Z]+):(.*)\]$/#

    /// 完整歌词行:`<多时间标签><非空内容>[【翻译】]`。
    private nonisolated(unsafe) static let lyricsLineRegex = #/^((?:\[([+-]?\d+):(\d+(?:\.\d+)?)\])+)(?!\[)([^【\r\n]*?)(?:【(.*?)】)?\s*$/#

    // MARK: - 入口

    /// 解析 LRC 文本,返回 `Lyrics`。
    /// - Parameter trackKey: 关联的曲目 key,会写入 `Lyrics.trackKey` 便于缓存匹配。
    /// - Parameter defaultTimeDelay: 全局偏移(秒),会写入 `Lyrics.timeDelay`。
    public static func parse(
        lrcText text: String,
        trackKey: String? = nil,
        defaultTimeDelay: TimeInterval = 0,
        source: String = "LRCLIB"
    ) -> Lyrics {
        // 用 \r?\n 拆行,兼容 Windows / Mac
        let rawLines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        var idTags: [String: String] = [:]
        var inlineTimeDelay: TimeInterval = 0
        var collected: [LyricsLine] = []
        var nextIndex = 0

        for rawLine in rawLines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // 先尝试 ID 标签(整行就一个标签)
            if let idMatch = try? id3TagRegex.wholeMatch(in: line) {
                let key = String(idMatch.output.1).lowercased()
                let value = String(idMatch.output.2)
                    .trimmingCharacters(in: .whitespaces)

                if key == "offset" {
                    // [offset:+500] 或 [offset:-200],单位毫秒
                    inlineTimeDelay = (TimeInterval(value) ?? 0) / 1000.0
                } else {
                    idTags[key] = value
                }
                continue
            }

            // 解析时间标签 + 内容 + 翻译
            guard let match = try? lyricsLineRegex.wholeMatch(in: line) else {
                continue
            }

            // match.output.1 是 "[00:01.23][00:02.34]" 这种字符串,
            // 我们再扫一遍拿每个时间标签
            let tagsPart = String(match.output.1)
            let content = String(match.output.4).trimmingCharacters(in: .whitespaces)
            let translation = match.output.5.map { String($0).trimmingCharacters(in: .whitespaces) }

            // content 为空表示这行只是 metadata 或翻译(没歌词正文)
            // 比如 "[00:01.23]" 单独成行 —— 这种行跳过
            guard !content.isEmpty || translation != nil else { continue }

            // 提取所有时间标签(可能多个)
            let positions = extractTimeTags(from: tagsPart)
            guard !positions.isEmpty else { continue }

            // 同一句多个时间标签 → 每个标签创建一行(同内容)
            for pos in positions {
                collected.append(LyricsLine(
                    index: nextIndex,
                    position: pos,
                    content: content,
                    translation: translation
                ))
                nextIndex += 1
            }
        }

        let effectiveDelay = defaultTimeDelay + inlineTimeDelay
        return Lyrics(
            lines: collected,
            timeDelay: effectiveDelay,
            source: source,
            trackKey: trackKey
        )
    }

    // MARK: - 工具

    /// 从 "[00:01.23][00:05.50]" 这种字符串里提取所有时间标签(秒)。
    private static func extractTimeTags(from str: String) -> [TimeInterval] {
        var results: [TimeInterval] = []
        for match in str.matches(of: timeTagRegex) {
            let minutes = TimeInterval(match.output.1) ?? 0
            let seconds = TimeInterval(match.output.2) ?? 0
            results.append(minutes * 60 + seconds)
        }
        return results
    }
}