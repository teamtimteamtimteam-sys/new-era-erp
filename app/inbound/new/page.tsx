// app/inbound/new/page.tsx
// 服务端组件:抓取下拉框所需的物料/供应商列表 + 可收货的采购单行(cut 4c),
// 再渲染客户端表单。?po= 预选采购单(采购单详情"按此单收货"入口)。
import { createClient } from '@/lib/supabase/server'
import NewInboundForm, { type PoLineOption } from './NewInboundForm'
import { getTranslations } from '@/lib/i18n/server'

export default async function NewInboundPage({
    searchParams,
}: {
    searchParams: Promise<{ po?: string }>
}) {
    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    const [materialsRes, suppliersRes, poLinesRes] = await Promise.all([
        supabase
            .from('materials')
            .select('id, code, name')
            .is('deleted_at', null)
            .order('name'),
        supabase
            .from('suppliers')
            .select('id, code, legal_name')
            .is('deleted_at', null)
            .order('legal_name'),
        supabase
            .from('po_receivable_lines')
            .select('po_id, po_code, supplier_id, order_date, line_id, line_no, material_id, material_name, remaining_qty, unit')
            .order('po_code')
            .order('line_no'),
    ])

    if (materialsRes.error || suppliersRes.error || poLinesRes.error) {
        const err = materialsRes.error ?? suppliersRes.error ?? poLinesRes.error
        return (
            <div className="p-8 max-w-2xl">
                <h1 className="text-2xl font-bold mb-4">{t('inbound.newTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('inbound.dropdownLoadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(err, null, 2)}</pre>
                </div>
            </div>
        )
    }

    return (
        <NewInboundForm
            materials={materialsRes.data ?? []}
            suppliers={suppliersRes.data ?? []}
            poLines={(poLinesRes.data ?? []) as PoLineOption[]}
            initialPoId={sp.po ?? ''}
        />
    )
}
