#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// NARROW-COVERAGE-1(2026-09-09)· 每一支量具都要说得出【它自己在看什么】
// ════════════════════════════════════════════════════════════════════════════
// 【为什么它必须是一道闸,而不是一条约定】
// 本刀落地前实测:31 支 check-*/survey-* 里,**23 支一条覆盖断言都没有**,
// 3 支两向、1 支单向、4 支只有空总体。那个分布就是「靠人记得写」的成绩单。
// 本仓库对这件事有明文门槛(check-auth-error-swallowing 抬头):
// **一条被破了很多次的规矩不再是一条规矩,是一个机制。** 这个文件就是那次替换。
//
// ════════════════════════════════════════════════════════════════════════════
// 【瞄准 · AIM】
//   我读的是      :`scripts/` 下 check-*.mjs 与 survey-*.mjs 的**源码文本**,
//                   以及 `package.json` 的 build 那一串。
//   我声称管的是   :每一支量具都写下了它的瞄准线;构建链里的每一支都带着覆盖断言。
//   两者不同之处   :★★ **我只看得见那三行字【写了】,看不见它们【写得对】。**
//                   一句「我读的是 X」可以是假的,而我永远不会知道 ——
//                   那正是瞄准这一半**不能自动生成**的原因:它要一个人读一遍代码,
//                   然后把两句话并排写下来,看它们是不是同一件事。
//                   ☞ CHECKER-BLIND-SPOTS ④(字体守卫读 coverage.json、文档写
//                     Helvetica)对**任何**机械检查都是隐形的,对这三行字不是。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { assertPinned, assertPopulation } from './lib/selfproof.mjs'

const ROOT = process.cwd()
const DIR = join(ROOT, 'scripts')
const SELF = 'check-instrument-selfproof.mjs'

const names = readdirSync(DIR)
    .filter((n) => /^(check|survey)-.*\.mjs$/.test(n))
    .sort()

// ── 覆盖断言 ①:总体非空,而且两条独立的路数出来一样多 ──────────────────────
// 一条走文件名筛子,一条走"读得出内容的文件"。都为 0 时下面每一条判据都空转。
const readable = names.filter((n) => {
    try { readFileSync(join(DIR, n), 'utf8'); return true } catch { return false }
})
assertPopulation('check-instrument-selfproof', 'scripts/ 下的 check-*/survey-* 量具', names.length)
assertPinned('check-instrument-selfproof', '按文件名数出的量具 ↔ 真的读得出来的量具',
    names.length, readable.length, '读不出来的那几支等于没有被检查过。')

// ── 构建链:从 package.json 现读,不写死 ──────────────────────────────────────
// 【为什么现读】写死一份名单就是同一件事的第二份陈述,而两份陈述必然漂开 ——
// check-enum-mirrors 的抬头把这条规矩说得最清楚。
const build = JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8')).scripts.build
const inBuild = names.filter((n) => build.includes(`scripts/${n}`))
assertPopulation('check-instrument-selfproof', 'npm run build 里跑到的量具', inBuild.length)

const problems = []
let withAim = 0
let withCoverage = 0

for (const n of names) {
    const src = readFileSync(join(DIR, n), 'utf8')

    // ① 瞄准线 —— 每一支都要有,构建链内外一视同仁(R-Q2 ②)
    const hasMarker = src.includes('【瞄准 · AIM】')
    const hasRead = /我读的是\s*:/.test(src) || /我读的是\s+:/.test(src)
    const hasGovern = /我声称管的是\s*:/.test(src) || /我声称管的是\s+:/.test(src)
    if (hasMarker && hasRead && hasGovern) withAim++
    else {
        problems.push(
            `${n}:缺【瞄准 · AIM】那三行` +
            `(标记 ${hasMarker ? '有' : '无'} · 「我读的是」${hasRead ? '有' : '无'} · ` +
            `「我声称管的是」${hasGovern ? '有' : '无'})`
        )
    }

    // ② 覆盖断言 —— 只要求【构建链里的】那些带(R-Q3:按构建链划线)
    if (n === SELF || inBuild.includes(n)) {
        const usesSelfproof = /from '\.\/lib\/selfproof\.mjs'/.test(src)
        const ownAssertion = /覆盖断言|coverage/i.test(src)
        if (usesSelfproof || ownAssertion) withCoverage++
        else problems.push(`${n}:在构建链里,却没有任何覆盖断言 —— 它报 0 条时说不出自己有没有在看。`)
    }
}

// ── 覆盖断言 ②:上面那个循环真的跑了每一支 ──────────────────────────────────
assertPinned('check-instrument-selfproof', '量具总数 ↔ 判过瞄准线的量具数',
    names.length, withAim + problems.filter((p) => p.includes('缺【瞄准')).length,
    '对不上就是上面那个循环漏掉了文件。')

// ★【本刀自己在这里栽了一次,记下来】把本支接进构建链之后,SELF 也成了 inBuild
//   的一员,而这一行原本写的是 `inBuild.length + 1` —— 于是它把自己数了两遍,
//   当场 exit 2。**一个"加一"的常量,前提是"它不在那份名单里",而那个前提变了。**
//   与 AGENTS.md 那条「一道闸只守它当时那条路」同形:名单变了,常量没跟上。
//   用集合去重,前提就不必再成立。
const expectCoverage = new Set([...inBuild, SELF]).size
assertPinned('check-instrument-selfproof', '应当带覆盖断言的量具 ↔ 判过的',
    expectCoverage,
    withCoverage + problems.filter((p) => p.includes('没有任何覆盖断言')).length,
    '对不上就是覆盖断言那一段漏判了。')

if (problems.length) {
    console.error(`✗ check-instrument-selfproof:${problems.length} 处`)
    for (const p of problems) console.error(`   · ${p}`)
    console.error('')
    console.error('【瞄准线怎么写】三行,写在文件抬头:')
    console.error('   //   我读的是      :<这支脚本【实际】解析的那个东西>')
    console.error('   //   我声称管的是   :<它的名字/抬头说它在管的那件事>')
    console.error('   //   两者不同之处   :<两者不是同一个东西时,就地说明白>')
    console.error('☞ 这三行【不许自动生成】。能自动生成的话,它就抓不住')
    console.error('  CHECKER-BLIND-SPOTS ④ 那一类了 —— 那道守卫读的是另一个对象,')
    console.error('  而它每一次致盲注入都照常变红。')
    process.exit(1)
}

console.log(
    `✓ check-instrument-selfproof:${names.length} 支量具都写了瞄准线;` +
    `其中 ${expectCoverage} 支(构建链里的,含本支)都带着覆盖断言。`
)
