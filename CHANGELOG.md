# Changelog

## v1.0.0 (2026-06-21)

首个 macOS 菜单栏歌词应用正式版。

### 特性
- 菜单栏常驻,无 Dock 图标
- Apple Music / iTunes 当前曲目实时读取(AppleScript)
- LRCLIB 在线搜索 + 本地缓存
- 网易云音乐 fallback(LRCLIB 找不到中文/抖音/翻唱时)
- 桌面悬浮歌词窗口(无边框、毛玻璃、可拖动、可穿透)
- 歌词时间偏移 ±10s 微调
- 时间戳 + 内嵌翻译解析
- LRC / LRCX 格式支持

### 技术栈
- Swift 6 + Swift 6.3 严格并发
- SwiftUI + AppKit 混合
- 异步 async/await,无回调地狱
- 41 个单元测试
- SPM 构建 + Xcode 工程构建

### 已知限制
- macOS 16+ only
- 不支持逐字卡拉 OK 效果
- 不支持 Spotify / Vox 等第三方播放器
- 歌词缓存路径 `~/Library/Application Support/NiceLyricsX/lyrics/`
- macOS 26 上 MediaRemote 私有 framework 走不通,走 AppleScript fallback
  (LyricsService 不受影响,网络歌词照常工作)
