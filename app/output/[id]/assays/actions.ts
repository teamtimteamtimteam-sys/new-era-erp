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
function metalsPayload(metalNames: string[], contents: string[]): { metal: string; content_pct: number }[] {
    const out: { metal: string; content_pct: number }[] = []
    metalNames.forEach((metal, i) => {
        const s = (contents[i] ?? '').trim()
        if (s === '') return
        const n = Number(s)
        if (Number.isNaN(n)) return
        out.push({ metal, content_pct: n })
    })
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

    const payload = metalsPayload(
        formData.getAll('assay_metal').map(String),
        formData.getAll('assay_content').map(String)
    )
    if (payload.length === 0) return { error: t('assay.errors.NO_METALS') }

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
    revalidatePath('/processing')   // 过期旗在加工单上

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
    revalidatePath('/processing')   // 过期旗在加工单上
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
