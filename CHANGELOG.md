# 更新日志

## v0.5.1

**新：日志按天分文件保存，并可一键提交议题到仓库**
- 服务日志由单文件 `ofm.log` 改为按天分文件：`/data/adb/ofm/logs/ofm-YYYY-MM-DD.log`，
  跨零点自动切换到新的一天。默认保留最近 14 天（`config.sh` 的 `LOG_KEEP_DAYS` 可调），
  更早的自动清理。旧版 `ofm.log` 仍可读取，不影响从旧版升级。
- WebUI「日志」卡片升级：可按日期下拉查看任意一天、「复制日志」，以及「提交议题」——
  在浏览器打开预填好标题与当天日志尾部的 `luoyi0914/ofm-gateway-magisk` 新建议题页，确认后提交即可。
  全程不内置任何 GitHub 令牌；日志以正文形式附带（尾部约 3KB，需要完整日志请先「复制日志」再粘贴）。
- 本次只改动模块脚本（`common/ofmctl.sh`、`webroot/index.html`、`config.sh`），服务与运行时均不变，
  `usr` 指纹不变，刷增量包即可。

## v0.5.0

本次把「模型工作台 / Magpie 引擎」在 Android 上真正跑通，并修复取模型列表失败的 DNS 问题。

**新：内置 Android/arm64 Magpie 引擎（cgo 编译）**
- 引擎（上游 magpie 6a900e0d，随 Our Free Model 2.8.0）现以 **cgo + Android NDK** 编译
  （`CGO_ENABLED=1`、`aarch64-linux-android21-clang`），让 Go 的网络栈走 bionic 的
  `getaddrinfo()` → netd，与系统 DNS 一致。
- 修复「添加供应商 / 获取模型列表」报 `dial tcp: lookup … on [::1]:53: read udp …: connection refused`：
  之前是 `CGO_ENABLED=0` 的纯 Go 解析器读不到 Android 的 DNS（没有 /etc/resolv.conf）。

**修：模型工作台报「此管理操作需要已登录的本地管理会话」**
- 上游把「模型工作台 / 引擎 / 供应商 / 订阅 / 路由」列为特权路由，只认一次性登录链接或
  `managementKey`；用 `forwardKey`（客户端 API Key）登录只得到普通会话，于是这些页面 403。
- 模块 `ofmctl` 新增 `mgmt-key` 子命令，`status` / `info` 会显示管理密钥；WebUI 控制台新增
  「管理密钥」一行（打码、可复制），并说明：普通登录用 API Key，进入模型工作台/引擎等特权功能
  必须用管理密钥登录控制台。

**升级注意**
- 引擎二进制变化会改变 `usr` 指纹，**请刷完整包**（增量包会因 `usr` 指纹不匹配被拒绝）；
  数据目录 `/data/adb/ofm` 不受影响。
- 一并包含此前累积的改进：局域网中继实际端口展示、日志轮转、启动参数引号健壮化、文档校正。

## v0.4.10-test

> **测试版（预发布 / Alpha）**：本版用于验证「模型工作台 / Magpie 引擎」在 Android 上的**网络（DNS）修复**，属实验性构建。
> 以 GitHub pre-release 形式发布，暂不作为稳定版推送；欢迎小范围测试并反馈。

**修：模型工作台「获取模型 / 添加供应商」报 DNS 失败**（`dial tcp: lookup xxx on [::1]:53: read udp ...: connection refused`）。

- **根因：** Magpie 引擎是用 Go 静态方式（`CGO_ENABLED=0`）交叉编译的，走 Go 自带的纯 Go DNS 解析器。
  而 Android 的 DNS 由 `netd` 统一管理、没有标准的 `/etc/resolv.conf`，纯解析器读不到 nameserver，
  只能回退到 `127.0.0.1:53`/`[::1]:53`，于是所有对外请求（拉取 `/v1/models` 等）都在解析阶段被拒。
  这与登录/权限无关，是引擎二进制的编译方式问题。
