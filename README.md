# NiceLyricsX

一个现代的 macOS 菜单栏歌词应用,支持 Apple Music 和 iTunes。

## 特性

- 🎵 **菜单栏应用**:启动后只在菜单栏显示图标,无 Dock 图标
- 🎤 **智能读取播放信息**:优先用 macOS 14+ 的 `MediaRemote` 私有 framework,自动 fallback 到 Apple Script
- 📜 **歌词获取**:LRCLIB API 在线搜索 + 本地缓存(自动 fallback)
- 💫 **桌面悬浮歌词**:无边框、置顶、毛玻璃背景、可拖动、可穿透点击
- ⚙️ **歌词偏移微调**:±10 秒范围,实时保存到 UserDefaults
- ⚡ **现代技术栈**:Swift 6 + SwiftUI + Swift Concurrency,无第三方依赖

## 架构

借鉴 [LyricsX](https://github.com/ddddxxx/LyricsX) 的设计思路,但用现代 Swift 重写:

```
LyricsMenu/
├── App.swift                              # @main 入口 + AppDelegate
├── MenuBarView.swift                      # 菜单栏 status item + SwiftUI 下拉面板
├── DesktopLyricsWindow.swift              # NSPanel + SwiftUI 桌面歌词窗口
├── MusicPlayer/
│   ├── PlaybackInfo.swift                 # 播放状态数据模型(playing 用 wall-clock 起播时间)
│   ├── MusicPlayerProtocol.swift          # 播放器协议 + CompositeMusicPlayer(多源代理)
│   ├── AppleMusicPlayer.swift             # Apple Music / iTunes 实现(MediaRemote + Apple Script)
│   └── MediaRemoteLoader.swift            # 私有 framework dlopen 加载器
├── LyricsService/
│   ├── LyricsLine.swift                   # LyricsLine + Lyrics(实现 RandomAccessCollection)
│   ├── LyricsParser.swift                 # LRC / LRCX 解析器
│   ├── LRCLIBClient.swift                 # LRCLIB API 客户端(async/await)
│   ├── LyricsProvider.swift               # 在线 + 缓存统一入口
│   └── LyricsEngine.swift                 # 协调 player 流 + 精准 dispatch_after 切行
├── Utils/
│   └── UserDefaults+Extension.swift       # 类型安全的 UserDefaults + 屏幕位置因子
└── Resources/
    ├── Info.plist                         # LSUIElement=true(无 Dock 图标)
    ├── NiceLyricsX.entitlements           # Sandbox + 网络 + Automation
    └── Assets.xcassets
```

## 核心设计

### 1. Player 状态机:wall-clock 起播时间

`PlaybackState.playing(start: Date)` 表达"起播时刻",这样:
```swift
case .playing(let start):
    return Date.now.timeIntervalSince(start)  // 零延迟、无需计时器
```

切换到 paused 时冻结时间戳。整个状态机只需 3 行就能算出当前进度。

### 2. 歌词切行:精准 dispatch_after,不每帧 poll

`LyricsEngine.handleProgressUpdate` 计算"距离下一行还有多久",用 `Task.sleep` 精准唤醒:

```swift
let wakeup = max(0.05, timeToNext - 0.05)
nextLineWakeupTask = Task {
    try? await Task.sleep(nanoseconds: UInt64(wakeup * 1_000_000_000))
    recomputeCurrentLine(playbackTime: lastPlaybackTime)
}
```

CPU 占用接近 0,完全没有 timer drift。

### 3. MediaRemote 私有 framework dlopen

借鉴 LyricsX 的 `MRPrivateLoader.m`,用 `dlopen` + `dlsym` 按需加载符号,App Store 审核友好:

```swift
let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
guard let h = dlopen(path, RTLD_LAZY) else { return nil }
let fn = dlsym(h, "MRMediaRemoteGetNowPlayingInfo")
```

macOS 16+ 上,Apple 已经部分开放 `NowPlaying` API,代码里做了双轨适配。

### 4. 窗口位置:比例因子 + 中心吸附

`NSScreen.positionFactor` 把窗口位置存成 `[0,1]` 比例,4K / 外接显示器切换不破相。

## 构建

### 方式 A:Xcode 项目(推荐)

```bash
cd NiceLyricsX
open LyricsMenu.xcodeproj
# Cmd+R 运行
```

要求:
- macOS 16.0+
- Xcode 16+
- Swift 6

### 方式 B:命令行 SPM(测试代码用)

```bash
cd NiceLyricsX
swift build -c release
# 注意:SPM 不会生成 .app bundle,只用于编译检查
```

### 运行单元测试

```bash
swift test
```

测试覆盖:
- LRC 解析(标准、多时间标签、行内翻译、ID 标签、Windows 行尾)
- Lyrics 二分查找 + 偏移
- PlaybackState 状态机 + 容差比较
- LRCLIB JSON 解码

## 开发

### 首次运行权限

启动后,Apple Music / iTunes 通过 Apple Script 读取时,系统会弹 TCC 权限请求(自动化 → Apple Music)。同意即可。

如果拒绝了,可以去 **系统设置 → 隐私与安全性 → 自动化** 重新授权。

## 使用

1. **启动 Apple Music** 播放任意歌曲
2. 菜单栏 **音符图标** 出现
3. 点击图标 → 弹出面板显示当前曲目 + 当前/上一/下一行歌词
4. 在下拉面板里点 **"桌面歌词"** 打开悬浮窗口
5. 用 **±0.1s / ±1s** 按钮微调偏移

## 已知限制

- 不支持逐字卡拉 OK 效果(`<00:01.23>` 行内时间戳),只支持行级高亮
- 不支持 Spotify / Vox 等第三方播放器(只接 Apple Music / iTunes)
- 歌词缓存路径在 `~/Library/Application Support/NiceLyricsX/lyrics/`,删除可强制重新搜索
- 当前 macOS 16+ 部署目标,不支持 macOS 15 及以下

## 致谢

- [LyricsX](https://github.com/ddddxxx/LyricsX) — 架构设计灵感来源
- [LRCLIB](https://lrclib.net) — 开源歌词数据库