// app/purchasing/orders/[id]/page.tsx
// 采购单详情:头卡(供应商/日期/币种/状态/审批)+ 明细行(含预计化验)+
// 付款计划(比例期按估算总额折成钱)+ 预付摘要(已付/已抵扣/未抵扣 → 登记付款入口)+
// 收货记录(关联进料批次、已收 vs 下单量)+ 取消(无收货且无已抵扣预付才允许)。
//
// CCY-1:【这一页换过一次币,中间没有分界线】。头卡写着「币种:USD @ 1.35」,
// 明细行、估算总额、付款计划都是它 —— 那几处不必每格重复,指着头卡就够。
// 但预付摘要(已预付/已抵扣/未抵扣)与收货表的「已抵扣」「未结」是 *_base,
// 【本位币】。它们要是也裸着,就成了指着一个与自己矛盾的抬头:头卡说 USD,
// 数字其实是 SGD。所以下半截一律带币种写出来。
import Link from 'next/link'
import { getBaseCurrency } from '@/lib/currency'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { formatAmount, formatMoneyBare, formatUnitCost } from '@/lib/format'
import Subnav from '../../Subnav'
import CancelOrderControl from './CancelOrderControl'
import { CloseOrderControl, ReopenOrderControl } from './CloseReopenControls'
import { can, canViewPrices } from '@/lib/permissions'
import { MaskedValue } from '@/app/components/MaskedValue'
import { maskedExcept, maskedRows } from '@/lib/maskedRows'
import type { Tables } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

type AssayEntry = { metal: string; content_pct: number }

const round2 = (n: number) => Math.round(n * 100) / 100

