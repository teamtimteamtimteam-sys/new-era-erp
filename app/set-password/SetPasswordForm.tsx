'use client'

// app/set-password/SetPasswordForm.tsx
//
// ★★【FIX-1 item 2(2026-09-05):写入搬去了 server action,这里只剩表单】★★
// 成因、实测数字与"为什么 redirect() 修得了而 router.push 修不了",
// 全部写在 app/set-password/actions.ts 的抬头 —— 不在这里抄第二遍。
//
// 【这一页为什么用 useActionState 而不是 useTransition】
// 两者的 pending 【不是】同一段时间:
//   · useTransition —— 异步回调 return 的那一刻就变 false,而那时新页面
//     一个字节都还没到。旧实现正是这样:按钮先亮回来,屏幕再无声地空转几秒。
//   · useActionState —— pending 一直真到 **action 的应答(含 redirect)被应用完**。
//     于是那段空窗里按钮写着"保存中…"、两个输入框禁用 —— 空窗还在
//     (它由落点页面有多重决定),但它不再是无声的。
// ★ 这就是"成功提交之后不许留下一屏填着的密码框"那一条的落点。
import { useActionState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { setPassword, type SetPasswordState } from './actions'
import { Input } from '@/app/components/ui/input'
import { Label } from '@/app/components/ui/label'
import { Button } from '@/app/components/ui/button'

const EMPTY: SetPasswordState = { error: null }

export default function SetPasswordForm() {
    const t = useTranslations()
    const [state, formAction, pending] = useActionState(setPassword, EMPTY)

    // 错误【码】在这里才变成句子 —— 服务端不回句子,见 actions.ts。
    // 【认不出来的码不许静默】:落到 errUnknown,那一条自己就是一句话。
    const message =
        state.error === 'errTooShort' ? t('setPassword.errTooShort')
        : state.error === 'errMismatch' ? t('setPassword.errMismatch')
        : state.error === 'errSamePassword' ? t('setPassword.errSamePassword')
        : state.error === 'errWeak' ? t('setPassword.errWeak')
        : state.error ? t('setPassword.errUnknown')
        : null

    return (
        <form action={formAction} className="space-y-4">
            {message && (
                <div className="rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">
                    {message}
                </div>
            )}
            <div className="space-y-1.5">
                <Label htmlFor="sp-pw">{t('setPassword.password')}</Label>
                <Input
                    id="sp-pw"
                    name="password"
                    type="password"
                    autoComplete="new-password"
                    disabled={pending}
                />
            </div>
            <div className="space-y-1.5">
                <Label htmlFor="sp-pw2">{t('setPassword.confirm')}</Label>
                <Input
                    id="sp-pw2"
                    name="confirm"
                    type="password"
                    autoComplete="new-password"
                    disabled={pending}
                />
            </div>
            {/* ★ 原生 button:`button` 仍在隔离闸的 GUARDED 里,C-1 只毕业了
                input / label / select。见 CreateAccountPanel 抬头的同一段说明。 */}
            <Button
                type="submit"
                disabled={pending}
            >
                {pending ? t('common.saving') : t('setPassword.submit')}
            </Button>
        </form>
    )
}
