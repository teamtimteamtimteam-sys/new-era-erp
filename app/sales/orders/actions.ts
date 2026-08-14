'use server'

import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { mustRows } from '@/lib/db-helpers'
import { localizeSalesOrderError } from './salesOrderErrorCodes'
import { localizeInvoiceError } from '@/app/finance/invoiceErrorCodes'

export type OrderFormState = { error?: string; fieldErrors?: Record<string, string> }

type LineInput = { material_id: string; quantity: number; unit_price: number }

export async function createSalesOrder(
    _prev: OrderFormState,
    formData: FormData
): Promise<OrderFormState> {
    const t = await getTranslations()
    const customer_id = (formData.get('customer_id') as string) || ''
    // 【订单日永不默认】物理事件日:补一个 CURRENT_DATE 会让留空比填对更容易通过
    const order_date = (formData.get('order_date') as string)?.trim() || null
    const currency = (formData.get('currency') as string)?.trim() || ''
    const fx_raw = (formData.get('fx_rate') as string)?.trim() || ''
    const notes = (formData.get('notes') as string)?.trim() || null

    const fieldErrors: Record<string, string> = {}
    if (!customer_id) fieldErrors.customer_id = t('sales.form.errCustomer')
    if (!order_date) fieldErrors.order_date = t('sales.form.errOrderDate')
    if (!currency) fieldErrors.currency = t('sales.form.errCurrency')
    // 【汇率没有默认值 —— FIN-35】假设出来的 1:1 在非本位币单据上永远是错的
    const fx = Number(fx_raw)
    if (!fx_raw || Number.isNaN(fx) || fx <= 0) fieldErrors.fx_rate = t('sales.form.errFxRate')

    const lines: LineInput[] = []
    for (let i = 0; i < 20; i++) {
        const m = (formData.get(`line_material_${i}`) as string) || ''
        const q = (formData.get(`line_qty_${i}`) as string) || ''
        const p = (formData.get(`line_price_${i}`) as string) || ''
        if (!m && !q && !p) continue
        const qn = Number(q), pn = Number(p)
        if (!m || Number.isNaN(qn) || qn <= 0 || Number.isNaN(pn) || pn <= 0) {
            fieldErrors.lines = t('sales.form.errLine')
            continue
        }
        lines.push({ material_id: m, quantity: qn, unit_price: pn })
    }
    if (lines.length === 0) fieldErrors.lines = t('sales.form.errNoLines')
    if (Object.keys(fieldErrors).length > 0) return { fieldErrors }
    // 到这里 order_date 必非空(上面的校验分支已经 return),但 TS narrow 不到。
    // 【显式收窄而不是 as】—— 强转会把"其实可能为空"这件事藏起来,而这一行是
    // 进数据库之前的最后一道(与 inbound/output 那两处同一条)。
    if (order_date === null) return { fieldErrors: { order_date: t('sales.form.errOrderDate') } }

    // ══════════════════════════════════════════════════════════════════════
    // SO-2b:【建单只有一扇门】create_sales_order —— 单头、单行、'created' 留痕
    // 在同一个事务里写完。此前这里是三条客户端直插,而第三条(留痕)没有 INSERT
    // 策略、被 RLS 拒、返回值又没被解构 —— 于是线上 SO-2026-0001 从来没有
    // created 那一行,而且没有任何东西报过错。
    // 【所以这里不是加一句 if (error) throw】那只是把同一个形状再赌一次:
    // 三张表要么全写成、要么一张都不写,这条错误才不可能再发生。
    // 编号也搬进函数里 —— 取号与建单之间不该有一个"取到了号但没建成单"的缝。
    // ══════════════════════════════════════════════════════════════════════
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('create_sales_order', {
        p_customer_id: customer_id,
        p_order_date: order_date,
        p_currency: currency,
        p_fx_rate: fx,
        p_lines: lines,
        ...(notes ? { p_notes: notes } : {}),
    })
    if (error) return { error: await localizeSalesOrderError(error.message) }
    const orderId = (data as { id: string } | null)?.id
    // 【失败不是空集】RPC 成功却没带回 id,是一件不该发生的事;把它当成"建成了"
    // 会把人重定向到 /sales/orders/undefined,那正是 IOD-2 那次 [object Object] 的形状。
    if (!orderId) return { error: t('sales.form.saveError', { message: 'create_sales_order returned no id' }) }

    revalidatePath('/sales/orders')
    redirect(`/sales/orders/${orderId}`)
}

export async function transitionOrder(orderId: string, to: string, reason: string): Promise<OrderFormState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('set_sales_order_status', {
        p_order_id: orderId, p_to: to,
        ...(reason.trim() === '' ? {} : { p_reason: reason.trim() }),
    })
    if (error) return { error: await localizeSalesOrderError(error.message) }
    revalidatePath(`/sales/orders/${orderId}`)
    revalidatePath('/sales/orders')
    return {}
}

// ════════════════════════════════════════════════════════════════════════════
// SO-2:预留 / 释放
//
// 【页面不算库存】能预留多少、还剩多少,全部由 reserve_stock 决定,这里只转达。
// 页面上那个"可用 590"只是【上一次渲染时】的快照,拿它做判断就会与服务端漂开
// (与 stockActions.ts 抬头同一条)。
// ════════════════════════════════════════════════════════════════════════════
export type ReserveState = { error?: string }