export default async function PurchaseOrderDetailPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.purchasing)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const t = await getTranslations()

    const { data: poRaw, error } = await supabase
        .from('purchase_orders_masked')
        .select('id, code, supplier_id, order_date, expected_delivery_date, currency, fx_rate, estimated_total_ccy, status, approval_status, incoterm, terms_text, notes, cancelled_at, cancel_reason')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    if (error || !poRaw) {
        notFound()
    }

    // cut 2b:改读遮蔽视图。fx_rate / estimated_total_ccy 会被遮蔽(没有 data.view_prices
    // 时为 null),其余列恢复基表类型 —— 视图带来的"人人可空"只是类型噪音。
    const showPrices = await canViewPrices()
    // OPS-14:预付三列与 ap_open_items 现在都挂 module.finance.view —— 没有它读到的是
    // NULL / 0 行,【那是"看不见",不是"没有"】。取一次权限码,才能把两者分开渲染。
    const canFinance = await can('module.finance.view')
    const po = maskedExcept<Tables<'purchase_orders'>, 'fx_rate' | 'estimated_total_ccy'>(poRaw)

    const [supplierRes, linesRes, termsRes, statusRes, receiptsRes, apprRes, issuesRes, historyRes] = await Promise.all([
        supabase.from('suppliers').select('id, legal_name').eq('id', po.supplier_id).single(),
        supabase
            .from('purchase_order_lines_masked')
            .select('id, line_no, material_id, quantity, unit, pricing_formula_id, estimated_unit_price, estimated_amount_ccy, expected_assay, notes, price_source, price_provenance')
            .eq('purchase_order_id', id)
            .order('line_no'),
        supabase
            .from('purchase_order_payment_terms_masked')
            .select('seq, label, percentage, fixed_amount_ccy, trigger_event, due_date')
            .eq('purchase_order_id', id)
            .order('seq'),
        // 已取消的单不在视图里 → 预付/进度区不展示
        supabase.from('purchase_order_status').select('*').eq('po_id', id).maybeSingle(),
        supabase
            .from('inbound_batches_masked')
            .select('id, code, arrival_date, quantity, unit, unit_price')
            .eq('purchase_order_id', id)
            .is('deleted_at', null)
            .order('created_at'),
        // APR-2c:审批是否生效。屏幕必须【说出来】—— 悄悄放行才是缺陷。
        supabase.rpc('approvals_enabled'),
        // PUR-1:签发档 —— 供应商手里那份是某个具体版本
        supabase.from('po_issues').select('version, issued_at, issued_by, sha256')
            .eq('purchase_order_id', id).order('version', { ascending: false }),
        // PUR-2:编辑史。最新一行的时点用来判断"已改、未重发"
        supabase.from('purchase_order_history')
            .select('id, change_type, line_no, amend_reason, changed_at, old_quantity, new_quantity, old_estimated_unit_price, new_estimated_unit_price, old_estimated_total_ccy, new_estimated_total_ccy')
            .eq('purchase_order_id', id).order('changed_at', { ascending: false }).limit(50),
    ])

    // APR-2c:审批是否生效 —— 决定这一页说哪一句话
    const approvalsOn = (apprRes.data as unknown as boolean | null) ?? false

    // PUR-2:【已改、未重发】。比较【最新一次签发】与【最新一条编辑史】的时点 ——
    // 修改不作废那次签发(它确实发出去过),但供应商手里那份已经不是现在这张单了。
    const history = mustRows(historyRes, 'purchase_order_history') as unknown as {
        id: string; change_type: string; line_no: number | null; amend_reason: string | null
        changed_at: string; old_quantity: number | null; new_quantity: number | null
        old_estimated_unit_price: number | null; new_estimated_unit_price: number | null
        old_estimated_total_ccy: number | null; new_estimated_total_ccy: number | null
    }[]
    const issues = mustRows(issuesRes, 'po_issues')
    const latestIssueVersion = issues.length ? Number(issues[0].version) : null
    const amendedSinceIssue =
        issues.length > 0 && history.length > 0 &&
        new Date(history[0].changed_at) > new Date(issues[0].issued_at as string)

    // 遮蔽的是估价列;material_id / pricing_formula_id 等恢复基表类型。
    const lines = maskedRows<Tables<'purchase_order_lines'>, 'estimated_unit_price' | 'estimated_amount_ccy'>(mustRows(linesRes))
    const terms = maskedRows<Tables<'purchase_order_payment_terms'>, 'fixed_amount_ccy'>(mustRows(termsRes))
    const poStatus = statusRes.data
    const receipts = maskedRows<Tables<'inbound_batches'>, 'unit_price'>(mustRows(receiptsRes))

    // 物料/公式名 + 收货批次的未结应付(结清的批次不在 ap_open_items → 敞口 0)
    const materialIds = Array.from(new Set(lines.map((l) => l.material_id)))
    const formulaIds = Array.from(new Set(lines.map((l) => l.pricing_formula_id).filter(Boolean))) as string[]
    const batchIds = receipts.map((r) => r.id)
    const [materialsRes, formulasRes, apRes] = await Promise.all([
        materialIds.length
            ? supabase.from('materials').select('id, code, name').in('id', materialIds)
            : Promise.resolve({ data: [] as { id: string; code: string; name: string }[], error: null }),
        formulaIds.length
            ? supabase.from('pricing_formulas').select('id, code, name').in('id', formulaIds)
            : Promise.resolve({ data: [] as { id: string; code: string; name: string }[], error: null }),
        batchIds.length
            ? supabase.from('ap_open_items').select('inbound_batch_id, open_base').in('inbound_batch_id', batchIds)
            : Promise.resolve({ data: [] as { inbound_batch_id: string | null; open_base: number }[], error: null }),
    ])
    const materialById = new Map((mustRows(materialsRes)).map((m) => [m.id, `${m.code} — ${m.name}`]))
    const formulaById = new Map((mustRows(formulasRes)).map((f) => [f.id, `${f.code} — ${f.name}`]))

    // FIN-27:这一行的结算条款是【下单时抄下来的】还是【还引着一张活公式】。
    // 存量行(FIN-27 之前下的单)没有副本,不回填 —— 画"未承诺",与 FIN-26 的
    // 灰色"出处未知"同一条规矩:编造的记录比缺失的记录更坏。
    const lineIds = lines.map((l) => l.id)
    const commitmentsRes = lineIds.length
        ? await supabase
              .from('pricing_term_commitments')
              .select('purchase_order_line_id, source_formula_code, committed_at')
              .in('purchase_order_line_id', lineIds)
        : { data: [] as { purchase_order_line_id: string | null; source_formula_code: string; committed_at: string }[], error: null }
    const commitmentByLine = new Map(
        (mustRows(commitmentsRes)).map((c) => [c.purchase_order_line_id ?? '', c])
    )
    const openByBatch = new Map((mustRows(apRes)).map((r) => [r.inbound_batch_id ?? '', r.open_base]))

    // 每批已抵扣的预付(cut 4c:收货记录多一列)
    const { data: appliedRows } = batchIds.length
        ? await supabase
              .from('prepayment_applications_masked')
              .select('inbound_batch_id, amount_base')
              .in('inbound_batch_id', batchIds)
        : { data: [] as { inbound_batch_id: string; amount_base: number }[] }
    const appliedByBatch = new Map<string, number>()
    for (const r of maskedRows<Tables<'prepayment_applications'>, 'amount_base'>(appliedRows)) {
        appliedByBatch.set(r.inbound_batch_id, round2((appliedByBatch.get(r.inbound_batch_id) ?? 0) + Number(r.amount_base)))
    }

    const isCancelled = po.status === 'cancelled'
    const receivedQty = poStatus?.received_qty ?? receipts.reduce((s, r) => s + Number(r.quantity), 0)
    const orderedQty = poStatus?.ordered_qty ?? lines.reduce((s, l) => s + Number(l.quantity), 0)
    const appliedUsd = Number(poStatus?.prepaid_applied_base ?? 0)
    // 取消的前置条件与 DB 的 cancel_purchase_order 一致:无收货、无已抵扣预付。
    // OPS-14:【没有财务模块就无从判断第二个条件】—— 读到的 NULL 不是 0。
    // 此时按"挡住"处理:服务端照样会拒,而摆一个注定被拒的按钮是本仓库明写的反面
    // (AGENTS.md《页面与服务端不一致》)。
    const cancelBlocked = receipts.length > 0 || appliedUsd > 0 || !canFinance

    const assayInline = (assay: unknown): string => {
        if (!Array.isArray(assay) || assay.length === 0) return ''
        return (assay as AssayEntry[])
            .map((a) => `${t('metals.' + a.metal)} ${a.content_pct}%`)
            .join(' · ')
    }

    const termAmount = (l: { percentage: number | null; fixed_amount_ccy: number | null }) =>
        l.percentage !== null
            ? round2((Number(po.estimated_total_ccy) * l.percentage) / 100)
            : Number(l.fixed_amount_ccy ?? 0)

    const statusPill = (
        <span
            className={
                'px-2 py-1 rounded text-xs ' +
                (po.status === 'confirmed' || po.status === 'receiving'
                    ? 'bg-green-100 text-green-800'
                    : po.status === 'closed'
                      ? 'bg-gray-200 text-gray-700'
                      : po.status === 'cancelled'
                        ? 'bg-red-100 text-red-700'
                        : 'bg-amber-100 text-amber-800')
            }
        >
            {t('purchasing.status.' + po.status)}
        </span>
    )

    return (
        <div className="p-8 max-w-5xl">
            <div className="mb-6">
                <Link href="/purchasing/orders" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <div className="flex justify-between items-start mb-2 gap-4">
                <h1 className="text-2xl font-bold">
                    {t('purchasing.orderDetailTitle')}
                    <span className="ml-3 font-mono text-base text-gray-500">{po.code}</span>
                </h1>
                <div className="flex flex-wrap items-center gap-3 justify-end">
                    {/* 按此单收货:只在可收货状态出现 */}
                    {(po.status === 'confirmed' || po.status === 'receiving') && (
                        <Link
                            href={`/inbound/new?po=${po.id}`}
                            className="bg-blue-600 text-white px-3 py-1.5 rounded hover:bg-blue-700 text-sm"
                        >
                            {t('purchasing.receiveAgainst')}
                        </Link>
                    )}
                    {(po.status === 'confirmed' || po.status === 'receiving') && (
                        <CloseOrderControl
                            poId={po.id}
                            unappliedPrepayment={canFinance ? Number(poStatus?.prepaid_remaining_base ?? 0) : null}
                            baseCurrency={baseCurrency}
                        />
                    )}
                    {/* PUR-2:修改入口。【已结束/已作废的不给】—— 服务端会拒,
                        不摆一个注定失败的按钮;要改就先 reopen,让状态变化成为
                        一次有记录的动作,而不是修改的副作用。
                        (动态路由的入口按 AGENTS.md 的规矩由人确认:走查不断言它。) */}
                    {po.status !== 'closed' && !isCancelled && (
                        <Link href={`/purchasing/orders/${po.id}/amend`}
                            className="border border-gray-300 px-3 py-1.5 rounded text-sm hover:bg-gray-50">
                            {t('purchasing.amend.link')}
                        </Link>
                    )}
                    {po.status === 'closed' && <ReopenOrderControl poId={po.id} />}
                    {!isCancelled &&
                        po.status !== 'closed' &&
                        (cancelBlocked ? (
                            <p className="text-sm text-gray-400">{t('purchasing.cancelBlocked')}</p>
                        ) : (
                            <CancelOrderControl poId={po.id} />
                        ))}
                </div>
            </div>

            <Subnav />

            {isCancelled && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4 text-sm">
                    {t('purchasing.status.cancelled')}
                    {po.cancelled_at ? ` · ${po.cancelled_at.slice(0, 10)}` : ''}
                    {po.cancel_reason ? `:${po.cancel_reason}` : ''}
                </div>
            )}

            {/* 头卡 */}
            <div className="bg-gray-50 rounded p-4 mb-6 flex flex-wrap gap-x-8 gap-y-2 text-sm items-center">
                <div>
                    <span className="text-gray-600 mr-1">{t('purchasing.colSupplier')}:</span>
                    <Link
                        href={`/suppliers/${po.supplier_id}/edit`}
                        className="text-blue-600 hover:underline"
                    >
                        {supplierRes.data?.legal_name ?? '—'}
                    </Link>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('purchasing.colOrderDate')}:</span>
                    <span>{po.order_date}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('purchasing.colExpectedDelivery')}:</span>
                    <span>{po.expected_delivery_date ?? '—'}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('purchasing.form.currency')}:</span>
                    <span className="font-mono">
                        {po.currency}
                        {po.currency !== baseCurrency && ` @ ${po.fx_rate}`}
                    </span>
                </div>
                {po.incoterm && (
                    <div>
                        <span className="text-gray-600 mr-1">{t('purchasing.form.incoterm')}:</span>
                        <span>{po.incoterm}</span>
                    </div>
                )}
                <div>{statusPill}</div>
                <div>
                    <span className="text-gray-600 mr-1">{t('purchasing.colEstimatedTotal')}:</span>
                    <span className="font-mono font-medium">{formatMoneyBare(po.estimated_total_ccy, '同一张头卡上的「币种」字段')}</span>
                </div>
            </div>

            {/* 审批:结构在,流程未启用 —— 但【不是等权限系统】。
                权限系统已经上线(perm1/perm2a/perm2b:模块权限、字段遮蔽、RLS),
                它交付的是「谁能进哪个模块」,不是「谁批准这一单」。两级审批
                (发起人 → 主管,超过阈值再升一级)按 Doc 3 排在【最终阶段】,
                与角色结构绑定后一起启用。指着一个已经发生过的条件,
                与描述一个不可能发生的隐患是同一种缺陷。 */}
            {/* APR-2c:三态各说各的话。【关着的时候必须明说"审批未生效"】——
                一张写着 approved 而其实没人批过的单子,与一张真的被批过的单子
                在屏幕上长得一模一样,那就是"0 冒充受限"换了第四件衣服。 */}
            {approvalsOn ? (
                <p className="text-xs text-gray-500 mb-4">
                    {t('purchasing.approvalOn')}
                    <span
                        className={
                            'ml-2 px-2 py-0.5 rounded ' +
                            (po.approval_status === 'approved'
                                ? 'bg-green-100 text-green-800'
                                : po.approval_status === 'rejected'
                                  ? 'bg-red-100 text-red-800'
                                  : 'bg-amber-100 text-amber-900')
                        }
                    >
                        {t('purchasing.approvalState.' + po.approval_status)}
                    </span>
                </p>
            ) : (
                <p className="text-xs mb-4 text-amber-800 bg-amber-50 border border-amber-200 rounded px-2 py-1 inline-block">
                    {t('purchasing.approvalOff')}
                </p>
            )}

            {/* PUR-1:采购单单据(规格:docs/purchase-order-document.md)。
                预览按当前数据渲染、不落档;【签发】把渲染出的字节存档并记录
                谁/何时/第几版 —— 供应商手里那份是某个具体版本,重签发产生新版本,
                旧版本原样留着。未获批的单签发会被 record_po_issue 点名拒绝。 */}
            <div className="border border-gray-200 rounded p-4 mb-4">
                <h2 className="font-semibold mb-2">{t('purchasing.doc.title')}</h2>
                <div className="flex items-center gap-3 mb-2">
                    <a href={`/purchasing/orders/${po.id}/pdf`} target="_blank"
                       className="text-sm text-blue-600 hover:underline">
                        {t('purchasing.doc.preview')}
                    </a>
                    <form method="post" action={`/purchasing/orders/${po.id}/pdf`}>
                        <button type="submit"
                            className="bg-blue-600 text-white text-sm px-3 py-1.5 rounded hover:bg-blue-700">
                            {t('purchasing.doc.issue')}
                        </button>
                    </form>
                </div>
                {mustRows(issuesRes, 'po_issues').length === 0 ? (
                    <p className="text-xs text-gray-500">{t('purchasing.doc.neverIssued')}</p>
                ) : (
                    <ul className="text-sm space-y-1">
                        {mustRows(issuesRes, 'po_issues').map((iss) => (
                            <li key={iss.version}>
                                <a href={`/purchasing/orders/${po.id}/pdf?version=${iss.version}`}
                                   className="text-blue-600 hover:underline font-mono">
                                    v{iss.version}
                                </a>
                                <span className="text-gray-500 ml-2">
                                    {t('purchasing.doc.issuedAt', { at: new Date(iss.issued_at).toISOString().slice(0, 16).replace('T', ' ') })}
                                </span>
                            </li>
                        ))}
                    </ul>
                )}
                {/* PUR-2:【已改、未重发】—— 供应商手里那份是某个具体版本,而这张单
                    此后又被改过。修改【不作废】那次签发(它确实发出去过,字节与摘要
                    原样留着),它要的是一次【新的签发】。 */}
                {amendedSinceIssue && (
                    <p className="mt-2 text-sm text-amber-800 bg-amber-50 border border-amber-300 rounded px-3 py-2">
                        {t('purchasing.doc.amendedSinceIssue', { version: latestIssueVersion ?? 0 })}
                    </p>
                )}
            </div>

            {/* PUR-2:编辑史。与 approval_log 各答各的 —— 那张答"谁批了什么金额",
                这张答"这张单当时说的是什么"。只增不改。 */}
            <div className="border border-gray-200 rounded p-4 mb-4">
                <h2 className="font-semibold mb-2">{t('purchasing.amend.historyTitle')}</h2>
                {history.length === 0 ? (
                    <p className="text-xs text-gray-500">{t('purchasing.amend.noHistory')}</p>
                ) : (
                    <ul className="text-sm space-y-1">
                        {history.map((h) => (
                            <li key={h.id} className="flex flex-wrap gap-2">
                                <span className="text-gray-500 font-mono text-xs">
                                    {new Date(h.changed_at).toISOString().slice(0, 16).replace('T', ' ')}
                                </span>
                                <span>{t('purchasing.amend.change.' + h.change_type)}</span>
                                {h.line_no !== null && (
                                    <span className="text-gray-500">#{h.line_no}</span>
                                )}
                                {h.old_quantity !== null && h.new_quantity !== null && (
                                    <span className="font-mono text-xs">{h.old_quantity} → {h.new_quantity}</span>
                                )}
                                {h.old_quantity !== null && h.new_quantity === null && (
                                    <span className="font-mono text-xs">{h.old_quantity} →</span>
                                )}
                                {h.amend_reason && <span className="text-gray-600">— {h.amend_reason}</span>}
                            </li>
                        ))}
                    </ul>
                )}
            </div>

            {po.notes && (
                <p className="text-sm text-gray-600 mb-2">
                    <span className="text-gray-500 mr-1">{t('purchasing.form.notes')}:</span>
                    {po.notes}
                </p>
            )}
            {po.terms_text && (
                <p className="text-sm text-gray-600 mb-4">
                    <span className="text-gray-500 mr-1">{t('purchasing.form.termsText')}:</span>
                    {po.terms_text}
                </p>
            )}

            {/* 明细行 */}
            <h2 className="text-xl font-bold mb-3">{t('purchasing.form.lines')}</h2>
            <table className="w-full border-collapse border border-gray-300 mb-6">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-3 py-2 text-left w-10">#</th>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('purchasing.colMaterial')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('purchasing.colQuantity')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('purchasing.colFormula')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('purchasing.colUnitPrice')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('purchasing.colAmount')}</th>
                    </tr>
                </thead>
                <tbody>
                    {lines.map((l) => (
                        <tr key={l.id}>
                            <td className="border border-gray-300 px-3 py-2 text-sm text-gray-500">{l.line_no}</td>
                            <td className="border border-gray-300 px-3 py-2 text-sm">
                                {materialById.get(l.material_id) ?? '—'}
                                {assayInline(l.expected_assay) && (
                                    <span className="block text-xs text-gray-500 mt-0.5">
                                        {t('purchasing.form.expectedAssay')}: {assayInline(l.expected_assay)}
                                    </span>
                                )}
                            </td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                {Number(l.quantity)} {l.unit}
                            </td>
                            <td className="border border-gray-300 px-3 py-2 text-sm">
                                {l.pricing_formula_id ? (formulaById.get(l.pricing_formula_id) ?? '—') : '—'}
                                {/* FIN-27:结算按哪一份条款。绿色 = 下单时抄下的副本,
                                    公式此后怎么改都碰不到这一行;琥珀 = 存量行,没有副本,
                                    结算会点名拒(不回填一份猜测的条款)。 */}
                                {l.pricing_formula_id && (
                                    <span className={'block text-xs mt-0.5 ' +
                                        (commitmentByLine.has(l.id) ? 'text-green-700' : 'text-amber-700')}>
                                        {commitmentByLine.has(l.id)
                                            ? t('purchasing.terms.committed', {
                                                code: commitmentByLine.get(l.id)!.source_formula_code,
                                                on: String(commitmentByLine.get(l.id)!.committed_at).slice(0, 10),
                                              })
                                            : t('purchasing.terms.notCommitted')}
                                    </span>
                                )}
                            </td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                {l.estimated_unit_price !== null ? formatUnitCost(l.estimated_unit_price) : '—'}
                                {/* FIN-26:价的出处 —— 读者不必懂内部机制就能分清
                                    "公式算出的"与"手敲的"。NULL(存量行)画"未知",
                                    不猜(B3)。computed 带汇率与取自哪天。 */}
                                {l.estimated_unit_price !== null && (
                                    <span className={'block text-xs font-sans mt-0.5 ' +
                                        (l.price_source === 'computed' ? 'text-green-700'
                                         : l.price_source === 'manual' ? 'text-amber-700'
                                         : 'text-gray-400')}>
                                        {l.price_source === 'computed'
                                            ? t('purchasing.priceSource.computed', {
                                                fx: String((l.price_provenance as { fx_factor?: number } | null)?.fx_factor ?? '—'),
                                                asOf: String((l.price_provenance as { fx_as_of?: string } | null)?.fx_as_of ?? '—'),
                                              })
                                            : l.price_source === 'manual'
                                                ? t('purchasing.priceSource.manual')
                                                : t('purchasing.priceSource.unknown')}
                                    </span>
                                )}
                            </td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                {formatMoneyBare(l.estimated_amount_ccy, '头卡「币种」—— 明细行是单据币种')}
                            </td>
                        </tr>
                    ))}
                </tbody>
                <tfoot>
                    <tr className="bg-gray-100 font-bold">
                        <td colSpan={5} className="border border-gray-300 px-3 py-2 text-right">
                            {t('purchasing.colEstimatedTotal')}
                        </td>
                        <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                            {formatMoneyBare(po.estimated_total_ccy, '头卡「币种」—— 明细行是单据币种')}
                        </td>
                    </tr>
                </tfoot>
            </table>

            {/* 付款计划 + 预付摘要 */}
            <div className="grid gap-6 md:grid-cols-3 mb-6">
                <div className="md:col-span-2">
                    <h2 className="text-xl font-bold mb-3">{t('purchasing.form.paymentTerms')}</h2>
                    {terms.length > 0 ? (
                        <table className="w-full border-collapse border border-gray-300">
                            <thead className="bg-gray-100">
                                <tr>
                                    <th className="border border-gray-300 px-3 py-2 text-left w-10">{t('purchasing.colSeq')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('purchasing.colLabel')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-right">{t('purchasing.colShare')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-right">{t('purchasing.colAmount')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('purchasing.colTrigger')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('purchasing.colDueDate')}</th>
                                </tr>
                            </thead>
                            <tbody>
                                {terms.map((l) => (
                                    <tr key={l.seq}>
                                        <td className="border border-gray-300 px-3 py-2 text-sm text-gray-500">{l.seq}</td>
                                        <td className="border border-gray-300 px-3 py-2 text-sm">{l.label}</td>
                                        <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                            {l.percentage !== null
                                                ? `${l.percentage}%`
                                                : formatAmount(l.fixed_amount_ccy, po.currency)}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                            {formatMoneyBare(termAmount(l), '头卡「币种」—— 付款计划按估算总额折算,同为单据币种')}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 text-sm">
                                            {t('purchasing.trigger.' + l.trigger_event)}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 text-sm">{l.due_date ?? '—'}</td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    ) : (
                        <p className="text-sm text-gray-500">—</p>
                    )}
                </div>

                {poStatus && (
                    /* CCY-1:这一块是【本位币】,而左边的付款计划与上方头卡是单据币种。
                       两块并排,所以这三行各自把币种写出来 —— 省掉它就等于指着头卡的
                       「币种:USD」,而这里的数字并不是 USD。 */
                    <div className="border border-gray-300 rounded p-4 text-sm space-y-2 h-fit">
                        <div className="flex justify-between">
                            <span className="text-gray-600">{t('purchasing.prepaidLabel')}</span>
                            <span className="font-mono">
                                <MaskedValue value={poStatus.prepaid_base === null ? null : formatAmount(poStatus.prepaid_base, baseCurrency)} canView={canFinance} />
                            </span>
                        </div>
                        <div className="flex justify-between">
                            <span className="text-gray-600">{t('purchasing.appliedLabel')}</span>
                            <span className="font-mono">
                                <MaskedValue value={poStatus.prepaid_applied_base === null ? null : formatAmount(poStatus.prepaid_applied_base, baseCurrency)} canView={canFinance} />
                            </span>
                        </div>
                        <div className="flex justify-between font-medium border-t pt-2">
                            <span>{t('purchasing.remainingLabel')}</span>
                            <span className="font-mono">
                                <MaskedValue value={poStatus.prepaid_remaining_base === null ? null : formatAmount(poStatus.prepaid_remaining_base, baseCurrency)} canView={canFinance} />
                            </span>
                        </div>
                        {!isCancelled && (
                            <Link
                                href={`/finance/payments/new?direction=out&supplier=${po.supplier_id}`}
                                className="block text-center border border-gray-300 px-3 py-1.5 rounded hover:bg-gray-50 text-blue-600"
                            >
                                {t('purchasing.payDeposit')}
                            </Link>
                        )}
                    </div>
                )}
            </div>

            {/* 收货记录 */}
            <h2 className="text-xl font-bold mb-3">{t('purchasing.receipts')}</h2>
            {receipts.length > 0 ? (
                <>
                    <p className="text-sm text-gray-600 mb-2">
                        {t('purchasing.receivedVsOrdered', {
                            received: receivedQty,
                            ordered: orderedQty,
                            unit: lines[0]?.unit ?? 'kg',
                        })}
                        {poStatus?.receipt_pct !== null && poStatus?.receipt_pct !== undefined && (
                            <span className="ml-2 font-mono">({poStatus.receipt_pct}%)</span>
                        )}
                    </p>
                    <table className="w-full border-collapse border border-gray-300">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colCode')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('inbound.form.arrivalDate')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-right">{t('purchasing.colQuantity')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-right">{t('purchasing.colUnitPrice')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-right">{t('purchasing.appliedLabel')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colOpen')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {receipts.map((r) => (
                                <tr key={r.id}>
                                    <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                        <Link href={`/inbound/${r.id}/edit`} className="text-blue-600 hover:underline">
                                            {r.code}
                                        </Link>
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">{r.arrival_date ?? '—'}</td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {Number(r.quantity)} {r.unit}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {r.unit_price !== null ? (
                                            formatUnitCost(r.unit_price)
                                        ) : (
                                            <span className="text-amber-700">{t('purchasing.unpriced')}</span>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {/* CCY-1:抵扣额与敞口是本位币 —— 上方头卡说的是单据币种,不能借它 */}
                                        {appliedByBatch.has(r.id) ? formatAmount(appliedByBatch.get(r.id), baseCurrency) : '—'}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {r.unit_price === null ? '—' : (
                                            <MaskedValue
                                                value={canFinance ? formatAmount(openByBatch.get(r.id) ?? 0, baseCurrency) : null}
                                                canView={canFinance}
                                            />
                                        )}
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </>
            ) : (
                <p className="text-sm text-gray-500">{t('purchasing.noReceipts')}</p>
            )}
        </div>
    )
}
