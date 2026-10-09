# XM 赛尔号脱机日常 —— 启动 + 完成检测 + 企业微信推送

> **首次使用**：企业微信 key 是**可选的**；不填也能跑，只是不会推送。XM 路径默认已配置好。
>
> 1. **企业微信机器人 key** —— 编辑 `wecom_key.txt`，把 `YOUR-KEY-HERE` 换成你的 key：
>    ```text
>    你的key
>    ```
>    也可以直接粘整条 Webhook 地址。拿到 key：企业微信群 → 右上角 → 群机器人 →
>    添加机器人 → 新建 → 复制它的 Webhook 地址，`key=` 后面那串就是。
>
> 2. **XM.exe 位置** —— 编辑 `xm_path.txt`，填你自己的路径。
>
> 两个文件里都写好了注释和示例，照着改即可，**不需要改任何脚本**。
> 仓库里之所以是占位符，是为了不把作者的 key 和本机路径公开出去
> （这两个文件也写进了 `.gitignore`，避免你误提交自己的）。
>
> 环境要求：**只要 Windows 自带的 PowerShell 5.1**，不需要 Python、不需要 pip。

## 这是什么

双击 `seer.bat` 后全自动执行：

1. 启动 `XM.exe`
2. 依次点击 **进入脱机** → **登陆** → **开始**（按钮位置由 UI Automation 实时定位，不是写死像素）
3. 监视 XM 的日志输出窗口，出现下面任一标记就推送企业微信

```
[时:分:秒]:开始执行[日常签到&道具兑换]   → 推送 [时:分:秒]:开始执行（去掉列表名）
[时:分:秒]:选择任务已执行完毕~           → 推送该行原文
```

没等到开始标记 → 推送 `任务失败`；一直没等到完成标记 → 推送 `任务执行超时，未检测到完成提示`。

推送内容示例：

```
开始：[01:04:55]:开始执行
完成：[01:05:22]:选择任务已执行完毕~
```

> 开始通知由 `Get-StartNotifyText` 生成：正则取出开头的 `[时:分:秒]`（允许带毫秒），
> 拼上 `开始执行`。若某行形状异常（没有时间戳）就原样发送，**保证通知永远不会丢**。

---

## 点击方式：按控件名定位（核心）

**不用硬编码像素。** XM 的按钮是普通 Win32 控件，UI Automation 能报出它们的**名字和位置**
（读日志用的是同一个通道）。`click_ui.ps1` 按名字在控件树里找：

| 键 | 匹配的控件名 | 说明 |
|---|---|---|
| `enter` | 进入脱机 | 正常路径 |
| `enter_update` | 继续使用该版本 | **进入脱机不存在时**的替代：XM 提示有新版本，点它继续用当前版本，并推送"有新版本，继续使用该版本" |
| `login` | 登陆（兼容"登录"） | |
| `start` | 开始 | **点完登陆后才会亮起/变成可点击**，所以用它是否 `IsEnabled` 当就绪信号 |

找到后取**面积最小的匹配节点**（真正的按钮，不是包着它的容器），用它的中心点，再用
**和原版完全相同**的 `mouse_event` 点下去：

```powershell
[System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($cx, $cy)
[Win.CU]::mouse_event(0x0002, 0, 0, 0, 0)
Start-Sleep -Milliseconds 150
[Win.CU]::mouse_event(0x0004, 0, 0, 0, 0)
```

**DPI 分工（关键）**：`click_ui.ps1` 自己声明 DPI 感知（UIA 给物理像素，感知进程也用物理像素设光标，天然对齐）；
`seer_run.ps1` 保持 DPI 不感知（读日志要和你初版同一坐标系）。

## 时序：最后一次点击后「立刻」开始检测

流程严格要求：**按下最后一个 UI（"开始"）之后立即开始轮询**，不能有任何额外等待。

实现方式（`seer_run.ps1`）：

1. 点击"开始"**之前**先给日志拍快照（`New-SeenSet -Kind 'start'`）；
2. 调用 `click_ui.ps1 -Key start`（它内部：等按钮可点击 → 停 3s → 点击）返回后，
   **不做任何 sleep**，直接进入每秒轮询；
