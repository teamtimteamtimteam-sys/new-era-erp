#!/usr/bin/env node
// scripts/check-unpaged-reads.mjs
// ════════════════════════════════════════════════════════════════════════════
// GOLIVE-2 第 10 行(Tim 2026-10-22 TABLE-EXPORT-2 Q3 · 2026-10-30 Q1)· 一张会长的表上,不许有一条【不翻页】的读取
// ════════════════════════════════════════════════════════════════════════════
// 【为什么】线上 PostgREST `max_rows = 1000`:一条既不翻页也不封顶的读取拿到第 1,000 行就停,不报错 —— 屏幕上由它算出来的合计、
//   人数、净值就悄悄偏小。GOLIVE-2 把 app/ lib/ 里每一条这样的读取改成经 lib/readAll.ts(一律翻页读、长名单分批、5 万行按名拒);
//   这道闸让下一条新写的读取不把它带回来。
//
// 【瞄准 · AIM】
//   我读的是      :app/ 与 lib/ 下每一个 .ts / .tsx 的 TypeScript AST(判法只在 scripts/unpaged-reads/classify.mjs 一份,
//                   GOLIVE-2 的那一次改写 import 的也是它);scripts/unpaged-reads/bounded-relations.json(不必翻页的关系与理由)·
//                   per-parent-max.json(按父键筛的读取、在年体量种子上量过的一位父亲最多几行)· lib/database.types.ts 的 Functions
//                   (哪几支 .rpc 回一组行)。
//   我声称管的是   :① 每一条 .from('<关系>') / .rpc('<回一组行的函数>') 读取,要么翻了页(.range · readAll · readAllIn)、
//                      要么封了顶(.limit(n),n ≤ 1000)、要么只回一行 / 一个数、要么关系在名单里、要么按一位父亲筛且量过、
//                      要么那一句写着 `unpaged-ok: <理由>`;否则红,并点名文件与行。
//                   ② .limit(n) 而 n > 1000:红(线上照样只给 1,000 行,写的人以为是 n)。
//                   ③ 名单里的关系今天都还被读着(死条目 = 红);每一条 unpaged-ok 都带一句话(空理由 = 红)。
//   两者不同之处   :★ 我看的是【代码怎么问】,不是【库里有几行】—— "会不会长"由名单与年体量种子回答,种子没造到的那一类,
//                     名单之外一律当作会长(宁可多要一次翻页)。
//                   ★ 关系名写成变量的(.from(d.table))我认不出是哪一张,一律要翻页或写理由。
//                   ★ 一条交给变量、之后在同一个函数里 .range 的读取我认得(later);交给别的函数、在函数外面才 .range 的我认不出 ——
//                     那种写 unpaged-ok 说清是谁翻页。
//
// 判据 ④ 覆盖是断言:AST 认出的、起头参数是字符串的 .from / .rpc 个数 = TypeScript 词法扫描器(不建树)数出的个数,逐文件(两条独立的路)。
//
// 故障注入(CHECK_UNPAGED_FAULT=…,每一格都要红在它说的那一行):
//   add:<文件>   在那个文件末尾加一条不翻页的读取 → exit 1 并点名
//   overcap      假装某一处写着 .limit(5000) → exit 1
//   unlist:<关系> 假装名单里没有那一张 → 读它的每一处 exit 1
//   blind        AST 那一路一个文件都不读 → 覆盖断言 exit 2,不许报"干净"
// 两格每次运行都自己跑一遍(不靠人记得):add 与 blind —— 它们没红,本支在检查任何东西之前先红。
import { readFileSync } from 'node:fs'
import { listFiles, loadConfig, scanFile, textCount } from './unpaged-reads/classify.mjs'
import { assertPopulation, assertPinned, assertAllowlistLive } from './lib/selfproof.mjs'

const SELF = 'check-unpaged-reads'
const FAULT = process.env.CHECK_UNPAGED_FAULT ?? ''
const INJECTED = "\nexport async function __unpagedProbe(s: any) { return await s.from('inventory_movements').select('id') }\n"

