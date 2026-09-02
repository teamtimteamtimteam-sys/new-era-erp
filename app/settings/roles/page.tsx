// app/settings/roles/page.tsx
// 角色列表:码、双语名、描述、启用、系统角色标记、授权数、持有人数。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { requireManagePermissions } from '../guard'
import { mustRows } from '@/lib/db-helpers'

type RoleRow = {
    id: string
    code: string
    name_en: string
    name_zh: string
    description_en: string | null
    description_zh: string | null
    is_system: boolean
    is_active: boolean
    sort_order: number
}

export default async function RolesPage() {
    const denied = await requireManagePermissions()
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const [rolesRes, permRes, userRes] = await Promise.all([
        supabase
            .from('roles')
            .select('id, code, name_en, name_zh, description_en, description_zh, is_system, is_active, sort_order')
            .is('deleted_at', null)
            .order('sort_order'),
        supabase.from('role_permissions').select('role_id'),
        supabase.from('user_roles').select('role_id').is('revoked_at', null),
    ])

    const roles = (mustRows(rolesRes)) as RoleRow[]
    const permCount = new Map<string, number>()
    for (const r of mustRows(permRes)) permCount.set(r.role_id, (permCount.get(r.role_id) ?? 0) + 1)
    const userCount = new Map<string, number>()
    for (const r of mustRows(userRes)) userCount.set(r.role_id, (userCount.get(r.role_id) ?? 0) + 1)

    return (
        <div className="p-8 max-w-6xl">
            <h1 className="text-2xl font-bold mb-4">{t('permissions.title')}</h1>

            <div className="flex justify-between items-center mb-4">
                <p className="text-sm text-gray-600">{t('permissions.rolesIntro')}</p>
                <Link
                    href="/settings/roles/new"
                    className="bg-gray-900 text-white px-3 py-1.5 rounded text-sm"
                >
                    {t('permissions.addRole')}
                </Link>
            </div>

            <table className="w-full border-collapse">
                <thead>
                    <tr className="bg-gray-50 text-left text-sm">
                        <th className="border border-gray-300 px-3 py-2">{t('permissions.roleCode')}</th>
                        <th className="border border-gray-300 px-3 py-2">{t('permissions.roleName')}</th>
                        <th className="border border-gray-300 px-3 py-2">{t('permissions.roleDescription')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('permissions.permissionCount')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('permissions.userCount')}</th>
                        <th className="border border-gray-300 px-3 py-2">{t('permissions.active')}</th>
                        <th className="border border-gray-300 px-3 py-2"></th>
                    </tr>
                </thead>
                <tbody>
                    {roles.map((r) => (
                        <tr key={r.id} className="text-sm">
                            <td className="border border-gray-300 px-3 py-2 font-mono text-xs">
                                {r.code}
                                {r.is_system && (
                                    <span className="ml-2 rounded bg-amber-100 px-1.5 py-0.5 text-[10px] text-amber-800">
                                        {t('permissions.systemRole')}
                                    </span>
                                )}
                            </td>
                            <td className="border border-gray-300 px-3 py-2">
                                {locale === 'zh' ? r.name_zh : r.name_en}
                            </td>
                            <td className="border border-gray-300 px-3 py-2 text-gray-600">
                                {(locale === 'zh' ? r.description_zh : r.description_en) ?? '—'}
                            </td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                {permCount.get(r.id) ?? 0}
                            </td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                {userCount.get(r.id) ?? 0}
                            </td>
                            <td className="border border-gray-300 px-3 py-2">
                                {r.is_active ? t('permissions.yes') : t('permissions.no')}
                            </td>
                            <td className="border border-gray-300 px-3 py-2">
                                <Link
                                    href={`/settings/roles/${r.id}`}
                                    className="text-blue-600 hover:underline"
                                >
                                    {t('permissions.editRole')}
                                </Link>
                            </td>
                        </tr>
                    ))}
                </tbody>
            </table>
        </div>
    )
}
