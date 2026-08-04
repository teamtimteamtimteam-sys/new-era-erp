// app/finance/payments/new/page.tsx
// 收付款登记页(服务端壳):取客户/供应商(在册)+ 两侧全部未结单据 + 可预付的
// 采购单(cut 4b:定金在货物存在之前就要付,那一刻没有任何 AP 单据可核销 ——
// 指向采购单的核销行就是预付款,分录走 1300 而不是 2000,拆账在 record_payment 内)。
// ?direction= 定初始方向,?supplier= 预选供应商(采购单详情"登记付款"入口带过来),
// 表单交给客户端组件。
// NOTE: 未结单据两侧全量下发、客户端按往来单位过滤 —— 免选择后的往返;
// 数据量小(未结清才进视图),体量上来再改按需加载。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import NewPaymentForm, { type PartyOption, type OpenItem, type PoItem } from './NewPaymentForm'
import { mustRows } from '@/lib/db-helpers'

// 视图列生成类型全可空;行进视图即非空,取用列本地锁死
type ArItem = {
    sales_record_id: string
    customer_id: string | null
    doc_code: string
    sale_date: string
    open_ccy: number
}
type ApItem = {
    doc_kind: 'inbound' | 'expense'
    doc_id: string
    supplier_id: string | null
    doc_code: string
    doc_date: string
    open_ccy: number
}

export default async function NewPaymentPage({
    searchParams,
}: {
    searchParams: Promise<{ direction?: string; supplier?: string }>
}) {
    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    const initialDirection = sp.direction === 'out' ? 'out' : 'in'
    // 预选供应商只对付款方向有意义
    const initialPartyId = initialDirection === 'out' ? (sp.supplier ?? '') : ''

    const [customersRes, suppliersRes, arRes, apRes, poRes] = await Promise.all([
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
            .select('sales_record_id, customer_id, doc_code, sale_date, open_ccy')
            .order('sale_date', { ascending: true }),
        supabase
            .from('ap_open_items')
            .select('doc_kind, doc_id, supplier_id, doc_code, doc_date, open_ccy')
            .order('doc_date', { ascending: true }),
        // 可预付的采购单:视图本身排除已取消,这里再排除已结束的
        supabase
            .from('purchase_order_status')
            .select('po_id, supplier_id, code, order_date, estimated_total_usd, prepaid_base')
            .neq('status', 'closed')
            .order('order_date', { ascending: true }),
    ])

    const error = customersRes.error ?? suppliersRes.error ?? arRes.error ?? apRes.error ?? poRes.error
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

    const customers: PartyOption[] = (mustRows(customersRes)).map((c) => ({
        id: c.id,
        name: c.legal_name,
    }))
    const suppliers: PartyOption[] = (mustRows(suppliersRes)).map((s) => ({
        id: s.id,
        name: s.legal_name,
    }))
    const arItems: OpenItem[] = ((arRes.data as unknown as ArItem[] | null) ?? []).map((r) => ({
        doc_id: r.sales_record_id,
        doc_kind: 'sale' as const,
        party_id: r.customer_id ?? '',
        doc_code: r.doc_code,
        doc_date: r.sale_date,
        open_ccy: r.open_ccy,
    }))
    const apItems: OpenItem[] = ((apRes.data as unknown as ApItem[] | null) ?? []).map((r) => ({
        doc_id: r.doc_id,
        doc_kind: r.doc_kind,
        party_id: r.supplier_id ?? '',
        doc_code: r.doc_code,
        doc_date: r.doc_date,
        open_ccy: r.open_ccy,
    }))
    const poItems: PoItem[] = ((poRes.data as unknown as {
        po_id: string
        supplier_id: string | null
        code: string
        order_date: string
        estimated_total_usd: number
        prepaid_base: number
    }[] | null) ?? []).map((r) => ({
        po_id: r.po_id,
        party_id: r.supplier_id ?? '',
        code: r.code,
        order_date: r.order_date,
        estimated_total_usd: r.estimated_total_usd,
        prepaid_base: r.prepaid_base,
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
                poItems={poItems}
                initialDirection={initialDirection}
                initialPartyId={initialPartyId}
            />
        </div>
    )
}
