'use server'

// 付款条款模板的增/改/软删。模板表是普通读写表(无 RPC、无不可变约束)——
// 表单数据在这里落库:新建 = 插头 + 插行;编辑 = 改头 + 删行重插(行无独立身份,
// 整份计划就是编辑单位);删除 = 置 deleted_at(套用过它的 PO 已持有行的副本,不受影响)。
// 行以 JSON 字段(lines_json)整体提交 —— 行里嵌着模式/触发事件/偏移天数,
// 并列数组会散架。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'

export type TemplateFormState = { error?: string }

export type TemplateLineInput = {
    label: string
    mode: 'percentage' | 'fixed'
    percentage: string
    fixed_amount: string
    trigger_event: string
    days_offset: string
}

const TRIGGERS = new Set(['on_order', 'on_shipment', 'on_arrival', 'post_assay', 'fixed_date'])

// 表单行 → 可插入的行(seq 按行序重排);非法处返回错误键(由调用方翻译)
function parseLines(raw: string):
    | { error: string; params?: Record<string, string | number> }
    | {
          rows: {
              seq: number
              label: string
              percentage: number | null
              fixed_amount_usd: number | null
              trigger_event: string
              days_offset: number | null
          }[]
      } {
    let parsed: TemplateLineInput[]
    try {
        parsed = JSON.parse(raw)
    } catch {
        return { error: 'purchasing.errTermLine', params: { 0: 1 } }
    }
    if (!Array.isArray(parsed) || parsed.length === 0) {
        return { error: 'purchasing.errNoTermLines' }
    }

    const rows = []
    let pctTotal = 0
    for (let i = 0; i < parsed.length; i++) {
        const l = parsed[i]
        const label = (l.label ?? '').trim()
        if (!label || !TRIGGERS.has(l.trigger_event)) {
            return { error: 'purchasing.errTermLine', params: { 0: i + 1 } }
        }
        let percentage: number | null = null
        let fixed: number | null = null
        if (l.mode === 'percentage') {
            const n = Number(l.percentage)
            if (!l.percentage || Number.isNaN(n) || n <= 0 || n > 100) {
                return { error: 'purchasing.errTermLine', params: { 0: i + 1 } }
            }
            percentage = n
            pctTotal += n
        } else {
            const n = Number(l.fixed_amount)
            if (!l.fixed_amount || Number.isNaN(n) || n <= 0) {
                return { error: 'purchasing.errTermLine', params: { 0: i + 1 } }
            }
            fixed = n
        }
        // 偏移天数只对 fixed_date 有意义;其余触发事件忽略输入
        let offset: number | null = null
        if (l.trigger_event === 'fixed_date') {
            const n = Number(l.days_offset)
            offset = l.days_offset !== '' && Number.isInteger(n) && n >= 0 ? n : 0
        }
        rows.push({
            seq: i + 1,
            label,
            percentage,
            fixed_amount_usd: fixed,
            trigger_event: l.trigger_event,
            days_offset: offset,
        })
    }
    if (pctTotal > 100) {
        return { error: 'purchasing.errors.TERMS_PCT_EXCEEDS', params: { 0: pctTotal } }
    }
    return { rows }
}

export async function saveTemplate(
    _prevState: TemplateFormState,
    formData: FormData
): Promise<TemplateFormState> {
    const t = await getTranslations()

    const id = String(formData.get('template_id') ?? '').trim()
    const name = String(formData.get('name') ?? '').trim()
    const description = String(formData.get('description') ?? '').trim()
    const isActive = formData.get('is_active') === 'on'

    if (!name) return { error: t('purchasing.errNameRequired') }

    const parsed = parseLines(String(formData.get('lines_json') ?? '[]'))
    if ('error' in parsed) return { error: t(parsed.error, parsed.params) }

    const supabase = await createClient()
    let templateId = id

    if (id) {
        const { error } = await supabase
            .from('payment_term_templates')
            .update({ name, description: description || null, is_active: isActive })
            .eq('id', id)
        if (error) {
            return {
                error: error.code === '23505' ? t('purchasing.errNameTaken', { 0: name }) : error.message,
            }
        }
        // 行无独立身份:整删重插(模板行仅被套用时读取,无外键指进来)
        const { error: delError } = await supabase
            .from('payment_term_template_lines')
            .delete()
            .eq('template_id', id)
        if (delError) return { error: delError.message }
    } else {
        const { data, error } = await supabase
            .from('payment_term_templates')
            .insert({ name, description: description || null, is_active: isActive })
            .select('id')
            .single()
        if (error || !data) {
            return {
                error:
                    error?.code === '23505'
                        ? t('purchasing.errNameTaken', { 0: name })
                        : (error?.message ?? 'insert failed'),
            }
        }
        templateId = data.id
    }

    const { error: lineError } = await supabase
        .from('payment_term_template_lines')
        .insert(parsed.rows.map((r) => ({ ...r, template_id: templateId })))
    if (lineError) return { error: lineError.message }

    revalidatePath('/purchasing/payment-terms')
    redirect('/purchasing/payment-terms')
}

export async function deleteTemplate(templateId: string): Promise<{ error?: string }> {
    const supabase = await createClient()
    // 软删:名字上的唯一性是 partial index(只看在册),删除后同名可重建。
    // 供应商的默认模板引用照旧指着这行 —— 套用时按"在册且启用"过滤,不会再被带出。
    const { error } = await supabase
        .from('payment_term_templates')
        .update({ deleted_at: new Date().toISOString() })
        .eq('id', templateId)
    if (error) return { error: error.message }
    revalidatePath('/purchasing/payment-terms')
    return {}
}
