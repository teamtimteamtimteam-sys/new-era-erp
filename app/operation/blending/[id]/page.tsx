// app/operation/blending/[id]/page.tsx
// MES-5b-3(2026-10-09,MES-5b Step 0 Q17–Q20,Tim):一份配料计划 —— 目标与预测、候选批次、放行 / 取消、从这里执行、之后的化验对着目标。
//   【门】requireFunction(FN.blending) = module.processing.view。
//   【这一页不算任何数】预测、实际与差、化验对着目标,全部取自四张视图(blending_plan_prediction · _line_metals · _execution · _outcome)。
//   【受限 ≠ 没量过 ≠ 0】看不见一批的读者,那一批的含量与由它算出的预测读到 NULL 且 content_restricted —— 屏幕说「受限」。
//   【执行只在这里】配料这道工序不在新建加工单的选单里(started_from_run_page);库那一侧另有一道守卫(BLEND_RUN_FROM_PLAN_ONLY)。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import { fmtKg } from '@/lib/massFormat'
import { blendingStatusKey, blendingFlagKey, blendingVerdictKey, blendingSourceKey } from '../blendingTypes'
import { loadBlendingOptions } from '../options'
import BlendingPlanForm from '../BlendingPlanForm'
import BlendingPlanActions from './BlendingPlanActions'
import ExecuteBlendForm from './ExecuteBlendForm'
import { TargetsTable, LinesTable, OutcomeTable, type TargetRow, type LineRow, type OutcomeRow } from './BlendingTables'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

type Plan = {
    id: string; code: string; status: string; output_material_id: string; source_contract_id: string | null; notes: string | null
    created_at: string; created_by: string | null; released_at: string | null; executed_at: string | null; run_id: string | null
    cancelled_at: string | null; cancel_reason: string | null
}
type Pred = {
    metal: string; has_target: boolean; min_pct: number | null; max_pct: number | null; target_source: string | null
    line_count: number; lines_measured: number | null; lines_from_assay: number | null; lines_manual: number | null
    lines_source_unknown: number | null; predicted_pct: number | null; not_measured: boolean | null; flag: string | null; content_restricted: boolean
}
type LineMetal = {
    line_id: string; batch_kind: string; batch_id: string; batch_code: string; planned_kg: number; metal: string | null
    content_pct: number | null; content_source: string | null; content_restricted: boolean
}
type Exec = { line_id: string; batch_code: string; planned_kg: number; actual_kg: number | null; difference_kg: number | null; run_code: string | null; run_status: string | null }
type Outcome = {
    metal: string; min_pct: number | null; max_pct: number | null; run_id: string; run_status: string; batch_id: string | null; batch_code: string | null
    assay_code: string | null; assay_date: string | null; weight_basis: string | null; content_pct: number | null; verdict: string | null; content_restricted: boolean
}

const pct = (n: number) => `${Number(n).toFixed(2)} %`
const kg = (n: number) => fmtKg(n)

