'use client'

// MES-8b-1(2026-10-17,MES-8 Step 0 Q15 · Q16,Tim):冻这个月的合规包。
//   【只有关账的月份冻得下来】—— 月份还开着时按钮按不动,并说出为什么(库也会按名拒 COMPLIANCE_PACK_MONTH_NOT_LOCKED:那是一条对的规矩,
//   AGENTS.md「服务端对的时候,不提供这个动作,并说出理由」)。这个月已经有一份在册的包时,再冻要写理由(新的一份是 CPK-…-2,旧的留着)。
//   缺 action.compliance_pack 时看得见、按不动、说出码。
import Link from 'next/link'
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { freezeCompliancePack } from './actions'

export default function FreezePanel({ month, locked, lockedBefore, liveCode, canFreeze }: {
    month: string; locked: boolean; lockedBefore: string | null; liveCode: string | null; canFreeze: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, startTransition] = useTransition()
    const [notes, setNotes] = useState('')
    const [reason, setReason] = useState('')
    const [error, setError] = useState('')
    const [frozen, setFrozen] = useState<{ id: string; code: string } | null>(null)
    return (
        <section className="mb-6" data-section="freeze-compliance-pack">
            <h2 className="mb-1">{t('compliancePacks.freezeTitle', { month })}</h2>
            {!locked && (
                <p className="text-sm text-amber-900 bg-amber-50 border border-amber-300 rounded px-3 py-2 mb-3 max-w-3xl" data-notice="month-not-locked">
                    {t('compliancePacks.monthNotLocked', { month, lockedBefore: lockedBefore ?? '—' })}
                </p>
            )}
            {liveCode && <p className="text-sm mb-2" data-value="live-pack">{t('compliancePacks.alreadyFrozen', { code: liveCode })}</p>}
            {error && <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800" data-error="freeze-compliance-pack">{error}</div>}
            {frozen && (
                <p className="mb-3 text-sm text-green-700" data-saved="freeze-compliance-pack">
                    {t('compliancePacks.frozen', { code: frozen.code })}{' '}
                    <Link href={`/compliance/packs/${frozen.id}`} className="app-link hover:underline">{t('compliancePacks.openPack')}</Link>
                </p>
            )}
            <PermissionGate code="action.compliance_pack" allowed={canFreeze}>
                <div className="flex flex-wrap items-end gap-3">
                    <label className="block text-sm min-w-0 basis-full sm:basis-auto">
                        <span className="block mb-1">{t('compliancePacks.notes')}</span>
                        <input value={notes} onChange={(e) => setNotes(e.target.value)} className={`${CONTROL_INPUT} w-full sm:w-72`} data-field="notes" />
                    </label>
                    {liveCode && (
                        <label className="block text-sm min-w-0 basis-full sm:basis-auto">
                            <span className="block mb-1">{t('compliancePacks.supersedeReason')} <span className="text-red-600">*</span></span>
                            <input value={reason} onChange={(e) => setReason(e.target.value)} placeholder={t('compliancePacks.supersedeReasonHint')}
                                className={`${CONTROL_INPUT} w-full sm:w-72`} data-field="supersede_reason" />
                        </label>
                    )}
                    <Button type="button" disabled={pending || !locked || (!!liveCode && reason.trim() === '')}
                        onClick={() => { setError(''); setFrozen(null); startTransition(async () => {
                            const res = await freezeCompliancePack(month, notes, reason)
                            if (res.error) { setError(res.error); return }
                            setFrozen({ id: res.packId ?? '', code: res.code ?? '' }); setNotes(''); setReason('')
                            router.refresh()
                        }) }}>
                        {pending ? t('common.saving') : (liveCode ? t('compliancePacks.reissue') : t('compliancePacks.freeze'))}
                    </Button>
                </div>
            </PermissionGate>
        </section>
    )
}
