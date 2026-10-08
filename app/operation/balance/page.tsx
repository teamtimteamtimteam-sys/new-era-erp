// app/operation/balance/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-5b-1(2026-10-08,规格 §4;MES-0 Q48 · Q59;MES-5b Step 0 Q8 · Q9 · Q10,Tim)· 月度物料平衡
// ════════════════════════════════════════════════════════════════════════════
// 【这一页是什么】选一个月(按 process_date):全厂一份、每道工序一份 —— 消耗型加工单的投入、按形态的产出、按类别 × 来由的有名字损耗、
//   按状态的余数;穿过去的质量(深度放电 · 拆去隔离)与回滚的单另列;有一条腿单位不是 kg 的单只数件数。下面是同一个月的库存滚动
//   (库存流水按业务日期)。【实时数,不冻结】—— 页面照直说(Q9)。月末那一步"物料平衡已结"链到这里。
// 【算术一个字都不在这里】读 processing_balance_monthly 与 stock_rollforward_monthly(带门的外壳);这里只把行摆出来,
//   恒等式那一行是把同一个月的几条线加起来给人看,不是一次判断。
// 【门】requireFunction(FN.balance) = module.processing.view。读的两张外壳另认 finance / inventory 的查看码(/inventory 与月末靠它)。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { businessToday } from '@/lib/format'
import { fmtKg, num } from '@/lib/massFormat'
import { ListPage } from '@/app/components/ui/list-page'
import MassTable, { type MassRow } from './MassTable'
import { labelMaps, remainderOrder, type MonthlyLine } from './labels'

const MONTH_RE = /^\d{4}-\d{2}$/

