'use server'

// 产出化验的服务端动作:记录(可选顺带应用)/ 应用 / 撤销。
// 进料侧(app/inbound/[id]/assays/actions.ts)是形状的出处;这里没有价格 ——
// 产出化验的应用只抄含量并让过期机制看得见(apply_output_assay),没有一张
// 应付可以重述,所以也没有算价预览。"应用会怎样"由 preview_apply_output_assay
// 回答(详情页直接问库),本文件不重算任何东西。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizeAssayError } from '@/app/inbound/assayErrorCodes'

export type SubmitOutputAssayState = { error?: string }

// 表单里的化验行 → metals 载荷(空含量整行忽略 —— 空 = 没测;与进料侧同构)
// ★★ DRAFT-4(2026-09-21):收的从【两条按下标配对的数组】换成【自带配对的行】。
//   ☞ **循环体一个字都没改** —— 空含量整行忽略、非数字整行忽略,判据原样。
//   变的只是那一对 `(metal, content)` 从哪里来:从前要靠下标把两条数组对起来,
//   现在它本来就在同一行里。**这个组件因此不再有「数组长度对不上」这个失败模式。**
//   ★ 这里【不是】进料那一侧的同名函数:那一个收 `Record<metal, content>`,
//     而且还有第二个调用方(预览),所以那一个的签名刻意没动。两个文件各一份,
//     是 `DRAFT-0` 就记着的刻意重复,不要顺手合并。
function metalsPayload(lines: { metal: string; content: string }[]): { metal: string; content_pct: number }[] {
    const out: { metal: string; content_pct: number }[] = []
    lines.forEach(({ metal, content }) => {
        const s = (content ?? '').trim()
        if (s === '') return
        const n = Number(s)
        if (Number.isNaN(n)) return
        out.push({ metal, content_pct: n })
    })
    return out
}

/** 桥 → 行。⚠ **读不懂的桥不当空集** —— 那是一次说不出话的提交,不是「没测」。 */
function parseMetalLines(raw: string): { metal: string; content: string }[] | null {
    let parsed: unknown
    try {
        parsed = JSON.parse(raw)
    } catch {
        return null
    }
    if (!Array.isArray(parsed)) return null
    const out: { metal: string; content: string }[] = []
    for (const el of parsed) {
        if (el === null || typeof el !== 'object') continue
        const row = el as { metal?: unknown; content?: unknown }
        const metal = String(row.metal ?? '')
        if (metal === '') continue
        out.push({ metal, content: String(row.content ?? '') })
    }
    return out
}

// 记录产出化验(intent='record_apply' 时顺带应用)。
// 【记录与应用是两次独立的 RPC,因此是两个独立事务】—— 记录一旦成功就已经落库,
// 应用失败也不会把它带走(化验单是实验室出的客观事实);失败带着错误跳详情页。
export async function submitOutputAssay(
    batchId: string,
    _prevState: SubmitOutputAssayState,
    formData: FormData
): Promise<SubmitOutputAssayState> {
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

    const metalLines = parseMetalLines(String(formData.get('assay_metals_json') ?? '[]'))
    if (metalLines === null) return { error: t('assay.errors.NO_METALS') }
    const payload = metalsPayload(metalLines)
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
    // 共享的记录器,父给产出批(两个父都在默认值区,记谁给谁;XOR 由库把门)
    const { data, error } = await supabase.rpc('record_assay_result', {
        p_output_batch_id: batchId,
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

    let applyError = ''
    if (intent === 'record_apply') {
        const { error: applyErr } = await supabase.rpc('apply_output_assay', {
            p_assay_result_id: assayId,
        })
        if (applyErr) applyError = applyErr.message
    }

    revalidatePath('/output')
    revalidatePath(`/output/${batchId}/edit`)
    revalidatePath('/operation/processing')   // 过期旗在加工单上

    redirect(
        `/output/${batchId}/assays/${assayId}` +
            (applyError ? `?apply_error=${encodeURIComponent(applyError)}` : '')
    )
}

// 详情页的"立即应用"
export async function applyOutputAssayAction(
    assayId: string,
    batchId: string
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('apply_output_assay', {
        p_assay_result_id: assayId,
    })
    if (error) return { error: await localizeAssayError(error.message) }

    revalidatePath('/output')
    revalidatePath(`/output/${batchId}/edit`)
    revalidatePath(`/output/${batchId}/assays/${assayId}`)
    revalidatePath('/operation/processing')   // 过期旗在加工单上
    return {}
}

// 撤销应用:共享的 DB 函数(链按父各自成链);【不回含量】—— 控件里挂着提醒
export async function unapplyOutputAssayAction(
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

    revalidatePath('/output')
    revalidatePath(`/output/${batchId}/edit`)
    revalidatePath(`/output/${batchId}/assays/${assayId}`)
    return {}
}
