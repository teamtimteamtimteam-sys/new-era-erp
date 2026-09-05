#!/usr/bin/env node
// scripts/assert-home-greeting.mjs
// ════════════════════════════════════════════════════════════════════════════
// UI-1b(2026-09-05)· 问候语的两条断言 —— 时钟,与"不重样"
// ════════════════════════════════════════════════════════════════════════════
//
// ★ 这是一支【断言】,不是普查:它退非零。★ 手动跑,也可以进任何一条流水线。
//     node scripts/assert-home-greeting.mjs
//   它自己会用三个不同的 TZ 重跑自己(见下),所以不需要外面套 shell。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【断言一:说"早上"必须是【读的人】的早上,而不是服务器的】★★
// ════════════════════════════════════════════════════════════════════════════
//
// 这一条要防的东西在这个仓库里发生过:CONV-7 ② 用 `toISOString().slice(0,10)`
// 当业务日期,于是新加坡每天 00:00–08:00 之间,财务 Overview 有两条腿画成
// 「答不上来」——(lib/format.ts:67 整段)。**一句「Good morning」在 TZ=UTC 的
// 机器上会在新加坡的下午四点出现,是同一个病换了件衣服。**
//
// 【它怎么证明,而不是被相信】`slotFor(instant, tz)` 是纯函数,两个入参都显式。
// 于是这支脚本**把自己用三个 TZ 各跑一遍**(UTC / America/Los_Angeles /
// Asia/Singapore),断言同一个瞬间在三处得到同一个时段。
//
//   判据那一刻:**2026-09-06T15:00:00Z = 新加坡 23:00 = LATE NIGHT。**
//   它选得很刁:那一刻在 UTC 是 15:00(下午),在洛杉矶是 08:00(清晨)。
//   **三个进程 TZ 会给出三个不同的"直觉答案",而正确答案只有一个。**
//
// ★【故障注入过】★ 把 `slotFor(t, tz)` 的第二个实参换成
//   `Intl.DateTimeFormat().resolvedOptions().timeZone`(系统默认),
//   TZ=UTC 那一趟当场报 afternoon ≠ late_night 并退 1。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【断言二:排除上一句,而且排不空】★★
// ════════════════════════════════════════════════════════════════════════════
//
// "每次重挑"若不排除上一句,一个刷两下的人有 1/12 的机会看见同一句 —— 那不算
// 缺陷。真正的缺陷是**排除写错了方向**(排掉了别的、留下了上一句),
// 或者**排到空集**(于是整行不画,而那是把一次缺席渲染成了一个答案)。
// 两条都断言,并且**穷举 roll**:0 到 1 之间取 200 个点,一个都不许命中上一句。
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { slotFor, pickGreeting, GREETING_SLOTS } from '../lib/homeGreetingCore.ts'

const TZS = ['UTC', 'America/Los_Angeles', 'Asia/Singapore']
const SG = 'Asia/Singapore'
const fails = []
const ok = (cond, what) => { if (!cond) fails.push(what) }

// ── 断言一 · a:委托书点名的那一刻,三个 TZ 下都必须是 LATE NIGHT ──────────
const THE_INSTANT = new Date('2026-09-06T15:00:00Z') // = 23:00 SGT
{
    const got = slotFor(THE_INSTANT, SG)
    ok(got === 'late_night',
        `[clock] 2026-09-06T15:00:00Z(=23:00 SGT)应为 late_night,实为 ${got}` +
        `  ← 进程 TZ=${process.env.TZ ?? '(未设)'}`)
}

// ── 断言一 · b:六个时段的【边界】,每个都在两侧各钉一针 ────────────────────
// 边界写成 "HH:MM" 的新加坡本地时刻;用 SGT 是 UTC+8 且【不实行夏令时】这一点
// 把它换算成 Z 时刻(减 8 小时)。这个换算本身也是断言的一部分。
const sgt = (hhmm) => {
    const [h, m] = hhmm.split(':').map(Number)
    const utcH = h - 8
    const day = utcH < 0 ? 5 : 6 // 跨回前一天
    const hh = ((utcH % 24) + 24) % 24
    return new Date(`2026-09-0${day}T${String(hh).padStart(2, '0')}:${String(m).padStart(2, '0')}:00Z`)
}
const BOUNDARIES = [
    ['05:59', 'late_night'], ['06:00', 'early_morning'],
    ['08:59', 'early_morning'], ['09:00', 'morning'],
    ['11:29', 'morning'], ['11:30', 'midday'],
    ['13:29', 'midday'], ['13:30', 'afternoon'],
    ['17:29', 'afternoon'], ['17:30', 'evening'],
    ['21:59', 'evening'], ['22:00', 'late_night'],
    ['00:00', 'late_night'], ['12:00', 'midday'],
]
for (const [hhmm, want] of BOUNDARIES) {
    const got = slotFor(sgt(hhmm), SG)
    ok(got === want, `[clock] SGT ${hhmm} 应为 ${want},实为 ${got}(进程 TZ=${process.env.TZ ?? '(未设)'})`)
}

