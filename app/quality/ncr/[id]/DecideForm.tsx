'use client'

// app/quality/ncr/[id]/DecideForm.tsx
// MES-6b-1(MES-6b Step 0 Q9 · Q22):决定一张不合格报告 —— 处置 + 一句说明(必填);带罚接受另要指出钱走的那一张既有单据。
//   缺 action.ncr_decide 时整块在 PermissionGate 里(看得见、按不动、说出那个码)。开单人自己(同一个账号)看得见一句为什么不能决定 ——
//   那不是码的问题,所以不进 PermissionGate;库里按人认再判一次(SELF_APPROVAL_FORBIDDEN)。
import { CONTROL_SELECT, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { decideNcr } from '../../actions'
import { NCR_DISPOSITIONS, ncrDispositionKey } from '../../qualityTypes'

export type Option = { id: string; label: string }

export default function DecideForm({ ncrId, batchKind, batchId, canDecide, selfOpened, penaltyOptions, penaltyRestricted }: {
    ncrId: string
    batchKind: 'inbound' | 'output'
    batchId: string
    canDecide: boolean
    selfOpened: boolean
    penaltyOptions: Option[]
    penaltyRestricted: boolean
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [disposition, setDisposition] = useState('')
    const [note, setNote] = useState('')
    const [docId, setDocId] = useState('')

    const needsDoc = disposition === 'accept_with_penalty'
    const canSave = !!disposition && note.trim() !== '' && (!needsDoc || !!docId) && !selfOpened && !isPending

    function save() {
        setError('')
        startTransition(async () => {
            const res = await decideNcr(ncrId, {
                disposition, note,
                invoiceRequestId: needsDoc && batchKind === 'output' ? docId : null,
                priceRequestId: needsDoc && batchKind === 'inbound' ? docId : null,
                batchKind, batchId,
            })
            if (res?.error) setError(res.error)
        })
    }

    return (
        <PermissionGate code="action.ncr_decide" allowed={canDecide}>
            <div className="space-y-4 max-w-3xl" data-form="ncr-decide">
                {error && <p className="text-sm text-red-600">{error}</p>}
                {selfOpened && <p className="text-sm text-amber-700" data-notice="ncr-self">{t('quality.ncr.selfOpened')}</p>}
                <label className="block text-sm max-w-md">
                    <span className="block mb-1">{t('quality.ncr.disposition')} <span className="text-red-600">*</span></span>
                    <select value={disposition} onChange={(e) => { setDisposition(e.target.value); setDocId('') }}
                            className={`${CONTROL_SELECT} w-full`} data-field="disposition" disabled={selfOpened}>
                        <option value="" disabled>{t('quality.ncr.pickDisposition')}</option>
                        {NCR_DISPOSITIONS.map((d) => <option key={d} value={d}>{t(ncrDispositionKey(d))}</option>)}
                    </select>
                    {disposition && <span className="block mt-1 text-xs text-[color:var(--brand-muted-text)]">{t('quality.ncr.dispositionWhy.' + disposition)}</span>}
                </label>
                {needsDoc && (
                    <label className="block text-sm max-w-md">
                        <span className="block mb-1">
                            {batchKind === 'output' ? t('quality.ncr.creditNoteRequest') : t('quality.ncr.priceRequest')} <span className="text-red-600">*</span>
                        </span>
                        <select value={docId} onChange={(e) => setDocId(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="penalty_document">
                            <option value="" disabled>{t('quality.ncr.pickDocument')}</option>
                            {penaltyOptions.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}
                        </select>
                        <span className="block mt-1 text-xs text-[color:var(--brand-muted-text)]">
                            {penaltyRestricted ? t('quality.ncr.documentRestricted')
                                : penaltyOptions.length === 0 ? (batchKind === 'output' ? t('quality.ncr.noCreditNoteRequest') : t('quality.ncr.noPriceRequest'))
                                : t('quality.ncr.documentWhy')}
                        </span>
                    </label>
                )}
                <label className="block text-sm">
                    <span className="block mb-1">{t('quality.ncr.decisionNote')} <span className="text-red-600">*</span></span>
                    <textarea value={note} onChange={(e) => setNote(e.target.value)} rows={2} className={`${CONTROL_TEXTAREA} w-full`}
                              data-field="decision_note" disabled={selfOpened} />
                </label>
                <Button type="button" disabled={!canSave} onClick={save}>
                    {isPending ? t('common.saving') : t('quality.ncr.decide')}
                </Button>
            </div>
        </PermissionGate>
    )
}
