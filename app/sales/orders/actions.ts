'use server'

import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { mustRows } from '@/lib/db-helpers'
import { localizeSalesOrderError } from './salesOrderErrorCodes'

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

    const supabase = await createClient()
    const codeRes = await supabase.rpc('next_sales_order_code', { p_date: order_date })
    if (codeRes.error) return { error: t('sales.form.saveError', { message: codeRes.error.message }) }

    const ins = await supabase
        .from('sales_orders')
        .insert({ code: codeRes.data as string, customer_id, order_date, currency, fx_rate: fx, notes })
        .select('id')
        .single()
    if (ins.error || !ins.data) {
        return { error: await localizeSalesOrderError(ins.error?.message ?? '') }
    }
    const orderId = (ins.data as { id: string }).id

    const lineRows = lines.map((l, i) => ({ sales_order_id: orderId, line_no: i + 1, ...l }))
    const lineIns = await supabase.from('sales_order_lines').insert(lineRows)
    if (lineIns.error) return { error: await localizeSalesOrderError(lineIns.error.message) }

    await supabase.from('sales_order_history').insert({
        sales_order_id: orderId, change_type: 'created', detail: codeRes.data as string,
    })

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