3. 轮询里出现「快照里没有的」`开始执行[...]` 行就算命中 →
   推送该行原文，并**立刻**再拍一次快照用于完成标记；
4. 之后**每 5 分钟**（`-DonePollSeconds`）只读一次**最新一行**，若是
   `选择任务已执行完毕~` 就推送该行原文。

   为什么改慢：一次日常可能跑几小时，每秒把整份日志快照/比对纯属浪费内存和 CPU。
   而完成行永远出现在**最后一行**，所以只看最新一行、5 分钟看一次就够。

这条时序很关键：实测一次日常从头到尾**几秒就跑完**（`[23:56:42]:开始执行…` 到
`[23:57:05]:选择任务已执行完毕~` 之间还会在秒级内翻页），
点击后再 sleep 会把开始行漏掉，所以快照必须在点击前拍、轮询必须点击后立刻开始。

## 等待方式：等 UI 就绪 + 3 秒缓冲（提速的关键）

初版是"点完等 60 秒"，纯浪费时间。现在**等控件就绪**再点：

| 步骤 | 等待条件 | 上限参数 |
|---|---|---|
| 启动 XM | 轮询直到"进入脱机"控件出现 | `-EnterTimeoutSeconds`（默认 180s） |
| 点击后 | 轮询直到"登陆"控件出现 | `-LoginTimeoutSeconds`（默认 180s） |
| 点击后 | 轮询直到"开始"控件出现**且 `IsEnabled`** | `-StartTimeoutSeconds`（默认 300s） |
| 每个控件就绪后 | 再等 `-SettleSeconds`（默认 **3 秒**）让界面画完，然后点击 | `-SettleSeconds` |

所以正常情况下**几秒内就能点完三下**，比原来的 150 秒快得多。
"开始"按钮的 `IsEnabled` 就是"登陆成功、任务列表已加载"的信号，比死等 60 秒准得多。

> 找不到控件时会对窗口做一次 `SW_RESTORE` + 置前，再查一遍（窗口被压住或最小化时控件会从自动化树里消失）。

## 流程

```
启动 XM.exe
  ↓ 轮询等"进入脱机"就绪 → 等 3s → 点击        （进入新界面）
  ↓ 轮询等"登陆"就绪     → 等 3s → 点击
  ↓ （给日志拍快照）
  ↓ 轮询等"开始"变为可点击 → 等 3s → 点击
  ↓ 立即每秒轮询日志（不再等待）
检测 "开始执行[自定义魔法-Flash]"（上限 60s）
  ├─ 检测到 → 推送该行原文 → 继续
  └─ 没检测到 → 推送"任务失败" → 结束
  ↓
检测 "选择任务已执行完毕~"（上限 4 小时）
  ├─ 检测到 → 推送该行原文 → 结束
  └─ 超时   → 推送"任务执行超时，未检测到完成提示" → 结束
```

**三个按钮各点一次，没有重试循环。**

## 文件

| 文件 | 作用 |
|---|---|
| `seer.bat` | 双击运行的入口 |
| `seer_run.ps1` | 主逻辑：等就绪、点击、读日志、推送 |
| `click_ui.ps1` | 按控件名定位按钮并点击（UI Automation） |
| `wecom_key.txt` | **企业微信 key（改这里就行）**，不必改脚本 |
| `xm_path.txt` | **XM.exe 位置（换目录时改这里）**，不必改脚本 |
| `find_button.ps1` | 排查工具：列出 XM 各按钮的真实位置（不点击） |
| `selftest_ui.ps1` | 自检：用自建窗口验证"定位+点击"链路（不碰 XM） |
| `diag.ps1` | 排查工具：DPI / 屏幕 / 坐标下是什么窗口 / 实时盯日志 |
| `seer_watch.log` | 运行日志（自动生成，排错看这个） |

依赖：**只需要 PowerShell 5.1**（系统自带）。不需要 Python，不需要 pip 安装任何东西。

## 怎么换企业微信机器人（改 key）

**不用改脚本** —— 打开同目录的 `wecom_key.txt`，把 key 换成新的即可：

