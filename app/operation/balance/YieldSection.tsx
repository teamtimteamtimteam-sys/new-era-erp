// app/operation/balance/YieldSection.tsx
// ════════════════════════════════════════════════════════════════════════════
// SYSTEM-MAP-4(Tim 2026-10-29 第 9 条 · 2026-10-30 Q4 (a))· 得率是物料平衡页的【第二段】
// ════════════════════════════════════════════════════════════════════════════
// 【它此前是什么】/operation/yield 一整页(MES-5b-1):同一个月的得率合计(全部 / 按机器 / 按化学体系 / 按供应商)与逐张单。
//   Tim 把它并进物料平衡:同一个月份选择,画在平衡的三张表下面;/operation/yield 留作注册表里的孩子,带着筛选跳到 #yield。
// 【一个字的算术都没有改】读的仍是 processing_yield_summary 与 processing_run_yield(带门的外壳),
//   格子、导出、低于预期的标记与「受限」的组名照搬原页;只有分组链接改指平衡页,月份由平衡页的选择器给。
import Link from 'next/link'
import type { createClient } from '@/lib/supabase/server'
import type { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { compareForSort } from '@/lib/sortCollation'
import { fmtKg, fmtPct, num } from '@/lib/massFormat'
import MassTable, { type MassCell, type MassRow } from './MassTable'
import { remainderOrder, type labelMaps } from './labels'
import { xText, xNum, xRestricted, type ExportCell } from '@/lib/export/cells'

export const YIELD_GROUPS = ['all', 'machine', 'chemistry', 'supplier'] as const
export type YieldGroup = (typeof YIELD_GROUPS)[number]
const LINE_ORDER: Record<string, number> = { output: 0, total_output: 1, loss: 2, remainder: 3 }

type YieldLine = {
    group_kind: string; group_key: string | null; group_label: string | null; group_label_restricted: boolean
    operation_type_code: string | null; line_kind: string; line_key: string | null; recoverable: boolean | null
    qty: number | string | null; input_qty: number | string | null; runs: number; pre_mes4a_runs: number
    yield_pct: number | string | null; expected_yield_pct: number | string | null; below_expected: boolean | null
}
type RunLine = {
    run_id: string; run_code: string; operation_type_code: string | null; era_mes4a: boolean; input_qty: number | string | null
    line_kind: string; line_key: string | null; recoverable: boolean | null; qty: number | string | null
    yield_pct: number | string | null; expected_yield_pct: number | string | null; below_expected: boolean | null
}


export default async function YieldSection({ supabase, t, labels, month, group }: {
    supabase: Awaited<ReturnType<typeof createClient>>
    t: Awaited<ReturnType<typeof getTranslations>>
    labels: Awaited<ReturnType<typeof labelMaps>>
    /** YYYY-MM —— 平衡页的月份选择给的 */
    month: string
    group: YieldGroup
}) {
    const monthStart = `${month}-01`
    const [sumRes, runRes] = await Promise.all([
        supabase.from('processing_yield_summary')
            .select('group_kind, group_key, group_label, group_label_restricted, operation_type_code, line_kind, line_key, recoverable, qty, input_qty, runs, pre_mes4a_runs, yield_pct, expected_yield_pct, below_expected')
            .eq('month', monthStart).eq('group_kind', group),
        supabase.from('processing_run_yield')
            .select('run_id, run_code, operation_type_code, era_mes4a, input_qty, line_kind, line_key, recoverable, qty, yield_pct, expected_yield_pct, below_expected')
            .eq('month', monthStart).order('run_code'),
    ])
    const summary = mustRows(sumRes, 'processing_yield_summary') as unknown as YieldLine[]
    const runs = mustRows(runRes, 'processing_run_yield') as unknown as RunLine[]

    const lineText = (kind: string, key: string | null, recoverable: boolean | null) => {
        if (kind === 'output') return t('massBalance.yield.lineOutput', { form: labels.form(key) })
        if (kind === 'total_output') return t('massBalance.yield.lineTotal')
        if (kind === 'loss') return recoverable
            ? t('massBalance.yield.lineLossRecoverable', { category: labels.loss(key) })
            : t('massBalance.yield.lineLoss', { category: labels.loss(key) })
        return t('massBalance.yield.lineRemainder', { state: labels.remainder(key) })
    }
    const expectedCell = (kind: string, v: number | string | null): MassCell =>
        kind !== 'output' ? '' : num(v) === null ? { text: t('massBalance.yield.expectedNotSet'), tone: 'notSet' } : fmtPct(v)
    const yieldCell = (y: number | string | null, below: boolean | null): MassCell =>
        below ? { text: `${fmtPct(y)} · ${t('massBalance.yield.below')}`, tone: 'flag', mark: 'below' } : fmtPct(y)
    const groupText = (l: YieldLine): MassCell => {
        if (l.group_label_restricted) return { text: t('common.restricted'), tone: 'muted', mark: 'restricted' }
        if (l.group_key === null) {
            return { text: group === 'machine' ? t('massBalance.yield.machineNone') : group === 'chemistry'
                ? t('massBalance.yield.chemistryNone') : t('massBalance.yield.supplierNone'), tone: 'notSet' }
        }
        return l.group_label ?? l.group_key
    }
    // TABLE-EXPORT-1:与上面三个画格子的函数同位的【导出一格】—— 读原始值;得率是屏幕上那个百分数(xNum 'pct')。
    //   低于预期的标记只在屏幕上(一格只能是一个数);受限的组名写「受限」,与屏幕同一个判据(group_label_restricted)。
    const expectedX = (kind: string, v: number | string | null): ExportCell =>
        kind !== 'output' ? xText(null) : num(v) === null ? xText(t('massBalance.yield.expectedNotSet')) : xNum(v, 'pct')
    const groupX = (l: YieldLine): ExportCell => {
        if (l.group_label_restricted) return xRestricted
        const g = groupText(l)
        return xText(typeof g === 'string' ? g : g.text)
    }
    const sortLine = (a: { line_kind: string; line_key: string | null }, b: { line_kind: string; line_key: string | null }) =>
        (LINE_ORDER[a.line_kind] - LINE_ORDER[b.line_kind])
        || (a.line_kind === 'output' ? labels.formSort(a.line_key) - labels.formSort(b.line_key)
            : a.line_kind === 'loss' ? labels.lossSort(a.line_key) - labels.lossSort(b.line_key)
            : remainderOrder(a.line_key) - remainderOrder(b.line_key))

    // ── 合计:工序 → 组 → 线 ──────────────────────────────────────────────────
    const sumRows: MassRow[] = []
    const notes: string[] = []
    const ops = [...new Set(summary.map((l) => l.operation_type_code ?? ''))].sort((a, b) => labels.opSort(a || null) - labels.opSort(b || null))
    for (const op of ops) {
        const ofOp = summary.filter((l) => (l.operation_type_code ?? '') === op)
        const keys = [...new Set(ofOp.map((l) => l.group_key ?? ''))]
        for (const k of keys) {
            const ls = ofOp.filter((l) => (l.group_key ?? '') === k).sort(sortLine)
            const total = ls.find((l) => l.line_kind === 'total_output')
            if (total && total.pre_mes4a_runs > 0) {
                const g = groupText(total)
                notes.push(`${labels.op(op || null)}${group === 'all' ? '' : ' · ' + (typeof g === 'string' ? g : g.text)}: `
                    + t('massBalance.yield.preMes4a', { n: total.pre_mes4a_runs, m: total.runs }))
            }
            for (const l of ls) {
                const cells: MassCell[] = [labels.op(op || null)]
                const exports: ExportCell[] = [xText(labels.op(op || null))]
                if (group !== 'all') { cells.push(groupText(l)); exports.push(groupX(l)) }
                cells.push(lineText(l.line_kind, l.line_key, l.recoverable), fmtKg(l.qty), fmtKg(l.input_qty),
                    yieldCell(l.yield_pct, l.below_expected), expectedCell(l.line_kind, l.expected_yield_pct))
                exports.push(xText(lineText(l.line_kind, l.line_key, l.recoverable)), xNum(l.qty, 'qty'), xNum(l.input_qty, 'qty'),
                    xNum(l.yield_pct, 'pct'), expectedX(l.line_kind, l.expected_yield_pct))
                sumRows.push({ key: `${op}|${k}|${l.line_kind}|${l.line_key ?? ''}`, cells, exports, emphasis: l.line_kind === 'total_output' })
            }
        }
    }
    const sumHeaders = [{ label: t('massBalance.colOperation'), priority: true }]
    if (group !== 'all') sumHeaders.push({ label: t('massBalance.yield.colGroup'), priority: true })
    sumHeaders.push({ label: t('massBalance.yield.colLine'), priority: true })

    // ── 逐张单 ─────────────────────────────────────────────────────────────
    const runRows: MassRow[] = [...runs].sort((a, b) => compareForSort(a.run_code, b.run_code) || sortLine(a, b)).map((r) => ({
        key: `${r.run_id}|${r.line_kind}|${r.line_key ?? ''}`,
        emphasis: r.line_kind === 'total_output',
        cells: [
            { text: r.era_mes4a ? r.run_code : `${r.run_code} · ${t('massBalance.yield.preMes4aRun')}`, href: `/operation/processing/${r.run_id}` },
            labels.op(r.operation_type_code), lineText(r.line_kind, r.line_key, r.recoverable), fmtKg(r.qty), fmtKg(r.input_qty),
            yieldCell(r.yield_pct, r.below_expected), expectedCell(r.line_kind, r.expected_yield_pct),
        ],
        exports: [
            xText(r.era_mes4a ? r.run_code : `${r.run_code} · ${t('massBalance.yield.preMes4aRun')}`),
            xText(labels.op(r.operation_type_code)), xText(lineText(r.line_kind, r.line_key, r.recoverable)), xNum(r.qty, 'qty'), xNum(r.input_qty, 'qty'),
            xNum(r.yield_pct, 'pct'), expectedX(r.line_kind, r.expected_yield_pct),
        ],
    }))

    const groupLabel: Record<YieldGroup, string> = {
        all: t('massBalance.yield.groupAll'), machine: t('massBalance.yield.groupMachine'),
        chemistry: t('massBalance.yield.groupChemistry'), supplier: t('massBalance.yield.groupSupplier'),
    }

    return (
        <section id="yield" className="mt-10 scroll-mt-20" data-yield-section>
            <h2 className="mb-1">{t('massBalance.yield.title')}</h2>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-3">{t('massBalance.yield.intro')}</p>
            <nav className="flex flex-wrap gap-x-3 gap-y-1 text-sm mb-4" aria-label={t('massBalance.yield.groupBy')} data-groups>
                <span className="text-[color:var(--brand-muted-text)]">{t('massBalance.yield.groupBy')}:</span>
                {YIELD_GROUPS.map((g) => (g === group
                    ? <span key={g} className="font-medium" aria-current="true">{groupLabel[g]}</span>
                    : <Link key={g} href={`/operation/balance?month=${month}&group=${g}#yield`} className="hover:underline app-link">{groupLabel[g]}</Link>))}
            </nav>
            {(group === 'chemistry' || group === 'supplier') && <p className="text-sm text-[color:var(--brand-muted-text)] mb-2">{t('massBalance.yield.sharedNote')}</p>}
            {notes.map((n) => <p key={n} className="text-sm text-amber-800 mb-1" data-pre-mes4a>{n}</p>)}
            <MassTable testId="yield-summary" empty={t('massBalance.yield.noRuns')} exportSpec={{ name: 'operation-yield-summary', title: t('massBalance.yield.title') }}
                       headers={[...sumHeaders, { label: t('massBalance.yield.colQty'), align: 'right' }, { label: t('massBalance.yield.colInput'), align: 'right' },
                                 { label: t('massBalance.yield.colYield'), priority: true, align: 'right' }, { label: t('massBalance.yield.colExpected'), align: 'right' }]}
                       rows={sumRows} />
            <h2 className="mt-8 mb-2">{t('massBalance.yield.runsTitle')}</h2>
            <MassTable testId="yield-runs" empty={t('massBalance.yield.noRuns')} exportSpec={{ name: 'operation-yield-runs', title: t('massBalance.yield.runsTitle') }}
                       headers={[{ label: t('massBalance.yield.colRun'), priority: true }, { label: t('massBalance.colOperation') },
                                 { label: t('massBalance.yield.colLine'), priority: true }, { label: t('massBalance.yield.colQty'), align: 'right' },
                                 { label: t('massBalance.yield.colInput'), align: 'right' }, { label: t('massBalance.yield.colYield'), priority: true, align: 'right' },
                                 { label: t('massBalance.yield.colExpected'), align: 'right' }]}
                       rows={runRows} />
            <p className="text-sm text-[color:var(--brand-muted-text)] mt-4">{t('massBalance.yield.recoveryNote')}</p>
        </section>
    )
}
