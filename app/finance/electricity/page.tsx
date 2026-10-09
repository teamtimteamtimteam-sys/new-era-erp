// app/finance/electricity/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-5a-2(2026-10-08,MES-0 Q26 · Q27;MES-5a Step 0 Q19 · Q24 · Q25 · Q32,Tim)· 电费单的分摊
// ════════════════════════════════════════════════════════════════════════════
// 【一张账单只过一次账】每一张分摊就是那张账单的唯一一笔:一张费用单、各炉的实际电费行、一张结掉它们的分录;被覆盖的炉上
//   手敲的估计被冲掉(electricity_allocations 的抬头)。这一页列出过过账的每一张(金额只给看得见价格的人,data.view_prices)。
// 【电表】每一台电表挂在哪台机器上(没挂 = 共用池)、最近一条读数 —— 设备表要加工查看码;读不到时说「受限」,不说"没有电表"。
// 【V25】共用池的电怎么摊(写下 / 清空,module.finance.edit);写下之后本版本仍然不按它摊 —— 页面照直说。
// 【门】requireModule(MOD.finance)。新建一张在 /finance/electricity/new(过账要 module.finance.edit)。审计记录:V25 的修改史。
// 【撤回】MES-5b-2(Step 0 Q22):撤回过的那一张照样列着(分摊只追加),账单号旁边标「已撤回」;撤回在那一张自己的页面上。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { can, canViewPrices } from '@/lib/permissions'
import { getBaseCurrency } from '@/lib/currency'
import { formatAmount } from '@/lib/format'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import { ListPage } from '@/app/components/ui/list-page'
import { MaskedValue } from '@/app/components/MaskedValue'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import CellsTable, { type CellRow } from '@/app/operation/equipment/CellsTable'
import SharedPoolRulePanel from './SharedPoolRulePanel'

type AllocRow = {
    id: string; period_from: string; period_to: string; bill_date: string; invoice_ref: string; currency: string
    bill_amount: number | null; bill_kwh: number; metered_kwh: number; allocated_kwh: number; allocated_amount: number | null
    overhead_amount: number | null; relieved_estimate_count: number; payment_status: string; expense_id: string
}

