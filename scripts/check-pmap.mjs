#!/usr/bin/env node
// scripts/check-pmap.mjs — 有上限的并发 map,三条性质各钉一条。
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么这三条要断言,而不是"读一遍代码就看得出来"】
// 三条**全部是静默失败**:
//   ① 顺序错位 —— 靠完成顺序对齐下标是这类工具的经典写法错误。错了之后
//      /settings/dictionaries 上每一行旁边的用量都是【别人的】数字,
//      而屏幕上没有任何东西看起来不对。**一个要停用某个值的人会读到别人的用量。**
//   ② 上限失效 —— 全放出去也"能跑",而且跑得更快;它的代价在连接池那边,
//      不在这个页面上。本仓库为打爆连接池付过账(check_mirrors 走池子那一段)。
//   ③ 吞掉 reject —— 把一次查询失败变成一个看起来正常的零,
//      正是 AGENTS.md「失败不是空集」那一条。
//
// 退出码 0 = 全过;1 = 有断言不成立。
// ════════════════════════════════════════════════════════════════════════════
import { pMap, DEFAULT_QUERY_CONCURRENCY } from '../lib/pMap.ts'

let failures = 0
const fails = []
function check(name, cond, detail) {
    if (cond) return
    failures++
    const at = (new Error().stack || '').split('\n')
        .find((l) => l.includes('check-pmap.mjs') && !l.includes('at check '))
    const loc = at ? at.replace(/^.*?\(?(scripts\/check-pmap\.mjs:\d+:\d+)\)?\s*$/, '$1') : '?'
    fails.push(`${loc}  ${name}${detail ? ` —— ${detail}` : ''}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// ── ① 顺序:结果按【输入顺序】,不是完成顺序 ────────────────────────────────
//    故意让先入的慢、后入的快 —— 靠完成顺序对齐的实现在这里必然错位。
{
    const input = [50, 40, 30, 20, 10, 0]
    const out = await pMap(input, 3, async (ms) => { await sleep(ms); return ms })
    check('①-a 返回顺序 = 输入顺序(不是完成顺序)',
        JSON.stringify(out) === JSON.stringify(input), `got=${JSON.stringify(out)}`)
    const idx = await pMap(input, 3, async (_, i) => i)
    check('①-b 下标传得对', JSON.stringify(idx) === '[0,1,2,3,4,5]', `got=${JSON.stringify(idx)}`)
}

// ── ② 上限:任何时刻在飞的不超过 limit ──────────────────────────────────────
{
    for (const limit of [1, 3, 12]) {
        let inFlight = 0, peak = 0
        await pMap(Array.from({ length: 40 }, (_, i) => i), limit, async () => {
            inFlight++; peak = Math.max(peak, inFlight)
            await sleep(5)
            inFlight--
        })
        check(`②-a limit=${limit} 时峰值并发 ≤ ${limit}`, peak <= limit, `peak=${peak}`)
        check(`②-b limit=${limit} 时确实并发了(不是退化成串行)`,
            limit === 1 ? peak === 1 : peak > 1, `peak=${peak}`)
    }
}

// ── ③ 失败要向外抛,不许吞 ────────────────────────────────────────────────
{
    let threw = null
    try {
        await pMap([1, 2, 3, 4], 2, async (n) => {
            if (n === 3) throw new Error('BOOM')
            await sleep(5); return n
        })
    } catch (e) { threw = e }
    check('③-a 一个 reject 会向外 reject', threw instanceof Error && threw.message === 'BOOM',
        `threw=${threw && threw.message}`)
}

// ── ④ 边界 ────────────────────────────────────────────────────────────────
{
    check('④-a 空输入返回空数组', JSON.stringify(await pMap([], 4, async () => 1)) === '[]')
    // limit 比长度大时不该起一堆立刻退出的工人,也不该崩
    check('④-b limit > 长度 也对', JSON.stringify(await pMap([1, 2], 99, async (n) => n * 2)) === '[2,4]')
    let bad = null
    try { await pMap([1], 0, async () => 1) } catch (e) { bad = e }
    check('④-c limit < 1 按名拒绝(而不是静默死循环或空转)',
        bad instanceof Error && /limit/.test(bad.message), `threw=${bad && bad.message}`)
    check('④-d 默认上限是一个 ≥1 的数', Number.isInteger(DEFAULT_QUERY_CONCURRENCY) && DEFAULT_QUERY_CONCURRENCY >= 1,
        `DEFAULT=${DEFAULT_QUERY_CONCURRENCY}`)
}

// ── ⑤ 页面那一场的形状:79 个探针、上限 12 → 墙上时间该是【批数】而不是【和】 ──
{
    const N = 79, PER = 20
    const t0 = Date.now()
    await pMap(Array.from({ length: N }, (_, i) => i), DEFAULT_QUERY_CONCURRENCY, () => sleep(PER))
    const ms = Date.now() - t0
    const serial = N * PER                                    // 1580ms
    const batches = Math.ceil(N / DEFAULT_QUERY_CONCURRENCY) * PER // 140ms
    check('⑤-a 墙上时间接近【批数 × 一次往返】,不是【次数 × 一次往返】',
        ms < serial / 3, `ms=${ms} 串行=${serial} 理论批=${batches}`)
}

if (failures) {
    console.error(`✗ check-pmap:${failures} 条断言不成立`)
    for (const f of fails) console.error(`   · ${f}`)
    process.exit(1)
}
console.log('✓ check-pmap:顺序 / 上限 / 失败外抛 / 边界 / 批数,全部按名成立')
