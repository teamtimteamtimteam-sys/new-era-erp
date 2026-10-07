'use server'

// MES-3b(2026-10-07,MES-3b Step 0 Q6–Q8,Tim):打印页按下"打印" —— record_label_print 先记下这一次,页面再调打印。
//   函数做全部判断(种类 · 查看码 · 找得到 · 模板 · 份数 · 补印要理由),这里只把拒绝说成句子。
//   返回的是【记下来的那一份】数据:页面拿它画标签,于是印出去的与记下来的是同一份(Q8)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeLabelError } from './labelErrorCodes'
import type { LabelData } from './labelHtml'

export type LabelKind = 'inbound_batch' | 'output_batch' | 'storage_location'
export type LabelTemplateInfo = { code: string; name_en: string; name_zh: string; page_size: 'A6' | 'A5'; show_dg: boolean }
export type LabelContext = {
    data: LabelData
    template: LabelTemplateInfo
    qr_path: string
    prints_so_far: number
    next_is_reprint: boolean
    last_printed_at: string | null
    print_no?: number
    is_reprint?: boolean
    copies?: number
}

const PAGE_OF: Record<LabelKind, (id: string) => string> = {
    inbound_batch: (id) => `/inbound/${id}/edit`,
    output_batch: (id) => `/output/${id}/edit`,
    storage_location: (id) => `/inventory/locations/${id}/edit`,
}

export async function printLabel(kind: LabelKind, id: string, template: string, copies: string, reason: string)
    : Promise<{ error?: string; ctx?: LabelContext }> {
    const supabase = await createClient()
    const args: { p_kind: string; p_id: string; p_template?: string; p_copies?: number; p_reason?: string } = { p_kind: kind, p_id: id }
    if (template) args.p_template = template
    // 份数不是一个整数 → 交给函数按名拒(LABEL_COPIES_INVALID),不在这里悄悄改成 1
    if (copies.trim() !== '') args.p_copies = Number.isInteger(Number(copies)) ? Number(copies) : 0
    if (reason.trim() !== '') args.p_reason = reason
    const { data, error } = await supabase.rpc('record_label_print', args)
    if (error) return { error: await localizeLabelError(error.message) }
    revalidatePath(PAGE_OF[kind](id))
    return { ctx: data as unknown as LabelContext }
}
