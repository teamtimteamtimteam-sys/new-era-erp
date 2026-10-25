'use client'

// app/logistics/forwarders/[id]/ForwarderFreightTable.tsx
// TABLE-EXPORT-3c(Tim 2026-10-25):货代详情页上的【运费单据】那张表 —— 从一张手搓、没有表头的
//   原生 <table> 换成 DataTable,带表头与一对导出(Tim 批准重建)。
//
// 【为什么要多这一个文件】页面是 server component,而 Column.render / exportAs 是函数,
//   函数跨不过 server→client 那道边界(与 AssayMetalsTable.tsx 抬头同一条)。
//   所以方向那一格的字在【服务端】译好(directionLabel),这里只负责画。
//
// 【手机】转换前这张表【一处 hidden sm:table-cell 都没有】,五列在 390px 上本来就都看得见
//   (外面套一层 overflow-x-auto)—— 这里五列都 priority,搬的是那个事实,不是一次新判断。
//
// 【受限】freight_document_lookup 对不持 data.view_prices 的人把金额给成 NULL;基表上这一列 NOT NULL,
//   所以这里的 NULL 只可能是「受限」(ROLE-1 Batch 4a 那条判据)。屏幕画 <Refusal>受限</Refusal>,
//   导出在【同一个条件】下写 xRestricted。金额格里写着币种(formatAmount(v, 单据币种))→ xMoney(v, currency)。
import Link from 'next/link'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { formatAmount } from '@/lib/format'
import { formatDate } from '@/lib/dates'
import { Refusal } from '@/app/components/ui/refusal'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xDate, xMoney, xRestricted, xText } from '@/lib/export/cells'

export type ForwarderFreightRow = {
    id: string
    code: string
    /** 服务端译好的方向短词(进 / 出)—— t() 不跨边界 */
    directionLabel: string
    /** 单据日的原始日历日(YYYY-MM-DD);屏幕在这里格式化,导出读它本身 */
    docDate: string | null
    /** NULL = 受限(见抬头);数值可能以字符串来(numeric) */
    amountCcy: number | string | null
    currency: string
    /** 原样画出(转换前就是原样画的,本刀不改它的字) */
    paymentStatus: string | null
}

export function ForwarderFreightTable({ rows, forwarderCode }: { rows: readonly ForwarderFreightRow[]; forwarderCode: string }) {
    const t = useTranslations()
    const locale = useLocale()
    const columns: ExportableColumn<ForwarderFreightRow>[] = [
        {
            // LOG-2b:运费凭证【有自己的页面】(app/finance/freight/[id]),所以这一格是链接 → 导出写单号
            key: 'code', header: t('finance.freight.colCode'), priority: true,
            render: (f) => (
                <Link href={`/finance/freight/${f.id}`} className="hover:underline app-link">{f.code}</Link>
            ),
            exportAs: (f) => xText(f.code),
        },
        {
            // LOG-4b:方向一个字。进货运费与出口运费在这张表上长得一模一样,而它们去的是完全不同的科目。
            key: 'direction', header: t('finance.freight.colDirection'), priority: true, singleValue: true,
            className: 'text-gray-600',
            render: (f) => f.directionLabel,
            exportAs: (f) => xText(f.directionLabel),
        },
        {
            key: 'date', header: t('finance.freight.colDate'), priority: true, singleValue: true,
            render: (f) => formatDate(f.docDate, locale),
            exportAs: (f) => xDate(f.docDate),
        },
        {
            key: 'amount', header: t('finance.freight.colAmount'), priority: true, align: 'right', singleValue: true,
            className: 'tabular-nums',
            render: (f) => f.amountCcy === null
                ? <Refusal>{t('common.restricted')}</Refusal>
                : formatAmount(Number(f.amountCcy), f.currency),
            exportAs: (f) => (f.amountCcy === null ? xRestricted : xMoney(f.amountCcy, f.currency)),
        },
        {
            key: 'payment', header: t('finance.freight.colPayment'), priority: true, singleValue: true,
            render: (f) => f.paymentStatus,
            exportAs: (f) => xText(f.paymentStatus),
        },
    ]
    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(f) => f.id}
            phone={{ mode: 'columns' }}
            exportSpec={{ name: 'logistics-forwarder-freight-documents', title: t('logistics.freightHeading'),
                          aboutExtra: [[t('logistics.colCode'), forwarderCode]] }}
        />
    )
}
