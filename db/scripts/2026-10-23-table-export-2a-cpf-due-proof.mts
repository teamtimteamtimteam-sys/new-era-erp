// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-2a(Tim 2026-10-22,TABLE-EXPORT-2 Q9)· 「Sep 202」那一族四处 —— 【跑】出来,不是读出来
// ════════════════════════════════════════════════════════════════════════════
// Tim:「cpfDue receives the raw month, so the unpaid CPF buttons on /finance/payroll-payments no longer throw (prove it by running, not by reading)」。
// 线上今天【没有】一颗没付的公积金钮(唯一一期 PAY-2026-0001 的公积金已付,TABLE-EXPORT-2a 以 postgres 读);造一期没付的就得在线上提交一张单据,
// 规矩不许。而那颗钮所在的面板(PayPanel)用 useRouter,离开 app router 渲染不起来。所以本证明跑的是【那颗钮的标签实际调用的那一支函数】
// (app/finance/payroll-payments/cpfDue.ts —— 从 PayPanel 里原样搬出来),两臂:
//   对照臂(旧的调用形状):cpfDue(formatMonth(月, 'en' | 'zh')) —— 必须抛 RangeError(那正是面板崩掉的原因);
//   本刀臂(新的调用形状):cpfDue(原始的 period_month) —— 必须给出次月 14 日,含十二月跨年。
// 再加一条源码断言:PayPanel 里那一处调用就是新的形状,而且【没有】旧的形状 —— 否则跑通的只是一支没人调的函数。
// 另外三处(同一个病)一并跑:期间格的切法、编辑页的月份框、/me 考勤的排序。
// 不连线上、不起服务器。判词只看最后一行 CPF_PROOF_EXIT=(0 = 全 PASS)。
// 用法:npx tsx db/scripts/2026-10-23-table-export-2a-cpf-due-proof.mts
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync } from 'node:fs'
import { cpfDue } from '../../app/finance/payroll-payments/cpfDue'
import { formatMonth, toYearMonth } from '../../lib/dates'

let bad = 0
const ok = (cond: boolean, what: string) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++ }
const throws = (f: () => unknown): string | null => { try { f(); return null } catch (e) { return e instanceof Error ? `${e.name}: ${e.message}` : String(e) } }

// ── ① 公积金钮的到期日 ─────────────────────────────────────────────────────────
for (const loc of ['en', 'zh']) {
    for (const month of ['2026-07-01', '2026-09-01', '2026-10-01', '2026-12-01']) {
        const label = formatMonth(month, loc)
        const err = throws(() => cpfDue(label))
        ok(err !== null && err.startsWith('RangeError'), `C1 control · old call cpfDue(formatMonth(${month}, ${loc})) = cpfDue(${JSON.stringify(label)}) throws → ${err ?? 'did NOT throw'}`)
    }
}
for (const [month, want] of [['2026-07-01', '2026-08-14'], ['2026-09-01', '2026-10-14'], ['2026-10-01', '2026-11-14'], ['2026-12-01', '2027-01-14']] as const) {
    const err = throws(() => cpfDue(month))
    const got = err ? `threw ${err}` : cpfDue(month)
    ok(got === want, `C1 fix · cpfDue(${month}) = ${got} (want ${want})`)
}
const panel = readFileSync(new URL('../../app/finance/payroll-payments/PayPanel.tsx', import.meta.url), 'utf8')
ok(/due: cpfDue\(p\.period_month\)/.test(panel) && !/cpfDue\(formatMonth/.test(panel),
   'C1 source · PayPanel calls cpfDue(p.period_month) and no longer cpfDue(formatMonth(…))')

// ── ② /hr/payroll 期间格:显示用的字照原样显示,不再 .slice(0, 7) ───────────────────
for (const [month, loc] of [['2026-09-01', 'en'], ['2026-10-01', 'zh'], ['2026-12-01', 'zh'], ['2026-09-01', 'zh']] as const) {
    const label = formatMonth(month, loc)
    ok(label.slice(0, 7) !== label || label.length <= 7, `C2 control · old cell ${JSON.stringify(label)}.slice(0, 7) = ${JSON.stringify(label.slice(0, 7))}${label.length > 7 ? ' (cut)' : ' (short enough — this month was never cut)'}`)
}
ok(formatMonth('2026-09-01', 'en') === 'Sep 2026' && formatMonth('2026-10-01', 'zh') === '2026年10月',
   `C2 fix · the cell now shows formatMonth as is: ${formatMonth('2026-09-01', 'en')} · ${formatMonth('2026-10-01', 'zh')}`)
const periodsTable = readFileSync(new URL('../../app/hr/payroll/PayrollPeriodsTable.tsx', import.meta.url), 'utf8')
ok(!/periodMonth\?\.slice\(0, 7\)/.test(periodsTable) && /\{r\.periodMonth\}/.test(periodsTable), 'C2 source · PayrollPeriodsTable renders {r.periodMonth} with no .slice(0, 7)')

// ── ③ /hr/payroll/[id]/edit 的月份框:要 YYYY-MM(actions.ts 的 /^\d{4}-\d{2}$/)──────────
const SHAPE = /^\d{4}-\d{2}$/
ok(toYearMonth(formatMonth('2026-09-01', 'zh')) === '', `C3 control · old default in zh: toYearMonth(${JSON.stringify(formatMonth('2026-09-01', 'zh'))}) = ${JSON.stringify(toYearMonth(formatMonth('2026-09-01', 'zh')))} → the month box is empty and save is refused`)
ok(SHAPE.test(toYearMonth('2026-09-01')) && toYearMonth('2026-09-01') === '2026-09', `C3 fix · toYearMonth('2026-09-01') = ${toYearMonth('2026-09-01')} (passes the action's /^\\d{4}-\\d{2}$/)`)
const editPage = readFileSync(new URL('../../app/hr/payroll/[id]/edit/page.tsx', import.meta.url), 'utf8')
ok(/period_month: toYearMonth\(period\.period_month\)/.test(editPage), 'C3 source · the edit page passes toYearMonth(period.period_month)')

// ── ④ /me 考勤按日子排,不按月份名排 ──────────────────────────────────────────
const months = ['2025-09-01', '2026-04-01', '2026-01-01', '2025-12-01']
const byLabel = [...months].sort((a, b) => formatMonth(b, 'en').localeCompare(formatMonth(a, 'en'))).map((m) => formatMonth(m, 'en'))
const byDate = [...months].sort((a, b) => b.localeCompare(a)).map((m) => formatMonth(m, 'en'))
ok(byLabel.join() !== byDate.join(), `C4 control · old sort by label: ${byLabel.join(' · ')}`)
ok(byDate.join() === 'Apr 2026,Jan 2026,Dec 2025,Sep 2025', `C4 fix · new sort by raw month: ${byDate.join(' · ')}`)
const mePage = readFileSync(new URL('../../app/me/page.tsx', import.meta.url), 'utf8')
ok(/\.sort\(\(a, b\) => b\.monthKey\.localeCompare\(a\.monthKey\)\)/.test(mePage) && !/b\.periodMonth\.localeCompare\(a\.periodMonth\)/.test(mePage),
   'C4 source · /me sorts attendance by the raw month key, not by the label')

console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
console.log(`CPF_PROOF_EXIT=${bad ? 1 : 0}`)
process.exit(bad ? 1 : 0)
