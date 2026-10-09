import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'
import { refusePermission } from '@/lib/action-refusal'
import { localizeSelfApproval } from '@/lib/selfApproval'
import { localizeProcessingError } from '../errorCodes'

// MES-5b-3(2026-10-09,MES-5b Step 0 Q17–Q20):配料计划的拒绝 → 人话。
//   ① 计划自己的函数(create / amend / release / cancel / execute_blending_plan · blending_plan_write_children)按名抛的码:`CODE|参数0|…`;
//   ② 执行那一支经 commit_processing_run 抛的码(称重、开始 / 结束 / 班次、余量、安全状态……)—— 不在这里另写一份,交给加工那一支的映射;
//   ③ SELF_APPROVAL_FORBIDDEN(建单人放行)与 PERMISSION_DENIED 是横跨所有模块的那两句。
// 【加一条 = 来这里加一个名字】check-i18n 的 blending.errors.* 后缀集合现读下面这个 Set,漏了句子 npm run build 当场红。
const BLENDING_ERROR_CODES = new Set([
    'BLEND_NO_OTHER_RELEASER', 'BLEND_PLAN_NOT_FOUND', 'BLEND_PLAN_NOT_DRAFT', 'BLEND_PLAN_NOT_RELEASED', 'BLEND_PLAN_NOT_CANCELLABLE',
    'BLEND_PLAN_NO_TARGETS', 'BLEND_NO_LINES', 'BLEND_CANCEL_REASON_REQUIRED',
    'BLEND_OUTPUT_NOT_SALEABLE', 'BLEND_OUTPUT_FORM_NOT_BLENDABLE', 'BLEND_CONTRACT_NOT_FOUND',
    'BLEND_TARGETS_INVALID', 'BLEND_TARGET_SPEC_NOT_FROM_CONTRACT', 'BLEND_TARGET_SPEC_OTHER_MATERIAL', 'BLEND_TARGET_DUPLICATE_METAL',
    'BLEND_TARGET_NEEDS_A_BOUND', 'BLEND_TARGET_PCT_INVALID', 'BLEND_TARGET_BOUNDS_ORDER',
    'BLEND_LINE_ONE_BATCH', 'BLEND_LINE_UNIT_NOT_KG', 'BLEND_LINE_FORM_NOT_BLENDABLE', 'BLEND_LINE_KG_INVALID', 'BLEND_LINE_DUPLICATE_BATCH',
    'BLEND_ACTUAL_LINES_MISMATCH', 'BLEND_ACTUAL_KG_INVALID', 'BLEND_ACTUAL_NOTHING_FED', 'BLEND_RUN_FROM_PLAN_ONLY',
    'BLEND_CONTENT_FROM_ASSAY_ONLY', 'MATERIAL_NOT_FOUND', 'METAL_INVALID', 'OUTPUT_NOT_FOUND',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeBlendingError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    if (match && match[1] === 'SELF_APPROVAL_FORBIDDEN') {
        return await localizeSelfApproval((match[2] ?? '').split('|')[0] || null)
    }
    if (match && match[1] === 'PERMISSION_DENIED') {
        return (await refusePermission(match[2] ?? '')).error
    }
    if (!match || !BLENDING_ERROR_CODES.has(match[1])) {
        // 执行那一支经引擎抛的码:加工那一支的映射认得出就用它的句子,认不出它自己会落到共用兜底
        if (match) return await localizeProcessingError(raw)
        return await fallbackForRawError(raw, 'localizeBlendingError@app/operation/blending/blendingErrorCodes.ts')
    }
    const params: Record<string, string> = {}
    if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return (await getTranslations())('blending.errors.' + match[1], params)
}
