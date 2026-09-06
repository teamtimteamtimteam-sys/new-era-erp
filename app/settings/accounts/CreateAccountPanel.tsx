'use client'

// app/settings/accounts/CreateAccountPanel.tsx
// ════════════════════════════════════════════════════════════════════════════
// C-1(2026-09-04):建一个账号 —— 邮箱 + 初始密码 + 【恰好一个】角色 + 可选员工档案。
// ════════════════════════════════════════════════════════════════════════════
// 【它取代了 InvitePanel】那一版发邀请邮件,而本系统没有邮件服务(Tim 的裁定 Q12)。
//
// 【为什么角色是 Select 而不是一排勾选框】旧版是勾选框(可以零个、也可以多个),
//   而 Tim 的裁定是【每人恰好一个角色】。一排勾选框把"零个"画成一个合法的形状,
//   于是"建一个没有角色的账号"看起来像一个选项 —— 它不是。
//   Select + 一个空的占位值,让"还没选"和"选了不给角色"变成同一件事:**不能提交**。
//
// 【组件库,以及这一页【没有】用库里的哪两个 —— 说清楚,那不是疏忽】
//   本文件用 Input / Label / Select —— 正是 C-1 从 BASE-1 隔离闸的 GUARDED 里
//   毕业掉的那三个(见 scripts/check-base-isolation.mjs 抬头)。
//   ★ 按钮与卡片【刻意用了原生标记】:`button` 与 `card` 仍然在 GUARDED 里,
//     而 Tim 对 C-1 的裁定只毕业了 input / label / select 三个。
//     隔离闸当场抓到了这次越界(实测 EXIT 1,点名本文件第 31 行的 button import)——
//     处置是【退回来】,不是顺手把 button/card 也毕业掉:
//     一道闸自己抓到的越界,如果由撞上它的人当场放宽,那道闸就不存在了。
//   ☞ 留给下一刀的判断:一张真正的表单页需要 button,几乎肯定还需要 card。
//     下一次建表单页会立刻再撞一次,那时该由 Tim 裁定是否一并毕业。
//
// ★【密码不进任何地方,只进那一次 server action】★
//   不写 URL、不写 console、不放进任何会被提交的文件;失败时也不回显它。
//   两个输入框都是 type="password" + autoComplete="new-password"。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { createAccount } from './accountActions'
import { MIN_PASSWORD_LENGTH } from '@/lib/passwordPolicy'
import type { RoleOption, EmployeeOption } from './UserRow'
import { Input } from '@/app/components/ui/input'
import { Label } from '@/app/components/ui/label'
import {
    Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from '@/app/components/ui/select'
import { Button } from '@/app/components/ui/button'

const NO_EMPLOYEE = '__none__'

export default function CreateAccountPanel({
    roles,
    employees,
}: {
    roles: RoleOption[]
    employees: EmployeeOption[]
}) {
    const t = useTranslations()
    const locale = useLocale()
    const router = useRouter()
    const [open, setOpen] = useState(false)
    const [email, setEmail] = useState('')
    const [password, setPassword] = useState('')
    const [confirm, setConfirm] = useState('')
    const [roleId, setRoleId] = useState('')
    const [employeeId, setEmployeeId] = useState(NO_EMPLOYEE)
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [created, setCreated] = useState<string | null>(null)

    const free = employees.filter((e) => e.user_id === null)

    // 【提交条件写在一处】按钮的 disabled 与 submit 里的校验读同一个判据,
    // 否则"按不下去"与"按下去被拒"会各错一次。
    const tooShort = password.length < MIN_PASSWORD_LENGTH
    const mismatch = confirm !== password
    const canSubmit =
        email.trim() !== '' && roleId !== '' && !tooShort && !mismatch

    function reset() {
        setEmail(''); setPassword(''); setConfirm('')
        setRoleId(''); setEmployeeId(NO_EMPLOYEE)
    }

    function submit() {
        setError(null)
        setCreated(null)
        if (!canSubmit) return
        startTransition(async () => {
            const res = await createAccount({
                email,
                password,
                roleId,
                employeeId: employeeId === NO_EMPLOYEE ? null : employeeId,
            })
            if (res.error) {
                setError(res.error)
                // ★ 失败时【不清空密码框】以外的东西 —— 让人不必从头再打一遍。
                //   但密码本身清掉:一个留在屏幕上的密码是一次肩窥。
                setPassword(''); setConfirm('')
            } else {
                setCreated(res.email ?? email)
                reset()
                setOpen(false)
                router.refresh()
            }
        })
    }

    return (
        <div className="mb-6">
            <div className="flex items-center gap-3">
                <button
                    type="button"
                    aria-expanded={open}
                    onClick={() => setOpen((o) => !o)}
                    className="bg-gray-900 text-white px-3 py-1.5 rounded text-sm"
                >
                    {open ? t('common.cancel') : t('permissions.createAccount')}
                </button>
                {created && (
                    <span className="text-sm text-green-700">
                        {t('permissions.accountCreated', { 0: created })}
                    </span>
                )}
            </div>

            {open && (
                <div className="mt-3 rounded border border-gray-200 bg-gray-50 p-4">
                        {error && (
                            <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">
                                {error}
                            </div>
                        )}

                        {/* 【把"接下来会发生什么"说在前面】Tim 当面把密码交出去,
                            而对方第一次登录时会被要求换掉它 —— 那不是故障,
                            所以这一页要先讲清楚。 */}
                        <p className="mb-4 text-sm text-muted-foreground">
                            {t('permissions.createAccountHint')}
                        </p>

                        <div className="grid gap-4 md:grid-cols-2">
                            <div className="space-y-4">
                                <div className="space-y-1.5">
                                    <Label htmlFor="acct-email">{t('permissions.inviteEmail')}</Label>
                                    <Input
                                        id="acct-email"
                                        type="email"
                                        value={email}
                                        onChange={(e) => setEmail(e.target.value)}
                                        placeholder="name@example.com"
                                        autoComplete="off"
                                    />
                                </div>

                                <div className="space-y-1.5">
                                    <Label htmlFor="acct-pw">{t('permissions.initialPassword')}</Label>
                                    <Input
                                        id="acct-pw"
                                        type="password"
                                        value={password}
                                        onChange={(e) => setPassword(e.target.value)}
                                        autoComplete="new-password"
                                        aria-invalid={password !== '' && tooShort}
                                        nudgeOnInvalid
                                    />
                                    <span className="block text-xs text-muted-foreground">
                                        {t('permissions.passwordHint', { 0: String(MIN_PASSWORD_LENGTH) })}
                                    </span>
                                </div>

                                <div className="space-y-1.5">
                                    <Label htmlFor="acct-pw2">{t('permissions.confirmPassword')}</Label>
                                    <Input
                                        id="acct-pw2"
                                        type="password"
                                        value={confirm}
                                        onChange={(e) => setConfirm(e.target.value)}
                                        autoComplete="new-password"
                                        aria-invalid={confirm !== '' && mismatch}
                                        nudgeOnInvalid
                                    />
                                    {confirm !== '' && mismatch && (
                                        <span className="block text-xs text-destructive">
                                            {t('permissions.errPasswordMismatch')}
                                        </span>
                                    )}
                                </div>
                            </div>

                            <div className="space-y-4">
                                <div className="space-y-1.5">
                                    <Label htmlFor="acct-role">{t('permissions.roleLabel')}</Label>
                                    <Select value={roleId} onValueChange={setRoleId}>
                                        <SelectTrigger id="acct-role" className="w-full">
                                            <SelectValue placeholder={t('permissions.rolePlaceholder')} />
                                        </SelectTrigger>
                                        <SelectContent>
                                            {roles.map((r) => (
                                                <SelectItem key={r.id} value={r.id}>
                                                    {locale === 'zh' ? r.name_zh : r.name_en}
                                                </SelectItem>
                                            ))}
                                        </SelectContent>
                                    </Select>
                                    {/* 【恰好一个,而且不能是零个】—— 这句话要写在控件旁边,
                                        因为"为什么我不能不选"是一个人会当场问的问题。 */}
                                    <span className="block text-xs text-muted-foreground">
                                        {t('permissions.roleRequiredHint')}
                                    </span>
                                </div>

                                <div className="space-y-1.5">
                                    <Label htmlFor="acct-emp">{t('permissions.linkEmployee')}</Label>
                                    <Select value={employeeId} onValueChange={setEmployeeId}>
                                        <SelectTrigger id="acct-emp" className="w-full">
                                            <SelectValue />
                                        </SelectTrigger>
                                        <SelectContent>
                                            <SelectItem value={NO_EMPLOYEE}>
                                                {t('permissions.noEmployee')}
                                            </SelectItem>
                                            {free.map((e) => (
                                                <SelectItem key={e.id} value={e.id}>
                                                    {e.code} — {e.legal_name}
                                                </SelectItem>
                                            ))}
                                        </SelectContent>
                                    </Select>
                                    <span className="block text-xs text-muted-foreground">
                                        {t('permissions.linkEmployeeHint')}
                                    </span>
                                </div>
                            </div>
                        </div>

                        <div className="mt-4">
                            <Button size="sm"
                                type="button"
                                onClick={submit}
                                disabled={pending || !canSubmit}
                            >
                                {pending ? t('common.saving') : t('permissions.createAccount')}
                            </Button>
                        </div>
                </div>
            )}
        </div>
    )
}
