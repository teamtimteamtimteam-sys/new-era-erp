'use client'

// app/quality/samples/SampleForm.tsx
// MES-6a-1(MES-6a Step 0 Q7–Q10):取一份样品 —— 一批(页面已定)、种类、取样日、克数、放在哪、(产出批)哪张销售单、(交叉污染)哪一次抽检。
//   【取样日没有默认值】决定留样日的日子必填:空着保存钮按不下去,服务端【独立】拒空(SAMPLE_DATE_REQUIRED)。
//   【留到哪一天不在这里算】由 record_sample 按合同天数 → V16 → 尚未设定 抄下;保存之后在样品页上读。
//   缺 module.quality.edit 时整张表单在 PermissionGate 里,看得见、按不动、说出那个码。
import { CONTROL_INPUT, CONTROL_SELECT, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { DatePicker } from '@/app/components/ui/date-picker'
import { businessToday } from '@/lib/format'
import { recordSample } from '../actions'
import { SAMPLE_KINDS, sampleKindKey } from '../qualityTypes'

export type Option = { id: string; label: string }

export default function SampleForm({ batchKind, batchId, locations, salesOrders, checks, canEdit }: {
    batchKind: 'inbound' | 'output'
    batchId: string
    locations: Option[]
    salesOrders: Option[]
    checks: Option[]
    canEdit: boolean
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [kind, setKind] = useState('')
    const [takenOn, setTakenOn] = useState('')
    const [dateInvalid, setDateInvalid] = useState(false)
    const [massG, setMassG] = useState('')
    const [locationId, setLocationId] = useState('')
    const [salesOrderId, setSalesOrderId] = useState('')
    const [checkId, setCheckId] = useState('')
    const [notes, setNotes] = useState('')

    const canSave = !!kind && !!takenOn && !dateInvalid && !isPending

    function save() {
        setError('')
        startTransition(async () => {
            const res = await recordSample({
                kind, takenOn,
                inboundBatchId: batchKind === 'inbound' ? batchId : null,
                outputBatchId: batchKind === 'output' ? batchId : null,
                massG,
                salesOrderId: batchKind === 'output' && salesOrderId ? salesOrderId : null,
                contaminationCheckId: kind === 'contamination' && checkId ? checkId : null,
                storageLocationId: locationId || null,
                notes,
            })
            if (res?.error) setError(res.error)
        })
    }

    return (
        <PermissionGate code="module.quality.edit" allowed={canEdit}>
            <div className="space-y-4 max-w-3xl" data-form="sample">
                {error && <p className="text-sm text-red-600">{error}</p>}
                <div className="flex flex-wrap gap-4">
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        <span className="block mb-1">{t('quality.form.kind')} <span className="text-red-600">*</span></span>
                        <select value={kind} onChange={(e) => setKind(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="kind">
                            <option value="" disabled>{t('quality.form.pickKind')}</option>
                            {SAMPLE_KINDS.map((k) => <option key={k} value={k}>{t(sampleKindKey(k))}</option>)}
                        </select>
                        <span className="block mt-1 text-xs text-[color:var(--brand-muted-text)]">{t('quality.form.kindWhy')}</span>
                    </label>
                    <div className="block text-sm">
                        <span className="block mb-1">{t('quality.form.takenOn')} <span className="text-red-600">*</span></span>
                        <DatePicker value={takenOn} onChange={setTakenOn} onInvalidChange={setDateInvalid} max={businessToday()}
                                    required aria-label={t('quality.form.takenOn')} />
                    </div>
                    <label className="block text-sm">
                        <span className="block mb-1">{t('quality.form.massG')}</span>
                        <input type="number" inputMode="decimal" min={0} step="any" value={massG} onChange={(e) => setMassG(e.target.value)}
                               className={`${CONTROL_INPUT} w-32`} data-field="mass_g" />
                    </label>
                </div>
                <div className="flex flex-wrap gap-4">
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        <span className="block mb-1">{t('quality.form.location')}</span>
                        <select value={locationId} onChange={(e) => setLocationId(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="storage_location_id">
                            <option value="">{t('quality.noLocation')}</option>
                            {locations.map((l) => <option key={l.id} value={l.id}>{l.label}</option>)}
                        </select>
                    </label>
                    {batchKind === 'output' && (
                        <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                            <span className="block mb-1">{t('quality.form.salesOrder')}</span>
                            <select value={salesOrderId} onChange={(e) => setSalesOrderId(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="sales_order_id">
                                <option value="">{t('quality.form.noSalesOrder')}</option>
                                {salesOrders.map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}
                            </select>
                            <span className="block mt-1 text-xs text-[color:var(--brand-muted-text)]">{t('quality.form.salesOrderWhy')}</span>
                        </label>
                    )}
                </div>
                {kind === 'contamination' && (
                    <label className="block text-sm max-w-md">
                        <span className="block mb-1">{t('quality.form.check')}</span>
                        <select value={checkId} onChange={(e) => setCheckId(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="contamination_check_id">
                            <option value="">{t('quality.form.noCheck')}</option>
                            {checks.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}
                        </select>
                        {checks.length === 0 && <span className="block mt-1 text-xs text-[color:var(--brand-muted-text)]">{t('quality.form.noChecksForBatch')}</span>}
                    </label>
                )}
                <label className="block text-sm">
                    <span className="block mb-1">{t('quality.form.notes')}</span>
                    <textarea value={notes} onChange={(e) => setNotes(e.target.value)} rows={2} className={`${CONTROL_TEXTAREA} w-full`} />
                </label>
                <p className="text-xs text-[color:var(--brand-muted-text)]">{t('quality.form.retentionWhy')}</p>
                <Button type="button" disabled={!canSave} onClick={save}>
                    {isPending ? t('common.saving') : t('quality.form.save')}
                </Button>
            </div>
        </PermissionGate>
    )
}
