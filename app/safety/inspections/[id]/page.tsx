// app/safety/inspections/[id]/page.tsx
// MES-7b-2(2026-10-16,MES-0 Q72;MES-7b Step 0 Q13–Q15,Tim):一次巡检 —— 照哪一张清单(记下那一刻抄下的代号 / 名字 / 片区)、什么时候、谁、
//   在哪、哪台机器;每一项的结果(字是那一刻抄下的,之后改清单不改它);它更正了哪一次、被哪一次更正;发现(记、关、建任务、开不合格报告);
//   审计记录(主语 inspection_run:巡检、结果、发现、关闭,以及引用发现的不合格报告)。
//   【门】requireFunction(FN.safetyInspections) = module.safety.view。交了就不改:要改就"更正这一次"(另记一次、引用它、写理由)。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import CellsTable, { type CellRow } from '@/app/operation/equipment/CellsTable'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import { inspectionResultKey } from '../../safetyTypes'
import FindingsPanel, { type FindingRow, type FailRow } from './FindingsPanel'
import { xText } from '@/lib/export/cells'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

type Run = {
    id: string; code: string; template_id: string; template_code: string; template_name: string; template_area: string; inspected_at: string
    inspector_label: string; location_code: string | null; location_name: string | null; equipment_id: string | null; equipment_code: string | null
    equipment_name: string | null; notes: string | null; corrects_run_id: string | null; corrects_run_code: string | null; correction_reason: string | null
    corrected_by_run_id: string | null; corrected_by_run_code: string | null; recorded_at: string
}

