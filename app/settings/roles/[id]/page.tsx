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
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import { DeletedBanner, EndedFieldset } from '@/app/components/trail/EndedBanner'
import { requireDeletedAccess } from '@/app/components/moduleGuard'

export default async function RoleDetailPage({
    params,
    searchParams,
}: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ trail?: string | string[] }>
}) {
    const denied = await requireManagePermissions()
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const [roleRes, permRes, grantRes, holdersRes] = await Promise.all([
        supabase
            .from('roles')
            .select('id, code, name_en, name_zh, description_en, description_zh, is_system, is_active, sort_order, deleted_at')
            .eq('id', id)
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
    // AUDIT-TRAIL-1d-1(Tim 的 Q25):一个删掉的角色以前在这里 404。现在对持 data.view_deleted 的人只读打开(横幅 + 审计记录),
    //   别人得到一句具名拒绝 —— 不是 404("找不到"读起来是"从来没有过")。页面自己的门(manage_permissions)照旧先问。
    const deleted = !!role.deleted_at
    if (deleted) {
        const refused = await requireDeletedAccess('permissions.roleTitle')
        if (refused) return refused
    }

    return (
        <div className="p-8 max-w-4xl">
            {/* ★ MANUAL-FIX-1 F:这一屏编辑的是【一个角色】,不是「权限」。
                下面 PermissionMatrix 自己那个 <h2>「Permissions」是对的 ——
                那一段【真的】在编授权;错的是顶上这一句,它此前把整屏
                命名成了它其中一段的名字。 */}
            <h1 className="mb-4">{t('permissions.roleTitle')}</h1>

            <div className="mb-4">
                <Link
                    href="/settings/roles"
                    className="hover:underline text-sm app-link"
                >
                    {t('common.back')}
                </Link>
            </div>

            {deleted && <DeletedBanner kind="role" id={role.id} at={role.deleted_at as string} />}

            <h2 className="mb-4">
                {role.name_en}
                <span className="ml-3 text-sm text-[color:var(--brand-muted-text)]">{role.code}</span>
            </h2>

            <EndedFieldset ended={deleted}>
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
            </EndedFieldset>

            {/* AUDIT-TRAIL-1a:页底的审计记录 —— 这个角色的字段,与它的授权加上 / 拿掉(名字取 permissions.name_en);
                AUDIT-TRAIL-1d-1(Q22):外加这个角色授给了谁、从谁那里收回(user_roles —— 家在账号那一边) */}
            <AuditTrail subject="role" id={role.id} show={trailCount((await searchParams).trail)} />
        </div>
    )
}
