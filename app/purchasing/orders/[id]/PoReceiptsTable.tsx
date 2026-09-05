'use client'

// app/purchasing/orders/[id]/PoReceiptsTable.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-8(2026-09-04)· 这张单收到了什么
// ════════════════════════════════════════════════════════════════════════════
//
// ★【「敞口」那一列走 MaskedValue,而【不能】在服务端折成一个字符串】★
// 敞口是 finance 的数;没有 module.finance.view 的人看到的必须是「受限」,
// 不是 0、也不是空白 —— `lib/permissions.ts` 存在的全部理由就是
// 「null 已经有主了」(AGENTS.md 那条 0 冒充受限)。
// 所以这一列传的是 `openText: string | null` **加上一个 canFinance 布尔**,
// 由 MaskedValue 去画那两种情形。把它在服务端折成 '—' 会把两件事压平成一件。
//
// ☞ 手机上留【批次号】与【数量】:批次号是身份,而这张表回答的是"到了多少"。
//   单价与敞口进展开区 —— 与 CONV-5 给 /inventory/reports/snapshot 留数量
//   而不留价值是同一条理由:这一页的读者里有看不到价的人。
import * as React from 'react'
import Link from 'next/link'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { MaskedValue } from '@/app/components/MaskedValue'
import { useTranslations } from '@/lib/i18n/client'

export type PoReceiptRow = {
    id: string
    code: string
    arrivalDateText: string
    qtyText: string
    /** null = 这一批还没有定价(画成琥珀色的「未计价」,不是空白)。 */
    unitPriceText: string | null
    /**
     * ★ FIX-2b:null = 【看不到】(prepayment_applications_masked 在财务那道门
     * 后面),'—' = 这一批【真的】没有抵扣过。此前两者都是 '—'。
     */
    appliedText: string | null
    /** 见抬头:null 与「看不到」是两件事,交给 MaskedValue 分。 */
    openText: string | null
    /** unit_price 为空时,敞口这一格印破折号 —— 没有价就没有敞口可言。 */
    openApplicable: boolean
}

export default function PoReceiptsTable({
    rows,
    canFinance,
}: {
    rows: readonly PoReceiptRow[]
    canFinance: boolean
}) {
    const t = useTranslations()

    const columns: Column<PoReceiptRow>[] = [
        {
            key: 'code',
            header: t('finance.colCode'),
            // 身份列。
            priority: true,
            className: 'font-mono text-sm',
            render: (r) => (
                <Link href={`/inbound/${r.id}/edit`} className="text-blue-600 hover:underline">
                    {r.code}
                </Link>
            ),
        },
        {
            key: 'arrival',
            header: t('inbound.form.arrivalDate'),
            render: (r) => r.arrivalDateText,
        },
        {
            key: 'qty',
            header: t('purchasing.colQuantity'),
            align: 'right',
            // 这张表存在的理由:到了多少。
            priority: true,
            className: 'font-mono text-sm',
            render: (r) => r.qtyText,
        },
        {
            key: 'unitPrice',
            header: t('purchasing.colUnitPrice'),
            align: 'right',
            className: 'font-mono text-sm',
            render: (r) =>
                r.unitPriceText !== null ? (
                    r.unitPriceText
                ) : (
                    <span className="text-amber-700">{t('purchasing.unpriced')}</span>
                ),
        },
        {
            key: 'applied',
            header: t('purchasing.appliedLabel'),
            align: 'right',
            className: 'font-mono text-sm',
            // 与右邻那一格同一种画法(MaskedValue),所以「受限」在这张表里
            // 只有一个样子 —— CONV-0 收敛出来的那一个。
            render: (r) => <MaskedValue value={r.appliedText} canView={canFinance} />,
        },
        {
            key: 'open',
            header: t('finance.colOpen'),
            align: 'right',
            className: 'font-mono text-sm',
            render: (r) =>
                !r.openApplicable ? '—' : <MaskedValue value={r.openText} canView={canFinance} />,
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('purchasing.noReceipts')}
        />
    )
}
