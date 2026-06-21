# Changelog

## v0.1.0 (2026-06-21) — 测试版

首个公开测试版本。功能基本跑通,但**仍处于早期阶段**,可能有尚未发现的问题。

> ⚠️ **不要在生产环境依赖这个版本**。遇到 bug 欢迎在 [Issues](../../issues) 反馈,带 stderr 日志和复现步骤最好。

### 这个版本能做什么
- 菜单栏常驻,无 Dock 图标
- Apple Music / iTunes 当前曲目实时读取(AppleScript)
- LRCLIB 在线搜索 + 本地缓存
- 网易云音乐 fallback(LRCLIB 找不到中文/抖音/翻唱时)
- 桌面悬浮歌词窗口(无边框、毛玻璃、可拖动、可穿透)
- 歌词时间偏移 ±10s 微调
- LRC / LRCX 格式 + 行内翻译解析

### 已知问题 / 限制
- macOS 16+ only
- 不支持逐字卡拉 OK 效果
- 不支持 Spotify / Vox 等第三方播放器(只接 Apple Music / iTunes)
- macOS 26 上 MediaRemote 私有 framework 异步 callback 有 SIGSEGV,
  暂时走 AppleScript 路径(MediaRemote 类型与调用代码保留,等
  Apple 稳定接口后可恢复)
- 菜单栏 TCC 自动化权限是**第一次启动时**弹,误点拒绝要去
  系统设置 → 隐私与安全性 → 自动化 里手动开
- 歌词缓存路径 `~/Library/Application Support/NiceLyricsX/lyrics/`

### 技术栈
- Swift 6 + Swift 6.3 严格并发
- SwiftUI + AppKit 混合
- async/await 全异步
- 41 个单元测试,`swift test` 全绿

### 计划
- 1.0 之前会先到 0.2 / 0.3,主要看 Issues 反馈
- 待修:MediaRemote 异步 callback 在 macOS 26 上崩溃(目前 workaround
  是直接禁用 MediaRemote 走 AppleScript)
- 待加:快捷键(全局切换桌面歌词显隐)、自启动(Language & Region
  启动项 / LaunchAgent)

