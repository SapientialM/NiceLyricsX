# Changelog

## v0.4.0 (2026-10-06) — 测试版

### 新功能
- **播放控制(切歌)**:面板和刘海面板里都能 ⏮ ⏯ ⏭,外加一条**可拖动跳转**的进度条。
  走 Apple Music 的 AppleScript(`playpause` / `next track` / `previous track` /
  `set player position`),脚本跑在专用串行队列上。
  - 所有控制脚本都先判断 Music 在不在运行 —— 否则点一下"下一首"会把**没打开的
    Music 直接拉起来**
  - 命令**按调用顺序串行执行**:"下一首"紧跟"跳转到 30 秒"时,seek 必须落到新歌上,
    不能落到上一首(这个乱序 bug 是单测断言命令顺序才暴露的)
  - 进度条位置基于墙钟实时算 + `TimelineView` 自驱重绘,不用等 2 秒轮询
- **刘海面板展开**:鼠标移到刘海 → 向下展开成控制面板(封面 + 曲目信息 + 大字歌词 +
  翻译 + 进度条 + 切歌),移开自动收回。原来只有"细条"一档,现在细条 / 展开两档共存:
  - 切歌时出现 → 细条冒头 3.5 秒;悬停刘海 → 展开
  - 常驻 → 细条常驻;悬停刘海 → 展开,移开缩回细条

### 修复
- 播放控制命令的乱序问题(见上)。

### 说明
- 展开面板只在悬停时接收鼠标事件;其余时间窗口 `ignoresMouseEvents = true`,
  鼠标全部穿透。
- 窗口 `canBecomeKey = false`:按钮一击必中,且**永远不会抢走键盘焦点**
  (点一下刘海不该让你正在打字的编辑器失焦)。

---

## v0.3.0 (2026-10-06) — 测试版

### 新功能
- **刘海歌词**:把当前歌词投到 MacBook 刘海正下方(菜单栏下沿、水平居中于刘海)。
  两档模式:
  - **切歌时出现** —— 换歌时从刘海下方冒出来约 3.5 秒后收回;鼠标移到刘海或
    歌词条上会保持展开
  - **常驻** —— 一直挂在刘海下面

  技术上全部使用公开 API(`NSScreen.safeAreaInsets` / `auxiliaryTopLeftArea` /
  `auxiliaryTopRightArea` 算刘海几何,`NSPanel` + `level = .mainMenu + 3` 画在
  菜单栏之上,`ignoresMouseEvents` 保证不抢鼠标、菜单栏照常可点),
  **没有引入任何私有 framework**。

  为什么挂在菜单栏**下方**而不是刘海两翼:两翼就是菜单栏本体(左边 app 菜单、
  右边状态栏图标 + 时钟),常驻内容画在那里会和菜单栏项正面打架。

### 说明
- 没有物理刘海的机器(外接显示器 / 老 Mac)也能用,会用一块 183pt 宽的虚拟岛。
- 参考了开源项目 Boring Notch(GPL-3.0)的实现**思路**(它同样使用的那几个
  公开 API 属性),没有复制任何代码 —— NiceLyricsX 保持 MIT。
- 默认关闭,在菜单栏面板的「刘海歌词」里选模式。

### 已知限制
- 只在带刘海的屏幕上显示(外接屏不显示),也还不能调歌词条的尺寸/位置。
- peek 只在**换歌**时触发,不是每句都冒头。
- 歌词条是纯展示窗口,点击没有响应。

---

## v0.2.0 (2026-10-05) — 测试版

在 0.1 的基础上做了一轮「把没接完的线接完 + 把真卡的地方修掉」。没有破坏性变更,
设置项全部沿用原有 UserDefaults key。

### 修掉的真 bug
- **歌词源返回 503 就直接失败**:LRCLIB / 网易云偶发 503、502、429 时,旧实现
  直接把「服务器返回 503」丢到面板上,只能靠用户手动点重搜。现在所有出网请求
  都带指数退避重试(最多 3 次,尊重 `Retry-After`,带抖动),超时 / 连接中断 /
  DNS 失败同样会重试;404 这类重试没意义的错误不会浪费用户时间。
