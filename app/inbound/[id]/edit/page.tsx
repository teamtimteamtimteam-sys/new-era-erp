import Link from 'next/link'
import { formatTimestamp } from '@/lib/format'
import { getBaseCurrency } from '@/lib/currency'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import EditInboundForm from './EditInboundForm'
import PricingPanel, { type PriceHistoryRow } from './PricingPanel'
import LandedCostPanel from './LandedCostPanel'
import PrepaymentPanel, { type PrepaymentApplicationRow } from './PrepaymentPanel'
import AssaySection, { type AssayRow } from './AssaySection'
import RepriceFromContentPanel from './RepriceFromContentPanel'
import MetalContentPanel from '@/app/components/metals/MetalContentPanel'
import { priceBatchHref } from '@/app/components/metals/priceBatchHref'
import type { MetalContentRow } from '@/app/components/metals/metalContentTypes'
import { saveInboundMetal, deleteInboundMetal } from '@/app/components/metals/metalContentActions'
import MovementTimeline from '@/app/components/inventory/MovementTimeline'
import StockStatusPanel from '@/app/components/inventory/StockStatusPanel'
import type { MovementRow } from '@/app/components/inventory/movementTypes'
import StocktakeQuickCount from '@/app/stocktakes/StocktakeQuickCount'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import IntakeConditionPanel from './IntakeConditionPanel'
import DeepDischargePanel from './DeepDischargePanel'
import ImportDiligencePanel from './ImportDiligencePanel'
import { can, canViewPrices } from '@/lib/permissions'
import { maskedRows, maskedExcept } from '@/lib/maskedRows'
import type { Tables } from '@/lib/database.types'
import { mustRows, mustOne } from '@/lib/db-helpers'
import { loadMaterialAxes } from '@/app/inbound/intakeConditionQuery'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { loadSubstanceLabels, toOptions } from '@/app/metal-prices/substanceQuery'
import DiscrepancyKinds, {
    type DiscrepancyRow as GrnRow,
    type ReceivingThresholds as GrnThresholds,
} from '@/app/components/receiving/DiscrepancyKinds'

// FK 嵌入运行时是对象;显式类型 + cast 锁住。
type MovementFetchRow = {
    id: string
    movement_type: string
    qty_delta: number
    stock_status: string
    business_date: string | null
    notes: string | null
    occurred_at: string
    processing_runs: { id: string; code: string } | null
}