```text
# 这个文件里第一条非空、非 # 开头的行就是 key
YOUR-KEY-HERE
```

三种写法都认：

```text
YOUR-KEY-HERE                 ← 只写 key
key=YOUR-KEY-HERE             ← 带 key=
https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=YOUR-KEY-HERE   ← 整条地址
```

key 的优先级（高 → 低）：

| 来源 | 说明 |
|---|---|
| `-Webhook "..."` | 命令行最高优先级，临时换 key 用 |
| `wecom_key.txt` | 平时就改这里；文件删了会自动回退 |
| 脚本内 `$DefaultWebhook` | 内置兜底 |

想临时用另一个机器人跑一次：

```bat
seer.bat -Webhook "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=新的key"
```

**日志不会打印完整 key**，只显示尾 8 位和来源，方便你贴日志求助：

```
webhook : https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...48da10af   (from wecom_key.txt)
```

怎么拿到 key：企业微信群 → 右上角 → 群机器人 → 添加机器人 → 新建 →
复制它的 Webhook 地址，`key=` 后面那串就是。

## 怎么改 XM.exe 的位置

**不用改脚本** —— 打开同目录的 `xm_path.txt`：

```text
# 写 exe 的完整路径，或者只写它所在的文件夹，都行
D:\wenjianjia\xm\XM.exe
```

两种写法都认（实测通过），从资源管理器复制带引号也会自动去掉：

```text
D:\wenjianjia\xm\XM.exe            ← 完整路径
D:\wenjianjia\xm                   ← 只写文件夹
"D:\wenjianjia\xm\XM.exe"          ← 带引号（资源管理器"复制文件地址"的格式）
```

优先级（高 → 低）：

| 来源 | 说明 |
|---|---|
| `-XmExeOverride "..."` | 命令行最高优先 |
| `xm_path.txt` | 平时改这里；文件删了自动回退 |
| 脚本内 `$DefaultXmExe` | 内置兜底 |

```bat
seer.bat -XmExeOverride "E:\games\XM\XM.exe"
```

