// app/sales/orders/[id]/amend/page.tsx
// SO-1b:改单(服务端壳)。
//
// 【这张页面上的每一个数字都是【动手之前】就该看得见的】CMP-2 的规矩:
// 禁用与说明要长在控件旁边,而不是等人保存之后由服务端拒绝。而销售订单行
// 被【三件不同的事】咬住,三件事的出路完全不同 —— 所以是三列,不是一句
// "这一行不能改":
//     已发     不可逆,硬下限(改到它以下就是宣称我们答应的比发出去的少)
//     已开票   可逆,但要先作废那张票;数量与单价整个冻住
//     已预留   可逆,而且解铃的人要留名 —— 页面只说数,绝不替人释放
//
// 【真正的把关仍在数据库】三条下限是触发器(guard_sales_order_line_floors),
// 五列身份字段是表头守卫。页面上的提示是【礼貌】,不是保护 —— 与采购单那张
// 改单页逐字同一条。
//
// 【已开票那一列有一个真实的权限缺口,写在屏幕上而不是藏起来】读发票要
// module.finance.view,而改单只要 module.sales.edit。撞上时显示「受限」,
// 【不能显示"未开票"】—— 后者是另一件事,而它会把人送去做一次注定被拒的修改。
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { mustRows, mustOne } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireEditPermission } from '@/app/components/moduleGuard'
import Subnav from '@/app/sales/Subnav'
import AmendOrderForm, { type AmendLine } from './AmendOrderForm'

