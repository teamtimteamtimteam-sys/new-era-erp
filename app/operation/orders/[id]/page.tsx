// app/operation/orders/[id]/page.tsx
// WO-1c:工单详情 —— 计划、实绩、以及两者之间的差。
//
// 【三个状态在这一页上必须【长得不一样】,而这是整页的要点】
//   ① 有计划、有实绩 → 差异是一个数(可正可负);
//   ② 有计划、没实绩 → 差异 = −计划(还没开始做,不是"没有差异");
//   ③ 【没有计划】或【没有预期】→ 差异是【空】,并且屏幕上说出来是哪一种 ——
//      「未记录预期」「计划外」。绝不画成 0:一个 0 会让"没估过"读成"估了零",
//      于是任何产出都是超额完成(这正是 work_order_fulfilment 用 NULL 而不是
//      COALESCE 的理由,页面必须把那个 NULL 一路带到眼前)。
//
// 【差异不在这里算】两侧的数全部取自 work_order_fulfilment。页面自己减一遍,
// 就是给同一个规则留下第二处实现(AGENTS.md:一处推导,N 个消费者)。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { formatTimestamp } from '@/lib/format'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { workOrderStatusKey } from '../woTypes'
import WorkOrderActions from './WorkOrderActions'
import AmendLinesControl, { type AmendRow } from './AmendLinesControl'

type FulfilRow = {
    side: string; material_id: string
    material_code: string | null; material_name: string | null
    planned_or_expected_qty: number | null; actual_qty: number
    variance_qty: number | null; has_plan: boolean
}