**不需要管"工作目录"**：XM 的 `ini\` 配置和缓存是放在
`XM.exe` 自己所在的文件夹里的（现在 bat 在 `D:\wenjianjia\bat`，
XM 在 `D:\wenjianjia\xm`，照样能读到 `ini\`）。
所以把 `xm_path.txt` 指向新目录就够了。

路径不存在时会明确报错并停在退出码 9，不会静默跑错程序：

```
xm path : E:\nope\XM.exe   (from -XmExeOverride argument)
XM.exe not found: E:\nope\XM.exe
```

## 有新版本时的处理

点第一步时，脚本按顺序找两个按钮：

| 顺序 | 匹配的按钮 | 结果 |
|---|---|---|
| 1（优先） | `进入脱机` | 正常进入，不发额外消息 |
| 2（回退） | `继续使用该版本` | 点它继续用当前版本，**并推送一条消息** |

推送内容：

```
有新版本，继续使用该版本
```

**只有当"进入脱机"找不到时才会去匹配第二个**，所以 XM 没有提示更新时行为完全不变。
两个按钮同时存在时也优先点"进入脱机"（用"精确文本 > 包含文本 > 片段"的分级匹配保证）。

匹配用的片段（按 rank 递增）：

```
rank 0  继续使用该版本          ← 完整文本
rank 2  继续使用                ← 片段，兼容不同措辞
rank 3  使用该版本              ← 片段，兼容不同措辞
```

这样即使 XM 把按钮写成"继续使用"或"使用该版本"这类变体也能命中。
两个按钮真的都不存在时，仍然按原来的方式报错并停在退出码 4。

实测（真实 XM 弹出更新提示的那次）：

```
ui-click: found key=enter_update name="继续使用该版本" 208x80 center=(1532,930) rank=0
new-version prompt detected; notifying: 有新版本，继续使用该版本
new-version notification sent.
```

## 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `-SettleSeconds` | 3 | 控件就绪后再等几秒才点击 |
| `-EnterTimeoutSeconds` | 180 | 等"进入脱机"就绪的上限 |
| `-LoginTimeoutSeconds` | 180 | 等"登陆"就绪的上限 |
| `-StartTimeoutSeconds` | 300 | 等"开始"变为可点击的上限 |
| `-DetectWindowSeconds` | 60 | 等"开始执行"日志行的上限 |
| `-DoneTimeoutSeconds` | 14400 | 等"选择任务已执行完毕~"的上限（4 小时） |
| `-DonePollSeconds` | **300** | 完成检测间隔（每 5 分钟查一次最新一行） |
| `-Webhook` | 空 | 临时覆盖推送地址（优先于 `wecom_key.txt`） |
| `-XmExeOverride` | 空 | 临时覆盖 XM.exe 路径（优先于 `xm_path.txt`） |
| `-UseFixedCoords` | 关 | 改用固定像素点击（完全等同原版行为） |
| `-ReturnToDesktop` | 关 | **检测到"开始执行"后**最小化 XM 并回到桌面（检测不受影响） |
| `-EnterX/-EnterY` 等 | 760/460、180/180、890/590 | **仅** `-UseFixedCoords` 时生效 |
| `-NoSend` | 关 | 只检测不推送（调试） |
| `-AllowExisting` | 关 | 接受日志里已存在的标记（**仅自检**） |
| `-SkipLaunch` | 关 | 不启动 XM、不点击（调试） |

例：

```bat
seer.bat -ReturnToDesktop
seer.bat -SettleSeconds 5 -ReturnToDesktop
seer.bat -UseFixedCoords
```

## ⚠️ 关于"日志 txt"的一个重要区别

手动从窗口**复制粘贴**出来的 `.txt` **不等于** UI Automation 实际读到的文本：

| | 手动复制的 .txt | UIA 读到的 Name |
|---|---|---|
| 内容 | 你选中的可见文本 | 控件的完整文本属性 |
| 长度 | 可能只截到一部分 | 可能长得多 |

而且**真实工作跑一次是 30-50 分钟，日志会长得多**（远超 29 行）。
所以代码里**不能有"文本长度上限"之类的假设**，`Test-LogBoxName` 只做内容判断，与长度无关。

读长文本时，UIA 的属性访问可能变慢、甚至个别元素抛异常，
因此生产代码里**每个元素的属性读取都单独 `try/catch`**：
一个元素读失败不能中断对其余元素的搜索。

## 实测结论：登录前根本没有日志框

我用 UIA 亲自对真实的 XM 做了取证（启动 XM 后探测），结果：

```
XM processes: 2
top-level windows: 16
all windows (top + children): 46
hwnd=0xA0600 class=WTWindow visible=True EditControls=1 IS-LOGBOX=False title="XM Seer脱机日常"
      chars=96 lines=5
      first=[[v2.5.7]：]
      last =[(脱机之前的版本更新内容可看更新日志)]
total Edit-class controls seen: 4
windows containing a log-like box: 0
```

**46 个窗口（顶层 + 子窗口）里只有一个 96 字的"版本更新公告"，没有任何日志框。**

结论：XM 的日志框是**登录/游戏连接之后才出现/才开始有内容**的。
所以运行日志里那句报警

```
Edit-controls in main window=-1
```

的真实含义是**"那一刻没有日志框"**，不是代码读失败。它出现在"点击登录后 / 点击开始后"
那两个时间点，恰恰就是日志框还没被创建出来的时候。

⚠️ 我用账号登录不了，所以**无法自己复现"已登录 + 正在跑日常"的状态**。
要定位日志框在那种状态下属于哪个窗口/哪个进程，必须在**正在跑**的时候取一次证 —— 见下。

## 取证工具（跑日常时用）

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File D:\wenjianjia\bat\probe_all_windows.ps1
```

它枚举 XM 进程的**顶层窗口 + 所有子窗口**（不只顶层），对每个窗口报告
`class / visible / minimized / EditControls / IS-LOGBOX / 首行 / 末行`。

- 如果某个窗口 `IS-LOGBOX=True`，那就是日志框，它所在的 class 决定搜索策略；
- 如果**所有窗口都 `False`**，说明日志框不在 XM 进程的窗口树里 ——
  那它属于**别的进程**（游戏宿主），代码里的**全桌面兜底扫描**会去接住它。