export async function reserveForLine(
    orderId: string,
    lineId: string,
    outputBatchId: string,
    locationId: string | null,
    qty: string
): Promise<ReserveState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('reserve_stock', {
        p_sales_order_line_id: lineId,
        p_output_batch_id: outputBatchId,
        p_qty: Number(qty),
        // 【库位可空,不传就是 NULL】—— "未指定库位"是一等状态,不是缺失
        ...(locationId ? { p_location_id: locationId } : {}),
    })
    if (error) return { error: await localizeSalesOrderError(error.message) }
    revalidatePath(`/sales/orders/${orderId}`)
    revalidatePath('/inventory')
    revalidatePath(`/output/${outputBatchId}/edit`)
    return {}
}

export async function releaseReservation(
    orderId: string,
    reservationId: string,
    outputBatchId: string,
    qty: string,
    reason: string
): Promise<ReserveState> {
    const supabase = await createClient()
    const trimmedQty = qty.trim()
    const { error } = await supabase.rpc('release_reservation', {
        p_reservation_id: reservationId,
        // 【空 = 整笔释放】,而不是 0 —— 空着不是"释放零",服务端的默认值就是全部
        ...(trimmedQty === '' ? {} : { p_qty: Number(trimmedQty) }),
        p_reason: reason,
    })
    if (error) return { error: await localizeSalesOrderError(error.message) }
    revalidatePath(`/sales/orders/${orderId}`)
    revalidatePath('/inventory')
    revalidatePath(`/output/${outputBatchId}/edit`)
    return {}
}

// ════════════════════════════════════════════════════════════════════════════
// SO-3a:订单流开票 —— 发票在开票当刻过账(借 1100 / 贷 2500,按订单抄来的汇率)。
// 【错误走发票那一族】:抛错的是 create_order_invoice(发票函数),它的码
// (含 CREDIT_* / INVOICE_DATE_REQUIRED / SO_INVOICE_*)都登记在
// INVOICE_ERROR_CODES 里 —— 判据只有一份,不在这里手挑。
// ════════════════════════════════════════════════════════════════════════════
export async function createOrderInvoice(orderId: string, issueDate: string): Promise<ReserveState> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('create_order_invoice', {
        p_sales_order_id: orderId,
        // 【空串不是日期】空着交上来就让服务端按名拒(INVOICE_DATE_REQUIRED)——
        // 不在这里补一个今天。类型上该参数必填,所以空串经 null 断言递入。
        p_issue_date: (issueDate.trim() === '' ? null : issueDate) as unknown as string,
    })
    if (error) return { error: await localizeInvoiceError(error.message) }
    // 【失败不是空集】RPC 成功却没带回 id,不该被当成"开成了"
    if (!(data as { invoice_id?: string } | null)?.invoice_id) {
        return { error: 'create_order_invoice returned no id' }
    }
    revalidatePath(`/sales/orders/${orderId}`)
    revalidatePath('/finance/invoices')
    revalidatePath('/finance/receivables')
    return {}
}

// ════════════════════════════════════════════════════════════════════════════
// SO-3b:发货 —— 选项 C 的第二半(借 2500 释放负债 / 贷 4000 收入 + COGS)。
// 【错误走销售那一族】抛错的是 ship_order,它的码登记在 SALES_ORDER_ERROR_CODES;
// 而"这一行还没开票"那条(SO_SHIP_NOT_INVOICED)也在那里 —— 判据是"抛错的函数
// 属于哪一族",不是码里带不带 INVOICE 字样。
// ════════════════════════════════════════════════════════════════════════════
export async function shipOrderLine(
    orderId: string,
    reservationId: string,
    qty: string,
    shipDate: string
): Promise<ReserveState> {
    const supabase = await createClient()
    const trimmed = qty.trim()
    const { error } = await supabase.rpc('ship_order', {
        p_sales_order_id: orderId,
        // 【空串不是日期】空着就让服务端按名拒(SHIP_DATE_REQUIRED)
        p_ship_date: (shipDate.trim() === '' ? null : shipDate) as unknown as string,
        // 【数量留空 = 整条预留】—— 不传 qty,函数就整条消耗
        p_lines: [
            trimmed === ''
                ? { reservation_id: reservationId }
                : { reservation_id: reservationId, qty: Number(trimmed) },
        ],
    })
    if (error) return { error: await localizeSalesOrderError(error.message) }
    revalidatePath(`/sales/orders/${orderId}`)
    revalidatePath('/inventory')
    revalidatePath('/finance/receivables')
    return {}
}

export async function listCustomersAndMaterials() {
    const supabase = await createClient()
    const customers = mustRows(
        await supabase.from('customers').select('id, code, legal_name').is('deleted_at', null).order('code'),
        'customers')
    const materials = mustRows(
        await supabase.from('materials').select('id, code, name').is('deleted_at', null).order('code'),
        'materials')
    const currencies = mustRows(await supabase.from('currencies').select('code').order('code'), 'currencies')
    return { customers, materials, currencies }
}
