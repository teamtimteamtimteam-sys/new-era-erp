// SO-1:销售订单列表。
// 【入口与权限】本页守 MOD.finance —— module.sales.* 线上不存在(见
// salesOrderTypes.ts 抬头)。入口挂在财务子导航上,与该子导航其余各项同一对码,
// 这是 RPT-1 那条子导航规矩的前提;若将来订单改挂别的权限码,那个前提当场失效。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { soStatusKey } from './salesOrderTypes'

type Row = {
    id: string; code: string; order_date: string; status: string
    currency: string; customers: { code: string; legal_name: string } | null
}

export default async function SalesOrdersPage() {
    const denied = await requireModule(MOD.sales)
    if (denied) return denied
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const rows = mustRows(
        await supabase
            .from('sales_orders')
            .select('id, code, order_date, status, currency, customers ( code, legal_name )')
            .is('deleted_at', null)
            .order('order_date', { ascending: false })
            .limit(200),
        'sales_orders'
    ) as unknown as Row[]

    return (
        <>
            <div className="p-8">
                <div className="flex items-center justify-between mb-6">
                    <h1 className="text-2xl font-bold">{t('sales.listTitle')}</h1>
                    <Link href="/sales/orders/new"
                          className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700">
                        {t('sales.newOrder')}
                    </Link>
                </div>
                {rows.length === 0 ? (
                    <p className="text-gray-500">{t('sales.empty')}</p>
                ) : (
                    <table className="w-full border-collapse border border-gray-300 text-sm">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('sales.colCode')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('sales.colCustomer')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('sales.colDate')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('sales.colStatus')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('sales.colCurrency')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {rows.map((r) => (
                                <tr key={r.id}>
                                    <td className="border border-gray-300 px-3 py-2">
                                        <Link href={`/sales/orders/${r.id}`}
                                              className="text-blue-600 hover:underline font-mono text-xs">{r.code}</Link>
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        {r.customers ? `${r.customers.code} — ${r.customers.legal_name}` : '—'}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        {new Date(r.order_date).toLocaleDateString(locale === 'zh' ? 'zh-CN' : 'en-US')}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">{t(soStatusKey(r.status))}</td>
                                    <td className="border border-gray-300 px-3 py-2">{r.currency}</td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                )}
            </div>
        </>
    )
}
