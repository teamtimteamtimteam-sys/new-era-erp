#!/usr/bin/env node
// scripts/check-import-inert.mjs —— 一支对着线上动手的脚本,被 import 时【什么都不开始】
// ════════════════════════════════════════════════════════════════════════════
// MES-6a-2(2026-10-10,Tim 的并入):`scripts/smoke-routes.mjs`(以及每一支对着线上动手的脚本)只在被直接执行时跑,
//   从不在被 import 时跑;这一支检查证明 import 它什么都不开始。机制本身在 scripts/lib/entrypoint.mjs(为什么要它,见那里)。
//
// 【瞄准 · AIM】
//   我读的是      :scripts/ · db/ · docs/surveys/ 下每一支 .mjs 的 **JavaScript AST**(acorn;注释不进 AST),
//                   以及在一个子进程里【真的 import】它们之后,那个子进程里被拦下的每一次"开始做事"的尝试。
//   我声称管的是   :每一支对着线上动手的脚本,被 import 时一件事都不开始 —— 不起进程、不发请求、不开连接、不写文件、不退出进程。
//   两者不同之处   :★ 我判"对着线上动手"靠的是【它用了什么】(import 了 liveLock / 起一次性账号的那几支函数、动态 import 了它们、
//                   字面量里写着服务密钥的名字 / 连接池 / 线上域名)—— 一支换了一种我不认识的办法去碰线上的脚本,我认不出它。
//                   ★ 动态那一半拦的是【子进程里】的 child_process / fetch / net / http(s) / 写文件 / process.exit;
//                   一支用别的门(比如原生扩展)去做事的,我拦不到 —— 静态那一半(守卫必须是第一句)是另一层,不依赖拦截。
//
// 【两层,各自独立地红】
//   ① 静态:每一支对着线上动手的脚本,import 之后的【第一句】必须是 onlyWhenRunDirectly(import.meta.url),
//      而且那个名字 import 自 scripts/lib/entrypoint.mjs。库(liveLock.mjs · ephemeral.mjs · scripts/lib/*)不许有顶层语句。
//   ② 动态:在一个装了拦截的子进程里逐支 import —— 每一支都必须以 NOT_RUN_ON_IMPORT 拒绝,而且拦下的尝试必须是 0。
// 【每一次运行都先证明自己没瞎】(check_grants 的先例:自证格每次都跑,不是有人记得才跑):
//   · 一支不守卫、顶层就起进程的合成脚本 → 动态那一层必须拦下一次尝试;顶层发请求的 → 同上;
//   · 一支守卫了的合成脚本 → 必须以 NOT_RUN_ON_IMPORT 拒绝、0 次尝试;
//   · 一支守卫放在第二句的合成源码 → 静态那一层必须点名它;一支 import 了 liveLock 的合成源码 → 分类器必须认出它对着线上动手。
//   任何一格没有咬人 → 退 3(本检查瞎了,它的"干净"不作数)。
// 【故障注入】CHECK_IMPORT_INERT_FAULT=unguard:<相对路径> —— 读那一支时把守卫那一句从源码里拿掉再判(静态那一层必须红);
//   动态那一层的注入就是上面那两支不守卫的合成脚本(每次都跑)。
// 退出码:0 干净 · 1 有违反 · 3 本检查瞎了。
import { readFileSync, readdirSync, statSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { join, relative, dirname, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { spawnSync } from 'node:child_process'
import { pathToFileURL } from 'node:url'
import * as acorn from 'acorn'
import { assertPopulation, assertPinned } from './lib/selfproof.mjs'

const SELF = 'check-import-inert'
const SELF_REL = 'scripts/check-import-inert.mjs'
const ROOT = process.cwd()
const ENTRY = resolve(ROOT, 'scripts/lib/entrypoint.mjs')
const FAULT = process.env.CHECK_IMPORT_INERT_FAULT ?? ''
const ROOTS = ['scripts', 'db', 'docs/surveys']
const SKIP_DIRS = new Set(['node_modules', '.next', 'migrations', 'fixtures', 'tables', 'functions', 'views'])
/** 库:被别的脚本 import 来用的,它们自己不许有顶层语句(否则 import 它们就是在开始做事) */
const LIBRARIES = new Set(['scripts/liveLock.mjs', 'scripts/ephemeral.mjs'])
/** 从 ephemeral.mjs 里 import 这几支之一 = 要起一次性账号、开清理计划 —— 对着线上动手 */
const LIVE_FNS = new Set(['mintThrowaway', 'openPlan', 'reapStalePlans', 'runPlan', 'installExitHooks', 'exitAfterCleanup', 'planDelete'])
const LIVE_LITERAL = /SUPABASE_SERVICE_ROLE_KEY|pooler\.supabase\.com|new-era-erp\.vercel\.app/

function* walk(dir) {
    for (const n of readdirSync(dir)) {
        const p = join(dir, n)
        if (statSync(p).isDirectory()) { if (!SKIP_DIRS.has(n)) yield* walk(p) }
        else if (n.endsWith('.mjs')) yield p
    }
}
const parse = (src) => acorn.parse(src, { ecmaVersion: 'latest', sourceType: 'module', allowHashBang: true })

/** 递归走一遍 AST,对每一个节点调 fn */
function visit(node, fn) {
    if (!node || typeof node.type !== 'string') return
    fn(node)
    for (const k of Object.keys(node)) {
        const v = node[k]
        if (Array.isArray(v)) for (const x of v) visit(x, fn)
        else if (v && typeof v === 'object' && typeof v.type === 'string') visit(v, fn)
    }
}

/** 这一支是不是对着线上动手。返回命中的理由(空 = 不是)。 */
export function liveReasons(ast, src) {
    const why = []
    for (const n of ast.body) {
        if (n.type !== 'ImportDeclaration') continue
        const s = String(n.source.value)
        if (s.endsWith('liveLock.mjs')) why.push('imports liveLock.mjs')
        if (s.endsWith('ephemeral.mjs') && n.specifiers.some((x) => LIVE_FNS.has(x.imported?.name))) why.push('imports a throwaway / cleanup-plan function from ephemeral.mjs')
    }
    visit(ast, (n) => {
        if (n.type === 'ImportExpression') {
            const t = src.slice(n.source.start, n.source.end)
            if (/liveLock\.mjs|ephemeral\.mjs/.test(t)) why.push('dynamically imports liveLock / ephemeral')
        }
        if (n.type === 'Literal' && (typeof n.value === 'string' || n.regex) && LIVE_LITERAL.test(n.regex ? n.regex.pattern : n.value)) why.push('names a live credential / host in a literal')
        if (n.type === 'TemplateElement' && LIVE_LITERAL.test(n.value.raw)) why.push('names a live credential / host in a template')
    })
    return [...new Set(why)]
}

/** 静态规矩:import 之后的第一句是 onlyWhenRunDirectly(import.meta.url),而且它 import 自 scripts/lib/entrypoint.mjs。返回违反(空 = 守着)。 */
export function guardProblems(ast, file) {
    const out = []
    const imp = ast.body.find((n) => n.type === 'ImportDeclaration'
        && n.specifiers.some((x) => x.imported?.name === 'onlyWhenRunDirectly' && x.local?.name === 'onlyWhenRunDirectly'))
    if (!imp) out.push('does not import onlyWhenRunDirectly')
    else if (resolve(dirname(file), String(imp.source.value)) !== ENTRY) out.push(`imports onlyWhenRunDirectly from ${imp.source.value}, not scripts/lib/entrypoint.mjs`)
    const first = ast.body.find((n) => n.type !== 'ImportDeclaration')
    const ok = first && first.type === 'ExpressionStatement' && first.expression.type === 'CallExpression'
        && first.expression.callee.type === 'Identifier' && first.expression.callee.name === 'onlyWhenRunDirectly'
        && first.expression.arguments.length === 1 && first.expression.arguments[0].type === 'MemberExpression'
        && first.expression.arguments[0].object.type === 'MetaProperty' && first.expression.arguments[0].property.name === 'url'
    if (!ok) out.push('the first statement after the imports is not onlyWhenRunDirectly(import.meta.url)')
    return out
}

/** 库的规矩:没有顶层语句(只有 import / 声明 / 导出),声明里也不许 await */
function libraryProblems(ast, src) {
    const bad = ast.body.filter((n) => !['ImportDeclaration', 'ExportNamedDeclaration', 'ExportDefaultDeclaration', 'FunctionDeclaration',
        'ClassDeclaration', 'VariableDeclaration'].includes(n.type)
        || (n.type === 'VariableDeclaration' && /\bawait\b/.test(src.slice(n.start, n.end))))
    return bad.map((n) => `top-level ${n.type} at offset ${n.start} — a library must not start anything when imported`)
}

// ── 动态那一层:在一个装了拦截的子进程里逐支 import ────────────────────────────
const TRAP = `
import { syncBuiltinESMExports } from 'node:module'
import cp from 'node:child_process'
import fs from 'node:fs'
import net from 'node:net'
import tls from 'node:tls'
import http from 'node:http'
import https from 'node:https'
globalThis.__attempts = []
const trap = (what) => function () { globalThis.__attempts.push(what); throw new Error('TRAPPED|' + what) }
for (const k of ['spawn', 'spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork']) cp[k] = trap('child_process.' + k)
for (const k of ['writeFileSync', 'appendFileSync', 'mkdirSync', 'rmSync', 'unlinkSync', 'renameSync', 'createWriteStream', 'writeFile', 'appendFile'])
    fs[k] = trap('fs.' + k)
const openSync = fs.openSync
fs.openSync = function (p, flags, ...rest) { if (flags && String(flags) !== 'r') { globalThis.__attempts.push('fs.openSync:' + flags); throw new Error('TRAPPED|fs.openSync') } return openSync.call(this, p, flags, ...rest) }
net.connect = trap('net.connect'); net.createConnection = trap('net.createConnection')
net.Socket.prototype.connect = trap('net.Socket#connect')
tls.connect = trap('tls.connect')
for (const k of ['writeFile', 'appendFile', 'mkdir', 'rm', 'unlink', 'rename', 'open']) fs.promises[k] = trap('fs.promises.' + k)
http.request = trap('http.request'); http.get = trap('http.get'); https.request = trap('https.request'); https.get = trap('https.get')
syncBuiltinESMExports()
globalThis.fetch = trap('fetch')
globalThis.WebSocket = function () { globalThis.__attempts.push('WebSocket'); throw new Error('TRAPPED|WebSocket') }
process.exit = function (c) { globalThis.__attempts.push('process.exit(' + c + ')'); throw new Error('TRAPPED|process.exit') }
process.on('unhandledRejection', () => {})
`
const RUNNER = `
const files = JSON.parse(process.env.INERT_FILES)
for (const f of files) {
    const before = globalThis.__attempts.length
    let outcome = 'resolved'
    try { await import(f) } catch (e) { outcome = e && e.code === 'NOT_RUN_ON_IMPORT' ? 'NOT_RUN_ON_IMPORT' : 'threw:' + String(e && e.message || e).slice(0, 160) }
    await new Promise((r) => setTimeout(r, 30))   // 给异步开始的东西一个机会露头(一支顶层 main() 的第一个 await 之后)
    process.stdout.write(JSON.stringify({ f, outcome, attempts: globalThis.__attempts.slice(before) }) + '\\n')
}
process.stdout.write('INERT_DONE\\n')
`
function importInSandbox(files) {
    const dir = mkdtempSync(join(tmpdir(), 'inert-'))
    try {
        writeFileSync(join(dir, 'trap.mjs'), TRAP)
        writeFileSync(join(dir, 'runner.mjs'), RUNNER)
        const r = spawnSync(process.execPath, ['--disable-warning=MODULE_TYPELESS_PACKAGE_JSON', '--import', pathToFileURL(join(dir, 'trap.mjs')).href,
            join(dir, 'runner.mjs')], { cwd: ROOT, env: { ...process.env, INERT_FILES: JSON.stringify(files.map((f) => pathToFileURL(f).href)) },
            encoding: 'utf8', timeout: 120000 })
        const lines = (r.stdout ?? '').split('\n').filter(Boolean)
        const done = lines.includes('INERT_DONE')
        const rows = lines.filter((l) => l.startsWith('{')).map((l) => JSON.parse(l))
        return { done, rows, status: r.status, stderr: (r.stderr ?? '').slice(-600) }
    } finally { rmSync(dir, { recursive: true, force: true }) }
}

// ════════════════════════════════════════════════════════════════════════════
// 自证:每一次运行都先证明两层都看得见它们要看的东西
// ════════════════════════════════════════════════════════════════════════════
const blind = []
{
    const dir = mkdtempSync(join(tmpdir(), 'inert-self-'))
    try {
        const unguardedSpawn = join(dir, 'unguarded-spawn.mjs')
        const unguardedFetch = join(dir, 'unguarded-fetch.mjs')
        const guarded = join(dir, 'guarded.mjs')
        writeFileSync(unguardedSpawn, `import { spawn } from 'node:child_process'\nspawn('true')\n`)
        writeFileSync(unguardedFetch, `async function main() { await fetch('https://example.invalid/') }\nmain()\n`)
        writeFileSync(guarded, `import { onlyWhenRunDirectly } from ${JSON.stringify(pathToFileURL(ENTRY).href)}\nonlyWhenRunDirectly(import.meta.url)\nimport('node:child_process').then((m) => m.spawn('true'))\n`)
        const r = importInSandbox([unguardedSpawn, unguardedFetch, guarded])
        const by = Object.fromEntries(r.rows.map((x) => [x.f, x]))
        const at = (f) => by[pathToFileURL(f).href]
        if (!r.done) blind.push(`self-proof: the sandbox did not finish (status ${r.status}) ${r.stderr}`)
        if (!(at(unguardedSpawn)?.attempts ?? []).some((a) => a.startsWith('child_process.spawn'))) blind.push('self-proof: an unguarded top-level spawn was NOT trapped — the dynamic layer is blind')
        if (!(at(unguardedFetch)?.attempts ?? []).includes('fetch')) blind.push('self-proof: an unguarded top-level fetch was NOT trapped — the dynamic layer is blind')
        if (at(guarded)?.outcome !== 'NOT_RUN_ON_IMPORT' || (at(guarded)?.attempts ?? []).length) blind.push(`self-proof: a guarded script should refuse with NOT_RUN_ON_IMPORT and attempt nothing, got ${JSON.stringify(at(guarded))}`)
    } finally { rmSync(dir, { recursive: true, force: true }) }
    const second = parse(`import { onlyWhenRunDirectly } from './lib/entrypoint.mjs'\nimport { acquireOrExit } from './liveLock.mjs'\nconst x = 1\nonlyWhenRunDirectly(import.meta.url)\n`)
    if (guardProblems(second, join(ROOT, 'scripts/x.mjs')).length === 0) blind.push('self-proof: a guard in the SECOND statement was accepted — the static layer is blind')
    if (liveReasons(second, `import { acquireOrExit } from './liveLock.mjs'`).length === 0) blind.push('self-proof: a script importing liveLock.mjs was not recognised as acting on live — the classifier is blind')
    const plain = parse(`import { readFileSync } from 'node:fs'\nconsole.log(readFileSync('x'))\n`)
    if (liveReasons(plain, '').length !== 0) blind.push('self-proof: a script that touches nothing live was classified as acting on live')
}
if (blind.length) {
    console.error(`✗ ${SELF}:本检查瞎了 —— 它此刻报的"干净"不作数`)
    for (const b of blind) console.error('   · ' + b)
    process.exit(3)
}

// ════════════════════════════════════════════════════════════════════════════
// 本体
// ════════════════════════════════════════════════════════════════════════════
const problems = []
const live = []
let scanned = 0
for (const r of ROOTS) {
    for (const f of walk(join(ROOT, r))) {
        const rel = relative(ROOT, f)
        let src = readFileSync(f, 'utf8')
        if (FAULT === `unguard:${rel}`) src = src.replace(/^onlyWhenRunDirectly\(import\.meta\.url\)\s*$/m, '')
        let ast
        try { ast = parse(src) } catch (e) { problems.push(`${rel}: does not parse (${e.message}) — it cannot be judged`); continue }
        scanned++
        if (rel.startsWith('scripts/lib/')) continue
        if (rel === SELF_REL) continue          // 我自己的 LIVE_LITERAL 正则里写着那几个名字 —— 那是判据,不是对线上动手
        if (LIBRARIES.has(rel)) { for (const p of libraryProblems(ast, src)) problems.push(`${rel}: ${p}`); continue }
        const why = liveReasons(ast, src)
        if (!why.length) continue
        live.push(f)
        for (const p of guardProblems(ast, f)) problems.push(`${rel}: ${p} (it acts on live: ${why.join('; ')})`)
    }
}
assertPopulation(SELF, 'scripts/ · db/ · docs/surveys/ 下解析过的 .mjs', scanned)
assertPopulation(SELF, '认出来的、对着线上动手的脚本', live.length)
if (!live.some((f) => relative(ROOT, f) === 'scripts/smoke-routes.mjs')) problems.push('scripts/smoke-routes.mjs was not recognised as acting on live — the classifier missed the one the fold-in names')

// 动态:真的 import 每一支(静态那一层已经红了的照样 import —— 拦截保证它们做不成任何事)
const dyn = importInSandbox(live)
if (!dyn.done) problems.push(`the import sandbox did not finish (status ${dyn.status}): ${dyn.stderr}`)
assertPinned(SELF, '动态那一层 import 过的 ↔ 认出来的', dyn.rows.length, live.length, '少了的那几支没有被 import 过 —— 它们"什么都不开始"没有被证明。')
for (const x of dyn.rows) {
    const rel = relative(ROOT, new URL(x.f).pathname)
    if (x.attempts.length) problems.push(`${rel}: importing it TRIED TO START SOMETHING: ${x.attempts.join(', ')} (trapped; nothing ran)`)
    if (x.outcome !== 'NOT_RUN_ON_IMPORT') problems.push(`${rel}: importing it should refuse with NOT_RUN_ON_IMPORT, got ${x.outcome}`)
}

if (problems.length) {
    console.error(`✗ ${SELF}:${problems.length} 处`)
    for (const p of problems) console.error('   · ' + p)
    console.error('☞ 修法:在那一支 import 之后的第一句写 onlyWhenRunDirectly(import.meta.url)(import 自 scripts/lib/entrypoint.mjs)。')
    process.exit(1)
}
console.log(`✓ ${SELF}:${live.length} 支对着线上动手的脚本(在 ${scanned} 支 .mjs 里认出),每一支 import 之后的第一句都是守卫;`
    + `逐支真的 import 过,${dyn.rows.length} 支都以 NOT_RUN_ON_IMPORT 拒绝、拦下的尝试 0 次。自证 6 格全部咬人。`)