export default async function BalancePage({ searchParams }: { searchParams: Promise<{ month?: string }> }) {
    const denied = await requireFunction(FN.balance)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const sp = await searchParams

    const monthsRes = await supabase.from('processing_balance_monthly').select('month').eq('scope', 'plant').order('month', { ascending: false })
    const months = [...new Set(mustRows(monthsRes, 'processing_balance_monthly').map((r) => String(r.month).slice(0, 7)))]
    const month = sp.month && MONTH_RE.test(sp.month) ? sp.month : (months[0] ?? businessToday().slice(0, 7))
    const monthStart = `${month}-01`

    const [linesRes, rollRes, labels] = await Promise.all([
        supabase.from('processing_balance_monthly').select('scope, operation_type_code, line, line_key, basis, qty, runs').eq('month', monthStart),
        supabase.from('stock_rollforward_monthly')
            .select('month, unit, opening, received, produced, consumed, sold, written_off, adjusted, voided, moved, closing')
            .or(`month.eq.${monthStart},month.is.null`),
        labelMaps(supabase, locale, t),
    ])
    const lines = mustRows(linesRes, 'processing_balance_monthly') as unknown as MonthlyLine[]
    const roll = mustRows(rollRes, 'stock_rollforward_monthly')

    // ── 全厂:一条线一行,固定顺序 ─────────────────────────────────────────────
    const plant = lines.filter((l) => l.scope === 'plant')
    const sumOf = (ls: MonthlyLine[], line: string) => ls.filter((l) => l.line === line).reduce((s, l) => s + (num(l.qty) ?? 0), 0)
    const runsOf = (ls: MonthlyLine[], line: string) => ls.filter((l) => l.line === line).reduce((s, l) => s + (num(l.runs) ?? 0), 0)
    const plantRows: MassRow[] = []
    const inputLine = plant.find((l) => l.line === 'input')
    plantRows.push({ key: 'input', emphasis: true, cells: [t('massBalance.lineInput'), fmtKg(inputLine?.qty ?? 0), String(inputLine?.runs ?? 0)] })
    for (const l of plant.filter((x) => x.line === 'output').sort((a, b) => labels.formSort(a.line_key) - labels.formSort(b.line_key))) {
        plantRows.push({ key: `o:${l.line_key}`, cells: [t('massBalance.lineOutput', { form: labels.form(l.line_key) }), fmtKg(l.qty), String(l.runs)] })
    }
    for (const l of plant.filter((x) => x.line === 'loss').sort((a, b) => labels.lossSort(a.line_key) - labels.lossSort(b.line_key))) {
        plantRows.push({ key: `l:${l.line_key}:${l.basis}`, cells: [t('massBalance.lineLoss', { category: labels.loss(l.line_key), basis: labels.basis(l.basis) }), fmtKg(l.qty), String(l.runs)] })
    }
    for (const l of plant.filter((x) => x.line === 'remainder').sort((a, b) => remainderOrder(a.line_key) - remainderOrder(b.line_key))) {
        plantRows.push({ key: `r:${l.line_key}`, cells: [
            { text: t('massBalance.lineRemainder', { state: labels.remainder(l.line_key) }), tone: l.line_key === 'open' ? 'notSet' : undefined },
            fmtKg(l.qty), String(l.runs)] })
    }
    for (const l of plant.filter((x) => x.line === 'pass_through')) {
        plantRows.push({ key: `p:${l.line_key}`, cells: [
            { text: l.line_key === 'split' ? t('massBalance.linePassSplit') : t('massBalance.linePassDischarge'), tone: 'muted' }, fmtKg(l.qty), String(l.runs)] })
    }
    for (const l of plant.filter((x) => x.line === 'reversed')) {
        plantRows.push({ key: 'reversed', cells: [{ text: t('massBalance.lineReversed'), tone: 'muted' }, fmtKg(l.qty), String(l.runs)] })
    }
    for (const l of plant.filter((x) => x.line === 'not_kg')) {
        plantRows.push({ key: 'notkg', cells: [{ text: t('massBalance.lineNotKg'), tone: 'notSet' }, '—', String(l.runs)] })
    }

    // ── 每道工序:一行一道 ────────────────────────────────────────────────────
    const ops = [...new Set(lines.filter((l) => l.scope === 'operation').map((l) => l.operation_type_code ?? ''))]
        .sort((a, b) => labels.opSort(a || null) - labels.opSort(b || null))
    const opRows: MassRow[] = ops.map((code) => {
        const ls = lines.filter((l) => l.scope === 'operation' && (l.operation_type_code ?? '') === code)
        return {
            key: code || '(none)',
            cells: [labels.op(code || null), fmtKg(sumOf(ls, 'input')), fmtKg(sumOf(ls, 'output')), fmtKg(sumOf(ls, 'loss')),
                fmtKg(sumOf(ls, 'remainder')), fmtKg(sumOf(ls, 'pass_through')), fmtKg(sumOf(ls, 'reversed')), String(runsOf(ls, 'input'))],
        }
    })

    // ── 库存滚动 ─────────────────────────────────────────────────────────────
    const rollRows: MassRow[] = roll.filter((r) => r.month !== null).map((r) => ({
        key: String(r.unit),
        cells: [String(r.unit), fmtKg(r.opening), fmtKg(r.received), fmtKg(r.produced), fmtKg(r.consumed), fmtKg(r.sold),
            fmtKg(r.written_off), fmtKg(r.adjusted), fmtKg(r.voided), fmtKg(r.moved), fmtKg(r.closing)],
    }))
    const undatedUnits = roll.filter((r) => r.month === null).length

    const identity = t('massBalance.identity', {
        input: fmtKg(sumOf(plant, 'input')), output: fmtKg(sumOf(plant, 'output')),
        loss: fmtKg(sumOf(plant, 'loss')), remainder: fmtKg(sumOf(plant, 'remainder')),
    })

    return (
        <ListPage title={t('massBalance.title')} intro={t('massBalance.intro')} maxWidth="max-w-6xl"
                  state={months.length === 0 && lines.length === 0 ? { kind: 'empty', noRows: t('massBalance.noData') } : { kind: 'ok' }}>
            <p className="text-sm text-amber-800 mb-3" data-live-note>{t('massBalance.liveNote')}</p>
            <nav className="flex flex-wrap gap-x-3 gap-y-1 text-sm mb-4" aria-label={t('massBalance.month')} data-months>
                <span className="text-[color:var(--brand-muted-text)]">{t('massBalance.month')}:</span>
                {(months.includes(month) ? months : [month, ...months]).map((m) => (
                    m === month
                        ? <span key={m} className="font-medium" aria-current="true">{m}</span>
                        : <Link key={m} href={`/operation/balance?month=${m}`} className="hover:underline app-link">{m}</Link>
                ))}
                <Link href={`/operation/yield?month=${month}`} className="ml-auto hover:underline app-link">{t('massBalance.toYield')}</Link>
            </nav>

            <h2 className="mb-2">{t('massBalance.plantTitle')}</h2>
            <p className="text-sm mb-2" data-identity>{identity}</p>
            <MassTable testId="plant" empty={t('massBalance.noData')}
                       headers={[{ label: t('massBalance.colLine'), priority: true }, { label: t('massBalance.colQty'), priority: true, align: 'right' },
                                 { label: t('massBalance.colRuns'), align: 'right' }]}
                       rows={plantRows} />

            <h2 className="mt-8 mb-2">{t('massBalance.opTitle')}</h2>
            <MassTable testId="operations" empty={t('massBalance.noData')}
                       headers={[{ label: t('massBalance.colOperation'), priority: true }, { label: t('massBalance.colInput'), priority: true, align: 'right' },
                                 { label: t('massBalance.colOutput'), align: 'right' }, { label: t('massBalance.colNamedLoss'), align: 'right' },
                                 { label: t('massBalance.colRemainder'), priority: true, align: 'right' }, { label: t('massBalance.colPassThrough'), align: 'right' },
                                 { label: t('massBalance.colReversed'), align: 'right' }, { label: t('massBalance.colRuns'), align: 'right' }]}
                       rows={opRows} />

            <h2 className="mt-8 mb-2">{t('massBalance.rollTitle')}</h2>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-2">{t('massBalance.rollIntro')}</p>
            {undatedUnits > 0 && <p className="text-sm text-amber-800 mb-2" data-undated>{t('massBalance.rollUndated', { n: undatedUnits })}</p>}
            <MassTable testId="rollforward" empty={t('massBalance.noData')}
                       headers={[{ label: t('massBalance.colUnit'), priority: true }, { label: t('massBalance.colOpening'), align: 'right' },
                                 { label: t('massBalance.colReceived'), align: 'right' }, { label: t('massBalance.colProduced'), align: 'right' },
                                 { label: t('massBalance.colConsumed'), align: 'right' }, { label: t('massBalance.colSold'), align: 'right' },
                                 { label: t('massBalance.colWrittenOff'), align: 'right' }, { label: t('massBalance.colAdjusted'), align: 'right' },
                                 { label: t('massBalance.colVoided'), align: 'right' }, { label: t('massBalance.colMoved'), align: 'right' },
                                 { label: t('massBalance.colClosing'), priority: true, align: 'right' }]}
                       rows={rollRows} />
        </ListPage>
    )
}
