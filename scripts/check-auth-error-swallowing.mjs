#!/usr/bin/env node
// scripts/check-auth-error-swallowing.mjs
//
// ════════════════════════════════════════════════════════════════════════════
// 【它回答一个问题,而且只回答那一个】
//     **`auth.getUser()` 的 `error` 有没有被接住?**
//
// 接不住的后果不是少一句日志。`getUser()` 失败时 `user` 也是 `null`,于是
// **【认证够不着】与【这个人真的没登录】走同一条分支** —— 而那条分支通常是
// "把人踢到登录页"或"什么都不渲染"。判词说出了一个它根本没有确立的原因。
//
// 这条规矩本仓库写下过两次,都在认证【之外】的层:
//   * `lib/permissions.ts:37` —— 【查询失败 ≠ 这个人没有权限】;
//   * `lib/db-helpers.ts` 的 `mustRows` —— 【一次失败不是一个空集】。
// SESSION-1(2026-08-23)在认证这一层普查:**51 处调用,51 处丢掉 error。**
// 一条被破了 51 次的规矩不再是一条规矩,是一个机制 —— 这个文件就是那次替换。
//
// ────────────────────────────────────────────────────────────────────────────
// 【实测:三类是分得开的,所以"接住 error"是一件做得到的事,不是一句口号】
// (SESSION-1,一次性账号,已删。完整七情形表在 lib/supabase/middleware.ts 抬头)
//
//   AuthRetryableFetchError      → 判断不出(网络抛错 status=0、上游 5xx)
//   AuthApiError / AuthSessionMissingError → 确立的否定
//   无 error 且有 user           → 已登录
//
// ────────────────────────────────────────────────────────────────────────────
// 【它看得见什么】
//   ✓ `app/` 与 `lib/` 下 .ts / .tsx 里的 `auth.getUser()`
//   ✓ 解构里绑了 `error`                      → 算【接住了】
//   ✓ `const x = await …getUser()` 且随后 5 行内出现 `x.error` → 算【接住了】
//
// 【它看不见什么 —— 点名,不含糊。这一段比上面三行重要。】
//   ✗ **绑了 error 却从不用它**,它分不出来。`const { data, error } = …` 之后
//     再也不提 error 的写法,在本检查眼里是绿的。**它检查的是"有没有接住",
//     不是"接住之后有没有据此分支"** —— 后者要读控制流,那是另一个工具。
//   ✗ **`Promise.all` 里那种把整个结果绑成一个名字的写法**,它判不准。
//     实测的实例点名在此:`app/hr/reviews/[id]/page.tsx` 把 `getUser()` 塞进
//     `Promise.all`,绑成 `userRes`,然后只读 `userRes.data.user?.id ?? null`
//     —— **error 那一半一个字都没提**。本检查把它算作【没接住】并计进基线,
//     这是刻意的:宁可把一处存疑的算进债里,也不要让下一刀拿到一个偏小的数。
//   ✗ **`getSession()` / `getClaims()`** —— 本检查只看 `getUser()`。
//   ✗ **动态构造的调用**(`sb['auth']['getUser']()` 之类)。
//   ✗ **它不判断"接住之后处理得对不对"** —— 把 `AuthRetryableFetchError` 当成
//     "没登录"照样是本仓库那条病,而本检查看不出来。那一条靠人读代码,
//     以及 docs/manual-walk-list.md §14。
//
// ────────────────────────────────────────────────────────────────────────────
// 【它怎么拦人:一条只能往下走的棘轮】
//   落地时 app/ 与 lib/ 里【已经】有 49 处没接住(SESSION-1 修掉了中间件与
//   TopNav 那两处,其余原样在册)。一次改完不是本刀的事 —— 每一处的"判断不出
//   时该怎么办"是**各自不同的判断**:Route Handler 今天回 401、TopNav 曾经
//   什么都不画、动作里写 `user?.id ?? null`(于是一次瞬时故障静默记下一行
//   【没有作者】的数据)。49 个判断塞进发现它们的这一刀,正是 AGENTS.md 点名的
//   "匆忙写出来的检查"的由来。
//
//   所以判词是**增量**的:基线记着每个【文件】今天有几处没接住,**多一处就红**,
//   少了只提示可以收紧。
//
//   **基线的键是【文件】,不是【文件 · 行号】** —— 行号会因为任何一次无关的编辑
//   而漂移,而一个天天误报的基线,最后会被人删掉(GO-1 为这一条付过账,
//   scripts/masked-reads-baseline.json 的键也是这么定的)。
//
// 【为什么进 npm run build,不进 db/gate.py】它只需要仓库里已经有的文件,
//   毫秒级,不需要服务器也不需要数据库。AGENTS.md 那条"一条正确的检查放错了
//   相位就是一条慢检查"已经有四个实例(check_mirrors、--reach、
//   preflightIdSources、以及本条)。gate 实测 300–650 秒,而**一道慢闸门
//   最后会变成一道没人跑的闸门**。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs'
import { join, relative } from 'node:path'

const ROOT = process.cwd()
const SCAN_DIRS = ['app', 'lib']
const BASELINE = join(ROOT, 'scripts/auth-error-baseline.json')

function walk(dir, out = []) {
    for (const e of readdirSync(dir)) {
        const p = join(dir, e)
        if (statSync(p).isDirectory()) walk(p, out)
        else if (/\.(ts|tsx)$/.test(e)) out.push(p)
    }
    return out
}

