'use client'

// app/finance/freight/[id]/FreightAllocationsTable.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-9(2026-09-04)· 运费分摊明细表
// ════════════════════════════════════════════════════════════════════════════
//
// 【这张表就是这一页存在的理由】资本化之后,一次错的分摊藏在存货里而不是显示在
// 损益表上 —— 所以 basis_qty 与 in_stock_ratio 都摆出来,让那个数可以被
// 【重新导出】,而不是只能被相信。手机上留【批次】与【分到多少】正是这个理由的
// 两列形式:批次是主语,金额是被导出的那个结论。
//
// 【行数据在服务端压平】金额格式要 baseCurrency,那是只有服务端知道的东西;
// 批次链接过界的是 href 这个【字符串】,不是一个函数(CONV-5 §⑩-6 办法①)。
import * as React from 'react'
import Link from 'next/link'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { useTranslations } from '@/lib/i18n/client'

export type FreightAllocRow = {
    id: string
    batchCode: string
    /** null = 这一行没有可点的批次(FK 断了),画成 '—'。 */
    batchHref: string | null
    /** stated 口径没有中间量 —— 这时是一句具名的缺席,不是空白。 */
    basisQtyText: string
    basisQtyStated: boolean
    amountText: string
    inStockText: string
}

export default function FreightAllocationsTable({ rows }: { rows: readonly FreightAllocRow[] }) {
    const t = useTranslations()

    const columns: Column<FreightAllocRow>[] = [
        {
            key: 'batch',
            header: t('finance.freight.colBatch'),
            // 身份列 —— 分摊行的主语是"分给了哪一批货"。
            priority: true,
            className: 'font-mono text-sm',
            render: (r) =>
                r.batchHref ? (
                    <Link href={r.batchHref} className="text-blue-600 hover:underline">
                        {r.batchCode}
                    </Link>
                ) : (
                    '—'
                ),
        },
        {
            key: 'basisQty',
            header: t('finance.freight.colBasisQty'),
            align: 'right',
            className: 'font-mono text-sm',
            // stated 口径没有中间量 —— 金额是人直接列明的,空着是【对的】,
            // 所以它画成一句灰色的具名缺席,而不是一个空格子。
            render: (r) =>
                r.basisQtyStated ? (
                    <span className="text-gray-400">{r.basisQtyText}</span>
                ) : (
                    r.basisQtyText
                ),
        },
        {
            key: 'share',
            header: t('finance.freight.colShare'),
            align: 'right',
            // ★ 这张表存在的理由:**这一批分到了多少钱**。
            priority: true,
            className: 'font-mono text-sm',
            render: (r) => r.amountText,
        },
        {
            key: 'inStock',
            header: t('finance.freight.colInStock'),
            align: 'right',
            className: 'font-mono text-sm',
            render: (r) => r.inStockText,
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('finance.freight.noAllocs')}
        />
    )
}
