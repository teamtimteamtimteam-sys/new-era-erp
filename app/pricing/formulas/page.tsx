// app/pricing/formulas/page.tsx
// 定价公式列表:行数很少,不分页,但保留标准的记录数。已软删的不列。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { formatMoneyBare } from '@/lib/format'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

type FormulaRow = {
    id: string
    code: string
    name: string
    direction: string
    price_basis: string
    price_index: string | null
    average_days: number | null
    treatment_charge_usd_per_tonne: number
    flat_discount_pct: number
    supplier_id: string | null
    customer_id: string | null
    is_active: boolean
}

export default async function FormulasPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.pricing)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const { data, error } = await supabase
        .from('pricing_formulas_masked')
        .select('id, code, name, direction, price_basis, price_index, average_days, treatment_charge_usd_per_tonne, flat_discount_pct, supplier_id, customer_id, is_active')
        .is('deleted_at', null)
        .order('code', { ascending: false })

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('pricing.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const rows = (data as unknown as FormulaRow[] | null) ?? []

    // 往来单位名:页级两次小 .in
    const supplierIds = Array.from(new Set(rows.map((r) => r.supplier_id).filter(Boolean))) as string[]
    const customerIds = Array.from(new Set(rows.map((r) => r.customer_id).filter(Boolean))) as string[]
    const [supRes, cusRes] = await Promise.all([
        supplierIds.length
            ? // LOG-1b:【这一处绝不过滤 counterparty_type】—— 解析器,不是选择器。
              supabase.from('suppliers').select('id, legal_name').in('id', supplierIds)
            : Promise.resolve({ data: [] as { id: string; legal_name: string }[], error: null }),
        customerIds.length
            ? supabase.from('customers').select('id, legal_name').in('id', customerIds)
            : Promise.resolve({ data: [] as { id: string; legal_name: string }[], error: null }),
    ])
    const nameById = new Map<string, string>()
    for (const s of mustRows(supRes)) nameById.set(s.id, s.legal_name)
    for (const c of mustRows(cusRes)) nameById.set(c.id, c.legal_name)

    const basisLabel = (r: FormulaRow) =>
        r.price_basis === 'average'
            ? t('pricing.basis.average', { days: r.average_days ?? 0 })
            : t('pricing.basis.spot')

    return (
        <div className="p-8">
            <div className="flex justify-between items-center mb-4">
                <h1 className="text-2xl font-bold">{t('pricing.listTitle')}</h1>
                <Link
                    href="/pricing/formulas/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('pricing.new')}
                </Link>
            </div>

            <p className="text-sm text-gray-600 mb-4">{t('finance.recordCount', { count: rows.length })}</p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('pricing.colCode')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('pricing.colName')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('pricing.colDirection')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('pricing.colBasis')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('pricing.colTreatment')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('pricing.colDiscount')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('pricing.colCounterparty')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('pricing.colActive')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('metalPrices.colActions')}</th>
                    </tr>
                </thead>
                <tbody>
                    {rows.map((r) => (
                        <tr key={r.id}>
                            <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                <Link
                                    href={`/pricing/formulas/${r.id}/edit`}
                                    className="text-blue-600 hover:underline"
                                >
                                    {r.code}
                                </Link>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{r.name}</td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span className="px-2 py-1 rounded text-xs bg-gray-200 text-gray-700">
                                    {t('pricing.direction.' + r.direction)}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm">{basisLabel(r)}</td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {formatMoneyBare(r.treatment_charge_usd_per_tonne, '列头 pricing.colTreatment「加工费 (USD/吨)」')}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {r.flat_discount_pct}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm">
                                {nameById.get(r.supplier_id ?? r.customer_id ?? '') ?? (
                                    <span className="text-gray-500">{t('pricing.generic')}</span>
                                )}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span
                                    className={
                                        'px-2 py-1 rounded text-xs ' +
                                        (r.is_active
                                            ? 'bg-green-100 text-green-800'
                                            : 'bg-gray-200 text-gray-600')
                                    }
                                >
                                    {r.is_active ? t('pricing.form.active') : t('finance.inactive')}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <Link
                                    href={`/pricing/formulas/${r.id}/edit`}
                                    className="text-blue-600 hover:underline text-sm"
                                >
                                    {t('metalPrices.editAction')}
                                </Link>
                            </td>
                        </tr>
                    ))}
                    {rows.length === 0 && (
                        <tr>
                            <td colSpan={9} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('pricing.empty')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>
        </div>
    )
}
