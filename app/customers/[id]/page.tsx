// app/customers/[id]/page.tsx
// 客户【状况页】—— SAL-B6。
//
// 【为什么它存在】SAL-B 建了信用管控,却没有任何一块屏把【限额】与【敞口】放在
// 一起:限额在编辑表单上(一个可改的字段),敞口在应收页上(按客户合计,看不见
// 限额),没有一处拿两者相比。于是"这个客户越限了"这件事只有两个说法 ——
// 首页的一块牌子,和销售被拒的那一刻。走查时那块牌子指向客户【列表】,
// 而列表上一个字都不提信用。
//
// 【它是一个仓位,不是一张设置表】只读,不放任何字段;要改限额/冻结,走那条
// 明确的链接去编辑表单。这条分界正是它存在的理由:把一个活的财务仓位塞进
// 编辑表单,等于邀请读者去改那个让告警消失、却不改变事实的数字。
// (同一条判断也写进了 docs/dashboard-arm-inventory.md:编辑表单是【编辑即补救】
//  时的正确去处,不是"编辑只让信号消失"时的去处。)
//
// 【三段各有各的门,缺一段就说「受限」而不是显示 0】
//   身份 —— customers(module.customers.view)
//   信用 —— customer_credit_status(同上;敞口走有检查的外壳,见该视图注释)
//   明细 —— ar_open_items(module.finance.view)—— 【看得见限额不等于看得见账】,
//           所以这一段单独把关,无权时整段是「受限」,不是一张空表。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { getBaseCurrency } from '@/lib/currency'
import { formatAmount } from '@/lib/format'
import { can } from '@/lib/permissions'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

type CreditRow = {
    customer_id: string
    code: string
    legal_name: string
    credit_limit_base: number | null
    credit_hold: boolean
    exposure_base: number | null
    headroom_base: number | null
    sales_blocked: boolean
}

type OpenItem = {
    sales_record_id: string
    doc_code: string
    sale_date: string
    open_base: number
    days_outstanding: number
    bucket: string
}

export default async function CustomerStatusPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。
    const denied = await requireModule(MOD.customers)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const baseCurrency = await getBaseCurrency()
    const canFinance = await can('module.finance.view')

    const { data: cust, error } = await supabase
        .from('customers')
        .select('id, code, legal_name, country, status')
        .eq('id', id)
        .is('deleted_at', null)
        .single()
    if (error || !cust) notFound()

    const { data: creditRaw } = await supabase
        .from('customer_credit_status')
        .select('customer_id, code, legal_name, credit_limit_base, credit_hold, exposure_base, headroom_base, sales_blocked')
        .eq('customer_id', id)
        .maybeSingle()
    const credit = (creditRaw as CreditRow | null) ?? null

    // 明细只有持 module.finance.view 的人看得到 —— 不去查,而不是查了拿零行
    const openItems: OpenItem[] = canFinance
        ? (mustRows(
              await supabase
                  .from('ar_open_items')
                  .select('sales_record_id, doc_code, sale_date, open_base, days_outstanding, bucket')
                  .eq('customer_id', id)
                  .order('sale_date')
          ) as OpenItem[])
        : []

    const row = (label: string, value: React.ReactNode) => (
        <div className="flex justify-between py-1">
            <span className="text-gray-600">{label}</span>
            <span className="font-mono">{value}</span>
        </div>
    )

    return (
        <div className="p-8 max-w-3xl">
            <div className="mb-6">
                <Link href="/customers" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <div className="flex flex-wrap items-center justify-between gap-3 mb-4">
                <h1 className="text-2xl font-bold">
                    {cust.legal_name}
                    <span className="ml-3 font-mono text-base text-gray-500">{cust.code}</span>
                </h1>
                {/* 【改限额/冻结在别处】这一页不放字段 —— 见文件头 */}
                <Link
                    href={`/customers/${id}/edit`}
                    className="border border-gray-300 px-3 py-1.5 rounded hover:bg-gray-50 text-sm"
                >
                    {t('customers.status.editLink')}
                </Link>
            </div>

            <p className="text-sm text-gray-600 mb-6">
                {cust.country ?? '—'}
                <span className="mx-2">·</span>
                {cust.status}
            </p>

            {/* ── 信用仓位 ─────────────────────────────────────────────────── */}
            <section className="mb-8">
                <h2 className="text-lg font-semibold mb-2">{t('customers.status.creditTitle')}</h2>
                {credit === null ? (
                    // 拿不到行 = 无权。【不是 0】—— 0 读作"没有限额、余额充足"
                    <p className="text-sm text-gray-500">{t('common.restricted')}</p>
                ) : (
                    <div className="bg-gray-50 rounded p-4 text-sm max-w-md">
                        {credit.credit_hold && (
                            <p className="bg-red-100 border border-red-400 text-red-700 px-3 py-2 rounded mb-3">
                                {t('customers.status.onHold')}
                            </p>
                        )}
                        {row(
                            t('customers.status.limit'),
                            credit.credit_limit_base === null
                                ? t('customers.status.noLimit')
                                : formatAmount(credit.credit_limit_base, baseCurrency)
                        )}
                        {row(t('customers.status.exposure'), formatAmount(credit.exposure_base, baseCurrency))}
                        {credit.credit_limit_base !== null &&
                            row(
                                t('customers.status.headroom'),
                                <span className={credit.sales_blocked ? 'text-red-700 font-bold' : ''}>
                                    {formatAmount(credit.headroom_base, baseCurrency)}
                                </span>
                            )}
                        {credit.sales_blocked && !credit.credit_hold && (
                            <p className="bg-red-100 border border-red-400 text-red-700 px-3 py-2 rounded mt-3">
                                {t('customers.status.overLimit')}
                            </p>
                        )}
                    </div>
                )}
            </section>

            {/* ── 敞口由哪些单据构成 ───────────────────────────────────────── */}
            <section>
                <h2 className="text-lg font-semibold mb-2">{t('customers.status.openTitle')}</h2>
                {!canFinance ? (
                    // 看得见限额不等于看得见账 —— 整段受限,不是一张空表
                    <p className="text-sm text-gray-500">{t('common.restricted')}</p>
                ) : openItems.length === 0 ? (
                    <p className="text-sm text-gray-500">{t('customers.status.noOpenItems')}</p>
                ) : (
                    <div className="overflow-x-auto">
                        <table className="w-full border-collapse border border-gray-300 text-sm">
                            <thead className="bg-gray-100">
                                <tr>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('customers.status.colDoc')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('customers.status.colDate')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-right">{t('customers.status.colOpen', { ccy: baseCurrency })}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-right">{t('customers.status.colDays')}</th>
                                </tr>
                            </thead>
                            <tbody>
                                {openItems.map((it) => (
                                    <tr key={it.sales_record_id}>
                                        <td className="border border-gray-300 px-3 py-2">
                                            <Link
                                                href={`/finance/receivables/${it.sales_record_id}`}
                                                className="text-blue-600 hover:underline font-mono"
                                            >
                                                {it.doc_code}
                                            </Link>
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2">{it.sale_date}</td>
                                        <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                            {formatAmount(it.open_base, baseCurrency)}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                            {it.days_outstanding}
                                        </td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    </div>
                )}
            </section>
        </div>
    )
}
