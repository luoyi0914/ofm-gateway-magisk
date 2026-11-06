#!/usr/bin/env node
/**
 * 构建期的「Magpie 引擎二进制路径」修补。
 *
 * 为什么需要：
 *   上游 2.8.0 的独立服务在 packages/standalone/service.mjs 里这样创建引擎：
 *       magpieEngine = createMagpieEngine({ dataDir, logger })
 *   从不传 `binary` 参数，于是 createMagpieEngine 只会去 app 自带的
 *   vendor/magpie/bin/magpie-<platform>-<arch> 找引擎。而 app 里只有 win32 的引擎分片
 *   （单文件 4MB/128 文件上限，也放不下 61MB 的引擎），Android/arm64 上必然找不到。
 *
 *   本模块的方案 A 把 arm64 引擎二进制放进模块运行时 usr/（不放进 app，避免被 app 自更新
 *   覆盖），由启动脚本导出环境变量 OFM_MAGPIE_BINARY 指向它。这里把该环境变量接进
 *   createMagpieEngine，引擎即可用：
 *       createMagpieEngine({ dataDir, logger, binary: process.env.OFM_MAGPIE_BINARY || undefined })
 *
 *   createMagpieEngine 对 `binary` 的处理：给了 binary 就走 path.resolve(binary)、
 *   status().available = existsSync(executable)；未设置（空串视为 falsy）时退回原有
 *   vendor/bin 查找逻辑，行为与上游完全一致。
 *
 * 目标文件：
 *   - packages/standalone/service.mjs —— 模块实际运行的入口（必需）
 *   - index.js —— 上游发布 npm 包时的打包入口（可选，存在就一并补，保持两边一致）
 *
 * 幂等：已补过的形态会被识别并跳过（--app 复用同一目录不失败）。
 * 严格：必需文件里锚点找不到就退出 1，宁可构建失败，也不出「看起来修了」的包。
 *
 * 用法：node scripts/magpie-binary-env.mjs <app 目录>
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import path from 'node:path'

const app = process.argv[2]
if (!app) {
  console.error('用法：node scripts/magpie-binary-env.mjs <app 目录>')
  process.exit(1)
}

const fail = message => {
  console.error(`magpie-binary-env: ${message}`)
  process.exit(1)
}

const ANCHOR_RAW = 'createMagpieEngine({ dataDir, logger })'
const ANCHOR_PATCHED = 'createMagpieEngine({ dataDir, logger, binary: process.env.OFM_MAGPIE_BINARY || undefined })'
// 幂等探测只看「本脚本关心的那一段」：后续 magpie-bun-env.mjs 会在这个调用里再追加
// `bun: process.env.OFM_MAGPIE_BUN || undefined`，整串比对会在第二次构建（增量包复用
// 已打过补丁的 --app 目录）时既匹配不到 ANCHOR_PATCHED、又匹配不到 ANCHOR_RAW，
// 误判成「上游结构变了」而让构建失败。
const PATCH_MARKER = 'binary: process.env.OFM_MAGPIE_BINARY || undefined'

/**
 * 补一个文件。required=true 时找不到锚点即失败；否则只报告跳过。
 * @returns {'patched' | 'already' | 'skipped'}
 */
function patchFile(rel, required) {
  const file = path.join(app, rel)
  if (!existsSync(file)) {
    if (required) fail(`找不到 ${file}`)
    console.log(`magpie-binary-env: 跳过 ${rel}（文件不存在）`)
    return 'skipped'
  }
  const source = readFileSync(file, 'utf8')
  // 只认「OFM_MAGPIE_BINARY 已经接进去了」这个事实，不要求整串完全等于 ANCHOR_PATCHED。
  if (source.includes(PATCH_MARKER)) {
    console.log(`magpie-binary-env: ${rel} 已经是修补后的形态，跳过`)
    return 'already'
  }
  const hits = source.split(ANCHOR_RAW).length - 1
  if (hits !== 1) {
    if (required) fail(`在 ${rel} 里找到 ${hits} 处锚点（期望 1 处）。上游结构可能变了，需要重新确认锚点`)
    console.log(`magpie-binary-env: ${rel} 找到 ${hits} 处锚点，跳过`)
    return 'skipped'
  }
  writeFileSync(file, source.replace(ANCHOR_RAW, ANCHOR_PATCHED))
  console.log(`magpie-binary-env: 已修补 ${rel}（createMagpieEngine 接入 OFM_MAGPIE_BINARY）`)
  return 'patched'
}

const required = patchFile('packages/standalone/service.mjs', true)
patchFile('index.js', false)

if (required !== 'patched' && required !== 'already') {
  fail('service.mjs 没有打上补丁')
}
console.log('magpie-binary-env: 完成')
