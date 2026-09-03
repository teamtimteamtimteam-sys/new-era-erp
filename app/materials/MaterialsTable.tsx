'use client'

// app/materials/MaterialsTable.tsx
// CONV-5 · 物料主数据那张表。
//
// ★★【这一页有【四处】"具名的缺席",一处都不能画成空白】★★
//   · 种类未决定(PROC-1)· 未分类(MAT-1)· 无化验要求(ASY-P2)· 未监控(SS-1)
//   四条各自的理由写在下面对应的列上。服务端把它们压平成【可判空的字段】,
//   由这里画出那四句话 —— 判据不过边界,词过。
// ★ Q7:排序仍是服务端的(sorting.mode='server')。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import DeleteButton from './DeleteButton'

export type MaterialTableRow = {
    id: string
    code: string
    name: string
    /** null = 【没人决定过】种类,不是"没有种类"。 */
    kindLabel: string | null
    chemistry: string
    /** null = 【没有人分过类】,与"分类为非受控"不是一回事。 */
    wasteClassLabel: string | null
    wasteControlled: boolean
    /** 空数组 = 【无化验要求】——一个决定(或一个还没做的决定),不是没填。 */
    assayMetals: string[]
    unitLabel: string
    /** null = 【没有人设过这个阈值】,不是"没事"。 */
    safetyStockLabel: string | null
    status: string
    createdLabel: string
}

export default function MaterialsTable({
    rows, empty, sort, dir, filterQuery, shown, total,
}: {
    rows: MaterialTableRow[]
    empty: React.ReactNode
    sort: string
    dir: 'asc' | 'desc'
    filterQuery: Record<string, string>
    shown: number
    total: number
}) {
    const t = useTranslations()

    const href = (key: string, nextDir: 'asc' | 'desc') => {
        const params = new URLSearchParams(filterQuery)
        params.set('sort', key)
        params.set('dir', nextDir)
        return `/materials?${params.toString()}`
    }

    // ★ 手机上留【物料号】与【物料名】—— 物料号是身份,名字是这份主数据被查的理由。
    //   四处"具名的缺席"都在展开区里,而它们【仍然是那四句话】,不是空白 ——
    //   展开区渲染的是同一个 render,所以那条判据在小屏上没有被削掉。
    const columns: Column<MaterialTableRow>[] = [
        {
            key: 'code', header: t('materials.colCode'), priority: true, sortable: true, className: 'font-mono text-sm',
            render: (r) => (
                <Link href={`/materials/${r.id}/edit`} className="text-blue-600 hover:underline">
                    {r.code}
                </Link>
            ),
        },
        { key: 'name', header: t('materials.colName'), priority: true, sortable: true, render: (r) => r.name },
        {
            // PROC-1:【没人决定过】按名印出来,不留空 —— 空白会被读成"没有种类"
            key: 'category', header: t('materials.colCategory'),
            render: (r) => r.kindLabel ?? <span className="text-amber-700">{t('materials.kindUndecided')}</span>,
        },
        { key: 'chemistry', header: t('materials.colChemistry'), render: (r) => r.chemistry },
        {
            // MAT-1:【未分类要说出来,不能画成空白】
            key: 'wasteClass', header: t('materials.colWasteClass'), className: 'text-sm',
            render: (r) =>
                r.wasteClassLabel ? (
                    <>
                        {r.wasteClassLabel}
                        {r.wasteControlled && (
                            <span className="ml-2 px-1.5 py-0.5 rounded text-xs bg-amber-100 text-amber-800 border border-amber-300">
                                {t('materials.wasteClass.controlled')}
                            </span>
                        )}
                    </>
                ) : (
                    <span className="text-gray-400">{t('materials.wasteClass.unclassified')}</span>
                ),
        },
        {
            // ASY-P2:【"无化验要求"要说出来,不能画成空白】
            key: 'assay', header: t('materials.colAssayRequired'), className: 'text-sm',
            render: (r) =>
                r.assayMetals.length === 0 ? (
                    <span className="text-gray-400">{t('materials.assayPolicy.noRequirement')}</span>
                ) : (
                    <span className="font-mono text-xs">{r.assayMetals.map((c) => t('metals.' + c)).join(', ')}</span>
                ),
        },
        { key: 'unit', header: t('materials.colUnit'), render: (r) => r.unitLabel },
        {
            // SS-1:【绝不留空】—— 空白读起来像"没事",而真实含义是"没有人设过这个阈值"
            key: 'safetyStock', header: t('materials.colSafetyStock'),
            render: (r) => r.safetyStockLabel ?? <span className="text-gray-400">{t('materials.notMonitored')}</span>,
        },
        {
            key: 'status', header: t('materials.colStatus'),
            render: (r) => <span className="px-2 py-1 bg-gray-200 rounded text-xs">{r.status}</span>,
        },
        {
            key: 'created_at', header: t('materials.colCreated'), sortable: true,
            className: 'text-sm text-gray-600', render: (r) => r.createdLabel,
        },
        {
            key: 'actions', header: t('materials.colActions'),
            render: (r) => <DeleteButton id={r.id} name={r.name} />,
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
            sorting={{ mode: 'server', coverage: { shown, total }, active: { key: sort, dir }, href }}
        />
    )
}
