// SO-4b:报价列表。
//
// 【读 quote_status,不读 quotes】过期是【算出来的】——
// quote_is_expired(valid_until),而那个函数正是 convert_quote 的拒绝读的同一个。
// 在这里自己写一句 valid_until < today,就是给同一个判断留下第二份实现:
// 屏幕上说"还有效"而服务端拒绝转换,或者反过来。CMP-1 的证书过期就是被写了
// 两遍的那一对(它自己的注释写着"改一边要改两边"),这里不重演。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { quoteStatusKey } from './quoteTypes'

type Row = {
    quote_id: string; code: string; customer_code: string; customer_name: string
    quote_date: string; valid_until: string; currency: string; status: string
    expired: boolean; converted_order_id: string | null; converted_order_code: string | null
    issue_version: number | null
}

export default async function QuotesPage() {
    const denied = await requireModule(MOD.sales)
    if (denied) return denied
    const t = await getTranslations()
    const locale = await getLocale()
    const dl = locale === 'zh' ? 'zh-CN' : 'en-US'
    const supabase = await createClient()

    const rows = mustRows(
        await supabase.from('quote_status')
            .select('quote_id, code, customer_code, customer_name, quote_date, valid_until, currency, status, expired, converted_order_id, converted_order_code, issue_version')
            .order('quote_date', { ascending: false })
            .limit(200),
        'quote_status') as unknown as Row[]

    return (
        <>
            <div className="p-8">
                <div className="flex items-center justify-between mb-2">
                    <h1 className="text-2xl font-bold">{t('quotes.listTitle')}</h1>
                    <Link href="/sales/quotes/new"
                          className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700">
                        {t('quotes.newQuote')}
                    </Link>
                </div>
                <p className="text-sm text-gray-600 mb-6 max-w-3xl">{t('quotes.listNote')}</p>

                {rows.length === 0 ? (
                    <p className="text-gray-500">{t('quotes.empty')}</p>
                ) : (
                    <table className="w-full border-collapse border border-gray-300 text-sm">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('quotes.colCode')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('sales.colCustomer')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('quotes.colQuoteDate')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('quotes.colValidUntil')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('sales.colStatus')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('sales.colCurrency')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('quotes.colOrder')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {rows.map((r) => (
                                <tr key={r.quote_id}>
                                    <td className="border border-gray-300 px-3 py-2 font-mono">
                                        <Link href={`/sales/quotes/${r.quote_id}`}
                                              className="text-blue-600 hover:underline">{r.code}</Link>
                                        {r.issue_version !== null && (
                                            <span className="ml-2 text-xs text-gray-500">
                                                v{r.issue_version}
                                            </span>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        {r.customer_code} — {r.customer_name}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        {new Date(r.quote_date).toLocaleDateString(dl)}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        {new Date(r.valid_until).toLocaleDateString(dl)}
                                        {/* 【过期是派生的,不是一个存下来的状态】琥珀色徽章 ——
                                            与 status 那一列【并列】而不是替代它:存的那个说
                                            "人做了什么",这个说"日历走到哪了"。 */}
                                        {r.expired && (
                                            <span className="ml-2 px-1.5 py-0.5 rounded text-xs bg-amber-100 text-amber-800">
                                                {t('quotes.expired')}
                                            </span>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        {/* 【静态映射,不拼动态键】quoteStatusKey 是那一份唯一的表 */}
                                        {t(quoteStatusKey(r.status))}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">{r.currency}</td>
                                    <td className="border border-gray-300 px-3 py-2 font-mono">
                                        {r.converted_order_id ? (
                                            <Link href={`/sales/orders/${r.converted_order_id}`}
                                                  className="text-blue-600 hover:underline">
                                                {r.converted_order_code}
                                            </Link>
                                        ) : (
                                            <span className="text-gray-400">—</span>
                                        )}
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                )}
            </div>
        </>
    )
}
