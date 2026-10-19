'use client'

// MES-8b-2(2026-10-17,MES-0 §5.1 V28 · MES-8 Step 0 Q20 · Q29,Tim):V28 —— 大屏多久自己刷新、画哪几块牌子(按勾选的顺序 = 车间支的顺序)。
//   【空着就是 Not yet set】—— 表单不预填任何一个间隔。两样一起给(只给一半按名拒),「清空」把两样一起清回 Not yet set。
//   缺 action.manage_permissions 时整张表单在 PermissionGate 里(看得见、按不动、说出码)。一块大屏自己的会话【不画】这一块(page.tsx)。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { setFloorBoardSettings } from './actions'

export type FloorArm = { item_type: string; label: string }

export default function DisplaySettingsPanel({ arms, refreshSeconds, tiles, canEdit }: {
    arms: FloorArm[]; refreshSeconds: number | null; tiles: string[] | null; canEdit: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [saved, setSaved] = useState(false)
    const [seconds, setSeconds] = useState(refreshSeconds === null ? '' : String(refreshSeconds))
    const [chosen, setChosen] = useState<Set<string>>(new Set(tiles ?? []))

    const save = (clear: boolean) => {
        setError(''); setSaved(false)
        startTransition(async () => {
            const n = seconds.trim() === '' ? null : Number(seconds)
            const picked = arms.map((a) => a.item_type).filter((x) => chosen.has(x))
            const res = clear
                ? await setFloorBoardSettings(null, null)
                : await setFloorBoardSettings(n !== null && Number.isFinite(n) ? n : null, picked.length > 0 ? picked : null)
            if (res.error) { setError(res.error); return }
            if (clear) { setSeconds(''); setChosen(new Set()) }
            setSaved(true)
            router.refresh()
        })
    }

    return (
        <PermissionGate code="action.manage_permissions" allowed={canEdit}>
            <div className="space-y-3 max-w-3xl" data-form="floor-board-settings">
                {error && <p className="text-sm text-red-600" data-error="floor-board-settings">{error}</p>}
                {saved && <p className="text-sm text-green-700" data-saved="floor-board-settings">{t('display.settings.saved')}</p>}
                <label className="block text-sm">
                    <span className="block mb-1">{t('display.settings.refreshSeconds')}</span>
                    <input inputMode="numeric" value={seconds} onChange={(e) => { setSaved(false); setSeconds(e.target.value) }}
                        className={`${CONTROL_INPUT} w-40`} data-field="refresh_seconds" />
                </label>
                <fieldset className="border border-gray-300 rounded px-3 py-2">
                    <legend className="text-sm font-medium px-1">{t('display.settings.tiles')}</legend>
                    <div className="flex flex-wrap gap-x-4 gap-y-1">
                        {arms.map((a) => (
                            <label key={a.item_type} className="inline-flex items-center gap-2 text-sm">
                                <input type="checkbox" checked={chosen.has(a.item_type)} data-tile={a.item_type}
                                    onChange={(e) => {
                                        setSaved(false)
                                        const next = new Set(chosen)
                                        if (e.target.checked) next.add(a.item_type); else next.delete(a.item_type)
                                        setChosen(next)
                                    }} />
                                {a.label}
                            </label>
                        ))}
                    </div>
                </fieldset>
                <div className="flex flex-wrap gap-3">
                    <Button type="button" disabled={pending} onClick={() => save(false)}>
                        {pending ? t('common.saving') : t('display.settings.save')}
                    </Button>
                    <Button type="button" variant="secondary" disabled={pending} onClick={() => save(true)}>
                        {t('display.settings.clear')}
                    </Button>
                </div>
            </div>
        </PermissionGate>
    )
}
