'use client'

// app/quality/disputes/OpenDisputeForm.tsx
// MES-6a-1(MES-6a Step 0 Q16 · Q17):立一件化验争议 —— 同一批的一份我们的结果、一份对手方的结果、一句理由;卖方可以指一张销售单
//   (那张单挂着的合同里的分歧容差与仲裁费规则在立案时抄进争议,以后不改)。
//   【立不立是人的决定】这里不判两份差多少(Q17);差多少、超没超在争议页上读 assay_dispute_rows。
//   理由空着保存钮按不下去,服务端【独立】拒空(ASSAY_DISPUTE_REASON_REQUIRED)。缺 module.quality.edit 时整张表单看得见、按不动、说出码。
import { CONTROL_SELECT, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { openDispute } from '../actions'

export type AssayOption = { id: string; label: string }

export default function OpenDisputeForm({ batchKind, ours, counterparty, salesOrders, canEdit }: {
    batchKind: 'inbound' | 'output'
    ours: AssayOption[]
    counterparty: AssayOption[]
    salesOrders: AssayOption[]
    canEdit: boolean
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [ourId, setOurId] = useState('')
    const [cpId, setCpId] = useState('')
    const [soId, setSoId] = useState('')
    const [reason, setReason] = useState('')
    const canSave = !!ourId && !!cpId && reason.trim() !== '' && !isPending

    function save() {
        setError('')
        startTransition(async () => {
            const res = await openDispute({ ourAssayId: ourId, counterpartyAssayId: cpId, reason, salesOrderId: batchKind === 'output' && soId ? soId : null })
            if (res?.error) setError(res.error)
        })
    }

    return (
        <PermissionGate code="module.quality.edit" allowed={canEdit}>
            <div className="space-y-4 max-w-3xl" data-form="open-dispute">
                {error && <p className="text-sm text-red-600">{error}</p>}
                {(ours.length === 0 || counterparty.length === 0) && (
                    <p className="text-sm text-amber-700">{t('quality.disputeForm.needBoth')}</p>
                )}
                <div className="flex flex-wrap gap-4">
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        <span className="block mb-1">{t('quality.disputeForm.ours')} <span className="text-red-600">*</span></span>
                        <select value={ourId} onChange={(e) => setOurId(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="our_assay_id">
                            <option value="" disabled>{t('quality.disputeForm.pickAssay')}</option>
                            {ours.map((a) => <option key={a.id} value={a.id}>{a.label}</option>)}
                        </select>
                    </label>
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        <span className="block mb-1">{t('quality.disputeForm.counterparty')} <span className="text-red-600">*</span></span>
                        <select value={cpId} onChange={(e) => setCpId(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="counterparty_assay_id">
                            <option value="" disabled>{t('quality.disputeForm.pickAssay')}</option>
                            {counterparty.map((a) => <option key={a.id} value={a.id}>{a.label}</option>)}
                        </select>
                    </label>
                </div>
                {batchKind === 'output' && (
                    <label className="block text-sm max-w-md">
                        <span className="block mb-1">{t('quality.form.salesOrder')}</span>
                        <select value={soId} onChange={(e) => setSoId(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="sales_order_id">
                            <option value="">{t('quality.form.noSalesOrder')}</option>
                            {salesOrders.map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}
                        </select>
                        <span className="block mt-1 text-xs text-[color:var(--brand-muted-text)]">{t('quality.disputeForm.salesOrderWhy')}</span>
                    </label>
                )}
                <label className="block text-sm">
                    <span className="block mb-1">{t('quality.disputeForm.reason')} <span className="text-red-600">*</span></span>
                    <textarea value={reason} onChange={(e) => setReason(e.target.value)} rows={3} placeholder={t('quality.disputeForm.reasonPlaceholder')}
                              className={`${CONTROL_TEXTAREA} w-full`} data-field="reason" />
                </label>
                <p className="text-xs text-[color:var(--brand-muted-text)]">
                    {batchKind === 'inbound' ? t('quality.disputeForm.holdsInbound') : t('quality.disputeForm.holdsOutput')}
                </p>
                <Button type="button" disabled={!canSave} onClick={save}>
                    {isPending ? t('common.saving') : t('quality.disputeForm.open')}
                </Button>
            </div>
        </PermissionGate>
    )
}
