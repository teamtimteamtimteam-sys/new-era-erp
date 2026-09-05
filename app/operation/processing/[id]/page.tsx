import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import DeleteButton from './DeleteButton'
import CostPanel from './CostPanel'
import LossPanel, { type LossCategory, type LossRow } from './LossPanel'
import AllocateButton from './AllocateButton'
import { type CostEntryRow } from './costTypes'
import { processingStatusLabelKey } from '../../status'
import { metalLabelKey } from '@/app/tools/pricing/metal-prices/options'
import { formatAmount, formatMoneyBare, formatUnitCost, formatTimestamp } from '@/lib/format'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { maskedRows, maskedExcept } from '@/lib/maskedRows'
import type { Tables } from '@/lib/database.types'
import { canViewPrices, can } from '@/lib/permissions'
import { MaskedValue } from '@/app/components/MaskedValue'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { getBaseCurrency } from '@/lib/currency'
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
// LineageRow 这个名字页面自己已经用掉了(batch_lineage 的行形状),
// 所以表那一侧的行类型换个名字进来 —— 不改页面既有的那个类型。
import {
    WoVarianceTable, type WoVarianceRow,
    LineageTable, type LineageRow as LineageTableRow,
    InputsTable, type InputLegRow,
    OutputsTable, type OutputLegRow,
    RecoveryTable, type RecoveryRow,
} from './ProcessingTables'

// FK 嵌入运行时是对象(包括两层嵌套);显式类型 + cast 锁住。
type ProcessingInputRow = {
    id: string
    quantity_consumed: number
    inbound_batches: {
        id: string
        code: string
        unit: string
        deleted_at: string | null
        materials: { name: string } | null
    } | null
    // FIN-25:再加工投料 —— 双亲恰一非空
    output_batches: {
        id: string
        code: string
        unit: string
        deleted_at: string | null
        materials: { name: string } | null
    } | null
}

type ProcessingOutputRow = {
    id: string
    quantity_produced: number
    allocated_cost_base: number | null
    unit_cost_base: number | null
    cost_incomplete: boolean
    output_batches: {
        id: string
        code: string
        unit: string
        purity: string | null
        deleted_at: string | null
        materials: { name: string } | null
    } | null
}

