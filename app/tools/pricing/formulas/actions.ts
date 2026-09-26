'use server'

// ★ APR-8(Tim 2026-09-26):公式表【没有直连写了】(guard_pricing_formula_direct_write)。新建 = 一张停用的公式 +
//   一张 formula_create 申请;改一张在用的 = formula_change(完整拟议条款,批准时就地替换);改一张停用的 =
//   formula_reactivate(批准时写进并启用);删除 = delete_pricing_formula。CFO 批准之前什么都不生效。
//   审批关着时申请生下来就批准并生效 —— 返回的 status 说的是哪一种,页面据此说话。
// 定价公式的增/改/软删。字段校验镜像 DB 的 CHECK(payable 0–100、discount 0–100、
// treatment ≥ 0、average 基准必须给 1–365 的天数),DB 侧仍是最终把关。
// 计价比例:填了的 upsert,清空的删除 —— "留空 = 不计价"这条语义靠删除行来表达
// (pricing_formula_metals 里没有的金属 payable 视为 0)。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { parseIndexField } from '@/app/tools/pricing/metal-prices/indexOptions'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { loadSubstances } from '../metal-prices/substanceQuery'
import { refuseFromCoded } from '@/lib/action-refusal'
import { localizeTermsRequestError } from '@/app/components/pricing/termsRequestErrorCodes'

export type FormulaState = {
    error?: string
    detail?: string
    fieldErrors?: Record<string, string>
}

type Parsed = {
    name: string
    direction: string
    price_basis: string
    price_index: string | null
    average_days: number | null
    treatment_charge_usd_per_tonne: number
    flat_discount_pct: number
    supplier_id: string | null
    customer_id: string | null
    notes: string | null
    /** APR-8:提交给 CFO 的理由(必填) */
    reason: string
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

    // METAL-2:这份公式在哪个指数上结算 —— 交易条款,承诺时抄给成交记录。
    const price_index = parseIndexField(formData.get('price_index'))

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
    // PROC-4:认哪些物质【现读字典】—— 加一行之后这里立刻认它,不必改代码。
    // (外键仍然是权威;这里只是不让一个不认识的值悄悄走完后面的循环。)
    const allowedMetals = new Set(
        (await loadSubstances(await createClient())).map((r) => r.code)
    )
    // ★★ DRAFT-4(2026-09-21):并列数组 → 一座 JSON 桥(Tim 的 (b) 裁定)。
    //   变的【只有行从哪来】—— 下面整段循环体一个字都没改:
    //   字典没认的金属跳过、留空 = 不计价 → `clears`、越界 → 逐格报错。
    //   ⚠ **读不懂的桥不当空集**:那会让「一次说不出话的提交」看起来像
    //     「所有金属都不计价」,而那一支是**删光所有计价行**。按名拒。
    let pLines: { metal: string; pct: string }[]
    try {
        const parsed: unknown = JSON.parse(String(formData.get('payables_json') ?? '[]'))
        if (!Array.isArray(parsed)) throw new Error('not an array')
        pLines = parsed.flatMap((el) => {
            if (el === null || typeof el !== 'object') return []
            const row = el as { metal?: unknown; pct?: unknown }
            const metal = String(row.metal ?? '')
            return metal === '' ? [] : [{ metal, pct: String(row.pct ?? '') }]
        })
    } catch {
        // ★ 形状照抄这棵树已有的那几座桥(`sales/quotes/actions.ts:67-76`):
        //   一个坏掉的 / 不是数组的载荷**照直拒绝**,而不是当成「没有行」。
        //   ⚠ 这一张上两者的差别【特别大】:当成空集 = 一个金属都没送上来
        //   = 一个 `clears` 都不产生……而那恰好**看起来像什么都没发生**,
        //   于是一次读不懂的提交会**静悄悄地把公式存下来、而比例一格都没动**。
        //   **按名拒,摆在表上面。**
        fieldErrors.payables = t('pricing.errPayablesUnreadable')
        pLines = []
    }
    const payables: { metal: string; payable_pct: number }[] = []
    const clears: string[] = []
    for (const line of pLines) {
        const metal = line.metal
        if (!allowedMetals.has(metal)) continue
        const raw = line.pct.trim()
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

    // APR-8:每一次提交都是一张给 CFO 的申请,理由必填(库里也拒 TERMS_REQUEST_REASON_REQUIRED)
    const reason = String(formData.get('reason') ?? '').trim()
    if (!reason) fieldErrors.reason = t('termsRequest.reasonRequired')

    if (Object.keys(fieldErrors).length > 0) return { fieldErrors }

    return {
        parsed: {
            name,
            direction,
            price_basis,
            price_index,
            average_days,
            treatment_charge_usd_per_tonne: treat,
            flat_discount_pct: disc,
            supplier_id,
            customer_id,
            notes: String(formData.get('notes') ?? '').trim() || null,
            reason,
            payables,
            clears,
        },
    }
}

/** 表单那一组 → 申请里的规范条款(与 formula_terms_normalize 同一个形状)。留空的金属不进 metals = 不计价。 */
function termsOf(p: Parsed) {
    return {
        name: p.name,
        direction: p.direction,
        price_basis: p.price_basis,
        price_index: p.price_index,
        average_days: p.average_days,
        treatment_charge_usd_per_tonne: p.treatment_charge_usd_per_tonne,
        flat_discount_pct: p.flat_discount_pct,
        supplier_id: p.supplier_id,
        customer_id: p.customer_id,
        notes: p.notes,
        metals: p.payables,
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
    const { error } = await supabase.rpc('submit_formula_create_request', {
        p_terms: termsOf(p),
        p_reason: p.reason,
    })
    if (error) return await refuseFromCoded(error.message, localizeTermsRequestError)

    revalidatePath('/tools/pricing/formulas')
    redirect('/tools/pricing/formulas')
}

// 在用的公式 → formula_change;停用着的 → formula_reactivate(批准时写进并启用)。
// 走哪一扇由【此刻】公式的状态决定 —— 页面传进来的,库里还会再按名拒一次(FORMULA_NOT_ACTIVE / FORMULA_ALREADY_ACTIVE)。
export async function updateFormula(
    formulaId: string,
    isActive: boolean,
    _prevState: FormulaState,
    formData: FormData
): Promise<FormulaState> {
    const { parsed, fieldErrors } = await parseForm(formData)
    if (fieldErrors) return { fieldErrors }
    const p = parsed!

    const supabase = await createClient()
    const args = { p_formula_id: formulaId, p_terms: termsOf(p), p_reason: p.reason }
    const { error } = isActive
        ? await supabase.rpc('submit_formula_change_request', args)
        : await supabase.rpc('submit_formula_reactivate_request', args)
    if (error) return await refuseFromCoded(error.message, localizeTermsRequestError)

    revalidatePath('/tools/pricing/formulas')
    revalidatePath(`/tools/pricing/formulas/${formulaId}/edit`)
    redirect('/tools/pricing/formulas')
}

export async function deleteFormula(
    formulaId: string
): Promise<{ error?: string; detail?: string }> {
    const supabase = await createClient()
    // APR-8:删除是 cco 一步(只会让能用的变少);等待中的申请挂在它上面时库按名拒 TERMS_REQUEST_OPEN。
    const { error } = await supabase.rpc('delete_pricing_formula', { p_formula_id: formulaId })
    if (error) return await refuseFromCoded(error.message, localizeTermsRequestError)

    revalidatePath('/tools/pricing/formulas')
    redirect('/tools/pricing/formulas')
}
