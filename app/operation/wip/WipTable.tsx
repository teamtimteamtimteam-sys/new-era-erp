'use client'

// app/operation/wip/WipTable.tsx
// CONV-5 · 在制品那张表。
// 工序名的语言、以及"没排到工序"与"没人记过安全状态"这两个判断,都在服务端
// 压平成纯数据 —— locale 与那两条判据都不过 RSC 边界(CONV-1 §① 通则)。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xNum } from '@/lib/export/cells'

export type WipRow = {
    outputBatchId: string
    batchCode: string
    material: string
    qty: string
    /** null = 还没排到具体工序。空是一个答案,而且不是"不适用"。 */
    awaitingLabel: string | null
    safetyStatesRecorded: number
    /** TABLE-EXPORT-1:导出用的原始余量(Excel 里是一个数,不是「12 kg」这串字;单位见物料)。 */
    remainingQty: number
    /** TABLE-EXPORT-1:屏幕上跟在余量后面的单位(原样的码)—— 各行不同,导出时一起写。 */
    unit: string
}

export default function WipTable({ rows, empty }: { rows: WipRow[]; empty: React.ReactNode }) {
    const oneUnit = new Set(rows.map((r) => r.unit)).size <= 1
    const t = useTranslations()

    // ★ 手机上留【批次】与【等哪一道工序】—— 批次是身份;而这一页回答的是
    //   "下一炉该跑什么",那个答案就在等待工序这一列里。数量进展开区。
    const columns: ExportableColumn<WipRow>[] = [
        {
            key: 'batch', header: t('processing.wip.colBatch'), priority: true, className: 'text-sm', exportAs: (r) => xText(r.batchCode),
            render: (r) => (
                <Link href={`/output/${r.outputBatchId}/edit`} className="hover:underline app-link">
                    {r.batchCode}
                </Link>
            ),
        },
        { key: 'material', header: t('processing.wip.colMaterial'), className: 'text-sm', render: (r) => r.material, exportAs: (r) => xText(r.material) },
        { key: 'qty', header: t('processing.wip.colQty'), align: 'right', className: 'text-sm', render: (r) => r.qty, exportAs: (r) => xNum(r.remainingQty, 'qty', r.unit),
            // TABLE-FEATURES-1 Q9:单位可以逐行不同(kg、件……)—— 这一屏的行【都是同一个单位】时才可排,
            //   否则把不同单位的数放在一起排没有意义(与「各行币种不同的金额」同一条)。
            sortable: oneUnit ? undefined : false },
        {
            key: 'awaiting', header: t('processing.wip.colAwaiting'), priority: true, className: 'text-sm',
            exportAs: (r) => xText(r.awaitingLabel ?? t('processing.wip.notScheduled')),
            render: (r) =>
                r.awaitingLabel ?? (
                    // 【没排到具体工序就说"还没决定",不画成一道工序】
                    // 空是一个答案 —— 而且它【不是】"不适用":这一批仍然是在制品。
                    <span className="text-gray-500 italic">{t('processing.wip.notScheduled')}</span>
                ),
        },
        {
            key: 'safety', header: t('processing.wip.colSafety'), className: 'text-sm',
            // 0 是一句具名的话(没有人记过),不是一个安静的 0 —— 导出同一句话
            exportAs: (r) => xText(r.safetyStatesRecorded === 0 ? t('processing.wip.noSafetyState')
                : t('processing.wip.safetyRecorded', { n: String(r.safetyStatesRecorded) })),
            render: (r) =>
                // ★ 0 = 没有人记过,不是"安全" —— 而且这一批因此【投不进去】。
                //   把它画成一个安静的 0,就是把那道拒绝藏起来等操作员去撞。
                r.safetyStatesRecorded === 0 ? (
                    <span className="text-amber-700">{t('processing.wip.noSafetyState')}</span>
                ) : (
                    <span className="text-[color:var(--brand-muted-text)]">
                        {t('processing.wip.safetyRecorded', { n: String(r.safetyStatesRecorded) })}
                    </span>
                ),
        },
    ]

    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => r.outputBatchId} phone={{ mode: 'columns' }} empty={empty}
                   exportSpec={{ name: 'operation-wip', title: t('processing.wip.title') }}
                   // TABLE-FEATURES-1 Q9:一次读取拿到全体 —— 在浏览器里排
                   sorting={{ mode: 'client', coverage: 'complete' }} />
    )
}
