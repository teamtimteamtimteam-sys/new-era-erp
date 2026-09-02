'use client'

// app/settings/accounts/InvitePanel.tsx
// 邀请一个账号:邮箱 + (可选)关联员工 + (可选)角色,一次走完。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { inviteUser } from './inviteActions'
import type { RoleOption, EmployeeOption } from './UserRow'

export default function InvitePanel({
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
    const [employeeId, setEmployeeId] = useState('')
    const [checked, setChecked] = useState<string[]>([])
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [sent, setSent] = useState<string | null>(null)

    const free = employees.filter((e) => e.user_id === null)

    function submit() {
        setError(null)
        setSent(null)
        startTransition(async () => {
            const res = await inviteUser({
                email,
                employeeId: employeeId === '' ? null : employeeId,
                roleIds: checked,
            })
            if (res.error) setError(res.error)
            else {
                setSent(res.email ?? email)
                setEmail('')
                setEmployeeId('')
                setChecked([])
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
                    onClick={() => setOpen((o) => !o)}
                    className="bg-gray-900 text-white px-3 py-1.5 rounded text-sm"
                >
                    {open ? t('common.cancel') : t('permissions.inviteUser')}
                </button>
                {sent && (
                    <span className="text-sm text-green-700">
                        {t('permissions.inviteSent', { 0: sent })}
                    </span>
                )}
            </div>

            {open && (
                <div className="mt-3 rounded border border-gray-200 p-4 bg-gray-50">
                    {error && (
                        <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">
                            {error}
                        </div>
                    )}
                    <div className="grid gap-4 md:grid-cols-2">
                        <div>
                            <label className="block text-sm">
                                {t('permissions.inviteEmail')}
                                <input
                                    type="email"
                                    value={email}
                                    onChange={(e) => setEmail(e.target.value)}
                                    className="mt-1 w-full border border-gray-300 rounded px-2 py-1 text-sm"
                                    placeholder="name@example.com"
                                />
                            </label>
                            <label className="mt-3 block text-sm">
                                {t('permissions.linkEmployee')}
                                <select
                                    value={employeeId}
                                    onChange={(e) => setEmployeeId(e.target.value)}
                                    className="mt-1 w-full border border-gray-300 rounded px-2 py-1 text-sm"
                                >
                                    <option value="">{t('permissions.noEmployee')}</option>
                                    {free.map((e) => (
                                        <option key={e.id} value={e.id}>
                                            {e.code} — {e.legal_name}
                                        </option>
                                    ))}
                                </select>
                                <span className="mt-1 block text-xs text-gray-500">
                                    {t('permissions.linkEmployeeHint')}
                                </span>
                            </label>
                        </div>
                        <div>
                            <div className="text-sm mb-1">{t('permissions.rolesLabel')}</div>
                            <div className="space-y-1 max-h-48 overflow-y-auto">
                                {roles.map((r) => (
                                    <label key={r.id} className="flex items-center gap-2 text-sm">
                                        <input
                                            type="checkbox"
                                            checked={checked.includes(r.id)}
                                            onChange={() =>
                                                setChecked((c) =>
                                                    c.includes(r.id)
                                                        ? c.filter((x) => x !== r.id)
                                                        : [...c, r.id]
                                                )
                                            }
                                        />
                                        {locale === 'zh' ? r.name_zh : r.name_en}
                                    </label>
                                ))}
                            </div>
                            <p className="mt-2 text-xs text-gray-500">
                                {t('permissions.inviteRolesHint')}
                            </p>
                        </div>
                    </div>
                    <button
                        type="button"
                        onClick={submit}
                        disabled={pending || email.trim() === ''}
                        className="mt-4 bg-gray-900 text-white px-4 py-1.5 rounded text-sm disabled:opacity-50"
                    >
                        {pending ? t('permissions.inviting') : t('permissions.sendInvite')}
                    </button>
                </div>
            )}
        </div>
    )
}
