// app/settings/permissions/page.tsx
// 账号页:系统账号一行一个 —— 邮箱、关联员工、当前角色、最近登录、创建时间。
// 数据来自 user_directory 视图(cut 3 B2):它是属主权限视图,谓词写在视图体里,
// 没有 action.manage_permissions 的人拿到【零行而不是报错】。
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import Subnav from './Subnav'
import { requireManagePermissions } from './guard'
import UserRow, { type DirectoryRow, type RoleOption, type EmployeeOption } from './UserRow'

export default async function PermissionUsersPage() {
    const denied = await requireManagePermissions()
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const [dirRes, rolesRes, empRes] = await Promise.all([
        supabase.from('user_directory').select('*').order('created_at', { ascending: true }),
        supabase
            .from('roles')
            .select('id, code, name_en, name_zh, is_system')
            .is('deleted_at', null)
            .eq('is_active', true)
            .order('sort_order'),
        supabase
            .from('employees')
            .select('id, code, legal_name, user_id')
            .is('deleted_at', null)
            .order('code'),
    ])

    const rows = (dirRes.data ?? []) as unknown as DirectoryRow[]
    const roles = (rolesRes.data ?? []) as RoleOption[]
    const employees = (empRes.data ?? []) as EmployeeOption[]

    const fmt = (v: string | null) =>
        v ? new Date(v).toLocaleString(dateLocale) : '—'

    return (
        <div className="p-8 max-w-6xl">
            <h1 className="text-2xl font-bold mb-4">{t('permissions.title')}</h1>
            <Subnav />

            {/* C4:被锁在门外的人读不到这个界面 —— 所以恢复流程必须写在【别处】,
                这里只负责告诉还进得来的人:它存在,在哪儿。 */}
            <div className="mb-6 rounded border border-gray-200 bg-gray-50 px-4 py-3 text-sm text-gray-600">
                <span className="font-medium">{t('permissions.recoveryTitle')}</span>{' '}
                {t('permissions.recoveryBody')}
                <code className="ml-1 font-mono text-xs">
                    db/migrations/2026-08-01-perm2a-module-enforcement.sql
                </code>
            </div>

            <p className="mb-4 text-sm text-gray-500 italic">{t('permissions.noCreateUser')}</p>

            {rows.length === 0 ? (
                <p className="text-gray-500">{t('permissions.noUsers')}</p>
            ) : (
                <div className="space-y-3">
                    {rows.map((r) => (
                        <UserRow
                            key={r.user_id}
                            row={r}
                            roles={roles}
                            employees={employees}
                            lastSignInDisplay={fmt(r.last_sign_in_at)}
                            createdDisplay={fmt(r.created_at)}
                        />
                    ))}
                </div>
            )}
        </div>
    )
}
