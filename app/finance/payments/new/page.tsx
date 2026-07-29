// app/finance/payments/new/page.tsx
// 收付款登记页(服务端壳):取客户/供应商(在册)+ 两侧全部未结单据,
// ?direction= 定初始方向,表单交给客户端组件。
// NOTE: 未结单据两侧全量下发、客户端按往来单位过滤 —— 免选择后的往返;
// 数据量小(未结清才进视图),体量上来再改按需加载。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import NewPaymentForm, { type PartyOption, type OpenItem } from './NewPaymentForm'

// 视图列生成类型全可空;行进视图即非空,取用列本地锁死
type ArItem = {
    sales_record_id: string
    customer_id: string | null
    doc_code: string
    sale_date: string
    open_usd: number
}
type ApItem = {
    inbound_batch_id: string
    supplier_id: string | null
    doc_code: string
    doc_date: string
    open_usd: number
}

export default async function NewPaymentPage({
    searchParams,
}: {
    searchParams: Promise<{ direction?: string }>
}) {
    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    const initialDirection = sp.direction === 'out' ? 'out' : 'in'

    const [customersRes, suppliersRes, arRes, apRes] = await Promise.all([
        supabase
            .from('customers')
            .select('id, legal_name')
            .is('deleted_at', null)
            .order('legal_name'),
        supabase
            .from('suppliers')
            .select('id, legal_name')
            .is('deleted_at', null)
            .order('legal_name'),
        supabase
            .from('ar_open_items')
            .select('sales_record_id, customer_id, doc_code, sale_date, open_usd')
            .order('sale_date', { ascending: true }),
        supabase
            .from('ap_open_items')
            .select('inbound_batch_id, supplier_id, doc_code, doc_date, open_usd')
            .order('doc_date', { ascending: true }),
    ])

    const error = customersRes.error ?? suppliersRes.error ?? arRes.error ?? apRes.error
    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('finance.newPaymentTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const customers: PartyOption[] = (customersRes.data ?? []).map((c) => ({
        id: c.id,
        name: c.legal_name,
    }))
    const suppliers: PartyOption[] = (suppliersRes.data ?? []).map((s) => ({
        id: s.id,
        name: s.legal_name,
    }))
    const arItems: OpenItem[] = ((arRes.data as unknown as ArItem[] | null) ?? []).map((r) => ({
        doc_id: r.sales_record_id,
        party_id: r.customer_id ?? '',
        doc_code: r.doc_code,
        doc_date: r.sale_date,
        open_usd: r.open_usd,
    }))
    const apItems: OpenItem[] = ((apRes.data as unknown as ApItem[] | null) ?? []).map((r) => ({
        doc_id: r.inbound_batch_id,
        party_id: r.supplier_id ?? '',
        doc_code: r.doc_code,
        doc_date: r.doc_date,
        open_usd: r.open_usd,
    }))

    return (
        <div className="p-8 max-w-5xl">
            <h1 className="text-2xl font-bold mb-4">{t('finance.newPaymentTitle')}</h1>
            <Subnav />
            <NewPaymentForm
                customers={customers}
                suppliers={suppliers}
                arItems={arItems}
                apItems={apItems}
                initialDirection={initialDirection}
            />
        </div>
    )
}
