'use client'

// MES-5a-2(2026-10-08,MES-5a Step 0 Q22 · Q24 · Q25 · Q26 · Q28,Tim):一张电费单 —— 先预览,再过账。
//   【预览就是过账会写下的东西】两个按钮调的是库里同一支 electricity_allocation_compute(AGENTS.md「一个预览的屏幕问数据库」);
//   这里一个数都不算,只画它回来的东西。输入改了,预览就作废(过账按钮回到按不下去),免得照着一份旧预览过账。
//   【必填、不给默认】时间段、账单日、账单号、金额、账单 kWh —— 它们决定期间与金额;空着时按钮按不下去,服务端也照样按名拒。
//   【币种】只有本位币(Q28);外币的账单这里不摆出来 —— 库里按名拒(ELECTRICITY_BILL_CURRENCY_NOT_BASE)。
//   【付款】未付 = 应付挂在供应商上,之后走付款申请(Q29);已付 = 本位币那个银行户。
//   过账要 module.finance.edit(看得见、按不下去、说出码 —— DBLOCK-1)。
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { Button } from '@/app/components/ui/button'
import { DatePicker } from '@/app/components/ui/date-picker'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { previewAllocation, postAllocation, type AllocationInput, type AllocationPreview } from '../actions'

type Opt = { value: string; label: string }
type RunRow = AllocationPreview['runs'][number]
type MachineRow = AllocationPreview['machines'][number]