- **修法（模块侧，不改上游源码）：** 改用 **cgo + Android NDK（aarch64-linux-android21-clang）** 编译
  `CGO_ENABLED=1` 的 Android/arm64 引擎，让 Go 走 bionic 的 `getaddrinfo()` → `netd`，与系统 DNS 行为一致。
  `scripts/build-magpie-engine.mjs` 现支持 `--cc/--cgo`，android 目标默认用 cgo。
- **升级注意：** 引擎二进制变化会改变 `usr` 指纹，**本版必须刷完整包**（增量包会因 `usr` 指纹不匹配而被拒绝），
  数据目录 `/data/adb/ofm` 不受影响。

## v0.4.9-test

> **测试版（预发布 / Alpha）**：本版用于验证「模型工作台 / Magpie 引擎」的特权登录修复，属实验性构建。
> 以 GitHub pre-release 形式发布，暂不作为稳定版推送；欢迎小范围测试并反馈。

**修：模型工作台报「此管理操作需要已登录的本地管理会话」。**

- **根因：** 上游把「模型工作台 / Magpie 引擎 / 供应商 / 订阅 / 路由」等页面归为特权管理路由，只认两种登录凭据：
  启动时打印的一次性登录链接，或本机的 `managementKey`。而模块 WebUI 之前把 `forwardKey`（也就是给客户端用的
  API Key）当作「登录 Key」引导用户去粘贴，用它登录只能拿到普通会话，于是这些页面返回 403
  「此管理操作需要已登录的本地管理会话」。
- **修法（模块侧，不改上游）：**
  - `ofmctl` 新增 `mgmt-key` 子命令，`status`/`info` 现在会显示**管理密钥**（`info` 增加 `mgmt_key=` 字段）。
  - WebUI 控制台卡新增「管理密钥」一行（打码显示、点击复制），并把说明改为：**普通登录用 API Key；
    进入模型工作台/引擎等特权功能必须用管理密钥登录控制台**。
- **怎么用：** 打开 `http://127.0.0.1:15656` 登录页，粘贴**管理密钥**（来自 `ofmctl mgmt-key`，
  或 WebUI「管理密钥」一行），即可进入模型工作台。
- 本次只改动模块脚本（`common/ofmctl.sh`、`webroot/index.html`），服务与运行时均不变，`usr` 指纹不变，
  仍可用增量包升级（已装 v0.4.8 的用户）。

## v0.4.8

> **Alpha Testing（预发布版）**：本版首次在 Android/arm64 上启用 Magpie 引擎，属实验性构建。
> 发布以 pre-release 形式标记，暂不作为稳定版推荐；从 v0.4.7 及更早升级需刷完整包。欢迎小范围测试并反馈。

**同步上游到 2.8.0，并让 Magpie 引擎在 Android/arm64 上可用（方案 A：引擎随 usr 分发）。**

- **同步上游服务到 2.8.0**（`src/`、`packages/standalone`、`vendor/channel-pack` 均取自上游 v2.8.0）。
- **新增：arm64 Magpie 引擎。** 上游 2.8.0 只随包分发 win32 版引擎，Android/arm64 上模型列表里的
  Magpie 供应商一直不可用。本版用与上游一致的参数（`-tags nogui -trimpath -buildvcs=true
  -ldflags "-s -w"`，上游 magpie 钉子 `6a900e0d`）交叉编译出 **android/arm64** 引擎，随模块运行时
  `usr/` 分发（`usr/bin/magpie-android-arm64`），服务启动时通过环境变量 `OFM_MAGPIE_BINARY` 指向它。
- **为什么引擎放 `usr/` 而不是 `app/`：** 引擎约 61 MB，远超 app 自更新机制的「单文件 4 MB / 128 文件」
  限制，也远超 app 块 10 MB 的上限。放进 `usr/` 由模块安装器解到 `/data/adb/ofm-runtime/usr/bin/`，
  且不受 app 自更新覆盖。**因此本版完整包体积一次性增大到约 61 MB**；增量包仍只含 app（约 2 MB）。
