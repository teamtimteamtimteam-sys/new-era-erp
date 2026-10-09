'use client'

// app/quality/disputes/[id]/DisputeActions.tsx
// MES-6a-1(MES-6a Step 0 Q16 · Q19 · Q13):一件开着的争议上的三件事 —— 记下仲裁样品与仲裁结果、结案(点名哪一份说了算)、撤回。
//   【三把码,分开说】仲裁与撤回要 module.quality.edit;结案要 action.apply_assay(今天应用化验的人 —— 结案预先替他做了那个选择,Q13)。
//   每一块各自在自己的 PermissionGate 里:看得见、按不动、说出那个码。
//   【结案什么都不应用】(Q19):这里直说,并在结案之后由页面指回那一份结果的页面 —— 应用照常在那里走。
//   说明 / 理由空着按钮按不下去,服务端【独立】拒空(ASSAY_DISPUTE_NOTE_REQUIRED · ASSAY_DISPUTE_REASON_REQUIRED)。
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { recordDisputeUmpire, resolveDispute, withdrawDispute } from '../../actions'

export type Opt = { id: string; label: string }

export default function DisputeActions({ id, umpireSamples, umpireAssays, governingOptions, currentUmpireSampleId, currentUmpireAssayId, canEdit, canResolve }: {
    id: string
    umpireSamples: Opt[]
    umpireAssays: Opt[]
    governingOptions: Opt[]
    currentUmpireSampleId: string | null
    currentUmpireAssayId: string | null
    canEdit: boolean
    canResolve: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [sampleId, setSampleId] = useState(currentUmpireSampleId ?? '')
    const [assayId, setAssayId] = useState(currentUmpireAssayId ?? '')
    const [governing, setGoverning] = useState('')
    const [note, setNote] = useState('')
    const [withdrawReason, setWithdrawReason] = useState('')

    function run(fn: () => Promise<{ error?: string }>) {
        setError('')
        startTransition(async () => {
            const res = await fn()
            if (res?.error) { setError(res.error); return }
            router.refresh()
        })
    }

    return (
        <div className="space-y-6 max-w-3xl" data-control="dispute-actions">
            {error && <p className="text-sm text-red-600">{error}</p>}

            <section>
                <h3 className="text-sm font-semibold mb-1">{t('quality.dispute.umpireTitle')}</h3>
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('quality.dispute.umpireWhy')}</p>
                <PermissionGate code="module.quality.edit" allowed={canEdit}>
                    <div className="flex flex-wrap items-end gap-3">
                        <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                            <span className="block mb-1">{t('quality.dispute.umpireSample')}</span>
                            <select value={sampleId} onChange={(e) => setSampleId(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="umpire_sample_id">
                                <option value="">{t('quality.dispute.none')}</option>
                                {umpireSamples.map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}
                            </select>
                        </label>
                        <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                            <span className="block mb-1">{t('quality.dispute.umpireAssay')}</span>
                            <select value={assayId} onChange={(e) => setAssayId(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="umpire_assay_id">
                                <option value="">{t('quality.dispute.none')}</option>
                                {umpireAssays.map((a) => <option key={a.id} value={a.id}>{a.label}</option>)}
                            </select>
                        </label>
                        <Button type="button" variant="secondary" disabled={isPending || (!sampleId && !assayId)}
                                onClick={() => run(() => recordDisputeUmpire(id, sampleId || null, assayId || null))}>
                            {t('quality.dispute.saveUmpire')}
                        </Button>
                    </div>
                </PermissionGate>
            </section>

            <section>
                <h3 className="text-sm font-semibold mb-1">{t('quality.dispute.resolveTitle')}</h3>
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('quality.dispute.resolveWhy')}</p>
                <PermissionGate code="action.apply_assay" allowed={canResolve}>
                    <div className="space-y-2">
                        <label className="block text-sm max-w-md">
                            <span className="block mb-1">{t('quality.dispute.governing')} <span className="text-red-600">*</span></span>
                            <select value={governing} onChange={(e) => setGoverning(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="governing_assay_id">
                                <option value="" disabled>{t('quality.dispute.pickGoverning')}</option>
                                {governingOptions.map((a) => <option key={a.id} value={a.id}>{a.label}</option>)}
                            </select>
                        </label>
                        <div className="flex flex-wrap items-center gap-3">
                            <input type="text" value={note} onChange={(e) => setNote(e.target.value)} placeholder={t('quality.dispute.notePlaceholder')}
                                   className={`${CONTROL_INPUT} min-w-0 basis-full sm:basis-96`} data-field="note" />
                            <Button type="button" disabled={isPending || !governing || note.trim() === ''}
                                    onClick={() => run(() => resolveDispute(id, governing, note))}>
                                {t('quality.dispute.resolve')}
                            </Button>
                        </div>
                    </div>
                </PermissionGate>
            </section>

            <section>
                <h3 className="text-sm font-semibold mb-1">{t('quality.dispute.withdrawTitle')}</h3>
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('quality.dispute.withdrawWhy')}</p>
                <PermissionGate code="module.quality.edit" allowed={canEdit} inline className="flex-wrap">
                    <input type="text" value={withdrawReason} onChange={(e) => setWithdrawReason(e.target.value)} placeholder={t('quality.dispute.withdrawPlaceholder')}
                           className={`${CONTROL_INPUT} min-w-0 basis-full sm:basis-96`} data-field="withdraw_reason" />
                    <Button type="button" variant="destructive" disabled={isPending || withdrawReason.trim() === ''}
                            onClick={() => run(() => withdrawDispute(id, withdrawReason))}>
                        {t('quality.dispute.withdraw')}
                    </Button>
                </PermissionGate>
            </section>
        </div>
    )
}
