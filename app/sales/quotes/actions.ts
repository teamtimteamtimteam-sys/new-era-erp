'use server'

// SO-4b:报价的写入路径。
//
// 【建报价【走直连】,而这是 SO-4a 的设计,不是这里图省事】报价是谈判过程中的
// 东西:改价、改量、加一行、去一行本来就是它的用途,所以 draft/issued 的行
// 不上冻结守卫,RLS 直接放行 module.sales.edit。真正不能绕的两件事各有机制:
//   * 'created' 留痕由【触发器】保证(不靠哪扇门)——  SO-1 的建单就是在这里
//     栽的:留痕那条 insert 被 RLS 拒、错误被丢掉,线上 SO-2026-0001 至今缺着;
//   * 单号由【触发器】填(next_quote_code 对 authenticated 收权)。
// 转换、谢绝、签发三件事有【真正的判据】,所以它们各自是一个 RPC。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { localizeQuoteError } from './quoteErrorCodes'
import type { InsertRow } from '@/lib/db-helpers'

export type QuoteFormState = { error?: string; fieldErrors?: Record<string, string> }

type LineInput = { material_id: string; quantity: number; unit_price: number }

export async function createQuote(
    _prev: QuoteFormState,
    formData: FormData
): Promise<QuoteFormState> {
    const customer_id = String(formData.get('customer_id') ?? '')
    // 【两个日期永不默认】物理承诺日:补一个今天会让"留空"比"填对"更容易通过,
    // 而一个补出来的有效期永远不会在它该过期的那天过期。
    const quote_date = String(formData.get('quote_date') ?? '').trim()
    const valid_until = String(formData.get('valid_until') ?? '').trim()
    const currency = String(formData.get('currency') ?? '').trim()
    const fx_raw = String(formData.get('fx_rate') ?? '').trim()
    const notes = String(formData.get('notes') ?? '').trim()
    const terms = String(formData.get('terms_text') ?? '').trim()

    const t = await getTranslations()
    const fieldErrors: Record<string, string> = {}
    if (!customer_id) fieldErrors.customer_id = t('quotes.form.errCustomer')
    if (!quote_date) fieldErrors.quote_date = t('quotes.form.errQuoteDate')
    if (!valid_until) fieldErrors.valid_until = t('quotes.form.errValidUntil')
    if (quote_date && valid_until && valid_until < quote_date)
        fieldErrors.valid_until = t('quotes.form.errValidityWindow')
    if (!currency) fieldErrors.currency = t('quotes.form.errCurrency')
    // 【汇率没有默认值 —— FIN-35】假设出来的 1:1 在非本位币单据上永远是错的,
    // 而且看起来完全正常。
    const fx = Number(fx_raw)
    if (!fx_raw || Number.isNaN(fx) || fx <= 0) fieldErrors.fx_rate = t('quotes.form.errFxRate')

    const lines: LineInput[] = []
    for (let i = 0; i < 20; i++) {
        const m = String(formData.get(`line_material_${i}`) ?? '')
        const q = String(formData.get(`line_qty_${i}`) ?? '')
        const p = String(formData.get(`line_price_${i}`) ?? '')
        if (!m && !q && !p) continue
        const qn = Number(q), pn = Number(p)
        if (!m || Number.isNaN(qn) || qn <= 0 || Number.isNaN(pn) || pn <= 0) {
            fieldErrors.lines = t('quotes.form.errLine')
            continue
        }
        lines.push({ material_id: m, quantity: qn, unit_price: pn })
    }
    // 【至少一行,在写库【之前】判】一张没有行的报价签发出去就是一张空纸。
    // 这一条今天由本页把关,而不是由引擎 —— 见切次报告里点名的那处缺口。
    if (lines.length === 0) fieldErrors.lines = t('quotes.form.errNoLines')
    if (Object.keys(fieldErrors).length > 0) return { fieldErrors }

    const supabase = await createClient()
    const { data: head, error } = await supabase
        .from('quotes')
        .insert({
            customer_id, quote_date, valid_until, currency, fx_rate: fx,
            notes: notes || null, terms_text: terms || null,
            // 【code 不传,由触发器生成】next_quote_code 对 authenticated 收权,
            // 所以号根本不由客户端取(先例:customers 的建单同一个写法与同一个
            // as 断言 —— 见 lib/db-helpers.ts 的 InsertRow 注释)。
        } as InsertRow<'quotes'>)
        .select('id, code')
        .single()
    if (error) return { error: await localizeQuoteError(error.message) }
    const q = head as { id: string; code: string }

    const { error: lineErr } = await supabase.from('quote_lines').insert(
        lines.map((l, i) => ({ quote_id: q.id, line_no: i + 1, ...l }))
    )
    // 【明细写不进去时,单头已经在库里了 —— 说出来,不要假装没建】
    // PostgREST 没有跨语句事务,所以这两步不是原子的。把单号报出去,人至少
    // 找得到那张空报价并补上行;悄悄返回一个错误会让它变成一张没人知道的孤儿。
    if (lineErr) {
        return { error: `${q.code}: ${await localizeQuoteError(lineErr.message)}` }
    }

    revalidatePath('/sales/quotes')
    redirect(`/sales/quotes/${q.id}`)
}

