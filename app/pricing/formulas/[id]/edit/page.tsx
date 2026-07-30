// app/pricing/formulas/[id]/edit/page.tsx
// 编辑定价公式(服务端壳):取公式 + 其计价比例行 + 往来单位下拉;updateFormula 绑 id。
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../../Subnav'
import FormulaForm, { type FormulaDefaults, type PartyOption } from '../../FormulaForm'
import { updateFormula } from '../../actions'
import DeleteFormulaButton from './DeleteFormulaButton'

export default async function EditFormulaPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const { data: formula, error } = await supabase
        .from('pricing_formulas')
        .select('id, code, name, direction, price_basis, average_days, treatment_charge_usd_per_tonne, flat_discount_pct, supplier_id, customer_id, notes, is_active')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    if (error || !formula) {
        notFound()
    }

    const [metalsRes, supRes, cusRes] = await Promise.all([
        supabase.from('pricing_formula_metals').select('metal, payable_pct').eq('formula_id', id),
        supabase.from('suppliers').select('id, legal_name').is('deleted_at', null).order('legal_name'),
        supabase.from('customers').select('id, legal_name').is('deleted_at', null).order('legal_name'),
    ])

    const defaults: FormulaDefaults = {
        name: formula.name,
        direction: formula.direction,
        price_basis: formula.price_basis,
        average_days: formula.average_days != null ? String(formula.average_days) : '',
        treatment_charge_usd_per_tonne: String(formula.treatment_charge_usd_per_tonne ?? ''),
        flat_discount_pct: String(formula.flat_discount_pct ?? ''),
        supplier_id: formula.supplier_id,
        customer_id: formula.customer_id,
        notes: formula.notes ?? '',
        is_active: formula.is_active,
        payables: Object.fromEntries(
            (metalsRes.data ?? []).map((m) => [m.metal, String(m.payable_pct)])
        ),
    }

    const suppliers: PartyOption[] = (supRes.data ?? []).map((s) => ({ id: s.id, name: s.legal_name }))
    const customers: PartyOption[] = (cusRes.data ?? []).map((c) => ({ id: c.id, name: c.legal_name }))

    const updateWithId = updateFormula.bind(null, id)

    return (
        <div className="p-8">
            <div className="flex justify-between items-center mb-4">
                <h1 className="text-2xl font-bold">
                    {t('pricing.listTitle')}
                    <span className="ml-3 font-mono text-base text-gray-500">{formula.code}</span>
                </h1>
                <DeleteFormulaButton formulaId={formula.id} />
            </div>
            <Subnav />
            <FormulaForm
                action={updateWithId}
                defaults={defaults}
                suppliers={suppliers}
                customers={customers}
            />
        </div>
    )
}
