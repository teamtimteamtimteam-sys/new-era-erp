// app/purchasing/orders/[id]/amend/page.tsx
// PUR-2:修改采购单(服务端壳)。
//
// 【为什么这张页面是这一刀里最不重要的一半】调查结论是:商业字段从来只是【够不着】
// (应用里没有这个按钮),不是【被保护】—— RLS 今天就允许一条直连的 UPDATE。
// 所以这一刀的实质是守卫,而这张表单只是把那条已经存在的路变得可见、可记录。
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { maskedRows } from '@/lib/maskedRows'
import type { Tables } from '@/lib/database.types'
import AmendOrderForm, { type AmendLine, type AmendTerm } from './AmendOrderForm'
import { requireEditPermission } from '@/app/components/moduleGuard'
import { applicableTriggers, loadPaymentTriggerEvents, type OrderKind } from '@/lib/paymentTriggers'

export default async function AmendOrderPage({ params }: { params: Promise<{ id: string }> }) {
    const denied = await requireEditPermission('module.purchasing.edit', 'nav.purchasing')
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const { data: po } = await supabase
        .from('purchase_orders_masked')
        .select('id, code, status, approval_status, order_date, expected_delivery_date, currency, incoterm, notes, delivery_location')
        .eq('id', id)
        .is('deleted_at', null)
        .maybeSingle()
    if (!po) notFound()

    const linesRaw = maskedRows<Tables<'purchase_order_lines'>, 'estimated_unit_price' | 'estimated_amount_ccy'>(
        mustRows(await supabase.from('purchase_order_lines_masked')
            .select('id, line_no, material_id, asset_id, quantity, unit, estimated_unit_price, pricing_formula_id, price_status')
            .eq('purchase_order_id', id).order('line_no'))
    )

    // 每一行【已收多少】—— 下限就在这里,表单把它写在行上,而不是等服务端拒绝之后
    // 才让人知道(CMP-2 的规矩:禁用/说明要在动作之前)。真正的把关仍在触发器上。
    const received = mustRows(
        await supabase.from('inbound_batches')
            .select('purchase_order_line_id, quantity')
            .eq('purchase_order_id', id).is('deleted_at', null),
        'inbound_batches'
    ) as { purchase_order_line_id: string | null; quantity: number }[]

    const receivedBy = new Map<string, number>()
    for (const r of received) {
        if (!r.purchase_order_line_id) continue
        receivedBy.set(r.purchase_order_line_id,
            (receivedBy.get(r.purchase_order_line_id) ?? 0) + Number(r.quantity))
    }

    const lines: AmendLine[] = linesRaw.map((l) => ({
        id: l.id as string,
        line_no: l.line_no as number,
        quantity: Number(l.quantity),
        unit: l.unit as string,
        estimated_unit_price: l.estimated_unit_price === null ? null : Number(l.estimated_unit_price),
        received: receivedBy.get(l.id as string) ?? 0,
        // PUR-1:这一行现在的定价状态选择,以及【它挂没挂公式】——
        // 后者决定表单要不要把 fixed 那一项禁掉(礼貌;把关在 DB 那道闸)。
        price_status: (l.price_status as 'fixed' | 'provisional' | null) ?? '',
        has_formula: l.pricing_formula_id !== null,
    }))

    // ── PUR-1:现在这份付款计划 ──────────────────────────────────────────────
    // 【读遮蔽视图】定额腿是钱(fixed_amount_ccy 随 data.view_prices 遮蔽),
    // 与本页读行单价走的是同一扇门。
    const termsRaw = maskedRows<Tables<'purchase_order_payment_terms'>, 'fixed_amount_ccy'>(
        mustRows(await supabase.from('purchase_order_payment_terms_masked')
            .select('seq, label, percentage, fixed_amount_ccy, trigger_event, due_date, notes')
            .eq('purchase_order_id', id).order('seq'))
    )
    const terms: AmendTerm[] = termsRaw.map((r) => ({
        seq: r.seq as number,
        label: (r.label as string) ?? '',
        mode: r.percentage !== null ? 'percentage' : 'fixed',
        percentage: r.percentage === null ? '' : String(r.percentage),
        fixed_amount: r.fixed_amount_ccy === null ? '' : String(r.fixed_amount_ccy),
        trigger_event: (r.trigger_event as string) ?? '',
        due_date: (r.due_date as string | null) ?? '',
    }))

    // 【这张单是材料单还是设备单】由它的行决定 —— purchase_orders 上没有类型列
    // (与建单那一侧逐字同一句话)。里程碑的可选清单跟着它走。
    const orderKind: OrderKind = linesRaw.some((l) => l.asset_id !== null) ? 'equipment' : 'material'
    const triggers = applicableTriggers(await loadPaymentTriggerEvents(supabase), orderKind)

    return (
        <div className="p-8">
            <AmendOrderForm
                poId={po.id as string}
                code={po.code as string}
                status={po.status as string}
                currency={po.currency as string}
                orderDate={po.order_date as string}
                expectedDelivery={(po.expected_delivery_date as string | null) ?? ''}
                incoterm={(po.incoterm as string | null) ?? ''}
                notes={(po.notes as string | null) ?? ''}
                deliveryLocation={(po.delivery_location as string | null) ?? ''}
                lines={lines}
                terms={terms}
                triggers={triggers}
            />
        </div>
    )
}