export default async function InspectionRunPage({ params, searchParams }: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ trail?: string | string[] }>
}) {
    const denied = await requireFunction(FN.safetyInspections)
    if (denied) return denied
    const { id } = await params
    if (!UUID.test(id)) notFound()
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const r = mustOne(await supabase.from('inspection_run_rows')
        .select('id, code, template_id, template_code, template_name, template_area, inspected_at, inspector_label, location_code, location_name, equipment_id, equipment_code, equipment_name, notes, corrects_run_id, corrects_run_code, correction_reason, corrected_by_run_id, corrected_by_run_code, recorded_at')
        .eq('id', id).maybeSingle(), 'inspection_run_rows') as Run | null
    if (!r) notFound()

    const [resRes, findRes, peopleRes, canEdit, canQualityEdit, canTasks, canTasksEdit, canProcessing] = await Promise.all([
        supabase.from('inspection_results').select('position, item_text, result, note').eq('run_id', id).order('position'),
        supabase.from('inspection_finding_rows')
            .select('id, position, item_text, corrective_action, owner_label, due_date, overdue, task_code, is_open, closed_at, what_was_done, ncr_count')
            .eq('run_id', id).order('position').order('recorded_at'),
        supabase.from('incident_people').select('id, code, preferred_name').order('code'),
        can('module.safety.edit'), can('module.quality.edit'), can('module.tasks.view'), can('module.tasks.edit'), can('module.processing.view'),
    ])
    const results = mustRows(resRes, 'inspection_results') as { position: number; item_text: string; result: string; note: string | null }[]
    const findings: FindingRow[] = (mustRows(findRes, 'inspection_finding_rows') as {
        id: string; position: number; item_text: string; corrective_action: string; owner_label: string; due_date: string | null; overdue: boolean
        task_code: string | null; is_open: boolean; closed_at: string | null; what_was_done: string | null; ncr_count: number }[]).map((f) => ({
        id: f.id, position: f.position, itemText: f.item_text, correctiveAction: f.corrective_action, owner: f.owner_label,
        due: f.due_date ? formatDate(f.due_date, locale) : null, overdue: f.overdue, taskCode: f.task_code, open: f.is_open,
        closedAt: f.closed_at ? formatAuditStamp(f.closed_at) : null, whatWasDone: f.what_was_done, ncrCount: f.ncr_count,
    }))
    const people = (mustRows(peopleRes, 'incident_people') as { id: string; code: string; preferred_name: string | null }[])
        .map((p) => ({ id: p.id, label: p.preferred_name ? `${p.code} · ${p.preferred_name}` : p.code }))
    const fails: FailRow[] = results.filter((x) => x.result === 'fail').map((x) => ({ position: x.position, text: x.item_text, note: x.note ?? '' }))
    const superseded = !!r.corrected_by_run_id

    const resultRows: CellRow[] = results.map((x) => ({
        id: String(x.position),
        cells: {
            item: `${x.position}. ${x.item_text}`,
            result: <span className={`px-2 py-0.5 rounded text-xs ${x.result === 'fail' ? 'bg-amber-100' : 'bg-gray-100'}`} data-result={x.result}>{t(inspectionResultKey(x.result))}</span>,
            note: x.note ?? '—',
        },
        // TABLE-EXPORT-1:检查项是屏幕上那一串(序号 + 文字);结果是屏幕上那个词;没写备注照屏幕写「—」
        exports: {
            item: xText(`${x.position}. ${x.item_text}`),
            result: xText(t(inspectionResultKey(x.result))),
            note: xText(x.note ?? '—'),
        },
    }))

    const correct = canEdit && !superseded
        ? <Button asChild variant="outline"><Link href={`/safety/inspections/new?corrects=${id}`}>{t('safety.run.correct')}</Link></Button>
        : !canEdit
            ? <PermissionGate code="module.safety.edit" allowed={false} inline><Button variant="outline" disabled>{t('safety.run.correct')}</Button></PermissionGate>
            : null

    return (
        <ListPage
            maxWidth="max-w-5xl"
            breadcrumb={<Link href="/safety/inspections" className="hover:underline text-sm app-link">{t('common.back')}</Link>}
            title={<span>{r.code}</span>}
            actions={correct}
            state={{ kind: 'ok' }}
            notices={superseded ? (
                <div className="bg-amber-50 border border-amber-300 px-4 py-3 rounded mb-4 text-sm" data-notice="superseded">
                    {t('safety.run.supersededBy')}{' '}
                    <Link href={`/safety/inspections/${r.corrected_by_run_id}`} className="app-link hover:underline">{r.corrected_by_run_code}</Link>
                </div>
            ) : null}
        >
            <RecordHeader fields={[
                { label: t('safety.run.checklist'), value: <Link href={`/safety/inspections/templates/${r.template_id}`} className="app-link hover:underline">{`${r.template_code} · ${r.template_name}`}</Link> },
                { label: t('safety.run.area'), value: r.template_area },
                { label: t('safety.run.inspectedAt'), value: formatAuditStamp(r.inspected_at) },
                { label: t('safety.run.inspector'), value: r.inspector_label },
                { label: t('safety.incident.location'), value: r.location_code ? `${r.location_code} · ${r.location_name}` : '—' },
                { label: t('safety.incident.machine'), value: r.equipment_id
                    ? (canProcessing ? <Link href={`/operation/equipment/${r.equipment_id}`} className="app-link hover:underline">{r.equipment_code}</Link> : r.equipment_code) : '—' },
                { label: t('safety.incident.recordedAt'), value: formatAuditStamp(r.recorded_at) },
            ]} />
            <p className="text-xs text-[color:var(--brand-muted-text)] mt-2">{t('safety.run.copiedNote')}</p>
            {r.corrects_run_id && (
                <p className="text-sm mt-3" data-value="corrects">
                    {t('safety.run.corrects')}{' '}
                    <Link href={`/safety/inspections/${r.corrects_run_id}`} className="app-link hover:underline">{r.corrects_run_code}</Link>
                    {` — ${r.correction_reason ?? ''}`}
                </p>
            )}
            {r.notes && <><h2 className="mt-6 mb-1">{t('safety.run.notes')}</h2><p className="text-sm whitespace-pre-wrap">{r.notes}</p></>}

            <section className="mt-6" data-section="results">
                <h2 className="mb-1">{t('safety.run.resultsTitle')}</h2>
                <CellsTable
                    columns={[{ key: 'item', header: t('safety.run.colItem'), priority: true },
                              { key: 'result', header: t('safety.run.colResult'), priority: true },
                              { key: 'note', header: t('safety.run.colNote') }]}
                    rows={resultRows}
                    empty="—"
                    exportSpec={{ name: 'safety-inspection-results', title: t('safety.run.resultsTitle') }}
                />
            </section>

            <FindingsPanel runId={id} findings={findings} fails={fails} people={people} canEdit={canEdit} canQualityEdit={canQualityEdit}
                           canRaiseTask={canTasks || canTasksEdit} superseded={superseded} />

            <AuditTrail subject="inspection_run" id={id} show={trailCount((await searchParams).trail)} />
        </ListPage>
    )
}
