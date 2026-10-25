'use client'

// app/sales/commissions/CommissionsTable.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-1 · 佣金登记簿的那张表。
//
// ★★【为什么这里【必须】多出一个文件 —— 这是本刀量出来的、模板的真实形状】★★
// `Column.render` 与 `sortValue` 都是【函数】,而 DataTable 是 'use client'。
// React Server Component 【不能把函数当 prop 传过客户端边界】。
// 所以列描述符没有办法住在服务端的 page.tsx 里 —— 它必须住在一个客户端模块里。
//
// 【于是每一页的形状是固定的两半,而这一点后面六刀都逃不掉】
//   page.tsx（服务端）—— 守卫、取数、算好【纯数据】的行,交给下面这个组件;
//   XxxTable.tsx（客户端）—— 列描述符 + <DataTable>。文案走 i18n 的 client 版。
// **也就是说转换一页 = 改一个文件 + 新建一个文件**,不是"把 <table> 换成 <DataTable>"。
// PAGE-0 §⑤ 把代价记成「960 个列描述符」,那一栏是对的;
// 它没有记的是【129 个新文件】。见 docs/list-page-template.md。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatAmount } from '@/lib/format'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xNum, xMoney } from '@/lib/export/cells'

/** 服务端传下来的【纯数据】—— 一个函数都没有,所以过得了边界。 */
export type CommissionRow = {
    id: string
    side: string
    basis: string
    rate_pct: number | null
    amount_ccy: number | null
    currency: string | null
    recognition_trigger: string
    valid_from: string
    valid_to: string
    /** TABLE-EXPORT-1:有效期两端的原始 `YYYY-MM-DD`(valid_from / valid_to 是屏幕上格式化过的那串)。 */
    validFromRaw: string
    validToRaw: string
    remarks: string | null
    agentCode: string | null
    agentName: string | null
}

export default function CommissionsTable({ rows }: { rows: CommissionRow[] }) {
    const t = useTranslations()

    // ★【手机上留哪两列 —— 这张表自己的判断,写在这里而不是提交信息里】★
    //   7 列里留【代理商】与【费率】:
    //   · 代理商是身份 —— 没有它,底下那一行是谁都不知道;
    //   · 费率是这张登记簿存在的理由 —— 人来这一页就是查"这家收多少"。
    //   方向(买/卖)、基准、触发点、有效期、备注都是【读到那一行之后才要问的】,
    //   进展开区。
    const columns: ExportableColumn<CommissionRow>[] = [
        {
            key: 'agent', header: t('commissions.colAgent'), priority: true,
            exportAs: (r) => xText(r.agentCode === null ? null : r.agentCode + (r.agentName ? ` · ${r.agentName}` : '')),
            render: (r) => (
                <>
                    <Link href={`/sales/commissions/${r.id}/edit`} className="hover:underline app-link">
                        {r.agentCode}
                    </Link>
                    {r.agentName ? ` · ${r.agentName}` : null}
                </>
            ),
        },
        { key: 'side', header: t('commissions.colSide'), render: (r) => t('commissions.side.' + r.side),
          exportAs: (r) => xText(t('commissions.side.' + r.side)) },
        { key: 'basis', header: t('commissions.colBasis'), render: (r) => t('commissions.basis.' + r.basis),
          exportAs: (r) => xText(t('commissions.basis.' + r.basis)) },
        {
            key: 'rate', header: t('commissions.colRate'), priority: true, align: 'right',
            // TABLE-FEATURES-1(Tim 2026-10-25 Q9):一格是费率(%)【或】一笔各自币种的金额 —— 放在一起比没有意义,不可排
            sortable: false,
            // TABLE-EXPORT-1:这一格是「费率 或 金额」二选一,与屏幕同一个判断 —— 费率写成百分数(屏幕上的那个数),
            //   金额写成钱,币种跟着金额走(Excel 里进数字格式,CSV 里跟在数后面)—— 与屏幕同。
            exportAs: (r) =>
                r.rate_pct !== null
                    ? xNum(r.rate_pct, 'pct')
                    : r.amount_ccy !== null && r.currency
                      ? xMoney(r.amount_ccy, r.currency)
                      : xText(null),
            render: (r) =>
                r.rate_pct !== null
                    ? `${r.rate_pct}%`
                    : r.amount_ccy !== null && r.currency
                      ? formatAmount(Number(r.amount_ccy), r.currency)
                      : null,
        },
        { key: 'trigger', header: t('commissions.colTrigger'), render: (r) => t('commissions.trigger.' + r.recognition_trigger),
          exportAs: (r) => xText(t('commissions.trigger.' + r.recognition_trigger)) },
        // TABLE-EXPORT-1:一格装着两个日子,导出成一格就只能是文字 —— 用原始的 `YYYY-MM-DD` 拼,不用屏幕上格式化过的那串。
        { key: 'validity', header: t('commissions.colValidity'), sortValue: (r) => r.validFromRaw, render: (r) => `${r.valid_from} → ${r.valid_to}`,
          exportAs: (r) => xText(`${r.validFromRaw} → ${r.validToRaw}`) },
        { key: 'remarks', header: t('commissions.colRemarks'), render: (r) => r.remarks, exportAs: (r) => xText(r.remarks) },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            exportSpec={{ name: 'sales-commissions', title: t('commissions.title') }}
            // TABLE-FEATURES-1 Q9:登记簿一次读完 —— 在浏览器里排;有效期按起始日排
            sorting={{ mode: 'client', coverage: 'complete' }}
        />
    )
}
