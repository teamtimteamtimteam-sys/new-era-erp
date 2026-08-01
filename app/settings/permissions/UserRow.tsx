'use client'

// app/settings/permissions/UserRow.tsx
// 一个系统账号一行,展开后是编辑面板:勾选角色 + 关联员工档案。
import { useState, useTransition } from 'react'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { saveUserRoles } from './actions'

export type DirectoryRow = {
    user_id: string
    email: string | null
    created_at: string | null
    last_sign_in_at: string | null
    employee_id: string | null
    employee_code: string | null
    employee_name: string | null
    roles: { role_id: string; code: string; name_en: string; name_zh: string }[]
}
export type RoleOption = {
    id: string
    code: string
    name_en: string
    name_zh: string
    is_system: boolean | null
}
export type EmployeeOption = {
    id: string
    code: string
    legal_name: string
    user_id: string | null
}

export default function UserRow({
    row,
    roles,
    employees,
    lastSignInDisplay,
    createdDisplay,
}: {
    row: DirectoryRow
    roles: RoleOption[]
    employees: EmployeeOption[]
    lastSignInDisplay: string
    createdDisplay: string
}) {
    const t = useTranslations()
    const locale = useLocale()
    const [open, setOpen] = useState(false)
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [done, setDone] = useState(false)

    const [checked, setChecked] = useState<string[]>(row.roles.map((r) => r.role_id))
    const [employeeId, setEmployeeId] = useState<string>(row.employee_id ?? '')
    const [reason, setReason] = useState('')

    // employees.user_id 上是 partial unique index(一名员工最多绑一个账号),
    // 所以选项里【排除已经绑给别人的员工】,并在提示里说明为什么它们不在列表上。
    const options = employees.filter((e) => e.user_id === null || e.id === row.employee_id)

    function toggle(id: string) {
        setChecked((c) => (c.includes(id) ? c.filter((x) => x !== id) : [...c, id]))
    }

    function save() {
        setError(null)
        setDone(false)
        startTransition(async () => {
            const res = await saveUserRoles(
                row.user_id,
                checked,
                reason,
                employeeId === '' ? null : employeeId
            )
            if (res.error) setError(res.error)
            else {
                setDone(true)
                setOpen(false)
            }
        })
    }

    return (
        <div className="border border-gray-200 rounded">
            <div className="flex items-center justify-between px-4 py-3 gap-4">
                <div className="min-w-0">
                    <div className="font-medium truncate">{row.email ?? '—'}</div>
                    <div className="text-sm text-gray-500">
                        {row.employee_code ? (
                            <>
                                {row.employee_code} — {row.employee_name}
                            </>
                        ) : (
                            <span className="italic text-gray-400">
                                {t('permissions.notLinked')}
                            </span>
                        )}
                    </div>
                </div>

                <div className="flex flex-wrap gap-1 justify-end">
                    {row.roles.length === 0 ? (
                        <span className="text-xs text-gray-400 italic">
                            {t('permissions.noRoles')}
                        </span>
                    ) : (
                        row.roles.map((r) => (
                            <span
                                key={r.role_id}
                                className="rounded-full bg-gray-100 px-2 py-0.5 text-xs text-gray-700"
                            >
                                {locale === 'zh' ? r.name_zh : r.name_en}
                            </span>
                        ))
                    )}
                </div>

                <div className="text-xs text-gray-500 whitespace-nowrap text-right">
                    <div>
                        {t('permissions.lastSignIn')}: {lastSignInDisplay}
                    </div>
                    <div>
                        {t('permissions.created')}: {createdDisplay}
                    </div>
                </div>

                <button
                    type="button"
                    onClick={() => setOpen((o) => !o)}
                    className="border border-gray-300 px-3 py-1 rounded text-sm hover:bg-gray-50 whitespace-nowrap"
                >
                    {open ? t('common.cancel') : t('permissions.editUser')}
                </button>
            </div>

            {done && (
                <p className="px-4 pb-2 text-sm text-green-700">{t('permissions.saved')}</p>
            )}

            {open && (
                <div className="border-t border-gray-200 px-4 py-4 bg-gray-50">
                    {error && (
                        <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">
                            {error}
                        </div>
                    )}

                    <div className="grid gap-6 md:grid-cols-2">
                        <div>
                            <h3 className="font-medium mb-2 text-sm">
                                {t('permissions.rolesLabel')}
                            </h3>
                            <div className="space-y-1">
                                {roles.map((r) => (
                                    <label key={r.id} className="flex items-center gap-2 text-sm">
                                        <input
                                            type="checkbox"
                                            checked={checked.includes(r.id)}
                                            onChange={() => toggle(r.id)}
                                        />
                                        <span>
                                            {locale === 'zh' ? r.name_zh : r.name_en}
                                            <span className="ml-1 font-mono text-xs text-gray-400">
                                                {r.code}
                                            </span>
                                        </span>
                                    </label>
                                ))}
                            </div>
                        </div>

                        <div>
                            <h3 className="font-medium mb-2 text-sm">
                                {t('permissions.linkEmployee')}
                            </h3>
                            <select
                                value={employeeId}
                                onChange={(e) => setEmployeeId(e.target.value)}
                                className="w-full border border-gray-300 rounded px-2 py-1 text-sm"
                            >
                                <option value="">{t('permissions.noEmployee')}</option>
                                {options.map((e) => (
                                    <option key={e.id} value={e.id}>
                                        {e.code} — {e.legal_name}
                                    </option>
                                ))}
                            </select>
                            <p className="mt-1 text-xs text-gray-500">
                                {t('permissions.linkEmployeeHint')}
                            </p>

                            <label className="mt-4 block text-sm">
                                {t('permissions.revokeReason')}
                                <input
                                    value={reason}
                                    onChange={(e) => setReason(e.target.value)}
                                    className="mt-1 w-full border border-gray-300 rounded px-2 py-1 text-sm"
                                    placeholder={t('permissions.revokeReasonHint')}
                                />
                            </label>
                        </div>
                    </div>

                    <div className="mt-4">
                        <button
                            type="button"
                            onClick={save}
                            disabled={pending}
                            className="bg-gray-900 text-white px-4 py-1.5 rounded text-sm disabled:opacity-50"
                        >
                            {pending ? t('common.saving') : t('common.save')}
                        </button>
                    </div>
                </div>
            )}
        </div>
    )
}
