'use server'

// 定价公式的增/改/软删。字段校验镜像 DB 的 CHECK(payable 0–100、discount 0–100、
// treatment ≥ 0、average 基准必须给 1–365 的天数),DB 侧仍是最终把关。
// 计价比例:填了的 upsert,清空的删除 —— "留空 = 不计价"这条语义靠删除行来表达
// (pricing_formula_metals 里没有的金属 payable 视为 0)。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { METAL_VALUES } from '../../metal-prices/options'

export type FormulaState = {
    error?: string
    fieldErrors?: Record<string, string>
}

type Parsed = {
    name: string
    direction: string
    price_basis: string
    average_days: number | null
    treatment_charge_usd_per_tonne: number
    flat_discount_pct: number
    supplier_id: string | null
    customer_id: string | null
    notes: string | null
    is_active: boolean
    payables: { metal: string; payable_pct: number }[]
    clears: string[]
}

async function parseForm(formData: FormData): Promise<{ parsed?: Parsed; fieldErrors?: Record<string, string> }> {
    const t = await getTranslations()
    const fieldErrors: Record<string, string> = {}

    const name = String(formData.get('name') ?? '').trim()
    if (!name) fieldErrors.name = t('pricing.errName')

    const direction = String(formData.get('direction') ?? 'both')
    if (!['purchase', 'sale', 'both'].includes(direction)) fieldErrors.direction = t('pricing.errDirection')

    const price_basis = String(formData.get('price_basis') ?? 'spot')
    if (!['spot', 'average'].includes(price_basis)) fieldErrors.price_basis = t('pricing.errBasis')

    let average_days: number | null = null
    if (price_basis === 'average') {
        const raw = String(formData.get('average_days') ?? '').trim()
        const n = Number(raw)
        if (!raw || Number.isNaN(n) || !Number.isInteger(n) || n < 1 || n > 365) {
            fieldErrors.average_days = t('pricing.errAverageDays')
        } else {
            average_days = n
        }
    }

    const treatRaw = String(formData.get('treatment_charge_usd_per_tonne') ?? '').trim()
    const treat = treatRaw === '' ? 0 : Number(treatRaw)
    if (Number.isNaN(treat) || treat < 0) fieldErrors.treatment_charge_usd_per_tonne = t('pricing.errTreatment')

    const discRaw = String(formData.get('flat_discount_pct') ?? '').trim()
    const disc = discRaw === '' ? 0 : Number(discRaw)
    if (Number.isNaN(disc) || disc < 0 || disc > 100) fieldErrors.flat_discount_pct = t('pricing.errDiscount')

    // 适用对象:generic / supplier / customer —— DB 侧 num_nonnulls <= 1 兜底
    const mode = String(formData.get('counterparty_mode') ?? 'generic')
    let supplier_id: string | null = null
    let customer_id: string | null = null
    if (mode === 'supplier') {
        supplier_id = String(formData.get('supplier_id') ?? '').trim() || null
        if (!supplier_id) fieldErrors.supplier_id = t('pricing.errCounterparty')
    } else if (mode === 'customer') {
        customer_id = String(formData.get('customer_id') ?? '').trim() || null
        if (!customer_id) fieldErrors.customer_id = t('pricing.errCounterparty')
    }

    // 计价比例:并列数组 payable_metal[] / payable_pct[]
    const pMetals = formData.getAll('payable_metal').map(String)
    const pPcts = formData.getAll('payable_pct').map(String)
    const payables: { metal: string; payable_pct: number }[] = []
    const clears: string[] = []
    for (let i = 0; i < pMetals.length; i++) {
        const metal = pMetals[i]
        if (!METAL_VALUES.includes(metal)) continue
        const raw = (pPcts[i] ?? '').trim()
        if (raw === '') {
            clears.push(metal) // 留空 = 不计价 → 删掉可能存在的旧行
            continue
        }
        const n = Number(raw)
        if (Number.isNaN(n) || n < 0 || n > 100) {
            fieldErrors['payable_' + metal] = t('pricing.errPayable')
            continue
        }
        payables.push({ metal, payable_pct: n })
    }

    if (Object.keys(fieldErrors).length > 0) return { fieldErrors }

    return {
        parsed: {
            name,
            direction,
            price_basis,
            average_days,
            treatment_charge_usd_per_tonne: treat,
            flat_discount_pct: disc,
            supplier_id,
            customer_id,
            notes: String(formData.get('notes') ?? '').trim() || null,
            is_active: formData.get('is_active') === 'on',
            payables,
            clears,
        },
    }
}