function run(fault, quiet) {
    const cfg = loadConfig()
    if (fault.startsWith('unlist:')) delete cfg.bounded[fault.slice(7)]
    const files = listFiles()
    let lit = 0, txt = 0
    const bad = [], exempts = [], tally = {}, boundedHit = new Set()
    for (const f of files) {
        let src = readFileSync(f, 'utf8')
        if (fault === `add:${f}`) src += INJECTED
        const t = textCount(src, f)
        txt += t
        if (fault === 'blind') continue
        const { reads, literalCount } = scanFile(f, src, cfg)
        lit += literalCount
        if (literalCount !== t && !quiet) console.error(`  覆盖:${f} AST ${literalCount} · 词法 ${t}`)
        for (const r of reads) {
            let v = r.verdict
            if (fault === 'overcap' && v === 'capped' && !bad.some((b) => b.startsWith('overcap'))) v = 'overcap'
            tally[v] = (tally[v] ?? 0) + 1
            if (v === 'bounded') boundedHit.add(r.rel)
            if (v === 'exempt') {
                exempts.push(`${r.file}:${r.line} ${r.relText} — ${r.reason}`)
                if (!r.reason || r.reason.length < 12) bad.push(`exempt ${r.file}:${r.line}:\`unpaged-ok:\` 后面要有一句理由(实际是「${r.reason ?? ''}」)`)
            }
            if (v === 'UNPAGED') bad.push(`unpaged ${r.file}:${r.line} ${r.kind}('${r.relText}') —— 一张会长的${r.kind === 'rpc' ? '函数结果' : '表'},读取既不翻页也不封顶:改成 readAll(() => …)(lib/readAll.ts),或在那一句写 unpaged-ok: <理由>`)
            if (v === 'overcap') bad.push(`overcap ${r.file}:${r.line} ${r.kind}('${r.relText}') ${r.reason ?? ''} —— 线上一次最多给 1,000 行;要更多就 readAll`)
        }
    }
    return { cfg, files, lit, txt, bad, exempts, tally, boundedHit }
}

// ── 每次运行都自己注入两格(不靠人记得)──────────────────────────────────────
if (!FAULT) {
    const probe = 'lib/readAll.ts'
    const a = run(`add:${probe}`, true)
    if (!a.bad.some((b) => b.includes(probe))) {
        console.error(`✗ ${SELF}:自检失败 —— 往 ${probe} 里加了一条不翻页的读取,判据没有红。它的绿不作数。`)
        process.exit(2)
    }
    const b = run('blind', true)
    if (b.lit === b.txt) {
        console.error(`✗ ${SELF}:自检失败 —— AST 那一路被弄瞎了(0 个文件),覆盖断言却说两边一样多。`)
        process.exit(2)
    }
}

const r = run(FAULT, false)
// ④ 覆盖是断言
assertPopulation(SELF, 'app/ lib/ 下读到的文件', r.files.length, 100)
assertPopulation(SELF, '认出的 .from / .rpc 读取', r.lit, 1000)
assertPinned(SELF, 'AST 认出的字符串关系名 .from/.rpc ↔ 词法扫描器数出的', r.lit, r.txt,
    'AST 少了 = 有一类写法它没走到;多了 = 它把不是读取的东西算了进来。两种都意味着下面的判词不作数。')
assertPopulation(SELF, '回一组行的函数(lib/database.types.ts)', r.cfg.setof.size, 20)
// ③ 名单是活的
if (!FAULT.startsWith('unlist:')) assertAllowlistLive(SELF, 'bounded-relations.json 里的关系', Object.keys(r.cfg.bounded), (k) => r.boundedHit.has(k))

if (r.bad.length) {
    console.error(`✗ ${SELF}:${r.bad.length} 处`)
    for (const b of r.bad) console.error('  ' + b)
    process.exit(1)
}
const order = ['helper', 'paged', 'later', 'capped', 'one', 'head', 'write', 'scalar', 'bounded', 'parent', 'exempt']
console.log(`✓ ${SELF}:${r.lit} 条读取(${r.files.length} 个文件,AST = 词法 = ${r.txt})· ` + order.map((k) => `${k} ${r.tally[k] ?? 0}`).join(' · '))
console.log(`  豁免(unpaged-ok,${r.exempts.length} 处):`)
for (const e of r.exempts) console.log('    ' + e)
