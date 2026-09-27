'use server'

// TERMS-EDIT-1(Tim 2026-09-27,grilling Q2 · Q5):合同详情页的写 —— 表头与七张条款表。
//
// ★【直连写,不经函数】(Q2)★ 七张表与表头各有写策略(action.contract_terms)、enforce_write_permission,
//   以及 APR-8 的冻结守卫(生效中 / 有在等的申请 / 到期 / 终止 → 按名拒)。守卫以调用者身份跑,所以直连写
//   已经被守住了 —— 与 APR-10 关掉的采购单直连写不是一回事。这里先在字段旁边拒一次(termSpecs.ts 的范围),
//   然后让库作最后的回答,再把那一句翻译成人话(约束名 → contractErrorCodes;守卫的码 → termsRequestErrorCodes)。
// ★【零行不许报成功】★ UPDATE / DELETE 零行 = 被策略挡下或那一行已不在:refuseNothingChanged 按码说出是哪一种。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { refuseFromCoded, refuseNothingChanged } from '@/lib/action-refusal'
import { localizeContractError, isContractConstraintError } from '../contractErrorCodes'
import { localizeTermsRequestError } from '@/app/components/pricing/termsRequestErrorCodes'
import { sectionSpec, HEADER_KINDS, type FieldSpec } from './termSpecs'

export type EditResult = {
    error?: string
    detail?: string
    fieldErrors?: Record<string, string>
}

/** 约束名与 RLS 那一句先认(合同那一份),其余交给条款申请那一份(守卫的码、权限、兜底) */
async function localizeTermWrite(message: string): Promise<string> {
    return isContractConstraintError(message) || /row-level security|42501/i.test(message ?? '')
        ? localizeContractError(message)
        : localizeTermsRequestError(message)
}

function refresh(contractId: string) {
    revalidatePath(`/contracts/${contractId}`)
    revalidatePath('/contracts')
}

type Translate = Awaited<ReturnType<typeof getTranslations>>

/** 按 termSpecs 取一格;返回 [值, 错误] */
function readField(f: FieldSpec, formData: FormData, t: Translate): [string | number | boolean | null, string | null] {
    const raw = ((formData.get(f.name) as string | null) ?? '').trim()
    if (raw === '') {
        return [null, f.required ? t('contractDetail.fieldRequired') : null]
    }
    switch (f.type) {
        case 'text':
        case 'textarea':
            return [raw, null]
        case 'boolean':
            if (raw !== 'true' && raw !== 'false') return [null, t('contractDetail.fieldChoice')]
            return [raw === 'true', null]
        case 'select':
            if (f.options?.kind === 'enum' && !f.options.values.includes(raw)) {
                return [null, t('contractDetail.fieldChoice')]
            }
            return [raw, null]
        case 'number':
        case 'integer': {
            const n = Number(raw)
            if (!Number.isFinite(n) || (f.type === 'integer' && !Number.isInteger(n))) {
                return [null, t(f.type === 'integer' ? 'contractDetail.fieldWhole' : 'contractDetail.fieldNumber')]
            }
            const low = f.min !== undefined && (f.minExclusive ? n <= f.min : n < f.min)
            const high = f.max !== undefined && n > f.max
            if (low || high) {
                const key = f.max === undefined
                    ? (f.minExclusive ? 'contractDetail.fieldAbove' : 'contractDetail.fieldAtLeast')
                    : (f.minExclusive ? 'contractDetail.fieldRangeAbove' : 'contractDetail.fieldRange')
                return [null, t(key, { min: String(f.min ?? 0), max: String(f.max ?? '') })]
            }
            return [n, null]
        }
    }
}

