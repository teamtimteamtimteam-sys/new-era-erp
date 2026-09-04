'use server'

// 化验单据的服务端动作:实时预览 / 记录(可选顺带应用)/ 单独应用 / 撤销应用 /
// 按当前含量重新计价。
//
// 【价格永远由 DB 算】客户端从不提交价格。FIN-27 起解析也在 DB:预览走
// preview_assay_price / preview_reprice_from_committed_terms,提交走
// apply_assay_result / reprice_from_committed_terms —— 两侧读【同一份承诺条款】,
// 本文件不再自己解析公式、也不再自己算价。界面上的数字只是显示。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizeAssayError } from '../../assayErrorCodes'
import type { CalcResult } from '@/app/tools/pricing/calculator/actions'

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
    // ASY-1 起 DB 一并返回折算用的牌价与它取自哪天。面板【在这里换单位】——
    // 上半截是 USD(行情口径),这一块是本位币 —— 所以把这一乘摆出来当分界线。
    fx_rate: number | null
    rate_as_of: string | null
}

// preview_reprice_inbound_batch 的返回形状
type RepricePreview = {
    old_unit_price: number | null
    new_unit_price: number
    delta_usd: number
    in_stock_ratio: number
    inventory_share_usd: number
    cost_share_usd: number
    fx_rate: number | null
    rate_as_of: string | null
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
        fx_rate: p.fx_rate === null || p.fx_rate === undefined ? null : Number(p.fx_rate),
        rate_as_of: p.rate_as_of ?? null,
    }
}

// 批次 + 目标单价 → 影响。单价 ≤ 0 时【不调 DB 试算】(它会 PRICE_INVALID),
// 直接返回 undefined:那种料 apply_assay_result 本来就不会给它定价,
// 摆一个"调整 −X 元"的影响块反而是误导。
//
// ASY-1:币种【显式传】。计价口径是 USD/kg(行情与处理费都按 USD/吨),提交路径
// apply_assay_result 也是按 USD 递给 reprice_inbound_batch —— 试算不说币种,就会
// 像 ASY-1 之前那样少乘一次汇率(本位币是 SGD,USD 是外币)。
export async function repricePreview(
    supabase: Awaited<ReturnType<typeof createClient>>,
    batchId: string,
    unitPrice: number
): Promise<AssayImpact | undefined> {
    if (!(unitPrice > 0)) return undefined
    const { data, error } = await supabase.rpc('preview_reprice_inbound_batch', {
        p_inbound_batch_id: batchId,
        p_new_unit_price: unitPrice,
        p_currency: 'USD',
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

// 实时预览:算价 + 影响。无有效含量时返回空(界面自行提示),不当错误。
//
// 【FIN-27:预览与应用读同一份承诺条款】此前这里把解析出的【活公式】喂给
// calculate_metal_price,而 apply_assay_result 现在按承诺副本结算 —— 公式改过之后
// 两者会给出不同的数,而人们信的是看得见的那一个。解析、算价、拆账试算现在都在
// preview_assay_price 里,与 apply_assay_result 逐字同构:
//   有副本 → 按副本算;有公式引用没副本 → 当场 PRICING_TERMS_NOT_COMMITTED;
//   连引用都没有 → calc 为 null(手工定价的采购,不是错误)。
export async function previewAssayPrice(input: {
    batchId: string
    metals: Record<string, string>
    referenceDate: string
}): Promise<PreviewState> {
    const payload = metalsPayload(input.metals)
    if (payload.length === 0) return {}
    // FIN-10 起计价不再默认成今天 —— 空日期会抛 REFERENCE_DATE_REQUIRED。这里先挡
    // 一道,免得把裸错误码甩给操作员;而且预览用哪天的行情,本来就该由化验日说了算。
    if (!input.referenceDate) return {}

    const supabase = await createClient()
    const { data, error } = await supabase.rpc('preview_assay_price', {
        p_inbound_batch_id: input.batchId,
        p_metals: payload,
        p_reference_date: input.referenceDate,
    })
    if (error) return { error: await localizeAssayError(error.message) }

    const row = data as unknown as { calc: CalcResult | null; impact: RepricePreview | null }
    if (!row?.calc) return {}   // 没有公式可解:界面自行提示,不是错误
    return { result: row.calc, impact: row.impact ? toImpact(row.impact) : undefined }
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

    // PROC-6:三个新字段。基准与出具方必填(服务端也独立拒一次);
    // 水分可空 —— 空的意思是【没测过】,不是 0。
    const weightBasis = String(formData.get('weight_basis') ?? '').trim()
    const resultParty = String(formData.get('result_party') ?? '').trim()
    const moistureRaw = String(formData.get('moisture_pct') ?? '').trim()
    let moisturePct: number | null = null
    if (moistureRaw !== '') {
        const n = Number(moistureRaw)
        if (Number.isNaN(n) || n < 0 || n > 100) return { error: t('assay.errMoisture') }
        moisturePct = n
    }
    if (!weightBasis) return { error: t('assay.errors.ASSAY_BASIS_REQUIRED') }
    if (!resultParty) return { error: t('assay.errors.ASSAY_RESULT_PARTY_REQUIRED') }

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
        // PROC-6:基准与出具方【都没有默认值】—— 表单必须明说。
        // 基准:一份没说明基准的含量数字事后还原不出来(干基 30% 与湿基 30% 是两个数)。
        // 出具方:默认成 'ours' 会让"忘了改"变成"这是我们测的"。
        // 水分【可空】:没测就不传,库里落 NULL —— **绝不要传 0**,
        // 那是一次测量,而一个乘数的单位元是看不见的。
        p_weight_basis: weightBasis,
        p_result_party: resultParty,
        ...(moisturePct === null ? {} : { p_moisture_pct: moisturePct }),
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
//
// 【FIN-27:解析与算术都在库里,这里只问结果】此前这个动作在 TypeScript 里
// 重写了一遍公式解析次序,再拿【活公式】算价交给 set_inbound_unit_price ——
// 那是"公式在交易脚下改变"的第三个入口,也是"页面不得重实现记账规则"那条规矩的
// 又一次违反。现在一律走 reprice_from_committed_terms:结算读承诺时抄下的副本,
// 没有副本就点名拒(PRICING_TERMS_NOT_COMMITTED),不悄悄退回去读活公式。
export async function repriceFromCurrentContent(
    batchId: string,
    referenceDate: string
): Promise<{ error?: string; unitPrice?: number }> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('reprice_from_committed_terms', {
        p_inbound_batch_id: batchId,
        p_reference_date: referenceDate || undefined,
    })
    if (error) return { error: await localizeAssayError(error.message) }

    revalidatePath(`/inbound/${batchId}/edit`)
    revalidatePath('/finance/journal')
    return { unitPrice: Number((data as { unit_price_usd_per_kg?: number } | null)?.unit_price_usd_per_kg) }
}

// 上面那个动作的【试算】—— 同一份算术(committed_terms_price),同一份承诺。
// 预览读活公式而提交读副本,就是这个仓库数过四次的那个 bug:两份实现写下的当天
// 一致、之后无声漂移,而人们信的偏偏是看得见的那一个。
export async function previewRepriceFromCommittedTerms(
    batchId: string,
    referenceDate: string
): Promise<PreviewState> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('preview_reprice_from_committed_terms', {
        p_inbound_batch_id: batchId,
        p_reference_date: referenceDate || undefined,
    })
    if (error) return { error: await localizeAssayError(error.message) }
    const row = data as unknown as { calc: CalcResult; impact: RepricePreview | null }
    return {
        result: row.calc,
        impact: row.impact ? toImpact(row.impact) : undefined,
    }
}