export default async function ElectricityPage({ searchParams }: { searchParams: Promise<{ trail?: string }> }) {
    const denied = await requireModule(MOD.finance)
    if (denied) return denied
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const [canEdit, showPrices, canSeeDevices, baseCurrency] = await Promise.all([
        can('module.finance.edit'), canViewPrices(), can('module.processing.view'), getBaseCurrency(),
    ])

    const [allocRes, settingsRes, revRes] = await Promise.all([
        supabase.from('electricity_allocations_masked')
            .select('id, period_from, period_to, bill_date, invoice_ref, currency, bill_amount, bill_kwh, metered_kwh, allocated_kwh, allocated_amount, overhead_amount, relieved_estimate_count, payment_status, expense_id')
            .order('period_from', { ascending: false }),
        supabase.from('electricity_settings').select('shared_pool_rule').maybeSingle(),
        supabase.from('electricity_allocation_reversals_masked').select('allocation_id'),
    ])
    const allocs = mustRows(allocRes, 'electricity_allocations_masked') as AllocRow[]
    const settings = mustOne(settingsRes, 'electricity_settings') as { shared_pool_rule: string | null } | null
    const reversed = new Set((mustRows(revRes, 'electricity_allocation_reversals_masked') as { allocation_id: string }[]).map((r) => r.allocation_id))
    const expIds = [...new Set(allocs.map((a) => a.expense_id))]
    const exps = expIds.length ? mustRows(await supabase.from('expenses').select('id, code').in('id', expIds), 'expenses') as { id: string; code: string }[] : []
    const expCode = new Map(exps.map((e) => [e.id, e.code]))
    const money = (v: number | null) => <MaskedValue value={v === null ? null : formatAmount(Number(v), baseCurrency)} canView={showPrices} fallback="—" />

    const allocRows: CellRow[] = allocs.map((a) => ({
        id: a.id,
        cells: {
            period: <Link href={`/finance/electricity/${a.id}`} className="app-link hover:underline">{formatDate(a.period_from, locale)} – {formatDate(a.period_to, locale)}</Link>,
            bill: <>{a.invoice_ref} · {formatDate(a.bill_date, locale)}
                {reversed.has(a.id) && <span className="ml-2 text-[color:var(--brand-muted-text)]" data-allocation-reversed="1">· {t('energy.reversedTag')}</span>}</>,
            amount: money(a.bill_amount),
            kwh: `${Number(a.bill_kwh)} / ${Number(a.metered_kwh)} / ${Number(a.allocated_kwh)}`,
            runs: money(a.allocated_amount),
            overhead: money(a.overhead_amount),
            expense: <Link href={`/finance/expenses/${a.expense_id}`} className="app-link hover:underline">{expCode.get(a.expense_id) ?? '—'}</Link>,
        },
    }))

    // 电表:设备表要加工查看码 —— 读不到时说「受限」,不把 RLS 的零行说成"没有电表"
    let meterRows: CellRow[] = []
    let poolMeters: number | null = null
    if (canSeeDevices) {
        const [mRes, rRes, eqRes] = await Promise.all([
            supabase.from('devices').select('id, code, name, equipment_id, retired_at').eq('kind', 'meter').order('code'),
            supabase.from('meter_readings_current').select('device_id, read_at, register_kwh').order('read_at', { ascending: false }),
            supabase.from('equipment_usage').select('equipment_id, equipment_code, equipment_description'),
        ])
        const meters = mustRows(mRes, 'devices') as { id: string; code: string; name: string; equipment_id: string | null; retired_at: string | null }[]
        const reads = mustRows(rRes, 'meter_readings_current') as { device_id: string; read_at: string; register_kwh: number }[]
        const eqs = mustRows(eqRes, 'equipment_usage') as { equipment_id: string; equipment_code: string; equipment_description: string | null }[]
        const latest = new Map<string, { read_at: string; register_kwh: number }>()
        for (const r of reads) if (!latest.has(r.device_id)) latest.set(r.device_id, r)
        poolMeters = meters.filter((m) => !m.equipment_id && !m.retired_at).length
        meterRows = meters.map((m) => {
            const eq = m.equipment_id ? eqs.find((e) => e.equipment_id === m.equipment_id) : null
            const last = latest.get(m.id)
            return {
                id: m.id,
                cells: {
                    meter: <Link href={`/operation/devices/${m.id}`} className="app-link hover:underline">{m.code}</Link>,
                    name: m.name + (m.retired_at ? ` · ${t('devices.retired')}` : ''),
                    machine: eq ? `${eq.equipment_code}${eq.equipment_description ? ` — ${eq.equipment_description}` : ''}` : t('energy.sharedPool'),
                    last: last ? `${Number(last.register_kwh)} kWh · ${formatAuditStamp(last.read_at)}` : t('energy.noReadingsShort'),
                },
            }
        })
    }

    return (
        <ListPage title={t('energy.listTitle')} maxWidth="max-w-6xl" state={{ kind: 'ok' }}
                  intro={t('energy.listIntro')}
                  actions={<Link href="/finance/electricity/new" className="app-link hover:underline text-sm" data-new-allocation="1">{t('energy.newLink')}</Link>}>
            <section data-section="allocations">
                <h2 className="mb-2">{t('energy.allocationsTitle')}</h2>
                <CellsTable
                    columns={[
                        { key: 'period', header: t('energy.colPeriod'), priority: true },
                        { key: 'bill', header: t('energy.colBill') },
                        { key: 'amount', header: t('energy.colBillAmount', { ccy: baseCurrency }), align: 'right', priority: true },
                        { key: 'kwh', header: t('energy.colKwhTriple') },
                        { key: 'runs', header: t('energy.colToRuns'), align: 'right' },
                        { key: 'overhead', header: t('energy.colOverhead'), align: 'right' },
                        { key: 'expense', header: t('energy.colExpense') },
                    ]}
                    rows={allocRows}
                    empty={t('energy.noAllocations')}
                />
                {!canEdit && <p className="mt-2 text-sm text-[color:var(--brand-muted-text)]">{t('energy.postNeedsEdit')}</p>}
            </section>

            <section className="mt-8" data-section="meters">
                <h2 className="mb-1">{t('energy.metersTitle')}</h2>
                <p className="mb-2 text-sm text-[color:var(--brand-muted-text)]">{t('energy.metersIntro')}</p>
                {canSeeDevices
                    ? <CellsTable
                        columns={[
                            { key: 'meter', header: t('energy.colMeter'), priority: true },
                            { key: 'name', header: t('energy.colName') },
                            { key: 'machine', header: t('energy.colMachine'), priority: true },
                            { key: 'last', header: t('energy.colLastReading') },
                        ]}
                        rows={meterRows}
                        empty={t('energy.noMeters')}
                    />
                    : <p className="text-sm" data-meters="restricted">{t('energy.metersRestricted')}</p>}
            </section>

            <SharedPoolRulePanel rule={settings?.shared_pool_rule ?? null} canEdit={canEdit} poolMeters={poolMeters} />

            <AuditTrail subject="electricity_settings" id="true" show={trailCount((await searchParams).trail)} />
        </ListPage>
    )
}
