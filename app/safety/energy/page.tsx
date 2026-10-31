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
// ★ ESG-2(Tim 2026-10-31 Q1 · Q2 · Q3):【Scope 2】是这一页上的一列与一段按月 —— 每张单 = kWh × 那张单的年份(账期结束那天)的电网因子 ÷ 1000(tCO2;
//   EMA 的因子只含 CO2),那一年没有就用更早最近的一年并照直说;一个都用不上 →「没设因子」,从不读成 0。按月那一段【按天摊】(apportioned by days),
//   年初至今 = 今年到这个月为止各月之和;有一个月没设因子,年初至今也说「没设因子」。算术只在库里(esg_scope2_bills · esg_scope2_monthly),
//   这一页只排开。因子在页底那一块设(action.manage_esg;更正是带理由的新版本)。
// 【门】注册表 /safety/energy = 财务或加工查看码任一 —— 电费单视图的门;平衡视图的门(加工 · 财务 · 库存)包含这两个。
// ════════════════════════════════════════════════════════════════════════════
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { formatDate, formatDateTime, formatMonth, addDaysIso, addMonthsIso } from '@/lib/dates'
import { fmtKg, num } from '@/lib/massFormat'
import { ListPage } from '@/app/components/ui/list-page'
import CellsTable, { type CellRow } from '@/app/operation/equipment/CellsTable'
import { xText, xNum, xDate } from '@/lib/export/cells'
import { readAll } from '@/lib/readAll'
import { can } from '@/lib/permissions'
import { businessToday } from '@/lib/format'
import { loadActorNames } from '@/app/components/ActorName'
import Link from 'next/link'
import GridFactorPanel, { type FactorVersion } from './GridFactorPanel'

type Scope2 = { allocation_id: string; bill_year: number; factor_year: number | null; kg_co2_per_kwh: number | string | null; tco2: number | string | null }
type Scope2Month = { month: string; kwh: number | string; tco2: number | string | null; factor_missing: boolean; bills: number }
type FactorRow = { id: number; factor_year: number; kg_co2_per_kwh: number | string; source: string; reason: string | null; recorded_at: string; recorded_by: string | null }
const tco2 = (v: number | null) => (v === null ? '—' : new Intl.NumberFormat('en-US', { minimumFractionDigits: 3, maximumFractionDigits: 3 }).format(v))

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

