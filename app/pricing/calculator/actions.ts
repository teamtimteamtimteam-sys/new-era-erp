'use server'

// 计价:把化验行组装成 metals jsonb → rpc calculate_metal_price。
// 【客户端不做任何计算】—— DB 函数是唯一的真相来源,页面只负责把它返回的明细摊开。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { localizePricingError } from '../pricingErrorCodes'

export type CalcLine = {
    metal: string
    content_pct: number
    payable_pct: number
    contained_kg: number
    payable_kg: number
    price_usd_per_tonne: number | null
    price_date: string | null
    price_from: string | null
    price_to: string | null
    metal_value_usd: number
}

export type CalcResult = {
    formula_code: string
    formula_name: string
    price_basis: string
    average_days: number | null
    reference_date: string
    quantity_kg: number
    lines: CalcLine[]
    gross_value_usd: number
    treatment_usd: number
    discount_usd: number
    net_value_usd: number
    unit_price_usd_per_kg: number
    negative_value: boolean
    skipped_metals: string[]
    unpaid_metals: string[]
}

export type CalculatorState = { error?: string; result?: CalcResult }

export async function calculatePrice(
    _prevState: CalculatorState,
    formData: FormData
): Promise<CalculatorState> {
    const t = await getTranslations()

    const formulaId = String(formData.get('formula_id') ?? '').trim()
    const quantityRaw = String(formData.get('quantity_kg') ?? '').trim()
    const refDate = String(formData.get('reference_date') ?? '').trim()

    if (!formulaId) return { error: t('pricing.errFormulaRequired') }
    const quantity = Number(quantityRaw)
    if (!quantityRaw || Number.isNaN(quantity) || quantity <= 0) {
        return { error: t('pricing.errors.QUANTITY_INVALID') }
    }
    if (!refDate || Number.isNaN(Date.parse(refDate))) {
        return { error: t('finance.errDate') }
    }

    // 化验行:并列数组,空含量的行整行忽略(不是 0,是"没测")
    const metals = formData.getAll('assay_metal').map(String)
    const contents = formData.getAll('assay_content').map(String)
    const payload: { metal: string; content_pct: number }[] = []
    for (let i = 0; i < metals.length; i++) {
        const raw = (contents[i] ?? '').trim()
        if (raw === '') continue
        const n = Number(raw)
        if (Number.isNaN(n)) continue
        payload.push({ metal: metals[i], content_pct: n })
    }
    if (payload.length === 0) return { error: t('pricing.errors.NO_METALS') }

    const supabase = await createClient()
    const { data, error } = await supabase.rpc('calculate_metal_price', {
        p_formula_id: formulaId,
        p_metals: payload,
        p_quantity_kg: quantity,
        p_reference_date: refDate,
    })

    if (error) {
        return { error: await localizePricingError(error.message) }
    }

    const result = data as unknown as CalcResult
    // ════════════════════════════════════════════════════════════════════════
    // 【报价这条路:缺行情就拒绝】—— 拒绝放在【调用方】,不动 DB 函数。
    // calculate_metal_price_internal 对缺行情的金属计 0 并列进 skipped_metals,
    // 这是 Phase 1 的有意决定,【不能改】:allocate_processing_costs 也靠它,
    // 而"为了一个金属没报价就卡住生产"从来不是我们要的。
    // 但报价不一样:少算一个金属的价,报出去的是一个偏低的价,而且看不出来 ——
    // 极端情况下加工费照扣、金属一个都没定上价,单价能算成 −0.8 USD/kg。
    // 所以:同一个函数,两个调用方,两种处置。
    //   * 报价(本文件)   → skipped_metals 非空即拒,并点名是哪些金属;
    //   * 成本分摊(DB)   → 照旧跳过,不阻断生产。
    // 【别把它们统一了】—— 它们的差异是有意的,理由就写在这里和
    // db/functions/allocate_processing_costs.sql 的对应位置。
    // ════════════════════════════════════════════════════════════════════════
    if (result.skipped_metals?.length) {
        const t = await getTranslations()
        return {
            error: t('pricing.errNoPriceForMetals', {
                metals: result.skipped_metals.join(', '),
                date: result.reference_date,
            }),
        }
    }

    return { result }
}
