'use client'

// app/finance/journal/[id]/JournalLinesTable.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-8(2026-09-04)· 分录行表 —— 详情页的第一张 DataTable
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么这一页多一个文件,而抬头没有】CONV-1 §① 那条:`Column.render` 是函数,
// RSC 传不过客户端边界,所以列描述符必须住在一个 'use client' 文件里。
// **RecordHeader 不受这一条约束**(它的 props 全是数据),所以详情页的
// 「多一个文件」只由【有表的那一半】承担,不由整页承担。
//
// 【行数据在服务端就压平成字符串了】locale(科目名取 zh 还是 en)与 baseCurrency
// (金额格式)都是**只有服务端知道的东西**,一个 Map、一个判据都不过界 ——
// 与 CONV-1 在 /inbound 的来源列上做的事逐字同形。
//
// ★【合计行是一行【数据】,不是一个 <tfoot>】★
// 转换前这张表有一个 <tfoot> 借贷合计。DataTable 没有表尾概念,而 CONV-4 §⑨-3
// 已经为这件事定过型:**把合计行当数据塞进 rows(带 isTotal),用 rowClassName
// 加粗它**,不给组件另开一个槽。本刀量到全仓详情页共 9 张页面、18 处 <tfoot>,
// 数字远过「第三次才建」那道坎 —— 而仍然不建,理由是【一种东西一个写法】:
// 合计已经有一个能用的表达方式,再加一个只会让两种写法同时活着。
// (这一条是 Tim 在本刀的裁定,连数字一起记在 docs/detail-page-template.md。)
import * as React from 'react'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { useTranslations } from '@/lib/i18n/client'

export type JournalLineRow = {
    id: string
    accountCode: string
    accountName: string
    debitText: string
    creditText: string
    /** 原币那一格:与借/贷【不是同一个币种】,所以它自带前缀,见服务端注释。 */
    ccyText: string
    memo: string
    /** 合计行。见抬头。 */
    isTotal?: boolean
}

export default function JournalLinesTable({ rows }: { rows: readonly JournalLineRow[] }) {
    const t = useTranslations()

    const columns: Column<JournalLineRow>[] = [
        {
            key: 'account',
            header: t('finance.colAccount'),
            // 身份列 —— 手机上必须留下,否则展开区里那一竖列没有主语。
            priority: true,
            render: (r) =>
                r.isTotal ? (
                    r.accountName
                ) : (
                    <>
                        <span className="mr-2 font-mono text-sm">{r.accountCode}</span>
                        {r.accountName}
                    </>
                ),
        },
        {
            key: 'debit',
            header: t('finance.debit'),
            align: 'right',
            // ★【借与贷【两列都】留在手机上,而这是一个判断,不是一次测量】★
            // 一条分录行只说「科目 + 金额」是不成话的:同一个数字在借方与在贷方
            // 是相反的两件事。留一列会逼读者去展开每一行才能知道方向 ——
            // 那正好毁掉 DataTable 抬头说的「顺着一列往下比」。
            // 代价是手机上是三列而不是两列,已在 survey-phone 上量过不溢出。
            priority: true,
            className: 'font-mono text-sm',
            render: (r) => r.debitText,
        },
        {
            key: 'credit',
            header: t('finance.credit'),
            align: 'right',
            priority: true,
            className: 'font-mono text-sm',
            render: (r) => r.creditText,
        },
        {
            key: 'ccy',
            header: t('finance.colOriginalCcy'),
            render: (r) => r.ccyText,
        },
        {
            key: 'memo',
            header: t('finance.lineMemo'),
            render: (r) => r.memo,
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            rowClassName={(r) => (r.isTotal ? 'font-bold bg-[color:var(--brand-muted)]' : undefined)}
            empty={t('finance.noJournalLines')}
        />
    )
}
