'use client'

// app/finance/credit-notes/[id]/CreditNoteLinesTable.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-9(2026-09-04)· 贷项凭证的行表
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么这一页多一个文件】CONV-1 §① 那条:`Column.render` 是函数,RSC 传不过
// 客户端边界,所以列描述符必须住在一个 'use client' 文件里。RecordHeader 不受
// 这一条约束(props 全是数据),所以详情页的「多一个文件」只由有表的那一半承担。
//
// 【行数据在服务端就压平成字符串了】`t('cn.kind.' + kind)` 的动态前缀、
// 金额格式、以及那个减号,全部在 page.tsx 里做完 —— 一个判据、一个 Map 都不过界。
//
// ★【合计行是一行【数据】,不是一个 <tfoot>】★
// 转换前这张表的最后一行是 `colSpan={4}` 的合计。DataTable 没有表尾概念,
// 而 CONV-4 §⑨-3 已经为这件事定过型(isTotal + rowClassName),CONV-8 §⑧
// 复核过并保留了那条裁定 —— **一种东西一个写法**。代价照 CONV-8 记的写:
// 合计标签不再顶到右边,而是落在【发票行】那一列。
import * as React from 'react'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { useTranslations } from '@/lib/i18n/client'

export type CreditNoteLineRow = {
    id: string
    lineNo: string
    description: string
    kindText: string
    qtyText: string
    amountText: string
    /** 合计行。见抬头。 */
    isTotal?: boolean
}

export default function CreditNoteLinesTable({
    rows,
    amountHeader,
}: {
    rows: readonly CreditNoteLineRow[]
    /** 冲减({ccy}) —— 币种由服务端插好,所以这个表头整句过界。 */
    amountHeader: string
}) {
    const t = useTranslations()

    const columns: Column<CreditNoteLineRow>[] = [
        {
            key: 'lineNo',
            header: '#',
            className: 'font-mono text-sm',
            render: (r) => r.lineNo,
        },
        {
            key: 'line',
            header: t('cn.colLine'),
            // 身份列 —— 手机上必须留下,否则展开区里那一竖列没有主语。
            // 【为什么不是 #】发票行号在这张凭证之外没有意义;人认得出的是那行货。
            priority: true,
            render: (r) => r.description,
        },
        {
            key: 'kind',
            header: t('cn.colKind'),
            render: (r) => r.kindText,
        },
        {
            key: 'qty',
            header: t('cn.colQty'),
            align: 'right',
            className: 'font-mono text-sm',
            render: (r) => r.qtyText,
        },
        {
            key: 'amount',
            header: amountHeader,
            align: 'right',
            // ★ 这张表存在的理由:**这一行冲掉了多少钱**。
            priority: true,
            className: 'font-mono text-sm',
            render: (r) => r.amountText,
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            rowClassName={(r) => (r.isTotal ? 'font-bold bg-[color:var(--brand-muted)]' : undefined)}
            empty={t('cn.noLines')}
        />
    )
}
