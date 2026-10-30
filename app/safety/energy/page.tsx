// app/safety/energy/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// SYSTEM-MAP-4(Tim 2026-10-30 Q1,候选 1)· ESG › 能耗强度 —— 每一张电费单的 kWh 与那一段加工了多少吨
// ════════════════════════════════════════════════════════════════════════════
// 【一行一张电费单】(electricity_allocations_masked;作废冲回的那几张不算,与 /finance/electricity 同一个判据:
//   electricity_allocation_reversals_masked 里有它的就是冲回了)。kWh 不遮(那张视图只遮金额)。
// 【吨数从物料平衡来】processing_balance_monthly 的全厂「投入」线 —— 与 /operation/balance 与 ESG › 回收读的是同一份,
//   于是三处说的投入吨数不可能不一样。那份数是【按月】的(按 process_date 的月),所以:
//   ★ 只有账期【正好是整月】(从某月 1 日到某月最后一天,可以跨几个整月)的那张单,才配得上一个吨数与「每吨 kWh」。
//     账期切在月中的单,那两格说「账期不是整月 —— 算不出」,不按天数摊一个出来(摊出来的数是一个猜测,不是一次测量)。
// 【没有 Scope 2】(Tim Q1:这一刀不做电网排放因子,也不加新的设定)。
// 【门】注册表 /safety/energy = 财务或加工查看码任一 —— 电费单视图的门;平衡视图的门(加工 · 财务 · 库存)包含这两个。
// ════════════════════════════════════════════════════════════════════════════
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { formatDate, addDaysIso, addMonthsIso } from '@/lib/dates'
import { fmtKg, num } from '@/lib/massFormat'
import { ListPage } from '@/app/components/ui/list-page'
import CellsTable, { type CellRow } from '@/app/operation/equipment/CellsTable'
import { xText, xNum, xDate } from '@/lib/export/cells'
import { readAll } from '@/lib/readAll'

type Bill = {
    id: string; period_from: string; period_to: string; invoice_ref: string
    bill_kwh: number | string; metered_kwh: number | string; unmetered_kwh: number | string
}

/** 账期是不是一段【整月】:从某月 1 日起,到某月最后一天止(结束日的下一天是某月 1 日)。是 → 交回覆盖的那几个月(YYYY-MM-01),否 → null。 */
function wholeMonths(from: string, to: string): string[] | null {
    if (!from.endsWith('-01') || !addDaysIso(to, 1).endsWith('-01') || to < from) return null
    const out: string[] = []
    for (let m = from; m <= to; m = addMonthsIso(m, 1)) out.push(m)
    return out
}

const kwh = (v: number | null) => (v === null ? '—' : new Intl.NumberFormat('en-US', { maximumFractionDigits: 1 }).format(v))

export default async function EnergyIntensityPage() {
    const denied = await requireFunction(FN.esgEnergy)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const [billRes, revRes, inRes] = await Promise.all([
        readAll(() => supabase.from('electricity_allocations_masked')
            .select('id, period_from, period_to, invoice_ref, bill_kwh, metered_kwh, unmetered_kwh')
            .order('period_from', { ascending: false }), { label: 'electricity_allocations_masked' }),
        readAll(() => supabase.from('electricity_allocation_reversals_masked').select('allocation_id'), { label: 'electricity_allocation_reversals_masked' }),
        supabase.from('processing_balance_monthly').select('month, qty').eq('scope', 'plant').eq('line', 'input'),
    ])
    const reversed = new Set((mustRows(revRes, 'electricity_allocation_reversals_masked') as { allocation_id: string }[]).map((r) => r.allocation_id))
    const allBills = mustRows(billRes, 'electricity_allocations_masked') as unknown as Bill[]
    const bills = allBills.filter((b) => !reversed.has(b.id))
    const inputByMonth = new Map<string, number>()
    for (const r of mustRows(inRes, 'processing_balance_monthly') as { month: string; qty: number | string | null }[]) {
        const k = String(r.month).slice(0, 10)
        inputByMonth.set(k, (inputByMonth.get(k) ?? 0) + (num(r.qty) ?? 0))
    }

    const notWhole = t('esg.energy.notWholeMonths')
    const rows: CellRow[] = bills.map((b) => {
        const months = wholeMonths(b.period_from, b.period_to)
        const inputKg = months ? months.reduce((s, m) => s + (inputByMonth.get(m) ?? 0), 0) : null
        const tonnes = inputKg === null ? null : inputKg / 1000
        const billKwh = num(b.bill_kwh) ?? 0
        const perTonne = tonnes === null || tonnes === 0 ? null : billKwh / tonnes
        const period = `${formatDate(b.period_from, locale)} – ${formatDate(b.period_to, locale)}`
        return {
            id: b.id,
            cells: {
                period,
                invoice: b.invoice_ref,
                billKwh: kwh(billKwh),
                metered: kwh(num(b.metered_kwh)),
                unmetered: kwh(num(b.unmetered_kwh)),
                input: inputKg === null ? <span className="text-[color:var(--brand-muted-text)] italic">{notWhole}</span> : fmtKg(inputKg),
                perTonne: inputKg === null ? <span className="text-[color:var(--brand-muted-text)] italic">{notWhole}</span>
                    : perTonne === null ? <span className="text-[color:var(--brand-muted-text)] italic">{t('esg.energy.noInput')}</span>
                    : kwh(perTonne),
            },
            exports: {
                period: xDate(b.period_from),
                invoice: xText(b.invoice_ref),
                billKwh: xNum(billKwh, 'qty'),
                metered: xNum(num(b.metered_kwh), 'qty'),
                unmetered: xNum(num(b.unmetered_kwh), 'qty'),
                input: inputKg === null ? xText(notWhole) : xNum(inputKg, 'qty'),
                perTonne: inputKg === null ? xText(notWhole) : perTonne === null ? xText(t('esg.energy.noInput')) : xNum(perTonne, 'qty'),
            },
        }
    })

    return (
        <ListPage title={t('esg.energy.title')} intro={t('esg.energy.intro')} maxWidth="max-w-6xl" state={{ kind: 'ok' }}>
            {reversed.size > 0 && (
                <p className="text-sm text-[color:var(--brand-muted-text)] mb-3" data-reversed>{t('esg.energy.reversedNote', { n: allBills.length - bills.length })}</p>
            )}
            <CellsTable
                columns={[
                    { key: 'period', header: t('esg.energy.colPeriod'), priority: true },
                    { key: 'invoice', header: t('esg.energy.colInvoice') },
                    { key: 'billKwh', header: t('esg.energy.colBillKwh'), align: 'right', priority: true },
                    { key: 'metered', header: t('esg.energy.colMetered'), align: 'right' },
                    { key: 'unmetered', header: t('esg.energy.colUnmetered'), align: 'right' },
                    { key: 'input', header: t('esg.energy.colInput'), align: 'right' },
                    { key: 'perTonne', header: t('esg.energy.colPerTonne'), align: 'right', priority: true },
                ]}
                rows={rows}
                empty={t('esg.energy.none')}
                sorting="client"
                exportSpec={{ name: 'esg-energy-intensity', title: t('esg.energy.title') }}
            />
            <p className="text-sm text-[color:var(--brand-muted-text)] mt-4">{t('esg.energy.basis')}</p>
        </ListPage>
    )
}