- **升级提示：** 从 v0.4.7 及更早升级时，`usr` 指纹因加入引擎而改变，**请刷完整包**；此后的增量升级照常。
- **构建链：** 新增 `scripts/build-magpie-engine.mjs`（编译引擎 + 生成 engine.json/LICENSE/NOTICE）
  与 `scripts/magpie-binary-env.mjs`（构建期把 `OFM_MAGPIE_BINARY` 接进 `createMagpieEngine`）；
  `scripts/build.sh` 在算 usr 指纹前注入引擎、给 app 带上引擎元数据；CI 增加 Go 环境步骤自动构建引擎。
- 引擎带上完整的上游与 Go 依赖许可证（`vendor/magpie/{engine.json,LICENSE,NOTICE.md}`）。

## v0.4.7

**修：局域网中继的实际端口现在能被正确看到；顺带做了一轮健壮性与文档校正。**

- **修：LAN_PORT=0（自动分配）时，status / info / WebUI 不再只显示「0」或「待服务分配」。**
  服务启动时会把中继端口写进日志的 `LAN API：…:端口/v1` 那一行，本版在 `ofmctl status`/`info`
  里据此解析出真实端口（`info` 额外给出 `lan_actual_port` 字段；配置值 `lan_port` 仍保留，不污染表单）。
- **改进：日志轮转。** 启动前若 `ofm.log` 已超过 4 MB，只保留最近 2 MB，避免长期运行无限增长占满数据分区。
- **健壮性：启动参数逐项加引号**，`DATA_DIR` 含空格时也能正常拉起服务。
- **文档校正：** 构建产物体积统一为实测口径（app 约 8 MB → 约 2 MB）；补充上游版本说明
  （模块内置以根 `package.json` 为准，`packages/standalone` 仍写 2.7.1、服务自报 2.7.1，属上游自身不一致）。
- **清理：** 移除一次性发版脚本 `scripts/release-0.4.6.sh`（发版由 CI 工作流完成，该脚本已无引用）。

模块行为与安装方式不变：开机以 root 常驻，默认端口 `15656`，WebUI 与控制台照旧。

## v0.4.6

**同步上游到 2.7.3，并回到「不带模型工作台引擎」的纯上游形态。**

这一版做两件事：

1. **同步上游服务到 2.7.3**（`packages/standalone`、`src/`、`vendor/channel-pack`
   均取自上游 v2.7.3）。上游这一版是免费车道兼容与渠道稳定性修复。
2. **移除模型工作台引擎（magpie）**。先前试做的「按需下载工作台引擎 + DNS 代理」
   （`engine.json`、`engine-fetch.mjs`、`dnsproxy.mjs`、`magpie-engine-overlay.mjs`）
   整体撤掉，模块回到不带任何额外引擎的状态：只打包上游服务本身，
   不引入需要联网下载的额外二进制。

模块行为与安装方式不变：开机以 root 常驻，默认端口 `15656`，WebUI 与控制台照旧。
`scripts/openai-developer-compat.mjs`（让 `/v1/chat/completions` 接受 `developer` 角色）
继续保留——上游 2.7.3 的这条入口仍只认 `system/user/assistant/tool`，补丁锚点不变。

> 说明：v0.4.5 曾在本仓库发布过带「模型工作台引擎」的版本；本版起放弃该方向，
> 因此 v0.4.6 的内容等价于「v0.4.4 的纯上游基线 + 上游 2.7.3」。

## v0.4.4

**修：换用新版客户端时，这个网关会直接 400「一句话都发不出去」。**

现象是请求一进 `/v1/chat/completions` 就被拒：

```json
{"error":{"message":"unsupported message role: developer","type":"invalid_request_error","param":null}}
```

原因不在鉴权，也不在模型名。上游网关的 chat/completions 入口只认
`system / user / assistant / tool` 四个角色，收到 `developer` 直接抛错；而新版客户端
（DeepSeek Harness 的 pi-ai 适配层等）对**自定义 baseURL** 会把握手用的系统提示
发成 `role: "developer"` —— 于是第一个请求就失败，表现就是「这个通道连"你好"都发不出去」。
上游自己的 `/v1/responses` 入口本来就把 `developer` 折成 `system`，说明这是
chat/completions 这条路的缺口，而不是不兼容。

