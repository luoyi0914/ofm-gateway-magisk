# OFM 本机网关 · Magisk / KernelSU 模块

把 Our Free Model 的本地网关做成系统级模块：
**开机以 root 常驻运行，不需要安装那个 App，也不需要它在后台待着。**

> [!TIP]
> ### 📱 推荐：在手机上直接跑 AI 编程代理
> **[Deepseek-Harness-Local-Android](https://github.com/Soodok/Deepseek-Harness-Local-Android)**
> —— 免 Root、免 Termux，在 Android 上原生运行 DeepSeek Harness，自带扩展中心，
> 终端、文件、SSH、多智能体协作一应俱全。
>
> 本模块的代码、构建、发版与线上排查，全程都是在这台手机上的 DSH 里完成的。
> 想把手机接上本地模型网关，两者正好配套。

> 作者酷安主页：<https://www.coolapk.com/u/3214953>
>
> 运行时代码分别来自 [上游 App](https://yun.139.com/shareweb/#/w/i/2yA8DQdn7gvts) 与
> [dsh-our-free-model](https://github.com/Ebony-Vinyl/dsh-our-free-model)，
> 详见 [上游来源](#上游来源)。

---

## 为什么做这个

上游的 `Our Free Model` 自带一个本地网关，但它是跟着 APK 跑的：App 被系统杀掉、被清理后台、
或者你压根不想装它时，网关就没了。这个模块把同一套服务搬到 Magisk / KernelSU 层：

- 开机由 root 拉起，不占前台、不弹通知、不参与保活竞争
- 只要手机活着，`127.0.0.1:15656` 就一直在
- 数据放在独立目录，与 App 的数据互不干扰

## 特性

| 特性 | 说明 |
| --- | --- |
| **独立运行** | 模块自带 Node 运行时与完整服务，APK 可以完全不装 |
| **开机自启** | KernelSU / Magisk 在 boot 阶段拉起，可随时关闭 |
| **端口固定** | 默认 `15656`，被占用时自动顺延并记住实际端口 |
| **局域网中继** | 可选开启，用自己的 LAN Key，与本机 API Key 互不通用 |
| **WebUI 管理** | KernelSU 里点「打开」即可查看状态、启停、改配置、看日志 |
| **动作按钮** | 没有 WebUI 时也能在管理器里点「动作」操作 |
| **数据独立** | 全部落在 `/data/adb/ofm`，与 App 数据隔离 |
| **更新检测** | 通过 `update.json` 支持管理器内直接检查更新 |

## 上游来源

本模块不自己实现任何模型能力，只是把上游的现成服务搬到 Android 系统层运行。
当前内置上游版本：**2.7.3**（以仓库根 `package.json` 为准；上游的
`packages/standalone/package.json` 仍写作 2.7.1，服务启动时也自报 2.7.1，
这是上游自身的版本号不一致，不影响功能）。

| 来源 | 地址 | 说明 |
| --- | --- | --- |
| **上游项目（服务实现）** | <https://github.com/Ebony-Vinyl/dsh-our-free-model> | `src/`、`packages/standalone`、`vendor/channel-pack` 均取自该仓库 |
| **Node 运行时** | 取自早期官方 Android 安装包 | 模块里的 `usr/`（Node 与 Android 依赖库），服务代码不再从它取 |

模块不改动服务本身的业务逻辑：`app/` 目录是上游源码按版本组装的产物，
`usr/` 是能跑在 Android 上的 Node。两者合起来就是「同一个服务，换了个启动方式」。

早期版本整包来自一个第三方分发的 Android 安装包，我不知道那个 App 的源头是谁。
如果你是这个 App 的维护者并不希望被这样分发，请开 issue 告知，我会移除相关制品。

模型额度、地区限制、账号渠道、上游条款等一切能力与限制，都由上游决定，
本模块不介入也无法保证。

## 安装

每个版本会发两个附件，**先装完整包，之后日常升级刷增量包**：

| 文件 | 大小 | 什么时候下 |
| --- | --- | --- |
| `OFM_Gateway_Magisk_v<版本>.zip` | 约 35 MB | 第一次装，或换过 Node 运行时 |
| `OFM_Gateway_Magisk_v<版本>_patch.zip` | 约 2 MB | 已经装过 0.4.2 及以上，日常升级用这个 |

1. 到 [Releases](../../releases) 下载对应的 zip
2. 在 KernelSU / Magisk 模块页面选「从本地安装」，选中该 zip
3. 重启手机

增量包只含服务代码，不含 Node 运行时（那部分占整包的 92%，但几乎不随版本变）。
安装时它会核对设备上已有的 `usr/` 指纹：对得上就原地复用、只换 `app/`；
对不上会**明确报错并中止安装**，提示改刷完整包 —— 不会装出半套运行时的机器。

模块安装时已解好运行时，重启后服务会自动起来。确认状态：

```sh
su -c 'sh /data/adb/modules/ofm_gateway/common/ofmctl.sh status'
```

输出会给出 pid、地址、API Key 与日志路径。

## 它提供什么

服务启动后在本机暴露 OpenAI 兼容接口：

| 用途 | 地址 |
| --- | --- |
| 模型清单 | `GET http://127.0.0.1:15656/v1/models` |
| 对话补全 | `POST http://127.0.0.1:15656/v1/chat/completions` |
| Responses API | `POST http://127.0.0.1:15656/v1/responses` |
| Anthropic Messages | `POST http://127.0.0.1:15656/v1/messages` |
| 存活探针 | `GET http://127.0.0.1:15656/health` |

除 `/health` 外都需要带上 API Key：

```http
Authorization: Bearer <你的 Key>
```

Key 由服务首次启动时自动生成并存入 `/data/adb/ofm/settings.json`，重启不变。
在 WebUI 或动作按钮里都能直接看到。

## WebUI

在 KernelSU 管理器里点模块的「打开」进入（需要 KernelSU，Magisk 无此功能）。

页面通过 `ksu.exec` 调用 `common/ofmctl.sh`，不额外监听端口，也不直接请求网关接口：

- **状态**：运行中 / 未运行、PID、地址、局域网中继、API Key（点一下复制）、运行时版本
- **操作**：启动 / 停止 / 重启
- **配置**：端口、局域网访问开关与端口、开机自启，可「保存」或「保存并重启」
- **控制台**：推理服务、渠道模块、EAC 授权、可用模型计数、刷新间隔、输出上限、目录同步时间
- **日志**：`ofm.log` 最后 60 行

页面地址与 Key 均支持点击复制。完整管理面板（渠道登录、用量看板、Key 轮换）带
`frame-ancestors 'none'` 与 HttpOnly 会话，无法内嵌，请复制地址到浏览器打开后粘贴 Key 登录。

写入值有严格校验：端口只能是 0–65535 的整数、局域网开关只允许 0/1、
自启只允许 0/1；`set-config` 只做整行替换，不把输入拼接进 shell。

## 配置

编辑 `/data/adb/modules/ofm_gateway/config.sh`，然后在动作按钮里选「重启服务」生效。

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `PORT` | `15656` | 监听端口。填 `0` 则沿用服务自己记住的端口 |
| `LAN` | `0` | 局域网访问。`1` 额外开一个中继（独立 Key） |
| `LAN_PORT` | `0` | 中继端口。`0` 由系统自动分配 |
| `AUTOSTART` | `1` | 开机自启，`0` 关闭 |
| `DATA_DIR` | `/data/adb/ofm` | 数据目录 |

本机监听固定为 `127.0.0.1`，不可改成通配地址 —— 上游从 2.5.x 起只允许回环绑定，
跨设备访问改由它自己的局域网中继承担。中继使用**独立的 LAN Key**（与本机 API Key 互不通用），
实际端口与 Key 见 `status` 或 WebUI 的「局域网」一行
（`LAN_PORT=0` 自动分配时，实际端口取自服务启动日志里的 `LAN API` 行）。

> **注意**：开启 `LAN` 后，同网段能连到该端口的设备都能用你的额度，请仅在可信网络启用。

## 常用命令

```sh
CTL=/data/adb/modules/ofm_gateway/common/ofmctl.sh
su -c "sh $CTL status"     # 运行状态
su -c "sh $CTL start"      # 启动
su -c "sh $CTL stop"       # 停止
su -c "sh $CTL restart"    # 重启
su -c "sh $CTL log 80"     # 最近 80 行日志
su -c "sh $CTL info"       # 机器可读状态（WebUI 用）
```

## 文件都在哪

| 路径 | 内容 |
| --- | --- |
| `/data/adb/modules/ofm_gateway` | 模块本体（脚本、运行时压缩包、webroot） |
| `/data/adb/ofm-runtime` | 解压出来的 Node 运行时与服务代码 |
| `/data/adb/ofm` | 数据：`settings.json`、`stats.json`、`ofm.log` 等 |
| `/data/adb/ofm/ofm.log` | 服务日志，含管理面板一次性登录链接 |

运行时放在 `/data/adb/ofm-runtime` 而不是模块目录，是因为模块升级时旧目录会被整体清理，
正在运行的进程会被一并杀掉。

## 卸载

在模块页面移除即可。卸载脚本会先停服务、再删 `/data/adb/ofm-runtime`，
**不会**动 `/data/adb/ofm` 里的数据与 Key；要彻底清干净请手动删掉该目录。

## 更新

模块通过 `update.json` 向 KernelSU / Magisk 上报新版本，管理器会提示更新。

- 当前版本：见 `module/module.prop` 的 `version`
- 变更记录：[CHANGELOG.md](CHANGELOG.md)

## 从源码构建

仓库**不含**运行时二进制，构建时现场组装。两种产物：

```sh
./scripts/build.sh          # 完整包 ~35 MB：usr（Node）+ app
./scripts/build.sh --patch  # 增量包 ~2 MB：只有 app
```

产物分别是 `dist/OFM_Gateway_Magisk_v<版本>.zip` 与 `dist/OFM_Gateway_Magisk_v<版本>_patch.zip`。

运行时由两部分拼成，「为什么能增量」也在这里：

| 部分 | 解压后 | 压成 | 随版本变吗 | 来源 |
| --- | --- | --- | --- | --- |
| `usr/`（Node 与 Android 依赖库） | 90 MB | 33 MB | 几乎不变 | `.cache/node-runtime-arm64.tgz`，或 `--usr` 指定的目录/tgz |
| `app/`（独立服务代码） | 约 8 MB | 约 2 MB | 每次升级变的就是它 | 从上游源码按版本组装 |

增量包靠**内容指纹**判断设备上的 `usr/` 能否复用：按「相对路径 + 逐文件 sha256」
算出摘要（`usr-rev`，取前 16 位），与打包工具、压缩级别、mtime 全无关。
这一点很关键 —— 本机是 toybox tar、CI 是 GNU tar，用 tgz 的字节哈希会算出不同的值，
那样本机打的增量包就永远装不进 CI 出的基线包。

常用参数：

| 参数 | 作用 |
| --- | --- |
| `--patch` | 打增量包（只含 app） |
| `--usr <dir\|tgz>` | 指定 usr 来源，usr 目录或含 `usr/` 的 tgz 都行（旧的 `--runtime` 是它的别名） |
| `--app <dir>` | 复用已组装好的 app，跳过拉上游源码（离线构建） |
| `--upstream <v>` | 指定上游版本，等价于 `UPSTREAM_VERSION` 环境变量 |

`.cache/` 不进版本库。首次构建需要自己准备一份 `usr/` 版运行时（含 `usr/bin/node`
与 `usr/lib/*.so`），或用 `--usr` 直接给定；缺失时脚本会报错而不是拿宿主 Node 充数。

上游版本由 `UPSTREAM_VERSION` 控制（默认 `2.7.3`），仓库地址由 `OFM_SOURCE_REPO` 覆盖。
脚本会校验取到的 `package.json` 版本与期望值一致，不一致直接失败。

构建前脚本会校验：

- `module.prop` 必需键齐全（`id`/`name`/`version`/`versionCode`/`author`/`description`）
- `update.json` 的 `version` / `versionCode` 与 `module.prop` 一致
- 组装后的 `app/packages/standalone/cli.mjs`、`app/vendor/channel-pack/pack.js` 都存在；
  完整包还要求 `usr/bin/node`

任一项不符直接报错，避免推出错版本或让管理器反复提示更新。

### 升级上游

改 `UPSTREAM_VERSION` 后重跑构建即可。渠道集合、接口、监听行为都随上游变，
升级前先看一眼上游 README 的变更说明 —— 例如 2.5.x 起服务只允许回环绑定、
CodeArts / CodeBuddy / WorkBuddy 已从渠道包中移除。

### 发版流程

1. 改 `module/module.prop`：调高 `version` 与 `versionCode`
   （**`versionCode` 必须是递增整数**，管理器只按它比新旧）
2. 改 `update.json`：同步版本号，`zipUrl` 换成本次 Release 附件直链
3. 更新 `CHANGELOG.md`
4. push main，然后打 tag 并 push —— GitHub Actions 自动构建完整包与增量包、发 Release

Actions 每次产出两个附件。`update.json` 的 `zipUrl` 决定管理器内更新拉哪个：

- 指向 `..._patch.zip`：日常升级，约 2 MB（**默认这么配**）
- 指向完整 `...v<版本>.zip`：只有在**换了 Node 运行时**或包结构变更时才这么配 ——
  否则老用户会被推到一个装不上的增量包上，安装时明确报错中止

注意事项：

- `zipUrl` 必须指向 **Release 附件**，不能指向仓库源码 zip（源码包没有 `runtime/`，刷入会失败）
- `raw.githubusercontent.com` 有约 5 分钟 CDN 缓存，改完 `update.json` 不会立刻生效
- 换了 `usr/`（Node 版本、依赖库）就变了指纹，这一版必须发完整包并让 `zipUrl` 指向它
- 仓库必须公开，否则管理器取不到 `update.json`
- `RUNTIME_BASE_TAG` 决定 Actions 从哪个历史 Release 取 `usr/`：发完 v0.4.2 后建议改成 `v0.4.2`，
  这样基线里是规整的 `runtime/usr.tgz`，CI 不必每次从老格式整包里抽 usr 重打

## 说明

- 本模块只是把上游服务搬到 Android 系统层运行；模型能力与其限制（额度、地区、上游条款）与上游一致。
- 上游有两个：[App 安装包](https://yun.139.com/shareweb/#/w/i/2yA8DQdn7gvts)（运行时来源）
  与 [dsh-our-free-model](https://github.com/Ebony-Vinyl/dsh-our-free-model)（服务实现）。
- 免费模型的可用性由上游决定，模块不介入也无法保证。
- 模块不收集任何数据，也不联网上报；所有状态都在 `/data/adb/ofm`。
- 与任何模型提供方无隶属或背书关系。

## 贡献者

| 贡献者 | 做了什么 |
| --- | --- |
| [玖清雨](https://www.coolapk.com/u/3214953) · [@luoyi0914](https://github.com/luoyi0914) | 作者：模块结构与安装逻辑、构建与发版流程、WebUI 与动作按钮、文档 |
| DeepSeek Harness（AI 编程代理） | 结对开发：`usr` / `app` 拆包做增量更新（35 MB → 2 MB）、`developer` 角色兼容修复、上游同步与线上问题排查 |

改动基本都能在 [CHANGELOG.md](CHANGELOG.md) 里对上号；如果你也在某条改动里出过力却没被列上，
开个 PR 加一行就行。

## License

MIT