export async function saveTermRow(
    contractId: string, table: string, rowId: string | null, formData: FormData,
): Promise<EditResult> {
    const spec = sectionSpec(table)
    const t = await getTranslations()
    if (!spec) return { error: t('contractDetail.unknownSection') }

    const values: Record<string, string | number | boolean | null> = {}
    const fieldErrors: Record<string, string> = {}
    for (const f of spec.fields) {
        const [v, err] = readField(f, formData, t)
        if (err) fieldErrors[f.name] = err
        values[f.name] = v
    }
    if (Object.keys(fieldErrors).length > 0) return { fieldErrors }

    const supabase = await createClient()
    // 表名来自 termSpecs 的白名单(上面 sectionSpec 已经认过),不是来自表单
    const from = supabase.from(spec.dbTable as 'contract_grade_specs')
    if (rowId === null) {
        const { error } = await from.insert({ ...values, contract_id: contractId } as never)
        if (error) return await refuseFromCoded(error.message, localizeTermWrite)
    } else {
        const { data, error } = await from.update(values as never)
            .eq('id', rowId).eq('contract_id', contractId).select('id')
        if (error) return await refuseFromCoded(error.message, localizeTermWrite)
        if (!data || data.length === 0) return await refuseNothingChanged('action.contract_terms')
    }
    refresh(contractId)
    return {}
}

export async function deleteTermRow(contractId: string, table: string, rowId: string): Promise<EditResult> {
    const spec = sectionSpec(table)
    if (!spec) return { error: (await getTranslations())('contractDetail.unknownSection') }
    const supabase = await createClient()
    const { data, error } = await supabase.from(spec.dbTable as 'contract_grade_specs')
        .delete().eq('id', rowId).eq('contract_id', contractId).select('id')
    if (error) return await refuseFromCoded(error.message, localizeTermWrite)
    if (!data || data.length === 0) return await refuseNothingChanged('action.contract_terms')
    refresh(contractId)
    return {}
}

// 表头(Q5):对手方与买卖方向不在这里 —— 建好之后定死,要换就另建一份。状态也不在这里:进 active 只经 CFO,
// 暂停在"让合同生效"那一块。
export async function saveContractHeader(contractId: string, formData: FormData): Promise<EditResult> {
    const t = await getTranslations()
    const s = (k: string) => ((formData.get(k) as string | null) ?? '').trim()
    const kind = s('kind')
    const title = s('title')
    const effective_from = s('effective_from')
    const effective_to = s('effective_to') || null
    const ptdRaw = s('payment_terms_days')

    const fieldErrors: Record<string, string> = {}
    if (!(HEADER_KINDS as readonly string[]).includes(kind)) fieldErrors.kind = t('contracts.errors.CONTRACT_KIND_INVALID')
    if (!title) fieldErrors.title = t('contracts.errors.CONTRACT_TITLE_REQUIRED')
    if (!effective_from) fieldErrors.effective_from = t('contracts.errors.CONTRACT_EFFECTIVE_FROM_REQUIRED')
    if (effective_to && effective_from && effective_to < effective_from) {
        fieldErrors.effective_to = t('contracts.errors.CONTRACT_PERIOD_ORDER')
    }
    let payment_terms_days: number | null = null
    if (ptdRaw !== '') {
        const n = Number(ptdRaw)
        if (!Number.isInteger(n) || n < 0 || n > 365) {
            fieldErrors.payment_terms_days = t('contracts.errors.CONTRACT_PAYMENT_TERMS_INVALID')
        } else {
            payment_terms_days = n
        }
    }
    if (Object.keys(fieldErrors).length > 0) return { fieldErrors }

    const supabase = await createClient()
    const { data, error } = await supabase.from('contracts')
        .update({
            kind, title, effective_from, effective_to,
            signed_on: s('signed_on') || null,
            currency: s('currency') || null,
            incoterm: s('incoterm') || null,
            payment_terms_days,
            document_ref: s('document_ref') || null,
            notes: s('notes') || null,
        })
        .eq('id', contractId)
        .select('id')
    if (error) return await refuseFromCoded(error.message, localizeTermWrite)
    if (!data || data.length === 0) return await refuseNothingChanged('action.contract_terms')
    refresh(contractId)
    return {}
}
