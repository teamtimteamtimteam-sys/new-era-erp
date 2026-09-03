'use client'

// app/operation/wip/WipTable.tsx
// CONV-5 · 在制品那张表。
// 工序名的语言、以及"没排到工序"与"没人记过安全状态"这两个判断,都在服务端
// 压平成纯数据 —— locale 与那两条判据都不过 RSC 边界(CONV-1 §① 通则)。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type WipRow = {
    outputBatchId: string
    batchCode: string
    material: string
    qty: string
    /** null = 还没排到具体工序。空是一个答案,而且不是"不适用"。 */
    awaitingLabel: string | null
    safetyStatesRecorded: number
}

export default function WipTable({ rows, empty }: { rows: WipRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【批次】与【等哪一道工序】—— 批次是身份;而这一页回答的是
    //   "下一炉该跑什么",那个答案就在等待工序这一列里。数量进展开区。
    const columns: Column<WipRow>[] = [
        {
            key: 'batch', header: t('processing.wip.colBatch'), priority: true, className: 'font-mono text-sm',
            render: (r) => (
                <Link href={`/output/${r.outputBatchId}/edit`} className="text-blue-600 hover:underline">
                    {r.batchCode}
                </Link>
            ),
        },
        { key: 'material', header: t('processing.wip.colMaterial'), className: 'text-sm', render: (r) => r.material },
        { key: 'qty', header: t('processing.wip.colQty'), align: 'right', className: 'font-mono text-sm', render: (r) => r.qty },
        {
            key: 'awaiting', header: t('processing.wip.colAwaiting'), priority: true, className: 'text-sm',
            render: (r) =>
                r.awaitingLabel ?? (
                    // 【没排到具体工序就说"还没决定",不画成一道工序】
                    // 空是一个答案 —— 而且它【不是】"不适用":这一批仍然是在制品。
                    <span className="text-gray-500 italic">{t('processing.wip.notScheduled')}</span>
                ),
        },
        {
            key: 'safety', header: t('processing.wip.colSafety'), className: 'text-sm',
            render: (r) =>
                // ★ 0 = 没有人记过,不是"安全" —— 而且这一批因此【投不进去】。
                //   把它画成一个安静的 0,就是把那道拒绝藏起来等操作员去撞。
                r.safetyStatesRecorded === 0 ? (
                    <span className="text-amber-700">{t('processing.wip.noSafetyState')}</span>
                ) : (
                    <span className="text-gray-600">
                        {t('processing.wip.safetyRecorded', { n: String(r.safetyStatesRecorded) })}
                    </span>
                ),
        },
    ]

    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => r.outputBatchId} phone={{ mode: 'columns' }} empty={empty} />
    )
}