export async function createFormula(
    _prevState: FormulaState,
    formData: FormData
): Promise<FormulaState> {
    const { parsed, fieldErrors } = await parseForm(formData)
    if (fieldErrors) return { fieldErrors }
    const p = parsed!

    const supabase = await createClient()
    // code 由 BEFORE INSERT 触发器分配(无缝编号)。列是 NOT NULL 且无 DB 默认值,
    // 生成的类型看不见触发器,故这里送空串 —— 触发器对 NULL 与 '' 一视同仁,都补号。
    const { data, error } = await supabase
        .from('pricing_formulas')
        .insert({
            code: '',
            name: p.name,
            direction: p.direction,
            price_basis: p.price_basis,
            average_days: p.average_days,
            treatment_charge_usd_per_tonne: p.treatment_charge_usd_per_tonne,
            flat_discount_pct: p.flat_discount_pct,
            supplier_id: p.supplier_id,
            customer_id: p.customer_id,
            notes: p.notes,
            is_active: p.is_active,
        })
        .select('id')
        .single()

    if (error) return { error: error.message }

    if (p.payables.length > 0) {
        const { error: mErr } = await supabase
            .from('pricing_formula_metals')
            .insert(p.payables.map((m) => ({ formula_id: data.id, ...m })))
        if (mErr) return { error: mErr.message }
    }

    revalidatePath('/pricing/formulas')
    redirect('/pricing/formulas')
}

export async function updateFormula(
    formulaId: string,
    _prevState: FormulaState,
    formData: FormData
): Promise<FormulaState> {
    const { parsed, fieldErrors } = await parseForm(formData)
    if (fieldErrors) return { fieldErrors }
    const p = parsed!

    const supabase = await createClient()
    const { error } = await supabase
        .from('pricing_formulas')
        .update({
            name: p.name,
            direction: p.direction,
            price_basis: p.price_basis,
            average_days: p.average_days,
            treatment_charge_usd_per_tonne: p.treatment_charge_usd_per_tonne,
            flat_discount_pct: p.flat_discount_pct,
            supplier_id: p.supplier_id,
            customer_id: p.customer_id,
            notes: p.notes,
            is_active: p.is_active,
        })
        .eq('id', formulaId)

    if (error) return { error: error.message }

    if (p.payables.length > 0) {
        const { error: mErr } = await supabase
            .from('pricing_formula_metals')
            .upsert(
                p.payables.map((m) => ({ formula_id: formulaId, ...m })),
                { onConflict: 'formula_id,metal' }
            )
        if (mErr) return { error: mErr.message }
    }
    if (p.clears.length > 0) {
        const { error: dErr } = await supabase
            .from('pricing_formula_metals')
            .delete()
            .eq('formula_id', formulaId)
            .in('metal', p.clears)
        if (dErr) return { error: dErr.message }
    }

    revalidatePath('/pricing/formulas')
    revalidatePath(`/pricing/formulas/${formulaId}/edit`)
    redirect('/pricing/formulas')
}

export async function deleteFormula(formulaId: string): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase
        .from('pricing_formulas')
        .update({ deleted_at: new Date().toISOString() })
        .eq('id', formulaId)
        .is('deleted_at', null)

    if (error) return { error: error.message }

    revalidatePath('/pricing/formulas')
    redirect('/pricing/formulas')
}