export default async function ProcessingDetailPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.processing)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    // CCY-1:概况块的三个成本是 *_base 而【一个币种都没写】,底下产出表的列头却写着
    // 「分摊成本 (SGD)」—— 同一页两种待遇,上面那三个就成了没人认领的数字。
    // 本位币从 currencies.is_base 取(不写死),三个数各自带上它。
    const baseCurrency = await getBaseCurrency()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const [runRes, inputsRes, outputsRes, costsRes, recoveryRes] = await Promise.all([
        supabase
            .from('processing_runs_masked')
            .select('*')
            .eq('id', id)
            .is('deleted_at', null)
            .single(),
        supabase
            .from('processing_inputs')
            .select('id, quantity_consumed, inbound_batches ( id, code, unit, deleted_at, materials ( name ) ), output_batches ( id, code, unit, deleted_at, materials ( name ) )')
            .eq('run_id', id)
            .order('created_at'),
        supabase
            .from('processing_outputs_masked')
            .select('id, quantity_produced, allocated_cost_base, unit_cost_base, cost_incomplete, output_batches ( id, code, unit, purity, deleted_at, materials ( name ) )')
            .eq('run_id', id)
            .order('created_at'),
        supabase
            .from('processing_cost_entries_masked')
            .select('id, cost_type, amount_base, is_estimate, notes, created_at, updated_at, updated_by')
            .eq('run_id', id)
            .is('deleted_at', null)
            .order('created_at'),
        supabase
            .from('processing_metal_recovery')
            // PROC-1c:两侧出处一并取 —— 守恒警告要说得出自己比的是
            // 【实验室 vs 实验室】(真异常)还是【实验室 vs 手敲】(先怀疑打错字)
            .select('metal, input_metal_kg, output_metal_kg, recovery_pct, input_measured, output_measured, recovery_blocked_by, conservation_warning, run_recovery_computable, input_source, output_source')
            .eq('run_id', id)
            .order('metal'),
    ])

    if (runRes.error || !runRes.data) {
        notFound()
    }

    if (inputsRes.error || outputsRes.error) {
        const err = inputsRes.error ?? outputsRes.error
        return (
            <div className="p-8 max-w-3xl">
                <h1 className="text-2xl font-bold mb-4">{t('processing.detailTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('processing.detailLoadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(err, null, 2)}</pre>
                </div>
            </div>
        )
    }

    // cut 2b:改读遮蔽视图(select('*') 会碰到被收回的成本列)。
    const run = maskedExcept<
        Tables<'processing_runs'>,
        'material_cost_base' | 'process_cost_base' | 'total_cost_base' | 'capitalized_cost_base'
    >(runRes.data)
    const inputs = inputsRes.data as unknown as ProcessingInputRow[] | null

    // FIN-25:血缘 —— 本单产出批的【全部】祖先(递归视图;security_invoker,RLS 照常)。
    // 立账公理是全链路可溯,再加工让链条真正变长,这一块是它的眼睛。
    type LineageRow = {
        output_batch_id: string; depth: number; via_run_id: string; via_run_code: string
        parent_kind: string; parent_batch_id: string; parent_code: string | null
        quantity_consumed: number
    }
    const outputIds = ((outputsRes.data as unknown as ProcessingOutputRow[] | null) ?? [])
        .map((o) => o.output_batches?.id).filter(Boolean) as string[]
    let lineage: LineageRow[] = []
    if (outputIds.length > 0) {
        const lineageRes = await supabase
            .from('batch_lineage')
            .select('output_batch_id, depth, via_run_id, via_run_code, parent_kind, parent_batch_id, parent_code, quantity_consumed')
            .in('output_batch_id', outputIds)
            .order('depth')
        lineage = (mustRows(lineageRes, 'batch_lineage') as unknown as LineageRow[])
    }
    const outputs = outputsRes.data as unknown as ProcessingOutputRow[] | null

    const isCommitted = run.status === 'committed'

    // 状态标签(未知值回退原样)
    const statusLabel = (v: string | null) => {
        const k = processingStatusLabelKey(v)
        return k ? t(k) : v ?? '—'
    }

    // 成本条目行:服务端预格式化 created_at
    const showPrices = await canViewPrices()
    // PROC-BUILD-1:损耗分类。字典【现读】—— 加一种损耗是往 loss_categories 加一行,
    // 屏幕不该是第二份权威(materials 那五条轴立的同一条先例)。
    const canEditRun = await can('module.processing.edit')
    const [lossCatRes, lossRowRes] = await Promise.all([
        supabase.from('loss_categories')
            .select('code, name_en, name_zh, metal_fate, is_true_loss')
            .eq('is_active', true).order('sort_order'),
        supabase.from('processing_run_losses')
            .select('loss_category_code, quantity, notes').eq('run_id', id).order('loss_category_code'),
    ])
    const lossCategories = mustRows(lossCatRes, 'loss_categories') as LossCategory[]
    const lossRows = mustRows(lossRowRes, 'processing_run_losses') as LossRow[]

    const rawCosts = maskedRows<Tables<'processing_cost_entries'>, 'amount_base'>(mustRows(costsRes))
    // 改过条目的操作人姓名(一次取回,不逐行查)
    const editorIds = [...new Set(rawCosts
        .filter((c) => c.updated_at !== c.created_at && c.updated_by)
        .map((c) => c.updated_by as string))]
    // ★★【FIX-2b:「谁改的」读不到时要【说出来】,不能留空】★★
    //   employees 的 RLS 是 has_permission('module.hr.view') OR 自己那一行,而
    //   operations【没有】那个码(实测:Phua 读 employees 得 1 行 —— 只有他自己)。
    //   于是这里的名字表几乎总是空的,下面 `?? null` 让 CostPanel 那一格
    //   【什么都不印】—— 屏幕上只剩「改于 X 时」,而没有人。
    //   一个没有主语的改动记录,读起来就是"系统自己改的",那正是
    //   app/components/ActorName.tsx 抬头第 ④ 条整段在防的东西。
    //
    //   ★ 为什么不是 (a):employee_lookup 的体内谓词是 hr.view OR finance.view,
    //     operations 两个都没有 —— 要用它就得放宽那张视图的谓词,而那是一次
    //     真的扩权(把整份员工名册给运营),不是换一个读法。所以走 (b):
    //     判据取一次,读不到时印一句具名的「受限」。
    const canSeeEmployees = await can('module.hr.view')
    const editorName = new Map<string, string>()
    if (editorIds.length) {
        for (const e of mustRows(await supabase.from('employees')
            .select('user_id, legal_name').in('user_id', editorIds), 'employees editors')) {
            if (e.user_id) editorName.set(e.user_id, e.legal_name)
        }
    }

    const costRows: CostEntryRow[] = rawCosts.map((c) => ({
        id: c.id,
        cost_type: c.cost_type,
        amount_base: c.amount_base,
        is_estimate: c.is_estimate,
        notes: c.notes,
        created_at_display: formatTimestamp(c.created_at, dateLocale),
        edited_at_display: c.updated_at !== c.created_at
            ? formatTimestamp(c.updated_at, dateLocale) : null,
        // 三态,与 ActorName 同形:查得到印名字 · 查不到但看得见人事 = 真的没这个人
        // (仍是 null,由面板印一个诚实的空)· 看不见人事 = 具名的「受限」。
        edited_by_name: !c.updated_by
            ? null
            : editorName.get(c.updated_by) ?? (canSeeEmployees ? null : t('common.restricted')),
    }))

    // FIN-8:分摊是否已过期 —— 改了成本条目,总账会动,批次不会自己重算。
    // 视图还告诉我们【能不能安全重跑】(已过账的 COGS 不会被重述,见迁移头注)。
    type AllocStatus = {
        allocated_at: string | null; last_cost_change: string | null
        is_stale: boolean | null; cogs_posted: number | null; safe_to_reallocate: boolean | null
    }
    const allocStatus = mustOne<AllocStatus>(await supabase.from('processing_run_allocation_status')
        .select('allocated_at, last_cost_change, is_stale, cogs_posted, safe_to_reallocate')
        .eq('run_id', id).maybeSingle(), 'processing_run_allocation_status')

    // 回收率行(视图已按 committed + 未软删过滤)
    const recoveryRows = mustRows(recoveryRes)

    // REC-1:整单的话由数据说(视图里的窗口聚合),不由页面从数字反推。
    // 【投产之后无法补救】—— 所以这句话只出现在单据上,不上看板:一盏关不掉的
    // 灯就是 hr_alerts 那盏常亮灯换个地方(预防那一半归看板的 awaiting_assay 支)。
    const recoveryComputable = recoveryRows.length === 0 || recoveryRows[0].run_recovery_computable !== false
    // 守恒提示:【只在两侧都测过】时才可能为真 —— 没测过的投入没有可守恒的对象。
    const conservationRows = recoveryRows.filter((r) => r.conservation_warning)
    const metalLabel = (v: string | null) => {
        const k = metalLabelKey(v)
        return k ? t(k) : v ?? '—'
    }

    // PROC-1c:含量出处的标签。四个取值来自视图的聚合(assay / manual / mixed /
    // unknown),NULL = 那一侧根本没测 —— 没测过的边没有出处可言,不画。
    // 【逐个字面量写死,不拼 key】:'mixed' 在视图里是字面量,另外三个是
    // min(COALESCE(content_source,'unknown')) 算出来的,check-i18n 的动态键解析
    // 取不到它们 —— 而一个解析不出后缀的动态前缀按约定是【失败】,不是放行。
    const sourceLabel = (s: string | null) =>
        s === 'assay' ? t('processing.recovery.source.assay')
            : s === 'manual' ? t('processing.recovery.source.manual')
                : s === 'mixed' ? t('processing.recovery.source.mixed')
                    : t('processing.recovery.source.unknown')

    // 守恒警告分得出自己站在哪一种情形里。两侧都测过是警告成立的前提,所以
    // 这里只在 assay/manual/mixed/unknown 之间判:
    //   * 两侧都是化验 → 真异常,值得追(拿错批、污染),不是打错字;
    //   * 任一侧出处未记 → 说不出是哪一种,照直说,不猜;
    //   * 其余(含 mixed)→ 至少有一侧不是纯化验数,先去看那一侧。
    // 顺序要紧:unknown 先判,否则 'assay' + 'unknown' 会被当成"有手敲的"。
    const anomalyCauseKey = (r: { input_source: string | null; output_source: string | null }) =>
        r.input_source === 'unknown' || r.output_source === 'unknown'
            ? 'processing.recovery.anomalyCauseUnknownSource'
            : r.input_source === 'assay' && r.output_source === 'assay'
                ? 'processing.recovery.anomalyCauseBothAssay'
                : 'processing.recovery.anomalyCauseNotBothAssay'

    // 分摊信息:上次分摊时间 + 基准标签
    // ── WO-1c:这次加工照的那张工单,以及它的差异 ───────────────────────────
    // 【差异不在这里算】两个数都取自 work_order_fulfilment —— 页面自己减一遍,
    // 就是给同一个规则留下第二处实现(AGENTS.md:一处推导,N 个消费者)。
    const woId = (run as { work_order_id?: string | null }).work_order_id ?? null
    const wo = woId
        ? (mustOne(await supabase.from('work_orders').select('id, code, status')
                    .eq('id', woId).maybeSingle(), 'work_orders') as
            { id: string; code: string; status: string } | null)
        : null
    const woVariance = woId
        ? (mustRows(await supabase.from('work_order_fulfilment')
                .select('side, material_code, material_name, planned_or_expected_qty, actual_qty, variance_qty, has_plan')
                .eq('work_order_id', woId), 'work_order_fulfilment') as {
                    side: string; material_code: string | null; material_name: string | null
                    planned_or_expected_qty: number | null; actual_qty: number
                    variance_qty: number | null; has_plan: boolean }[])
        : []

    const allocatedWhen = run.allocated_at
        ? formatTimestamp(run.allocated_at, dateLocale)
        : null
    const basisLabel =
        run.allocation_basis === 'metal_value' || run.allocation_basis === 'weight'
            ? t('processing.allocation.basis.' + run.allocation_basis)
            : run.allocation_basis

    // 分摊快照里未参与价值分摊的金属(没有价格),用于提示
    const snapshot = run.allocation_snapshot as { skipped_metals?: unknown } | null
    const skippedMetals = Array.isArray(snapshot?.skipped_metals)
        ? (snapshot!.skipped_metals as string[])
        : []

    // ── 行数据在服务端压平 ─────────────────────────────────────────────────
    // CONV-1 §① 那条:`Column.render` 是函数,过不了 RSC 边界,所以表在客户端,
    // 而【数据】在这里就变成字符串与布尔值 —— 客户端组件不碰 supabase,也不碰
    // 权限判断(showPrices 已经在这里问过了,过界的只是它的结果)。
    const varianceRows: WoVarianceRow[] = woVariance.map((v, i) => ({
        id: String(i),
        sideLabel: t(v.side === 'input' ? 'processing.wo.inputSide' : 'processing.wo.outputSide'),
        material: v.material_code ?? '—',
        plannedText: v.has_plan
            ? String(v.planned_or_expected_qty)
            : t(v.side === 'input' ? 'processing.wo.unplannedMaterial' : 'processing.wo.noExpectation'),
        plannedMuted: !v.has_plan,
        actualText: String(v.actual_qty),
        // null 是【无从相减】,不是 0 —— 表里画成灰横杠,与转换前逐字相同。
        varianceText: v.variance_qty == null
            ? null
            : (Number(v.variance_qty) > 0 ? '+' : '') + String(v.variance_qty),
        varianceNegative: v.variance_qty != null && Number(v.variance_qty) < 0,
    }))

    const lineageTableRows: LineageTableRow[] = lineage.map((l, i) => ({
        id: `${l.parent_batch_id}-${l.depth}-${i}`,
        depth: l.depth,
        viaRunCode: l.via_run_code,
        parentCode: l.parent_code ?? '—',
        parentHref: l.parent_kind === 'inbound'
            ? `/inbound/${l.parent_batch_id}/edit`
            : `/output/${l.parent_batch_id}/edit`,
        parentKindLabel: t('processing.lineage.kind_' + l.parent_kind),
        qty: String(l.quantity_consumed),
    }))

    const inputRows: InputLegRow[] = (inputs ?? []).map((leg) => {
        // FIN-25:双亲投料 —— 进料批或(再加工)产出批
        const parent = leg.inbound_batches ?? leg.output_batches
        return {
            id: leg.id,
            parentCode: parent?.code ?? null,
            parentHref: leg.inbound_batches
                ? `/inbound/${leg.inbound_batches.id}/edit`
                : leg.output_batches ? `/output/${leg.output_batches.id}/edit` : null,
            parentDeleted: !!parent?.deleted_at,
            deletedMarker: t('processing.detail.deletedMarker'),
            reprocessed: !!leg.output_batches,
            material: parent?.materials?.name ?? '—',
            qtyText: `${leg.quantity_consumed} ${parent?.unit ?? ''}`.trim(),
        }
    })

    const outputRows: OutputLegRow[] = (outputs ?? []).map((leg) => ({
        id: leg.id,
        batchCode: leg.output_batches?.code ?? null,
        batchHref: leg.output_batches ? `/output/${leg.output_batches.id}/edit` : null,
        batchDeleted: !!leg.output_batches?.deleted_at,
        deletedMarker: t('processing.detail.deletedMarker'),
        material: leg.output_batches?.materials?.name ?? '—',
        qtyText: `${leg.quantity_produced} ${leg.output_batches?.unit ?? ''}`.trim(),
        purity: leg.output_batches?.purity != null ? String(leg.output_batches.purity) : '—',
        // 遮蔽后是 null,和「尚未分摊」是两回事 —— 前者显示「受限」,后者才是「—」。
        // 两者都画成 — 会让运营以为成本没算。判断留在服务端,MaskedValue 在客户端。
        allocatedCostText: leg.allocated_cost_base === null
            ? null : formatMoneyBare(leg.allocated_cost_base, '列头「分摊成本 (SGD)」'),
        unitCostText: leg.unit_cost_base === null
            ? null : formatUnitCost(leg.unit_cost_base) + ' /kg',
        costIncomplete: !!leg.cost_incomplete,
    }))

    const recoveryTableRows: RecoveryRow[] = recoveryRows.map((r, idx) => ({
        id: String(r.metal ?? idx),
        metalLabel: metalLabel(r.metal),
        inputMeasured: !!r.input_measured,
        inputText: String(r.input_metal_kg),
        inputSource: sourceLabel(r.input_source),
        outputMeasured: !!r.output_measured,
        outputText: String(r.output_metal_kg),
        outputSource: sourceLabel(r.output_source),
        recoveryPctText: r.recovery_pct != null ? r.recovery_pct.toFixed(2) + '%' : null,
        blockedReason: t('processing.recovery.blocked.' + (r.recovery_blocked_by ?? 'input_not_measured')),
    }))

    return (
        <ListPage
            maxWidth="max-w-3xl"
            breadcrumb={
                <Link href="/operation/processing" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            }
            title={t('processing.detailTitle')}
            // ★ 出口:删除这一单。转换前它画在 h1 右边的 justify-between 里 ——
            //   actions 是同一个位置,而且画在状态分支【之前】,空态吃不掉它。
            actions={<DeleteButton runId={run.id} />}
            // ★★ 详情页恒为 ok —— 这一单在不在由上面的 notFound() 回答。CONV-8 §⑤。
            state={{ kind: 'ok' }}
        >
            {/* ★ 记录抬头 —— 转换前是一块 bg-gray-50 rounded p-4 的面板(25 张里的一张)。
                单号与状态徽章转换前住在 <h1> 底下那一行 p;它们是这条记录的字段,
                所以搬进抬头,而不是留在标题里当装饰。 */}
            <RecordHeader
                fields={[
                    { label: t('processing.colCode'), value: run.code, mono: true },
                    {
                        label: t('processing.colStatus'),
                        value: (
                            <span className="px-2 py-1 rounded text-xs bg-gray-200">
                                {statusLabel(run.status)}
                            </span>
                        ),
                    },
                    { label: t('processing.detail.processDate'), value: run.process_date ?? '—' },
                    { label: t('processing.detail.totalInput'), value: run.total_input ?? '—' },
                    { label: t('processing.detail.totalOutput'), value: run.total_output ?? '—' },
                    {
                        label: t('processing.detail.loss'),
                        value: (run.loss_qty ?? '—') + (run.loss_qty != null && run.total_input
                            ? ` (${((run.loss_qty / run.total_input) * 100).toFixed(1)}%)` : ''),
                    },
                    {
                        // WO-1c:【没有就说「无计划」,不留空】—— 空白读起来像数据缺了,
                        // 而「临时起意的加工」是一个正当的类别。
                        label: t('processing.detail.workOrder'),
                        value: wo
                            ? <Link href={`/operation/orders/${wo.id}`}
                                    className="text-blue-600 hover:underline font-mono">{wo.code}</Link>
                            : <span className="text-gray-500 italic">{t('processing.noWorkOrder')}</span>,
                    },
                    {
                        label: t('processing.detail.materialCost'),
                        value: <MaskedValue value={run.material_cost_base === null ? null : formatAmount(run.material_cost_base, baseCurrency)} canView={showPrices} fallback="—" />,
                    },
                    {
                        label: t('processing.detail.processCost'),
                        value: <MaskedValue value={run.process_cost_base === null ? null : formatAmount(run.process_cost_base, baseCurrency)} canView={showPrices} fallback="—" />,
                    },
                    {
                        label: t('processing.detail.totalCost'),
                        value: <MaskedValue value={run.total_cost_base === null ? null : formatAmount(run.total_cost_base, baseCurrency)} canView={showPrices} fallback="—" />,
                    },
                    ...(run.notes ? [{ label: t('processing.detail.notes'), value: run.notes }] : []),
                ]}
            />

            {allocatedWhen && (
                <p className="mt-3 text-xs text-gray-500">
                    {t('processing.allocation.lastRun', { when: allocatedWhen, basis: basisLabel })}
                </p>
            )}
            {skippedMetals.length > 0 && (
                <p className="mt-1 text-xs text-amber-600">
                    {t('processing.allocation.skippedMetals', {
                        metals: skippedMetals.map((m) => metalLabel(m)).join(locale === 'zh' ? '、' : ', '),
                    })}
                </p>
            )}

            <div className="space-y-6 mt-6">
                {/* 【差异读的是视图,不是这里算的】而且它是【整张工单】的差异,不是这一次
                    加工的 —— 一张工单可以有几次加工,差异只在工单这一层才有意义。
                    ☞ 守卫的是 wo 存不存在(记录的属性),画的是数据不是出口 —— §⑬-0c。 */}
                {wo && varianceRows.length > 0 && (
                    <section>
                        <h2 className="text-lg font-semibold mb-2">
                            {t('processing.detail.varianceTitle', { code: wo.code })}
                        </h2>
                        <WoVarianceTable rows={varianceRows} />
                    </section>
                )}

                {/* 成本条目(仅已提交单) */}
                {isCommitted && <CostPanel runId={run.id} entries={costRows} canViewPrices={showPrices} />}

                {/* PROC-BUILD-1:损耗分类 —— 就记在损耗被记下来的这一页。
                    只在【已提交】单上;reversed 单是历史,不可改(与 CostPanel 同一条)。 */}
                {isCommitted && (
                    <LossPanel runId={run.id} categories={lossCategories} rows={lossRows}
                               lossQty={run.loss_qty ?? null} canEdit={canEditRun} locale={locale} />
                )}

                {/* FIN-25:血缘 —— 深度 >1 才值得占版面(一段加工的直接投入上面已经列了)。
                    ☞ 这一条守卫【不是】空集守卫:depth>1 说的是「有没有多层」,
                       而单层血缘就是上面那张投入表,画出来是重复不是补充。 */}
                {lineage.some((l) => l.depth > 1) && (
                    <section>
                        <h2 className="text-lg font-semibold mb-2">{t('processing.lineage.title')}</h2>
                        <LineageTable rows={lineageTableRows} />
                    </section>
                )}

                {/* 成本分摊(仅已提交单) */}
                {isCommitted && (
                    <div className="mt-8 pt-8 border-t">
                        <h2 className="text-xl font-bold mb-4">{t('processing.allocation.title')}</h2>
                        {/* 过期标记(FIN-24 起差额法):重跑把差额按处置拆 —— 在库→1220、
                            已售→5000 补 COGS、注销→5200,全记当期。已过账 COGS 不再是
                            不能重跑的理由;唯一的红 = 资本化分录被人工冲销(基线分道)。 */}
                        {(allocStatus?.is_stale
                          || (allocStatus && !allocStatus.allocated_at && allocStatus.last_cost_change)) && (
                            <div className={'mb-4 rounded border px-3 py-2 text-sm '
                                + (allocStatus.safe_to_reallocate
                                    ? 'border-amber-300 bg-amber-50 text-amber-900'
                                    : 'border-red-300 bg-red-50 text-red-900')}>
                                <p className="font-medium">
                                    {allocStatus.is_stale
                                        ? t('processing.allocation.stale')
                                        : t('processing.allocation.neverAllocated')}
                                </p>
                                <p className="mt-1 text-xs">
                                    {allocStatus.safe_to_reallocate
                                        ? t('processing.allocation.staleSafe')
                                        : t('processing.allocation.staleUnsafe')}
                                </p>
                            </div>
                        )}
                        {/* ★ 出口:重跑分摊。住 children,靠 state 恒为 'ok' 撑着;
                            它的守卫是 isCommitted —— 记录的状态,不是一个集合空不空。 */}
                        <AllocateButton runId={run.id} />
                    </div>
                )}

                {/* 投入 —— 空态由表自己说(CONV-8 §⑤ 的推论),不再自己画一行 colSpan */}
                <section>
                    <h2 className="text-lg font-semibold mb-2">{t('processing.detail.inputsSectionHeader')}</h2>
                    <InputsTable rows={inputRows} />
                </section>

                {/* 产出 */}
                <section>
                    <h2 className="text-lg font-semibold mb-2">{t('processing.detail.outputsSectionHeader')}</h2>
                    <OutputsTable rows={outputRows} canViewPrices={showPrices} />
                </section>

                {/* 金属回收率(仅已提交单) */}
                {isCommitted && (
                    <section>
                        <h2 className="text-lg font-semibold mb-2">{t('processing.recovery.title')}</h2>
                        {!recoveryComputable && (
                            <p className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-3 text-sm">
                                {t('processing.recovery.runNotComputable')}
                            </p>
                        )}
                        {conservationRows.map((r) => (
                            <p key={'warn-' + r.metal}
                               className="bg-red-50 border border-red-300 text-red-800 px-4 py-3 rounded mb-3 text-sm">
                                <span className="font-medium">{t('processing.recovery.anomalyTitle')}</span>{' — '}
                                {Number(r.input_metal_kg) === 0
                                    ? t('processing.recovery.anomalyFromZero', {
                                          metal: metalLabel(r.metal), output: String(r.output_metal_kg),
                                      })
                                    : t('processing.recovery.anomaly', {
                                          metal: metalLabel(r.metal),
                                          input: String(r.input_metal_kg),
                                          output: String(r.output_metal_kg),
                                          pct: String(r.recovery_pct ?? '—'),
                                      })}
                                {' — '}
                                {t(anomalyCauseKey(r))}
                            </p>
                        ))}
                        {/* 空态由表自己说 —— 转换前这里是一句表外的 <p>,
                            于是「这一单没有可算的金属」和「表画不出来」长得一样。 */}
                        <RecoveryTable rows={recoveryTableRows} />
                    </section>
                )}
            </div>
        </ListPage>
    )
}
