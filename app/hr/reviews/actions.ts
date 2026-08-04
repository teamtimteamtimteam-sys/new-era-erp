'use server'

// 绩效评估的全部写入。每一条守卫都在 DB 函数或 RLS 里,这里不重复判断 ——
// 没权限的人写不进去,数据库会拒;这里只负责把错误码翻成人话、把页面刷新。
// 【直接写表的只有两处】HR 的决定列(probation_outcome / 薪酬两列)与评估轮的
// 建立/关闭 —— 它们本来就是 module.hr.edit 的 UPDATE/INSERT 策略在管,没有函数。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { localizeReviewError } from './reviewErrorCodes'
import { getTranslations } from '@/lib/i18n/server'

export type ReviewState = { error?: string; success?: boolean }

// 评估的读者分布在四个入口,写一次要把四处都刷掉;
// 评估人指派与试用期决定还会改变 /hr 的待办看板。
function revalidateReviewPaths(reviewId?: string) {
    revalidatePath('/hr')
    revalidatePath('/hr/reviews')
    revalidatePath('/hr/reviews/cycles')
    revalidatePath('/my-reviews')
    revalidatePath('/me')
    if (reviewId) {
        revalidatePath(`/hr/reviews/${reviewId}`)
        revalidatePath(`/my-reviews/${reviewId}`)
    }
}

// ── 目标行(评估人或 HR;draft)────────────────────────────────────────────
// 【target 与 unit 一起收】—— 没有单位的数字进不了库(review_goals_unit_required),
// 而且两条写实际值的路都补不了单位。表单把两个框摆在一起,这里把两个值一起递。
export async function addGoal(
    reviewId: string,
    objectiveText: string,
    targetValue: number | null,
    unit: string | null
): Promise<ReviewState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('add_review_goal', {
        p_review_id: reviewId,
        p_objective_text: objectiveText,
        p_target_value: targetValue ?? undefined,
        p_unit: unit ?? undefined,
    })
    if (error) return { error: await localizeReviewError(error.message) }
    revalidateReviewPaths(reviewId)
    return { success: true }
}

export async function updateGoal(
    reviewId: string,
    goalId: string,
    objectiveText: string,
    targetValue: number | null,
    unit: string | null
): Promise<ReviewState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('update_review_goal', {
        p_goal_id: goalId,
        p_objective_text: objectiveText,
        p_target_value: targetValue ?? undefined,
        p_unit: unit ?? undefined,
    })
    if (error) return { error: await localizeReviewError(error.message) }
    revalidateReviewPaths(reviewId)
    return { success: true }
}

export async function removeGoal(reviewId: string, goalId: string): Promise<ReviewState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('remove_review_goal', { p_goal_id: goalId })
    if (error) return { error: await localizeReviewError(error.message) }
    revalidateReviewPaths(reviewId)
    return { success: true }
}

export async function setGoalAssessment(
    reviewId: string,
    goalId: string,
    text: string
): Promise<ReviewState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('set_goal_assessment', {
        p_goal_id: goalId,
        p_reviewer_assessment_text: text,
    })
    if (error) return { error: await localizeReviewError(error.message) }
    revalidateReviewPaths(reviewId)
    return { success: true }
}

// draft / submitted 阶段由评估人或 HR 填实际值(自评阶段归本人,走 saveSelfAssessment)
export async function setGoalActual(
    reviewId: string,
    goalId: string,
    actualValue: number | null
): Promise<ReviewState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('set_goal_actual_value', {
        p_goal_id: goalId,
        p_actual_value: actualValue as unknown as number,
    })
    if (error) return { error: await localizeReviewError(error.message) }
    revalidateReviewPaths(reviewId)
    return { success: true }
}

// ── 结论(评估人或 HR;draft / self_review)─────────────────────────────────
export async function setConclusion(
    reviewId: string,
    ratingCode: string | null,
    summaryText: string | null
): Promise<ReviewState> {
    const supabase = await createClient()
    // 生成的类型不含 null,但 DB 函数显式接受 NULL(清空评级/结论)
    const { error } = await supabase.rpc('set_review_conclusion', {
        p_review_id: reviewId,
        p_rating_code: ratingCode as unknown as string,
        p_summary_text: summaryText as unknown as string,
    })
    if (error) return { error: await localizeReviewError(error.message) }
    revalidateReviewPaths(reviewId)
    return { success: true }
}

// ── 状态流 ───────────────────────────────────────────────────────────────────
export async function openSelfAssessment(reviewId: string): Promise<ReviewState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('open_for_self_assessment', { p_review_id: reviewId })
    if (error) return { error: await localizeReviewError(error.message) }
    revalidateReviewPaths(reviewId)
    return { success: true }
}

