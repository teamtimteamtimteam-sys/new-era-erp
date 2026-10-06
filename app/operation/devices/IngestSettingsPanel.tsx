'use client'

// app/operation/devices/IngestSettingsPanel.tsx
// MES-1(2026-10-06,MES-0 Q7 · MES-1 Step 0 Q9 · Q13 · Q22):采集层的传输上限 —— 读给每一个进得来的人看,改要 action.manage_devices。
//   它们保护的是日志与库,不是任何一道工艺标准(MES-0 Q7);修改史在本页底下那一块审计记录里(主语 ingest_settings,Q22)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { saveIngestSettings, type IngestSettingsFields } from './actions'

export const SETTING_KEYS = ['fail_budget', 'fail_window_s', 'global_reject_budget', 'max_payload_bytes', 'max_messages',
    'clock_ahead_s'] as const
export type SettingValues = Record<(typeof SETTING_KEYS)[number], number>

export default function IngestSettingsPanel({ values, canManage }: { values: SettingValues; canManage: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [editing, setEditing] = useState(false)
    const [draft, setDraft] = useState<Record<string, string>>(() =>
        Object.fromEntries(SETTING_KEYS.map((k) => [k, String(values[k])])))
    const [error, setError] = useState<string | null>(null)

    function save() {
        setError(null)
        const changed: IngestSettingsFields = {}
        for (const k of SETTING_KEYS) if (draft[k] !== String(values[k])) changed[k] = draft[k]
        start(async () => {
            const r = await saveIngestSettings(changed)
            if (r.error) { setError(r.error); return }
            setEditing(false)
            router.refresh()
        })
    }

    return (
        <div className="max-w-xl text-sm">
            <dl className="grid grid-cols-1 gap-x-6 gap-y-1 sm:grid-cols-2">
                {SETTING_KEYS.map((k) => (
                    <div key={k} className="flex flex-wrap justify-between gap-x-3">
                        <dt className="text-[color:var(--brand-muted-text)]">{t('devices.settings.' + k)}</dt>
                        <dd className="font-medium">{values[k]}</dd>
                    </div>
                ))}
            </dl>
            <p className="mt-2 text-xs text-[color:var(--brand-muted-text)]">{t('devices.settings.hint')}</p>
            {!editing && (
                <div className="mt-2">
                    <PermissionGate code="action.manage_devices" allowed={canManage} inline>
                        <Button type="button" size="sm" variant="outline" onClick={() => setEditing(true)}>{t('devices.settings.edit')}</Button>
                    </PermissionGate>
                </div>
            )}
            {editing && (
                <div className="mt-3 space-y-2 rounded border border-[color:var(--brand-border)] p-3">
                    {SETTING_KEYS.map((k) => (
                        <label key={k} className="block">
                            <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('devices.settings.' + k)}</span>
                            <input inputMode="numeric" value={draft[k]} onChange={(e) => setDraft({ ...draft, [k]: e.target.value })}
                                   className={`${CONTROL_INPUT} w-full`} />
                        </label>
                    ))}
                    <div className="flex flex-wrap gap-2">
                        <Button type="button" size="sm" disabled={pending} onClick={save}>{t('common.save')}</Button>
                        <Button type="button" size="sm" variant="secondary" disabled={pending}
                                onClick={() => { setEditing(false); setError(null) }}>{t('common.cancel')}</Button>
                    </div>
                    {error && <p className="text-sm text-red-700" role="alert">{error}</p>}
                </div>
            )}
        </div>
    )
}
