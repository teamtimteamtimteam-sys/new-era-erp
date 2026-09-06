// app/settings/roles/page.tsx
// 角色列表:码、双语名、描述、启用、系统角色标记、授权数、持有人数。
import { Button } from '@/app/components/ui/button'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { requireManagePermissions } from '../guard'
import { mustRows } from '@/lib/db-helpers'
import { ListPage } from '@/app/components/ui/list-page'
import RolesTable, { type RoleRow as RolesTableRow } from './RolesTable'

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

    // CONV-5:套 CONV-1 的两文件模板。state 恒为 'ok' —— 抬头「新建角色」
    // 与那句 rolesIntro 都住在状态分支之前。
    // 名称/描述的语言在服务端选好 —— locale 不过 RSC 边界。
    const tableRows: RolesTableRow[] = roles.map((r) => ({
        id: r.id,
        code: r.code,
        isSystem: Boolean(r.is_system),
        name: locale === 'zh' ? r.name_zh : r.name_en,
        description: (locale === 'zh' ? r.description_zh : r.description_en) ?? '—',
        permissionCount: permCount.get(r.id) ?? 0,
        userCount: userCount.get(r.id) ?? 0,
        isActive: Boolean(r.is_active),
    }))

    return (
        <ListPage
            title={t('permissions.title')}
            intro={t('permissions.rolesIntro')}
            maxWidth="max-w-6xl"
            actions={
                <Button asChild>
                    <Link href="/settings/roles/new">{t('permissions.addRole')}</Link>
                </Button>
            }
            state={{ kind: 'ok' }}
        >
            <RolesTable rows={tableRows} empty={t('permissions.rolesEmpty')} />
        </ListPage>
    )
}
