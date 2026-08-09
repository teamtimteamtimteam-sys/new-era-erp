// app/inbound/new/page.tsx
// 服务端组件:抓取下拉框所需的物料/供应商列表 + 可收货的采购单行(cut 4c),
// 再渲染客户端表单。?po= 预选采购单(采购单详情"按此单收货"入口)。
import { createClient } from '@/lib/supabase/server'
import NewInboundForm, { type PoLineOption } from './NewInboundForm'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function NewInboundPage({
    searchParams,
}: {
    searchParams: Promise<{ po?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.inbound)
    if (denied) return denied

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
            materials={mustRows(materialsRes)}
            suppliers={mustRows(suppliersRes)}
            poLines={(mustRows(poLinesRes)) as PoLineOption[]}
            initialPoId={sp.po ?? ''}
        />
    )
}
