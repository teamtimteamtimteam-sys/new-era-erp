import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import DeleteButton from './DeleteButton'
import CostPanel from './CostPanel'
import AllocateButton from './AllocateButton'
import { type CostEntryRow } from './costTypes'
import { processingStatusLabelKey } from '../status'
import { metalLabelKey } from '@/app/metal-prices/options'
import { formatAmount, formatMoneyBare, formatUnitCost, formatTimestamp } from '@/lib/format'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { maskedRows, maskedExcept } from '@/lib/maskedRows'
import type { Tables } from '@/lib/database.types'
import { canViewPrices } from '@/lib/permissions'
import { MaskedValue } from '@/app/components/MaskedValue'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { getBaseCurrency } from '@/lib/currency'

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

    const rawCosts = maskedRows<Tables<'processing_cost_entries'>, 'amount_base'>(mustRows(costsRes))
    // 改过条目的操作人姓名(一次取回,不逐行查)
    const editorIds = [...new Set(rawCosts
        .filter((c) => c.updated_at !== c.created_at && c.updated_by)
        .map((c) => c.updated_by as string))]
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
        edited_by_name: c.updated_by ? editorName.get(c.updated_by) ?? null : null,
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

    return (
        <div className="p-8 max-w-3xl">
            <div className="mb-6">
                <Link
                    href="/processing"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <div className="flex items-start justify-between mb-6">
                <div>
                    <h1 className="text-2xl font-bold mb-2">{t('processing.detailTitle')}</h1>
                    <p className="text-sm text-gray-600">
                        <span className="font-mono">{run.code}</span>
                        <span className="mx-2">·</span>
                        <span className="px-2 py-0.5 bg-gray-200 rounded text-xs">
                            {statusLabel(run.status)}
                        </span>
                    </p>
                </div>
                <DeleteButton runId={run.id} />
            </div>

            <div className="space-y-6">
                {/* 概况 */}
                <div className="bg-gray-50 rounded p-4">
                    <div className="grid grid-cols-2 gap-x-6 gap-y-2 text-sm">
                        <div>
                            <span className="text-gray-600">{t('processing.detail.processDate')}</span>{' '}
                            {run.process_date ?? '—'}
                        </div>
                        <div>
                            <span className="text-gray-600">{t('processing.detail.totalInput')}</span>{' '}
                            {run.total_input ?? '—'}
                        </div>
                        <div>
                            <span className="text-gray-600">{t('processing.detail.totalOutput')}</span>{' '}
                            {run.total_output ?? '—'}
                        </div>
                        <div>
                            <span className="text-gray-600">{t('processing.detail.loss')}</span>{' '}
                            {run.loss_qty ?? '—'}
                            {run.loss_qty != null && run.total_input
                                ? ` (${((run.loss_qty / run.total_input) * 100).toFixed(1)}%)`
                                : ''}
                        </div>
                    </div>

                    {/* 成本(本位币金额;币种随数写出,见文件顶部 baseCurrency)*/}
                    <div className="mt-3 pt-3 border-t border-gray-200 grid grid-cols-2 gap-x-6 gap-y-2 text-sm">
                        <div>
                            <span className="text-gray-600">{t('processing.detail.materialCost')}</span>{' '}
                            <MaskedValue value={run.material_cost_base === null ? null : formatAmount(run.material_cost_base, baseCurrency)} canView={showPrices} fallback="—" />
                        </div>
                        <div>
                            <span className="text-gray-600">{t('processing.detail.processCost')}</span>{' '}
                            <MaskedValue value={run.process_cost_base === null ? null : formatAmount(run.process_cost_base, baseCurrency)} canView={showPrices} fallback="—" />
                        </div>
                        <div>
                            <span className="text-gray-600">{t('processing.detail.totalCost')}</span>{' '}
                            <MaskedValue value={run.total_cost_base === null ? null : formatAmount(run.total_cost_base, baseCurrency)} canView={showPrices} fallback="—" />
                        </div>
                    </div>

                    {allocatedWhen && (
                        <p className="mt-3 text-xs text-gray-500">
                            {t('processing.allocation.lastRun', {
                                when: allocatedWhen,
                                basis: basisLabel,
                            })}
                        </p>
                    )}

                    {skippedMetals.length > 0 && (
                        <p className="mt-1 text-xs text-amber-600">
                            {t('processing.allocation.skippedMetals', {
                                metals: skippedMetals
                                    .map((m) => metalLabel(m))
                                    .join(locale === 'zh' ? '、' : ', '),
                            })}
                        </p>
                    )}

                    {run.notes && (
                        <div className="mt-3 pt-3 border-t border-gray-200 text-sm">
                            <span className="text-gray-600">{t('processing.detail.notes')}</span> {run.notes}
                        </div>
                    )}
                </div>

                {/* 成本条目(仅已提交单) */}
                {isCommitted && <CostPanel runId={run.id} entries={costRows} canViewPrices={showPrices} />}

                {/* FIN-25:血缘 —— 深度 >1 才值得占版面(一段加工的直接投入上面已经列了)*/}
                {lineage.some((l) => l.depth > 1) && (
                    <section>
                        <h2 className="text-lg font-semibold mb-2">{t('processing.lineage.title')}</h2>
                        <table className="w-auto min-w-[36rem] border-collapse border border-gray-300">
                            <thead className="bg-gray-100">
                                <tr>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('processing.lineage.colDepth')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('processing.lineage.colViaRun')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('processing.lineage.colParent')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-right">{t('processing.lineage.colQty')}</th>
                                </tr>
                            </thead>
                            <tbody>
                                {lineage.map((l, i) => (
                                    <tr key={i}>
                                        <td className="border border-gray-300 px-3 py-2 font-mono text-sm">{l.depth}</td>
                                        <td className="border border-gray-300 px-3 py-2 font-mono text-sm">{l.via_run_code}</td>
                                        <td className="border border-gray-300 px-3 py-2 font-mono text-sm">
                                            <Link href={l.parent_kind === 'inbound'
                                                    ? `/inbound/${l.parent_batch_id}/edit`
                                                    : `/output/${l.parent_batch_id}/edit`}
                                                  className="text-blue-600 hover:underline">
                                                {l.parent_code ?? '—'}
                                            </Link>
                                            <span className="ml-2 text-xs text-gray-500 font-sans">
                                                {t('processing.lineage.kind_' + l.parent_kind)}
                                            </span>
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">{l.quantity_consumed}</td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
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
                        <AllocateButton runId={run.id} />
                    </div>
                )}

                {/* 投入 */}
                <section>
                    <h2 className="text-lg font-semibold mb-2">{t('processing.detail.inputsSectionHeader')}</h2>
                    <div className="overflow-x-auto">
                    <table className="w-full border-collapse border border-gray-300">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.detail.colInboundBatch')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.detail.colMaterial')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.detail.colConsumedQty')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {inputs?.map((leg) => {
                                {/* FIN-25:双亲投料 —— 进料批或(再加工)产出批 */}
                                const parent = leg.inbound_batches ?? leg.output_batches
                                const href = leg.inbound_batches
                                    ? `/inbound/${leg.inbound_batches.id}/edit`
                                    : leg.output_batches ? `/output/${leg.output_batches.id}/edit` : null
                                return (
                                <tr key={leg.id}>
                                    <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                        {!parent ? (
                                            '—'
                                        ) : parent.deleted_at ? (
                                            <span className="text-gray-500">
                                                {parent.code}{t('processing.detail.deletedMarker')}
                                            </span>
                                        ) : (
                                            <Link href={href!} className="text-blue-600 hover:underline">
                                                {parent.code}
                                            </Link>
                                        )}
                                        {leg.output_batches && (
                                            <span className="ml-2 px-1.5 py-0.5 rounded text-xs bg-blue-50 text-blue-700 font-sans">
                                                {t('processing.detail.reprocessedTag')}
                                            </span>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        {parent?.materials?.name ?? '—'}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        {leg.quantity_consumed} {parent?.unit ?? ''}
                                    </td>
                                </tr>
                                )
                            })}
                            {(!inputs || inputs.length === 0) && (
                                <tr>
                                    <td
                                        colSpan={3}
                                        className="border border-gray-300 px-4 py-8 text-center text-gray-500"
                                    >
                                        {t('processing.detail.noInputRecords')}
                                    </td>
                                </tr>
                            )}
                        </tbody>
                    </table>
                    </div>
                </section>

                {/* 产出 */}
                <section>
                    <h2 className="text-lg font-semibold mb-2">{t('processing.detail.outputsSectionHeader')}</h2>
                    <div className="overflow-x-auto">
                    <table className="w-full border-collapse border border-gray-300">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.detail.colOutputBatch')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.detail.colMaterial')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.detail.colProducedQty')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.detail.colPurity')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.detail.colAllocatedCost')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.detail.colUnitCost')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {outputs?.map((leg) => (
                                <tr key={leg.id}>
                                    <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                        {!leg.output_batches ? (
                                            '—'
                                        ) : leg.output_batches.deleted_at ? (
                                            <span className="text-gray-500">
                                                {leg.output_batches.code}{t('processing.detail.deletedMarker')}
                                            </span>
                                        ) : (
                                            <Link
                                                href={`/output/${leg.output_batches.id}/edit`}
                                                className="text-blue-600 hover:underline"
                                            >
                                                {leg.output_batches.code}
                                            </Link>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        {leg.output_batches?.materials?.name ?? '—'}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        {leg.quantity_produced} {leg.output_batches?.unit ?? ''}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        {leg.output_batches?.purity ?? '—'}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {/* 遮蔽后是 null,和"尚未分摊"是两回事 —— 前者显示「受限」,
                                            后者才是「—」。都画成 — 会让运营以为成本没算。 */}
                                        <MaskedValue
                                            value={leg.allocated_cost_base === null ? null : formatMoneyBare(leg.allocated_cost_base, '列头「分摊成本 (SGD)」')}
                                            canView={showPrices}
                                            fallback="—"
                                        />
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        <MaskedValue
                                            value={leg.unit_cost_base === null ? null : formatUnitCost(leg.unit_cost_base) + ' /kg'}
                                            canView={showPrices}
                                            fallback="—"
                                        />
                                        {/* FIN-25:含计 0 的无价投料(或上游带标)—— 零不静默,
                                            上游补分摊后本单过期,重跑即清 */}
                                        {leg.cost_incomplete && (
                                            <span className="ml-1 px-1.5 py-0.5 rounded text-xs bg-amber-100 text-amber-800 font-sans">
                                                {t('processing.detail.costIncomplete')}
                                            </span>
                                        )}
                                    </td>
                                </tr>
                            ))}
                            {(!outputs || outputs.length === 0) && (
                                <tr>
                                    <td
                                        colSpan={6}
                                        className="border border-gray-300 px-4 py-8 text-center text-gray-500"
                                    >
                                        {t('processing.detail.noOutputRecords')}
                                    </td>
                                </tr>
                            )}
                        </tbody>
                    </table>
                    </div>
                </section>

                {/* 金属回收率(仅已提交单) */}
                {isCommitted && (
                    <section>
                        <h2 className="text-lg font-semibold mb-2">{t('processing.recovery.title')}</h2>
                        {recoveryRows.length > 0 ? (
                            <>
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
                                          })}
                                    {/* PROC-1c:这条警告比的是哪两种数 —— 先把两侧出处照直说出来
                                        (事实),再给一句该先看哪里(判断)。事实单独成句,是因为
                                        那句判断按 mixed/unknown 必然粗糙,而粗糙的判断不该把事实
                                        一起吃掉。 */}
                                    <span className="block mt-2 pt-2 border-t border-red-200">
                                        <span className="font-medium">
                                            {t('processing.recovery.sourcePair', {
                                                input: sourceLabel(r.input_source),
                                                output: sourceLabel(r.output_source),
                                            })}
                                        </span>
                                        {' — '}
                                        {t(anomalyCauseKey(r))}
                                    </span>
                                </p>
                            ))}
                            <div className="overflow-x-auto">
                            <table className="w-full border-collapse border border-gray-300">
                                <thead className="bg-gray-100">
                                    <tr>
                                        <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.recovery.colMetal')}</th>
                                        <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.recovery.colInput')}</th>
                                        <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.recovery.colOutput')}</th>
                                        <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.recovery.colRecovery')}</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    {recoveryRows.map((r, idx) => (
                                        <tr key={r.metal ?? idx}>
                                            <td className="border border-gray-300 px-4 py-2">{metalLabel(r.metal)}</td>
                                            {/* REC-1:【未测】与【测出来是零】渲染成两样东西。此前视图把
                                                前者压成 0,于是"投入 0 / 产出 40"看着像无中生有,其实
                                                只是那个金属从没在投入侧被测过。 */}
                                            {/* PROC-1c:出处贴在它修饰的那个数下面 —— 回收率是
                                                产出÷投入,"这个百分比除的是哪一种数"是【每一侧
                                                各自】的事实,不是行级的一个标签。没测过的那一侧
                                                不画出处:没有数就没有出处,空着才是对的。 */}
                                            <td className="border border-gray-300 px-4 py-2 text-right text-sm">
                                                {r.input_measured ? (
                                                    <>
                                                        <span className="font-mono">{r.input_metal_kg}</span>
                                                        <span className="block text-xs text-gray-500">{sourceLabel(r.input_source)}</span>
                                                    </>
                                                ) : (
                                                    <span className="text-gray-400" title={t('processing.recovery.notMeasuredTitle')}>
                                                        {t('processing.recovery.notMeasured')}
                                                    </span>
                                                )}
                                            </td>
                                            <td className="border border-gray-300 px-4 py-2 text-right text-sm">
                                                {r.output_measured ? (
                                                    <>
                                                        <span className="font-mono">{r.output_metal_kg}</span>
                                                        <span className="block text-xs text-gray-500">{sourceLabel(r.output_source)}</span>
                                                    </>
                                                ) : (
                                                    <span className="text-gray-400" title={t('processing.recovery.notMeasuredTitle')}>
                                                        {t('processing.recovery.notMeasured')}
                                                    </span>
                                                )}
                                            </td>
                                            {/* 算不出的时候说【为什么】和【怎么才能算出来】,而不是一根横杠 */}
                                            <td className="border border-gray-300 px-4 py-2 text-sm">
                                                {r.recovery_pct != null ? (
                                                    <span className="font-mono">{r.recovery_pct.toFixed(2)}%</span>
                                                ) : (
                                                    <span className="text-gray-500 text-xs">
                                                        {t('processing.recovery.blocked.' + (r.recovery_blocked_by ?? 'input_not_measured'))}
                                                    </span>
                                                )}
                                            </td>
                                        </tr>
                                    ))}
                                </tbody>
                            </table>
                            </div>
                            </>
                        ) : (
                            <p className="text-sm text-gray-500">{t('processing.recovery.empty')}</p>
                        )}
                    </section>
                )}
            </div>
        </div>
    )
}