export default async function BlendingPlanPage({ params, searchParams }: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ trail?: string | string[] }>
}) {
    const denied = await requireFunction(FN.blending)
    if (denied) return denied
    const { id } = await params
    if (!UUID.test(id)) notFound()
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const plan = mustOne(
        await supabase.from('blending_plans')
            .select('id, code, status, output_material_id, source_contract_id, notes, created_at, created_by, released_at, executed_at, run_id, cancelled_at, cancel_reason')
            .eq('id', id).maybeSingle(),
        'blending_plans') as Plan | null
    if (!plan) notFound()

    const [material, contractRows, pred, lineMetals, execRows, outcome, metalRows] = await Promise.all([
        supabase.from('material_lookup').select('code, name').eq('id', plan.output_material_id).maybeSingle(),
        plan.source_contract_id
            ? supabase.from('contracts').select('code, title').eq('id', plan.source_contract_id)
            : Promise.resolve(null),
        supabase.from('blending_plan_prediction').select('metal, has_target, min_pct, max_pct, target_source, line_count, lines_measured, lines_from_assay, lines_manual, lines_source_unknown, predicted_pct, not_measured, flag, content_restricted').eq('plan_id', id).order('metal'),
        supabase.from('blending_plan_line_metals').select('line_id, batch_kind, batch_id, batch_code, planned_kg, metal, content_pct, content_source, content_restricted').eq('plan_id', id).order('batch_code'),
        supabase.from('blending_plan_execution').select('line_id, batch_code, planned_kg, actual_kg, difference_kg, run_code, run_status').eq('plan_id', id),
        supabase.from('blending_plan_outcome').select('metal, min_pct, max_pct, run_id, run_status, batch_id, batch_code, assay_code, assay_date, weight_basis, content_pct, verdict, content_restricted').eq('plan_id', id).order('metal'),
        supabase.from('substances').select('code, name_en, name_zh'),
    ])
    const mat = mustOne(material, 'material_lookup') as { code: string; name: string } | null
    // 合同的读规则按客户 / 供应商查看码:读不到就说「受限」,不说"没有合同"
    const contractList = contractRows === null ? null : mustRows(contractRows, 'contracts') as { code: string; title: string }[]
    const contract: { code: string; title: string } | 'restricted' | null =
        contractList === null ? null : contractList.length === 0 ? 'restricted' : contractList[0]
    const predRows = mustRows(pred, 'blending_plan_prediction') as Pred[]
    const lmRows = mustRows(lineMetals, 'blending_plan_line_metals') as LineMetal[]
    const exRows = mustRows(execRows, 'blending_plan_execution') as Exec[]
    const outRows = mustRows(outcome, 'blending_plan_outcome') as Outcome[]
    const metals = mustRows(metalRows, 'substances') as { code: string; name_en: string; name_zh: string }[]
    const metalName = (c: string) => { const m = metals.find((x) => x.code === c); return m ? (locale === 'zh' ? m.name_zh : m.name_en) : c }
    const bounds = (min: number | null, max: number | null) =>
        min != null && max != null ? `${min} – ${max} %` : min != null ? `≥ ${min} %` : max != null ? `≤ ${max} %` : '—'

    const [canCreate, canRelease, canCommit] = await Promise.all([can('action.wo_create'), can('action.wo_release'), can('action.processing_commit')])
    const { data: meData, error: meErr } = await supabase.auth.getUser()
    const myUserId = meErr ? null : (meData.user?.id ?? null)
    const releaseBlockedReason = myUserId && plan.created_by === myUserId ? t('blending.blocked.releaseSelf') : null

    // ── 目标与预测 ──
    const targetRows: TargetRow[] = predRows.map((p) => ({
        metal: metalName(p.metal),
        bounds: p.has_target ? bounds(p.min_pct, p.max_pct) : t('blending.noTargetForMetal'),
        source: p.target_source ? t(blendingSourceKey(p.target_source)) : '—',
        predicted: p.content_restricted ? t('common.restricted')
            : p.predicted_pct == null ? t('blending.notMeasured') : pct(p.predicted_pct),
        predictedTone: p.content_restricted || p.predicted_pct == null ? 'muted' : p.flag && p.flag !== 'within' ? 'flag' : 'ok',
        measured: p.content_restricted ? t('common.restricted') : t('blending.measuredOf', { n: String(p.lines_measured ?? 0), of: String(p.line_count) }),
        sources: p.content_restricted ? t('common.restricted')
            : t('blending.sourcesCount', { assay: String(p.lines_from_assay ?? 0), manual: String(p.lines_manual ?? 0), unknown: String(p.lines_source_unknown ?? 0) }),
        flag: p.content_restricted ? t('common.restricted') : p.flag ? t(blendingFlagKey(p.flag)) : '—',
    }))

    // ── 候选批次:一行一批,含量逐种金属连起来 ──
    const exOf = new Map(exRows.map((e) => [e.line_id, e]))
    const lineIds = [...new Set(lmRows.map((r) => r.line_id))]
    const lineRows: LineRow[] = lineIds.map((lid) => {
        const rs = lmRows.filter((r) => r.line_id === lid)
        const first = rs[0]
        const restricted = rs.some((r) => r.content_restricted)
        const measured = rs.filter((r) => r.metal && r.content_pct != null)
        const content = restricted ? t('common.restricted')
            : measured.length === 0 ? t('blending.noContent')
            : measured.map((r) => `${metalName(r.metal!)} ${Number(r.content_pct)} % (${t(blendingSourceKey(r.content_source ?? 'unknown'))})`).join(' · ')
        const ex = exOf.get(lid)
        const diff = ex?.difference_kg
        return {
            id: lid, batchCode: first.batch_code,
            batchHref: first.batch_kind === 'inbound' ? `/inbound/${first.batch_id}/edit` : `/output/${first.batch_id}/edit`,
            kind: t('blending.kind.' + first.batch_kind),
            planned: kg(first.planned_kg), content, contentMuted: restricted || measured.length === 0,
            actual: ex?.actual_kg == null ? '—' : kg(ex.actual_kg),
            difference: diff == null ? '—' : (Number(diff) > 0 ? '+' : '') + kg(diff),
            differenceNegative: diff != null && Number(diff) < 0,
        }
    })

    // ── 之后的化验对着目标 ──
    const outcomeRows: OutcomeRow[] = outRows.map((o) => ({
        metal: metalName(o.metal),
        bounds: bounds(o.min_pct, o.max_pct),
        assay: o.content_restricted ? t('common.restricted')
            : o.assay_code ? `${o.assay_code} · ${formatDate(o.assay_date, locale) ?? '—'}${o.weight_basis ? ' · ' + t('blending.basis.' + o.weight_basis) : ''}` : '—',
        content: o.content_restricted ? t('common.restricted') : o.content_pct == null ? '—' : pct(o.content_pct),
        verdict: o.content_restricted ? t('common.restricted') : o.verdict ? t(blendingVerdictKey(o.verdict)) : '—',
        verdictTone: o.content_restricted || !o.verdict || o.verdict === 'not_assayed' ? 'muted' : o.verdict === 'within' ? 'ok' : 'flag',
    }))
    const blended = outRows[0] ?? null

    // 草稿态才需要表单的四份清单
    const options = plan.status === 'draft' ? await loadBlendingOptions(supabase, locale) : null
    // 改草稿时目标原样带回去 —— 抄自合同的那几条带着它的规格(source_grade_spec_id),保存之后仍是"抄自合同"
    const draftTargets = plan.status !== 'draft' ? [] : mustRows(
        await supabase.from('blending_plan_targets').select('metal, min_pct, max_pct, source, source_grade_spec_id').eq('plan_id', id).order('metal'),
        'blending_plan_targets') as { metal: string; min_pct: number | null; max_pct: number | null; source: string; source_grade_spec_id: string | null }[]
    const shifts = plan.status === 'released'
        ? (mustRows(await supabase.from('shifts').select('code, name_en, name_zh').eq('is_active', true).order('sort_order'), 'shifts') as
            { code: string; name_en: string; name_zh: string }[]).map((s) => ({ code: s.code, name: locale === 'zh' ? s.name_zh : s.name_en }))
        : []
    const planLines = lineIds.map((lid) => { const r = lmRows.find((x) => x.line_id === lid)!; return { lineId: lid, batchCode: r.batch_code, plannedKg: Number(r.planned_kg) } })

    return (
        <ListPage
            maxWidth="max-w-5xl"
            breadcrumb={<Link href="/operation/blending" className="hover:underline text-sm app-link">{t('common.back')}</Link>}
            title={<span>{plan.code}</span>}
            actions={<span className="px-3 py-1 rounded bg-gray-200 text-sm">{t(blendingStatusKey(plan.status))}</span>}
            state={{ kind: 'ok' }}
            notices={plan.cancelled_at ? (
                <div className="bg-gray-50 border border-gray-300 text-[color:var(--brand-text)] px-4 py-3 rounded mb-4">
                    {t('blending.cancelledBanner', { at: formatAuditStamp(plan.cancelled_at), reason: plan.cancel_reason ?? '—' })}
                </div>
            ) : undefined}
        >
            <RecordHeader
                fields={[
                    { label: t('blending.colOutputMaterial'), value: mat ? `${mat.code} — ${mat.name}` : '—' },
                    { label: t('blending.form.contract'), value: contract === null ? t('blending.form.noContract')
                        : contract === 'restricted' ? t('common.restricted') : `${contract.code} — ${contract.title}` },
                    { label: t('blending.colCreated'), value: formatAuditStamp(plan.created_at) },
                    { label: t('blending.released'), value: plan.released_at ? formatAuditStamp(plan.released_at) : '—' },
                    { label: t('blending.executed'), value: plan.executed_at ? formatAuditStamp(plan.executed_at) : '—' },
                    { label: t('blending.colNotes'), value: plan.notes ?? '—' },
                ]}
            />

            <h2 className="mt-6 mb-1">{t('blending.targetsTitle')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('blending.targetsNote')}</p>
            <TargetsTable rows={targetRows} />

            <h2 className="mt-8 mb-1">{t('blending.linesTitle')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('blending.linesNote')}</p>
            <LinesTable rows={lineRows} />

            {plan.status === 'executed' && blended && (
                <>
                    <h2 className="mt-8 mb-1">{t('blending.outcomeTitle')}</h2>
                    <p className="text-sm mb-1">
                        {t('blending.outcomeRun')}{' '}
                        <Link href={`/operation/processing/${blended.run_id}`} className="hover:underline app-link">
                            {exRows[0]?.run_code ?? '—'}
                        </Link>
                        {blended.run_status === 'reversed' && <span className="ml-2 text-amber-700">{t('blending.runReversed')}</span>}
                        {blended.batch_id && (
                            <>
                                {' · '}{t('blending.outcomeBatch')}{' '}
                                <Link href={`/output/${blended.batch_id}/edit`} className="hover:underline app-link">{blended.batch_code}</Link>
                            </>
                        )}
                    </p>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('blending.outcomeNote')}</p>
                    <OutcomeTable rows={outcomeRows} />
                </>
            )}

            {plan.status === 'draft' && options && (
                <>
                    <h2 className="mt-8 mb-2">{t('blending.editTitle')}</h2>
                    <BlendingPlanForm mode="amend" planId={plan.id} materials={options.outputMaterials} batches={options.batches}
                        contracts={options.contracts} metals={options.metals} canEdit={canCreate}
                        inboundVisible={options.canIn} outputVisible={options.canOut}
                        initial={{
                            outputMaterialId: plan.output_material_id, contractId: plan.source_contract_id ?? '', notes: plan.notes ?? '',
                            targets: draftTargets.map((x) => ({ gradeSpecId: x.source === 'contract' ? x.source_grade_spec_id : null, metal: x.metal,
                                                                min: x.min_pct == null ? null : Number(x.min_pct), max: x.max_pct == null ? null : Number(x.max_pct) })),
                            lines: lineIds.map((lid) => { const r = lmRows.find((x) => x.line_id === lid)!; return { batchKey: `${r.batch_kind}:${r.batch_id}`, plannedKg: Number(r.planned_kg) } }),
                        }} />
                </>
            )}

            {plan.status === 'released' && (
                <>
                    <h2 className="mt-8 mb-1">{t('blending.executeTitle')}</h2>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('blending.executeNote')}</p>
                    <ExecuteBlendForm id={plan.id} lines={planLines} shifts={shifts} canExecute={canCommit} />
                </>
            )}

            <h2 className="mt-8 mb-2">{t('blending.actionsTitle')}</h2>
            <BlendingPlanActions id={plan.id} status={plan.status} canRelease={canRelease} canManage={canCreate}
                releaseBlockedReason={releaseBlockedReason} />

            <AuditTrail subject="blending_plan" id={id} show={trailCount((await searchParams).trail)} />
        </ListPage>
    )
}
