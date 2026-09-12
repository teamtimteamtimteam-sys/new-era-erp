'use client'

// app/sales/customers/[id]/OpenItemsTable.tsx
// ★ TABLE-CONVERT-3(2026-09-10):从 page.tsx 里搬出来的未结清单。
//
// 【为什么必须是新文件】page.tsx 是 server component,而列描述符带
//   `render: (row) => ReactNode` —— 函数跨不过 server→client 的边界,
//   留在原地【编译不过】。与 TABLE-CONVERT-1 / 2 撞到的是同一条,处置也照抄:
//   金额在服务端 formatAmount 过再过界,过来的只有字符串。
//
// 【这张表【没有】列选判断要搬】转换之前一个 hidden sm:table-cell 都没有,
//   四列在 390px 上全部看得见 —— 所以四列全部 priority,那是把今天的样子
//   原样说了一遍,不是新做了一次判断。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type OpenItemRow = {
    salesRecordId: string
    docCode: string
    saleDate: string
    /** 已在服务端按本位币格式化。 */
    openBase: string
    daysOutstanding: number
}

export default function OpenItemsTable({
    rows, baseCurrency, empty,
}: { rows: OpenItemRow[]; baseCurrency: string; empty: React.ReactNode }) {
    const t = useTranslations()

    const columns: Column<OpenItemRow>[] = [
        {
            key: 'doc', header: t('customers.status.colDoc'), priority: true,
            render: (it) => (
                <Link
                    href={`/finance/receivables/${it.salesRecordId}`}
                    className="hover:underline app-link"
                >
                    {it.docCode}
                </Link>
            ),
        },
        { key: 'date', header: t('customers.status.colDate'), priority: true, render: (it) => it.saleDate },
        {
            key: 'open', header: t('customers.status.colOpen', { ccy: baseCurrency }), align: 'right',
            priority: true, render: (it) => it.openBase,
        },
        {
            key: 'days', header: t('customers.status.colDays'), align: 'right', priority: true, render: (it) => it.daysOutstanding,
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(it) => it.salesRecordId}
            phone={{ mode: 'columns' }}
            empty={empty}
        />
    )
}
