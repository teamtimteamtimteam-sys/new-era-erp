// app/operation/yield/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-5b-1(2026-10-08,规格 §3.5a;MES-0 Q60;MES-5a Q23;MES-5b Step 0 Q13 · Q14 · Q15,Tim)· 质量得率
// ════════════════════════════════════════════════════════════════════════════
// 【这一页是什么】选一个月与一种分组(不分组 · 机器 · 化学体系 · 供应商):每道工序的每一种产出形态、全部产出、每一类有名字的损耗
//   与余数,各占那一格【全部】消耗型加工单投入的百分比;下面是这个月逐张单的同一套数。V37(预期得率)给了的格子,低于它标出来 ——
//   只标,从不拒。放电、拆去隔离、回滚的单与有一条腿单位不是 kg 的单没有得率(库里就不在这两张视图里)。MES-4a 之前的单在,标着。
// 【算术一个字都不在这里】读 processing_yield_summary 与 processing_run_yield(带门的外壳);分组的份额按投入质量往回追到源头批次,
//   在库里算(processing_run_origin_share_all)。供应商的名字只给持 module.inbound.view 的人 —— 不持的人看到「受限」,不是空白(Q14)。
// 【门】requireFunction(FN.yield) = module.processing.view。金属的得率(每种金属的回收率)仍在每张加工单的页面上,不在这里重算。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { businessToday } from '@/lib/format'
import { compareForSort } from '@/lib/sortCollation'
import { fmtKg, fmtPct, num } from '@/lib/massFormat'
import { ListPage } from '@/app/components/ui/list-page'
import MassTable, { type MassCell, type MassRow } from '../balance/MassTable'
import { labelMaps, remainderOrder } from '../balance/labels'

const MONTH_RE = /^\d{4}-\d{2}$/
const GROUPS = ['all', 'machine', 'chemistry', 'supplier'] as const
type Group = (typeof GROUPS)[number]
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

export default async function YieldPage({ searchParams }: { searchParams: Promise<{ month?: string; group?: string }> }) {
    const denied = await requireFunction(FN.yield)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const sp = await searchParams
    const group: Group = (GROUPS as readonly string[]).includes(sp.group ?? '') ? (sp.group as Group) : 'all'

    const monthsRes = await supabase.from('processing_yield_summary').select('month').eq('group_kind', 'all').order('month', { ascending: false })
    const months = [...new Set(mustRows(monthsRes, 'processing_yield_summary').map((r) => String(r.month).slice(0, 7)))]
    const month = sp.month && MONTH_RE.test(sp.month) ? sp.month : (months[0] ?? businessToday().slice(0, 7))
    const monthStart = `${month}-01`

    const [sumRes, runRes, labels] = await Promise.all([
        supabase.from('processing_yield_summary')
            .select('group_kind, group_key, group_label, group_label_restricted, operation_type_code, line_kind, line_key, recoverable, qty, input_qty, runs, pre_mes4a_runs, yield_pct, expected_yield_pct, below_expected')
            .eq('month', monthStart).eq('group_kind', group),
        supabase.from('processing_run_yield')
            .select('run_id, run_code, operation_type_code, era_mes4a, input_qty, line_kind, line_key, recoverable, qty, yield_pct, expected_yield_pct, below_expected')
            .eq('month', monthStart).order('run_code'),
        labelMaps(supabase, locale, t),
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
                if (group !== 'all') cells.push(groupText(l))
                cells.push(lineText(l.line_kind, l.line_key, l.recoverable), fmtKg(l.qty), fmtKg(l.input_qty),
                    yieldCell(l.yield_pct, l.below_expected), expectedCell(l.line_kind, l.expected_yield_pct))
                sumRows.push({ key: `${op}|${k}|${l.line_kind}|${l.line_key ?? ''}`, cells, emphasis: l.line_kind === 'total_output' })
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
    }))

    const groupLabel: Record<Group, string> = {
        all: t('massBalance.yield.groupAll'), machine: t('massBalance.yield.groupMachine'),
        chemistry: t('massBalance.yield.groupChemistry'), supplier: t('massBalance.yield.groupSupplier'),
    }

    return (
        <ListPage title={t('massBalance.yield.title')} intro={t('massBalance.yield.intro')} maxWidth="max-w-6xl"
                  state={months.length === 0 && summary.length === 0 ? { kind: 'empty', noRows: t('massBalance.yield.noRuns') } : { kind: 'ok' }}>
            <nav className="flex flex-wrap gap-x-3 gap-y-1 text-sm mb-2" aria-label={t('massBalance.month')} data-months>
                <span className="text-[color:var(--brand-muted-text)]">{t('massBalance.month')}:</span>
                {(months.includes(month) ? months : [month, ...months]).map((m) => (
                    m === month
                        ? <span key={m} className="font-medium" aria-current="true">{m}</span>
                        : <Link key={m} href={`/operation/yield?month=${m}&group=${group}`} className="hover:underline app-link">{m}</Link>
                ))}
                <Link href={`/operation/balance?month=${month}`} className="ml-auto hover:underline app-link">{t('massBalance.yield.toBalance')}</Link>
            </nav>
            <nav className="flex flex-wrap gap-x-3 gap-y-1 text-sm mb-4" aria-label={t('massBalance.yield.groupBy')} data-groups>
                <span className="text-[color:var(--brand-muted-text)]">{t('massBalance.yield.groupBy')}:</span>
                {GROUPS.map((g) => (g === group
                    ? <span key={g} className="font-medium" aria-current="true">{groupLabel[g]}</span>
                    : <Link key={g} href={`/operation/yield?month=${month}&group=${g}`} className="hover:underline app-link">{groupLabel[g]}</Link>))}
            </nav>
            {(group === 'chemistry' || group === 'supplier') && <p className="text-sm text-[color:var(--brand-muted-text)] mb-2">{t('massBalance.yield.sharedNote')}</p>}
            {notes.map((n) => <p key={n} className="text-sm text-amber-800 mb-1" data-pre-mes4a>{n}</p>)}
            <MassTable testId="yield-summary" empty={t('massBalance.yield.noRuns')}
                       headers={[...sumHeaders, { label: t('massBalance.yield.colQty'), align: 'right' }, { label: t('massBalance.yield.colInput'), align: 'right' },
                                 { label: t('massBalance.yield.colYield'), priority: true, align: 'right' }, { label: t('massBalance.yield.colExpected'), align: 'right' }]}
                       rows={sumRows} />
            <h2 className="mt-8 mb-2">{t('massBalance.yield.runsTitle')}</h2>
            <MassTable testId="yield-runs" empty={t('massBalance.yield.noRuns')}
                       headers={[{ label: t('massBalance.yield.colRun'), priority: true }, { label: t('massBalance.colOperation') },
                                 { label: t('massBalance.yield.colLine'), priority: true }, { label: t('massBalance.yield.colQty'), align: 'right' },
                                 { label: t('massBalance.yield.colInput'), align: 'right' }, { label: t('massBalance.yield.colYield'), priority: true, align: 'right' },
                                 { label: t('massBalance.yield.colExpected'), align: 'right' }]}
                       rows={runRows} />
            <p className="text-sm text-[color:var(--brand-muted-text)] mt-4">{t('massBalance.yield.recoveryNote')}</p>
        </ListPage>
    )
}
