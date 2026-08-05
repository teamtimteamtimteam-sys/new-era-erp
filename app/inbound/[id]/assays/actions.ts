'use server'

// 化验单据的服务端动作:实时预览 / 记录(可选顺带应用)/ 单独应用 / 撤销应用 /
// 按当前含量重新计价。
//
// 【价格永远由 DB 算】客户端从不提交价格 —— 预览与提交都在服务端调
// calculate_metal_price,提交再把它的结果交给 apply_assay_result 或
// set_inbound_unit_price。界面上的数字只是显示。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizeAssayError } from '../../assayErrorCodes'
import type { CalcResult } from '@/app/pricing/calculator/actions'

// "如果应用会怎样"的影响数字。
// 【拆分算术全部来自 DB】—— preview_reprice_inbound_batch 与真正入账的
// reprice_inbound_batch 共用同一个纯函数 reprice_split(见
// db/migrations/2026-08-01-perm1-permission-skeleton.sql),所以预览说的和提交
// 做的不可能不一致。这里只做字段改名,不做任何计算。
// 唯一的例外是 unit_delta(每公斤差额):它只是"新价 − 旧价"的展示项,不属于
// 存货/成本的分摊口径,DB 也不返回它。
export type AssayImpact = {
    current_unit_price: number | null
    new_unit_price: number
    unit_delta: number
    total_delta: number
    in_stock_ratio: number
    inventory_share: number
    cost_share: number
}

// preview_reprice_inbound_batch 的返回形状
type RepricePreview = {
    old_unit_price: number | null
    new_unit_price: number
    delta_usd: number
    in_stock_ratio: number
    inventory_share_usd: number
    cost_share_usd: number
}

const round4 = (n: number) => Math.round(n * 10000) / 10000

function toImpact(p: RepricePreview): AssayImpact {
    return {
        current_unit_price: p.old_unit_price === null ? null : Number(p.old_unit_price),
        new_unit_price: Number(p.new_unit_price),
        unit_delta: round4(Number(p.new_unit_price) - Number(p.old_unit_price ?? 0)),
        total_delta: Number(p.delta_usd),
        in_stock_ratio: Number(p.in_stock_ratio),
        inventory_share: Number(p.inventory_share_usd),
        cost_share: Number(p.cost_share_usd),
    }
}

// 批次 + 目标单价 → 影响。单价 ≤ 0 时【不调 DB 试算】(它会 PRICE_INVALID),
// 直接返回 undefined:那种料 apply_assay_result 本来就不会给它定价,
// 摆一个"调整 −X 元"的影响块反而是误导。
export async function repricePreview(
    supabase: Awaited<ReturnType<typeof createClient>>,
    batchId: string,
    unitPrice: number
): Promise<AssayImpact | undefined> {
    if (!(unitPrice > 0)) return undefined
    const { data, error } = await supabase.rpc('preview_reprice_inbound_batch', {
        p_inbound_batch_id: batchId,
        p_new_unit_price: unitPrice,
    })
    if (error || !data) return undefined
    return toImpact(data as unknown as RepricePreview)
}

export type PreviewState = { error?: string; result?: CalcResult; impact?: AssayImpact }

// 表单里的化验行 → calculate_metal_price 的 metals 载荷(空含量整行忽略 —— 空 = 没测)
function metalsPayload(metals: Record<string, string>): { metal: string; content_pct: number }[] {
    const out: { metal: string; content_pct: number }[] = []
    for (const [metal, raw] of Object.entries(metals ?? {})) {
        const s = (raw ?? '').trim()
        if (s === '') continue
        const n = Number(s)
        if (Number.isNaN(n)) continue
        out.push({ metal, content_pct: n })
    }
    return out
}

