'use client'

// app/finance/payments/[id]/PaymentAllocationsTable.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-9(2026-09-04)· 收付款的核销行表
// ════════════════════════════════════════════════════════════════════════════
//
// ★【手机上【三列全留】,而这是一个判断,不是一次测量】★
// 两个金额列不是同一个数:左边是解除掉的应收/应付(本位币,按【单据】入账汇率),
// 右边是这条核销吃掉的款额(付款币种)。跨币种时它们的差额【就是已实现汇兑】——
// 而 page.tsx 里那段 FIN-18 的注释正是为这件事写的。把其中一列赶进展开区,
// 等于把"这两个数为什么不一样"这个问题从屏幕上拿掉。
// 与 CONV-8 在分录行表上留三列(科目/借/贷)是同一条判据的同一个答案:
// **一个数字单独出现时说的是另一件事。**
//
// 【行数据在服务端压平】单据编号要跨五种来源反查(发票/销售/开支/采购单/进料批次),
// 那是一段只有服务端做得了的判断;过界的是 code 与 href 两个字符串。
import * as React from 'react'
import Link from 'next/link'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type PaymentAllocRow = {
    id: string
    docCode: string
    docHref: string | null
    allocatedBaseText: string
    allocatedPayText: string
    /** 合计行。见 CONV-4 §⑨-3 / CONV-8 §⑧。 */
    isTotal?: boolean
}

export default function PaymentAllocationsTable({
    rows,
    docHeader,
    baseHeader,
    payHeader,
    empty,
}: {
    rows: readonly PaymentAllocRow[]
    docHeader: string
    /** 已解除应付/应收 ({baseCurrency}) —— 币种由服务端插好。 */
    baseHeader: string
    /** 消耗款额 ({payment.currency}) —— 同上。 */
    payHeader: string
    empty: string
}) {
    const columns: Column<PaymentAllocRow>[] = [
        {
            key: 'doc',
            header: docHeader,
            // 身份列 —— 一条核销行的主语是"冲的哪一张单据"。
            priority: true,
            className: 'font-mono text-sm',
            render: (r) =>
                r.docHref ? (
                    <Link href={r.docHref} className="text-blue-600 hover:underline">
                        {r.docCode}
                    </Link>
                ) : (
                    r.docCode
                ),
        },
        {
            key: 'base',
            header: baseHeader,
            align: 'right',
            priority: true, // ★ 见抬头:两个金额列一起才解释得清那笔汇兑差。
            className: 'font-mono text-sm',
            render: (r) => r.allocatedBaseText,
        },
        {
            key: 'pay',
            header: payHeader,
            align: 'right',
            priority: true, // ★ 同上。
            className: 'font-mono text-sm',
            render: (r) => r.allocatedPayText,
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            rowClassName={(r) => (r.isTotal ? 'font-bold bg-[color:var(--brand-muted)]' : undefined)}
            empty={empty}
        />
    )
}
