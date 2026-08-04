import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import DeleteButton from './DeleteButton'
import CostPanel from './CostPanel'
import AllocateButton from './AllocateButton'
import { type CostEntryRow } from './costTypes'
import { processingStatusLabelKey } from '../status'
import { metalLabelKey } from '@/app/metal-prices/options'
import { formatMoney, formatUnitCost } from '@/lib/format'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { maskedRows, maskedExcept } from '@/lib/maskedRows'
import type { Tables } from '@/lib/database.types'
import { canViewPrices } from '@/lib/permissions'
import { MaskedValue } from '@/app/components/MaskedValue'

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
}

type ProcessingOutputRow = {
    id: string
    quantity_produced: number
    allocated_cost_base: number | null
    unit_cost_base: number | null
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
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
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
            .select('id, quantity_consumed, inbound_batches ( id, code, unit, deleted_at, materials ( name ) )')
            .eq('run_id', id)
            .order('created_at'),
        supabase
            .from('processing_outputs_masked')
            .select('id, quantity_produced, allocated_cost_base, unit_cost_base, output_batches ( id, code, unit, purity, deleted_at, materials ( name ) )')
            .eq('run_id', id)
            .order('created_at'),
        supabase
            .from('processing_cost_entries_masked')
            .select('id, cost_type, amount_base, is_estimate, notes, created_at')
            .eq('run_id', id)
            .is('deleted_at', null)
            .order('created_at'),
        supabase
            .from('processing_metal_recovery')
            .select('metal, input_metal_kg, output_metal_kg, recovery_pct')
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
    const outputs = outputsRes.data as unknown as ProcessingOutputRow[] | null

    const isCommitted = run.status === 'committed'

    // 状态标签(未知值回退原样)
    const statusLabel = (v: string | null) => {
        const k = processingStatusLabelKey(v)
        return k ? t(k) : v ?? '—'
    }

    // 成本条目行:服务端预格式化 created_at
    const showPrices = await canViewPrices()

    const costRows: CostEntryRow[] = maskedRows<Tables<'processing_cost_entries'>, 'amount_base'>(costsRes.data).map((c) => ({
        id: c.id,
        cost_type: c.cost_type,
        amount_base: c.amount_base,
        is_estimate: c.is_estimate,
        notes: c.notes,
        created_at_display: new Date(c.created_at).toLocaleString(dateLocale),
    }))

    // 回收率行(视图已按 committed + 未软删过滤)
    const recoveryRows = recoveryRes.data ?? []
    const metalLabel = (v: string | null) => {
        const k = metalLabelKey(v)
        return k ? t(k) : v ?? '—'
    }

    // 分摊信息:上次分摊时间 + 基准标签
    const allocatedWhen = run.allocated_at
        ? new Date(run.allocated_at).toLocaleString(dateLocale)
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

                    {/* 成本(金额,USD) */}
                    <div className="mt-3 pt-3 border-t border-gray-200 grid grid-cols-2 gap-x-6 gap-y-2 text-sm">
                        <div>
                            <span className="text-gray-600">{t('processing.detail.materialCost')}</span>{' '}
                            <MaskedValue value={run.material_cost_base} canView={showPrices} format={formatMoney} fallback="—" />
                        </div>
                        <div>
                            <span className="text-gray-600">{t('processing.detail.processCost')}</span>{' '}
                            <MaskedValue value={run.process_cost_base} canView={showPrices} format={formatMoney} fallback="—" />
                        </div>
                        <div>
                            <span className="text-gray-600">{t('processing.detail.totalCost')}</span>{' '}
                            <MaskedValue value={run.total_cost_base} canView={showPrices} format={formatMoney} fallback="—" />
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

                {/* 成本分摊(仅已提交单) */}
                {isCommitted && (
                    <div className="mt-8 pt-8 border-t">
                        <h2 className="text-xl font-bold mb-4">{t('processing.allocation.title')}</h2>
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
                            {inputs?.map((leg) => (
                                <tr key={leg.id}>
                                    <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                        {!leg.inbound_batches ? (
                                            '—'
                                        ) : leg.inbound_batches.deleted_at ? (
                                            <span className="text-gray-500">
                                                {leg.inbound_batches.code}{t('processing.detail.deletedMarker')}
                                            </span>
                                        ) : (
                                            <Link
                                                href={`/inbound/${leg.inbound_batches.id}/edit`}
                                                className="text-blue-600 hover:underline"
                                            >
                                                {leg.inbound_batches.code}
                                            </Link>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        {leg.inbound_batches?.materials?.name ?? '—'}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        {leg.quantity_consumed} {leg.inbound_batches?.unit ?? ''}
                                    </td>
                                </tr>
                            ))}
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
                                            value={leg.allocated_cost_base}
                                            canView={showPrices}
                                            format={formatMoney}
                                            fallback="—"
                                        />
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        <MaskedValue
                                            value={leg.unit_cost_base}
                                            canView={showPrices}
                                            format={(v) => formatUnitCost(v) + ' /kg'}
                                            fallback="—"
                                        />
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
                                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                                {r.input_metal_kg ?? '—'}
                                            </td>
                                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                                {r.output_metal_kg ?? '—'}
                                            </td>
                                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                                {r.recovery_pct != null ? r.recovery_pct.toFixed(2) + '%' : '—'}
                                            </td>
                                        </tr>
                                    ))}
                                </tbody>
                            </table>
                            </div>
                        ) : (
                            <p className="text-sm text-gray-500">{t('processing.recovery.empty')}</p>
                        )}
                    </section>
                )}
            </div>
        </div>
    )
}