## 全桌面兜底

`Get-XMLogText` 的搜索顺序：

1. XM 进程的 `MainWindowHandle`；
2. XM 进程的其余**顶层窗口**；
3. **全桌面兜底**：遍历系统里所有顶层窗口，套用同一套内容规则（最多 400 个窗口）。

第 3 步是为"日志框其实归另一个进程所有"这种情况准备的。
内容规则很严（必须含 `选择任务已执行完毕~` 或 `开始执行[...]` 这类中文任务标记），
所以误命中别的程序的概率极低。

## 怎么认出日志框（关键：不能取"最长的"）

**踩过的大坑**：一开始用"取文本最长的控件"当日志框。这个假设是**错的** ——
XM 里还有别的长文本控件（比日志框更长），于是每次都拿到错的控件，
表现就是"XM 明明在正常运行，却报读不到日志"。

**正确做法：按内容认**，而不是按长度、也不依赖固定的行号
（行号会随日志滚动、清空、中途运行而变化）：

1. 文本必须是多行的，且**第 1 行**以 `[时:分:秒]` 开头；
2. 然后只要满足下列之一，就认定它是 XM 任务日志框：
   - 任意一行是 **`选择任务已执行完毕~`**（任务全部跑完）；
   - 任意一行是 **`开始执行[自定义魔法-Flash]`**（自定义魔法开始，覆盖"还在跑"的情况）；
   - 任意一行含 **`[自定义魔法`**（更宽松的兜底）。

实测日志（23:56 那次，29 行）就是标准形状：

```
[23:56:24]:游戏数据加载中ing...
[23:56:25]:游戏数据加载完毕！
[23:56:33]:[Flash]服务器连接成功
[23:56:36]:[Flash]服务器登录成功
[23:56:42]:开始执行[自定义魔法-Flash]      ← 第 5 行
...
[23:57:05]:选择任务已执行完毕~              ← 最后一行
```

**为什么不做成"严格第 5 行 + 末行"**：日志是滚动窗口，行数和位置会变。
按内容认更稳，而且**同样能挡住长诱饵**——诱饵里不会含这些标记。

### 单元测试（`test_logbox.ps1`，不需要 XM）

```
(real log: 12 lines, 342 chars)
[PASS] verbatim real log                     got=True  expect=True
(decoy len=5449 vs real len=342)
[PASS] LONGER decoy control                  got=False expect=False
[PASS] mid-run log (no completion line yet)  got=True  expect=True
[PASS] short unrelated text                  got=False expect=False
[PASS] stamped but unrelated                 got=False expect=False
[PASS] empty name                            got=False expect=False

RESULT: 6/6 passed
```

注意那个诱饵有 **5449 字符，真日志只有 342 字符** —— 旧逻辑必然选错，新逻辑正确拒绝。

### 另外两件事也必须做对

1. **不能只查 `MainWindowHandle`**：点"进入脱机"后 XM 会开新的顶层窗口，
   `MainWindowHandle` 会指向有焦点的新窗口，而日志框留在另一个窗口里。
   所以枚举 **XM.exe 的全部顶层窗口**（`EnumWindows` + PID 过滤），逐个找，命中即停。
2. **不能全量遍历后代**：XM 完全跑起来后有约 **24 个顶层窗口**，
   对每个窗口做 `TreeScope.Descendants` + `TrueCondition` 又慢又容易中途抛异常。
   改成定向查询 `ClassName='Edit'`（日志框 `ClassName=Edit`，
   但 `ControlType` 是 `Pane`，**必须按 ClassName 匹配**）。

失败时会打印到底缺什么：

```
log not readable yet: XM processes=0, top-level windows=0,  MainWindowHandle=0x0, Edit-controls in main window=-1
log not readable yet: XM processes=1, top-level windows=24, MainWindowHandle=0x1C0702, Edit-controls in main window=11
```

`Edit-controls in main window` 是关键：**0 或 -1** 说明主窗口里根本没有 `Edit` 类控件（那就要靠探针
去看日志框到底以什么 ClassName/ControlType 暴露出来）；**大于 0** 说明有候选但没通过内容判定。