export default async function WorkOrderPage({ params }: { params: Promise<{ id: string }> }) {
    const denied = await requireModule(MOD.processing)
    if (denied) return denied

    const { id } = await params
    const t = await getTranslations()
    const locale = await getLocale()
    const dl = locale === 'zh' ? 'zh-CN' : 'en-US'
    const supabase = await createClient()

    const wo = mustOne(
        await supabase.from('work_orders')
            .select('id, code, status, scheduled_date, notes, created_at, closed_at, close_reason, cancelled_at, cancel_reason')
            .eq('id', id).maybeSingle(),
        'work_orders') as {
            id: string; code: string; status: string; scheduled_date: string | null
            notes: string | null; created_at: string
            closed_at: string | null; close_reason: string | null
            cancelled_at: string | null; cancel_reason: string | null } | null
    if (!wo) notFound()

    const fulfil = mustRows(
        await supabase.from('work_order_fulfilment')
            .select('side, material_id, material_code, material_name, planned_or_expected_qty, actual_qty, variance_qty, has_plan')
            .eq('work_order_id', id),
        'work_order_fulfilment') as FulfilRow[]

    // 【被冲销的加工也列出来,而且标出来】它确实是照这张工单做的(链接是历史),
    // 只是它断言过的消耗不再算数 —— 把它藏起来,人会问"那次加工去哪了"。
    const runs = mustRows(
        await supabase.from('processing_runs')
            .select('id, code, process_date, status, total_input, total_output')
            .eq('work_order_id', id).order('process_date', { ascending: false }),
        'processing_runs') as {
            id: string; code: string; process_date: string | null
            status: string; total_input: number | null; total_output: number | null }[]

    const history = mustRows(
        await supabase.from('work_order_history')
            .select('change_type, detail, amend_reason, old_qty, new_qty, changed_at')
            .eq('work_order_id', id).order('changed_at', { ascending: false }),
        'work_order_history') as {
            change_type: string; detail: string | null; amend_reason: string | null
            old_qty: number | null; new_qty: number | null; changed_at: string }[]

    // ── PROC-SUPPORT-1(R3):每一行预期产出的【出处】────────────────────────
    // 【为什么单独读一次,而不是往 work_order_fulfilment 里加一列】那张视图回答的是
    // "计划与实绩差了多少",而出处回答的是"那个计划数可不可信" —— 两个问题。
    // 把它塞进差异视图,下一个改差异口径的人会连着出处一起改。
    const expectedBasis = mustRows(
        await supabase.from('work_order_expected_outputs')
            .select('material_id, basis, basis_reference')
            .eq('work_order_id', id),
        'work_order_expected_outputs') as {
            material_id: string; basis: string | null; basis_reference: string | null }[]
    const basisOf = new Map(expectedBasis.map((r) => [r.material_id, r]))

    const canEdit = await can('module.processing.edit')
    const inputRows = fulfil.filter((r) => r.side === 'input')
    const outputRows = fulfil.filter((r) => r.side === 'output')
    const liveRuns = runs.filter((r) => r.status === 'committed')
    const editable = canEdit && ['draft', 'released'].includes(wo.status)

    const label = (r: FulfilRow) =>
        r.material_code ? `${r.material_code} — ${r.material_name ?? ''}` : '—'

    const amendRows: AmendRow[] = inputRows.map((r) => ({
        material_id: r.material_id, material_label: label(r),
        planned_qty: r.planned_or_expected_qty, consumed_qty: Number(r.actual_qty ?? 0),
    }))

    return (
        <>
            <div className="p-8 max-w-5xl">
                <div className="mb-6">
                    <Link href="/operation/orders" className="text-blue-600 hover:underline text-sm">
                        {t('common.back')}
                    </Link>
                </div>

                <div className="flex items-start justify-between mb-4">
                    <h1 className="text-2xl font-bold font-mono">{wo.code}</h1>
                    <span className="px-3 py-1 rounded bg-gray-200 text-sm">
                        {t(workOrderStatusKey(wo.status))}
                    </span>
                </div>

                {/* 【收工 / 取消的理由摆在最上面】—— 一张终态的单据,人第一个问题是
                    "为什么结束了",答案不该藏在历史列表的最下面。 */}
                {wo.closed_at && (
                    <div className="bg-gray-50 border border-gray-300 text-gray-800 px-4 py-3 rounded mb-4">
                        {t('processing.wo.closedBanner', {
                            at: formatTimestamp(wo.closed_at, dl),
                            reason: wo.close_reason ?? '—',
                        })}
                    </div>
                )}
                {wo.cancelled_at && (
                    <div className="bg-gray-50 border border-gray-300 text-gray-800 px-4 py-3 rounded mb-4">
                        {t('processing.wo.cancelledBanner', {
                            at: formatTimestamp(wo.cancelled_at, dl),
                            reason: wo.cancel_reason ?? '—',
                        })}
                    </div>
                )}

                <dl className="grid grid-cols-2 gap-x-8 gap-y-1 text-sm mb-6">
                    <div>
                        <dt className="inline text-gray-500">{t('processing.wo.colScheduled')}: </dt>
                        <dd className="inline">
                            {wo.scheduled_date
                                ? new Date(wo.scheduled_date).toLocaleDateString(dl)
                                : <span className="text-gray-500 italic">{t('processing.wo.noSchedule')}</span>}
                        </dd>
                    </div>
                    <div>
                        <dt className="inline text-gray-500">{t('processing.wo.colNotes')}: </dt>
                        <dd className="inline">{wo.notes ?? '—'}</dd>
                    </div>
                </dl>

                {/* ── 投入侧 ──────────────────────────────────────────────── */}
                <h2 className="text-lg font-semibold mb-1">{t('processing.wo.inputSide')}</h2>
                <p className="text-xs text-gray-500 mb-2">{t('processing.wo.inputSideNote')}</p>
                <table className="w-full border-collapse border border-gray-300 text-sm mb-2">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('processing.wo.colMaterial')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('processing.wo.colPlanned')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('processing.wo.colConsumed')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('processing.wo.colVariance')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {inputRows.map((r) => (
                            <tr key={r.material_id} className={r.has_plan ? '' : 'bg-amber-50'}>
                                <td className="border border-gray-300 px-3 py-2">
                                    {label(r)}
                                    {/* 【吃了没人计划过的料】自己一行,并说出它是什么 */}
                                    {!r.has_plan && (
                                        <span className="ml-2 text-xs text-amber-700">
                                            {t('processing.wo.unplannedMaterial')}
                                        </span>
                                    )}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                    {r.planned_or_expected_qty ?? <span className="text-gray-400">—</span>}
                                </td>
                                {/* ★【出处必须在屏幕上分得开,不只是在数据里分得开】★
                                    播种的猜测标成琥珀色并带一个"低置信"的字样,校准过的标成绿色;
                                    **没人说过的那一格写着"还没有人说过",不是一个空白格** ——
                                    空白格读起来像"这一栏不重要",而这一栏正是六个月后
                                    唯一能回答"这个数可不可信"的东西。 */}
                                <td className="border border-gray-300 px-3 py-2 text-xs">
                                    {(() => {
                                        const b = basisOf.get(r.material_id)
                                        if (!r.has_plan) return <span className="text-gray-400">—</span>
                                        if (!b?.basis) return (
                                            <span className="text-gray-500 italic">
                                                {t('processing.wo.basis.unstated')}
                                            </span>)
                                        const tone = b.basis === 'calibrated' ? 'bg-green-100 text-green-800'
                                            : b.basis === 'seeded_industry' ? 'bg-amber-100 text-amber-800'
                                            : 'bg-gray-100 text-gray-700'
                                        return (
                                            <>
                                                <span className={`inline-block px-2 py-0.5 rounded ${tone}`}>
                                                    {t('processing.wo.basis.' + b.basis)}
                                                </span>
                                                {b.basis_reference && (
                                                    <span className="block text-gray-500 mt-1">{b.basis_reference}</span>
                                                )}
                                            </>)
                                    })()}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">{r.actual_qty}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                    {/* 【差异为空就留空 —— 绝不写 0】没有被减数,差就说不出来 */}
                                    {r.variance_qty == null
                                        ? <span className="text-gray-400">—</span>
                                        : <span className={Number(r.variance_qty) < 0 ? 'text-amber-700' : ''}>
                                              {Number(r.variance_qty) > 0 ? '+' : ''}{r.variance_qty}
                                          </span>}
                                </td>
                            </tr>
                        ))}
                        {inputRows.length === 0 && (
                            <tr><td colSpan={4} className="border border-gray-300 px-3 py-4 text-center text-gray-500">
                                {t('processing.wo.noLines')}
                            </td></tr>
                        )}
                    </tbody>
                </table>
                <AmendLinesControl
                    id={wo.id} rows={amendRows} editable={editable}
                    blockedReason={!canEdit
                        ? `${t('common.restricted')} — ${t('processing.wo.needsEdit')}`
                        : t('processing.wo.blocked.amendTerminal', { status: t(workOrderStatusKey(wo.status)) })}
                />

                {/* ── 产出侧 ──────────────────────────────────────────────── */}
                <h2 className="text-lg font-semibold mt-8 mb-1">{t('processing.wo.outputSide')}</h2>
                <p className="text-xs text-gray-500 mb-2">{t('processing.wo.outputSideNote')}</p>
                <table className="w-full border-collapse border border-gray-300 text-sm">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('processing.wo.colMaterial')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('processing.wo.colExpected')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('processing.wo.colBasis')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('processing.wo.colProduced')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('processing.wo.colVariance')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {outputRows.map((r) => (
                            <tr key={r.material_id}>
                                <td className="border border-gray-300 px-3 py-2">{label(r)}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                    {/* 【没估过 ≠ 估了零 —— 屏幕上把它说出来】 */}
                                    {r.has_plan
                                        ? r.planned_or_expected_qty
                                        : <span className="text-gray-500 italic text-xs">
                                              {t('processing.wo.noExpectation')}
                                          </span>}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">{r.actual_qty}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                    {r.variance_qty == null
                                        ? <span className="text-gray-400">—</span>
                                        : <span className={Number(r.variance_qty) < 0 ? 'text-amber-700' : ''}>
                                              {Number(r.variance_qty) > 0 ? '+' : ''}{r.variance_qty}
                                          </span>}
                                </td>
                            </tr>
                        ))}
                        {outputRows.length === 0 && (
                            <tr><td colSpan={5} className="border border-gray-300 px-3 py-4 text-center text-gray-500">
                                {t('processing.wo.noOutputsYet')}
                            </td></tr>
                        )}
                    </tbody>
                </table>

                {/* ── 挂上来的加工单 ──────────────────────────────────────── */}
                <h2 className="text-lg font-semibold mt-8 mb-2">{t('processing.wo.linkedRuns')}</h2>
                {runs.length === 0 ? (
                    <p className="text-sm text-gray-500">{t('processing.wo.noRuns')}</p>
                ) : (
                    <table className="w-full border-collapse border border-gray-300 text-sm">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('processing.colCode')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('processing.colProcessDate')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-right">{t('processing.colTotalInput')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-right">{t('processing.colTotalOutput')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('processing.colStatus')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {runs.map((r) => (
                                <tr key={r.id} className={r.status === 'reversed' ? 'text-gray-400' : ''}>
                                    <td className="border border-gray-300 px-3 py-2 font-mono">
                                        <Link href={`/operation/processing/${r.id}`} className="text-blue-600 hover:underline">
                                            {r.code}
                                        </Link>
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">{r.process_date ?? '—'}</td>
                                    <td className="border border-gray-300 px-3 py-2 text-right font-mono">{r.total_input ?? '—'}</td>
                                    <td className="border border-gray-300 px-3 py-2 text-right font-mono">{r.total_output ?? '—'}</td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        {r.status === 'reversed'
                                            ? <span className="text-xs px-2 py-1 bg-gray-200 rounded">
                                                  {t('processing.wo.runReversed')}
                                              </span>
                                            : <span className="text-xs px-2 py-1 bg-gray-200 rounded">
                                                  {t('processing.status.committed')}
                                              </span>}
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                )}
                {runs.some((r) => r.status === 'reversed') && (
                    <p className="text-xs text-gray-500 mt-2">{t('processing.wo.reversedNote')}</p>
                )}

                {/* ── 动作 ────────────────────────────────────────────────── */}
                <h2 className="text-lg font-semibold mt-8 mb-2">{t('processing.wo.actionsTitle')}</h2>
                <WorkOrderActions
                    id={wo.id} status={wo.status} canEdit={canEdit}
                    hasRuns={liveRuns.length > 0}
                />

                {/* ── 历史 ────────────────────────────────────────────────── */}
                <h2 className="text-lg font-semibold mt-8 mb-2">{t('processing.wo.history')}</h2>
                <ul className="text-sm space-y-1">
                    {history.map((h, i) => (
                        <li key={i} className="text-gray-600">
                            {formatTimestamp(h.changed_at, dl)}
                            {/* 动态前缀,后缀集合接 work_order_history 的 CHECK(check-i18n 的清单) */}
                            {' · '}{t('processing.wo.changeType.' + h.change_type)}
                            {h.old_qty != null || h.new_qty != null
                                ? ` · ${h.old_qty ?? '—'} → ${h.new_qty ?? '—'}`
                                : ''}
                            {h.amend_reason ? ` · ${h.amend_reason}` : ''}
                            {h.detail ? ` · ${h.detail}` : ''}
                        </li>
                    ))}
                </ul>
            </div>
        </>
    )
}
