// app/finance/electricity/[id]/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-5a-2(2026-10-08,MES-5a Step 0 Q22 · Q24 · Q25 · Q30 · Q31,Tim)· 一张电费单的分摊
// ════════════════════════════════════════════════════════════════════════════
// 【它是这张账单唯一的一笔】费用单(链过去)· 那张分录(借 2200 各炉 · 借 6200 余数 · 贷 应付或银行)· 各炉一行(依据印在每一行:
//   按记下的电量 / 按运行时长)· 被冲掉的估计。kWh 分三份说清楚:量到的 = 分给各炉 + 共用池 + 有表无单;账单 = 量到的 + 不计量。
// 【金额】只给看得见价格的人(data.view_prices,经 _masked 视图;没有就画「受限」,不画 0)。kWh 不遮。
// 【门】requireModule(MOD.finance)(与审计记录主语 electricity_allocation 的读码同一个)。本刀没有撤销一次分摊的路 —— 页面照直说。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { canViewPrices } from '@/lib/permissions'
import { getBaseCurrency } from '@/lib/currency'
import { formatAmount } from '@/lib/format'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import { MaskedValue } from '@/app/components/MaskedValue'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import CellsTable, { type CellRow } from '@/app/operation/equipment/CellsTable'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

type Alloc = {
    id: string; period_from: string; period_to: string; bill_date: string; invoice_ref: string; supplier_id: string | null; payee_name: string | null
    currency: string; bill_amount: number | null; bill_kwh: number; price_per_kwh: number | null; metered_kwh: number; allocated_kwh: number
    shared_pool_kwh: number; unallocated_metered_kwh: number; unmetered_kwh: number; allocated_amount: number | null; overhead_amount: number | null
    relieved_estimate_amount: number | null; relieved_estimate_count: number; payment_status: string; bank_account_code: string | null
    expense_id: string; journal_entry_id: string; notes: string | null; created_at: string
}
type Line = {
    id: number; run_id: string; equipment_id: string; basis: string; run_energy_kwh: number | null; run_minutes: number | null
    share: number; machine_kwh: number; kwh: number; amount: number | null
}

