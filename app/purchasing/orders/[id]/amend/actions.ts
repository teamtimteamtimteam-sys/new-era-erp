'use server'

// PUR-2:采购单修改。判据、守卫与留痕全在 amend_purchase_order 与触发器里 ——
// 页面【不自己判断能不能改】。理由与本仓库其它写入路径同一条:两份判断会在写下的
// 那天一致,此后各自漂移,而 RLS 今天就允许一条直连的 UPDATE 绕过页面。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { localizePurchasingError } from '../../../purchasingErrorCodes'
import { getTranslations } from '@/lib/i18n/server'

export type AmendState = { error?: string }

export async function amendOrder(
    poId: string,
    _prev: AmendState,
    formData: FormData
): Promise<AmendState> {
    const reason = String(formData.get('reason') ?? '').trim()
    const orderDate = String(formData.get('order_date') ?? '').trim()
    const expected = String(formData.get('expected_delivery_date') ?? '').trim()
    const incoterm = String(formData.get('incoterm') ?? '').trim()
    const notes = String(formData.get('notes') ?? '').trim()
    // PUR-1:交货地点。【空串要传下去,不能吞成 undefined】—— 清空它是一次
    // 正当的修改,而 DB 那一侧靠"键在不在"区分"不动它"与"清掉它"。
    const deliveryLocation = String(formData.get('delivery_location') ?? '').trim()

    // 并列数组:每一行的 id / 数量 / 单价 / 是否删除
    const ids = formData.getAll('line_id').map(String)
    const qtys = formData.getAll('line_quantity').map(String)
    const prices = formData.getAll('line_price').map(String)
    const removes = formData.getAll('line_remove').map(String)
    const priceStatuses = formData.getAll('line_price_status').map(String)

    const lines = ids.map((id, i) => {
        const remove = removes[i] === '1'
        if (remove) return { id, remove: true }
        return {
            id,
            quantity: qtys[i] ? Number(qtys[i]) : null,
            estimated_unit_price: (prices[i] ?? '').trim() === '' ? null : Number(prices[i]),
            // PUR-1:这一行的定价状态。空串 = 清回"按事实推导",而那与
            // "不动它"不是同一件事 —— 所以这个键【总是】送出去(表单上每一行
            // 都有这个下拉框,它的当前值就是这一行的答案)。
            price_status: (priceStatuses[i] ?? '').trim(),
        }
    })

    // ── PUR-1:付款计划 ─────────────────────────────────────────────────────
    // 【没有勾"同时修改付款计划"就不传这个参数】—— DB 那一侧 NULL = 不动它,
    // 空数组 = 把整份计划清掉。两者必须分得开:一次只想改数量的修改,
    // 不该顺手把付款计划抹了。
    const editTerms = String(formData.get('edit_terms') ?? '') === '1'
    let terms: Record<string, unknown>[] | null = null
    if (editTerms) {
        const labels = formData.getAll('term_label').map(String)
        const modes = formData.getAll('term_mode').map(String)
        const pcts = formData.getAll('term_percentage').map(String)
        const fixeds = formData.getAll('term_fixed').map(String)
        const events = formData.getAll('term_event').map(String)
        const dues = formData.getAll('term_due').map(String)
        // 【与建单那一侧【同一句话】】建单的 createOrder 对每一期做的正是这三条
        // 检查(标签非空、比例 0<n≤100、定额 >0),拒绝文案也是这一条。
        // 不抄过来,改单这条路会把一个空的比例送成 0,撞上表上那条
        // `percentage > 0`,而操作员拿到的是一句裸约束原文 —— 同一个错误,
        // 两条路两副面孔,正是 CMP-2 点名的那种缺陷。
        const t = await getTranslations()
        terms = []
        for (let i = 0; i < labels.length; i++) {
            const label = labels[i].trim()
            if (!label) return { error: t('purchasing.errTermLine', { 0: i + 1 }) }
            if (modes[i] === 'percentage') {
                const n = Number(pcts[i])
                if (!pcts[i] || Number.isNaN(n) || n <= 0 || n > 100) {
                    return { error: t('purchasing.errTermLine', { 0: i + 1 }) }
                }
                terms.push({ seq: i + 1, label, percentage: n, trigger_event: events[i],
                             ...(dues[i]?.trim() ? { due_date: dues[i] } : {}) })
            } else {
                const n = Number(fixeds[i])
                if (!fixeds[i] || Number.isNaN(n) || n <= 0) {
                    return { error: t('purchasing.errTermLine', { 0: i + 1 }) }
                }
                terms.push({ seq: i + 1, label, fixed_amount_ccy: n, trigger_event: events[i],
                             ...(dues[i]?.trim() ? { due_date: dues[i] } : {}) })
            }
        }
    }

    const supabase = await createClient()
    const { error } = await supabase.rpc('amend_purchase_order', {
        p_purchase_order_id: poId,
        // 【理由不在这里兜底】空的理由由 DB 点名拒(PO_AMEND_REASON_REQUIRED):
        // 一次改动没有理由,历史上就只是一行"数字变了"。
        p_reason: reason,
        p_header: {
            order_date: orderDate || undefined,
            expected_delivery_date: expected || null,
            incoterm: incoterm || null,
            notes: notes || null,
            // 【总是带这个键】空串在 DB 那一侧收成 NULL —— 也就是"清掉它"。
            delivery_location: deliveryLocation,
        },
        p_lines: lines,
        // 【不勾就传 null】—— null 与 [] 在 DB 那一侧是两件事(不动它 / 清空它)。
        p_payment_terms: terms as unknown as import('@/lib/database.types').Json,
    })

    if (error) return { error: await localizePurchasingError(error.message) }

    revalidatePath('/purchasing/orders')
    revalidatePath(`/purchasing/orders/${poId}`)
    redirect(`/purchasing/orders/${poId}`)
}
