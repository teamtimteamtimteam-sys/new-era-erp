'use client'

// app/settings/reference/PermissionReferenceTable.tsx
// CONV-5 · 权限速查那张表(每个类别一张,同一个组件用三次)。

import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type PermissionRefRow = {
    code: string
    name: string
    description: string
    /** 当前持有它的角色名(已按 locale 选好);空数组 = 没有任何角色持有。 */
    holders: string[]
}

export default function PermissionReferenceTable({ rows }: { rows: PermissionRefRow[] }) {
    const t = useTranslations()

    // ★ 3 列表:手机上留【权限】与【谁持有】—— 权限码是身份,而这一页就是
    //   "谁能看见什么"的答案,持有者那一列【就是】那个答案。
    //   "它揭示什么"是解释性文字,进展开区。
    const columns: Column<PermissionRefRow>[] = [
        {
            key: 'permission', header: t('permissions.permission'), priority: true, className: 'w-64',
            render: (r) => (
                <>
                    <div>{r.name}</div>
                    <div className="font-mono text-xs text-gray-400">{r.code}</div>
                </>
            ),
        },
        {
            key: 'reveals', header: t('permissions.whatItReveals'), className: 'text-gray-700',
            render: (r) => r.description,
        },
        {
            key: 'heldBy', header: t('permissions.heldBy'), priority: true, className: 'w-64',
            render: (r) =>
                r.holders.length === 0 ? (
                    <span className="text-gray-400 italic">{t('permissions.heldByNobody')}</span>
                ) : (
                    <div className="flex flex-wrap gap-1">
                        {r.holders.map((h) => (
                            <span key={h} className="rounded-full bg-gray-100 px-2 py-0.5 text-xs text-gray-700">
                                {h}
                            </span>
                        ))}
                    </div>
                ),
        },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.code} phone={{ mode: 'columns' }} />
}
