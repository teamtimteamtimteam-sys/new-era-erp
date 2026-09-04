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
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatAmount, formatMoneyBare, formatUnitCost } from '@/lib/format'
import CancelOrderControl from './CancelOrderControl'
import ApprovalControls from './ApprovalControls'
import ActorName, { loadActorNames } from '@/app/components/ActorName'
import { CloseOrderControl, ReopenOrderControl } from './CloseReopenControls'
import { can, canViewPrices } from '@/lib/permissions'
import { MaskedValue } from '@/app/components/MaskedValue'
import { maskedExcept, maskedRows } from '@/lib/maskedRows'
import type { Tables } from '@/lib/database.types'
import IssuePanel from '@/app/components/IssuePanel'
import { mustRows, mustOne } from '@/lib/db-helpers'
import { loadPaymentTriggerEvents, triggerLabel } from '@/lib/paymentTriggers'
import RetentionPanel, { type RetentionRow } from './RetentionPanel'
// ★ CONV-8:ExpectedDateControl / DeepDischargeJudgementControl 不再由本页直接渲染 ——
//   它们搬进了各自那张表的列描述符里(格子里的控件走 DataTable 的 render,
//   Tim 的 Q3 裁定,理由写在 PoLinesTable.tsx 抬头)。
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import PoLinesTable, { type PoLineRow, type Tone } from './PoLinesTable'
import PoPaymentTermsTable, { type PoTermRow } from './PoPaymentTermsTable'
import PoReceiptsTable, { type PoReceiptRow } from './PoReceiptsTable'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import DiscrepancyKinds, {
    type DiscrepancyRow as GrnRow,
    type ReceivingThresholds as GrnThresholds,
} from '@/app/components/receiving/DiscrepancyKinds'

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
        .select('id, code, supplier_id, order_date, expected_delivery_date, currency, fx_rate, estimated_total_ccy, tax_total_ccy, gross_total_ccy, carries_tax, status, approval_status, incoterm, terms_text, notes, cancelled_at, cancel_reason, cancelled_by')
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
    // PROC-1B-iii(R1):深度放电判断的字典。【只读 is_active 的】—— 停用是
    // "以后别再选它",而历史行照旧显示(下面的 label 回落到码本身,不画空白)。
    // 这张字典没有 _masked 伴生,表级 SELECT 授权给 authenticated,直读。
    const ddRes = await supabase.from('deep_discharge_judgements')
        .select('code, name_en, name_zh').eq('is_active', true).order('sort_order')
    const po = maskedExcept<Tables<'purchase_orders'>, 'fx_rate' | 'estimated_total_ccy'>(poRaw) as unknown as
        (Tables<'purchase_orders'> & { tax_total_ccy: number | null; gross_total_ccy: number | null; carries_tax: boolean })

    const [supplierRes, linesRes, termsRes, statusRes, receiptsRes, apprRes, issuesRes, historyRes] = await Promise.all([
        supabase.from('suppliers').select('id, legal_name').eq('id', po.supplier_id).single(),
        supabase
            .from('purchase_order_lines_masked')
            .select('id, line_no, material_id, asset_id, quantity, unit, pricing_formula_id, estimated_unit_price, estimated_amount_ccy, expected_assay, notes, price_source, price_provenance, deep_discharge_judgement_code')
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

    // ── GRN-1b:这张单的收货差异,【按采购行】────────────────────────────────
    // 【为什么这一块必须在这里,而不是只在批次详情上】
    // po_receivable_lines 只收 confirmed/receiving —— 单一关那一行就消失了,
    // 而短交恰恰是关单之后才成为问题的;上面那句"已收 / 已订"是【单级】汇总,
    // 一行超一行短可以正好抵成 100%。grn_discrepancies 两者都不做,所以它在
    // 关掉的单上仍然说得出话 —— 那正是 GRN-1a 的全部意义,也是这一块存在的理由。
    const [grnRes, grnSettingsRes] = await Promise.all([
        supabase
            .from('grn_discrepancies')
            .select('batch_id, batch_code, po_code, po_status, line_id, line_no, ' +
                    'ordered_material_code, received_material_code, ordered_qty, ordered_unit, ' +
                    'received_qty, received_unit, declared_qty, line_received_qty, ' +
                    'line_receipt_count, line_delta_qty, line_delta_pct, declared_delta_qty, ' +
                    'assay_beyond_tolerance, assay_metals_compared, ' +
                    // PROC-1B-iii:两侧的【原始码】都要取 —— 只取那个布尔的话,
                    // 「没设」与「未评估」在屏幕上就并成一句了(两者的布尔都是 NULL)。
                    'deep_discharge_judged, deep_discharge_actual, deep_discharge_contradicted, kinds')
            .eq('po_id', id)
            .order('line_no'),
        supabase
            .from('receiving_settings')
            .select('grn_short_pct, grn_over_pct, grn_assay_tolerance_pct')
            .maybeSingle(),
    ])
    // 【失败必须失败】读不出来时不许渲染成"这张单没有差异"
    const grnRows = mustRows(grnRes, 'grn_discrepancies') as unknown as (GrnRow & { line_id: string })[]
    const grnSettings = mustOne(grnSettingsRes, 'receiving_settings') as GrnThresholds | null

    // 按采购行归拢。short/over 是【行级】事实,挂在该行的每一条收货上,所以
    // 同一行的多条收货带着同一个结论 —— 按行显示时取第一条即可,而按行计数
    // 正是视图注释里说的 DISTINCT line_id(这里用 Map 达到同样效果)。
    const grnByLine = new Map<string, (GrnRow & { line_id: string })[]>()
    for (const r of grnRows) {
        const cur = grnByLine.get(r.line_id) ?? []
        cur.push(r)
        grnByLine.set(r.line_id, cur)
    }

    // APR-2c:审批是否生效 —— 决定这一页说哪一句话
    const approvalsOn = (apprRes.data as unknown as boolean | null) ?? false

    // PUR-2:【已改、未重发】。比较【最新一次签发】与【最新一条编辑史】的时点 ——
    // 修改不作废那次签发(它确实发出去过),但供应商手里那份已经不是现在这张单了。
    // AUDEL-3:取名与兜底只有一处 —— app/components/ActorName.tsx。
    const cancelNames = await loadActorNames(supabase, [po.cancelled_by])

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
    // PROC-1B-iii:字典翻成本地语言。**读不出来就【按名喊出来】,不画空白** ——
    // mustRows 在这里的作用正是这个:一张读不到的字典会让每一行的判断悄悄
    // 变成"未填写",而那与"这一行真的没填"在屏幕上一模一样。
    const ddLocale = await getLocale()
    const ddOptions = (mustRows(ddRes, 'deep_discharge_judgements') as
        { code: string; name_en: string; name_zh: string }[])
        .map((r) => ({ code: r.code, label: ddLocale === 'zh' ? r.name_zh : r.name_en }))
    // EQP-PAY-1:里程碑的名字来自字典 —— 与 ddOptions 同一个惯用法(按语言选一个),
    // 而【读不出来就按名喊】的理由也同一条:一张读不到的字典会让每一期的里程碑
    // 悄悄变成一个裸码,而那看起来像数据坏了,不像字典没读到。
    const triggerNames = new Map(
        (await loadPaymentTriggerEvents(supabase)).map((e) => [e.code, triggerLabel(e, ddLocale)])
    )
    const terms = maskedRows<Tables<'purchase_order_payment_terms'>, 'fixed_amount_ccy'>(mustRows(termsRes))
    // CASHFLOW-1：按事件类型的保管人。【无权时不去查，而不是查了拿零行】——
    // 零行会让每一期都显示成「不需要估计」，那是一句假话。
    const eventOwners = Object.fromEntries(
        (mustRows(
            await supabase.from('payment_event_owners').select('trigger_event, owner_name')
        ) as unknown as { trigger_event: string; owner_name: string }[])
            .map((o) => [o.trigger_event, o.owner_name])
    ) as Record<string, string>
    const canEditPurchasing = await can('module.purchasing.edit')
    const poStatus = statusRes.data
    const receipts = maskedRows<Tables<'inbound_batches'>, 'unit_price'>(mustRows(receiptsRes))

    // 物料/公式名 + 收货批次的未结应付(结清的批次不在 ap_open_items → 敞口 0)
    // EQP-1a:material_id 现在可空(设备行不订物料)。这里【滤掉 null】——
    // 只是不去查一个不存在的物料,不是把设备行藏起来:行本身照旧在 lines 里。
    // TypeScript 抓到的正是这一处:(string | null)[] 喂不进 .in('id', …)。
    const materialIds = Array.from(new Set(
        lines.map((l) => l.material_id).filter((id): id is string => id !== null)))
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
    // ── EQP-1c-b-fu2:这张单是【设备单】还是【材料单】───────────────────────
    // 【一张单只有一种】EQP-1a 的 N1 由一条延迟约束触发器保证不混装,所以
    // "任意一行有 asset_id" 就是整单的种类,不需要逐行判。
    // 这一个布尔量决定了下面【一整批】只对材料成立的东西出不出现 ——
    // 走查看到的是"按此单收货"那一个按钮,而按钮只是其中一项(见本刀的分类表)。
    const isEquipmentOrder = lines.some((l) => l.asset_id !== null)

    // ── EQP-PAY-1(R6):这张单上的质保金 ────────────────────────────────────
    // 【读的是 purchase_order_retention_status,不是基表】那张视图是【属主权限】的:
    // 它体内 JOIN 了 fixed_assets(module.finance.view),而本页的门是采购 ——
    // 直接 JOIN 会让一个只有采购权限的人读到【零行】,于是"这台机器有没有质保金"
    // 悄悄变成"没有"。这正是本文件上面那段 EQP-1c-b-fu2 注释记下的同一条
    // (OPS-14:跨模块的行会无声消失),所以这里走同一条补救。
    //
    // 【零行有两种,而这里它们是同一种】设备单读到零行 = 这张单【没有质保金条款】——
    // 不是"读不到"(视图不会因为权限少给行,它按 has_permission 整张给或整张不给,
    // 而本页已经过了采购那道门)。RetentionPanel 因此把零行画成一句明说的话。
    const retentionRes = isEquipmentOrder
        ? await supabase
              .from('purchase_order_retention_status')
              .select('retention_id, line_no, asset_code, asset_description, acceptance_date, retention_months, maturity_date, retention_state, percentage, retention_amount_ccy, released_at, released_amount_ccy, withheld_amount_ccy, withholding_reason')
              .eq('purchase_order_id', id)
              .order('line_no')
        : { data: [] as RetentionRow[], error: null }
    const retentions = mustRows(retentionRes) as RetentionRow[]
    const canSeePrices = await canViewPrices()

    const materialById = new Map((mustRows(materialsRes)).map((m) => [m.id, `${m.code} — ${m.name}`]))

    // ── EQP-1c-b(P3):设备行的名字 ────────────────────────────────────────
    // 【为什么不直接查 fixed_assets】那张表的 SELECT 策略要 module.finance.view,
    // 而本页的门是 module.purchasing.view。一个只有采购权限的人直接查它会读到
    // 【零行】—— 于是机器名又变回一个破折号,而且是【悄悄】变回去的:
    // 没有错误、没有提示,正是 OPS-14 那条"跨模块的行会无声消失"。
    // 【改从 po_document_data 拿】它是 DEFINER + require_permission('module.purchasing.view'),
    // 以属主身份算 COALESCE(m.name, fa.description) —— 也就是说
    // **供应商手里那份和这块屏幕从此读的是同一份实现**,不可能各说各话。
    const docRes = await supabase.rpc('po_document_data', { p_po_id: id })
    const docLines = (docRes.data as { lines?: { line_no: number; material_name: string | null }[] } | null)?.lines ?? []
    const docNameByLineNo = new Map(docLines.map((d) => [d.line_no, d.material_name]))
    // 材料行照旧画 `编号 — 名称`(信息比单独一个名字多);设备行画机器的描述,
    // 与供应商那份逐字相同。两者都拿不到时才是真的破折号。
    const lineName = (l: { line_no: number; material_id: string | null }): string =>
        (l.material_id ? materialById.get(l.material_id) : docNameByLineNo.get(l.line_no) ?? null)
        ?? docNameByLineNo.get(l.line_no) ?? '—'
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
        // EQP-1b-i:inbound_batch_id 可空了 —— 冲抵的第二个目的地是费用单。
        // 那种行【不属于】这张按批次归集的表(它们没有批次),所以跳过而不是
        // 塞进一个空键里。查询本身已经 .in(batchIds) 过滤掉了它们,这一句是
        // 让类型与那个事实对齐,不是一层新的过滤。
        if (r.inbound_batch_id === null) continue
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
    // FIX-2(B2):**报【触发的那一条】,不报它当初写出来的那个析取式。**
    // 此前这里是 `receipts > 0 || applied > 0 || !canFinance`,而屏幕上那句话写的是
    // "已收货或已抵扣预付" —— 三个分支里只提了两个,**而且漏掉的那个是【权限】**:
    // 一个没有财务编辑权的人会看见一句业务理由,去查两件根本不存在的事。
    // 设备采购单更糟:它【永远不可能收货】,那句话等于让人去查一件不可能的事。
    const cancelWhy = !canFinance
        ? t('purchasing.cancelNeedsFinance')
        : receipts.length > 0
        ? t('purchasing.cancelHasReceipts', { n: String(receipts.length) })
        : appliedUsd > 0
        ? t('purchasing.cancelHasPrepayments')
        : ''

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

    // ════════════════════════════════════════════════════════════════════════
    // CONV-8:三张表的行数据,全部在服务端压平成【纯数据】
    // ════════════════════════════════════════════════════════════════════════
    // CONV-1 §① 的通则:判据、locale、Map、货币格式一律不过客户端边界。
    // 这一页尤其要紧 —— 它的格子里挂着 FIN-26(价的出处)与 FIN-27(条款副本)
    // 两套【带颜色的】判断,把它们搬到客户端就等于把这一页的取数形状也搬过去。
    // 所以颜色在这里算成 Tone,客户端只认 'green' | 'amber' | 'gray' 三个字。

    const lineRows: PoLineRow[] = lines.map((l) => ({
        id: l.id,
        lineNoText: String(l.line_no),
        name: lineName(l),
        expectedAssayText: assayInline(l.expected_assay) || null,
        materialId: l.material_id ?? null,
        ddCurrent: l.deep_discharge_judgement_code ?? null,
        qtyText: `${Number(l.quantity)} ${l.unit}`,
        formulaText: l.pricing_formula_id ? (formulaById.get(l.pricing_formula_id) ?? '—') : '—',
        // FIN-27:绿 = 下单时抄下的副本,公式此后怎么改都碰不到这一行;
        //         琥珀 = 存量行,没有副本,结算会点名拒。
        commitmentText: l.pricing_formula_id
            ? commitmentByLine.has(l.id)
                ? t('purchasing.terms.committed', {
                      code: commitmentByLine.get(l.id)!.source_formula_code,
                      on: String(commitmentByLine.get(l.id)!.committed_at).slice(0, 10),
                  })
                : t('purchasing.terms.notCommitted')
            : null,
        commitmentTone: l.pricing_formula_id
            ? ((commitmentByLine.has(l.id) ? 'green' : 'amber') satisfies Tone)
            : null,
        unitPriceText: l.estimated_unit_price !== null ? formatUnitCost(l.estimated_unit_price) : '—',
        // FIN-26:价的出处。NULL(存量行)画「未知」,不猜。
        priceSourceText:
            l.estimated_unit_price === null
                ? null
                : l.price_source === 'computed'
                  ? t('purchasing.priceSource.computed', {
                        fx: String((l.price_provenance as { fx_factor?: number } | null)?.fx_factor ?? '—'),
                        asOf: String((l.price_provenance as { fx_as_of?: string } | null)?.fx_as_of ?? '—'),
                    })
                  : l.price_source === 'manual'
                    ? t('purchasing.priceSource.manual')
                    : t('purchasing.priceSource.unknown'),
        priceSourceTone:
            l.estimated_unit_price === null
                ? null
                : ((l.price_source === 'computed'
                      ? 'green'
                      : l.price_source === 'manual'
                        ? 'amber'
                        : 'gray') satisfies Tone),
        amountText: formatMoneyBare(l.estimated_amount_ccy, '头卡「币种」—— 明细行是单据币种'),
    }))

    // ★★【PO-GST-1 的三行合计,搬成三行【数据】】★★
    // 【不带税的历史单据只印一行】carries_tax 为 false 时不印「GST 0.00」——
    // 那会是一句断言,而真相是"这张单没有算过税"。这条判据原样保住。
    // amount 是 number | null —— 与 formatMoneyBare 的签名一致。收窄成 number
    // 会把「这张单没有算过税」(null)逼成一个 0,而那正是 PO-GST-1 拒绝印的那句断言。
    const totalRow = (
        key: string,
        label: string,
        amount: number | null,
        kind: 'sub' | 'grand',
    ): PoLineRow => ({
        id: key,
        lineNoText: '',
        name: label,
        expectedAssayText: null,
        materialId: null,
        ddCurrent: null,
        qtyText: '',
        formulaText: '',
        commitmentText: null,
        commitmentTone: null,
        unitPriceText: '',
        priceSourceText: null,
        priceSourceTone: null,
        amountText: formatMoneyBare(amount, '头卡「币种」—— 明细行是单据币种'),
        totalKind: kind,
    })

    if (lineRows.length > 0) {
        if (po.carries_tax) {
            lineRows.push(
                totalRow('__net__', t('purchasing.colNetTotal'), po.estimated_total_ccy, 'sub'),
                totalRow('__tax__', t('purchasing.colTaxTotal'), po.tax_total_ccy, 'sub'),
                totalRow('__gross__', t('purchasing.colGrossTotal'), po.gross_total_ccy, 'grand'),
            )
        } else {
            lineRows.push(
                totalRow('__est__', t('purchasing.colEstimatedTotal'), po.estimated_total_ccy, 'grand'),
            )
        }
    }

    const termRows: PoTermRow[] = terms.map((l) => ({
        id: l.id,
        seqText: String(l.seq),
        label: l.label,
        shareText:
            l.percentage !== null ? `${l.percentage}%` : formatAmount(l.fixed_amount_ccy, po.currency),
        amountText: formatMoneyBare(
            termAmount(l),
            '头卡「币种」—— 付款计划按估算总额折算,同为单据币种',
        ),
        triggerText: triggerNames.get(l.trigger_event) ?? l.trigger_event,
        dueDateText: l.due_date ?? '—',
        triggerEvent: l.trigger_event,
        expectedDate: l.expected_date ?? null,
        ownerName: eventOwners[l.trigger_event] ?? null,
    }))

    const receiptRows: PoReceiptRow[] = receipts.map((r) => ({
        id: r.id,
        code: r.code,
        arrivalDateText: r.arrival_date ?? '—',
        qtyText: `${Number(r.quantity)} ${r.unit}`,
        unitPriceText: r.unit_price !== null ? formatUnitCost(r.unit_price) : null,
        // CCY-1:抵扣额与敞口是本位币 —— 上方头卡说的是单据币种,不能借它。
        appliedText: appliedByBatch.has(r.id)
            ? formatAmount(appliedByBatch.get(r.id), baseCurrency)
            : '—',
        // ★ 不在这里折成字符串:null(看不到)与 '—'(没有价)是两件事,
        //   交给 MaskedValue 分。见 PoReceiptsTable.tsx 抬头。
        openText: canFinance ? formatAmount(openByBatch.get(r.id) ?? 0, baseCurrency) : null,
        openApplicable: r.unit_price !== null,
    }))

    return (
        <ListPage
            maxWidth="max-w-5xl"
            breadcrumb={
                <Link href="/purchasing/orders" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            }
            title={
                <>
                    {t('purchasing.orderDetailTitle')}
                    <span className="ml-3 font-mono text-base text-gray-500">{po.code}</span>
                </>
            }
            // ★ 详情页恒为 ok —— 记录存在与否由上面的 notFound() 回答。
            //   理由与后果见 docs/detail-page-template.md 与 record-header.tsx 抬头。
            state={{ kind: 'ok' }}
            // ★★【这一页的动作【全部】住在 actions 槽里,而那正是详情页版本的
            //     「空态吃掉出口」要防的东西】★★
            //   收货、结束、修改、重开、取消 —— 五个出口。ListPage 把 actions
            //   画在状态分支【之前】,所以即使将来有人把 state 改成别的分支,
            //   这五个出口也不会跟着消失。
            actions={
                <div className="flex flex-wrap items-center gap-3 justify-end">
                    {/* 按此单收货:只在可收货状态出现。
                        【EQP-1c-b-fu2:设备单上【隐藏】,不是变灰】——
                        机器到厂【不是一次收货】(不产生批次、没有化验、不进库位),
                        而 guard_inbound_po_line_match 在库里按名拒。
                        本仓库的规矩是:问题【不适用】就隐藏,问题适用但此刻做不到
                        才变灰加一句话。"这台机器收几公斤"是前者 —— 它根本不是
                        一个可以问的问题。
                        【拿掉按钮不等于解决困惑】所以下面那一句告诉人该去哪 ——
                        否则只是把困惑挪了个地方。 */}
                    {!isEquipmentOrder && (po.status === 'confirmed' || po.status === 'receiving') && (
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
                    {/* FIX-2(B3):【已结束】时改成禁用 + 一句话,不再藏起来。
                        "这张单还能不能改"是一个适用的问题 —— 答案是"先重开"。
                        藏起来会让人以为这个系统不支持改单。
                        【已作废仍然藏】那才是"不适用":一张作废的单没有可改的东西。 */}
                    {!isCancelled && (po.status !== 'closed' ? (
                        <Link href={`/purchasing/orders/${po.id}/amend`}
                            className="border border-gray-300 px-3 py-1.5 rounded text-sm hover:bg-gray-50">
                            {t('purchasing.amend.link')}
                        </Link>
                    ) : (
                        <span className="inline-flex flex-col items-start">
                            {/* FIX-3(B2):`items-start` —— 与 CancelOrderControl 同一个毛病,
                                而【这一个没有人报过】:列方向 flex 默认 stretch,按钮被下面
                                那句长理由撑到同宽,读起来像输入框。B2 要找的就是它。 */}
                            <button type="button" disabled
                                    className="border border-gray-300 text-gray-400 px-3 py-1.5 rounded text-sm cursor-not-allowed">
                                {t('purchasing.amend.link')}
                            </button>
                            <span className="text-xs text-amber-700 mt-1">{t('purchasing.amendClosedWhy')}</span>
                        </span>
                    ))}
                    {po.status === 'closed' && <ReopenOrderControl poId={po.id} />}
                    {/* FIX-2(B1):挡住时也把控件画出来 —— 变灰 + 一句话,不是消失。 */}
                    {!isCancelled && po.status !== 'closed' && (
                        <CancelOrderControl poId={po.id} blockedWhy={cancelWhy} />
                    )}
                </div>
            }
            // 无条件渲染的那两块话 —— CONV-1 的 notices 槽,同一条理由:
            // 一条只在某个分支里才出现的警告,等于没有警告。
            notices={
                <>
            {/* A3:拿掉了"收货"这个动作,就得说清楚机器到了该去哪 —— 否则
                删掉按钮只是把困惑搬了个家。 */}
            {isEquipmentOrder && (
                <p className="mb-4 rounded border border-blue-200 bg-blue-50 px-3 py-2 text-sm text-blue-900">
                    {t('purchasing.equipmentOrderNote')}
                </p>
            )}

            {isCancelled && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4 text-sm">
                    {t('purchasing.status.cancelled')}
                    {po.cancelled_at ? ` · ${po.cancelled_at.slice(0, 10)}` : ''}
                    {/* AUDEL-2:取消要看得见【谁】和【为什么】,不只是"已取消"这个事实。
                        AUDEL-3:取名与兜底移进 app/components/ActorName.tsx ——
                        此前这里写着"反查不到就印 uuid",那句话已经不成立了,
                        现在印的是具名状态,uuid 只作小字附注。 */}
                    {po.cancelled_by && (
                        <>
                            {' · '}
                            <ActorName userId={po.cancelled_by} names={cancelNames} />
                        </>
                    )}
                    {po.cancel_reason ? `:${po.cancel_reason}` : ''}
                </div>
            )}
                </>
            }
        >
            {/* ★ 头卡 —— 七个字段(incoterm 只在有的时候出现),动作全在 actions 槽里,
                所以这里【没有】actions prop:这一页的出口住在标题那一行。 */}
            <RecordHeader
                fields={[
                    {
                        label: t('purchasing.colSupplier'),
                        value: (
                            <Link
                                href={`/suppliers/${po.supplier_id}/edit`}
                                className="text-blue-600 hover:underline"
                            >
                                {supplierRes.data?.legal_name ?? '—'}
                            </Link>
                        ),
                    },
                    { label: t('purchasing.colOrderDate'), value: po.order_date },
                    { label: t('purchasing.colExpectedDelivery'), value: po.expected_delivery_date ?? '—' },
                    {
                        label: t('purchasing.form.currency'),
                        value: (
                            <>
                                {po.currency}
                                {po.currency !== baseCurrency && ` @ ${po.fx_rate}`}
                            </>
                        ),
                        mono: true,
                    },
                    // incoterm 没有就不占一格 —— 与转换前的 {po.incoterm && …} 同义。
                    ...(po.incoterm
                        ? [{ label: t('purchasing.form.incoterm'), value: po.incoterm }]
                        : []),
                    // 状态药丸没有标签,它自己就是一句话。RecordHeader 的 label
                    // 允许是空 —— 与转换前那个裸着的 <div>{statusPill}</div> 同形。
                    { label: t('purchasing.colStatus'), value: statusPill },
                    {
                        label: po.carries_tax
                            ? t('purchasing.colGrossTotal')
                            : t('purchasing.colEstimatedTotal'),
                        value: formatMoneyBare(
                            po.carries_tax ? po.gross_total_ccy : po.estimated_total_ccy,
                            '同一张头卡上的「币种」字段',
                        ),
                        mono: true,
                    },
                ]}
            />

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

            {/* SOD-1:审批生效 + 这张单在等审批 → 【这里必须有批得了它的地方】。
                此前 approve_purchase_order / reject_purchase_order 在 app/ 里
                一个调用方都没有:开关一打开,每一张新单都会停在 pending 且收不了货。
                关着的时候不渲染 —— 那不是"被挡住",是这个问题【不适用】
                (没有人做过决定,也就没有决定可改)。 */}
            {approvalsOn && po.approval_status === 'pending' && !isCancelled && (
                <ApprovalControls poId={po.id} />
            )}

            {/* PUR-1:采购单单据(规格:docs/purchase-order-document.md)。
                预览按当前数据渲染、不落档;【签发】把渲染出的字节存档并记录
                谁/何时/第几版 —— 供应商手里那份是某个具体版本,重签发产生新版本,
                旧版本原样留着。未获批的单签发会被 record_po_issue 点名拒绝。 */}
            <div className="border border-gray-200 rounded p-4 mb-4">
                <h2 className="font-semibold mb-2">{t('purchasing.doc.title')}</h2>
                {/* EXT-1:此前这里是这一族里唯一的 <form method="post"> 变体。
                    换成公共件之后有三处【看得见的】变化,都记在切次报告里:
                      ① 外观并入这一族(蓝色实心钮 → 描边钮,蓝色文字链 → 描边链);
                      ② 服务端拒绝【不再整页显示】,而是摆在按钮旁边(此前表单提交
                         是一次导航,浏览器把那段纯文本当成一页渲染出来);
                      ③ 签发之后版本列表会刷新 —— 表单那一版下载完就停在原地,
                         新版本要手工刷新才看得见。
                    【签发即下载没有丢】:采购单那条 POST 回的是 PDF 字节本身,
                    组件按 Content-Type 分叉把它存下来(见组件抬头)。
                    【不传 canIssue】—— 此前这个钮永不禁用,保持不变;未获批的单
                    由 record_po_issue 按名拒,那句拒绝现在显示在旁边。 */}
                <IssuePanel
                    pdfHref={`/purchasing/orders/${po.id}/pdf`}
                    previewLabel={t('purchasing.doc.preview')}
                    issueLabel={t('purchasing.doc.issue')}
                />
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
            <PoLinesTable
                rows={lineRows}
                poId={id}
                ddOptions={ddOptions}
                canEditPurchasing={canEditPurchasing}
                isEquipmentOrder={isEquipmentOrder}
            />

            {/* ★★【FA-PO-1(2026-09-03):一句话,而它是为了拦住一次【已经发生过的】误读】★★
                Tim 给一家供应商设了默认进项税码(TX · 标准税率进项),开出采购单,
                发现金额里【没有 GST】—— 于是把那张单取消了(PO-2026-0008,
                取消理由原文就是 "GST not included")。
                **而这套系统是对的,错的是它什么都没说。**
                供应商上那个字段自己的定义写着它管的是这家供应商的【账单】默认用哪个
                进项税码(db/tables/suppliers.sql 的列注释),落点是 record_expense;
                purchase_orders 与 purchase_order_lines 上【没有任何税相关的列】——
                GST-2 把税放在【费用/发票】那一层,不在订单这一层。这在会计上也是对的:
                采购单是一个承诺,不是纳税时点;进项税的抵扣挂在供应商开来的税务发票上。
                【所以本刀不接税,只说话】—— 一个金额旁边什么都不写,读的人只能猜,
                而这一次的猜法已经让一张单被取消掉了。 */}
            {/* PO-GST-1 取代了 FA-PO-1 那一句。那一句说的是"本单不含税,税在录发票时产生"
                —— 在 Tim 裁定采购单必须携带税之后,它【不再为真】。留着一句过期的
                解释比没有解释更坏:它会让人相信屏幕上那个数是全部。 */}
            {po.carries_tax ? (
                <p className="text-sm text-gray-600 mb-2">{t('purchasing.gstOnOrderNote')}</p>
            ) : (
                <p className="text-sm text-gray-600 mb-2">{t('purchasing.gstNotCarriedNote')}</p>
            )}
            {lines.some((l) => (l as { tax_code?: string | null }).tax_code === 'OP') && (
                <p className="text-sm text-gray-600 mb-6">{t('purchasing.gstOutOfScopeNote')}</p>
            )}

            {/* 付款计划 + 预付摘要 */}
            <div className="grid gap-6 md:grid-cols-3 mb-6">
                <div className="md:col-span-2">
                    <h2 className="text-xl font-bold mb-3">{t('purchasing.form.paymentTerms')}</h2>
                    {terms.length > 0 ? (
                        <PoPaymentTermsTable
                            rows={termRows}
                            poId={po.id}
                            canEditPurchasing={canEditPurchasing}
                        />
                    ) : (
                        <p className="text-sm text-gray-500">—</p>
                    )}

                    {/* EQP-PAY-1(R6):质保金。★ 它【紧挨着付款计划】,因为它就是
                        付款条款的一部分 —— 只是形状不同:别的期次是"某件事发生的时候",
                        它是"某件事发生【之后 N 个月】"。
                        ★【有与没有必须看得出来】★ 没有质保金的单在这里印一句明说的话,
                        不是留白、更不是一个 0%。 */}
                    <div className="mt-6">
                        <RetentionPanel
                            poId={po.id}
                            rows={retentions}
                            isEquipmentOrder={isEquipmentOrder}
                            canEdit={canEditPurchasing}
                            currency={po.currency}
                            canSeePrices={canSeePrices}
                        />
                    </div>
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

            {/* ── GRN-1b:收货差异,按采购行 ─────────────────────────────────────
                【它活过关单】上面那句"已收 / 已订"是单级汇总(一行超一行短抵成
                100%),而 po_receivable_lines 在单一关就不再收这一行。这一块两者
                都不做,所以关掉的单上它照样说得出话。 */}
            {/* ── EQP-1c-b-fu2:整块【收货】的东西在设备单上不出现 ──────────────
                走查看到的是"按此单收货"那个按钮,但按钮只是入口;这两整节
                (收货差异、收货批次)同样只对材料成立 —— 设备行【永远】没有收货行,
                所以它们在设备单上会渲染成一排"暂无收货",而那读起来像
                "还没收到货",不像"这件事不适用"。
                【与那个按钮同一条判据】问题不适用 → 隐藏。 */}
            {!isEquipmentOrder && (<>
            <h2 className="text-xl font-bold mb-3">{t('grn.po.heading')}</h2>
            <p className="text-sm text-gray-600 mb-3">{t('grn.po.note')}</p>
            <div className="space-y-3 mb-8">
                {lines.map((l) => {
                    const rows = grnByLine.get(l.id) ?? []
                    const withKinds = rows.filter((r) => r.kinds && r.kinds.length > 0)
                    return (
                        <div key={l.id} className="border border-gray-300 rounded-lg p-3">
                            <p className="text-sm mb-2">
                                <span className="text-gray-500">#{l.line_no}</span>
                                <span className="ml-2 font-mono">{lineName(l)}</span>
                                <span className="ml-2 text-gray-600">
                                    {t('grn.po.orderedLabel', { qty: Number(l.quantity), unit: l.unit ?? 'kg' })}
                                </span>
                                {rows.length > 0 && (
                                    <span className="ml-2 text-gray-600">
                                        {t('grn.po.receivedLabel', {
                                            qty: rows[0].line_received_qty,
                                            unit: l.unit ?? 'kg',
                                            receipts: rows[0].line_receipt_count,
                                        })}
                                    </span>
                                )}
                            </p>

                            {rows.length === 0 ? (
                                /* 【GRN-1a 点名的盲区,写在它最该被读到的地方】
                                   这张视图的粒度是一条收货一行,所以一条【一次都没
                                   收过】的采购行【根本不产生行】—— 而那恰恰是最彻底
                                   的短交。空白在这里【不是】"没问题",这一句就是不让
                                   它被那样读的全部办法。**绝不**在这里自己补一个
                                   "订量 − 0"的算式:那就是 GRN-1a 拒绝顺手做掉的那张
                                   伴生视图,写在页面里等于写成第二份会漂开的实现。 */
                                <p className="text-sm text-amber-800 border border-amber-300 bg-amber-50 rounded px-3 py-2">
                                    {t('grn.po.noReceipts')}
                                </p>
                            ) : withKinds.length === 0 ? (
                                <p className="text-sm text-green-800">{t('grn.po.lineClean')}</p>
                            ) : grnSettings ? (
                                <DiscrepancyKinds
                                    row={withKinds[0]}
                                    thresholds={grnSettings}
                                    assayHref={`/inbound/${withKinds[0].batch_id}/edit`} />
                            ) : null}

                            {/* 逐条收货点名 —— 行级结论说的是"这一行短了",而人还要
                                知道它是由哪几条收货组成的。 */}
                            {rows.length > 0 && (
                                <p className="text-xs text-gray-500 mt-2">
                                    {t('grn.po.receiptsList')}{' '}
                                    {rows.map((r, i) => (
                                        <span key={r.batch_id}>
                                            {i > 0 && ', '}
                                            <Link href={`/inbound/${r.batch_id}/edit`}
                                                  className="font-mono text-blue-600 hover:underline">
                                                {r.batch_code}
                                            </Link>
                                            <span> ({r.received_qty} {r.received_unit})</span>
                                        </span>
                                    ))}
                                </p>
                            )}
                        </div>
                    )
                })}
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
                    <PoReceiptsTable rows={receiptRows} canFinance={canFinance} />
                </>
            ) : (
                <p className="text-sm text-gray-500">{t('purchasing.noReceipts')}</p>
            )}
            </>)}
        </ListPage>
    )
}
