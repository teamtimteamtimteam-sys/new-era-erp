'use client'

// ESG-2(Tim 2026-10-31 Q4 · Q9):安全率页上的「标准日工时」—— 一个工作日算几个小时(工时 = 在职工作日 × 本值 − 请假 + 加班)。
//   没设时整页一个率都不算(库那一侧:hours_not_set)。门 action.manage_esg(admin · cco · cfo):不持的人看得见、按不动、说出码。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { setStandardHours } from '../esgActions'

export default function StandardHoursPanel({ current, canManage }: { current: number | null; canManage: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [hours, setHours] = useState('')
    const [error, setError] = useState('')
    function save() {
        setError('')
        start(async () => {
            const r = await setStandardHours(hours)
            if (r.error) { setError(r.error); return }
            setHours('')
            router.refresh()
        })
    }
    return (
        <section className="mt-8 space-y-2" data-section="standard-hours" aria-label={t('esg.rates.hoursTitle')}>
            <h2 className="mb-1">{t('esg.rates.hoursTitle')}</h2>
            <p className="text-sm" data-standard-hours={current === null ? 'not-set' : String(current)}>
                {current === null
                    ? <span className="font-medium text-amber-900">{t('esg.rates.hoursNotSet')}</span>
                    : t('esg.rates.hoursCurrent', { hours: String(current) })}
            </p>
            <p className="text-sm text-[color:var(--brand-muted-text)] max-w-3xl">{t('esg.rates.hoursIntro')}</p>
            <PermissionGate code="action.manage_esg" allowed={canManage} wrap>
                <div className="flex flex-wrap items-end gap-2" data-form="standard-hours">
                    <label className="block text-sm">
                        <span className="block mb-1">{t('esg.rates.hoursLabel')} <span className="text-red-600">*</span></span>
                        <input type="number" inputMode="decimal" step="0.25" min={0} max={24} value={hours} onChange={(e) => setHours(e.target.value)} className={`${CONTROL_INPUT} w-28`} data-field="hours" />
                    </label>
                    <Button type="button" disabled={pending || !hours.trim()} onClick={save}>{t('esg.rates.hoursSave')}</Button>
                </div>
                {error && <p className="text-sm text-red-600 mt-1" data-error="standard-hours">{error}</p>}
            </PermissionGate>
        </section>
    )
}
