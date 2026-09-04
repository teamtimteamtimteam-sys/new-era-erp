'use client'

// app/set-password/SetPasswordForm.tsx
// 设完密码后去哪儿:关联了员工档案 → /me;没关联 → /welcome(那页只说"等管理员配好")。
// 判断交给一个 server action,因为客户端读不到 my_profile 的判定条件。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【C-1(2026-09-04):必须在【同一次 updateUser】里把强制标记清掉】★★
//   中间件按 user_metadata.must_change_password 把人扣在这一页
//   (lib/supabase/middleware.ts)。如果这里只改密码、不清标记,
//   **改完之后中间件会立刻把他再送回这一页** —— 一个改对了密码却出不去的死循环,
//   而且屏幕上看起来像"保存失败了"。
//   ★ 两件事必须是【一次】调用:分成两次的话,中间那一刻(密码已改、标记还在)
//     只要请求失败,这个人就永远卡在这一页。
// ════════════════════════════════════════════════════════════════════════════
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { useTranslations } from '@/lib/i18n/client'
import { landingAfterSetPassword } from './actions'
// 【与建账号那一屏读同一个数】见 lib/passwordPolicy.ts 的抬头。
import { MIN_PASSWORD_LENGTH } from '@/lib/passwordPolicy'
import { Input } from '@/app/components/ui/input'
import { Label } from '@/app/components/ui/label'



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
        if (pw.length < MIN_PASSWORD_LENGTH) return setError(t('setPassword.errTooShort'))
        if (pw !== confirm) return setError(t('setPassword.errMismatch'))

        startTransition(async () => {
            const supabase = createClient()
            // ★ 密码与标记【一次写完】—— 见抬头。
            const { error: upErr } = await supabase.auth.updateUser({
                password: pw,
                data: { must_change_password: false },
            })
            if (upErr) return setError(upErr.message)
            const where = await landingAfterSetPassword()
            router.push(where)
        })
    }

    return (
        <form onSubmit={submit} className="space-y-4">
            {error && (
                <div className="rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">
                    {error}
                </div>
            )}
            <div className="space-y-1.5">
                <Label htmlFor="sp-pw">{t('setPassword.password')}</Label>
                <Input
                    id="sp-pw"
                    type="password"
                    value={pw}
                    onChange={(e) => setPw(e.target.value)}
                    autoComplete="new-password"
                />
            </div>
            <div className="space-y-1.5">
                <Label htmlFor="sp-pw2">{t('setPassword.confirm')}</Label>
                <Input
                    id="sp-pw2"
                    type="password"
                    value={confirm}
                    onChange={(e) => setConfirm(e.target.value)}
                    autoComplete="new-password"
                />
            </div>
            {/* ★ 原生 button:`button` 仍在隔离闸的 GUARDED 里,C-1 只毕业了
                input / label / select。见 CreateAccountPanel 抬头的同一段说明。 */}
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