// 实时预览:算价 + 影响。无公式 / 无有效含量时返回空(界面自行提示),不当错误。
export async function previewAssayPrice(input: {
    batchId: string
    formulaId: string | null
    metals: Record<string, string>
    referenceDate: string
}): Promise<PreviewState> {
    const payload = metalsPayload(input.metals)
    if (!input.formulaId || payload.length === 0) return {}
    // FIN-10 起 calculate_metal_price_internal 不再默认成今天 —— 空日期会抛
    // REFERENCE_DATE_REQUIRED。这里先挡一道,免得把裸错误码甩给操作员;
    // 而且预览用哪天的行情,本来就该由化验日说了算,不是"今天"。
    if (!input.referenceDate) return {}

    const supabase = await createClient()
    // 只为算价拿数量;影响的拆分不在这里算 —— 交给 DB 的试算函数
    const { data: batch } = await supabase
        .from('inbound_batches')
        .select('quantity')
        .eq('id', input.batchId)
        .is('deleted_at', null)
        .single()
    if (!batch) return { error: await localizeAssayError('INBOUND_NOT_FOUND') }

    const { data, error } = await supabase.rpc('calculate_metal_price', {
        p_formula_id: input.formulaId,
        p_metals: payload,
        p_quantity_kg: batch.quantity,
        p_reference_date: input.referenceDate,
    })
    if (error) return { error: await localizeAssayError(error.message) }

    const result = data as unknown as CalcResult
    return {
        result,
        impact: await repricePreview(supabase, input.batchId, Number(result.unit_price_usd_per_kg)),
    }
}

export type SubmitAssayState = { error?: string }

// 记录化验(intent='record_apply' 时顺带应用)。
//
// 【记录与应用是两次独立的 RPC,因此是两个独立事务】—— 这正是我们要的:
// 记录一旦成功就【已经落库】,后续应用失败也不会把它带走(化验单是实验室出的
// 客观事实,不该因为定价环节出问题而消失)。所以应用失败时【绝不做补偿性删除】,
// 而是带着错误跳到化验详情页,操作员可以稍后再应用。
export async function submitAssay(
    batchId: string,
    _prevState: SubmitAssayState,
    formData: FormData
): Promise<SubmitAssayState> {
    const t = await getTranslations()

    const intent = String(formData.get('intent') ?? 'record')
    const assayDate = String(formData.get('assay_date') ?? '').trim()
    const labName = String(formData.get('lab_name') ?? '').trim()
    const certificateRef = String(formData.get('certificate_ref') ?? '').trim()
    const sampleRef = String(formData.get('sample_ref') ?? '').trim()
    const isFinal = formData.get('is_final') === 'on'
    const notes = String(formData.get('notes') ?? '').trim()

    if (!assayDate || Number.isNaN(Date.parse(assayDate))) {
        return { error: t('assay.errors.ASSAY_DATE_INVALID', { 0: assayDate || '?' }) }
    }

    // 并列数组 → metals 载荷(与计价器同构:空含量整行忽略)
    const metalNames = formData.getAll('assay_metal').map(String)
    const contents = formData.getAll('assay_content').map(String)
    const metals: Record<string, string> = {}
    metalNames.forEach((m, i) => {
        metals[m] = contents[i] ?? ''
    })
    const payload = metalsPayload(metals)
    if (payload.length === 0) return { error: t('assay.errors.NO_METALS') }

    const supabase = await createClient()
    const { data, error } = await supabase.rpc('record_assay_result', {
        p_inbound_batch_id: batchId,
        p_assay_date: assayDate,
        p_metals: payload,
        p_lab_name: labName || undefined,
        p_certificate_ref: certificateRef || undefined,
        p_sample_ref: sampleRef || undefined,
        p_is_final: isFinal,
        p_notes: notes || undefined,
    })
    if (error) {
        return { error: await localizeAssayError(error.message) }
    }

    const assayId = (data as { assay_result_id?: string } | null)?.assay_result_id
    if (!assayId) return { error: t('assay.errors.ASSAY_NOT_FOUND', { 0: '?' }) }

    // 顺带应用:失败不回滚上面的记录,只把错误带到详情页
    let applyError = ''
    if (intent === 'record_apply') {
        const { error: applyErr } = await supabase.rpc('apply_assay_result', {
            p_assay_result_id: assayId,
        })
        if (applyErr) applyError = applyErr.message
    }

    revalidatePath('/inbound')
    revalidatePath(`/inbound/${batchId}/edit`)

    // redirect 会抛 NEXT_REDIRECT —— 放在所有可能 catch 的逻辑之外
    redirect(
        `/inbound/${batchId}/assays/${assayId}` +
            (applyError ? `?apply_error=${encodeURIComponent(applyError)}` : '')
    )
}

