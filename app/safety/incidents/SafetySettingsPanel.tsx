'use client'

// app/safety/incidents/SafetySettingsPanel.tsx
// MES-7b-1(MES-0 §5.1 V19;MES-7b Step 0 Q10 · Q11,Tim):V19 —— 一件要通报 NEA 的事故,书面报告要在事故日之后的第几个工作日之前交。
//   ★ Q11:引导存 2、【未确认】—— 出处是仓库里那条义务的记录,不是执照原文。面板照直说:现在的数、它从哪里来、确认了没有。
//   未确认时期限照算,屏幕上标"未确认",V19 留在待补的值上;持 module.safety.edit 的人对着执照确认它(勾选"已对着 NEA 执照核过")。
//   改了数而不勾确认 = 回到未确认(服务端同一句规矩,set_safety_settings)。缺码时控件看得见、按不动、说出码(DBLOCK-1)。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { setSafetySettings } from '../actions'

export default function SafetySettingsPanel({ days, source, confirmedAt, canEdit }: {
    days: number | null; source: string | null; confirmedAt: string | null; canEdit: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [value, setValue] = useState(days == null ? '' : String(days))
    const [confirmed, setConfirmed] = useState(false)
    const [src, setSrc] = useState('')
    const [error, setError] = useState('')
    const [saved, setSaved] = useState(false)
    const [isPending, startTransition] = useTransition()

    function save() {
        setError('')
        setSaved(false)
        startTransition(async () => {
            const res = await setSafetySettings({ days: value, confirmed, source: src })
            if (res?.error) { setError(res.error); return }
            setSaved(true)
            setConfirmed(false)
            router.refresh()
        })
    }

    return (
        <div className="border border-gray-300 rounded-lg p-4 mb-6 max-w-3xl" data-panel="safety-settings">
            <p className="font-medium mb-1">{t('safety.settings.title')}</p>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-1">{t('safety.settings.hint')}</p>
            <p className="text-sm mb-1">
                {t('safety.settings.current')}:{' '}
                <span data-value="nea_report_working_days">
                    {days == null ? t('safety.notYetSet') : t('safety.settings.days', { n: String(days) })}
                </span>
                {' · '}
                <span data-value="confirmed">
                    {confirmedAt ? t('safety.settings.confirmedOn', { date: confirmedAt }) : t('safety.settings.unconfirmed')}
                </span>
            </p>
            {source && <p className="text-xs text-[color:var(--brand-muted-text)] mb-3 break-words" data-value="source">{t('safety.settings.source')}: {source}</p>}
            {error && <p className="text-sm text-red-600 mb-2">{error}</p>}
            {saved && <p className="text-sm text-green-700 mb-2">{t('safety.settings.saved')}</p>}
            <PermissionGate code="module.safety.edit" allowed={canEdit}>
                <div className="flex flex-wrap items-end gap-3">
                    <label className="block text-sm">
                        <span className="block mb-1">{t('safety.settings.label')}</span>
                        <input type="number" inputMode="numeric" min={1} step={1} value={value}
                               onChange={(e) => setValue(e.target.value)}
                               className={`${CONTROL_INPUT} w-32`} data-field="nea_report_working_days" />
                    </label>
                    <label className="block text-sm min-w-0 flex-1 basis-60">
                        <span className="block mb-1">{t('safety.settings.sourceLabel')}</span>
                        <input type="text" value={src} onChange={(e) => setSrc(e.target.value)}
                               placeholder={t('safety.settings.sourcePlaceholder')}
                               className={`${CONTROL_INPUT} w-full`} data-field="nea_report_days_source" />
                    </label>
                    <label className="flex items-center gap-2 text-sm">
                        <input type="checkbox" checked={confirmed} onChange={(e) => setConfirmed(e.target.checked)} data-field="confirmed" />
                        <span>{t('safety.settings.confirmLabel')}</span>
                    </label>
                    <Button type="button" disabled={isPending} onClick={save}>
                        {isPending ? t('common.saving') : t('common.save')}
                    </Button>
                </div>
                <p className="text-xs text-[color:var(--brand-muted-text)] mt-2">{t('safety.settings.confirmHint')}</p>
            </PermissionGate>
        </div>
    )
}