### 排查工具（不点击）

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File D:\wenjianjia\bat\probe_xm_windows.ps1
```

它遍历 XM 所有顶层窗口的**全部后代节点**（带逐元素容错），列出每个长文本/文本类控件，
并对**每一个**给出内容判定结果（class、ControlType、字符数、行数、首行、末行）：

```
hwnd=0x908AA visible=True minimized=False Edit-controls=11
    [0] len=861 lines=29 IS-LOGBOX=True
         line5   : [23:56:42]:开始执行[自定义魔法-Flash]
         lastline: [23:57:05]:选择任务已执行完毕~
    [4] len=5449 lines=60 IS-LOGBOX=False
         line5   : [字段]这是一段很长很长的占位文本 5 ...
```

`IS-LOGBOX=True` 的那条就是日志框；如果全是 `False`，把这个输出发我。

## 回到桌面

**检测到 `开始执行[日常签到&道具兑换]` 之后**，加 `-ReturnToDesktop` 会把 XM 最小化并显示桌面：

```bat
seer.bat -ReturnToDesktop
```

要点：

- **时机**：在检测到「开始执行」之后才执行。这时三次点击早已完成、任务已在跑，
  所以**不会干扰点击流程**（点击三连需要 XM 在前台）。
  同时这个时点也正是日志框刚刚可读的时候，说明 XM 已经完全起来了。
- **不影响检测**：日志是通过 UI Automation 读的，窗口最小化后仍然可读，
  加上上面的多窗口扫描，检测照常工作。

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 已推送 开始执行 + 任务完成 |
| 1 | 检测到了但推送失败（看 `seer_watch.log`） |
| 2 | 没检测到开始执行标记，已推送"任务失败" |
| 3 | 等待完成标记超时 |
| 4 | "进入脱机"始终没变成可点击 |
| 5 | "登陆"始终没变成可点击 |
| 6 | "开始"始终没变成可点击 |
| 9 | 找不到 `XM.exe` |

> 这些中文说明由 `seer_run.ps1` 的 `Write-ExitSummary` 打印，**不是** `seer.bat` 打印的 —— 原因见"源码格式"。

## 排查

**先确认按钮能被定位**（不点击）：

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File D:\wenjianjia\bat\find_button.ps1
```

**验证"定位+点击"链路本身没问题**（自建窗口，不碰 XM，实测 PASS）：

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File D:\wenjianjia\bat\selftest_ui.ps1
```

**看日志**：`D:\wenjianjia\bat\seer_watch.log` 每次运行都会写：

```
mode: click buttons located through UI Automation (name-based)
--- step 3/3: waiting for the "start" button to be ENABLED ---
  ui-click: found key=start name="开始" 84x32 center=(1780,1180) enabled=True after 3 poll(s)
  ui-click: settling 3s before clicking
  ui-click: clicked at (1780,1180)
