// app/settings/permissions/reference/page.tsx
// 权限速查:整本目录按类别分组,每条权限列出【当前持有它的角色】。
//
// 这是"谁能看见什么"的答案,同时它【不可能与现实脱节】—— 页面直接读 permissions
// 与 role_permissions,而不是读一份需要有人记得更新的文档。
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import Subnav from '../Subnav'
import { requireManagePermissions } from '../guard'

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

    const perms = (permRes.data ?? []) as Perm[]
    const holders = new Map<string, { code: string; name_en: string; name_zh: string }[]>()
    for (const g of (grantRes.data ?? []) as unknown as {
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

    return (
        <div className="p-8 max-w-5xl">
            <h1 className="text-2xl font-bold mb-4">{t('permissions.title')}</h1>
            <Subnav />

            <p className="text-sm text-gray-600 mb-6">{t('permissions.referenceIntro')}</p>

            {categories.map((cat) => (
                <section key={cat} className="mb-8">
                    <h2 className="text-lg font-bold mb-3">{t(CATEGORY_KEY[cat] ?? cat)}</h2>
                    <table className="w-full border-collapse">
                        <thead>
                            <tr className="bg-gray-50 text-left text-sm">
                                <th className="border border-gray-300 px-3 py-2 w-64">
                                    {t('permissions.permission')}
                                </th>
                                <th className="border border-gray-300 px-3 py-2">
                                    {t('permissions.whatItReveals')}
                                </th>
                                <th className="border border-gray-300 px-3 py-2 w-64">
                                    {t('permissions.heldBy')}
                                </th>
                            </tr>
                        </thead>
                        <tbody>
                            {perms
                                .filter((p) => p.category === cat)
                                .map((p) => {
                                    const hs = holders.get(p.code) ?? []
                                    return (
                                        <tr key={p.code} className="text-sm align-top">
                                            <td className="border border-gray-300 px-3 py-2">
                                                <div>
                                                    {locale === 'zh' ? p.name_zh : p.name_en}
                                                </div>
                                                <div className="font-mono text-xs text-gray-400">
                                                    {p.code}
                                                </div>
                                            </td>
                                            <td className="border border-gray-300 px-3 py-2 text-gray-700">
                                                {(locale === 'zh'
                                                    ? p.description_zh
                                                    : p.description_en) ?? '—'}
                                            </td>
                                            <td className="border border-gray-300 px-3 py-2">
                                                {hs.length === 0 ? (
                                                    <span className="text-gray-400 italic">
                                                        {t('permissions.heldByNobody')}
                                                    </span>
                                                ) : (
                                                    <div className="flex flex-wrap gap-1">
                                                        {hs.map((r) => (
                                                            <span
                                                                key={r.code}
                                                                className="rounded-full bg-gray-100 px-2 py-0.5 text-xs text-gray-700"
                                                            >
                                                                {locale === 'zh'
                                                                    ? r.name_zh
                                                                    : r.name_en}
                                                            </span>
                                                        ))}
                                                    </div>
                                                )}
                                            </td>
                                        </tr>
                                    )
                                })}
                        </tbody>
                    </table>
                </section>
            ))}
        </div>
    )
}