export default async function AmendSalesOrderPage({ params }: { params: Promise<{ id: string }> }) {
    const denied = await requireEditPermission('module.sales.edit', 'nav.sales')
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()

    const order = mustOne(
        await supabase.from('sales_orders')
            .select('id, code, status, order_date, currency, fx_rate, notes, terms_text, customers ( code, legal_name )')
            .eq('id', id).is('deleted_at', null).maybeSingle(),
        'sales_orders')
    if (!order) notFound()
    const o = order as unknown as {
        id: string; code: string; status: string; order_date: string; currency: string
        fx_rate: number; notes: string | null; terms_text: string | null
        customers: { code: string; legal_name: string } | null }

    const lines = mustRows(
        await supabase.from('sales_order_lines')
            .select('id, line_no, quantity, unit_price, materials ( code, name, unit )')
            .eq('sales_order_id', id).order('line_no'),
        'sales_order_lines') as unknown as {
            id: string; line_no: number; quantity: number; unit_price: number
            materials: { code: string; name: string; unit: string } | null }[]
    const lineIds = lines.map((l) => l.id)

    // 已发:读 shipment_lines —— 【货真的离开了】的记录,与 line_spoken_for 同一个
    // 理由(consumed_at 只是预留的终局标记)。
    const shipLines = lineIds.length === 0 ? [] : (mustRows(
        await supabase.from('shipment_lines')
            .select('sales_order_line_id, qty, shipments ( code )')
            .in('sales_order_line_id', lineIds),
        'shipment_lines') as unknown as {
            sales_order_line_id: string; qty: number; shipments: { code: string } | null }[])

    // 已预留:【全部取回来,活的与过去的都要】
    //   * 活预留(released 与 consumed 都为空 —— SO-3b 起是两个条件)是软下限的那个数;
    //   * 【释放过的那些也要】—— 它们仍然是指着这一行的记录,而 SO-1b fu1 的
    //     SO_LINE_HAS_RECORD 正是为它们存在的:删行会销毁一条真发生过的记录。
    //     不取回来,这张页面就会给一条注定被拒的行摆一个可勾的删除框。
    const reservations = lineIds.length === 0 ? [] : (mustRows(
        await supabase.from('sales_order_reservations')
            .select('sales_order_line_id, qty, released_at, consumed_at')
            .in('sales_order_line_id', lineIds),
        'sales_order_reservations') as unknown as {
            sales_order_line_id: string; qty: number
            released_at: string | null; consumed_at: string | null }[])

    // 已开票:判据与 ship_order / 下限守卫逐字同一条 —— 在册未作废的行,
    // 坐在一张 kind='order' 且 status='issued' 的票上。
    const canSeeFinance = await can('module.finance.view')
    // 【作废了的发票行也取】—— 同上:它是一条留着供审计的记录,删行会毁掉它。
    const invLines = !canSeeFinance || lineIds.length === 0 ? [] : (mustRows(
        await supabase.from('invoice_lines_masked')
            .select('sales_order_line_id, invoice_id, quantity, invoice_voided')
            .in('sales_order_line_id', lineIds),
        'invoice_lines') as unknown as {
            sales_order_line_id: string | null; invoice_id: string; quantity: number
            invoice_voided: boolean }[])
    const liveInvoices = invLines.length === 0 ? [] : (mustRows(
        await supabase.from('invoices_masked')
            .select('id, code')
            .in('id', [...new Set(invLines.filter((r) => !r.invoice_voided).map((r) => r.invoice_id))])
            .eq('kind', 'order').eq('status', 'issued'),
        'invoices') as unknown as { id: string; code: string }[])
    const invCodeById = new Map(liveInvoices.map((i) => [i.id, i.code]))

    const shippedBy = new Map<string, number>()
    const shipCodeBy = new Map<string, string>()
    for (const s of shipLines) {
        shippedBy.set(s.sales_order_line_id, (shippedBy.get(s.sales_order_line_id) ?? 0) + Number(s.qty))
        if (s.shipments?.code) shipCodeBy.set(s.sales_order_line_id, s.shipments.code)
    }
    const reservedBy = new Map<string, number>()
    // 【有过去的行】—— 与守卫数的是同一批表(这里少了 sales_records,而它只与
    // 发货同生:已发 > 0 的行早就被上面那条挡住了,所以布尔值不会因此说错)。
    const recordCount = new Map<string, number>()
    const bump = (k: string) => recordCount.set(k, (recordCount.get(k) ?? 0) + 1)
    for (const r of reservations) {
        bump(r.sales_order_line_id)
        if (r.released_at !== null || r.consumed_at !== null) continue
        reservedBy.set(r.sales_order_line_id, (reservedBy.get(r.sales_order_line_id) ?? 0) + Number(r.qty))
    }
    for (const s of shipLines) bump(s.sales_order_line_id)
    const invoicedBy = new Map<string, { qty: number; code: string }>()
    for (const r of invLines) {
        if (!r.sales_order_line_id) continue
        bump(r.sales_order_line_id)
        const code = invCodeById.get(r.invoice_id)
        if (!code) continue                               // 作废的票 / 非订单流的票不算"已开票"
        const prev = invoicedBy.get(r.sales_order_line_id)
        invoicedBy.set(r.sales_order_line_id, {
            qty: (prev?.qty ?? 0) + Number(r.quantity), code: prev?.code ?? code })
    }

    const rows: AmendLine[] = lines.map((l) => ({
        id: l.id,
        line_no: l.line_no,
        material_code: l.materials?.code ?? '—',
        material_name: l.materials?.name ?? '',
        unit: l.materials?.unit ?? '',
        quantity: Number(l.quantity),
        unit_price: Number(l.unit_price),
        shipped: shippedBy.get(l.id) ?? 0,
        shipment_code: shipCodeBy.get(l.id) ?? null,
        reserved: reservedBy.get(l.id) ?? 0,
        invoiced: invoicedBy.get(l.id)?.qty ?? null,
        invoice_code: invoicedBy.get(l.id)?.code ?? null,
        has_record: (recordCount.get(l.id) ?? 0) > 0,
    }))

    const materials = mustRows(
        await supabase.from('materials').select('id, code, name')
            .is('deleted_at', null).order('code'),
        'materials') as unknown as { id: string; code: string; name: string }[]

    return (
        <>
            <Subnav />
            <div className="p-8">
                <AmendOrderForm
                    orderId={o.id}
                    code={o.code}
                    status={o.status}
                    currency={o.currency}
                    customerLabel={o.customers ? `${o.customers.code} — ${o.customers.legal_name}` : '—'}
                    orderDate={o.order_date}
                    fxRate={String(o.fx_rate)}
                    notes={o.notes ?? ''}
                    termsText={o.terms_text ?? ''}
                    lines={rows}
                    materials={materials}
                    canSeeInvoices={canSeeFinance}
                />
            </div>
        </>
    )
}
