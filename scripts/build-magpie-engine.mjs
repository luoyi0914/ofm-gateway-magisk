#!/usr/bin/env node
/**
 * 构建 arm64（Android/Termux ABI）版 Magpie 引擎二进制，并生成随包分发的元数据。
 *
 * 背景（方案 A）：
 *   上游 2.8.0 只随包分发 win32-x64 的 Magpie 引擎（engine.json 的 binaries 里只有
 *   `win32-x64`）。模块跑在 Android/arm64 上，process.platform=android、process.arch=arm64，
 *   于是 `createMagpieEngine` 找不到可用引擎，模型列表里的 Magpie 供应商全部不可用。
 *
 *   引擎二进制约 61MB，远超 app 自更新机制的「单文件 4MB / 128 文件」限制，所以不能放进
 *   app/ 目录。这里走方案 A：引擎二进制单独放进模块运行时 usr/（由模块 installer 解到
 *   /data/adb/ofm-runtime/usr/bin/），并让服务通过 OFM_MAGPIE_BINARY 环境变量指向它
 *   （构建期补丁 scripts/magpie-binary-env.mjs 负责把该环境变量接进 createMagpieEngine）。
 *
 * 与上游的关系：
 *   本脚本照抄上游 `scripts/build-magpie-engine.mjs` 的构建与 NOTICE 收集逻辑，唯一区别是
 *   目标平台由命令行参数指定（默认 android/arm64），且产物输出到指定路径/元数据目录，
 *   而不是写进仓库的 vendor/magpie。构建参数与上游 release 完全一致（-tags nogui -trimpath
 *   -buildvcs=true -ldflags "-s -w -X main.version=ofm-<rev12>"），保证可复现。
 *
 * 用法：
 *   node scripts/build-magpie-engine.mjs [--goos android] [--goarch arm64]
 *        [--revision 6a900e0d048e592cbc9120dd2c3f515aab9ef04a]
 *        [--out .cache/magpie-android-arm64] [--meta .cache/magpie-meta]
 *        [--work .cache/magpie-build] [--go go] [--cc <clang>] [--cgo 0|1]
 *
 * cgo / DNS：
 *   Android 的系统 DNS 由 netd 统一管理，没有标准的 /etc/resolv.conf。Go 的纯解析器
 *   （CGO_ENABLED=0 时默认）读不到 nameserver，会退回 127.0.0.1:53/[::1]:53，导致引擎
 *   发出的请求报 `dial tcp: lookup … on [::1]:53: connection refused`。因此 android/arm64
 *   必须用 cgo 构建：CGO_ENABLED=1 + Android NDK 的 aarch64 clang，让 net 走 bionic 的
 *   getaddrinfo → netd，和系统一致。非 android 目标默认仍 CGO_ENABLED=0。
 *   cgo 需 --cc 指定 NDK clang，或设置 ANDROID_NDK_HOME 由脚本推导。
 *
 * 产物：
 *   <out>              arm64 ELF 引擎二进制（chmod 0755）
 *   <meta>/engine.json 供 app/vendor/magpie/engine.json 使用（binaries 为空，引擎走 usr）
 *   <meta>/LICENSE     上游 MIT
 *   <meta>/NOTICE.md   上游 + Go 依赖许可证清单
 */
import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { chmod, mkdir, readFile, readdir, rename, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const DEFAULT_REVISION = '6a900e0d048e592cbc9120dd2c3f515aab9ef04a' // 上游 2.8.0 钉子
const UPSTREAM = 'https://github.com/yetone/magpie.git'
const ROOT = fileURLToPath(new URL('../', import.meta.url))

function parseArgs(argv) {
  const opts = {
    goos: 'android', goarch: 'arm64', revision: DEFAULT_REVISION,
    out: path.join(ROOT, '.cache', 'magpie-android-arm64'),
    meta: path.join(ROOT, '.cache', 'magpie-meta'),
    work: path.join(ROOT, '.cache', 'magpie-build'),
    go: process.env.GO || 'go',
    cc: process.env.CC || '',
    cgo: null, // null = 自动（android 目标开启，其余关闭）
  }
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i]
    if (a === '--goos') opts.goos = argv[++i]
    else if (a === '--goarch') opts.goarch = argv[++i]
    else if (a === '--revision') opts.revision = argv[++i]
    else if (a === '--out') opts.out = path.resolve(argv[++i])
    else if (a === '--meta') opts.meta = path.resolve(argv[++i])
    else if (a === '--work') opts.work = path.resolve(argv[++i])
    else if (a === '--go') opts.go = argv[++i]
    else if (a === '--cc') opts.cc = argv[++i]
    else if (a === '--cgo') opts.cgo = !['0', 'false', 'no', 'off'].includes(String(argv[++i]).toLowerCase())
    else if (a === '--no-cgo') opts.cgo = false
    else if (a === '-h' || a === '--help') { console.log('见脚本头部注释'); process.exit(0) }
    else { console.error(`未知参数：${a}`); process.exit(2) }
  }
  return opts
}