export default async function ElectricityAllocationPage({ params, searchParams }: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ trail?: string | string[] }>
}) {
    const denied = await requireModule(MOD.finance)
    if (denied) return denied
    const { id } = await params
    if (!UUID.test(id)) notFound()
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const [showPrices, baseCurrency] = await Promise.all([canViewPrices(), getBaseCurrency()])

    const a = mustOne(await supabase.from('electricity_allocations_masked')
        .select('id, period_from, period_to, bill_date, invoice_ref, supplier_id, payee_name, currency, bill_amount, bill_kwh, price_per_kwh, metered_kwh, allocated_kwh, shared_pool_kwh, unallocated_metered_kwh, unmetered_kwh, allocated_amount, overhead_amount, relieved_estimate_amount, relieved_estimate_count, payment_status, bank_account_code, expense_id, journal_entry_id, notes, created_at')
        .eq('id', id).maybeSingle(), 'electricity_allocations_masked') as Alloc | null
    if (!a) notFound()

    const [lineRes, expRes, jeRes, supRes, eqRes] = await Promise.all([
        supabase.from('electricity_allocation_lines_masked')
            .select('id, run_id, equipment_id, basis, run_energy_kwh, run_minutes, share, machine_kwh, kwh, amount')
            .eq('allocation_id', id).order('id'),
        supabase.from('expenses').select('id, code').eq('id', a.expense_id).maybeSingle(),
        supabase.from('journal_entries').select('id, code').eq('id', a.journal_entry_id).maybeSingle(),
        a.supplier_id ? supabase.from('supplier_lookup').select('legal_name').eq('id', a.supplier_id).maybeSingle() : Promise.resolve({ data: null, error: null }),
        supabase.from('equipment_usage').select('equipment_id, equipment_code'),
    ])
    const lines = mustRows(lineRes, 'electricity_allocation_lines_masked') as Line[]
    const exp = mustOne(expRes, 'expenses') as { id: string; code: string } | null
    const je = mustOne(jeRes, 'journal_entries') as { id: string; code: string } | null
    const sup = mustOne(supRes, 'supplier_lookup') as { legal_name: string } | null
    const eqs = mustRows(eqRes, 'equipment_usage') as { equipment_id: string; equipment_code: string }[]
    const runIds = lines.map((l) => l.run_id)
    const runs = runIds.length ? mustRows(await supabase.from('processing_runs_masked').select('id, code').in('id', runIds), 'processing_runs_masked') as { id: string; code: string }[] : []
    const runCode = new Map(runs.map((r) => [r.id, r.code]))
    const eqCode = new Map(eqs.map((e) => [e.equipment_id, e.equipment_code]))
    const money = (v: number | null) => <MaskedValue value={v === null ? null : formatAmount(Number(v), baseCurrency)} canView={showPrices} fallback="—" />
    const num = (v: number) => String(Number(v))

    const lineRows: CellRow[] = lines.map((l) => ({
        id: String(l.id),
        cells: {
            run: <Link href={`/operation/processing/${l.run_id}`} className="app-link hover:underline">{runCode.get(l.run_id) ?? '—'}</Link>,
            machine: eqCode.get(l.equipment_id) ?? '—',
            basis: <span data-line-basis={l.basis}>{l.basis === 'recorded_energy' ? t('energy.basisRecorded') : t('energy.basisRunTime')}</span>,
            own: l.run_energy_kwh === null ? '—' : num(l.run_energy_kwh),
            minutes: l.run_minutes === null ? '—' : num(l.run_minutes),
            share: `${(Number(l.share) * 100).toFixed(2)}%`,
            machineKwh: num(l.machine_kwh),
            kwh: num(l.kwh),
            amount: money(l.amount),
        },
    }))

    return (
        <ListPage title={t('energy.detailTitle', { ref: a.invoice_ref })} maxWidth="max-w-6xl" state={{ kind: 'ok' }}
                  breadcrumb={<Link href="/finance/electricity" className="app-link hover:underline text-sm">← {t('energy.listTitle')}</Link>}>
            <RecordHeader
                fields={[
                    { label: t('energy.colPeriod'), value: `${formatDate(a.period_from, locale)} – ${formatDate(a.period_to, locale)}` },
                    { label: t('energy.billDate'), value: formatDate(a.bill_date, locale) },
                    { label: t('energy.invoiceRef'), value: a.invoice_ref, mono: true },
                    { label: t('energy.supplier'), value: sup?.legal_name ?? a.payee_name ?? '—' },
                    { label: t('energy.payment'), value: a.payment_status === 'paid' ? `${t('energy.paymentPaid')} · ${a.bank_account_code ?? ''}` : t('energy.paymentUnpaid') },
                    { label: t('energy.colBillAmount', { ccy: a.currency }), value: money(a.bill_amount) },
                    { label: t('energy.billKwh'), value: `${num(a.bill_kwh)} kWh` },
                    { label: t('energy.priceLabel', { ccy: a.currency }), value: money(a.price_per_kwh) },
                    { label: t('energy.colExpense'), value: exp ? <Link href={`/finance/expenses/${exp.id}`} className="app-link hover:underline">{exp.code}</Link> : '—' },
                    { label: t('energy.journalTitle'), value: je ? <Link href={`/finance/journal/${je.id}`} className="app-link hover:underline">{je.code}</Link> : '—' },
                    { label: t('energy.postedAt'), value: formatAuditStamp(a.created_at) },
                ]}
            />
            {a.notes && <p className="mb-4 text-sm">{a.notes}</p>}

            <section data-section="allocation-split">
                <h2 className="mb-2">{t('energy.splitTitle')}</h2>
                <dl className="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-1 text-sm">
                    <dt className="text-[color:var(--brand-muted-text)]">{t('energy.sumMetered')}</dt><dd>{num(a.metered_kwh)} kWh</dd>
                    <dt className="text-[color:var(--brand-muted-text)]">{t('energy.sumToRuns')}</dt><dd>{num(a.allocated_kwh)} kWh · {money(a.allocated_amount)}</dd>
                    <dt className="text-[color:var(--brand-muted-text)]">{t('energy.sumOverhead')}</dt>
                    <dd>{money(a.overhead_amount)}
                        <span className="ml-2 text-[color:var(--brand-muted-text)]">{t('energy.overheadParts', { unmetered: num(a.unmetered_kwh), pool: num(a.shared_pool_kwh), idle: num(a.unallocated_metered_kwh) })}</span>
                    </dd>
                    <dt className="text-[color:var(--brand-muted-text)]">{t('energy.sumRelieved')}</dt><dd>{a.relieved_estimate_count} · {money(a.relieved_estimate_amount)}</dd>
                </dl>
            </section>

            <section className="mt-6" data-section="allocation-lines">
                <h2 className="mb-2">{t('energy.runsTitle')}</h2>
                <CellsTable
                    columns={[
                        { key: 'run', header: t('energy.colRun'), priority: true },
                        { key: 'machine', header: t('energy.colMachine') },
                        { key: 'basis', header: t('energy.colBasis'), priority: true },
                        { key: 'own', header: t('energy.colOwnKwh'), align: 'right' },
                        { key: 'minutes', header: t('energy.colMinutes'), align: 'right' },
                        { key: 'share', header: t('energy.colShare'), align: 'right' },
                        { key: 'machineKwh', header: t('energy.colMetered'), align: 'right' },
                        { key: 'kwh', header: t('energy.colKwh'), align: 'right' },
                        { key: 'amount', header: t('energy.colAmount', { ccy: a.currency }), align: 'right', priority: true },
                    ]}
                    rows={lineRows}
                    empty={t('energy.noRunsCovered')}
                />
                <p className="mt-2 text-sm text-[color:var(--brand-muted-text)]">{t('energy.noReversal')}</p>
            </section>

            <AuditTrail subject="electricity_allocation" id={id} show={trailCount((await searchParams).trail)} />
        </ListPage>
    )
}
