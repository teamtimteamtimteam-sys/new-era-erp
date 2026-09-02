// app/settings/roles/[id]/page.tsx
// 单个角色:字段表单 + 授权矩阵。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { requireManagePermissions } from '../../guard'
import RoleForm from '../RoleForm'
import PermissionMatrix, { type PermissionRow } from '../PermissionMatrix'
import { mustRows } from '@/lib/db-helpers'

export default async function RoleDetailPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const denied = await requireManagePermissions()
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const [roleRes, permRes, grantRes, holdersRes] = await Promise.all([
        supabase
            .from('roles')
            .select('id, code, name_en, name_zh, description_en, description_zh, is_system, is_active, sort_order')
            .eq('id', id)
            .is('deleted_at', null)
            .single(),
        supabase
            .from('permissions')
            .select('code, category, name_en, name_zh, description_en, description_zh, sort_order')
            .order('sort_order'),
        supabase.from('role_permissions').select('permission_code').eq('role_id', id),
        supabase.from('user_roles').select('id').eq('role_id', id).is('revoked_at', null),
    ])

    if (roleRes.error || !roleRes.data) notFound()
    const role = roleRes.data

    return (
        <div className="p-8 max-w-4xl">
            <h1 className="text-2xl font-bold mb-4">{t('permissions.title')}</h1>

            <div className="mb-4">
                <Link
                    href="/settings/roles"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h2 className="text-xl font-bold mb-4">
                {role.name_en}
                <span className="ml-3 font-mono text-sm text-gray-500">{role.code}</span>
            </h2>

            <RoleForm
                initial={{
                    id: role.id,
                    code: role.code,
                    name_en: role.name_en,
                    name_zh: role.name_zh,
                    description_en: role.description_en ?? '',
                    description_zh: role.description_zh ?? '',
                    is_active: role.is_active,
                    sort_order: role.sort_order,
                    is_system: role.is_system,
                    user_count: (mustRows(holdersRes)).length,
                }}
            />

            <PermissionMatrix
                roleId={role.id}
                permissions={(mustRows(permRes)) as PermissionRow[]}
                initial={(mustRows(grantRes)).map((g) => g.permission_code)}
            />
        </div>
    )
}
