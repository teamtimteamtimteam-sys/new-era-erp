// ★ APR-5b(Tim 2026-09-25,APR-5 grilling Q2–Q5 · 5b grilling Q2–Q4 · Q8 · Q10):订单的【发货放行】区。服务端组件。
//
// 【形状】cco 提一张放行,点名这张订单【已开票】、还没被放行覆盖的行(默认全部);CFO 批 ——
// 批准就是放行,仓库之后在 /logistics/shipping 照它发。一张订单同时只挂一张在等的;放行之后才开票的行
// 要它自己的放行;发票作废,那条发票行的覆盖自己失效。
//
// 【谁看得见什么】进得了这一页的人都持 module.sales.view,放行表的读策略就是它 —— 读不到只会是一次真的
// 失败(mustRows 抛)。CFO 决定时看的那一块(敞口、额度、冻结、收了多少、逐行毛利)经
// shipping_release_context(门 module.sales.view + data.view_prices)一次读出,只在有人要决定时读。
// 候选的发票行读 invoice_lines_masked(module.finance.view):读不到时不猜,提交交给库的默认
// (每一条已开票、未覆盖的行),并把这件事说出来。
import { createClient } from '@/lib/supabase/server'
import { mustRows, mustOne } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { getBaseCurrency } from '@/lib/currency'
import { formatAuditStamp } from '@/lib/dates'
import ShippingReleasePanel, { type ReleaseView, type ReleaseCandidate, type ReleaseContext } from './ShippingReleasePanel'

type RawRelease = {
    id: string; label: string; status: ReleaseView['status']; amount_base: number
    created_at: string; created_by: string; decided_at: string | null
    decision_notes: string | null; withdraw_reason: string | null
    shipping_release_lines: { sales_order_line_id: string; invoice_line_id: string }[] | null
}

export default async function ShippingReleaseSection({
    orderId,
    orderCode,
    status,
    lines,
}: {
    orderId: string
    orderCode: string
    status: string
    lines: { id: string; line_no: number; material_code: string; quantity: number; unit: string }[]
}) {
    const supabase = await createClient()
    const lineIds = lines.map((l) => l.id)
    const lineNo = new Map(lines.map((l) => [l.id, l.line_no]))

    const [canRaise, canDecide, canSeeFinance, baseCurrency] = await Promise.all([
        can('action.request_shipping_release'),
        can('data.view_prices'),
        can('module.finance.view'),
        getBaseCurrency(),
    ])

    const raw = mustRows(
        await supabase.from('shipping_releases')
            .select('id, label, status, amount_base, created_at, created_by, decided_at, decision_notes, withdraw_reason, shipping_release_lines ( sales_order_line_id, invoice_line_id )')
            .eq('sales_order_id', orderId)
            .order('created_at', { ascending: false }),
        'shipping_releases') as unknown as RawRelease[]

    // 这张订单此刻在册的发票行(订单流、未作废)—— 候选与"覆盖是否还成立"都从它出
    const liveInvoiceLines = !canSeeFinance || lineIds.length === 0
        ? null
        : (mustRows(
              await supabase.from('invoice_lines_masked')
                  .select('id, sales_order_line_id')
                  .in('sales_order_line_id', lineIds)
                  .eq('invoice_voided', false),
              'invoice_lines') as unknown as { id: string; sales_order_line_id: string }[])
    const liveSet = new Set((liveInvoiceLines ?? []).map((l) => l.id))
    const covered = new Set(
        raw.filter((r) => r.status === 'approved')
            .flatMap((r) => (r.shipping_release_lines ?? []).map((l) => l.invoice_line_id))
            .filter((id) => liveSet.has(id)))

    const candidates: ReleaseCandidate[] | null = liveInvoiceLines === null
        ? null
        : liveInvoiceLines
              .filter((il) => !covered.has(il.id))
              .map((il) => {
                  const l = lines.find((x) => x.id === il.sales_order_line_id)
                  return {
                      invoiceLineId: il.id,
                      lineNo: l?.line_no ?? 0,
                      label: l ? `#${l.line_no} ${l.material_code} · ${l.quantity} ${l.unit}` : '—',
                  }
              })
              .sort((a, b) => a.lineNo - b.lineNo)

    // 认证读不出来(error)时【不】猜"是不是提单人本人" —— 撤回钮退回只问提单码,库那一侧照样按人判。
    const { data: meData, error: meErr } = await supabase.auth.getUser()
    const myUserId = meErr ? null : (meData.user?.id ?? null)

    const views: ReleaseView[] = raw.map((r) => ({
        id: r.id,
        label: r.label,
        status: r.status,
        amountBase: Number(r.amount_base),
        createdText: formatAuditStamp(r.created_at),
        decidedText: r.decided_at ? formatAuditStamp(r.decided_at) : null,
        note: r.decision_notes ?? r.withdraw_reason,
        lines: (r.shipping_release_lines ?? [])
            .map((l) => ({
                lineNo: lineNo.get(l.sales_order_line_id) ?? 0,
                // 批准过、而那条发票行已经不在册(作废了)→ 这一条的覆盖已经失效(Q3);读不到发票时不下结论
                lapsed: r.status === 'approved' && liveInvoiceLines !== null && !liveSet.has(l.invoice_line_id),
            }))
            .sort((a, b) => a.lineNo - b.lineNo),
        raisedByMe: myUserId !== null && r.created_by === myUserId,
    }))
    const open = views.find((v) => v.status === 'submitted') ?? null
    const history = views.filter((v) => v.status !== 'submitted')

    // CFO 决定时看的那一块:只在有一张在等、而且读的人持那一对码时读
    const context = open && canDecide
        ? (mustOne(await supabase.rpc('shipping_release_context', { p_release_id: open.id }),
                   'shipping_release_context') as unknown as ReleaseContext | null)
        : null

    return (
        <ShippingReleasePanel
            orderId={orderId}
            orderCode={orderCode}
            shippable={status === 'confirmed' || status === 'partially_shipped'}
            candidates={candidates}
            open={open}
            history={history}
            context={context}
            canRaise={canRaise}
            canDecide={canDecide}
            canWithdraw={canRaise}
            baseCurrency={baseCurrency}
        />
    )
}