// 详情页的"立即应用"
export async function applyAssay(
    assayId: string,
    batchId: string
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('apply_assay_result', {
        p_assay_result_id: assayId,
    })
    if (error) return { error: await localizeAssayError(error.message) }

    revalidatePath('/inbound')
    revalidatePath(`/inbound/${batchId}/edit`)
    revalidatePath(`/inbound/${batchId}/assays/${assayId}`)
    revalidatePath('/finance/journal')
    return {}
}

// 撤销应用:只解开"已应用"标记与取代链,【不回价、不回含量】(见 DB 函数注释)
export async function unapplyAssay(
    assayId: string,
    batchId: string,
    reason: string
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('unapply_assay_result', {
        p_assay_result_id: assayId,
        p_reason: reason.trim(),
    })
    if (error) return { error: await localizeAssayError(error.message) }

    revalidatePath('/inbound')
    revalidatePath(`/inbound/${batchId}/edit`)
    revalidatePath(`/inbound/${batchId}/assays/${assayId}`)
    return {}
}

// 按【批次当前含量】重新计价(含量是手工改的、没有化验单时用)。
// 价格在服务端算完直接交给 set_inbound_unit_price —— 客户端提交的价格一概不信。
export async function repriceFromCurrentContent(
    batchId: string,
    referenceDate: string
): Promise<{ error?: string; unitPrice?: number }> {
    const supabase = await createClient()

    const { data: batch } = await supabase
        .from('inbound_batches')
        .select('quantity, pricing_formula_id, purchase_order_line_id')
        .eq('id', batchId)
        .is('deleted_at', null)
        .single()
    if (!batch) return { error: await localizeAssayError('INBOUND_NOT_FOUND') }

    // 公式解析顺序与 apply_assay_result 一致:批次 → 采购单明细行
    let formulaId = batch.pricing_formula_id
    if (!formulaId && batch.purchase_order_line_id) {
        const { data: line } = await supabase
            .from('purchase_order_lines')
            .select('pricing_formula_id')
            .eq('id', batch.purchase_order_line_id)
            .single()
        formulaId = line?.pricing_formula_id ?? null
    }
    if (!formulaId) return { error: await localizeAssayError('FORMULA_NOT_FOUND|?') }

    const { data: metalRows } = await supabase
        .from('inbound_batch_metals')
        .select('metal, content_pct')
        .eq('inbound_batch_id', batchId)
    const payload = (metalRows ?? []).map((m) => ({ metal: m.metal, content_pct: m.content_pct }))
    if (payload.length === 0) return { error: await localizeAssayError('NO_METALS') }

    const { data: calc, error: calcError } = await supabase.rpc('calculate_metal_price', {
        p_formula_id: formulaId,
        p_metals: payload,
        p_quantity_kg: batch.quantity,
        p_reference_date: referenceDate || undefined,
    })
    if (calcError) return { error: await localizeAssayError(calcError.message) }

    const unit = Number((calc as unknown as CalcResult).unit_price_usd_per_kg)
    if (!(unit > 0)) {
        // 净值 ≤ 0 的料不进价格机器(与 apply_assay_result 同一判断)
        return { error: (await getTranslations())('assay.negativeValue') }
    }

    const { error: priceError } = await supabase.rpc('set_inbound_unit_price', {
        p_inbound_batch_id: batchId,
        p_unit_price: unit,
        p_notes: 'Repriced from current recorded content',
    })
    if (priceError) return { error: await localizeAssayError(priceError.message) }

    // 批次上记下这张公式,下次化验可以直接解析到
    if (!batch.pricing_formula_id) {
        await supabase.from('inbound_batches').update({ pricing_formula_id: formulaId }).eq('id', batchId)
    }

    revalidatePath(`/inbound/${batchId}/edit`)
    revalidatePath('/finance/journal')
    return { unitPrice: unit }
}
