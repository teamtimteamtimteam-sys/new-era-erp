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
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import {
    InputSideTable, OutputSideTable, LinkedRunsTable,
    type FulfilmentRow, type LinkedRunRow,
} from './WorkOrderTables' 

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

    // ── 行数据在服务端压平(CONV-1 §①:render 是函数,过不了 RSC 边界)──────
    const toFulfilment = (r: FulfilRow, withBasis: boolean): FulfilmentRow => {
        const b = withBasis ? basisOf.get(r.material_id) : null
        return {
            id: r.material_id,
            label: label(r),
            hasPlan: r.has_plan,
            plannedText: r.planned_or_expected_qty == null ? null : String(r.planned_or_expected_qty),
            actualText: String(r.actual_qty),
            varianceText: r.variance_qty == null
                ? null
                : (Number(r.variance_qty) > 0 ? '+' : '') + String(r.variance_qty),
            varianceNegative: r.variance_qty != null && Number(r.variance_qty) < 0,
            basis: b?.basis
                ? {
                    tone: b.basis === 'calibrated' ? 'bg-green-100 text-green-800'
                        : b.basis === 'seeded_industry' ? 'bg-amber-100 text-amber-800'
                        : 'bg-gray-100 text-gray-700',
                    label: t('processing.wo.basis.' + b.basis),
                    reference: b.basis_reference ?? null,
                  }
                : null,
            basisUnstated: withBasis && r.has_plan && !b?.basis,
        }
    }
    const inputTableRows = inputRows.map((r) => toFulfilment(r, true))
    const outputTableRows = outputRows.map((r) => toFulfilment(r, false))
    const linkedRunRows: LinkedRunRow[] = runs.map((r) => ({
        id: r.id,
        code: r.code,
        href: `/operation/processing/${r.id}`,
        processDate: r.process_date ?? '—',
        totalInput: r.total_input == null ? '—' : String(r.total_input),
        totalOutput: r.total_output == null ? '—' : String(r.total_output),
        reversed: r.status === 'reversed',
        statusLabel: r.status === 'reversed'
            ? t('processing.wo.runReversed')
            : t('processing.status.committed'),
    }))

    return (
        <ListPage
            maxWidth="max-w-5xl"
            breadcrumb={
                <Link href="/operation/orders" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            }
            title={<span className="font-mono">{wo.code}</span>}
            // 状态徽章转换前住在 h1 右边的 justify-between 里 —— actions 是同一个位置。
            // 它不是一个动作,但它是【标题那一排右边那个东西】,搬进抬头会把它
            // 从"这张单现在怎么样"降级成"另一个字段"。
            actions={
                <span className="px-3 py-1 rounded bg-gray-200 text-sm">
                    {t(workOrderStatusKey(wo.status))}
                </span>
            }
            // ★★ 详情页恒为 ok —— 这张工单在不在由上面的 notFound() 回答。CONV-8 §⑤。
            state={{ kind: 'ok' }}
            // 【收工 / 取消的理由摆在最上面】—— 一张终态的单据,人第一个问题是
            // "为什么结束了",答案不该藏在历史列表的最下面。notices 画在标题之下、
            // 一切分支之前,正是这两条横幅要的位置。
            notices={
                <>
                    {wo.closed_at && (
                        <div className="bg-gray-50 border border-gray-300 text-gray-800 px-4 py-3 rounded mb-4">
                            {t('processing.wo.closedBanner', {
                                at: formatTimestamp(wo.closed_at, dl), reason: wo.close_reason ?? '—',
                            })}
                        </div>
                    )}
                    {wo.cancelled_at && (
                        <div className="bg-gray-50 border border-gray-300 text-gray-800 px-4 py-3 rounded mb-4">
                            {t('processing.wo.cancelledBanner', {
                                at: formatTimestamp(wo.cancelled_at, dl), reason: wo.cancel_reason ?? '—',
                            })}
                        </div>
                    )}
                </>
            }
        >
            {/* ★ 记录抬头 —— 转换前是一个 <dl grid grid-cols-2>(25 张抬头的四种写法之一)。 */}
            <RecordHeader
                fields={[
                    {
                        label: t('processing.wo.colScheduled'),
                        value: wo.scheduled_date
                            ? new Date(wo.scheduled_date).toLocaleDateString(dl)
                            : <span className="text-gray-500 italic">{t('processing.wo.noSchedule')}</span>,
                    },
                    { label: t('processing.wo.colNotes'), value: wo.notes ?? '—' },
                ]}
            />

            {/* ── 投入侧 ──────────────────────────────────────────────── */}
            <h2 className="text-lg font-semibold mt-6 mb-1">{t('processing.wo.inputSide')}</h2>
            <p className="text-xs text-gray-500 mb-2">{t('processing.wo.inputSideNote')}</p>
            <InputSideTable rows={inputTableRows} />
            {/* ★ 出口:改计划行。住 children,靠 state 恒为 'ok' 撑着;
                它自己带 blockedReason,不可改时说【为什么】而不是消失。 */}
            <div className="mt-2">
                <AmendLinesControl
                    id={wo.id} rows={amendRows} editable={editable}
                    blockedReason={!canEdit
                        ? `${t('common.restricted')} — ${t('processing.wo.needsEdit')}`
                        : t('processing.wo.blocked.amendTerminal', { status: t(workOrderStatusKey(wo.status)) })}
                />
            </div>

            {/* ── 产出侧 ──────────────────────────────────────────────── */}
            <h2 className="text-lg font-semibold mt-8 mb-1">{t('processing.wo.outputSide')}</h2>
            <p className="text-xs text-gray-500 mb-2">{t('processing.wo.outputSideNote')}</p>
            <OutputSideTable rows={outputTableRows} />

            {/* ── 挂上来的加工单 ──────────────────────────────────────── */}
            {/* 转换前是 {runs.length === 0 ? <p>没有</p> : <table>} —— 现在表无条件画,
                空态由表自己说(与 CONV-9 给 /hr/employees/[id] 的修法同向)。 */}
            <h2 className="text-lg font-semibold mt-8 mb-2">{t('processing.wo.linkedRuns')}</h2>
            <LinkedRunsTable rows={linkedRunRows} />
            {runs.some((r) => r.status === 'reversed') && (
                <p className="text-xs text-gray-500 mt-2">{t('processing.wo.reversedNote')}</p>
            )}

            {/* ── 动作 ────────────────────────────────────────────────── */}
            {/* ★ 出口:发布 / 收工 / 取消。住 children,无条件画,自己说不可用的理由。 */}
            <h2 className="text-lg font-semibold mt-8 mb-2">{t('processing.wo.actionsTitle')}</h2>
            <WorkOrderActions id={wo.id} status={wo.status} canEdit={canEdit} hasRuns={liveRuns.length > 0} />

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
        </ListPage>
    )
}