- **LRCLIB 挂了就等于没歌词**:以前只有「LRCLIB 没收录」才会 fallback 到网易云,
  服务端故障会直接中止。现在 LRCLIB 不可用也会改走网易云,两边都不行时才把
  主源的错误抛出来(比「未找到歌词」更能说明问题)。
- **主线程被 AppleScript 冻住**:`refresh()` 每 2 秒(以及每次播放器通知)
  都在主线程上跑 `osascript` 并 `waitUntilExit()`,UI 会周期性卡顿。
  现在脚本跑在专用串行队列上,并做了「同一时刻只查一次」的合并。
- **AppleScript 数字解析看 locale**:AppleScript 把 real 转字符串用系统
  小数分隔符,中文 / 欧洲 locale 下是逗号,旧实现 `TimeInterval("256,111")`
  直接得到 0 —— 时长 0 会选错歌词版本、进度 0 会让整首歌的切行全错。
- **AppleScript 会把没开的 Music 拉起来**:现在先判断 Music 在不在运行,
  不在就直接返回。
- **「桌面歌词」开关是死的**:开关默认 ON,但窗口从没显示过,用户点一下
  没反应、得关掉再打开才生效。现在开关的语义 = 窗口是否显示,且启动时由
  「启动时自动打开」恢复状态。
- **字号 / 不透明度改了不生效**:两个设置写进了 UserDefaults 却没有任何 UI
  读取,也没有任何视图会因它重绘。现在有滑杆,桌面歌词窗口会跟着改尺寸。
- **本地事件监视器从不注销**:桌面歌词的拖动监视器一直挂在 app 上。
- **无效状态反复广播**:没在播放时每 2 秒把 `status` / `currentLyrics` 重设
  一遍,导致整个 UI 每 2 秒空重绘一次。
- 自动化权限检测方式换掉了:旧实现跑 `tell application "System Events"` 去蹭
  弹窗,弹的是 System Events 的权限而不是 Music 的,还会阻塞启动路径。
  现在用 `AEDeterminePermissionToAutomateTarget` 直接问 Music 的权限,
  被拒绝时面板会给出「去系统设置」的提示。

### 新功能
- **菜单栏显示当前歌词**(可选,默认关):状态栏图标旁直接跟当前行。
- **专辑封面**:通过 iTunes Search API 反查 `600x600` 封面,进程内缓存。
- **网易云翻译合并**:网易云的 `tlyric` 之前解码了却没用,现在合进正文
  并显示;内嵌 `【】` 翻译优先,不会被覆盖。
- **桌面歌词显示翻译行**(可关)。
- **字号 / 不透明度滑杆**,窗口高度随字号自适应。
- **登录时启动**(`SMAppService.mainApp`,不需要 helper bundle)。
- **维护动作**:重新搜索歌词(跳过缓存)、重置窗口位置、清除歌词缓存。
- 面板显示真实曲目信息(歌名 / 艺人 / 专辑 / 歌词来源 / 播放状态)。

### 工程
- 新增 `AppSettingsStore` 作为设置的唯一真源,取代散落的
  NotificationCenter 广播 + 只写不读的静态 getter。
- 新增 `ArtworkService`、`LaunchAtLogin`、`AutomationPermission`、`HTTPRetry`。
- 新增 `AppleScriptCompileTests`:直接把生产用的 AppleScript 交给
  `osascript -e` 编译 —— 这次就是这么抓到「动态 tell 目标导致 -2741」的。
- 新增 `HTTPRetryTests`:用 `URLProtocol` 打桩验证 503 → 重试 → 成功 /
  重试用尽 / 404 不重试 / 超时重试。
- 新增 `scripts/make-dmg.sh`,一条命令出 `dist/NiceLyricsX-<version>.dmg`。
- 单元测试 41 → 97 个,`swift test` 全绿。

### 仍然没做
- 逐字卡拉 OK(需要 Apple Music 逐字时间戳,没有读取通道)
- Spotify / QQ 音乐 / 第三方播放器
- 全局快捷键切换桌面歌词显隐
- MediaRemote 在 macOS 26 上依然禁用,走 AppleScript

---

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

