'use server'

// 采购单创建:表单(行与付款计划以 JSON 字段整体提交,行里嵌着化验/模式等结构,
// 并列数组会散架)→ rpc create_purchase_order(编号、校验、行、计划一个事务)。
// 校验主体在 DB(SUPPLIER_NOT_FOUND / LINE_QTY_INVALID / TERMS_* …),错误码本地化后
// 展示;成功跳新采购单详情。
//
// computeLineEstimate:行上的"按化验估算" —— 把该行的公式 + 预计化验喂给
// calculate_metal_price(与计价器同一 DB 函数,客户端不做任何计算),
// 返回完整明细供面板摊开;填入的是 unit_price_usd_per_kg。
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizePurchasingError } from '../../purchasingErrorCodes'
import { localizePricingError } from '@/app/pricing/pricingErrorCodes'
import type { CalcResult } from '@/app/pricing/calculator/actions'

export type CreateOrderState = { error?: string }

export type OrderLineInput = {
    material_id: string
    // EQP-1c-b(P2):设备行订的是一张【已存在】的资产卡,不是物料。
    // 与 material_id 恰一非空 —— 表上那条 XOR 是 EQP-1a 立的。
    asset_id?: string
    quantity: string
    unit: string
    formula_id: string
    est_price: string
    assay: Record<string, string> // metal code → content % 原始输入(空 = 没测)
    // FIN-26:价格出处(记录,不推断)。computed 必带重导出依据。
    price_source?: 'computed' | 'manual'
    price_provenance?: Record<string, unknown>
}

export type OrderTermInput = {
    label: string
    mode: 'percentage' | 'fixed'
    percentage: string
    fixed_amount: string
    trigger_event: string
    due_date: string
}

const TRIGGERS = new Set(['on_order', 'on_shipment', 'on_arrival', 'post_assay', 'fixed_date'])

