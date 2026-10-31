'use client'

// ESG-2(Tim 2026-10-31 Q7):更正误工天数 —— 误工天数加入「可更正的字段」:带理由、最后一次说了算,存进只给持 data.view_health 的人
//   (与受伤的那名员工本人)读的那张表。门 module.safety.edit(与记下这件事故的同一批人);不持的人看得见、按不动、说出码。
//   关闭之后不画(库同样按名拒)。不持健康码的编辑者也能更正 —— 与他们当初能记下原来那个数是同一条规矩(MES-7b Q6)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { correctDaysLost } from '../../actions'

export default function DaysLostCorrectionForm({ incidentId, canEdit }: { incidentId: string; canEdit: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [days, setDays] = useState('')
    const [reason, setReason] = useState('')
    const [error, setError] = useState('')
    function save() {
        setError('')
        start(async () => {
            const r = await correctDaysLost(incidentId, { daysLost: days, reason })
            if (r.error) { setError(r.error); return }
            setDays(''); setReason('')
            router.refresh()
        })
    }
    return (
        <PermissionGate code="module.safety.edit" allowed={canEdit} wrap>
            <div className="mt-3 space-y-2 max-w-3xl" data-form="days-lost-correction">
                <p className="text-sm font-medium">{t('safety.daysLost.correctTitle')}</p>
                <div className="flex flex-wrap items-end gap-2">
                    <label className="block text-sm">
                        <span className="block mb-1">{t('safety.incident.daysLost')} <span className="text-red-600">*</span></span>
                        <input type="number" inputMode="decimal" min={0} step="0.5" value={days} onChange={(e) => setDays(e.target.value)} className={`${CONTROL_INPUT} w-28`} data-field="days-lost" />
                    </label>
                    <label className="block text-sm min-w-0 flex-1 basis-64">
                        <span className="block mb-1">{t('safety.updates.reason')} <span className="text-red-600">*</span></span>
                        <input type="text" value={reason} onChange={(e) => setReason(e.target.value)} className={`${CONTROL_INPUT} w-full`} data-field="reason" />
                    </label>
                    <Button type="button" disabled={pending || days.trim() === '' || reason.trim() === ''} onClick={save}>{t('safety.daysLost.correct')}</Button>
                </div>
                {error && <p className="text-sm text-red-600" data-error="days-lost">{error}</p>}
            </div>
        </PermissionGate>
    )
}