export async function submitReview(reviewId: string): Promise<ReviewState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('submit_review', { p_review_id: reviewId })
    if (error) return { error: await localizeReviewError(error.message) }
    revalidateReviewPaths(reviewId)
    return { success: true }
}

export async function approveReview(reviewId: string): Promise<ReviewState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('approve_review', { p_review_id: reviewId })
    if (error) return { error: await localizeReviewError(error.message) }
    revalidateReviewPaths(reviewId)
    return { success: true }
}

export async function voidReview(reviewId: string, reason: string): Promise<ReviewState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('void_review', {
        p_review_id: reviewId,
        p_reason: reason,
    })
    if (error) return { error: await localizeReviewError(error.message) }
    revalidateReviewPaths(reviewId)
    return { success: true }
}

// 只有被评估人本人能调(DB 里就是这么守的,HR 没有口子)
export async function acknowledgeReview(reviewId: string): Promise<ReviewState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('acknowledge_review', { p_review_id: reviewId })
    if (error) return { error: await localizeReviewError(error.message) }
    revalidateReviewPaths(reviewId)
    return { success: true }
}

// ── 自评(本人;self_review 且未定稿)───────────────────────────────────────
export async function saveSelfAssessment(
    reviewId: string,
    selfAssessmentText: string,
    goalResults: { goal_id: string; result_text?: string | null; actual_value?: number | null }[],
    final: boolean
): Promise<ReviewState> {
    // 【定稿不能是空的】save_self_assessment 是这一族里唯一没有 btrim = '' 守卫的写入
    // (对比 void_review 的 REASON_REQUIRED、submit_review 的 SUMMARY_REQUIRED)。
    // p_final 为真时会无条件盖上 self_assessment_submitted_at,此后任何再存都
    // SELF_ASSESSMENT_LOCKED —— 也就是【空白自评被永久锁死】,而评估人那一页因为
    // 提交时间非空照样显示"已提交",正文是 '' 又不是 null,连「—」都不会显示。
    // 存草稿仍允许留空,只有定稿要求有内容。
    if (final && selfAssessmentText.trim() === '') {
        return { error: (await getTranslations())('reviews.errSelfAssessmentEmpty') }
    }
    const supabase = await createClient()
    const { error } = await supabase.rpc('save_self_assessment', {
        p_review_id: reviewId,
        p_self_assessment_text: selfAssessmentText,
        p_goal_results: goalResults as unknown as undefined,
        p_final: final,
    })
    if (error) return { error: await localizeReviewError(error.message) }
    revalidateReviewPaths(reviewId)
    return { success: true }
}

// ── HR 的决定列:试用期结论与调薪(module.hr.edit 的 UPDATE 策略)────────────
// 【调薪两列要么都有、要么都空】(performance_reviews_salary_shape)。
// 表单把两个框摆在一起并一起提交,好让"填了工资忘了生效日"在离开屏幕之前就报出来。
export async function saveHrDecision(
    reviewId: string,
    decision: {
        probation_outcome?: string | null
        new_monthly_salary?: number | null
        salary_effective_date?: string | null
    }
): Promise<ReviewState> {
    const supabase = await createClient()
    const { error } = await supabase
        .from('performance_reviews')
        .update(decision)
        .eq('id', reviewId)
    if (error) return { error: await localizeReviewError(error.message) }
    revalidateReviewPaths(reviewId)
    return { success: true }
}

export async function setReviewer(
    reviewId: string,
    reviewerEmployeeId: string
): Promise<ReviewState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('set_review_reviewer', {
        p_review_id: reviewId,
        p_reviewer_employee_id: reviewerEmployeeId,
    })
    if (error) return { error: await localizeReviewError(error.message) }
    revalidateReviewPaths(reviewId)
    return { success: true }
}

// ── 评估轮 ───────────────────────────────────────────────────────────────────
export async function createCycle(cycle: {
    name: string
    period_start: string
    period_end: string
    due_date: string
    notes: string | null
}): Promise<ReviewState> {
    const supabase = await createClient()
    const { error } = await supabase.from('review_cycles').insert(cycle)
    if (error) return { error: await localizeReviewError(error.message) }
    revalidateReviewPaths()
    return { success: true }
}

export async function openCycle(cycleId: string): Promise<ReviewState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('open_review_cycle', { p_cycle_id: cycleId })
    if (error) return { error: await localizeReviewError(error.message) }
    revalidateReviewPaths()
    return { success: true }
}

// 关轮没有函数:它不铺单据、不改任何评估,只是把"这一轮结束了"记下来。
export async function closeCycle(cycleId: string): Promise<ReviewState> {
    const supabase = await createClient()
    const { error } = await supabase
        .from('review_cycles')
        .update({ status: 'closed' })
        .eq('id', cycleId)
    if (error) return { error: await localizeReviewError(error.message) }
    revalidateReviewPaths()
    return { success: true }
}
