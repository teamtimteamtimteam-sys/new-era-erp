'use client'

// app/logistics/forwarders/ForwardersTable.tsx
// CONV-5 · 货代名单那张表。
// 【这一页与供应商页故意不共用任何东西】—— 所以这张表也是它自己的,
// 不是 SuppliersTable 的一个变体。理由见 page.tsx 抬头。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { Refusal } from '@/app/components/ui/refusal'

export type ForwarderRow = {
    id: string
    legalName: string
    code: string
    mainRoutes: string
    paymentTerms: string
    /** null = 没有欠款。【零不写成 0.00】—— 没有欠款是一句话,不是一个金额。 */
    owedLabel: string | null
}

export default function ForwardersTable({
    rows,
    empty,
    /**
     * ★ FIX-2a:【两个"扣下了"的第三态】。
     * 此前这张表只有两种话可说:一个金额,或者「没有欠款」。
     * 一个没有 module.finance.view 的读者读回零行 ap_open_items,
     * 于是每一家货代都写着「没有欠款」—— 一个自信的、错的答案。
     * 「没有欠款」与「你不能看欠了多少」必须分得开,而分开它们要一个第三态。
     */
    moneyRestricted = false,
    termsRestricted = false,
}: {
    rows: ForwarderRow[]
    empty: React.ReactNode
    moneyRestricted?: boolean
    termsRestricted?: boolean
}) {
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
        {
            key: 'terms', header: t('logistics.colPaymentTerms'),
            render: (r) =>
                termsRestricted
                    ? <Refusal why={t('logistics.termsRestrictedHint')}>{t('common.restricted')}</Refusal>
                    : r.paymentTerms,
        },
        {
            key: 'owed', header: t('logistics.colBalanceOwed'), priority: true, align: 'right',
            render: (r) =>
                moneyRestricted
                    ? <Refusal why={t('logistics.owedRestrictedHint')}>{t('common.restricted')}</Refusal>
                    : r.owedLabel ?? <span className="text-gray-500">{t('logistics.noBalance')}</span>,
        },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty} />
}
