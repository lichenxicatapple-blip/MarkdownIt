# 参与开发

本指南说明开发环境、资源维护、测试和提交方法。应用介绍见 [README](README.md)，界面约定见[设计规范](design/README.md)，模块与数据流见[架构设计](docs/native-architecture.md)。

## 开发环境

| 项目 | 要求 |
| --- | --- |
| 系统与 IDE | macOS、Xcode 27.1 |
| 模拟器 | 已安装的 iOS 26+ 运行时 |
| 维护工具 | Python 3.11+、Node.js 22+ |
| Swift 格式 | 根目录 `.swift-format` |
| Python 检查 | Ruff 0.14.14，规则位于 `pyproject.toml` |

模拟器不需要开发者账号。实体设备的 Team、证书和签名配置在本机维护，不提交个人设置、凭据或 `xcuserdata`。

## 构建与资源维护

使用 Xcode 打开 `MarkdownIt.xcodeproj`，选择 MarkdownIt scheme 构建运行。工程与共享 scheme 直接维护并提交；新增文件时核对目标归属、编译及资源阶段。

原生源码按职责放入 `MarkdownIt/` 下的目录，划分见[架构设计](docs/native-architecture.md#系统组成)。移动或新增文件时，同步维护磁盘目录、Xcode 分组、[组件登记](design/components.json)与文档链接；生成文件还需更新生成器的目标路径。

修改 WebSource、设计参数、品牌资源、离线依赖或阅读夹具后执行：

```sh
python3 scripts/build_native_web.py
python3 scripts/build_native_web.py --check
```

提交生成的 `Resources/Web`、`Resources/Sample`、`Reader/ReaderDesign.swift` 和品牌资源，不要直接修改生成文件。依赖更新见[离线依赖](vendor/README.md)，品牌母版、配色与生成位置见[品牌说明](design/brand/README.md)。

`python3 scripts/build_native_web.py --check --audit-dependencies` 额外联网检查固定 npm 版本的公开漏洞公告，CI 使用同一入口；普通构建和 `--check` 不联网。

模型容量目录使用 `python3 scripts/update_model_catalog.py --revision FULL_GIT_SHA` 从审核过的 Models.dev 提交更新。工具提取供应商覆盖后的容量，保留准确模型 ID，更新目录、MIT 许可与依赖清单；可用 `--archive` 指定该 revision 的本地源码归档以重现生成。提交前审核容量差异，再执行资源校验和两端回归。普通 App 构建及运行不下载该目录。

界面翻译维护在 `MarkdownIt/Localizable.xcstrings`，系统权限说明维护在 `InfoPlist.xcstrings`。原生文案使用 SwiftUI 本地化 API 或 `String(localized:)`，由 Xcode 提取。新增或修改翻译后重新生成 Web 资源；生成器检查翻译是否完整、占位符是否一致及 Web 文案是否遗漏。验证时在 scheme 的 Application Language 中分别选择 English 和简体中文，并检查未支持语言的英文回退；不翻译文档内容和文件名。

隐私政策正文统一维护在 `docs/privacy.md` 的中英文部分；修改后运行同一资源生成器，提交供原生排版使用的政策内容。正文支持标题、段落、单段落无序列表、两列表格、加粗和链接；未支持的结构会中止生成，避免遗漏内容。应用中的政策入口不依赖网络，确认发送的授权按服务地址保存在设备上。

## 版本与发布

发布版本和构建号统一维护在 [`Configuration/Version.xcconfig`](Configuration/Version.xcconfig)，Debug 与 Release 引用同一份配置。`MARKETING_VERSION` 使用 `主版本.次版本.修订号`：修复增加修订号，兼容的新功能增加次版本，不兼容的变化增加主版本。`CURRENT_PROJECT_VERSION` 是递增的正整数，每次向 App Store Connect 上传新构建前增加，不因普通本地构建或测试自动变化。

App 的 `Info.plist` 引用这两个构建设置，首页从已构建应用的 Bundle 元数据读取，不在界面或脚本中重复写版本。App Store 的发布版本与 `MARKETING_VERSION` 保持一致；发布标签使用 `v主版本.次版本.修订号`。同一发布版本重新上传时仅增加构建号，保留已有标签的含义。

签名和上传在已登录用户的桌面会话中执行，自动化任务由该用户的 LaunchAgent 调度。仅使用相同用户名或 UID 不保证具有相同的钥匙串访问环境，详见 Apple 的 [Mac 钥匙串说明](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)。归档前在实际执行任务的会话中运行 `launchctl managername` 和 `security find-identity -v -p codesigning`，确认桌面会话为 `Aqua` 且能识别有效签名身份。

发行归档使用 Release 配置和本机开发者团队；将 `YOUR_TEAM_ID` 替换为自己的 Team ID，不把个人签名配置写入共享工程：

```sh
xcodebuild -project MarkdownIt.xcodeproj -scheme MarkdownIt \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath output/MarkdownIt.xcarchive \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=YOUR_TEAM_ID archive
```

在 Xcode Organizer 中验证归档并上传至 App Store Connect。上传前核对版本、构建号、签名和 Release 资源内容。

## 测试

测试按依赖环境管理。CI 使用 `MarkdownIt` scheme，真实模型使用独立的 `MarkdownItLive` scheme；实体键盘和输入浮条由真机人工验证。

| 类型 | 维护位置 | 验证内容 | CI |
| --- | --- | --- | --- |
| 单元测试 | `MarkdownItTests` | 文档、权限、上下文、协议解析、输入处理与撤销栈 | 在 iPhone、iPad 模拟器上运行 |
| WebKit 集成测试 | 同一目标中的 `WebReaderTests`、`AgentFlowTests` | 原生与 Web 同步、渲染、目录、编辑工具及模拟网络交互 | 在两端模拟器上运行 |
| UI 测试 | `MarkdownItUITests` | 实际控件操作、软键盘、旋转、前后台切换及面板开合 | 在两端模拟器上完整运行 |
| 真实服务测试 | `MarkdownItLiveTests` | 模型容量、上下文整理、两种协议、多轮对话、编辑、识图、系统时间，以及联网搜索与网页正文读取 | 只编译，不发送请求 |
| 真机人工验证 | 本节的操作流程 | 实体键盘、输入浮条、手指与触控板、Pencil 划线及随手写、系统合成与设备恢复 | 人工执行，不进入自动化 CI |

### 离线自动化测试

`MarkdownIt` scheme 使用唯一的共享测试计划 [Full.xctestplan](MarkdownIt.xcodeproj/xcshareddata/xctestplans/Full.xctestplan)。本地、每次推送、PR 和手动 CI 均完整执行单元、集成和 UI 测试；新增用例由 XCTest 自动发现，不维护核心用例清单。

在 Device Hub 中为每台测试设备关闭 `Device → Keyboard → Simulate Hardware Keyboard`，并确认点击输入框时显示完整软键盘。新连接的设备可能沿用 Settings 中的默认实体键盘模拟配置，应核对当前设备；工具栏的 Keyboard Capture 是另一项设置。实体键盘按下述真机流程验证。自动化运行期间不要手动操作正在测试的模拟器或向其发送键盘快捷键；交互检查在测试结束后进行。

每条 UI 用例在收尾时终止被测 App；跨启动的持久化场景在同一用例内验证。

合成填字后的触控操作先确认软键盘已实际进入屏幕，再解析下一控件的点击位置，避免使用键盘恢复前的旧布局。不要回点输入框来等待恢复；发送和设置流程断言系统编辑菜单未展开。软件按键还需检查目标按键可点击。环境不满足时验证失败，不跳过用例。

旋转用例等待目标 App 的实际界面方向，再检查内容、阅读区域和控件布局。设备朝向值可能与界面方向不同；正方形窗口及 180° 旋转也可能保持尺寸不变。坐标和截图使用实际窗口，不使用可能保留旧朝向的 App 辅助功能边界。

`SimulatorOrientation` 仅编入 UI 测试目标。普通设备使用 XCTest；带铰链的模拟器通过 CoreMotion 读取当前开合状态，再发送 Device Hub 的朝向事件，处理内屏相对外屏的 90° 偏移。该适配针对 [Duo 上 XCTest 与 devicectl 的旋转无效问题](https://github.com/mobile-dev-inc/maestro/issues/3617)，参考 [duoctl](https://github.com/skarol/duoctl) 的 MIT 许可协议实现。私有 API 缺失、签名变化或无法取得铰链角度均令测试失败；不自动跳过、重试或把事件提交成功视为旋转完成。App 界面方向读取也局限于测试目标。升级 Xcode 时，应在内外屏验证 XCTest 能否直接驱动实际旋转，再决定移除事件适配。

图片长按系统菜单用例暂时注释保留在 `ReaderUITests.swift`。模拟器中存在预览浮起后收回、系统菜单未展示的偶发现象，复制、分享、识图及菜单关闭目前需人工核对。定位该现象的原因、确认两端完整回归可靠后恢复自动化；图片轻点菜单及 AI 图片引用仍由自动化验证。

连续对话滚动、AI 阅读编辑与失败重试、发送授权、模型选择与搜索、首次模型配置、设置字段校验及综合阅读导航中的模型配置用例通过 `UIInteractionSynchronization` 保留 XCTest 的主线程空闲同步，并以目标控件的可点击性、内容和布局判断交互完成。系统交互可能保留暂停的屏外动画，或在界面更新完成后仍缺少全局动画完成通知；该适配只在上述用例中对被测 App 关闭全局动画空闲等待。适配使用 XCTest 私有方法，限定于 UI 测试目标，在用例结束、目标 App 退出后恢复；其余用例、App 动画及其他系统进程的同步不变。升级 Xcode 时必须复核方法签名，不匹配会令测试失败，不能静默忽略。

粘贴与撤销的集成用例通过 UIKit 的显式输入项验证事务分组，不读取共享剪贴板。代码块复制的集成用例注入独立命名的 UIKit 剪贴板，验证后删除，避免并行模拟器经宿主共享剪贴板相互覆盖。普通 App 使用系统通用剪贴板；UI 用例通过实际复制按钮及系统粘贴菜单验证完整流程，粘贴与撤销用例另检查撤销和重做。

运行完整的单元、WebKit 集成和 UI 测试：

```sh
python3 scripts/verify_ios.py
```

脚本先生成资源并检查 JavaScript 语法、Swift 格式，使用 `build-for-testing` 编译一次，并验证 App、测试宿主及测试包的完整代码签名，再为各设备选择已安装且兼容的最新 iOS 26+ 运行时。模拟器构建也需要签名，不能关闭 `CODE_SIGNING_ALLOWED`，否则钥匙串操作可能失败。CI 固定使用 iOS 26.5 运行时，两端仍运行全部用例；升级 CI 运行时前先完成对照验证。本地未指定版本时继续选择最新兼容运行时。项目专用 iPhone／iPad 模拟器已存在则复用，缺少时创建；两端并行使用同一份测试产物执行 `test-without-building`。每端内部顺序执行，任一端失败不取消另一端。

测试前在后台启动当前 Xcode 的 Device Hub，初始化系统软键盘用例依赖的模拟器输入服务；仅完成 `simctl boot` 不足以提供这一运行条件，Mac 可以保持锁屏。

Xcode 输出实时显示并保留完整日志，控制台可查看当前测试及结果。XCTest 首次报告动画同步超时时，脚本记录用例与等待操作，在 App 和测试进程仍存活时采集调用栈，再中断本轮并报告失败；持续输出等待日志不代表测试正常推进。其他设备继续执行，不自动重试或计为通过。XCTest 单项超时及连续 10 分钟无输出中断作为兜底。CI 的完整测试步骤上限为 40 分钟，整项任务上限为 45 分钟，包含构建、检查和诊断上传。运行期间使用系统 `caffeinate` 防止空闲休眠。

关闭 Xcode 失败后自动执行的整机 `sysdiagnose`，避免用例已经失败后再等待最长十分钟收集系统数据。`.xcresult` 仍保留结果、UI 层级、截图和录屏；脚本另外收集限时的文档错误日志，动画同步阻塞时采集相关进程调用栈。

| 参数 | 行为 |
| --- | --- |
| 不传参数 | 运行两端；产物写入 `output/native/` 下的本次运行目录 |
| `--family iPhone` / `--family iPad` / `--family iPhoneDuo` | 只验证指定设备类型；Duo 需 iOS 27.1 运行时，执行相同的完整测试计划 |
| `--output /临时目录/本次运行` | 使用指定且尚不存在的产物目录 |
| `--suite unit` / `--suite ui` | 分别运行单元／集成目标或 UI 目标；默认运行全部 |
| `--test-case Target/TestClass/testMethod` | 定向排查单个方法，可重复指定；与全量验证共用构建和签名检查，不与 `--suite` 合用 |
| `--runtime 26.5` | 显式使用已安装的指定版本作对照；默认仍选择各设备兼容的最新版本，结果记录实际运行时 |
| `--test-products /临时目录/Products` | 使用同版本 Xcode 构建的可迁移测试产物，不重复构建或检查源码 |
| `--simulator-prefix 名称` | 隔离模拟器名称；默认 `MarkdownIt`，CI 使用 `MarkdownIt CI` |

脚本校验共享计划和编译产物都包含完整的单元／集成、UI 目标，拒绝禁用、排除或仅选择部分用例的计划。结果必须包含所有请求的测试目标，全部通过且跳过数为零；空结果、缺少目标或未完成的结果均导致失败。每端的结果、模拟器准备与测试执行耗时写入 `results.json`；日志与 `.xcresult` 保存在本次产物目录。

定向排查也使用此脚本，不另写构建命令。指定 `--test-case` 时，结果标记为 `targeted` 并校验每个指定方法实际执行；它不替代修复后的完整回归，也不改变 CI 的全量范围。

这些测试只使用模拟网络或本机端口，不连接真实模型服务，不需要外部 API Key。测试凭据与正常 App 隔离，结束删除测试记录。未经维护者明确许可，不得跳过测试或通过排除必测用例绕过失败；环境或配置不足应报告为验证阻塞。脚本要求所有用例通过且跳过数为零。

其他静态检查：

```sh
ruff check scripts
ruff format --check scripts
python3 -m unittest discover -s scripts/tests
```

[GitHub Actions](.github/workflows/verify.yml) 使用带 `justmarkdown` 标签的 ARM64 macOS 自托管 runner，执行全部检查、Release 编译、真实模型测试目标的编译及两端完整离线回归。单个 runner 依次接收任务，每轮内部并行运行两端模拟器；工作目录与日常开发目录分开，CI 模拟器使用独立名称。runner 需安装上表工具，Xcode 位于 `/Applications/Xcode.app`，并保持运行账号登录、机器联网；runner 离线时已获准的任务排队。

runner 按 [GitHub 官方步骤](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners) 注册到仓库，添加 `justmarkdown` 标签，并配置登录后启动的服务。建议使用专用标准账号；使用日常账号时，任务具有该账号对本机文件和服务的访问权限。标准账号需经管理员授权加入 `_developer` 组，并通过系统 `DevToolsSecurity` 启用开发工具权限；测试不需要 Apple ID。注册凭据和 runner 安装目录不进入项目。

runner 的安装及工作路径不能包含空格，以免默认 shell 拆分脚本路径。需要代理的网络按 [GitHub 代理配置](https://docs.github.com/en/actions/how-tos/manage-runners/use-proxy-servers)在 runner 自己的 `.env` 中设置，并排除 localhost 和回环地址；不在仓库写入本机网络配置。

本机任务根据 GitHub 记录的发起人和重新运行操作人选择审批环境，不能依据提交中的作者姓名或邮箱判定信任：

- `local-ci-owner`：两者均为仓库所有者，且事件为推送、手动运行，或所有者从本仓库分支发起的 PR。该环境不设审批，供维护者正常开发使用。
- `local-ci`：其他任务。仓库管理员必须配置 Required reviewers，仅允许仓库所有者审批，允许本人审批，并保留管理员绕过入口。未获准的任务不会分配到 runner，包括检出代码在内的步骤都不会在本机执行；不通过脚本代替所有者批准。

外部 PR 始终进入审批环境，所有者点击重跑也不改变其来源。公开仓库同时要求所有外部贡献者的 fork PR 工作流获批后才能执行。配置这两个环境后再启用 runner。

批准前审查本轮代码、依赖及工作流。Environment 保护只约束引用它的任务，不是 runner 级强制策略，也不提供系统隔离；移除或替换 `environment` 的工作流可以绕开这一层。不要仅凭任务名称或现有测试通过就批准外部代码，详见 [GitHub 自托管 runner 安全说明](https://docs.github.com/en/actions/reference/security/secure-use)。

GitHub 展示真实执行状态、完整日志与两端结果摘要，始终保留结果和测试日志，失败时附完整 `.xcresult`。任一检查失败都会使流水线失败；更新提交自动取消同一分支的旧流水线。CI 不连接真机，不配置真实模型密钥；实体键盘及真实模型继续使用各自独立的验证入口。

Debug 的 `--sample-document` 打开长文副本，`--reset-sample-document` 重置副本；入口与样例不编入 Release。文件授权相关变更应经系统选择器打开外部文档复测，输入相关变更应核对对应的软件／实体键盘路径。

### 真实模型测试

选择 `MarkdownItLive` scheme，运行 [LiveModelTests.swift](MarkdownItLiveTests/LiveModelTests.swift) 的全部用例。该目标仅接受 HTTPS Atlas 端点，缺少配置时测试失败，不自动跳过或降级为模拟请求。

1. 在仓库外准备权限为 `0600` 的私有 JSON 文件，包含 `baseURL`、`model`、`key`，搜索联调使用的 `serperKey`，以及可选的 `apiProtocol`（`responses` 或 `chatCompletions`；省略时分别测试两种协议）。
2. 将 `MarkdownItLive` 复制为本机非共享 scheme，在 Test → Arguments 中维护本机环境变量；Test 不沿用 Run 的参数与环境变量。
3. 添加 `MARKDOWNIT_LIVE_CONFIG` 指向配置文件，设置 `CFNETWORK_DIAGNOSTICS=0`。
4. 分别选择 iPhone 与 iPad 模拟器运行该 scheme。

命令行复用同一构建、签名及两端执行流程：

```sh
python3 scripts/verify_ios.py --live-config /私有目录/live-model.json --output /tmp/markdownit-live
```

`--live-config` 明确选择独立的 Live 计划并执行该目标的全部用例，不改变默认离线回归或 CI，也不接受排除或局部选择。配置文件需要 `0600` 权限；路径只写入本次临时测试产物，密钥不加入命令参数或测试附件。

选择支持工具调用与识图的模型和接口组合；只验证一种协议时填写 `apiProtocol`。实体设备运行时，将配置文件放入测试宿主 App 的沙盒，环境变量支持以 `~/` 开头的应用内路径。

测试使用独立样本文档和 Keychain 服务，结束删除测试凭据。真实调用可能计费；不提交私有 scheme、配置路径、凭据或包含它们的附件。

### 真机人工验证

使用普通 App 启动方式运行 Debug，退出 XCTest 和调试断点后操作设备。`--sample-document --reset-sample-document` 准备独立长文副本；添加 `--ui-testing --ui-test-agent-fixture` 可使用隔离配置和模拟回答，离线检查 AI 界面与按键流程。文件授权检查应另用独立目录，经系统文件选择器打开。

1. 源码中用实体键盘输入和确认中文候选，用方向键移动光标、Enter 换行，检查滚动和内容；用 ⌘Z、⇧⌘Z 撤销重做，再编辑以确认旧重做分支失效。
2. AI 输入中检查 Enter 发送一次、Shift＋Enter 换行；候选确认和长按重复不误发送。切换软键盘后，回车只换行，发送按钮提交。
3. 分别显示停靠软键盘、浮动键盘和实体键盘输入浮条，包括完全最小化的“拼”按钮。完整停靠键盘缩短内容视口，局部浮条不产生整页底部白边；底部操作与 AI 面板保持在输入界面上方。源码聚焦后反复打开“更多”，点击正文关闭菜单，再打开 AI，确认避让继续生效；进入模型设置，分别操作输入框、接口类型和搜索服务的系统菜单，取消或完成后重复检查源码操作与 AI 面板的避让。
4. 用手指和触控板分别反复展开、收起底部操作，并在快速反向操作后再次收起；展开动作保持同一高度，组外仍可操作正文。
5. 在两个横屏方向和竖屏之间切换，继续在源码与 AI 输入区输入，确认内容、阅读位置和控件布局正确。
6. 重复切到其他 App 再返回，包括将实体键盘输入浮条最小化后返回，检查正文、目录、滚动、输入焦点和面板避让；锁屏解锁及重新连接键盘后再次检查。
7. 阅读时用 Pencil 在文字下方分别画直线、波浪线和略斜笔画，核对起笔容差、即时波浪线与抬笔保存；竖向笔势滚动正文，溢出的表格和代码可横向滚动。检查手掌接触及划线过程中的连续性。
8. 用系统选择菜单分别创建划线、批注及两者共存，检查复制和 AI 引用仍是实际选区。用 Pencil 随手写编辑批注，保留候选与未提交输入；查看已有批注后滚动正文，核对卡片一体移动及完全离屏后的关闭。结合旋转、分屏、大字号和深色外观检查布局。

真机检查结果记录在对应 PR 或 Issue，注明构建版本、设备、系统、键盘及实际操作结论。CI 通过不代表这些检查已经完成；未执行或失败的项目仍需补验，不能记为通过。

## 提交修改

说明问题、最终行为、实际检查和剩余限制。功能与交互变更先说明场景和预期，修复不夹带无关重构、依赖升级或界面改版。涉及平台交互时分别验证 iPhone 与 iPad；模拟器和模拟网络结果不能代替真机或真实服务验证。安全问题按 [SECURITY.md](SECURITY.md) 私下反馈。

公开文档服务于用户使用和贡献者维护。同一规则由对应文件负责，其他位置通过链接引用；操作用编号，比较用表格，标识符和命令使用代码格式。测试运行结果放在 CI／PR，具体缺陷通过 Issue 跟踪，不提交验收进度、排查经过或历史测试计数。

`scripts/` 只保留可重复执行的维护工具，稳定回归进入测试目标。单次探针、构建缓存、日志、xcresult 和评审截图放在可删除的临时目录，完成核对后清理。不要提交真实文档、原始模型请求／回复或含凭据的截图。
