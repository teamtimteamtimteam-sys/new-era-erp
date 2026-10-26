#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// TABLE-FEATURES-3(Tim 2026-10-26 Q4):批量动作的结果名单,本地证明 —— 一批里有做成的、有被拒的
// ════════════════════════════════════════════════════════════════════════════
// Q4 的裁定:结果名单在【本地】用一批"有做成、有被拒"的项证明;线上只摆出批量条与全选,什么都不按。
// 这里跑的是条子真正用的那一份 lib/bulkRun.ts(Node 自己剥类型,不另抄一份):
//   R1  一次一项、按屏幕先后:动作被调用的次序 = 屏幕次序(不是勾选次序),而且一次只有一项在跑(没有并发)
//   R2  结果名单逐项:做成的 done;被拒的带【它自己的】理由与细节(两项被拒、理由不同,各归各)
//   R3  一项抛了(请求没到)→ 那一项是被拒、理由是调用方给的人话、原文进 detail;后面的项照跑
//   R4  一项被拒不停下:被拒之后的那一项仍然做成
//   R5  全选只勾屏幕上的:屏幕外的选择不保留;已全选再按 → 全部取消
//   F   ★ 故障注入:一个"遇拒即停"的跑法让 R4 变红 —— 这条断言看得见它要证的那件事
// 判决只认最后一行 `BULK_RUN_EXIT=`:0 = 全 PASS · 1 = 有 FAIL。不连库、不起服务。
//
// 【瞄准 · AIM】
//   我读的是      :lib/bulkRun.ts 的三支纯函数(runOneAtATime · selectedInScreenOrder · toggleAllOnScreen),喂一个替身动作。
//   我声称管的是   :批量条的结果名单 —— 每一项「做成了」或「被拒了 + 它自己的理由」,一次一项,遇拒不停,全选只勾屏幕上的。
//   两者不同之处   :★ 我不渲染 React —— 条子(app/components/ui/bulk-decision-bar.tsx)把 runOneAtATime 的结果原样一项一行画出来,
//                   那一层(data-slot="bulk-results")由线上证明看它摆着,不按;★ 替身动作不是库:四眼与 CFO 档位【按项判】
//                   这件事由线上回滚证明(db/scripts/2026-10-26-table-features-3-live-proof.mjs)在真函数上证。
// ════════════════════════════════════════════════════════════════════════════
import { runOneAtATime, selectedInScreenOrder, toggleAllOnScreen } from '../lib/bulkRun.ts'

let bad = 0
const ok = (c, what) => { console.log(`${c ? 'PASS' : 'FAIL'}|${what}`); if (!c) bad++; return c }

const screen = [
    { id: 'a', label: 'JR-2026-0101' },
    { id: 'b', label: 'JR-2026-0102' },
    { id: 'c', label: 'JR-2026-0103' },
    { id: 'd', label: 'JR-2026-0104' },
    { id: 'e', label: 'JR-2026-0105' },
]
// 勾选的先后故意与屏幕先后不同
const ticked = new Set(['e', 'c', 'a', 'b'])
const chosen = selectedInScreenOrder(screen, ticked)

// 单项动作的替身:a 做成 · b 被四眼拒 · c 抛(请求没到)· e 被 CFO 档位拒 —— 与真动作同一个回给界面的形状
const calls = []
let inFlight = 0, maxInFlight = 0
const act = async (item) => {
    calls.push(item.id)
    inFlight++; maxInFlight = Math.max(maxInFlight, inFlight)
    await new Promise((r) => setTimeout(r, 5))
    inFlight--
    if (item.id === 'b') return { error: 'You raised this request yourself — someone else must approve it.', detail: 'SELF_APPROVAL_FORBIDDEN|raiser' }
    if (item.id === 'c') throw new Error('fetch failed')
    if (item.id === 'e') return { error: 'Only the CFO can approve this.', detail: 'APPROVAL_NOT_AUTHORISED|2|cfo' }
    return {}
}

const out = await runOneAtATime(chosen, act, { thrownReason: 'The request did not reach the system.' })

ok(JSON.stringify(calls) === JSON.stringify(['a', 'b', 'c', 'e']) && maxInFlight === 1,
   `R1 one at a time in screen order: calls ${JSON.stringify(calls)} (ticked ${JSON.stringify([...ticked])}), max in flight ${maxInFlight}`)
const by = Object.fromEntries(out.map((o) => [o.id, o]))
ok(out.length === 4 && by.a.done === true && by.a.reason === undefined
   && by.b.done === false && by.b.reason.startsWith('You raised this request yourself') && by.b.detail === 'SELF_APPROVAL_FORBIDDEN|raiser'
   && by.e.done === false && by.e.reason === 'Only the CFO can approve this.' && by.e.detail === 'APPROVAL_NOT_AUTHORISED|2|cfo'
   && out.map((o) => o.label).join(',') === 'JR-2026-0101,JR-2026-0102,JR-2026-0103,JR-2026-0105',
   `R2 every item named with its own outcome: ${JSON.stringify(out.map((o) => [o.label, o.done ? 'done' : `refused: ${o.reason}`]))}`)
ok(by.c.done === false && by.c.reason === 'The request did not reach the system.' && by.c.detail === 'fetch failed',
   `R3 a thrown call is that item's refusal (reason ${JSON.stringify(by.c.reason)}, detail ${JSON.stringify(by.c.detail)})`)
ok(calls.includes('e') && calls.indexOf('e') > calls.indexOf('b'),
   'R4 a refusal does not stop the batch: the item after the refused ones still ran')

const offScreenKept = toggleAllOnScreen(screen.slice(0, 3), new Set(['d', 'a']))
const allOff = toggleAllOnScreen(screen.slice(0, 3), new Set(['a', 'b', 'c']))
ok(JSON.stringify([...offScreenKept].sort()) === '["a","b","c"]' && allOff.size === 0,
   `R5 select-all ticks only the rows on screen (off-screen "d" dropped → ${JSON.stringify([...offScreenKept].sort())}); all ticked → cleared (${allOff.size})`)

// ── F · 故障注入:遇拒即停的跑法,R4 那条判据必须变红 ──
{
    const stopCalls = []
    const stopping = async (items, fn) => {
        const res = []
        for (const i of items) { stopCalls.push(i.id); const r = await fn(i).catch((e) => ({ error: String(e) })); res.push(r); if (r && r.error) break }
        return res
    }
    await stopping(chosen, act)
    const r4WouldPass = stopCalls.includes('e') && stopCalls.indexOf('e') > stopCalls.indexOf('b')
    ok(!r4WouldPass, `F injection: a stop-at-first-refusal runner makes R4 fail (calls ${JSON.stringify(stopCalls)}) — the R4 check can see the property`)
}

console.log(`BULK_RUN_EXIT=${bad ? 1 : 0}`)
process.exit(bad ? 1 : 0)
