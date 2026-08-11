'use server'

// PUR-2:采购单修改。判据、守卫与留痕全在 amend_purchase_order 与触发器里 ——
// 页面【不自己判断能不能改】。理由与本仓库其它写入路径同一条:两份判断会在写下的
// 那天一致,此后各自漂移,而 RLS 今天就允许一条直连的 UPDATE 绕过页面。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { localizePurchasingError } from '../../../purchasingErrorCodes'

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

    // 并列数组:每一行的 id / 数量 / 单价 / 是否删除
    const ids = formData.getAll('line_id').map(String)
    const qtys = formData.getAll('line_quantity').map(String)
    const prices = formData.getAll('line_price').map(String)
    const removes = formData.getAll('line_remove').map(String)

    const lines = ids.map((id, i) => {
        const remove = removes[i] === '1'
        if (remove) return { id, remove: true }
        return {
            id,
            quantity: qtys[i] ? Number(qtys[i]) : null,
            estimated_unit_price: (prices[i] ?? '').trim() === '' ? null : Number(prices[i]),
        }
    })

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
        },
        p_lines: lines,
    })

    if (error) return { error: await localizePurchasingError(error.message) }

    revalidatePath('/purchasing/orders')
    revalidatePath(`/purchasing/orders/${poId}`)
    redirect(`/purchasing/orders/${poId}`)
}
