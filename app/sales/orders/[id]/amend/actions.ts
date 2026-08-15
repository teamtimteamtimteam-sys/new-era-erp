'use server'

// SO-1b:销售订单改单。判据、守卫与留痕全在 amend_sales_order 与触发器里 ——
// 页面【不自己判断能不能改】。理由与本仓库其它写入路径同一条:两份判断会在写下的
// 那天一致、此后各自漂移,而 RLS 今天就允许一条直连的 UPDATE 绕过页面(那条路
// 是有意留着的 —— 守卫必须挡得住它,而"挡得住"只有在路还通着时才证明得了)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { localizeSalesOrderError } from '../../salesOrderErrorCodes'

export type AmendState = { error?: string }

type LinePayload = {
    id?: string
    remove?: boolean
    quantity?: number | null
    unit_price?: number | null
    material_id?: string
}

export async function amendOrder(
    orderId: string,
    _prev: AmendState,
    formData: FormData
): Promise<AmendState> {
    const mode = String(formData.get('mode') ?? 'amend')
    const reason = String(formData.get('reason') ?? '').trim()

    // 并列数组:每一行的 id / 数量 / 单价 / 是否删除
    const ids = formData.getAll('line_id').map(String)
    const qtys = formData.getAll('line_quantity').map(String)
    const prices = formData.getAll('line_price').map(String)
    const removes = formData.getAll('line_remove').map(String)

    const lines: LinePayload[] = []
    // 【shipped 的单只许加行】—— 既有行一条都不递过去。递了会被服务端按名拒
    // (SO_NOT_AMENDABLE),而那是一次注定失败的提交:表单已经把它们画成只读了。
    if (mode !== 'addonly') {
        for (let i = 0; i < ids.length; i++) {
            if (removes[i] === '1') { lines.push({ id: ids[i], remove: true }); continue }
            lines.push({
                id: ids[i],
                quantity: qtys[i] ? Number(qtys[i]) : null,
                unit_price: (prices[i] ?? '').trim() === '' ? null : Number(prices[i]),
            })
        }
    }

    // 加行:空槽整槽跳过;填了一半的槽【原样递过去】,由 SO_AMEND_LINE_INVALID
    // 点名是哪一格 —— 在这里悄悄丢掉它,人会以为自己加过了(而屏幕上什么都没有)。
    for (let i = 0; i < 3; i++) {
        const m = String(formData.get(`new_material_${i}`) ?? '')
        const q = String(formData.get(`new_qty_${i}`) ?? '').trim()
        const p = String(formData.get(`new_price_${i}`) ?? '').trim()
        if (!m && !q && !p) continue
        lines.push({
            material_id: m,
            quantity: q === '' ? null : Number(q),
            unit_price: p === '' ? null : Number(p),
        })
    }

    const supabase = await createClient()
    const { error } = await supabase.rpc('amend_sales_order', {
        p_order_id: orderId,
        // 【理由不在这里兜底】草稿态服务端根本不要它;非草稿态空理由由 DB 点名拒
        // (SO_AMEND_REASON_REQUIRED)—— 一次改动没有理由,历史上就只是一行"数字变了"。
        p_reason: reason,
        // 【addonly:表头一个字都不递】amend_sales_order 见到 p_header 非空就拒,
        // 因为一张发完的单的条款已经履行完了。递一个"内容没变"的对象同样会被拒,
        // 而那会让页面看起来坏了。
        ...(mode === 'addonly' ? {} : {
            p_header: {
                notes: String(formData.get('notes') ?? '').trim(),
                terms_text: String(formData.get('terms_text') ?? '').trim(),
            },
        }),
        p_lines: lines,
    })

    if (error) return { error: await localizeSalesOrderError(error.message) }

    revalidatePath('/sales/orders')
    revalidatePath(`/sales/orders/${orderId}`)
    redirect(`/sales/orders/${orderId}`)
}
