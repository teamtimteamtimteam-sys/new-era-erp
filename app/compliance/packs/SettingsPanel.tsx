'use client'

// MES-8b-1(2026-10-17,MES-0 §5.1 V26 · V27;MES-8 Step 0 Q18 · Q28,Tim):合规包的两个待补的值 —— V26(NEA 申报的格式与频率)与
//   V27(欧盟回收效率的方法与目标)。【空着就是 Not yet set】—— 表单不预填任何一句。两两成对(只给一半按名拒)。
//   给了也不算任何东西:包把它们照原样印进第 7、8 节(Q28);改它不改写任何一份冻下来的包(每一份都抄走了它当时的那一行)。
//   缺 action.compliance_pack 时整张表单在 PermissionGate 里(看得见、按不动、说出码)。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { setComplianceSettings } from './actions'

export type ComplianceSettings = {
    nea_return_format: string | null; nea_return_frequency: string | null; eu_efficiency_method: string | null; eu_efficiency_targets: string | null
}

export default function SettingsPanel({ settings, canEdit }: { settings: ComplianceSettings; canEdit: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [saved, setSaved] = useState(false)
    const [f, setF] = useState(settings.nea_return_format ?? '')
    const [q, setQ] = useState(settings.nea_return_frequency ?? '')
    const [m, setM] = useState(settings.eu_efficiency_method ?? '')
    const [g, setG] = useState(settings.eu_efficiency_targets ?? '')
    const field = (label: string, value: string, set: (v: string) => void, name: string) => (
        <label className="block text-sm min-w-0 basis-full sm:basis-auto">
            <span className="block mb-1">{label}</span>
            <input value={value} onChange={(e) => { setSaved(false); set(e.target.value) }} className={`${CONTROL_INPUT} w-full sm:w-72`} data-field={name} />
        </label>
    )
    return (
        <PermissionGate code="action.compliance_pack" allowed={canEdit}>
            <div className="space-y-3 max-w-3xl" data-form="compliance-settings">
                {error && <p className="text-sm text-red-600" data-error="compliance-settings">{error}</p>}
                {saved && <p className="text-sm text-green-700" data-saved="compliance-settings">{t('compliancePacks.settings.saved')}</p>}
                <fieldset className="border border-gray-300 rounded px-3 py-2 space-y-2">
                    <legend className="text-sm font-medium px-1">{t('compliancePacks.settings.v26')}</legend>
                    <div className="flex flex-wrap gap-3">
                        {field(t('compliancePacks.settings.neaFormat'), f, setF, 'nea_return_format')}
                        {field(t('compliancePacks.settings.neaFrequency'), q, setQ, 'nea_return_frequency')}
                    </div>
                </fieldset>
                <fieldset className="border border-gray-300 rounded px-3 py-2 space-y-2">
                    <legend className="text-sm font-medium px-1">{t('compliancePacks.settings.v27')}</legend>
                    <div className="flex flex-wrap gap-3">
                        {field(t('compliancePacks.settings.euMethod'), m, setM, 'eu_efficiency_method')}
                        {field(t('compliancePacks.settings.euTargets'), g, setG, 'eu_efficiency_targets')}
                    </div>
                </fieldset>
                <Button type="button" disabled={pending} onClick={() => { setError(''); setSaved(false); startTransition(async () => {
                    const res = await setComplianceSettings(f, q, m, g)
                    if (res.error) { setError(res.error); return }
                    setSaved(true)
                    router.refresh()
                }) }}>
                    {pending ? t('common.saving') : t('compliancePacks.settings.save')}
                </Button>
            </div>
        </PermissionGate>
    )
}