export default async function EnergyIntensityPage({ searchParams }: { searchParams: Promise<{ year?: string }> }) {
    const denied = await requireFunction(FN.esgEnergy)
    if (denied) return denied
    const sp = await searchParams
    const today = businessToday()
    const thisYear = Number(today.slice(0, 4))
    const asked = Number(sp.year)
    const year = Number.isInteger(asked) && asked >= 2000 && asked <= thisYear ? asked : thisYear
    const lastMonth = year === thisYear ? Number(today.slice(5, 7)) : 12

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const [billRes, revRes, inRes, s2Res, s2mRes, facRes, canManage] = await Promise.all([
        readAll(() => supabase.from('electricity_allocations_masked')
            .select('id, period_from, period_to, invoice_ref, bill_kwh, metered_kwh, unmetered_kwh')
            .order('period_from', { ascending: false }), { label: 'electricity_allocations_masked' }),
        readAll(() => supabase.from('electricity_allocation_reversals_masked').select('allocation_id'), { label: 'electricity_allocation_reversals_masked' }),
        supabase.from('processing_balance_monthly').select('month, qty').eq('scope', 'plant').eq('line', 'input'),
        readAll(() => supabase.rpc('esg_scope2_bills'), { label: 'esg_scope2_bills', key: 'allocation_id' }),
        supabase.rpc('esg_scope2_monthly', { p_year: year }),   // unpaged-ok: 恒为 12 行(一年的 12 个月)
        readAll(() => supabase.from('grid_emission_factors').select('id, factor_year, kg_co2_per_kwh, source, reason, recorded_at, recorded_by')
            .order('factor_year', { ascending: false }).order('id', { ascending: false }), { label: 'grid_emission_factors' }),
        can('action.manage_esg'),
    ])
    const reversed = new Set((mustRows(revRes, 'electricity_allocation_reversals_masked') as { allocation_id: string }[]).map((r) => r.allocation_id))
    const allBills = mustRows(billRes, 'electricity_allocations_masked') as unknown as Bill[]
    const bills = allBills.filter((b) => !reversed.has(b.id))
    const inputByMonth = new Map<string, number>()
    for (const r of mustRows(inRes, 'processing_balance_monthly') as { month: string; qty: number | string | null }[]) {
        const k = String(r.month).slice(0, 10)
        inputByMonth.set(k, (inputByMonth.get(k) ?? 0) + (num(r.qty) ?? 0))
    }

    const scope2 = new Map((mustRows(s2Res, 'esg_scope2_bills') as unknown as Scope2[]).map((r) => [r.allocation_id, r]))
    const factorNotSet = t('esg.energy.factorNotSet')
    const notWhole = t('esg.energy.notWholeMonths')
    const rows: CellRow[] = bills.map((b) => {
        const months = wholeMonths(b.period_from, b.period_to)
        const inputKg = months ? months.reduce((s, m) => s + (inputByMonth.get(m) ?? 0), 0) : null
        const tonnes = inputKg === null ? null : inputKg / 1000
        const billKwh = num(b.bill_kwh) ?? 0
        const perTonne = tonnes === null || tonnes === 0 ? null : billKwh / tonnes
        const period = `${formatDate(b.period_from, locale)} – ${formatDate(b.period_to, locale)}`
        const s2 = scope2.get(b.id)
        const s2t = s2 ? num(s2.tco2) : null
        const fallback = s2 && s2.factor_year !== null && s2.factor_year !== s2.bill_year
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
                scope2: s2t === null ? <span className="text-[color:var(--brand-muted-text)] italic" data-scope2="not-set">{factorNotSet}</span>
                    : <span data-scope2="value">{tco2(s2t)}{fallback && <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('esg.energy.factorFallback', { year: s2!.factor_year! })}</span>}</span>,
            },
            exports: {
                period: xDate(b.period_from),
                invoice: xText(b.invoice_ref),
                billKwh: xNum(billKwh, 'qty'),
                metered: xNum(num(b.metered_kwh), 'qty'),
                unmetered: xNum(num(b.unmetered_kwh), 'qty'),
                input: inputKg === null ? xText(notWhole) : xNum(inputKg, 'qty'),
                perTonne: inputKg === null ? xText(notWhole) : perTonne === null ? xText(t('esg.energy.noInput')) : xNum(perTonne, 'qty'),
                scope2: s2t === null ? xText(factorNotSet) : xNum(s2t, 'qty'),
            },
        }
    })

    // ── 按月(按天摊)与年初至今 ──
    const months = (mustRows(s2mRes, 'esg_scope2_monthly') as Scope2Month[]).filter((m) => Number(String(m.month).slice(5, 7)) <= lastMonth)
    const ytdMissing = months.some((m) => m.factor_missing)
    const ytdKwh = months.reduce((a, m) => a + (num(m.kwh) ?? 0), 0)
    const ytdT = ytdMissing ? null : months.reduce((a, m) => a + (num(m.tco2) ?? 0), 0)
    const monthRows: CellRow[] = months.map((m) => {
        const k = String(m.month).slice(0, 10)
        const none = m.bills === 0
        const tv = m.factor_missing ? null : num(m.tco2)
        return {
            id: k,
            cells: {
                month: formatMonth(k, locale),
                kwh: none ? <span className="text-[color:var(--brand-muted-text)] italic">{t('esg.energy.noBillThisMonth')}</span> : kwh(num(m.kwh)),
                scope2: none ? '—' : tv === null ? <span className="text-[color:var(--brand-muted-text)] italic">{factorNotSet}</span> : tco2(tv),
                bills: String(m.bills),
            },
            exports: {
                month: xDate(k),
                kwh: none ? xText(t('esg.energy.noBillThisMonth')) : xNum(num(m.kwh), 'qty'),
                scope2: none ? xText('') : tv === null ? xText(factorNotSet) : xNum(tv, 'qty'),
                bills: xNum(m.bills, 'qty'),
            },
        }
    })

    // ── 电网因子:每一年现在那一个版本 + 换过的版本 ──
    const facs = mustRows(facRes, 'grid_emission_factors') as FactorRow[]
    const names = await loadActorNames(supabase, facs.map((f) => f.recorded_by))
    const who = (u: string | null) => (u && names.names.get(u)) || (names.restricted ? t('common.restricted') : t('esg.someone'))
    // 读的次序是 年 ↓、id ↓ —— 每一年遇到的第一行就是它最后一个版本(id 是 identity,记录先后),也就是现在用的那一个
    const seenYears = new Set<number>()
    const versions: FactorVersion[] = facs.map((f) => ({
        id: f.id, year: f.factor_year, value: String(Number(f.kg_co2_per_kwh)), source: f.source, reason: f.reason,
        current: !seenYears.has(f.factor_year) && (seenYears.add(f.factor_year), true),
        line: t('esg.energy.factorSetBy', { who: who(f.recorded_by), at: formatDateTime(f.recorded_at, locale) }),
    }))

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
                    { key: 'scope2', header: t('esg.energy.colScope2'), align: 'right', priority: true },
                ]}
                rows={rows}
                empty={t('esg.energy.none')}
                sorting="client"
                exportSpec={{ name: 'esg-energy-intensity', title: t('esg.energy.title') }}
            />
            <p className="text-sm text-[color:var(--brand-muted-text)] mt-4">{t('esg.energy.basis')}</p>

            <section className="mt-8" data-section="scope2-monthly" aria-label={t('esg.energy.monthlyTitle', { year })}>
                <h2 className="mb-1">{t('esg.energy.monthlyTitle', { year })}</h2>
                <p className="text-sm text-[color:var(--brand-muted-text)] mb-2 max-w-3xl">{t('esg.energy.monthlyIntro')}</p>
                <p className="text-sm mb-2 flex flex-wrap gap-x-4">
                    {year > 2000 && <Link href={`?year=${year - 1}`} className="app-link hover:underline">{t('esg.energy.prevYear', { year: year - 1 })}</Link>}
                    {year < thisYear && <Link href={`?year=${year + 1}`} className="app-link hover:underline">{t('esg.energy.nextYear', { year: year + 1 })}</Link>}
                </p>
                <p className="text-sm font-medium mb-3" data-scope2-ytd={ytdT === null ? 'not-set' : 'value'}>
                    {ytdT === null
                        ? t('esg.energy.ytdNotSet', { year, kwh: kwh(ytdKwh) })
                        : t('esg.energy.ytdLine', { year, kwh: kwh(ytdKwh), t: tco2(ytdT) })}
                </p>
                <CellsTable
                    columns={[
                        { key: 'month', header: t('esg.energy.colMonth'), priority: true },
                        { key: 'kwh', header: t('esg.energy.colMonthKwh'), align: 'right', priority: true },
                        { key: 'scope2', header: t('esg.energy.colScope2'), align: 'right', priority: true },
                        { key: 'bills', header: t('esg.energy.colBills'), align: 'right' },
                    ]}
                    rows={monthRows}
                    empty={t('esg.energy.none')}
                    sorting="client"
                    exportSpec={{ name: `esg-scope2-monthly-${year}`, title: t('esg.energy.monthlyTitle', { year }) }}
                />
            </section>

            <GridFactorPanel versions={versions} canManage={canManage} defaultYear={thisYear} />
        </ListPage>
    )
}
