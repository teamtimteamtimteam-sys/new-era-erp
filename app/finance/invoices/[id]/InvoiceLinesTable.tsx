'use client'

// app/finance/invoices/[id]/InvoiceLinesTable.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-10(2026-09-04)· 一张发票的明细行
// ════════════════════════════════════════════════════════════════════════════
//
// ★★【这一页是本刀 16 张里唯一一张【委托点名、且量得到】的坏页】★★
//   修复前实测 **+133px 溢出 / 2 张表被裁**,culprit `a.text-blue-600`。
//   两张被裁的表就是【这一张】与【结算历史】,而那个 a 就是下面这一列
//   「AR 单据」的链接 —— 6 列的表在 390px 上必然顶宽,而最后那一列
//   是一个不折行的链接。
//
//   ☞ **委托记的是 +123px,实测 +133px。** 差的 10px 不是谁记错了:
//     是 §⑬-1 修好的那件事 —— 修前探针取发票【没有 order by】,
//     PostgREST 按物理顺序返回,两跑量的根本不是同一张发票。
//
// ★【手机上留【摘要】与【金额】】★
//   一行明细的主语是"卖了什么",而一张发票被打开的理由是"这一行多少钱"。
//   行号 / 数量 / 单价 / AR 链接进展开区 —— 它们回答的是"这个数怎么来的",
//   那是第二个问题。**AR 链接进展开区是刻意的**:它是每行一个的钻取入口,
//   不是这一行的身份;而它正是那个把整页顶宽的元素。
import * as React from 'react'
import Link from 'next/link'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { useTranslations } from '@/lib/i18n/client'

export type InvoiceLineRow = {
    id: string
    lineNo: number
    description: string
    qtyText: string
    unitPriceText: string
    amountText: string
    arHref: string
}

export default function InvoiceLinesTable({ rows }: { rows: readonly InvoiceLineRow[] }) {
    const t = useTranslations()

    const columns: Column<InvoiceLineRow>[] = [
        { key: 'lineNo', header: t('invoice.colLineNo'), className: 'text-sm text-gray-500', render: (r) => r.lineNo },
        {
            key: 'description',
            header: t('invoice.colDescription'),
            // 身份列:一行明细的主语是"卖了什么"。
            priority: true,
            className: 'text-sm',
            render: (r) => r.description,
        },
        { key: 'qty', header: t('invoice.colQuantity'), align: 'right', className: 'font-mono text-sm', render: (r) => r.qtyText },
        { key: 'unitPrice', header: t('invoice.colUnitPrice'), align: 'right', className: 'font-mono text-sm', render: (r) => r.unitPriceText },
        {
            key: 'amount',
            header: t('invoice.colAmount'),
            align: 'right',
            // ★ 一张发票被打开的理由:这一行【多少钱】。
            priority: true,
            className: 'font-mono text-sm',
            render: (r) => r.amountText,
        },
        {
            // 转换前这一列的表头是一个空的 <th />(它给了,所以 th/td 数是对的 ——
            // 与 /operation/orders/[id] 那一对镜像错位【不是】同一回事)。
            key: 'ar',
            header: '',
            className: 'text-sm',
            // 每行都能跳回它背后的 AR 单据(凭据附件挂在那里)。
            render: (r) => (
                <Link href={r.arHref} className="text-blue-600 hover:underline">
                    {t('finance.arDocTitle')}
                </Link>
            ),
        },
    ]

    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => r.id}
                   phone={{ mode: 'columns' }} empty={t('invoice.noLines')} />
    )
}