/** 这一处 getUser() 的 error 接住了吗?两种写法都算接住,其余一律不算。 */
function handlesError(lines, idx, callCol) {
    const line = lines[idx]
    // 写法一:解构里绑了 error —— 解构可能跨行,所以从最近的 const/let 往回找。
    let start = idx
    while (start > 0 && !/\b(const|let|var)\b/.test(lines[start])) start--
    const decl = lines.slice(start, idx + 1).join(' ')
    const lhs = decl.slice(0, decl.indexOf('await') === -1 ? decl.length : decl.indexOf('await'))
    if (/\berror\b/.test(lhs)) return true

    // 写法二:`const x = await …getUser()`,随后几行读 `x.error`。
    const m = lhs.match(/\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=/)
    if (m) {
        const name = m[1]
        const after = lines.slice(idx, idx + 6).join('\n')
        if (new RegExp(`\\b${name}\\.error\\b`).test(after)) return true
    }
    // 写法三(点名的盲区):Promise.all 里裸着的 `supabase.auth.getUser(),`
    // —— 绑的是整个结果数组,判不准。按【没接住】计,理由见抬头。
    void callCol
    void line
    return false
}

const files = SCAN_DIRS.flatMap((d) => walk(join(ROOT, d)))
const unchecked = []
let total = 0

for (const f of files) {
    const rel = relative(ROOT, f)
    const lines = readFileSync(f, 'utf8').split('\n')
    lines.forEach((line, i) => {
        // 注释行不算 —— PROC-CLEANUP 的教训:一个按文本找副本的检测器分不出
        // 代码与注释,而"我修好了它"的注释恰恰会让那个对象看起来仍然有罪。
        if (/^\s*(\/\/|\*|\/\*)/.test(line)) return
        const col = line.indexOf('auth.getUser()')
        if (col === -1) return
        total++
        if (!handlesError(lines, i, col)) unchecked.push({ file: rel, line: i + 1, text: line.trim() })
    })
}

const counts = new Map()
for (const h of unchecked) counts.set(h.file, (counts.get(h.file) ?? 0) + 1)

if (process.argv.includes('--update-baseline')) {
    const obj = Object.fromEntries([...counts].sort((a, b) => a[0].localeCompare(b[0])))
    writeFileSync(BASELINE, JSON.stringify(obj, null, 2) + '\n')
    console.log(`✓ 基线已刷新:${counts.size} 个文件,共 ${unchecked.length} 处没接住(总调用 ${total} 处)。`)
    process.exit(0)
}

let base
try {
    base = JSON.parse(readFileSync(BASELINE, 'utf8'))
} catch {
    console.error('✗ check-auth-error-swallowing:读不到基线 scripts/auth-error-baseline.json。')
    console.error('  读不到【不是】空基线 —— 那会把 49 处历史债当成 49 处新债,')
    console.error('  于是每一次构建都红,而人会学会跳过这道门。')
    console.error('  头一次生成:node scripts/check-auth-error-swallowing.mjs --update-baseline')
    process.exit(2)
}

const added = []
const gone = []
for (const [k, n] of counts) {
    const was = base[k] ?? 0
    if (n > was) added.push({ k, was, now: n })
}
for (const k of Object.keys(base)) {
    if ((counts.get(k) ?? 0) < base[k]) gone.push({ k, was: base[k], now: counts.get(k) ?? 0 })
}

console.log('== auth.getUser() 的 error 有没有被接住 ==')
console.log('   判词:**丢掉 error,「认证够不着」与「这个人没登录」就走同一条分支。**')
console.log('   它【不】断言"接住之后处理得对" —— 那要读控制流(抬头写着为什么)。')
console.log(`   ${total} 处调用,其中 ${unchecked.length} 处没接住(在册,见 docs/known-issues.md 的 AUTH-ERROR-SWALLOWED 条)。`)
console.log('')

if (gone.length) {
    console.log('· 少了几处 —— 有人改好了,或者文件动了。基线可以收紧:')
    for (const g of gone) console.log(`     ${g.k}   ${g.was} → ${g.now}`)
    console.log('  刷新:node scripts/check-auth-error-swallowing.mjs --update-baseline')
    console.log('')
}

if (added.length === 0) {
    console.log('✓ 没有【新增】丢掉 auth error 的地方。')
    process.exit(0)
}

console.log('✗ 新增了丢掉 auth error 的调用:')
for (const a of added) {
    console.log(`     ${a.k}   (在册 ${a.was} 处,现在 ${a.now} 处)`)
    for (const h of unchecked.filter((x) => x.file === a.k)) {
        console.log(`       第 ${h.line} 行: ${h.text.slice(0, 90)}`)
    }
}
console.log('')
console.log('【怎么改】接住 error,并把它分成三类 —— 判据与实测表在')
console.log('lib/supabase/middleware.ts 的抬头,那里也是本仓库这条规矩的参考实现:')
console.log("      AuthRetryableFetchError                → 判断不出:说出来,不要说「你没登录」")
console.log('      AuthApiError / AuthSessionMissingError  → 确立的否定:可以按没登录处理')
console.log('      无 error 且有 user                      → 已登录')
console.log('')
console.log('【确实不该接的话】(极少见)—— 先把这一处连同理由记进 docs/known-issues.md,')
console.log('然后 --update-baseline。**不要**为了让门变绿而直接刷新基线:')
console.log('那是把债划掉,不是还债。')
process.exit(1)