修法只有一处：`convertMessage` 里把 `developer` 与 `system` 同样处理
（`business.mjs` 与 `vendor/channel-pack/pack.js` 两份一起补）。
新增 `scripts/openai-developer-compat.mjs` 在构建期做这个修补：
**锚点找不到就构建失败**，不会出一个「看起来修了」的包；重复执行可识别已修补形态。

验证方式（同一模型、同一请求，只改第一个消息的 role）：

| 请求首条消息 | 修复前 | 修复后 |
| --- | --- | --- |
| `role: "system"` | 正常 | 正常 |
| `role: "developer"` | 400 `unsupported message role` | 正常，与 system 等价 |

**这一版没有其它改动。** 渠道包与模型目录完全沿用 v0.4.3（上游 2.7.2）。

## v0.4.3

**同步上游 2.5.9 → 2.7.2**，跨过 2.6.0、2.7.0、2.7.1、2.7.2 四个版本：

- 模型工作台（内嵌 magpie 引擎）、订阅车道（Codex / Claude / Gemini 订阅导入与额度查询）、
  三种智能路由策略、原生 Gemini 网关、客户端启动器；
- 渠道收紧：WorkBuddy 国内版、WorkBuddy 国际版、华为云与 CodeArts 在插件端与桌面端一并移除，
  已登录的旧账号不会被删除，只是撤回进入路径。

**工作台在 Android 上用不了，这一版也没法让它可用。** 上游的 magpie 引擎只发布
`win32-x64` 一种构建（65 MB 可执行文件 + 33.5 MB 分片），没有 arm64 版本。
模块不带这些平台二进制，因此工作台相关接口会返回 engine unavailable，
**网关主体不受影响**：模型列表、推理、API Key、局域网中继都正常。
实测环境：本机 arm64 + 模块自带 Node 24.18，`/v1/models` 返回 200。

**打包脚本跟着改了三处**，否则这一版刷进去开不了机：

1. `packages/standalone/` 改成整目录复制。上游 2.6 起多了 `workbench.mjs`、
   `library.mjs`、`providers.mjs`、`routing.mjs`、`client-terminal.mjs`，
   `management.mjs` 直接 import 了它们 —— 旧版那份 7 个文件的白名单会漏，
   漏一个就是启动即 `ERR_MODULE_NOT_FOUND`。
2. `src/engine-parts/`（33.5 MB，Windows 引擎分片）与 `vendor/magpie/` 完全不带。
   照旧整拷 `src/` 会让 app 块从 3 MB 顶到 36 MB，增量包直接失去意义。
3. 拉上游源码改用 partial clone + sparse，只下载要打进包的约 12 MB；
   仓库里另外 100 MB 平台二进制不再拖。

另外加了两道构建期检查：用 node 把 `service.mjs` 的 import 图整体 import 一遍
（漏文件当场失败，不用等刷进设备），以及 app.tgz 超过 10 MB 直接报错。

**体积**：app 从 1.9 MB 涨到约 3.4 MB（新增工作台、订阅车道、管理页），
增量包仍是完整包（约 36 MB）的十分之一。

**更新通道**：从这一版起 `update.json` 指向 `_patch.zip`，日常升级走增量包。
装在 v0.4.0 / v0.4.1 的设备没有 `usr-rev` 指纹，管理器里更新会明确中止并提示改刷完整包 ——
先手动刷一次 v0.4.3 完整包（或 v0.4.2 完整包），之后就都走增量包了。

## v0.4.2

**升级包从 35 MB 降到 2 MB。** 之前每发一版，整包都要重下 36 MB，
但其中 92% 是 Node 运行时（`usr/`，90 MB 解压后压成 33 MB）——
它几乎不随版本变化，每次升级真正变的只有 7.5 MB 的服务代码（`app/`，压成 1.9 MB）。

现在每个版本发两个附件：

