'use client'

// app/finance/close/YearCloseHistoryTable.tsx
// CONV-4 · 年结历史那张表(只读、无行内控件 —— 与它挂在同一页的月结历史表不同,
// 月结历史表因 ReopenForm 的行内表单不属于这一套模板的人口,见 page.tsx 顶注)。

import { useTranslations } from '@/lib/i18n/client'
import { formatAmount } from '@/lib/format'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xMoney, xDate } from '@/lib/export/cells'

export type YearCloseRow = {
    id: string
    yearEnd: string
    netResult: number
    baseCurrency: string
    reopened: boolean
    reopenReason: string | null
    /** TABLE-EXPORT-2a:年末的原始日历日(导出是真日期) */
    yearEndRaw: string
}

export default function YearCloseHistoryTable({ rows }: { rows: YearCloseRow[] }) {
    const t = useTranslations()

    // ★ 手机上留【年末】与【状态】—— 年末是身份,状态是这张表存在的理由。
    const columns: ExportableColumn<YearCloseRow>[] = [
        { key: 'yearEnd', header: t('finance.yearClose.colYearEnd'), priority: true, className: 'text-sm', render: (r) => r.yearEnd, exportAs: (r) => xDate(r.yearEndRaw) },
        {
            key: 'netResult', header: t('finance.yearClose.netResult'), align: 'right', className: 'text-sm',
            render: (r) => formatAmount(r.netResult, r.baseCurrency),
            exportAs: (r) => xMoney(r.netResult, r.baseCurrency),
        },
        {
            key: 'status', header: t('finance.colStatus'), priority: true, className: 'text-sm',
            exportAs: (r) => xText(r.reopened
                ? t('finance.yearClose.reopened') + (r.reopenReason ? ' — ' + r.reopenReason : '')
                : t('finance.yearClose.closed')),
            render: (r) => (r.reopened
                ? t('finance.yearClose.reopened') + (r.reopenReason ? ' — ' + r.reopenReason : '')
                : t('finance.yearClose.closed')),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            // ★ CONV-4:已重开的年结整行发灰(转换前 <tr className="text-gray-400">)
            //   —— rowClassName 的又一处调用点。
            rowClassName={(r) => (r.reopened ? 'text-gray-400' : undefined)}
            exportSpec={{ name: 'year-closes', title: t('finance.yearClose.title') }}
            // TABLE-FEATURES-1 Q9:年结记录一次读全(year_closes 不翻页)—— 在浏览器里排
            sorting={{ mode: 'client', coverage: 'complete' }}
        />
    )
}
