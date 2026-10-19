'use client'

// MES-9a(2026-10-19,MES-9 Step 0 §9 · Q24 · Q26,Tim):账号那一侧的两个待补的值 —— V38(初始密码在第一次登录之前有效几天)与
//   V40(项目的密码最短长度,Supabase 的设置 —— 这里记 Tim 在 Supabase 改好之后定的那个数)。一次给一个,空 = 清掉。
//   这一页的门是 action.manage_permissions,写的函数(set_account_setting)查同一个码。两个值今天都【不被执行】—— 屏幕照直说。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { setAccountSetting } from './accountSettingsActions'

export default function AccountSettingsPanel({ v38, v40 }: { v38: number | null; v40: number | null }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [days, setDays] = useState(v38 == null ? '' : String(v38))
    const [minLen, setMinLen] = useState(v40 == null ? '' : String(v40))

    function save(key: 'initial_password_valid_days' | 'password_min_length', raw: string) {
        setError('')
        startTransition(async () => {
            const res = await setAccountSetting(key, raw.trim() === '' ? null : Number(raw))
            if (res.error) { setError(res.error); return }
            router.refresh()
        })
    }

    return (
        <div className="mb-6 rounded border border-gray-200 px-4 py-3 text-sm space-y-3" data-section="account-settings">
            <p className="font-medium">{t('accountSettings.title')}</p>
            <p data-value="v38">{v38 == null ? t('accountSettings.v38NotSet') : t('accountSettings.v38Set', { days: String(v38) })}</p>
            <p data-value="v40">{v40 == null ? t('accountSettings.v40NotSet') : t('accountSettings.v40Set', { n: String(v40) })}</p>
            {error && <p className="text-red-600" data-error="account-settings">{error}</p>}
            <div className="flex flex-wrap gap-3 items-end">
                <label className="block min-w-0">
                    <span className="block mb-1">{t('accountSettings.v38Label')}</span>
                    <input inputMode="numeric" value={days} onChange={(e) => setDays(e.target.value)} className={`${CONTROL_INPUT} w-28`} data-field="v38" />
                </label>
                <Button type="button" variant="secondary" disabled={isPending} onClick={() => save('initial_password_valid_days', days)}>{t('accountSettings.save')}</Button>
                <label className="block min-w-0">
                    <span className="block mb-1">{t('accountSettings.v40Label')}</span>
                    <input inputMode="numeric" value={minLen} onChange={(e) => setMinLen(e.target.value)} className={`${CONTROL_INPUT} w-28`} data-field="v40" />
                </label>
                <Button type="button" variant="secondary" disabled={isPending} onClick={() => save('password_min_length', minLen)}>{t('accountSettings.save')}</Button>
            </div>
            <p className="text-xs text-[color:var(--brand-muted-text)]">{t('accountSettings.notEnforced')}</p>
        </div>
    )
}