| 文件 | 大小 | 什么时候下 |
| --- | --- | --- |
| `OFM_Gateway_Magisk_v0.4.2.zip` | 约 35 MB | 第一次装，或换过 Node |
| `OFM_Gateway_Magisk_v0.4.2_patch.zip` | 约 2 MB | 已经装过 0.4.2 之后，日常升级用这个 |

增量包只含 `app/`，安装时核对设备上已有的 `usr/` 指纹：**对得上就原地复用、
只换 `app/`；对不上就明确报错并中止安装，提示改刷完整包**。不会出现
「装到一半没有 Node」的机器。

指纹按「相对路径 + 逐文件 sha256」算（`runtime/usr-rev`，取前 16 位），
与打包工具、压缩级别、mtime 无关 —— 这点是必要的：开发机是 toybox tar、
CI 是 GNU tar，用 tgz 的字节哈希会得出不同的值，那本机打的增量包就永远装不进
CI 出的基线包。

**运行时目录结构变了**：`runtime/` 里不再是一个整包的 `runtime-arm64.tgz`，
而是 `usr.tgz` + `app.tgz` + `.version` + `usr-rev` 四件。`customize.sh` 和
`runtime.sh` 按新的结构解，并且仍认老格式（v0.4.1 及更早的整包）——
老用户直接刷这一版的完整包就能平滑切过来。

**构建脚本**多了 `--patch`、`--usr`、`--app`、`--upstream` 四个参数；
`--app` 可以复用已组装的 app 跳过拉上游源码，离线也能构建。

**迭代方向**：以后日常升级只下 2 MB。只有换 Node 版本这类改动才需要完整包。

## v0.4.1

修掉几处「平时看不出、换一台机器或换一次调用方式就会翻车」的问题。

**模块目录不再靠 `$0` 猜**。`service.sh`、`action.sh`、`uninstall.sh`、`ofmctl.sh`
原来都用 `${0%/*}` 推算模块目录，前提是调用方式恰好是绝对路径。但 Magisk 是把目录放进
`MODDIR` 环境变量、KernelSU 则是 `cd` 到模块目录后以 `sh service.sh` 调用 —— 后者 `$0`
只有文件名，`${0%/*}` 出来仍是个文件名，推导失败。现在统一按
「`MODDIR` / `OFM_MODDIR` 环境变量 → `$0` 所在目录及其上级 → 当前目录及其上级」逐个试，
**以「该目录里确实有 `config.sh`」为准**，都不成立才退回固定路径。

**控制台读取不再依赖 curl 的 cookie jar**。`ofmctl.sh console` 原来用 `curl -c/-b`
维护会话 cookie。这要求调用链上的 `curl` 是完整实现——实测在只认
`-s/-H/-d/-o` 的精简 curl（本项目开发环境里就是这种）上，`-c` 的 jar 路径会被当成
位置参数，请求直接失败，症状是控制台永远报「无法连接服务」。现在改成从响应头里取
`Set-Cookie`、再用 `Cookie` 头带回去，只用到最基础的参数，两种 curl 都能跑。

**顺手清掉的东西**：误提交进仓库的临时脚本 `tmp5/getsrc.py`（一次性的 MCP 探测脚本，
硬编码本机端口，与模块无关）已移除，`tmp5/` 加进 `.gitignore`。

## v0.4.0

同步上游到 **2.5.9**（内置运行时原为 2.1.0，跨 48 个版本）。

**构建方式变了**：以前整个运行时从第三方 Android 安装包里原样取出，服务代码因此被锁在
那个包的版本上。现在 `usr/`（Node 与 Android 依赖库）仍复用，`app/`（服务代码）改为
从上游仓库按版本组装，升级只需改 `UPSTREAM_VERSION` 重跑构建。

**监听行为变了**：上游从 2.5.x 起只允许服务绑定回环地址，跨设备访问改由它自己的
局域网中继承担。因此 `config.sh` 里的 `HOST` 已被移除：

