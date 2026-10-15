'use client'

// app/quality/ncr/NcrForm.tsx
// MES-6b-1(MES-6b Step 0 Q7):开一张不合格报告 —— 一批(页面已定)、来源(手动 / 客户投诉;越限由系统开,来料检验留给 MES-7b)、描述(必填)、
//   可选地指一份化验、一件争议、(产出批)一张销售单。描述空着保存钮按不下去,服务端【独立】拒空(NCR_DESCRIPTION_REQUIRED)。
//   缺 module.quality.edit 时整张表单在 PermissionGate 里,看得见、按不动、说出那个码。
import { CONTROL_SELECT, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { openNcr } from '../actions'
import { NCR_OPEN_SOURCES, ncrSourceKey } from '../qualityTypes'

export type Option = { id: string; label: string }

export default function NcrForm({ batchKind, batchId, assays, disputes, salesOrders, salesOrdersRestricted, canEdit }: {
    batchKind: 'inbound' | 'output'
    batchId: string
    assays: Option[]
    disputes: Option[]
    salesOrders: Option[]
    salesOrdersRestricted: boolean
    canEdit: boolean
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [source, setSource] = useState('')
    const [description, setDescription] = useState('')
    const [assayId, setAssayId] = useState('')
    const [disputeId, setDisputeId] = useState('')
    const [salesOrderId, setSalesOrderId] = useState('')

    const canSave = !!source && description.trim() !== '' && !isPending

    function save() {
        setError('')
        startTransition(async () => {
            const res = await openNcr({
                source, description,
                inboundBatchId: batchKind === 'inbound' ? batchId : null,
                outputBatchId: batchKind === 'output' ? batchId : null,
                assayId: assayId || null,
                disputeId: disputeId || null,
                salesOrderId: batchKind === 'output' && salesOrderId ? salesOrderId : null,
            })
            if (res?.error) setError(res.error)
        })
    }

    return (
        <PermissionGate code="module.quality.edit" allowed={canEdit}>
            <div className="space-y-4 max-w-3xl" data-form="ncr">
                {error && <p className="text-sm text-red-600">{error}</p>}
                <p className="text-sm bg-amber-50 border border-amber-300 px-3 py-2 rounded">{t('quality.ncr.holdWarning')}</p>
                <label className="block text-sm max-w-md">
                    <span className="block mb-1">{t('quality.ncr.source')} <span className="text-red-600">*</span></span>
                    <select value={source} onChange={(e) => setSource(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="source">
                        <option value="" disabled>{t('quality.ncr.pickSource')}</option>
                        {NCR_OPEN_SOURCES.map((s) => <option key={s} value={s}>{t(ncrSourceKey(s))}</option>)}
                    </select>
                    <span className="block mt-1 text-xs text-[color:var(--brand-muted-text)]">{t('quality.ncr.sourceWhy')}</span>
                </label>
                <label className="block text-sm">
                    <span className="block mb-1">{t('quality.ncr.description')} <span className="text-red-600">*</span></span>
                    <textarea value={description} onChange={(e) => setDescription(e.target.value)} rows={3} className={`${CONTROL_TEXTAREA} w-full`}
                              placeholder={t('quality.ncr.descriptionPlaceholder')} data-field="description" />
                </label>
                <div className="flex flex-wrap gap-4">
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        <span className="block mb-1">{t('quality.ncr.linkAssay')}</span>
                        <select value={assayId} onChange={(e) => setAssayId(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="assay_result_id">
                            <option value="">{t('quality.ncr.none')}</option>
                            {assays.map((a) => <option key={a.id} value={a.id}>{a.label}</option>)}
                        </select>
                    </label>
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        <span className="block mb-1">{t('quality.ncr.linkDispute')}</span>
                        <select value={disputeId} onChange={(e) => setDisputeId(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="assay_dispute_id">
                            <option value="">{t('quality.ncr.none')}</option>
                            {disputes.map((d) => <option key={d.id} value={d.id}>{d.label}</option>)}
                        </select>
                    </label>
                </div>
                {batchKind === 'output' && (
                    <label className="block text-sm max-w-md">
                        <span className="block mb-1">{t('quality.ncr.linkSalesOrder')}</span>
                        <select value={salesOrderId} onChange={(e) => setSalesOrderId(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="sales_order_id">
                            <option value="">{t('quality.ncr.none')}</option>
                            {salesOrders.map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}
                        </select>
                        <span className="block mt-1 text-xs text-[color:var(--brand-muted-text)]">
                            {salesOrdersRestricted ? t('quality.ncr.salesOrdersRestricted') : t('quality.ncr.salesOrderWhy')}
                        </span>
                    </label>
                )}
                <Button type="button" disabled={!canSave} onClick={save}>
                    {isPending ? t('common.saving') : t('quality.ncr.save')}
                </Button>
            </div>
        </PermissionGate>
    )
}
