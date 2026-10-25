'use client'

// app/settings/reference/PermissionReferenceTable.tsx
// CONV-5 · 权限速查那张表(每个类别一张,同一个组件用三次)。

import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText } from '@/lib/export/cells'

export type PermissionRefRow = {
    code: string
    name: string
    description: string
    /** 当前持有它的角色名(已按 locale 选好);空数组 = 没有任何角色持有。 */
    holders: string[]
}

// TABLE-EXPORT-2b-1:每个类别一张,导出名与标题由页面按类别给
export default function PermissionReferenceTable({ rows, exportName, exportTitle, sortable }: {
    rows: PermissionRefRow[]; exportName: string; exportTitle: string
    /** TABLE-FEATURES-1 Q9:页面的那一次读取是否完整(未读满 1,000 行)—— 是才在浏览器里排 */
    sortable: boolean
}) {
    const t = useTranslations()

    // ★ 3 列表:手机上留【权限】与【谁持有】—— 权限码是身份,而这一页就是
    //   "谁能看见什么"的答案,持有者那一列【就是】那个答案。
    //   "它揭示什么"是解释性文字,进展开区。
    const columns: ExportableColumn<PermissionRefRow>[] = [
        {
            key: 'permission', header: t('permissions.permission'), priority: true, className: 'w-64',
            // 格里上下两行(名字 + 权限码)—— 照屏幕拼成一串,码不能丢(它才是身份)
            exportAs: (r) => xText(`${r.name} · ${r.code}`),
            render: (r) => (
                <>
                    <div>{r.name}</div>
                    <div className="font-mono text-xs text-gray-400">{r.code}</div>
                </>
            ),
        },
        {
            key: 'reveals', header: t('permissions.whatItReveals'), className: 'text-gray-700',
            render: (r) => r.description, exportAs: (r) => xText(r.description),
        },
        {
            key: 'heldBy', header: t('permissions.heldBy'), priority: true, className: 'w-64',
            // TABLE-FEATURES-1 Q9:没有任何角色持有的排最后(不当成那句「无人持有」去比)
            sortValue: (r) => (r.holders.length === 0 ? null : r.holders.join(', ')),
            exportAs: (r) => xText(r.holders.length === 0 ? t('permissions.heldByNobody') : r.holders.join(', ')),
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

    // phone 写成字面量,check-datatable-phone 才读得出这张表在 390px 上留哪几列
    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => r.code} phone={{ mode: 'columns' }}
                   exportSpec={{ name: exportName, title: exportTitle }}
                   {...(sortable ? { sorting: { mode: 'client' as const, coverage: 'complete' as const } } : {})} />
    )
}