- 本机监听固定为 `127.0.0.1`，不再可配；
- 新增 `LAN`（0/1）与 `LAN_PORT`（0 = 自动分配）；
- 中继使用独立的 LAN Key，与本机 API Key 互不通用；
- WebUI 的「监听地址」下拉框换成「局域网访问」开关，状态卡多一行「局域网」。

⚠️ 从 0.3.x 升级时，如果你以前把 `HOST` 改成过 `0.0.0.0`，升级后该行会被忽略，
需要改在 `LAN=1` 上（或在 WebUI 里开启）。

**渠道变化**：CodeArts、CodeBuddy、WorkBuddy 已从上游渠道包中移除，现为
LobsterAI、Qoder / Qoder 中国版、TRAE、Cline、Loomy、Raccoon、MiniMax、ZCode、Gemini、
OpenCode，外加匿名免费车道、Kilo 免费池与 EAC。之前登录过前三家的账号在新面板里不可见。

**免费车道的指纹变了（最要紧的一条）**：上游网关 2026-10-14 把免费车道从 `/zen/v1`
迁到 `/inference/v1`，客户端 User-Agent 也从 `opencode/1.18.31` 换成
`opencode/latest/2.0.26/cli`，要求同时带 `x-opencode-session` 与
`x-opencode-session-id`（外加 `x-session-affinity` / `x-session-id` 镜像），
并**不再发送** `x-opencode-request`（v1 专用头，v2 收到即 403）。0.3.x 内置的
2.1.0 用的全是旧值，且工具名集合仍是 `bash/glob/grep/read` 四件套。

**其它**：聚合车道（76 家自带 Key 的提供商，以 `provider/model` 形式出现，2.5.9 把
`opencode` 换成了 `fleetrelay_t1`）与降级链（`combo:` 虚拟模型）均已接入独立服务；
新增“已失效模型剔除”、用量统计与备份导入导出页面更新、外发代理链路修正等。
`/v1/messages`（Anthropic Messages）在 2.1.0 已有，不属于本次新增。

> 上游的「工具输出压缩 / 提示词瘦身」挂在插件适配器上，不经过独立服务，
> 所以本模块不包含该能力。

## v0.3.5

尝试修复部分设备安装失败（`Error: Failed to install module script`，错误码 1）。

**现象**：安装进度走到 `- Extracting module files` 之后就中断，管理器只显示
`Failed to install module script`，模块没有装上。0.3.4 的用户反馈中出现这个问题。

**原因**：`customize.sh` 用 `${0%/*}` 推算自己所在的目录。但这个脚本不是被直接执行的，
而是被 KernelSU / Magisk 的安装器 `source` 进来的，此时 `$0` 指向的是安装器本身，
不是模块目录。推算失败后，脚本按回退逻辑去找 `/data/adb/modules/ofm_gateway`，
但安装阶段模块实际位于 `/data/adb/modules_update/ofm_gateway`，两边对不上：
它去执行 `/data/adb/modules/ofm_gateway/common/runtime.sh`，文件不存在，
运行时解压这一步直接失败，脚本按设计 `exit 1`，整个安装被判为失败。

**为什么不是所有人都遇到**：回退路径 `/data/adb/modules/ofm_gateway` 是否存在，
取决于那台设备之前有没有装过本模块。没装过的新设备上这个目录不存在，必然失败；
装过、目录还在的设备可能恰好能跑通，所以表现为「有人能装、有人装不上」。

**修复**：`customize.sh` 改为优先使用安装器传入的 `$MODPATH`（安装期为
`/data/adb/modules_update/<模块 id>`），取不到时才退回原来的 `$0` 推导。
这样无论安装器以 `source` 还是直接执行的方式调用，都能定位到正确的模块目录。

**顺带修正**：此前定位错误还会带来一个不易察觉的隐患：升级时如果旧模块目录仍在，
安装阶段可能去解旧目录里的运行时，导致装完版本与实际运行时版本不一致。
修复后安装阶段只从当前安装包解压，不会再串到旧版本。

> 若安装仍然失败，请附上日志（root 执行 `logcat -d -s ksud:* | tail -n 80`）。

## v0.3.4

一次模块整体审查后的修复：