start detected: [21:12:41]:开始执行[自定义魔法-Flash]
send: OK  HTTP 200 {"errcode":0,"errmsg":"ok"}
```

| 现象 | 结论 |
|---|---|
| `control for key "start" not ready after 300s` | "开始"一直没变可点击 → 登陆没成功，或任务列表为空 |
| `ui-click failed for key=...` | 控件没找到（看它打印的 `found`/错误行） |
| `start line not detected` | 点到了但 XM 没执行 → 检查 XM 里勾选的任务 |
| `send: FAIL` | 推送问题（网络 / webhook key） |

## 原理与关键技术点

1. **读日志**：XM 的清单是 `requireAdministrator`，读内存会返回错误 5，所以走
   **UI Automation** 读控件文本（跨进程、无需管理员）。
   日志框在 UIA 里是 `ControlType.Pane` 而 `ClassName=Edit`，
   **按 `ControlType.Edit` 过滤会得到 0 个结果**（踩过这个坑）。

2. **怎么判断"新事件"**：点击前把已有匹配行**文本**拍成快照，之后出现快照里没有的行才算新事件。

   ⚠️ 两个错误做法都踩过：
   - 按"匹配条数增加"判断 → 日志框是 29 行滚动窗口，增一行会挤掉一行，条数不变就永远不触发。
   - 点击后先 sleep 再检测 → 实测魔法**几秒就跑完**（21:09:29 点击，21:09:55 已全部结束），
     等 30 秒再建基线会把开始/完成两个标记都当成旧事件漏掉。

3. **标记串**：
   - **开始**：`开始执行[日常签到&道具兑换]`
     （即 `[时:分:秒]:开始执行[日常签到&道具兑换]`，实测在日志第 5 行）
     - 推送时**只发时间戳 + `开始执行`**，不带列表名
     - 兼容：任何 `开始执行[<名字>]` 行都认，但**排除** `[自定义魔法`（那是自定义魔法列表，
       不是本次要等的日常列表）
   - **完成**：`选择任务已执行完毕~`（取**最新/最后一行**；
     **不要**用 `执行完毕~`，单条任务结束也会打这个，会提前误触发）

4. **中文不能走命令行参数**：PowerShell 5.1 用 ANSI 代码页（cp936）编码传给原生程序的参数，
   中文会变乱码。所以 `click_ui.ps1` 用 ASCII 键（`enter`/`login`/`start`），
   推送则是先写 UTF-8 无 BOM 文件再让 Python 用 `--content-file` 读。

5. **⚠️ 不要把 Python 的 stdout 接到管道**：本机环境下 Python 直接往控制台/管道写会**卡住不退出**。
   （现在用纯 PowerShell 发送，已无此问题。）

6. **⚙️ 源码格式**（改动时注意）：
   - `seer.bat`：**纯 ASCII，一句中文都不要写**。
     ⚠️ 原因：cmd.exe 解析 `.bat` 用的是 ANSI 代码页，`chcp 65001` 对"已经开始的解析"不生效，
     无 BOM 的 UTF-8 中文会被拆成一堆垃圾 token，然后 cmd 逐条报
     `'...' is not recognized as an internal or external command`（实测踩过这个坑）。
     所以中文输出（流程提示、退出码说明）全部由 PowerShell 打印。
   - 所有 `.ps1`：**纯 ASCII**（中文一律用 Unicode 码点 `U @(0x...)` 构造）。
     PowerShell 5.1 会按 ANSI 解码**无 BOM 的 UTF-8 源码**，
     源码里只要出现中文注释就会把脚本读坏（踩过两次）。

7. **推送用纯 PowerShell，不需要 Python**：开始/完成/失败/超时通知都是一个 HTTPS POST，
   用 `Invoke-RestMethod` 发送（失败时回退 `HttpClient`）。

   ⚠️ **重要更正**：早期版本改用 Python 发送，理由是"本机 PowerShell/curl/.NET 的 HTTPS
   全部报 `Schannel: No credentials are available in the security package`"。
   **这个判断是错的** —— 那是 AI 开发沙箱的限制，不是本机的问题。实测本机
   `Invoke-RestMethod`、`HttpClient`、Python 三者都能正常返回 `{"errcode":0,"errmsg":"ok"}`，
   所以 Python 依赖已被移除，`send_wecom.py` 已删除。

   仍然保留的编码要点：**消息文本走请求体的 UTF-8 字节，绝不走命令行参数**
   （PowerShell 5.1 用 ANSI 代码页编码原生 argv，中文会变乱码）。

## 常见问题

**Q：没有配置企业微信 key 会怎样？**

A：**照常运行**。脚本会完整执行：启动 XM.exe → 依次点击进入脱机/登陆/开始 →
监视日志 → 在控制台打印每一个里程碑（开始执行、任务完成、超时等），
**只是不会推送到企业微信**。启动横幅会提示：

```
[WARN] webhook : NOT CONFIGURED - milestones are only printed to the console,
[WARN]           put your robot key in wecom_key.txt to enable WeCom push
```

每个里程碑也会照常打出：

```
[INFO] start detected: [20:57:05]:开始执行[日常签到&道具兑换]
[WARN] [no key] not pushed: [20:57:05]:开始执行
```

也就是说**克隆下来就能直接用**，等你想接企业微信时再往 `wecom_key.txt` 填 key。

> 退出码含义：`9` = 找不到 `XM.exe`；当前已没有"缺 key 退出"这个码了。

