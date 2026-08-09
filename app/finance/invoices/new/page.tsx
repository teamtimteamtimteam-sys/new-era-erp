// app/finance/invoices/new/page.tsx
// 开票页(服务端壳)。
// 待开票销售【不能只看 ar_open_items】—— 那张视图只含未结清的开放项,已收讫但从未
// 开过票的销售会被漏掉。所以直接查 sales_records,用 NOT EXISTS 排除已挂在册发票的,
// 并联出批次/物料做行摘要。customer_id 为空的销售一并带出(批次可能在客户登记之前
// 就卖了),前端标注为"未记录客户",可以开给所选客户。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import NewInvoiceForm, { type CustomerOption, type SaleOption } from './NewInvoiceForm'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

type SaleFetchRow = {
    id: string
    customer_id: string | null
    quantity: number
    unit_price: number
    currency: string
    amount_base: number
    sale_date: string
    output_batches: {
        code: string
        unit: string
        materials: { name: string } | null
    } | null
}

export default async function NewInvoicePage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const [customersRes, salesRes, settingsRes] = await Promise.all([
        supabase
            .from('customers')
            .select('id, legal_name, payment_terms_days')
            .is('deleted_at', null)
            .order('legal_name'),
        supabase
            .from('sales_records_masked')
            .select('id, customer_id, quantity, unit_price, currency, amount_base, sale_date, output_batches(code, unit, materials(name))')
            .order('sale_date', { ascending: false }),
        supabase.from('finance_settings').select('gst_registered, gst_rate_pct').limit(1).single(),
    ])

    const error = customersRes.error ?? salesRes.error
    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('invoice.newTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    // 已挂在册(未作废)发票上的销售 —— 这些不能再开
    // 读不到就必须炸:takenRows 是"这些销售不能再开票"的唯一依据,
    // 读成空集等于把重复开票的护栏拆掉。
    const takenRes = await supabase
        .from('invoice_lines')
        .select('sales_record_id')
        .eq('invoice_voided', false)
    const taken = new Set(mustRows(takenRes, 'invoice_lines taken').map((r) => r.sales_record_id))

    const customers: CustomerOption[] = (mustRows(customersRes)).map((c) => ({
        id: c.id,
        name: c.legal_name,
        payment_terms_days: c.payment_terms_days,
    }))

    const sales: SaleOption[] = ((salesRes.data as unknown as SaleFetchRow[] | null) ?? [])
        .filter((s) => !taken.has(s.id))
        .map((s) => ({
            sales_record_id: s.id,
            customer_id: s.customer_id,
            batch_code: s.output_batches?.code ?? '—',
            material_name: s.output_batches?.materials?.name ?? null,
            sale_date: s.sale_date,
            quantity: s.quantity,
            unit: s.output_batches?.unit ?? 'kg',
            unit_price: s.unit_price,
            currency: s.currency,
            amount_base: s.amount_base,
        }))

    return (
        <div className="p-8 max-w-6xl">
            <h1 className="text-2xl font-bold mb-4">{t('invoice.newTitle')}</h1>
            <Subnav />
            <NewInvoiceForm
                customers={customers}
                sales={sales}
                gstRegistered={settingsRes.data?.gst_registered ?? false}
                gstRatePct={Number(settingsRes.data?.gst_rate_pct ?? 0)}
            />
        </div>
    )
}
