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
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xMoney, xRestricted, xText } from '@/lib/export/cells'
import { useTranslations } from '@/lib/i18n/client'
import { Refusal } from '@/app/components/ui/refusal'

export type JournalLineRow = {
    id: string
    accountCode: string
    accountName: string
    debitText: string
    creditText: string
    /** 原币那一格:与借/贷【不是同一个币种】,所以它自带前缀,见服务端注释。 */
    ccyText: string
    /**
     * TABLE-EXPORT-3b:导出读的原始值(屏幕仍画上面那几串 *Text)。
     * debit / credit:屏幕画了数的那一格才有(与 debitText / creditText 同一条判据),否则 null。
     * fxCurrency:原币不是本位币时的那个币种,否则 null;fxAmount:原币金额(受限时 null)。
     */
    debit: number | null
    credit: number | null
    fxCurrency: string | null
    fxAmount: number | null
    memo: string
    /** 合计行。见抬头。 */
    isTotal?: boolean
    /**
     * ★ U1-A(Tim 的 UNBLOCK-1 Q1 · Q3,2026-10-05):工资分录的金额对不持 data.view_pay 的人是【受限】——
     *   那一格印「受限」(<Refusal>),不印空白(像没填),更不印 0.00(撒谎)。行、科目与行摘要照常在。
     *   哪一格受限由 journal_lines_masked 的 side 定(借或贷);合计行在本张分录有任何一行受限时两格都受限。
     */
    debitRestricted?: boolean
    creditRestricted?: boolean
}

// ★ TABLE-EXPORT-3b:一对导出。合计行在 rows 里排最后,照屏幕导出(Tim 2026-10-25 Q1);受限的格(行与合计)写 "Restricted"。
export default function JournalLinesTable({ rows, baseCurrency, entryCode }: { rows: readonly JournalLineRow[]; baseCurrency: string; entryCode: string }) {
    const t = useTranslations()

    const columns: ExportableColumn<JournalLineRow>[] = [
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
                        <span className="mr-2 text-sm">{r.accountCode}</span>
                        {r.accountName}
                    </>
                ),
            // 科目号与科目名同在一格 —— 导出写屏幕上的那串字;合计行只有「合计」那个标签
            exportAs: (r) => xText(r.isTotal ? r.accountName : `${r.accountCode} ${r.accountName}`),
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
            className: 'text-sm',
            render: (r) => (r.debitRestricted ? <Refusal>{t('common.restricted')}</Refusal> : r.debitText),
            exportAs: (r) => (r.debitRestricted ? xRestricted : xMoney(r.debit, baseCurrency)),
        },
        {
            key: 'credit',
            header: t('finance.credit'),
            align: 'right',
            priority: true,
            className: 'text-sm',
            render: (r) => (r.creditRestricted ? <Refusal>{t('common.restricted')}</Refusal> : r.creditText),
            exportAs: (r) => (r.creditRestricted ? xRestricted : xMoney(r.credit, baseCurrency)),
        },
        {
            key: 'ccy',
            header: t('finance.colOriginalCcy'),
            render: (r) => r.ccyText,
            // 屏幕这一格是「USD 1,234.00 @ 1.35」—— 一格一个值:导出原币金额(带币种后缀),【汇率不进文件】。
            //   原币金额受限(fxAmount 为 NULL,屏幕画「USD · 受限」)→ "Restricted";本位币行(屏幕「—」)与合计行 → 空格。
            exportAs: (r) => (r.fxCurrency === null ? xMoney(null) : r.fxAmount === null ? xRestricted : xMoney(r.fxAmount, r.fxCurrency)),
        },
        {
            key: 'memo',
            header: t('finance.lineMemo'),
            render: (r) => r.memo,
            exportAs: (r) => xText(r.memo),
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
            exportSpec={{ name: 'finance-journal-entry-lines', title: `${entryCode} — ${t('finance.detailTitle')}`, aboutExtra: [[t('finance.colCode'), entryCode]] }}
        />
    )
}