export async function createOrder(
    _prevState: CreateOrderState,
    formData: FormData
): Promise<CreateOrderState> {
    const t = await getTranslations()

    const supplierId = String(formData.get('supplier_id') ?? '').trim()
    const orderDate = String(formData.get('order_date') ?? '').trim()
    const expectedDelivery = String(formData.get('expected_delivery') ?? '').trim()
    const currency = String(formData.get('currency') ?? await getBaseCurrency())
    const incoterm = String(formData.get('incoterm') ?? '').trim()
    const notes = String(formData.get('notes') ?? '').trim()
    const termsText = String(formData.get('terms_text') ?? '').trim()

    if (!supplierId) return { error: t('purchasing.errors.SUPPLIER_NOT_FOUND', { 0: '?' }) }
    if (!orderDate || Number.isNaN(Date.parse(orderDate))) return { error: t('finance.errDate') }


    // 明细行(≥1;数量等硬校验交给 DB 的 LINE_QTY_INVALID,这里只组装)
    let lineInputs: OrderLineInput[]
    try {
        lineInputs = JSON.parse(String(formData.get('lines_json') ?? '[]'))
    } catch {
        return { error: t('purchasing.errors.NO_LINES') }
    }
    if (!Array.isArray(lineInputs) || lineInputs.length === 0) {
        return { error: t('purchasing.errors.NO_LINES') }
    }
    const lines = lineInputs.map((l, i) => {
        const assay = Object.entries(l.assay ?? {})
            .map(([metal, raw]) => ({ metal, content_pct: Number(String(raw).trim()) }))
            .filter((a) => String(l.assay[a.metal]).trim() !== '' && !Number.isNaN(a.content_pct))
        const price = l.est_price.trim() === '' ? null : Number(l.est_price)
        // EQP-1c-b(P2):设备行与材料行走同一个负载,但【只带其中一个 id】——
        // create_purchase_order 按"恰一非空"分支(PO_LINE_KIND_INVALID),
        // 表上还有一条同义的 XOR。两者都空或都给,直插也逃不掉。
        const isEquipment = Boolean(l.asset_id)
        return {
            line_no: i + 1,
            ...(isEquipment ? { asset_id: l.asset_id } : { material_id: l.material_id }),
            // 设备行的数量与单位【由规则定死】,不是表单填的:EQP-1a-TAIL 把
            // "一台机器一条行、单位 unit" 做成了表上的 CHECK。这里照它送,
            // 屏幕上也只显示不让改 —— 两边说的是同一件事。
            quantity: isEquipment ? 1 : Number(l.quantity),
            unit: isEquipment ? 'unit' : (l.unit.trim() || 'kg'),
            ...(l.formula_id ? { pricing_formula_id: l.formula_id } : {}),
            ...(price !== null && !Number.isNaN(price) ? { estimated_unit_price: price } : {}),
            ...(assay.length ? { expected_assay: assay } : {}),
            // FIN-26:出处随行进 DB;配对(computed ↔ provenance)由函数与 CHECK 双重把关
            ...(l.price_source ? { price_source: l.price_source } : {}),
            ...(l.price_provenance ? { price_provenance: l.price_provenance } : {}),
        }
    })

    // 付款计划(可选 —— 空表合法:有些采购就是到货即付)
    let termInputs: OrderTermInput[]
    try {
        termInputs = JSON.parse(String(formData.get('terms_json') ?? '[]'))
    } catch {
        termInputs = []
    }
    const terms = []
    for (let i = 0; i < termInputs.length; i++) {
        const l = termInputs[i]
        const label = (l.label ?? '').trim()
        if (!label || !TRIGGERS.has(l.trigger_event)) {
            return { error: t('purchasing.errTermLine', { 0: i + 1 }) }
        }
        if (l.trigger_event === 'fixed_date' && !l.due_date) {
            return { error: t('purchasing.errTermLine', { 0: i + 1 }) }
        }
        if (l.mode === 'percentage') {
            const n = Number(l.percentage)
            if (!l.percentage || Number.isNaN(n) || n <= 0 || n > 100) {
                return { error: t('purchasing.errTermLine', { 0: i + 1 }) }
            }
            terms.push({
                seq: i + 1,
                label,
                percentage: n,
                trigger_event: l.trigger_event,
                ...(l.due_date ? { due_date: l.due_date } : {}),
            })
        } else {
            const n = Number(l.fixed_amount)
            if (!l.fixed_amount || Number.isNaN(n) || n <= 0) {
                return { error: t('purchasing.errTermLine', { 0: i + 1 }) }
            }
            terms.push({
                seq: i + 1,
                label,
                fixed_amount_ccy: n,
                trigger_event: l.trigger_event,
                ...(l.due_date ? { due_date: l.due_date } : {}),
            })
        }
    }

    const supabase = await createClient()
    // 可空参数在 DB 签名里没有默认值,生成的类型因此标成 required string —— 运行时
    // 传 null 完全合法(列可空),此处仅为通过类型检查而窄化断言。
    const { data, error } = await supabase.rpc('create_purchase_order', {
        p_supplier_id: supplierId,
        p_order_date: orderDate,
        p_expected_delivery: (expectedDelivery || null) as unknown as string,
        p_currency: currency,
        // FIN-0:估算按下单日行方卖出价自动取,缺牌价 DB 直接拒;签名无默认故显式传 null
        p_fx_rate: null as unknown as number,
        p_incoterm: (incoterm || null) as unknown as string,
        p_terms_text: (termsText || null) as unknown as string,
        p_notes: (notes || null) as unknown as string,
        // provenance jsonb 自由形状 —— 生成类型的 Json 联合装不下 CalcResult,原样断言
        p_lines: lines as unknown as import('@/lib/database.types').Json,
        p_payment_terms: terms,
    })

    if (error) {
        return { error: await localizePurchasingError(error.message) }
    }

    const poId = (data as { purchase_order_id?: string } | null)?.purchase_order_id

    revalidatePath('/purchasing/orders')

    if (poId) {
        redirect(`/purchasing/orders/${poId}`)
    }
    redirect('/purchasing/orders')
}

