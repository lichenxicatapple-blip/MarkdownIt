# MarkdownIt! 隐私政策 / Privacy Policy

[中文](#中文) · [English](#english)

## 中文

**更新日期：** 2026-11-10\
**发布者：** CHENXI LI（个人开发者）\
**联系邮箱：** [lichenxi.catapple@gmail.com](mailto:lichenxi.catapple@gmail.com)

### 1. 适用范围

本政策说明个人开发者 CHENXI LI（下称“我们”）发布的 MarkdownIt! 如何处理信息。
第三方自行修改或分发的版本，应以相应发布者提供的政策为准。

MarkdownIt! 是本地 Markdown 阅读与编辑工具，不要求注册账号，不包含广告、分析 SDK
或跨 App 跟踪功能，也不提供由开发者运营的文档存储、同步或 AI、搜索中转服务器。

### 2. 在设备上处理的信息

| 信息 | 用途与保存方式 |
| --- | --- |
| 你选择的文档及授权范围内的图片等资源 | 用于阅读、渲染和编辑。文档在原位置保存；应用按系统授予的范围访问文件，不会自动将这些文件上传给开发者。 |
| 最近打开记录 | 在设备上保存最近 10 份不同文档的名称、位置、文件与资源目录的系统授权书签，用于重新打开。记录不包含正文副本；书签不能绕过系统权限。 |
| 阅读划线与批注 | 关联文字范围、划线状态和批注内容按文档完整路径保存在应用的本地数据目录，使用系统文件保护，不改写 Markdown 原文。关闭文档后保留，可能随系统设备备份保存。 |
| 连接设置 | 模型服务地址、模型名称、接口偏好、搜索服务选择及各自的 API Key 一起保存在本机钥匙串，用于建立你指定的连接。 |
| 发送授权 | 在设备上保存已允许模型服务地址的摘要，以及已允许的搜索服务标识。各自按服务记住许可；切换模型或更新密钥不改变同一服务的授权。 |
| API Key | 保存在本机钥匙串，采用设备解锁时可访问、仅限本设备的保护等级。密钥由原生网络层用于认证，不交给文档渲染网页，也不作为 AI 对话正文发送。 |

为在系统终止应用后继续阅读，应用会在本机保存当前文档的恢复数据，包括工作文本、撤销／重做历史、阅读位置与选区、划线与批注编辑现场，以及 AI 对话、搜索词与结果、已读取的网页片段、引用图片快照和未发送草稿。恢复数据采用系统文件保护，不参与设备备份，不发送给开发者。模型连接信息仍仅保存在钥匙串，不写入恢复数据。

成功关闭或切换文档会清除对应阅读现场的恢复数据。AI 对话、引用、图片快照、模型上下文及未发送草稿按文档完整路径独立保存在本机，采用同样的文件保护并排除备份；切换模式、收起面板、切到后台及关闭后重开文档均保留。未完成的回答保留已接收内容，等待你决定是否重试。无法重新访问原文件时，恢复数据保留在设备上，不覆盖其他文件。

清空 AI 历史会删除当前文档的对话记录与模型上下文，保留未发送草稿、当前引用和文档的撤销／重做历史。

应用使用系统本地日志记录服务主机、模型、请求标识、耗时、状态码、错误代码及用量等技术信息，用于排查请求和会话恢复问题。日志不包含密钥、文档正文、提问或回答内容，由系统滚动管理，不发送给开发者。

### 3. 可选 AI、联网搜索及模型列表查询

AI 服务由你通过服务地址、模型和 API Key 自行配置。请求直接发送至你配置的服务，
不经过开发者运营的服务器。

首次向一个服务发送文档、对话或图片前，应用会说明发送范围和接收地址，并请求你的明确许可。
取消时不发送，问题和引用保留在输入区。允许后对该服务不再询问；更换服务地址时重新请求许可。旧版纯文字许可不自动扩展为图片发送许可。

- 在模型设置中输入或更改有效连接信息时，应用可能自动查询模型列表；尚未点击“完成”
  也可能发起查询。查询使用你填写的 API Key 认证，不包含文档正文。
- 发送 AI 消息会将当前文档全文、所选片段、你的问题和本次会话历史发送至所配服务。
  请求还可能包含文档文件名、内容版本及当前可用能力。仅选中一段文字不代表只发送该片段。
- 长对话可能由同一服务整理为摘要，较长文档和引用可能分次按需发送；整理过程也会向该服务发送相关会话内容。
- 根据任务，模型可以读取当前系统时间和时区；工具结果会提供给所配模型服务。
- 源码编辑任务可能包含后续模型请求，以及当前文档编辑工具的参数、结果和修改内容。
- 选中的图片随问题发送实际画面。全局 AI 先发送文档中的图片引用清单，模型可按需读取并接收相关图片；
  不会每轮主动发送全部图片。本地图片受已有文件授权限制，网络图片由应用按其引用地址下载。
  图片会移除原始 EXIF、GPS 等元数据；已发送的画面随该文档的 AI 会话保留，以供追问和重试。
- 应用不额外加入文件的系统绝对路径；文档正文原有的路径、链接和其他信息仍会作为正文的一部分发送。
- 阅读划线与批注不会自动加入 AI 请求。你主动复制到问题中的批注文字按该次问题处理。

联网搜索由你选择服务并配置自己的 API Key，默认关闭。启用后，AI 可根据任务调用所选服务。首次请求会说明服务名称、将发送的数据种类，以及搜索结果及提取正文的发送范围，征求许可；取消不发送搜索请求，仍可根据已有资料回答。允许后记住该服务及发送范围的许可。

搜索请求直接发送至所选搜索服务，包含查询词、语言等搜索参数，以及用于认证的对应密钥。查询词可能由你的提问或文档内容生成。按需读取网页时，网页地址直接发送给支持正文提取的所选服务，由其访问目标页面。搜索结果及实际读取的正文片段会提供给已获准的模型服务，并与对话一起保存在本机，用于追问、恢复与重试。搜索提供者可能处理查询、认证信息、IP 地址与请求日志，其处理规则适用该服务的政策。

我们不将你的文档或对话收集到开发者的服务中用于广告、画像或模型训练。
你选择的服务提供者可能处理请求内容、认证信息、IP 地址及连接日志，其保留期限、训练用途、
处理地点和删除方式由该提供者及你与其约定的条款决定。我们无法代表任意自定义服务承诺零留存。
使用第三方服务前，请了解其隐私政策及服务条款。

### 4. 网络图片、链接与系统服务

文档、引用内容或 AI 回复中的网络图片可能在显示时自动向图片地址发出请求。
图片服务可能获知 IP 地址、请求地址、时间和标准网络请求信息；请求地址本身也可能包含参数。
外部链接通过系统交给相应应用或网站打开，后续处理适用其自身政策。

Apple 或你使用的文件提供程序、备份服务可能依据其政策处理下载、诊断或备份资料。
你选用的模型、图片或邮件服务也可能在其他国家或地区处理信息。
本地阅读不需要配置 AI；本地内容中没有网络资源时，渲染组件和字体可离线工作。

### 5. 联系我们时的信息

你向联系邮箱发送邮件时，我们会收到你的邮箱地址及主动提供的信息，仅用于处理来信、
回复、必要的后续沟通及履行适用法律义务。邮件会经由电子邮件服务提供者处理，
按上述目的所需保留。请勿发送 API Key 或无关的私人文档。

### 6. 保留、删除与用户控制

- 原文档和图片由你在其保存位置管理、移动或删除。删除应用不会自动删除保存在其他位置的原文档。
- 划线与批注可在对应文字处分别移除。删除应用会清除应用内的笔记数据，系统备份可能按其规则独立保留；笔记按路径关联，不随原文件移动。
- 最近打开记录最多保留 10 项，较旧记录随新记录加入而移除。删除应用可清除其本地设置、发送授权和最近记录；
  系统备份、文件提供程序及钥匙串可能按系统规则独立保留信息。
- 你可以在模型设置中使用“重置”清除钥匙串中的完整模型与搜索连接配置、各服务密钥及旧版密钥记录，也可清空 API Key 并保存，或在服务提供者处撤销密钥。
  不应仅依赖卸载应用来清除钥匙串中的密钥。
- 你可以不使用 AI，或停止正在进行的生成。停止操作不能撤回服务已经收到的内容。
  对第三方已收到数据的访问或删除请求，需要向该服务提供者提出。
- 你可通过上述邮箱，就我们实际持有的信息提出访问、更正或删除请求。我们将根据适用法律和
  实际可控范围处理；我们无法远程访问或删除你设备上的文档。

### 7. 信息保护

应用利用系统文件授权、钥匙串及网页内容隔离等措施限制信息访问。
模型连接允许你配置本地或其他 HTTP 服务；HTTP 不提供传输加密，互联网服务建议使用 HTTPS。
任何安全措施均不能保证绝对安全，选择服务地址和分享文档时请考虑内容的敏感性。

### 8. 未成年人

本应用不要求提供年龄或建立儿童档案。未成年人使用第三方 AI 服务时，应遵守该服务的年龄要求，
并在适用法律要求时取得监护人同意。

### 9. 政策更新与联系

我们可能随功能或适用要求的变化更新本政策，并修改文首的更新日期。
如信息处理方式发生需要重新授权的变化，我们会按适用要求取得相应授权。
对本政策或隐私处理有疑问，请联系 [lichenxi.catapple@gmail.com](mailto:lichenxi.catapple@gmail.com)。

## English

**Last updated:** 2026-11-10\
**Publisher:** CHENXI LI (individual developer)\
**Contact:** [lichenxi.catapple@gmail.com](mailto:lichenxi.catapple@gmail.com)

### 1. Scope

This policy explains how MarkdownIt!, published by CHENXI LI, an individual developer
(“we”), handles information. Versions modified or distributed independently by other
parties are subject to their respective publishers’ policies.

MarkdownIt! is a local Markdown reader and editor. It does not require an account,
include advertising, analytics SDKs or cross-app tracking, or provide developer-operated
document storage, synchronization or AI/search relay servers.

### 2. Information processed on your device

| Information | Purpose and storage |
| --- | --- |
| Documents you select and resources such as images within authorized locations | Used for reading, rendering and editing. Documents are saved in place and accessed within system-granted permissions. They are not automatically uploaded to the developer. |
| Recent documents | The names, locations and system access bookmarks for up to 10 distinct documents and their authorized resource folders are stored on your device for reopening. These records contain no copy of the document text. Bookmarks cannot override system permissions. |
| Reading underlines and annotations | Associated text ranges, underline states and annotation text are stored in the app’s local data directory, keyed by the full document path and protected by the system. They do not modify the Markdown file, remain after closing it and may be included in system device backups. |
| Connection settings | The model service address, model name, interface preference, search provider selection and their respective API keys are stored together in the device’s Keychain to establish your chosen connections. |
| Sending permission | Digest identifiers of allowed model service addresses and identifiers of allowed search services are stored on your device. Permission is remembered separately for each service; changing its model or API key does not change that permission. |
| API key | Stored in the device’s Keychain using protection that allows access while the device is unlocked and restricts the item to that device. The native network layer uses the key for authentication. It is not provided to document-rendering web content or sent as AI conversation text. |

To resume after the system terminates the app, the app saves recovery data for the current document on your device: working text, undo/redo history, reading position and selection, underlines and annotation drafts, AI conversations, search queries and results, retrieved webpage excerpts, referenced image snapshots and unsent drafts. Recovery data uses system file protection, is excluded from device backups and is not sent to the developer. Model connection information remains solely in the Keychain and is not included in recovery data.

Successfully closing or switching documents clears the corresponding reading recovery data. AI conversations, references, image snapshots, model context and unsent drafts are saved separately on your device by the full document path, with the same file protection and backup exclusion. They remain when switching modes, collapsing the panel, moving to the background, and closing and reopening the document. An interrupted answer keeps the content already received and waits for you to choose whether to retry. If the original file cannot be accessed, recovery data remains on the device without overwriting other files.

The app uses local system logs for technical information such as service hosts, models, request identifiers, timings, status and error codes, and usage, to diagnose requests and session restoration. Logs contain no API keys, document text, questions or answers. The system manages their retention; they are not sent to the developer.

### 3. Optional AI, web search and model-list requests

You configure the AI service address, model and API key. Requests go directly to the
service you configure, without passing through a developer-operated server.

Before documents, conversations or images are first sent to a service, the app explains the
scope and destination and asks for your explicit permission. Canceling sends nothing
and keeps your question and reference in the composer. Once allowed, the app does not
ask again for that service. A different service address requires new permission. Earlier text-only permission does not automatically authorize image sharing.

- Entering or changing valid connection details in model settings may automatically
  request a model list, including before you tap Done. This request uses your API key
  for authentication and does not contain document text.
- Sending an AI message transmits the entire current document, selected passage,
  your question and the current conversation history to your configured service.
  Requests may also include the document filename, content version and currently
  available capabilities. Selecting a passage does not limit transmission to that passage.
- Long conversations may be summarized by the same service, and long documents or
  references may be sent in parts on demand. Summarization also sends relevant
  conversation content to that service.
- Source-editing tasks may involve follow-up model requests containing current-document
  tool arguments, results and changes.
- Selected images are sent as actual image content with your question. Global AI initially
  receives an inventory of referenced images and may read relevant pictures on demand;
  the app does not proactively send every image each round. Local images remain subject
  to existing file permissions; remote images are downloaded from their referenced URLs.
  Original EXIF and GPS metadata are removed. Sent image snapshots remain with that
  document’s AI conversation for follow-up questions and retries.
- The app does not separately add the file’s absolute system path. Paths, links and other
  information already present in the document remain part of the transmitted text.
- Reading underlines and annotations are not automatically added to AI requests. Annotation text you choose to copy into a question is handled as part of that question.

When requested, the model can obtain the current system time and time zone through a local read-only tool. The result is shared with your configured AI service. Clearing AI history removes the current document’s conversation and model context while preserving the unsent draft, current reference, and document undo/redo history.

Web search is off by default. You choose a search provider and supply your own API key. Once enabled, AI may use it as needed. Before the first request to a search service, the app identifies the provider and the types of data to be sent, and asks for permission to share search results and extracted page content. Canceling sends no search request and allows the answer to continue using existing information. Permission is remembered for that service and sending scope.

Search requests go directly to the chosen provider and include search terms, search parameters such as language, and its authentication key. Queries may be derived from your question or document. When reading a webpage, its URL is sent directly to your selected service that supports extraction, which retrieves the target page. Search results and retrieved excerpts are supplied to your approved model service and retained locally with the conversation for follow-up questions, recovery and retries. The search provider may process queries, authentication information, IP addresses and request logs under its own policies.

We do not collect your documents or conversations into developer-operated services for
advertising, profiling or model training. Your chosen provider may process request content,
authentication information, IP addresses and connection logs. Its retention periods,
training uses, processing locations and deletion practices depend on that provider and
your agreement with it. We cannot promise zero retention on behalf of arbitrary custom
services. Review a provider’s privacy policy and terms before using its service.

### 4. Remote images, links and system services

Remote images in documents, quoted content or AI replies may automatically request their
image URLs when displayed. Image hosts may receive your IP address, requested URL,
request time and standard network request information. The URL itself may contain
parameters. External links are opened through the system in the relevant app or website,
whose subsequent handling is governed by its own policy.

Apple or your file and backup providers may process download, diagnostic or backup
information under their own policies. Your chosen model, image or email service may
process information in another country or region. Local reading does not require AI
configuration. Rendering components and fonts work offline when local content contains
no remote resources.

### 5. Information provided when contacting us

When you email the contact address, we receive your email address and the information
you choose to provide. We use it only to handle and respond to your message, conduct
necessary follow-up and meet applicable legal obligations. Email is processed through
email service providers and retained as needed for those purposes. Do not send API keys
or unrelated private documents.

### 6. Retention, deletion and your choices

- You manage, move or delete original documents and images at their storage locations.
  Deleting the app does not automatically delete originals stored elsewhere.
- Underlines and annotations can be removed separately at their associated text. Deleting the app removes its local notes; system backups may retain them under their own rules. Notes are associated with file paths and do not move with the original file.
- Recent documents are limited to 10 entries, with older entries removed as new entries
  are added. Deleting the app can remove its local settings, sending permissions and recent records. System
  backups, file providers and the Keychain may retain information independently under
  their own rules.
- You can use Reset in model settings to remove the complete model and search connection settings, provider keys and legacy key records from the Keychain,
  clear the API key field and save, or revoke the key with its provider. Do not rely solely on uninstalling the app
  to clear a key from the Keychain.
- You can choose not to use AI or stop an ongoing generation. Stopping cannot retract
  content already received by a service. Requests concerning access to or deletion of
  data already received by a third party must be addressed to that provider.
- You may contact the address above to request access to, correction of or deletion of
  information we actually hold. We handle requests according to applicable law and
  what is within our control. We cannot remotely access or delete documents on your device.

### 7. Protection of information

The app uses system file permissions, the Keychain and web-content isolation to limit
access to information. Model settings allow local and other HTTP services. HTTP does
not provide transport encryption; HTTPS is recommended for internet services. No
security measure guarantees absolute security. Consider the sensitivity of your content
when choosing a service address or sharing a document.

### 8. Minors

The app does not require an age or create profiles of children. Minors using third-party
AI services should follow those services’ age requirements and obtain a guardian’s
consent where required by applicable law.

### 9. Updates and contact

We may update this policy as features or applicable requirements change and revise the
date above. If changes to information handling require renewed authorization, we will
obtain it as required. For questions about this policy or privacy practices, contact
[lichenxi.catapple@gmail.com](mailto:lichenxi.catapple@gmail.com).
