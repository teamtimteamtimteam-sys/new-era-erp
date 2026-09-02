// app/inbound/[id]/assays/new/page.tsx
// 录入化验结果(服务端壳)。化验单自带实验室/证书/样品编号和一整张金属表,通常是
// 照着实验室 PDF 敲进来的 —— 值得一个专属页面,而不是批次页上的一块面板。
//
// 取:批次(物料/供应商/数量/当前单价/定价状态)、批次当前已录含量(作为录入起点 ——
// 一次更正是小改而不是重敲)、以及【会生效的那张定价公式】(批次上的,否则采购单
// 明细行上的 —— 与 apply_assay_result 的解析顺序一致),好让表单能说清楚"按哪张公式重算"。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import AssayForm from './AssayForm'
import { getBaseCurrency } from '@/lib/currency'
import { maskedExcept } from '@/lib/maskedRows'
import type { Tables } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { loadSubstances, toOptions } from '@/app/pricing/metal-prices/substanceQuery'
import { getLocale } from '@/lib/i18n/server'
import { loadLaboratories, toDictOptions } from '@/app/components/dictionaries/dictionaryQuery'

export default async function NewAssayPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.inbound)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    // PROC-4:物质清单从 substances 那张字典读(清单与顺序都由它定)。
    const substanceOptions = toOptions(await loadSubstances(supabase))
    // PROC-5:实验室字典
    const labOptions = toDictOptions(await loadLaboratories(supabase), await getLocale())
    const t = await getTranslations()
    // ASY-3:本位币来自数据(currencies.is_base),不是常量 —— 影响块要说出
    // 自己是哪种货币,而面板上半截是行情口径的 USD。
    const baseCurrency = await getBaseCurrency()

    const { data: batchRaw, error } = await supabase
        .from('inbound_batches_masked')
        .select('id, code, quantity, unit, remaining_qty, unit_price, pricing_status, pricing_formula_id, purchase_order_line_id, material_id, supplier_id')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    if (error || !batchRaw) {
        notFound()
    }

    // 遮蔽的只有 unit_price;其余列恢复基表类型。
    const batch = maskedExcept<Tables<'inbound_batches'>, 'unit_price'>(batchRaw)

    const [materialRes, supplierRes, metalsRes, lineRes] = await Promise.all([
        supabase.from('materials').select('name').eq('id', batch.material_id).single(),
        supabase.from('suppliers').select('legal_name').eq('id', batch.supplier_id).single(),
        supabase
            .from('inbound_batch_metals')
            .select('metal, content_pct')
            .eq('inbound_batch_id', id),
        batch.purchase_order_line_id
            ? supabase
                  .from('purchase_order_lines')
                  .select('pricing_formula_id')
                  .eq('id', batch.purchase_order_line_id)
                  .single()
            : Promise.resolve({ data: null, error: null }),
    ])

    // 公式解析顺序与 apply_assay_result 一致:批次 → 采购单明细行
    const formulaId = batch.pricing_formula_id ?? lineRes.data?.pricing_formula_id ?? null
    const { data: formula } = formulaId
        ? await supabase.from('pricing_formulas').select('id, code, name').eq('id', formulaId).single()
        : { data: null }

    // 起点含量:批次当前已录的化验值
    const currentMetals: Record<string, string> = {}
    for (const m of mustRows(metalsRes)) {
        currentMetals[m.metal] = String(m.content_pct)
    }

    return (
        <div className="p-4 sm:p-8 max-w-5xl">
            <div className="mb-6">
                <Link href={`/inbound/${id}/edit`} className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-2">{t('assay.newTitle')}</h1>
            <p className="text-sm text-gray-600 mb-6">
                <span className="font-mono">{batch.code}</span>
                <span className="mx-2">·</span>
                {materialRes.data?.name ?? '—'}
                <span className="mx-2">·</span>
                {supplierRes.data?.legal_name ?? '—'}
                <span className="mx-2">·</span>
                <span className="font-mono">
                    {batch.quantity} {batch.unit}
                </span>
            </p>

            <AssayForm
                labOptions={labOptions}
                substanceOptions={substanceOptions}
                batch={{
                    id: batch.id,
                    code: batch.code,
                    quantity: batch.quantity,
                    unit: batch.unit,
                    unit_price: batch.unit_price,
                    pricing_status: batch.pricing_status,
                }}
                formula={formula ? { id: formula.id, code: formula.code, name: formula.name } : null}
                baseCurrency={baseCurrency}
                currentMetals={currentMetals}
            />
        </div>
    )
}
