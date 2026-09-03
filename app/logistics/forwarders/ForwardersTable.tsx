'use client'

// app/logistics/forwarders/ForwardersTable.tsx
// CONV-5 · 货代名单那张表。
// 【这一页与供应商页故意不共用任何东西】—— 所以这张表也是它自己的,
// 不是 SuppliersTable 的一个变体。理由见 page.tsx 抬头。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type ForwarderRow = {
    id: string
    legalName: string
    code: string
    mainRoutes: string
    paymentTerms: string
    /** null = 没有欠款。【零不写成 0.00】—— 没有欠款是一句话,不是一个金额。 */
    owedLabel: string | null
}

export default function ForwardersTable({ rows, empty }: { rows: ForwarderRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【货代】与【未结应付】—— 名字是身份,而未结应付是这份名单
    //   与供应商名单共用同一张 ap_open_items 视图的全部意义。
    const columns: Column<ForwarderRow>[] = [
        {
            key: 'name', header: t('logistics.colName'), priority: true,
            render: (r) => (
                <Link href={`/logistics/forwarders/${r.id}`} className="text-blue-700 hover:underline">
                    {r.legalName}
                </Link>
            ),
        },
        { key: 'code', header: t('logistics.colCode'), className: 'font-mono text-xs', render: (r) => r.code },
        { key: 'routes', header: t('logistics.colMainRoutes'), render: (r) => r.mainRoutes },
        { key: 'terms', header: t('logistics.colPaymentTerms'), render: (r) => r.paymentTerms },
        {
            key: 'owed', header: t('logistics.colBalanceOwed'), priority: true, align: 'right',
            render: (r) =>
                r.owedLabel ?? <span className="text-gray-500">{t('logistics.noBalance')}</span>,
        },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty} />
}