export default function NewAllocationForm({ canEdit, baseCurrency, suppliers }: { canEdit: boolean; baseCurrency: string; suppliers: Opt[] }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [preview, setPreview] = useState<AllocationPreview | null>(null)
    const [f, setFState] = useState<AllocationInput>({
        periodFrom: '', periodTo: '', billDate: '', invoiceRef: '', billAmount: '', billKwh: '',
        paymentStatus: 'unpaid', supplierId: '', payeeName: '', notes: '',
    })
    // 任何一格改了,预览就作废
    const setF = (next: AllocationInput) => { setFState(next); setPreview(null) }
    const lbl = 'block text-xs font-medium text-[color:var(--brand-muted-text)] mb-1'
    const muted = 'text-sm text-[color:var(--brand-muted-text)]'
    const money = (v: number) => `${Number(v).toFixed(2)} ${baseCurrency}`

    const previewMissing = f.periodFrom === '' || f.periodTo === '' || f.billAmount.trim() === '' || f.billKwh.trim() === ''
    const postMissing = previewMissing || f.billDate === '' || f.invoiceRef.trim() === '' || (f.paymentStatus === 'unpaid' && f.supplierId === '')

    const machineColumns: Column<MachineRow>[] = [
        { key: 'machine', header: t('energy.colMachine'), priority: true, render: (m) => `${m.equipment_code}${m.description ? ` — ${m.description}` : ''}` },
        {
            key: 'kwh', header: t('energy.colMetered'), priority: true, align: 'right',
            render: (m) => (m.measured ? `${m.kwh} kWh` : <span className="text-amber-700" data-machine-measured="no">{t('energy.notMeasured')}</span>),
        },
        { key: 'basis', header: t('energy.colBasis'), render: (m) => (m.basis === 'recorded_energy' ? t('energy.basisRecorded') : m.basis === 'run_time' ? t('energy.basisRunTime') : '—') },
        { key: 'runs', header: t('energy.colRuns'), align: 'right', render: (m) => String(m.runs) },
        { key: 'meters', header: t('energy.colMeters'), render: (m) => m.meters.map((x) => `${x.code} (${x.readings})`).join(', ') },
    ]
    const runColumns: Column<RunRow>[] = [
        { key: 'run', header: t('energy.colRun'), priority: true, render: (r) => <Link href={`/operation/processing/${r.run_id}`} className="app-link hover:underline">{r.code}</Link> },
        { key: 'machine', header: t('energy.colMachine'), render: (r) => r.equipment_code },
        { key: 'basis', header: t('energy.colBasis'), priority: true, render: (r) => (r.basis === 'recorded_energy' ? t('energy.basisRecorded') : t('energy.basisRunTime')) },
        { key: 'own', header: t('energy.colOwnKwh'), align: 'right', render: (r) => (r.own_kwh === null ? '—' : `${r.own_kwh}`) },
        { key: 'minutes', header: t('energy.colMinutes'), align: 'right', render: (r) => (r.minutes === null ? '—' : `${r.minutes}`) },
        { key: 'share', header: t('energy.colShare'), align: 'right', render: (r) => `${(Number(r.share) * 100).toFixed(2)}%` },
        { key: 'kwh', header: t('energy.colKwh'), align: 'right', render: (r) => `${r.kwh}` },
        { key: 'amount', header: t('energy.colAmount', { ccy: baseCurrency }), align: 'right', priority: true, render: (r) => Number(r.amount).toFixed(2) },
    ]

    return (
        <div className="space-y-4" data-section="new-allocation">
            <div className="border border-gray-200 rounded p-3 space-y-3" data-allocation-form="1">
                <div className="flex flex-wrap items-end gap-3">
                    <div className="min-w-0 max-w-full">
                        <span className={lbl}>{t('energy.periodFrom')}</span>
                        <DatePicker kind="date" value={f.periodFrom} onChange={(v) => setF({ ...f, periodFrom: v })} className="flex" />
                    </div>
                    <div className="min-w-0 max-w-full">
                        <span className={lbl}>{t('energy.periodTo')}</span>
                        <DatePicker kind="date" value={f.periodTo} onChange={(v) => setF({ ...f, periodTo: v })} className="flex" />
                    </div>
                    <label className="block">
                        <span className={lbl}>{t('energy.billAmount', { ccy: baseCurrency })}</span>
                        <input type="number" min="0" step="0.01" value={f.billAmount} onChange={(e) => setF({ ...f, billAmount: e.target.value })} className={`${CONTROL_INPUT} w-32`} />
                    </label>
                    <label className="block">
                        <span className={lbl}>{t('energy.billKwh')}</span>
                        <input type="number" min="0" step="any" value={f.billKwh} onChange={(e) => setF({ ...f, billKwh: e.target.value })} className={`${CONTROL_INPUT} w-32`} />
                    </label>
                </div>
                <p className={muted}>{t('energy.baseOnly', { ccy: baseCurrency })}</p>
                <div className="flex flex-wrap items-end gap-3">
                    <div className="min-w-0 max-w-full">
                        <span className={lbl}>{t('energy.billDate')}</span>
                        <DatePicker kind="date" value={f.billDate} onChange={(v) => setF({ ...f, billDate: v })} className="flex" />
                    </div>
                    <label className="block">
                        <span className={lbl}>{t('energy.invoiceRef')}</span>
                        <input type="text" value={f.invoiceRef} onChange={(e) => setF({ ...f, invoiceRef: e.target.value })} className={`${CONTROL_INPUT} w-40`} />
                    </label>
                    <label className="block min-w-0 max-w-full">
                        <span className={lbl}>{t('energy.payment')}</span>
                        <select value={f.paymentStatus} onChange={(e) => setF({ ...f, paymentStatus: e.target.value === 'paid' ? 'paid' : 'unpaid' })} className={`${CONTROL_SELECT} max-w-full`}>
                            <option value="unpaid">{t('energy.paymentUnpaid')}</option>
                            <option value="paid">{t('energy.paymentPaid')}</option>
                        </select>
                    </label>
                    <label className="block min-w-0 max-w-full">
                        <span className={lbl}>{t('energy.supplier')}</span>
                        <select value={f.supplierId} onChange={(e) => setF({ ...f, supplierId: e.target.value })} className={`${CONTROL_SELECT} max-w-full`}>
                            <option value="">{f.paymentStatus === 'unpaid' ? t('energy.pickSupplier') : t('energy.noSupplier')}</option>
                            {suppliers.map((s) => <option key={s.value} value={s.value}>{s.label}</option>)}
                        </select>
                    </label>
                </div>
                <label className="block">
                    <span className={lbl}>{t('energy.notes')}</span>
                    <input type="text" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} className={`${CONTROL_INPUT} w-full`} />
                </label>
                <p className={muted}>{f.paymentStatus === 'unpaid' ? t('energy.unpaidHint') : t('energy.paidHint')}</p>
                {error && <p className="text-sm text-red-700" role="alert">{error}</p>}
                <div className="flex flex-wrap gap-2">
                    <Button type="button" variant="secondary" disabled={pending || previewMissing}
                            onClick={() => { setError(null); start(async () => {
                                const r = await previewAllocation(f)
                                if (r.error) { setError(r.error); setPreview(null); return }
                                setPreview(r.preview ?? null)
                            }) }}>
                        {t('energy.previewButton')}
                    </Button>
                    <PermissionGate code="module.finance.edit" allowed={canEdit}>
                        <Button type="button" disabled={pending || postMissing || !preview}
                                onClick={() => { setError(null); start(async () => {
                                    const r = await postAllocation(f)
                                    if (r.error) { setError(r.error); return }
                                    router.push(`/finance/electricity/${r.allocationId}`)
                                }) }}>
                            {t('energy.postButton')}
                        </Button>
                    </PermissionGate>
                </div>
                {!preview && <p className={muted}>{t('energy.previewFirst')}</p>}
            </div>

            {preview && (
                <section data-section="allocation-preview" className="space-y-4">
                    <h2>{t('energy.previewTitle')}</h2>
                    <dl className="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-1 text-sm">
                        <dt className="text-[color:var(--brand-muted-text)]">{t('energy.sumBill')}</dt>
                        <dd>{money(preview.bill_amount)} · {preview.bill_kwh} kWh · {t('energy.pricePerKwh', { price: String(preview.price_per_kwh), ccy: baseCurrency })}</dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('energy.sumMetered')}</dt>
                        <dd>{preview.metered_kwh} kWh</dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('energy.sumToRuns')}</dt>
                        <dd data-preview-allocated={preview.allocated_amount}>{preview.allocated_kwh} kWh · {money(preview.allocated_amount)}</dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('energy.sumOverhead')}</dt>
                        <dd data-preview-overhead={preview.overhead_amount}>{money(preview.overhead_amount)}
                            <span className={`ml-2 ${muted}`}>{t('energy.overheadParts', { unmetered: String(preview.unmetered_kwh), pool: String(preview.shared_pool_kwh), idle: String(preview.unallocated_metered_kwh) })}</span>
                        </dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('energy.sumRelieved')}</dt>
                        <dd>{preview.relieved_estimate_count} · {money(preview.relieved_estimate_amount)}</dd>
                    </dl>
                    {preview.shared_pool_rule && <p className={muted}>{t('energy.ruleNotApplied', { rule: preview.shared_pool_rule })}</p>}

                    <div>
                        <h3 className="mb-2 text-sm font-medium">{t('energy.machinesTitle')}</h3>
                        <DataTable rows={preview.machines} columns={machineColumns} rowKey={(m) => m.equipment_id} phone={{ mode: 'columns' }} empty={t('energy.noMachines')} />
                        {preview.pool_meters.length > 0 && (
                            <p className={`mt-2 ${muted}`}>{t('energy.poolMetersLine', { meters: preview.pool_meters.map((m) => `${m.code} ${m.measured ? `${m.kwh} kWh` : t('energy.notMeasured')}`).join(', ') })}</p>
                        )}
                    </div>
                    <div>
                        <h3 className="mb-2 text-sm font-medium">{t('energy.runsTitle')}</h3>
                        <DataTable rows={preview.runs} columns={runColumns} rowKey={(r) => r.run_id} phone={{ mode: 'columns' }} empty={t('energy.noRunsCovered')} />
                    </div>
                    <div>
                        <h3 className="mb-2 text-sm font-medium">{t('energy.estimatesTitle')}</h3>
                        {preview.estimates.length === 0
                            ? <p className={muted}>{t('energy.noEstimates')}</p>
                            : <ul className="text-sm list-disc pl-5">{preview.estimates.map((e) => <li key={e.id}>{e.run_code} · {money(e.amount)}</li>)}</ul>}
                    </div>
                    <div>
                        <h3 className="mb-2 text-sm font-medium">{t('energy.journalTitle')}</h3>
                        <ul className="text-sm" data-preview-journal="1">
                            {preview.journal.map((j, i) => (
                                <li key={i}>{j.side === 'debit' ? t('energy.debit') : t('energy.credit')} {j.account_code} · {money(j.amount_ccy)} <span className={muted}>{j.line_memo}</span></li>
                            ))}
                        </ul>
                    </div>
                </section>
            )}
        </div>
    )
}
