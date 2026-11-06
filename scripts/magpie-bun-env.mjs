#!/usr/bin/env node
/**
 * 构建期的「Bun 可执行路径」修补（模块版）。
 *
 * 为什么需要：
 *   Magpie 装 @magpie-community 插件要 fork/exec bun。它默认的 bun 是自己下载到
 *   $XDG_CACHE_HOME/magpie/bun/<ver>/magpie-bun 再执行。Android 10+ 的应用私有目录
 *   不给 exec，于是 `bun add …` 直接失败：
 *       bun add @magpie-community/xxx@latest: fork/exec …/magpie-bun: permission denied
 *   Magpie 上游给的正规逃生阀是环境变量 MAGPIE_BUN（internal/plugin/bun.go 的
 *   Bun() 首行就是读它），所以我们把 bun 随包分发到 usr/bin/magpie-bun，
 *   由模块启动脚本导出 OFM_MAGPIE_BUN，再在这里接进引擎。
 *
 *   （APK 侧对应的实现已经写在入了库的 magpie-engine.js 里；这里是对上游
 *    app 拷贝做同样的最小改动，因为模块构建是拉上游源码组装的，不读 APK 的 assets。）
 *
 * 三处锚点：
 *   1) createMagpieEngine 的签名与 executable 解析处 —— 加 `bun` 参数，解析成
 *      bunExecutable（存在才用，避免把不存在的路径塞给引擎）；
 *   2) 写 settings.json 处 —— 默认打开 chinaMirror（dist 分支走 jsDelivr 镜像，
 *      否则 raw.githubusercontent.com 在国内会被重置）；
 *   3) 组装引擎 env 的 Object.assign 之后 —— 注入 MAGPIE_BUN。必须是「之后」：
 *      上面那行会把继承来的所有 MAGPIE_* 键全删掉。
 *
 * 幂等：已补过的形态会被识别并跳过（--app 复用同一目录不失败）。
 * 严格：任一锚点命中数不为 1 就退出 1 —— 宁可构建失败，也不出「看起来修了」的包。
 *
 * 用法：node scripts/magpie-bun-env.mjs <app 目录>
 */
import { readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'

const app = process.argv[2]
if (!app) {
  console.error('用法：node scripts/magpie-bun-env.mjs <app 目录>')
  process.exit(1)
}

const fail = message => {
  console.error(`magpie-bun-env: ${message}`)
  process.exit(1)
}

const REL = 'src/magpie-engine.js'

// 0) 调用点：把 OFM_MAGPIE_BUN 传进 createMagpieEngine。
//    锚点用「已打上 magpie-binary-env 补丁」的形态——build.sh 里两个脚本就是这个顺序，
//    找不到就说明前一步没生效，直接失败比悄悄漏掉好。
const CALL_RAW = 'createMagpieEngine({ dataDir, logger, binary: process.env.OFM_MAGPIE_BINARY || undefined })'
const CALL_PATCHED = 'createMagpieEngine({ dataDir, logger, binary: process.env.OFM_MAGPIE_BINARY || undefined, bun: process.env.OFM_MAGPIE_BUN || undefined })'
const CALL_FILES = ['packages/standalone/service.mjs', 'index.js']

// 1) 签名 + bunExecutable
const SIG_RAW = 'export function createMagpieEngine({ dataDir, logger, binary } = {}) {\n'
const SIG_PATCHED = 'export function createMagpieEngine({ dataDir, logger, binary, bun } = {}) {\n'
const EXE_RAW = "  let executable = binary ? path.resolve(binary) : path.join(vendor, 'bin', `magpie-${target}${process.platform === 'win32' ? '.exe' : ''}`)\n"
const EXE_PATCHED = EXE_RAW +
  '  // Optional host-supplied bun. Only usable if it is actually there: handing the\n' +
  '  // engine a path that does not exist is worse than letting it download one.\n' +
  "  const bunExecutable = bun && existsSync(bun) ? path.resolve(bun) : ''\n"

// 2) settings.json 默认开国内镜像
const SETTINGS_RAW = "        noAutoUpdate: true, noAutoDownload: true, autoRestart: false,\n      })\n"
const SETTINGS_PATCHED = SETTINGS_RAW.replace('      })\n', '') +
  '        // The community plugin index lives on a raw.githubusercontent.com dist\n' +
  '        // branch, which is routinely reset from mainland networks. The engine\'s\n' +
  '        // own 「国内镜像」 switch is the only thing that routes it through\n' +
  '        // cdn.jsdelivr.net (settings.chinaMirror -> source.ChinaFirst -> the dist\n' +
  '        // reader). It defaults to false upstream, so turn it on here.\n' +
  '        chinaMirror: prefs.chinaMirror ?? true,\n' +
  '      })\n'

// 3) 注入 MAGPIE_BUN（必须在 MAGPIE_* 清理之后）
const ENV_ANCHOR = "        MAGPIE_NO_SHORTCUT: '1',\n      })\n"
const ENV_PATCHED = ENV_ANCHOR +
  '      // Bun must run from a read-only, executable location: the engine\'s own\n' +
  '      // download lands in the app-private data dir, which Android mounts noexec,\n' +
  '      // so every plugin install dies with EACCES. MAGPIE_BUN short-circuits\n' +
  '      // plugin.Bun() before it downloads anything. Set after the MAGPIE_* scrub.\n' +
  '      if (bunExecutable) env.MAGPIE_BUN = bunExecutable\n'

const file = path.join(app, REL)
const source = readFileSync(file, 'utf8')

/** 应用一处替换；已经改过（命中 0 次且目标已存在）则跳过。 */
function apply(what, raw, patched, source) {
  if (source.includes(patched)) {
    console.log(`magpie-bun-env: ${what} 已经是修补后的形态，跳过`)
    return source
  }
  const hits = source.split(raw).length - 1
  if (hits !== 1) fail(`${what}：找到 ${hits} 处锚点（期望 1 处）。上游结构可能变了，需要重新确认锚点`)
  console.log(`magpie-bun-env: 已修补 ${what}`)
  return source.replace(raw, patched)
}

let next = source
next = apply('createMagpieEngine 签名', SIG_RAW, SIG_PATCHED, next)
next = apply('bun 可执行解析', EXE_RAW, EXE_PATCHED, next)
next = apply('settings 默认国内镜像', SETTINGS_RAW, SETTINGS_PATCHED, next)
next = apply('MAGPIE_BUN 注入', ENV_ANCHOR, ENV_PATCHED, next)

if (next !== source) writeFileSync(file, next)

// 最后接调用点。service.mjs 必需，index.js 有就一并补（与 magpie-binary-env.mjs 一致）。
for (const [i, rel] of CALL_FILES.entries()) {
  const callFile = path.join(app, rel)
  let text
  try {
    text = readFileSync(callFile, 'utf8')
  } catch {
    if (i === 0) fail(`找不到 ${callFile}`)
    console.log(`magpie-bun-env: 跳过 ${rel}（文件不存在）`)
    continue
  }
  if (text.includes(CALL_PATCHED)) {
    console.log(`magpie-bun-env: ${rel} 已经是修补后的形态，跳过`)
    continue
  }
  const hits = text.split(CALL_RAW).length - 1
  if (hits !== 1) {
    if (i === 0) fail(`${rel}：找到 ${hits} 处 createMagpieEngine 调用（期望 1 处）。magpie-binary-env.mjs 是否先跑过了？`)
    console.log(`magpie-bun-env: ${rel} 找到 ${hits} 处锚点，跳过`)
    continue
  }
  writeFileSync(callFile, text.replace(CALL_RAW, CALL_PATCHED))
  console.log(`magpie-bun-env: 已修补 ${rel}（createMagpieEngine 接入 OFM_MAGPIE_BUN）`)
}

console.log('magpie-bun-env: 完成')