const opts = parseArgs(process.argv.slice(2))
const version = `ofm-${opts.revision.slice(0, 12)}`
const source = path.join(opts.work, 'magpie-build')

// 解析 cgo 与 Android C 工具链
const wantCgo = opts.cgo === null ? opts.goos === 'android' : opts.cgo
function deriveAndroidCC(ndkHome, goarch) {
  const archMap = { arm64: 'aarch64', amd64: 'x86_64', '386': 'i686', arm: 'armv7a' }
  const triple = archMap[goarch]
  if (!triple) throw new Error(`不支持的 android 架构：${goarch}`)
  const host = process.platform === 'darwin' ? 'darwin-x86_64' : 'linux-x86_64'
  return path.join(ndkHome, 'toolchains', 'llvm', 'prebuilt', host, 'bin', `${triple}-linux-android21-clang`)
}
let cc = opts.cc
const ndkHome = process.env.ANDROID_NDK_HOME || process.env.ANDROID_NDK_ROOT || process.env.ANDROID_NDK_LATEST_HOME || ''
if (wantCgo && !cc && ndkHome) cc = deriveAndroidCC(ndkHome, opts.goarch)
if (wantCgo && !cc) {
  throw new Error('cgo 构建需要 --cc 指定 Android NDK 的 clang，或设置 ANDROID_NDK_HOME')
}
const env = {
  ...process.env,
  GOOS: opts.goos,
  GOARCH: opts.goarch,
  GOARM64: opts.goarch === 'arm64' ? 'v8.0' : (process.env.GOARM64 || ''),
  CGO_ENABLED: wantCgo ? '1' : '0',
  GOFLAGS: '',
  GOCACHE: path.join(opts.work, 'go-cache'),
  GOMODCACHE: path.join(opts.work, 'go-mod'),
  GOWORK: 'off',
}
if (wantCgo) env.CC = cc

function run(command, args, cwd = source, capture = true) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd, env, shell: false, windowsHide: true,
      stdio: ['ignore', capture ? 'pipe' : 'inherit', 'inherit'],
    })
    let output = ''
    child.stdout?.on('data', chunk => { output += chunk })
    child.once('error', reject)
    child.once('close', code => code === 0
      ? resolve(output.trim())
      : reject(new Error(`${command} ${args[0]} 失败（退出码 ${code}）`)))
  })
}

async function exists(file) {
  try { await readFile(file); return true } catch (error) {
    if (error.code === 'ENOENT') return false
    throw error
  }
}

async function licenseFiles(dir, prefix = '', depth = 0) {
  const found = []
  for (const item of await readdir(path.join(dir, prefix), { withFileTypes: true })) {
    const relative = path.join(prefix, item.name)
    if (item.isFile() && /^(licen[cs]e|copying|notice|copyright)([._-].*)?$/i.test(item.name)) {
      found.push(relative)
    } else if (item.isDirectory() && depth < 2 && !item.name.startsWith('.') &&
      !['testdata', 'tests', 'site', 'node_modules'].includes(item.name)) {
      found.push(...await licenseFiles(dir, relative, depth + 1))
    }
  }
  return found.sort()
}