// 行上的"按化验估算":公式 + 预计化验 → calculate_metal_price。
// 参考日不传(DB 默认今天)—— 下单当刻的行情就是谈判桌上的行情。
export async function computeLineEstimate(input: {
    formulaId: string
    quantity: number
    assay: { metal: string; content_pct: number }[]
    currency: string
    orderDate: string
}): Promise<{
    error?: string
    result?: CalcResult
    unitPriceDoc?: number   // 折成【单据币种】的单价 —— 真正要填进行里的那个数
    fxUsed?: number
    fxAsOf?: string
}> {
    const t = await getTranslations()

    if (!input.formulaId) return { error: t('pricing.errFormulaRequired') }
    if (!input.quantity || input.quantity <= 0) return { error: t('pricing.errors.QUANTITY_INVALID') }
    if (!input.assay.length) return { error: t('pricing.errors.NO_METALS') }
    if (!input.currency || !input.orderDate) return { error: t('pricing.errQuoteNeedsCurrencyDate') }

    const supabase = await createClient()
    const { data, error } = await supabase.rpc('calculate_metal_price', {
        p_formula_id: input.formulaId,
        p_metals: input.assay,
        p_quantity_kg: input.quantity,
    })

    if (error) {
        return { error: await localizePricingError(error.message) }
    }
    const result = data as unknown as CalcResult
    // 报价路径:缺行情即拒(与 /pricing/calculator 同一条规矩,理由见那里)
    if (result.skipped_metals?.length) {
        return { error: t('pricing.errNoPriceForMetals', {
            metals: result.skipped_metals.join(', '), date: result.reference_date }) }
    }

    // ════════════════════════════════════════════════════════════════════════
    // 【公式价是 USD/kg,单据不一定是 USD —— 必须换算】
    // calculate_metal_price 全程 USD 进 USD 出(行情本身按 USD/吨报价),
    // 而 PO 的币种由操作员选。原先直接把 USD 数字填进单据币种的价格框:
    // 单据若是 SGD,等于把一个 USD 价当成 SGD 价 —— 按 1.26~1.35 算,
    // 【报价低了约四分之一】。这条路决定给本地供应商报什么价。
    // 换算口径:USD → 单据币种 = usd × fx(USD) / fx(单据币种),两边都取下单日、
    // 都走 fx_rate_asof(缺牌价即拒,并说明取自哪一天)。单据本身就是 USD 时,
    // 两个汇率相同、比值为 1 —— 不换算,也不需要特判。
    // ════════════════════════════════════════════════════════════════════════
    const usdPrice = Number(result.unit_price_usd_per_kg)
    const usd = await lookupRate('USD', input.orderDate)
    if (usd.error) return { error: usd.error }
    const doc = await lookupRate(input.currency, input.orderDate)
    if (doc.error) return { error: doc.error }

    const factor = (usd.rate as number) / (doc.rate as number)
    const unitPriceDoc = Math.round(usdPrice * factor * 10000) / 10000
    return { result, unitPriceDoc, fxUsed: factor, fxAsOf: usd.asOf }
}

// 下单日的行方卖出价(采购是我们买外币)。缺牌价即拒,并带回取自哪一天。
async function lookupRate(currency: string, date: string):
    Promise<{ rate?: number; asOf?: string; error?: string }> {
    const t = await getTranslations()
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('fx_rate_asof', {
        p_currency: currency, p_date: date, p_rate_type: 'tt_sell',
    })
    if (error) return { error: t('finance.fxLookup.missing', { 0: date, 1: currency, 2: 'tt_sell' }) }
    const row = (data as { rate: number; as_of: string }[] | null)?.[0]
    if (!row || !Number.isFinite(Number(row.rate)) || Number(row.rate) <= 0) {
        return { error: t('finance.fxLookup.missing', { 0: date, 1: currency, 2: 'tt_sell' }) }
    }
    return { rate: Number(row.rate), asOf: row.as_of }
}
