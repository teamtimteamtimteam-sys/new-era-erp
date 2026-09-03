'use client'

// app/sales/quotes/QuotesTable.tsx
// CONV-1 · 报价列表那张表。形状与 CommissionsTable 逐字相同(服务端取数 / 客户端列),
// 理由见那个文件的抬头:列描述符里有函数,函数过不了 RSC 边界。
import Link from 'next/link'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { quoteStatusKey } from './quoteTypes'

export type QuoteRow = {
    quote_id: string; code: string; customer_code: string; customer_name: string
    quote_date: string; valid_until: string; currency: string; status: string
    expired: boolean; converted_order_id: string | null; converted_order_code: string | null
    issue_version: number | null
}

export default function QuotesTable({ rows }: { rows: QuoteRow[] }) {
    const t = useTranslations()
    const locale = useLocale()
    const dl = locale === 'zh' ? 'zh-CN' : 'en-US'

    // ★【手机上留哪两列】★ 7 列里留【报价号】与【有效期至】:
    //   · 报价号是身份,而且是人嘴里说的那个东西(「Q-2026-0031 那张」);
    //   · 有效期至是【这一页存在的理由】—— 报价的全部张力是"它还作不作数",
    //     而这一格也是唯一会亮警示的那一格(过期琥珀片挂在它上面)。
    //   客户、报价日、状态、币种、转成的订单都是【看到那一行之后才问的】,进展开区。
    //   【没有留客户】是一次有代价的选择:手机上按客户找报价要多点一下。
    //   取舍的理由是"过期"必须一眼看见 —— 一张过了期而看起来正常的报价会被拿去报价。
    const columns: Column<QuoteRow>[] = [
        {
            key: 'code', header: t('quotes.colCode'), priority: true, className: 'font-mono',
            render: (r) => (
                <>
                    <Link href={`/sales/quotes/${r.quote_id}`} className="text-blue-600 hover:underline">{r.code}</Link>
                    {r.issue_version !== null && <span className="ml-2 text-xs text-gray-500">v{r.issue_version}</span>}
                </>
            ),
        },
        {
            key: 'customer', header: t('sales.colCustomer'),
            render: (r) => `${r.customer_code} — ${r.customer_name}`,
        },
        {
            key: 'quoteDate', header: t('quotes.colQuoteDate'),
            render: (r) => new Date(r.quote_date).toLocaleDateString(dl),
        },
        {
            key: 'validUntil', header: t('quotes.colValidUntil'), priority: true,
            render: (r) => (
                <>
                    {new Date(r.valid_until).toLocaleDateString(dl)}
                    {/* 【过期是派生的,不是一个存下来的状态】—— 与 status 那一列【并列】
                        而不是替代它:存的那个说"人做了什么",这个说"日历走到哪了"。
                        (原页面这一段一个字没改。) */}
                    {r.expired && (
                        <span className="ml-2 px-1.5 py-0.5 rounded text-xs bg-amber-100 text-amber-800">
                            {t('quotes.expired')}
                        </span>
                    )}
                </>
            ),
        },
        {
            key: 'status', header: t('sales.colStatus'),
            // 【静态映射,不拼动态键】quoteStatusKey 是那一份唯一的表
            render: (r) => t(quoteStatusKey(r.status)),
        },
        { key: 'currency', header: t('sales.colCurrency'), render: (r) => r.currency },
        {
            key: 'order', header: t('quotes.colOrder'), className: 'font-mono',
            render: (r) =>
                r.converted_order_id ? (
                    <Link href={`/sales/orders/${r.converted_order_id}`} className="text-blue-600 hover:underline">
                        {r.converted_order_code}
                    </Link>
                ) : (
                    <span className="text-gray-400">—</span>
                ),
        },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.quote_id} phone={{ mode: 'columns' }} />
}