// 【每个时段都够得着】—— 一个永远选不中的时段等于它不存在,而那不会报错。
{
    const reached = new Set(BOUNDARIES.map(([h]) => slotFor(sgt(h), SG)))
    for (const s of GREETING_SLOTS) ok(reached.has(s), `[clock] 时段 ${s} 在边界表里一次都没被命中 —— 边界表漏了它`)
}

// ── 断言二:排除上一句 ────────────────────────────────────────────────────
{
    const lines = Array.from({ length: 12 }, (_, i) => ({ id: `morning-${String(i + 1).padStart(2, '0')}`, line_en: 'x {name}' }))
    const prev = 'morning-04'
    let hitPrev = 0, nulls = 0
    for (let k = 0; k < 200; k++) {
        const got = pickGreeting(lines, prev, k / 200)
        if (got === null) { nulls++; continue }
        if (got.id === prev) hitPrev++
    }
    ok(hitPrev === 0, `[pick] 上一句被排除失败:200 次里命中 ${hitPrev} 次 ${prev}`)
    ok(nulls === 0, `[pick] 排除之后出现了 ${nulls} 次 null —— 一次缺席被渲染成了一个答案`)

    // 【它必须仍然挑得出别的 11 句,不是死盯一句】
    const seen = new Set(Array.from({ length: 200 }, (_, k) => pickGreeting(lines, prev, k / 200)?.id))
    ok(seen.size === 11, `[pick] 排除一句之后应当还能挑出 11 句,实际只挑出 ${seen.size} 句`)

    // 【只剩一句时【不能】排空】—— 宁可重样,不可空白。
    const one = [{ id: 'only-01', line_en: 'x {name}' }]
    ok(pickGreeting(one, 'only-01', 0.5)?.id === 'only-01',
        '[pick] 只剩一句而它正是上一句时,必须仍然返回它(排空 = 整行不画)')

    // 【cookie 不在(prev = null)时照常挑】
    ok(pickGreeting(lines, null, 0.5) !== null, '[pick] prev=null 时必须照常挑出一句')

    // 【空表返回 null,而调用方据此整行不画】—— 这是合法状态,不是失败。
    ok(pickGreeting([], null, 0.5) === null, '[pick] 空表必须返回 null')
}

// ── 三个 TZ 各跑一遍 ──────────────────────────────────────────────────────
// 顶层跑一次(承载 pick 那一组断言),然后把【自己】用另外两个 TZ 各起一次,
// 只为把 clock 那一组在不同进程时区下再跑一遍。子进程不再递归(RECURSED 哨兵)。
if (!process.env.__HG_RECURSED) {
    const self = fileURLToPath(import.meta.url)
    for (const tz of TZS) {
        try {
            execFileSync(process.execPath, [self], {
                env: { ...process.env, TZ: tz, __HG_RECURSED: '1' },
                stdio: 'pipe',
            })
            console.log(`  ✓ TZ=${tz}`)
        } catch (e) {
            fails.push(`[tz] TZ=${tz} 下断言失败:\n${String(e.stdout ?? '')}${String(e.stderr ?? '')}`)
        }
    }
}

if (fails.length) {
    console.error('\n✗ 问候语断言失败:')
    for (const f of fails) console.error('  · ' + f)
    process.exit(1)
}
if (!process.env.__HG_RECURSED) {
    console.log(`\n✓ 时钟:2026-09-06T15:00:00Z = 23:00 SGT = LATE NIGHT,在 TZ=${TZS.join(' / ')} 下一致`)
    console.log('✓ 时钟:六个时段的 14 处边界全部落对')
    console.log('✓ 选句:上一句 200 次全排除、不排空、只剩一句时不排空、空表返回 null')
}