async function main() {
  await mkdir(opts.work, { recursive: true })
  if (!await exists(path.join(source, '.git', 'HEAD'))) {
    await mkdir(source, { recursive: true })
    await run('git', ['init', source], opts.work)
  }
  // 有本地改动（含未跟踪）就拒绝构建，避免产物来源不明
  const dirty = await run('git', ['status', '--porcelain', '--untracked-files=all'])
  if (dirty) throw new Error('拒绝从有本地改动的 .cache/magpie-build 检出构建')
  try { await run('git', ['cat-file', '-e', `${opts.revision}^{commit}`]) } catch {
    await run('git', ['fetch', '--depth=1', UPSTREAM, opts.revision], source, false)
  }
  await run('git', ['checkout', '--detach', opts.revision], source, false)
  if (await run('git', ['rev-parse', 'HEAD']) !== opts.revision) throw new Error('revision 不一致')

  const executable = `magpie-${opts.goos}-${opts.goarch}${opts.goos === 'windows' ? '.exe' : ''}`
  const temporary = path.join(opts.work, executable)
  const flags = ['-tags', 'nogui', '-trimpath', '-buildvcs=true', '-ldflags', `-s -w -X main.version=${version}`]
  console.log(`build-magpie-engine: 构建 ${opts.goos}/${opts.goarch} @ ${opts.revision.slice(0, 12)} (${version}) …`)
  await run(opts.go, ['build', ...flags, '-o', temporary, '.'], source, false)

  const buildInfo = await run(opts.go, ['version', '-m', temporary])
  if (!buildInfo.includes(`vcs.revision=${opts.revision}`) || buildInfo.includes('vcs.modified=true')) {
    throw new Error('构建产物的 VCS 来源校验未通过')
  }
  const digest = createHash('sha256')
  for await (const chunk of createReadStream(temporary)) digest.update(chunk)
  const sha256 = digest.digest('hex')

  // 收集 Go 依赖许可证，生成 NOTICE.md（与上游逻辑一致）
  const modules = []
  const listed = await run(opts.go, ['list', '-deps', '-tags', 'nogui', '-f',
    '{{if .Module}}{{.Module.Path}}|{{.Module.Version}}|{{.Module.Dir}}{{end}}', '.'])
  const notices = [
    '# Magpie engine notices', '',
    `Upstream: ${UPSTREAM}`,
    `Pinned revision: ${opts.revision}`,
    `Source build version: ${version}`,
    `Target: ${opts.goos}/${opts.goarch}`, '',
    'Built without upstream modifications using the nogui tag. This excludes the native',
    'desktop shell and retains the complete embedded web UI and built-in plugins.',
    'The upstream MIT license is reproduced in LICENSE. Go dependency license and',
    'notice files below are copied verbatim from the modules linked into this build.',
    'The Go runtime license is included as well. Build inputs and hashes are in engine.json.', '',
  ]
  for (const row of [...new Set(listed.split(/\r?\n/).filter(Boolean))].sort()) {
    const [name, moduleVersion, dir] = row.split('|')
    if (name === 'github.com/yetone/magpie' || !dir) continue
    const files = await licenseFiles(dir)
    if (!files.length) {
      const readme = await readFile(path.join(dir, 'README.md'), 'utf8').catch(() => '')
      if (/^#+\s+Licen[cs]e\b/im.test(readme)) files.push('README.md')
    }
    if (!files.length) throw new Error(`缺少依赖许可证：${name}`)
    modules.push({ path: name, version: moduleVersion, licenses: files.map(f => f.replaceAll('\\', '/')) })
    notices.push(`## ${name} ${moduleVersion}`, '')
    for (const file of files) notices.push(`### ${file.replaceAll('\\', '/')}`, '', '```text',
      (await readFile(path.join(dir, file), 'utf8')).trimEnd(), '```', '')
  }
  const goroot = await run(opts.go, ['env', 'GOROOT'])
  notices.push('## Go runtime', '', '```text', (await readFile(path.join(goroot, 'LICENSE'), 'utf8')).trimEnd(), '```', '')

  // 落盘二进制
  await mkdir(path.dirname(opts.out), { recursive: true })
  await rename(temporary, opts.out)
  await chmod(opts.out, 0o755)

  // 落盘元数据（引擎走 usr，engine.json 的 binaries 留空，避免 app 侧去 src/engine-parts 找分片）
  await mkdir(opts.meta, { recursive: true })
  const upstreamLicense = await readFile(path.join(source, 'LICENSE'))
  await writeFile(path.join(opts.meta, 'LICENSE'), upstreamLicense)
  await writeFile(path.join(opts.meta, 'NOTICE.md'), notices.join('\n'))
  const metadata = {
    schemaVersion: 1, name: 'magpie', upstream: UPSTREAM, revision: opts.revision, version, license: 'MIT',
    build: {
      command: [opts.go, 'build', ...flags, '.'],
      go: await run(opts.go, ['version']),
      cgo: wantCgo,
      cc: wantCgo ? cc : null,
      env: wantCgo ? { CGO_ENABLED: '1', CC: path.basename(cc) } : { CGO_ENABLED: '0' },
    },
    binaries: {}, // 引擎二进制随 usr 分发，由 OFM_MAGPIE_BINARY 指向
    modules,
  }
  await writeFile(path.join(opts.meta, 'engine.json'), `${JSON.stringify(metadata, null, 2)}\n`)
  console.log(`build-magpie-engine: 完成 ${opts.out} sha256=${sha256}`)
  console.log(`build-magpie-engine: 元数据 ${opts.meta}/{engine.json,LICENSE,NOTICE.md}`)
}

await main()
