'use client'

// app/quality/samples/QualitySettingsPanel.tsx
// MES-6a-1(MES-6a Step 0 Q8 · Q14,Tim):V16 —— 没有合同天数的样品留多少天(quality_settings.internal_retention_days)。
//   人人看得见(读这一页的人都持 module.quality.view);持 module.quality.edit 的人改得动 —— 缺码时控件看得见、按不动、说出码(DBLOCK-1)。
//   【它只对之后登记的样品生效】取样时把天数与日子抄在样品上(retention_days_at · retain_until),以后不改 —— 屏幕上直说。
//   空 = 尚未设定(Not yet set):没有合同天数的样品留样日空着,不出处置提醒。清空是允许的,服务端收 NULL。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { setQualitySettings } from '../actions'

export default function QualitySettingsPanel({ days, canEdit }: { days: number | null; canEdit: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [value, setValue] = useState(days == null ? '' : String(days))
    const [error, setError] = useState('')
    const [saved, setSaved] = useState(false)
    const [isPending, startTransition] = useTransition()

    function save() {
        setError('')
        setSaved(false)
        startTransition(async () => {
            const res = await setQualitySettings(value)
            if (res?.error) { setError(res.error); return }
            setSaved(true)
            router.refresh()
        })
    }

    return (
        <div className="border border-gray-300 rounded-lg p-4 mb-6 max-w-3xl" data-panel="quality-settings">
            <p className="font-medium mb-1">{t('quality.settings.title')}</p>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-1">{t('quality.settings.hint')}</p>
            <p className="text-sm mb-3">
                {t('quality.settings.current')}:{' '}
                <span data-value="internal_retention_days">
                    {days == null ? t('quality.notYetSet') : t('quality.settings.days', { n: String(days) })}
                </span>
            </p>
            {error && <p className="text-sm text-red-600 mb-2">{error}</p>}
            {saved && <p className="text-sm text-green-700 mb-2">{t('quality.settings.saved')}</p>}
            <PermissionGate code="module.quality.edit" allowed={canEdit}>
                <div className="flex flex-wrap items-end gap-3">
                    <label className="block text-sm">
                        <span className="block mb-1">{t('quality.settings.label')}</span>
                        <input type="number" inputMode="numeric" min={1} step={1} value={value}
                               onChange={(e) => setValue(e.target.value)}
                               className={`${CONTROL_INPUT} w-32`} data-field="internal_retention_days" />
                    </label>
                    <Button type="button" disabled={isPending} onClick={save}>
                        {isPending ? t('common.saving') : t('common.save')}
                    </Button>
                </div>
                <p className="text-xs text-[color:var(--brand-muted-text)] mt-2">{t('quality.settings.appliesForward')}</p>
            </PermissionGate>
        </div>
    )
}
