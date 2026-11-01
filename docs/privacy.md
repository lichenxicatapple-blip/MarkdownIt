# MarkdownIt! 隐私政策 / Privacy Policy

[中文](#中文) · [English](#english)

## 中文

**更新日期：** 2026-11-01\
**发布者：** CHENXI LI（个人开发者）\
**联系邮箱：** [lichenxi.catapple@gmail.com](mailto:lichenxi.catapple@gmail.com)

### 1. 适用范围

本政策说明个人开发者 CHENXI LI（下称“我们”）发布的 MarkdownIt! 如何处理信息。
第三方自行修改或分发的版本，应以相应发布者提供的政策为准。

MarkdownIt! 是本地 Markdown 阅读与编辑工具，不要求注册账号，不包含广告、分析 SDK
或跨 App 跟踪功能，也不提供由开发者运营的文档存储、同步或 AI 中转服务器。

### 2. 在设备上处理的信息

| 信息 | 用途与保存方式 |
| --- | --- |
| 你选择的文档及授权范围内的图片等资源 | 用于阅读、渲染和编辑。文档在原位置保存；应用按系统授予的范围访问文件，不会自动将这些文件上传给开发者。 |
| 最近打开记录 | 在设备上保存最近 10 份不同文档的名称、位置、文件与资源目录的系统授权书签，用于重新打开。记录不包含正文副本；书签不能绕过系统权限。 |
| 模型设置 | 服务地址、模型名称、接口偏好与 API Key 作为完整连接配置保存在本机钥匙串，用于建立你指定的连接。 |
| AI 发送授权 | 在设备上保存已允许服务地址的摘要标识。对同一服务不重复询问；切换模型或更新密钥不改变该授权。 |
| API Key | 保存在本机钥匙串，采用设备解锁时可访问、仅限本设备的保护等级。密钥由原生网络层用于认证，不交给文档渲染网页，也不作为 AI 对话正文发送。 |

AI 对话和编辑上下文在当前文档会话中处理，不另行保存为应用的持久化对话历史。
关闭或切换文档会结束该会话；收起 AI 面板本身不会结束会话。

### 3. 可选 AI 服务及模型列表查询

AI 服务由你通过服务地址、模型和 API Key 自行配置。请求直接发送至你配置的服务，
不经过开发者运营的服务器。

首次向一个服务发送文档、对话或图片前，应用会说明发送范围和接收地址，并请求你的明确许可。
取消时不发送，问题和引用保留在输入区。允许后对该服务不再询问；更换服务地址时重新请求许可。旧版纯文字许可不自动扩展为图片发送许可。

- 在模型设置中输入或更改有效连接信息时，应用可能自动查询模型列表；尚未点击“完成”
  也可能发起查询。查询使用你填写的 API Key 认证，不包含文档正文。
- 发送 AI 消息会将当前文档全文、所选片段、你的问题和本次会话历史发送至所配服务。
  请求还可能包含文档文件名、内容版本及当前可用能力。仅选中一段文字不代表只发送该片段。
- 长对话可能由同一服务整理为摘要，较长文档和引用可能分次按需发送；整理过程也会向该服务发送相关会话内容。
- 源码编辑任务可能包含后续模型请求，以及当前文档编辑工具的参数、结果和修改内容。
- 选中的图片随问题发送实际画面。全局 AI 先发送文档中的图片引用清单，模型可按需读取并接收相关图片；
  不会每轮主动发送全部图片。本地图片受已有文件授权限制，网络图片由应用按其引用地址下载。
  图片会移除原始 EXIF、GPS 等元数据；已发送的画面在本次文档会话中保留，以供追问和重试，关闭文档时清除。
- 应用不额外加入文件的系统绝对路径；文档正文原有的路径、链接和其他信息仍会作为正文的一部分发送。

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
- 最近打开记录最多保留 10 项，较旧记录随新记录加入而移除。删除应用可清除其本地设置、发送授权和最近记录；
  系统备份、文件提供程序及钥匙串可能按系统规则独立保留信息。
- 你可以在模型设置中使用“重置”清除钥匙串中的完整连接配置及旧版密钥记录，也可清空 API Key 并保存，或在服务提供者处撤销密钥。
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

**Last updated:** 2026-11-01\
**Publisher:** CHENXI LI (individual developer)\
**Contact:** [lichenxi.catapple@gmail.com](mailto:lichenxi.catapple@gmail.com)

### 1. Scope

This policy explains how MarkdownIt!, published by CHENXI LI, an individual developer
(“we”), handles information. Versions modified or distributed independently by other
parties are subject to their respective publishers’ policies.

MarkdownIt! is a local Markdown reader and editor. It does not require an account,
include advertising, analytics SDKs or cross-app tracking, or provide developer-operated
document storage, synchronization or AI relay servers.

### 2. Information processed on your device

| Information | Purpose and storage |
| --- | --- |
| Documents you select and resources such as images within authorized locations | Used for reading, rendering and editing. Documents are saved in place and accessed within system-granted permissions. They are not automatically uploaded to the developer. |
| Recent documents | The names, locations and system access bookmarks for up to 10 distinct documents and their authorized resource folders are stored on your device for reopening. These records contain no copy of the document text. Bookmarks cannot override system permissions. |
| Model settings | The service address, model name, interface preference and API key are stored together in the device’s Keychain to establish your chosen connection. |
| AI sending permission | Digest identifiers of allowed service addresses are stored on your device. Permission is remembered for each service; changing its model or API key does not change that permission. |
| API key | Stored in the device’s Keychain using protection that allows access while the device is unlocked and restricts the item to that device. The native network layer uses the key for authentication. It is not provided to document-rendering web content or sent as AI conversation text. |

AI conversations and editing context are processed within the current document session,
without being saved as persistent conversation history by the app. Closing or switching
documents ends the session; collapsing the AI panel alone does not.

### 3. Optional AI services and model-list requests

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
  Original EXIF and GPS metadata are removed. Sent image snapshots remain in the current
  document session for follow-up questions and retries and are cleared when it closes.
- The app does not separately add the file’s absolute system path. Paths, links and other
  information already present in the document remain part of the transmitted text.

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
- Recent documents are limited to 10 entries, with older entries removed as new entries
  are added. Deleting the app can remove its local settings, sending permissions and recent records. System
  backups, file providers and the Keychain may retain information independently under
  their own rules.
- You can use Reset in model settings to remove the complete connection settings and legacy key records from the Keychain,
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
