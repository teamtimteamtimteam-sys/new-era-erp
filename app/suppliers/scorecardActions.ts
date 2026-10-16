'use server'

// MES-8a(2026-10-16,MES-8 Step 0 Q2 · Q4 · Q5 · Q6):供应商评分卡的三个动作 —— 预览一次评审会抄下什么、记一次评审、设定 V23 / V24。
//   门全在库里(supplier_scorecard_preview 查 module.suppliers.view;记评审与设定查 action.supplier_review);这里只把拒绝翻成人话。
//   预览与记评审调的是【同一支】库函数的两个入口(record_supplier_review 内部调 supplier_scorecard_preview)—— 表单显示的就是将要抄下的。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { refuseFromCoded, type ActionOutcome } from '@/lib/action-refusal'
import { localizeScorecardError } from './scorecardErrorCodes'
import type { ScorecardPreview, ScoreSettings } from './scorecardTypes'
import type { Json } from '@/lib/database.types'

export async function previewScorecard(supplierId: string, from: string, to: string):
    Promise<ActionOutcome & { preview?: ScorecardPreview }> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('supplier_scorecard_preview', {
        p_supplier_id: supplierId, p_from: from || (null as unknown as string), p_to: to || (null as unknown as string),
    })
    if (error) return await refuseFromCoded(error.message, localizeScorecardError)
    return { preview: data as unknown as ScorecardPreview }
}

export async function recordSupplierReview(input: {
    supplierId: string; from: string; to: string; note: string; correctsReviewId: string; correctionReason: string
}): Promise<ActionOutcome> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('record_supplier_review', {
        p_supplier_id: input.supplierId,
        // 窗口必填、不给默认 —— 空串送 null,由库按名拒(SCORECARD_WINDOW_REQUIRED)
        p_from: input.from || (null as unknown as string),
        p_to: input.to || (null as unknown as string),
        p_note: input.note || (null as unknown as string),
        p_corrects_review_id: input.correctsReviewId || (null as unknown as string),
        p_correction_reason: input.correctionReason || (null as unknown as string),
    })
    if (error) return await refuseFromCoded(error.message, localizeScorecardError)
    revalidatePath(`/suppliers/${input.supplierId}/edit`)
    revalidatePath('/suppliers/scorecards')
    return { success: true }
}

export async function saveScoreSettings(s: ScoreSettings): Promise<ActionOutcome> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('set_supplier_score_settings', {
        p_weights: s.weights as unknown as Json,
        p_grade_lines: s.grade_lines as unknown as Json,
        p_review_window_days: s.review_window_days as unknown as number,
        p_grade_caps: s.grade_caps as unknown as Json,
    })
    if (error) return await refuseFromCoded(error.message, localizeScorecardError)
    revalidatePath('/suppliers/scorecards')
    revalidatePath('/settings/pending-values')
    return { success: true }
}
