'use client'

// app/set-password/SetPasswordForm.tsx
// 设密码后去哪儿:关联了员工档案 → /me;没关联 → /welcome(那页只说"等管理员配好")。
// 判断交给一个 server action,因为客户端读不到 my_profile 的判定条件。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { useTranslations } from '@/lib/i18n/client'
import { landingAfterSetPassword } from './actions'

export default function SetPasswordForm() {
    const t = useTranslations()
    const router = useRouter()
    const [pw, setPw] = useState('')
    const [confirm, setConfirm] = useState('')
    const [error, setError] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()

    function submit(e: React.FormEvent) {
        e.preventDefault()
        setError(null)
        if (pw.length < 8) return setError(t('setPassword.errTooShort'))
        if (pw !== confirm) return setError(t('setPassword.errMismatch'))

        startTransition(async () => {
            const supabase = createClient()
            const { error: upErr } = await supabase.auth.updateUser({ password: pw })
            if (upErr) return setError(upErr.message)
            const where = await landingAfterSetPassword()
            router.push(where)
        })
    }

    const field = 'w-full border border-gray-300 rounded px-3 py-2 text-sm'

    return (
        <form onSubmit={submit} className="space-y-4">
            {error && (
                <div className="rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">
                    {error}
                </div>
            )}
            <label className="block text-sm">
                {t('setPassword.password')}
                <input
                    type="password"
                    value={pw}
                    onChange={(e) => setPw(e.target.value)}
                    className={field}
                    autoComplete="new-password"
                />
            </label>
            <label className="block text-sm">
                {t('setPassword.confirm')}
                <input
                    type="password"
                    value={confirm}
                    onChange={(e) => setConfirm(e.target.value)}
                    className={field}
                    autoComplete="new-password"
                />
            </label>
            <button
                type="submit"
                disabled={pending}
                className="bg-gray-900 text-white px-4 py-2 rounded text-sm disabled:opacity-50"
            >
                {pending ? t('common.saving') : t('setPassword.submit')}
            </button>
        </form>
    )
}