- **升级不再杀服务**：`runtime.sh` 删旧运行时前先停服务、解到临时目录再原子替换；
  之前升级会直接 `rm -rf` 正在使用的运行时目录，进程被连根拔起
- **卸载先停服务**：否则会留下拿着已删可执行文件的孤儿进程；另按 cmdline 兜底清理
- **`start` 的 FIFO 失败可退化**：`mkfifo` 失败时改为直接写日志，而不是整个启动失败
- **`stop` 的竞态**：`kill -9` 后补一次等待，避免误报仍在运行
- **`action.sh` 不再死循环**：stdin 不可读时 `read` 立即返回，现在会退出
- **`service.sh` 等待超时**：`/data/adb` 长期不就绪时最多等 60 秒
- **`customize.sh` 失败可见**：运行时解压失败会报错退出，而不是默默装完
- **控制台 cookie 改落数据目录**（0700），不再写全局可读的 `/data/local/tmp`
- **`console` 先检查 curl**，缺失时给出明确提示
- **WebUI**：`setBusy` 覆盖控制台按钮；移除未使用的变量

## v0.3.3

- 去掉「打开完整控制台」按钮，改为可点击复制的两行：
  控制台地址、登录 Key。复制后自行到浏览器打开地址、粘贴 Key 登录
- 地址与 Key 跟随状态刷新同步更新，不再依赖先点控制台的「读取」

## v0.3.2

- 修复 `module.prop` 里 `description` 被误写成 `.description`（多了一个点），
  导致管理器读不到模块介绍
- 构建脚本新增 `module.prop` 校验：必需键缺失、或以非字母开头的非法行都会直接报错

## v0.3.1

- 修复「打开完整控制台」首次打开报 `{"error":"管理接口仅允许本机同源访问"}`：
  浏览器给本机地址附带 `android-app://` 这类非 http 的 Referer 时，上游的同源围栏
  会以 `referer-invalid` 返回 403（手动在地址栏回车因来源变成自身而通过）
- 点按钮时先把地址写入剪贴板，再用 VIEW intent 投递；失败时提示粘贴打开
- 拷贝统一走 `copyText`，剪贴板 API 不可用时回退 `execCommand`

## v0.3.0

- WebUI 新增「控制台」区块：推理服务状态、渠道模块、EAC 授权、可用模型计数、
  刷新间隔、输出上限、目录同步时间
- 新增 `ofmctl.sh console`：用本机 API Key 临时换取会话后读取 `/api/management/summary`，
  cookie 写入临时文件、用完即删，Key 不经 URL
- 「打开完整控制台」交给系统浏览器：管理页带 `frame-ancestors 'none'`，无法在 WebView 内嵌

## v0.2.2

- 修复 PID 被复用导致的状态误判：`is_running` 除 `kill -0` 外再核对 `/proc/<pid>/cmdline`，
  避免把别的进程当成服务，从而 `start` 直接返回、服务实际已停
- `stop` 在服务已不在时也会清理残留的 pidfile、FIFO 与 service.lock

## v0.2.1

- 日志每行前面加时间戳，格式 `10/23-22:46:15`
- 服务输出改经 FIFO 后写入日志，node 仍以真实 PID 运行，启停不受影响

## v0.2.0

- 新增 KernelSU WebUI 管理页面：状态、启停 / 重启、端口与监听地址、开机自启、日志查看
- WebUI 通过 `ksu.exec` 调用 `ofmctl.sh`，不额外监听端口
- `ofmctl.sh` 新增 `info`、`set-config`、`log` 三个子命令
- 构建脚本会核对 `update.json` 与 `module.prop` 的版本是否一致

## v0.1.0

首个版本。

- 模块自带 Node 运行时与 Our Free Model standalone 服务，无需安装 App
- 开机由 KernelSU / Magisk 拉起，以 root 常驻运行
- 默认监听 `127.0.0.1:15656`，端口被占用时自动顺延并记住
- 动作按钮可查看地址与 API Key，并启停 / 重启服务
- 数据独立存放于 `/data/adb/ofm`，与 App 数据互不干扰