// ── 报价【签发之后仍然改得动】—— 那正是它与订单的区别 ────────────────────────
export async function updateQuoteLine(
    quoteId: string, lineId: string, quantity: string, unitPrice: string
): Promise<QuoteFormState> {
    const qn = Number(quantity), pn = Number(unitPrice)
    if (Number.isNaN(qn) || qn <= 0 || Number.isNaN(pn) || pn <= 0)
        return { error: (await getTranslations())('quotes.form.errLine') }
    const supabase = await createClient()
    const { error } = await supabase.from('quote_lines')
        .update({ quantity: qn, unit_price: pn }).eq('id', lineId)
    if (error) return { error: await localizeQuoteError(error.message) }
    revalidatePath(`/sales/quotes/${quoteId}`)
    return {}
}

export async function removeQuoteLine(quoteId: string, lineId: string): Promise<QuoteFormState> {
    const supabase = await createClient()
    const { error } = await supabase.from('quote_lines').delete().eq('id', lineId)
    if (error) return { error: await localizeQuoteError(error.message) }
    revalidatePath(`/sales/quotes/${quoteId}`)
    return {}
}

export async function addQuoteLine(
    quoteId: string, materialId: string, quantity: string, unitPrice: string
): Promise<QuoteFormState> {
    const qn = Number(quantity), pn = Number(unitPrice)
    if (!materialId || Number.isNaN(qn) || qn <= 0 || Number.isNaN(pn) || pn <= 0)
        return { error: (await getTranslations())('quotes.form.errLine') }
    const supabase = await createClient()
    // 行号接着现有最大的往下走 —— UNIQUE (quote_id, line_no) 挡重复
    const { data: rows, error: readErr } = await supabase
        .from('quote_lines').select('line_no').eq('quote_id', quoteId)
        .order('line_no', { ascending: false }).limit(1)
    if (readErr) return { error: await localizeQuoteError(readErr.message) }
    const next = ((rows as { line_no: number }[] | null)?.[0]?.line_no ?? 0) + 1
    const { error } = await supabase.from('quote_lines').insert({
        quote_id: quoteId, line_no: next, material_id: materialId,
        quantity: qn, unit_price: pn,
    })
    if (error) return { error: await localizeQuoteError(error.message) }
    revalidatePath(`/sales/quotes/${quoteId}`)
    return {}
}

export async function updateQuoteHeader(
    quoteId: string, validUntil: string, notes: string, terms: string
): Promise<QuoteFormState> {
    // 【有效期空着不兜底】它是承诺日 —— 见 quotes.valid_until 的列注释。
    if (validUntil.trim() === '') return { error: (await getTranslations())('quotes.form.errValidUntil') }
    const supabase = await createClient()
    const { error } = await supabase.from('quotes')
        .update({ valid_until: validUntil, notes: notes.trim() || null,
                  terms_text: terms.trim() || null })
        .eq('id', quoteId)
    if (error) return { error: await localizeQuoteError(error.message) }
    revalidatePath(`/sales/quotes/${quoteId}`)
    return {}
}

// ── 三件有【真正判据】的事,各自一个 RPC ────────────────────────────────────
export async function convertQuote(quoteId: string, orderDate: string): Promise<QuoteFormState> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('convert_quote', {
        p_quote_id: quoteId,
        // 【空串不是日期】空着交上来就让服务端按名拒(ORDER_DATE_REQUIRED)——
        // 不在这里补一个今天。类型上该参数必填,所以空串经 null 断言递入
        // (与 create_order_invoice 的 p_issue_date 逐字同一个写法)。
        p_order_date: (orderDate.trim() === '' ? null : orderDate) as unknown as string,
    })
    if (error) return { error: await localizeQuoteError(error.message) }
    const orderId = (data as { sales_order_id?: string } | null)?.sales_order_id
    // 【失败不是空集】RPC 成功却没带回 id 是一件不该发生的事
    if (!orderId) return { error: 'convert_quote returned no sales order id' }
    revalidatePath(`/sales/quotes/${quoteId}`)
    revalidatePath('/sales/quotes')
    revalidatePath('/sales/orders')
    redirect(`/sales/orders/${orderId}`)
}

export async function declineQuote(quoteId: string, reason: string): Promise<QuoteFormState> {
    const supabase = await createClient()
    // 【理由不在这里兜底】空理由由 DB 按名拒(QT_DECLINE_REASON_REQUIRED):
    // 一张没有理由的谢绝,三个月后没有人说得出对方为什么没买。
    const { error } = await supabase.rpc('decline_quote', {
        p_quote_id: quoteId, p_reason: reason,
    })
    if (error) return { error: await localizeQuoteError(error.message) }
    revalidatePath(`/sales/quotes/${quoteId}`)
    revalidatePath('/sales/quotes')
    return {}
}
