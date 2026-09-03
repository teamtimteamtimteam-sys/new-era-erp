// app/settings/reference/page.tsx
// 权限速查:整本目录按类别分组,每条权限列出【当前持有它的角色】。
//
// 这是"谁能看见什么"的答案,同时它【不可能与现实脱节】—— 页面直接读 permissions
// 与 role_permissions,而不是读一份需要有人记得更新的文档。
//
// CONV-5:三个类别各一张表,共用同一个客户端表组件(它们是同一种东西,
// 不是三张不同的表)。state 恒为 'ok' —— 类别标题与那句 referenceIntro
// 在任何行数下都要画。
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { requireManagePermissions } from '../guard'
import { mustRows } from '@/lib/db-helpers'
import { ListPage } from '@/app/components/ui/list-page'
import PermissionReferenceTable, { type PermissionRefRow } from './PermissionReferenceTable'

type Perm = {
    code: string
    category: string
    name_en: string
    name_zh: string
    description_en: string | null
    description_zh: string | null
    sort_order: number
}

const CATEGORY_KEY: Record<string, string> = {
    module: 'permissions.catModule',
    data: 'permissions.catData',
    action: 'permissions.catAction',
}

export default async function ReferencePage() {
    const denied = await requireManagePermissions()
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const [permRes, grantRes] = await Promise.all([
        supabase
            .from('permissions')
            .select('code, category, name_en, name_zh, description_en, description_zh, sort_order')
            .order('sort_order'),
        supabase
            .from('role_permissions')
            .select('permission_code, roles(code, name_en, name_zh, deleted_at)'),
    ])

    const perms = (mustRows(permRes)) as Perm[]
    const holders = new Map<string, { code: string; name_en: string; name_zh: string }[]>()
    for (const g of (mustRows(grantRes)) as unknown as {
        permission_code: string
        roles: { code: string; name_en: string; name_zh: string; deleted_at: string | null } | null
    }[]) {
        if (!g.roles || g.roles.deleted_at) continue
        const arr = holders.get(g.permission_code) ?? []
        arr.push(g.roles)
        holders.set(g.permission_code, arr)
    }

    const categories = ['module', 'data', 'action'].filter((c) =>
        perms.some((p) => p.category === c)
    )

    // 名称/描述/角色名的语言都在服务端选好 —— locale 不过 RSC 边界
    const rowsFor = (cat: string): PermissionRefRow[] =>
        perms
            .filter((p) => p.category === cat)
            .map((p) => ({
                code: p.code,
                name: locale === 'zh' ? p.name_zh : p.name_en,
                description: (locale === 'zh' ? p.description_zh : p.description_en) ?? '—',
                holders: (holders.get(p.code) ?? []).map((r) => (locale === 'zh' ? r.name_zh : r.name_en)),
            }))

    return (
        <ListPage
            title={t('permissions.title')}
            intro={t('permissions.referenceIntro')}
            maxWidth="max-w-5xl"
            state={{ kind: 'ok' }}
        >
            {categories.map((cat) => (
                <section key={cat} className="mb-8">
                    <h2 className="text-lg font-bold mb-3">{t(CATEGORY_KEY[cat] ?? cat)}</h2>
                    <PermissionReferenceTable rows={rowsFor(cat)} />
                </section>
            ))}
        </ListPage>
    )
}