export default async function EditInboundPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.inbound)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const t = await getTranslations()
    const locale = await getLocale()

    // PROC-4:物质清单从 substances 那张字典读 —— 【连停用的一起读】,
    // 因为这一页要把历史含量行里的码翻成名字,而停用不该让历史数据变成光秃秃的 code。
    const substanceOptions = toOptions(await loadSubstanceLabels(supabase))

    // ── PROC-2b:到货状态的两条轴 ────────────────────────────────────────────
    // 【读之前先对遮蔽清单】(S2):
    //   * inbound_batches 是【遮蔽表】—— 本页的 batch 已经走 inbound_batches_masked,
    //     所以 chemistry_certainty_code 直接从它上面取,不另查表;
    //   * inbound_batch_safety_states 实测【没有】_masked 伴生,表级 SELECT 授权,直读;
    //   * 两张字典同样没有伴生视图,表级授权,直读。
    // PROC-1B-iii:第三张字典 —— 【能不能深度放电】。它同样没有 _masked 伴生,
    // 表级 SELECT 授权,直读。**它与上面两条轴【不是同一条】**:那两条讲
    // "这批料现在是什么状态"(起火闸读它),本条讲"这批料压根能不能放电"。
    const [statesRes, certRes, pickedRes, ddRes] = await Promise.all([
        supabase.from('inbound_safety_states')
            .select('code, name_en, name_zh, may_be_fed').eq('is_active', true).order('sort_order'),
        supabase.from('inbound_chemistry_certainties')
            .select('code, name_en, name_zh, may_be_fed').eq('is_active', true).order('sort_order'),
        supabase.from('inbound_batch_safety_states')
            .select('safety_state_code').eq('inbound_batch_id', id),
        supabase.from('deep_discharge_judgements')
            .select('code, name_en, name_zh').eq('is_active', true).order('sort_order'),
    ])
    const safetyStates = mustRows(statesRes, 'inbound_safety_states')
    const certainties = mustRows(certRes, 'inbound_chemistry_certainties')
    const pickedStates = (mustRows(pickedRes, 'inbound_batch_safety_states') as { safety_state_code: string }[])
        .map((r) => r.safety_state_code)
    const ddOptions = (mustRows(ddRes, 'deep_discharge_judgements') as
        { code: string; name_en: string; name_zh: string }[])
        .map((r) => ({ code: r.code, label: locale === 'zh' ? r.name_zh : r.name_en }))
    const canEditInbound = await can('module.inbound.edit')
    // ★【跨模块:采购行躲在 module.purchasing.view 后面(OPS-14 的 xmodule)】★
    // 一个只有进料权限的人读 purchase_order_lines 会被 RLS 静默丢行,
    // 而"丢了行"与"那一列是空的"读出来一模一样。取一次权限码,把两者分开渲染 ——
    // 与本页上面 canFinance 那一处同源。
    const canViewPurchasing = await can('module.purchasing.view')
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const [batchRes, materialsRes, suppliersRes, metalsRes, movementsRes, stocktakeRes, priceHistoryRes] = await Promise.all([
        supabase
            .from('inbound_batches_masked')
            .select('*')
            .eq('id', id)
            .is('deleted_at', null)
            .single(),
        supabase
            .from('materials')
            .select('id, code, name')
            .is('deleted_at', null)
            .order('name'),
        supabase
            .from('suppliers')
            .select('id, code, legal_name')
            .is('deleted_at', null)
            // LOG-1b:货代不进供应商名单(他们保留 supplier id 只为账上那条链)
            .neq('counterparty_type', 'forwarder')
            .order('legal_name'),
        supabase
            .from('inbound_batch_metals')
            // PROC-1b:含量带出处 —— 化验来源嵌出单据号,行上要看得见是谁说的数
            .select('metal, content_pct, updated_at, content_source, source_assay:assay_results!inbound_batch_metals_source_assay_id_fkey ( id, code )')
            .eq('inbound_batch_id', id)
            .order('metal'),
        supabase
            .from('inventory_movements')
            .select('id, movement_type, qty_delta, stock_status, business_date, notes, occurred_at, run_id, processing_runs ( id, code )')
            .eq('inbound_batch_id', id)
            .order('occurred_at', { ascending: false }),
        // 进行中的盘点(最新一张):有则在顶部渲染"扫码即点"横幅
        supabase
            .from('stocktakes')
            .select('id, code')
            .eq('status', 'open')
            .is('deleted_at', null)
            .order('created_at', { ascending: false })
            .limit(1),
        // 价格历史(计价面板,cut 1)
        supabase
            .from('price_history_masked')
            .select('id, old_unit_price, new_unit_price, currency, original_price, fx_rate, rate_as_of, rate_type, notes, created_at')
            .eq('inbound_batch_id', id)
            .order('created_at', { ascending: false }),
    ])

    if (batchRes.error || !batchRes.data) {
        notFound()
    }

    if (materialsRes.error || suppliersRes.error) {
        const err = materialsRes.error ?? suppliersRes.error
        return (
            <div className="p-8 max-w-2xl">
                <h1 className="text-2xl font-bold mb-4">{t('inbound.editTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('inbound.dropdownLoadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(err, null, 2)}</pre>
                </div>
            </div>
        )
    }

    // cut 2b:改读遮蔽视图(select('*') 会碰到被收回的 unit_price)。
    // 只有 unit_price 会被遮蔽,其余列恢复基表类型。
    const batch = maskedExcept<Tables<'inbound_batches'>, 'unit_price'>(batchRes.data)

    // PROC-1B-iii:采购行上买的时候下的那个判断,摆到实际值旁边。
    // 【只在【看得见】的时候去读】—— 没有权限时不发这次查询,并让面板
    // 按名说"你看不到采购侧",而不是印一个会骗人的"未填写"。
    let judgedDeepDischarge: string | null = null
    if (canViewPurchasing && batch.purchase_order_line_id) {
        const { data: polRow } = await supabase
            // 【读遮蔽视图,不直连表】(S2)purchase_order_lines 是遮蔽表 ——
            // 直连会让一个部分权限的读者整条查询 42501,而 _masked 只把被扣下的
            // 列呈现成 null。本处只取判断那一列,它不在被扣之列。
            .from('purchase_order_lines_masked')
            .select('deep_discharge_judgement_code')
            .eq('id', batch.purchase_order_line_id)
            .maybeSingle()
        judgedDeepDischarge = polRow?.deep_discharge_judgement_code ?? null
    }

    // ── PROC-COST-1:落地成本的两个【非采购价】组件 ──────────────────────────
    // 【页面不重算任何一条】两个数都由数据库那一份实现给出,与
    // allocate_processing_costs 的材料成本表达式读的是同一个函数 ——
    // 一份实现、两个调用者(AGENTS.md 反复付过账的那条)。
    // 【mustOne,不是 ?? 0】读不出来必须【报错】:一个读失败被吞成 0 的落地成本,
    // 在屏幕上与"这批货没花过运费和加工成本"一模一样。
    const [freightRes, procCostRes] = await Promise.all([
        supabase.rpc('batch_freight_base', { p_inbound_batch_id: id }),
        supabase.rpc('batch_processing_cost_base', { p_inbound_batch_id: id }),
    ])
    const freightBase = mustOne(freightRes as never, 'batch_freight_base') as number | null
    const processingBase = mustOne(procCostRes as never, 'batch_processing_cost_base') as number | null
    // 采购价 = quantity × unit_price —— 与 ap_open_items 同一个算式。
    // 【没定过价是 null,不是 0】"还没定价"与"定价为零"是两件事。
    const purchaseBase =
        batch.unit_price === null || batch.unit_price === undefined
            ? null
            : Number(batch.quantity) * Number(batch.unit_price)

    // 【PROC-2c:这批货的种类说不说得上这两条轴】PROC-2b 把这一块无条件摆了出来,
    // 而 PROC-2c 之后库里有了 guard_inbound_condition_applicable —— 于是一箱吨袋的
    // 批次页面上会摆着一组【服务端保证会拒】的控件,正是 AGENTS.md 禁的那件事。
    // 这不是 PROC-2b 写错了:那时那道守卫还不存在,页面与服务端是一致的。
    // **一条新守卫会让别处一个本来诚实的控件变成一个骗人的控件** —— 加守卫时要回头
    // 看一眼谁在摆这个动作,这是本刀记下来的一条。
    //
    // 判据与建批次那两条路【读同一支】(loadMaterialAxes),因为它们问的是同一个
    // 问题;而那一支的判据又与库里那道守卫逐字同源:**查不到种类 = 没有人记过,
    // 那【不是】"不适用"**,照常可编辑(库那一侧此时也放行)。
    const materialAxes = await loadMaterialAxes(supabase)
    const axis = materialAxes[batch.material_id]
    const conditionApplicable = axis ? axis.has_axes : true
    const conditionKindLabel = axis ? (locale === 'zh' ? axis.kind_zh : axis.kind_en) : ''


    // 化验(cut 5b):本批次的化验单(新到旧)+ 会生效的定价公式
    // (解析顺序与 apply_assay_result 一致:批次 → 采购单明细行)
    const [assayRes, poLineFormulaRes] = await Promise.all([
        supabase
            .from('assay_results')
            .select('id, code, assay_date, lab_name, is_final, applied_at')
            .eq('inbound_batch_id', id)
            .is('deleted_at', null)
            .order('assay_date', { ascending: false })
            .order('code', { ascending: false }),
        batch.purchase_order_line_id
            ? supabase
                  .from('purchase_order_lines')
                  .select('pricing_formula_id')
                  .eq('id', batch.purchase_order_line_id)
                  .single()
            : Promise.resolve({ data: null, error: null }),
    ])
    const assayRows = (mustRows(assayRes)) as AssayRow[]

    // ── ASY-P2:这个批次的化验要求现状 ──────────────────────────────────────
    // 【两次查询,因为"没有缺口"有两种意思】batch_required_assay_gaps 里没有这一行,
    // 可能是【全验齐了】,也可能是【这个物料压根没有化验要求】—— 屏幕上那是两句
    // 完全不同的话,所以要求本身要单独问一次。把它们合成一个 boolean 就是把
    // "没有政策"显示成"已经做完了"。
    // 【失败必须失败】两处都用 mustRows:读不出来会渲染成"无化验要求",
    // 而那是这一族最不能撒的谎。
    const [gapRes, reqRes] = await Promise.all([
        supabase
            .from('batch_required_assay_gaps')
            .select('missing_metals, sampleable')
            .eq('inbound_batch_id', batch.id),
        supabase
            .from('material_required_metals')
            .select('metal')
            .eq('material_id', batch.material_id),
    ])
    const assayGap = (mustRows(gapRes) as unknown as
        { missing_metals: string[]; sampleable: boolean }[])[0] ?? null
    const hasAssayRequirement = mustRows(reqRes).length > 0
    const resolvedFormulaId: string | null =
        batch.pricing_formula_id ?? poLineFormulaRes.data?.pricing_formula_id ?? null

    // FIN-27:这批货按哪一份【承诺条款】结算 —— 解析次序与 resolve_pricing_commitment
    // 一致(批次自己的 → 它那条采购行的)。有公式引用却没有副本的批次,结算会点名
    // 拒(PRICING_TERMS_NOT_COMMITTED);那不是要瞒着操作员到按下按钮才说的事,
    // 所以这里就说,并且不渲染一个注定被拒的按钮。
    const commitmentRes = await supabase
        .from('pricing_term_commitments')
        .select('id, source_formula_code, committed_at, inbound_batch_id, purchase_order_line_id')
        .or(
            [
                `inbound_batch_id.eq.${id}`,
                batch.purchase_order_line_id
                    ? `purchase_order_line_id.eq.${batch.purchase_order_line_id}`
                    : null,
            ]
                .filter(Boolean)
                .join(',')
        )
    const commitmentRows = mustRows(commitmentRes)
    const commitment =
        commitmentRows.find((c) => c.inbound_batch_id === id) ??
        commitmentRows.find((c) => c.purchase_order_line_id === batch.purchase_order_line_id) ??
        null

    // 关联采购单(cut 4c):头部链接 + 行下单量;抵扣预付的资格/建议额与已抵扣记录
    let poHeader: { po_id: string; po_code: string; ordered_qty: number | null; unit: string } | null = null
    let applicable: {
        purchase_order_id: string
        po_code: string
        batch_ap_open_base: number
        po_unapplied_prepayment_base: number
        applicable_base: number
    } | null = null
    let prepaymentHistory: PrepaymentApplicationRow[] = []
    if (batch.purchase_order_id) {
        const [poRes, lineRes, applicableRes, historyRes] = await Promise.all([
            supabase.from('purchase_orders').select('id, code').eq('id', batch.purchase_order_id).single(),
            batch.purchase_order_line_id
                ? supabase
                      .from('purchase_order_lines')
                      .select('quantity, unit')
                      .eq('id', batch.purchase_order_line_id)
                      .single()
                : Promise.resolve({ data: null, error: null }),
            // 资格与建议额【只从视图读】—— 与 apply_prepayment 同一口径
            supabase
                .from('po_prepayment_applicable')
                .select('purchase_order_id, po_code, batch_ap_open_base, po_unapplied_prepayment_base, applicable_base')
                .eq('inbound_batch_id', id)
                .maybeSingle(),
            supabase
                .from('prepayment_applications_masked')
                .select('id, amount_base, created_at, journal_entry_id, journal_entries(id, code)')
                .eq('inbound_batch_id', id)
                .order('created_at', { ascending: false }),
        ])
        // GRN-1a:【失败必须失败】此前这三处的错误一个都没被读过。
        // 最贵的是 lineRes —— 它的 `?? null` 让【查不出订单量】与【这一行本来
        // 就没有订单量】在屏幕上一模一样,而 GRN-1a 之后订单量正是"收够了没有"
        // 这个判断的左边那个数:读成空的页面会安静地说不出短交。
        // poRes 同理:失败时 poHeader 停在 null,于是一张【挂着采购单】的批次
        // 渲染得跟自采收货一分不差 —— 连采购单链接都不见了。
        // (lineRes 那条三元分支给出的是 {data:null,error:null},那是【真的没有
        //  明细行】,mustOne 照直返回 null —— 两者从此分得开。)
        const poRow = mustOne(poRes, '采购单表头')
        const lineRow = mustOne(lineRes, '采购单明细行')
        if (poRow) {
            poHeader = {
                po_id: poRow.id,
                po_code: poRow.code,
                ordered_qty: lineRow?.quantity ?? null,
                unit: lineRow?.unit ?? batch.unit,
            }
        }
        // 视图列在生成类型里全可空;行进视图即非空(WHERE 已保证),此处锁死。
        // OPS-12:失败必须抛,不许读成"没有可抵扣的预付" —— 那个数字决定操作员
        // 抵不抵扣,读成空与"确实没有预付"在屏幕上一模一样。
        applicable = mustOne(applicableRes) as typeof applicable
        // 同上:已抵扣记录读不出来时,页面会说"一次都没抵扣过" —— 而操作员
        // 正是照着这句话决定要不要再抵一次。
        prepaymentHistory = (mustRows(historyRes) as unknown as {
            id: string
            amount_base: number
            created_at: string
            journal_entries: { id: string; code: string } | null
        }[]).map((h) => ({
            id: h.id,
            amount_base: h.amount_base,
            created_at_display: formatTimestamp(h.created_at, dateLocale),
            journal_id: h.journal_entries?.id ?? null,
            journal_code: h.journal_entries?.code ?? null,
        }))
    }

    // ── GRN-1b:这一条收货的差异 ────────────────────────────────────────────
    // 【三种"没有"必须分得开,而它们在屏幕上长得一模一样】
    //   ① 这一批没挂采购行  → 视图里根本没有它。不是"没有差异",是【没得比】;
    //   ② 挂了行、但一切正常 → 视图里有它,kinds 是空数组;
    //   ③ 读不出来          → mustOne 抛,页面报错(绝不渲染成 ① 或 ②)。
    // 判据取 batch.purchase_order_line_id —— 它是【视图收不收这一行的那个条件】
    // 本身,不是从空结果倒推出来的猜测。
    // 阈值与判词一起发:判词是视图用【当时那三个数】算的,两者之间有人改了阈值,
    // 屏幕会显示新阈值配旧判词。窄,但写下来而不是假装没有。
    const [grnRes, grnSettingsRes] = await Promise.all([
        supabase
            .from('grn_discrepancies')
            .select('batch_id, batch_code, po_code, po_status, line_no, ' +
                    'ordered_material_code, received_material_code, ordered_qty, ordered_unit, ' +
                    'received_qty, received_unit, declared_qty, line_received_qty, ' +
                    'line_receipt_count, line_delta_qty, line_delta_pct, declared_delta_qty, ' +
                    'assay_beyond_tolerance, assay_metals_compared, ' +
                    // PROC-1B-iii:两侧的【原始码】都要取 —— 只取那个布尔的话,
                    // 「没设」与「未评估」在屏幕上就并成一句了(两者的布尔都是 NULL)。
                    'deep_discharge_judged, deep_discharge_actual, deep_discharge_contradicted, kinds')
            .eq('batch_id', id)
            .maybeSingle(),
        supabase
            .from('receiving_settings')
            .select('grn_short_pct, grn_over_pct, grn_assay_tolerance_pct')
            .maybeSingle(),
    ])
    const grnRow = mustOne(grnRes, 'grn_discrepancies') as unknown as GrnRow | null
    const grnSettings = mustOne(grnSettingsRes, 'receiving_settings') as GrnThresholds | null
    // 【第四种"没有":你没有权限看订量】这一页的门是 module.inbound.view,
    // 而 grn_discrepancies 的门是 module.purchasing.view —— 两者【不是同一道】。
    // 实测(2026-08-17):warehouse 与 operations 持前者、不持后者,所以他们打得开
    // 这一页、却从视图读到 0 行。少了这个判据,上面那句 notInView(「这不该发生」)
    // 会【对着两个真实角色天天说一句吓人的假话】—— 而真相只是"订量在另一道门后面"。
    // 这正是 lib/permissions.ts 存在的全部理由:null 已经有别的意思了。
    const canSeeOrderedQty = await can(MOD.purchasing.permission)

    // 本批在进行中盘点里的已录实点数(有则预填横幅)
    const openStocktake = stocktakeRes.data?.[0] ?? null
    let stocktakeCounted: number | null = null
    if (openStocktake) {
        const { data: countLine } = await supabase
            .from('stocktake_lines')
            .select('counted_qty')
            .eq('stocktake_id', openStocktake.id)
            .eq('inbound_batch_id', id)
            .maybeSingle()
        stocktakeCounted = countLine?.counted_qty ?? null
    }

    // 价格历史行:服务端预格式化 created_at
    const showPrices = await canViewPrices()
    const priceHistoryRows: PriceHistoryRow[] = maskedRows<
        Tables<'price_history'>,
        'old_unit_price' | 'new_unit_price' | 'original_price' | 'fx_rate'
    >(mustRows(priceHistoryRes)).map((h) => ({
        id: h.id,
        old_unit_price: h.old_unit_price,
        new_unit_price: h.new_unit_price,
        currency: h.currency,
        original_price: h.original_price,
        fx_rate: h.fx_rate,
        // FIN-21:牌价取自哪一天、哪一侧。定价日(SG 日历)用来判断要不要标"取自":
        // PostgREST 现按业务时区吐 +08:00 偏移,slice(0,10) 即 SG 日期。
        rate_as_of: h.rate_as_of,
        rate_type: h.rate_type,
        priced_date: h.created_at?.slice(0, 10) ?? null,
        notes: h.notes,
        created_at_display: formatTimestamp(h.created_at, dateLocale),
    }))

    // 金属含量行:服务端预格式化 updated_at,避免客户端水合不一致。
    // PROC-1b:出处列 —— 化验(单据号,可点)/ 手工 / 出处未知。第三种状态在
    // 进料侧是真的:PROC-1 之前录的行 content_source 为 NULL,不回填(FIN-26),
    // 界面照直说「未知」而不是把它演成手工或化验。
    type MetalFetchRow = {
        metal: string
        content_pct: number
        updated_at: string
        content_source: string | null
        source_assay: { id: string; code: string } | null
    }
    const metalRows: MetalContentRow[] = ((mustRows(metalsRes)) as unknown as MetalFetchRow[]).map((m) => ({
        metal: m.metal,
        content_pct: m.content_pct,
        updated_at_display: formatTimestamp(m.updated_at, dateLocale),
        source_kind: m.content_source === 'assay' ? 'assay' : m.content_source === 'manual' ? 'manual' : 'unknown',
        source_label:
            m.content_source === 'assay'
                ? m.source_assay?.code ?? t('metalContent.sourceAssay')
                : m.content_source === 'manual'
                    ? t('metalContent.sourceManual')
                    : t('metalContent.sourceUnknown'),
        source_href:
            m.content_source === 'assay' && m.source_assay
                ? `/inbound/${id}/assays/${m.source_assay.id}`
                : null,
    }))

    // 库存流水行:服务端预格式化 occurred_at
    const movementRows: MovementRow[] = ((movementsRes.data as unknown as MovementFetchRow[] | null) ?? []).map((m) => ({
        id: m.id,
        movement_type: m.movement_type,
        qty_delta: m.qty_delta,
        stock_status: m.stock_status,
        business_date: m.business_date,
        notes: m.notes,
        occurred_at_display: formatTimestamp(m.occurred_at, dateLocale),
        run: m.processing_runs,
    }))

    return (
        <div className="p-4 sm:p-8 max-w-2xl">
            <div className="mb-6">
                <Link
                    href="/inbound"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-xl sm:text-2xl font-bold mb-2">{t('inbound.editTitle')}</h1>
            <p className="text-sm text-gray-600 mb-6">
                <span className="font-mono">{batch.code}</span>
                <span className="mx-2">·</span>
                <span className="px-2 py-0.5 bg-gray-200 rounded text-xs">
                    {batch.status}
                </span>
                {/* 定价状态(cut 5b):暂定价 = 还没按正式化验重算过 */}
                <span
                    className={
                        'ml-2 px-2 py-0.5 rounded text-xs ' +
                        (batch.pricing_status === 'final'
                            ? 'bg-green-100 text-green-800'
                            : batch.pricing_status === 'provisional'
                              ? 'bg-amber-100 text-amber-800'
                              : 'bg-gray-200 text-gray-600')
                    }
                >
                    {t('assay.pricingStatus.' + batch.pricing_status)}
                </span>
                <a
                    href={`/inbound/${batch.id}/label`}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="ml-3 text-blue-600 hover:underline"
                >
                    {t('batchLabel.print')}
                </a>
                {poHeader && (
                    <span className="ml-3">
                        {t('inbound.againstPo')}:{' '}
                        <Link
                            href={`/purchasing/orders/${poHeader.po_id}`}
                            className="text-blue-600 hover:underline font-mono"
                        >
                            {poHeader.po_code}
                        </Link>
                        {poHeader.ordered_qty !== null && (
                            <span className="text-gray-500">
                                {' '}({t('inbound.poLineOrdered', { qty: poHeader.ordered_qty, unit: poHeader.unit })})
                            </span>
                        )}
                    </span>
                )}
            </p>

            {/* GRN-1b:这一条收货的差异。摆在表单【上面】—— 看这块屏的人在改任何
                东西之前,先该知道这批货与单子对不对得上。
                三种"没有"三句话,绝不合并成一句(合并就等于让"没得比"读作"没问题"):
                  · 没挂采购行 → 【没得比】,并说清是为什么;
                  · 挂了、正常 → 【对得上】,并把比过的两个数摆出来当证据;
                  · 有差异     → 逐条点名(DiscrepancyKinds)。 */}
            <div className="mb-6">
                <h2 className="text-sm font-medium text-gray-700 mb-2">{t('grn.batch.heading')}</h2>
                {!batch.purchase_order_line_id ? (
                    <p className="text-sm text-gray-600 border border-gray-300 rounded px-3 py-2">
                        {t('grn.batch.noPoLine')}
                    </p>
                ) : !canSeeOrderedQty ? (
                    /* 【受限,不是"没有差异"】订量本来就只在采购那道门后面。
                       说"受限"而不是留白 —— 留白会被读成"这批货没问题"。 */
                    <p className="text-sm text-gray-600 border border-gray-300 rounded px-3 py-2">
                        {t('grn.batch.restricted')}
                    </p>
                ) : !grnRow ? (
                    /* 挂了采购行、视图里却没有这一行 —— 【不该发生】。不猜"那就是没问题",
                       因为那正是把一次读取异常粉饰成一句好消息。说出实情。 */
                    <p className="text-sm text-amber-700 border border-amber-300 bg-amber-50 rounded px-3 py-2">
                        {t('grn.batch.notInView')}
                    </p>
                ) : grnRow.kinds.length === 0 ? (
                    <p className="text-sm text-green-800 border border-green-300 bg-green-50 rounded px-3 py-2">
                        {t('grn.batch.clean', {
                            po: grnRow.po_code,
                            ordered: grnRow.ordered_qty,
                            received: grnRow.line_received_qty,
                            unit: grnRow.ordered_unit,
                        })}
                    </p>
                ) : grnSettings ? (
                    /* 【本页不给化验链接】—— 化验区就在这块屏下面几屏的地方,
                       给一个指回本页的链接是噪音。清单页与采购单详情才需要它。 */
                    <DiscrepancyKinds row={grnRow} thresholds={grnSettings} />
                ) : null}
            </div>

            {openStocktake && (
                <StocktakeQuickCount
                    stocktakeId={openStocktake.id}
                    stocktakeCode={openStocktake.code}
                    side="inbound"
                    batchId={batch.id}
                    counted={stocktakeCounted}
                />
            )}

            <EditInboundForm
                batch={batch}
                materials={mustRows(materialsRes)}
                suppliers={mustRows(suppliersRes)}
            />

            <MetalContentPanel
                options={substanceOptions}
                rows={metalRows}
                saveAction={saveInboundMetal.bind(null, id)}
                deleteAction={deleteInboundMetal.bind(null, id)}
                priceHref={priceBatchHref(batch.quantity, metalRows)}
                note={t('assay.metalsFromAssay')}
            />

            {/* 化验(cut 5b):含量从哪来 → 化验 → 价格往哪去,顺序读下来是一条线 */}
            <AssaySection
                batchId={batch.id}
                rows={assayRows}
                missingMetals={assayGap?.missing_metals ?? []}
                hasRequirement={hasAssayRequirement}
                sampleable={assayGap?.sampleable ?? true}
            />

            {/* PROC-COST-1:落地成本拆解 —— 摆在计价面板【之前】,因为看批次成本的人
                先问"这批货一共花了多少",再去看"采购价是怎么定的"。 */}
            <LandedCostPanel
                purchaseBase={purchaseBase}
                freightBase={freightBase}
                processingBase={processingBase}
                baseCurrency={baseCurrency}
                canViewPrices={showPrices}
            />

            <PricingPanel
                baseCurrency={baseCurrency}
                        canViewPrices={showPrices}
                        batchId={batch.id}
                unitPrice={batch.unit_price}
                history={priceHistoryRows}
                extraAction={
                    commitment ? (
                        <RepriceFromContentPanel batchId={batch.id} baseCurrency={baseCurrency} />
                    ) : resolvedFormulaId ? (
                        /* 有公式、没有副本 = FIN-27 之前留下的引用。不回填猜测的条款,
                           也不摆一个服务端保证会拒的按钮 —— 说清楚,指出手工定价这条路。 */
                        <p className="mb-4 text-sm text-amber-700 border border-amber-300 bg-amber-50 rounded px-3 py-2">
                            {t('assay.termsNotCommitted')}
                        </p>
                    ) : null
                }
            />

            {/* 抵扣预付(cut 4c):可抵扣 or 有历史时才渲染 */}
            <PrepaymentPanel batchId={batch.id} applicable={applicable} history={prepaymentHistory} baseCurrency={baseCurrency} />

            {/* STK-1:库存分布(库位 × 状态)与暂扣/释放 —— 摆在流水【上面】,
                因为看批次的人先问「现在有多少可动」,再去看「它是怎么变成这样的」 */}
            {/* PROC-2b:到货状态 —— 摆在库存分布【之前】,因为它回答的是
                「这批货【是什么状态】」,而库存回答的是「它现在在哪、还有多少」。
                【它也是能被【改】的那一块】:一批货到的时候带电,后来才放电并核验,
                而那个转变正是 PROC-3 的闸要能被满足所依赖的东西。 */}
            {conditionApplicable ? (
                <IntakeConditionPanel batchId={id} states={safetyStates as never[]}
                    certainties={certainties as never[]} currentStates={pickedStates}
                    currentCertainty={batch.chemistry_certainty_code ?? null}
                    canEdit={canEditInbound} locale={locale} />
            ) : (
                /* 【不适用时说出是哪一种种类,而不是让这一块凭空消失】——
                   一块无声消失的界面读起来像"这个功能坏了",而不像一个答复。 */
                <div className="mb-8">
                    <h2 className="text-sm font-medium text-gray-700 mb-2">{t('inbound.condition.title')}</h2>
                    <div className="border border-gray-300 rounded p-3 max-w-2xl bg-gray-50">
                        <p className="text-xs text-gray-600">
                            {t('inbound.condition.notApplicable', { kind: conditionKindLabel })}
                        </p>
                    </div>
                </div>
            )}

            {/* ★ PROC-1B-iii(R2):【实际到的货】能不能深度放电 —— 自己一块。 ★
                摆在"到货状态"之后、进口尽调之前,因为它与到货状态是相邻的两个问题
                (那一条问"现在是什么状态",这一条问"压根能不能放电"),
                但它们【不是同一条轴】:那一条是起火闸读的,这一条只影响路由。
                【它对所有进料批都适用】—— 不像到货状态那样受 conditionApplicable
                约束:能不能放电是买这批料时就要回答的问题,与料的种类有没有
                "状态轴"是两回事。 */}
            <DeepDischargePanel batchId={id}
                current={batch.deep_discharge_actual_code ?? null}
                judged={judgedDeepDischarge}
                judgedVisible={canViewPurchasing}
                hasPoLine={batch.purchase_order_line_id !== null}
                options={ddOptions}
                canEdit={canEditInbound} />

            {/* CMPL-1:进口尽调 —— 执照正文要求交货方在【进口当时】持有进口准证。
                它【只记录 + 只告警】,不加拒绝:判得了的那一半(交货方当下有没有一张
                在效的 nea_import 准证)已经由 certificate_types 的 block 处置拦在收货上,
                而"当时有没有"是一件系统确立不了的过去的事实。理由写在
                importDiligenceActions.ts 的抬头,也写在面板上给人看。 */}
            <ImportDiligencePanel batchId={id}
                imported={batch.imported ?? null}
                permitRef={batch.import_permit_ref ?? null}
                verifiedAt={batch.import_permit_verified_at ?? null}
                canEdit={canEditInbound} />

            <StockStatusPanel inboundBatchId={id} unit={batch.unit} />

            <MovementTimeline rows={movementRows} unit={batch.unit} />
        </div>
    )
}
