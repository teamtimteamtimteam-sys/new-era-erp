// app/tools/pricing/formulas/[id]/edit/page.tsx
// 编辑定价公式(服务端壳):取公式 + 其计价比例行 + 往来单位下拉;updateFormula 绑 id。
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations , getLocale } from '@/lib/i18n/server'
import { getMetalPriceIndices } from '@/app/tools/pricing/metal-prices/indexQuery'
import FormulaForm, { type FormulaDefaults, type PartyOption, type QuoteDate } from '../../FormulaForm'
import { updateFormula } from '../../actions'
import DeleteFormulaButton from './DeleteFormulaButton'
import { unmasked } from '@/lib/maskedRows'
import type { Tables } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { loadSubstances, toOptions } from '../../../metal-prices/substanceQuery'

export default async function EditFormulaPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.pricing)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    // PROC-4:物质清单从 substances 那张字典读(清单与顺序都由它定)。
    const substanceOptions = toOptions(await loadSubstances(supabase))
    const t = await getTranslations()

    const { data: formulaRaw, error } = await supabase
        .from('pricing_formulas_masked')
        .select('id, code, name, direction, price_basis, price_index, average_days, treatment_charge_usd_per_tonne, flat_discount_pct, supplier_id, customer_id, notes, is_active')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    if (error || !formulaRaw) {
        notFound()
    }

    // cut 2b:改读遮蔽视图(基表原始敏感列已收回)。断言回基表行类型 —— 能进定价模块的
    // 角色全都持有 data.view_prices,列不会被遮蔽。见 lib/maskedRows.ts。
    const formula = unmasked<Tables<'pricing_formulas'>>(formulaRaw)

    const [metalsRes, supRes, cusRes] = await Promise.all([
        supabase.from('pricing_formula_metals_masked').select('metal, payable_pct').eq('formula_id', id),
        // LOG-1b:货代不进供应商名单
        supabase.from('supplier_lookup').select('id, legal_name').is('deleted_at', null).neq('counterparty_type', 'forwarder').order('legal_name'),
        supabase.from('customer_lookup').select('id, legal_name').is('deleted_at', null).order('legal_name'),
    ])

    const defaults: FormulaDefaults = {
        name: formula.name,
        direction: formula.direction,
        price_basis: formula.price_basis,
        price_index: formula.price_index ?? null,
        average_days: formula.average_days != null ? String(formula.average_days) : '',
        treatment_charge_usd_per_tonne: String(formula.treatment_charge_usd_per_tonne ?? ''),
        flat_discount_pct: String(formula.flat_discount_pct ?? ''),
        supplier_id: formula.supplier_id,
        customer_id: formula.customer_id,
        notes: formula.notes ?? '',
        is_active: formula.is_active,
        payables: Object.fromEntries(
            (mustRows(metalsRes)).map((m) => [m.metal, String(m.payable_pct)])
        ),
    }

    const suppliers: PartyOption[] = (mustRows(supRes) as unknown as { id: string; legal_name: string }[])
        .map((s) => ({ id: s.id, name: s.legal_name }))
    const customers: PartyOption[] = (mustRows(cusRes) as unknown as { id: string; legal_name: string }[])
        .map((c) => ({ id: c.id, name: c.legal_name }))

    // 行情覆盖(最近一年,数据量极小):供表单当场说出"这两个基准现在算不算同一个数"。
    // 读 price_date 而不是 created_at —— 补录过的行情按【行情日】算窗口内外。
    const quoteRes = await supabase
        .from('metal_prices')
        .select('metal, price_date')
        .is('deleted_at', null)
        .gte('price_date', new Date(Date.now() - 365 * 86400000).toISOString().slice(0, 10))
        .order('price_date', { ascending: false })
    const quoteDates = mustRows(quoteRes) as QuoteDate[]


    const updateWithId = updateFormula.bind(null, id)

    // METAL-2:指数选项从表里现读
    const indices = await getMetalPriceIndices()
    const locale = await getLocale()

    return (
        <div className="p-8">
            <div className="flex justify-between items-center mb-4">
                <h1 className="text-2xl font-bold">
                    {t('pricing.listTitle')}
                    <span className="ml-3 font-mono text-base text-gray-500">{formula.code}</span>
                </h1>
                <DeleteFormulaButton formulaId={formula.id} subject={formula.code} />
            </div>
            <FormulaForm
                substanceOptions={substanceOptions}
            indices={indices}
            locale={locale}
                action={updateWithId}
                defaults={defaults}
                suppliers={suppliers}
                customers={customers}
                quoteDates={quoteDates}
            />
        </div>
    )
}
