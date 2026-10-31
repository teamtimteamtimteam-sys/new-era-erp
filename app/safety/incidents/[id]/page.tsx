// app/safety/incidents/[id]/page.tsx
// MES-7b-1(2026-10-16,MES-0 Q73 · Q74 · Q76;MES-7b Step 0 Q3 · Q6–Q12,Tim):一件事故 —— 它记下的样子与现在的样子(更正过的值说了算)、
//   受伤的细节(或「受限」)、NEA:要不要通报、通报了没有、书面报告的期限(未确认时标出来)、之后的事实、碰过的批次(建议、确认、按批号挑、
//   带理由解开、在链上的批上开一张来源 incident 的不合格报告)、引用它的交接班、从它开出来的报告、审计记录。
//   【门】requireFunction(FN.safetyIncidents) = module.safety.view —— 唯一的例外是受伤的那名员工本人(Q6:他永远看得见自己那一件的细节):
//   没有安全查看码而 incident_rows 仍给了他这一行(那张视图的行谓词带本人),页面只画事故与受伤的细节,别的一概不画。
//   【这一页不判任何事】期限、它的状态、受伤的细节能不能看(injury_visible)、建议哪几批,全部是库里的答案。
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
import { formatAuditStamp } from '@/lib/dates'
import { loadBatchOptions } from '@/app/quality/samples/batchOptions'
import { neaStatusLabel, deadlineLabel } from '../neaStatus'
import { fieldKey, updateKindKey, batchHref } from '../../safetyTypes'
import IncidentUpdatesPanel, { type UpdateRow } from './IncidentUpdatesPanel'
import IncidentBatchesPanel, { type LinkRow, type SuggestionRow } from './IncidentBatchesPanel'
import DaysLostCorrectionForm from './DaysLostCorrectionForm'
import { readAll } from '@/lib/readAll'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

type I = {
    id: string; code: string; kind_code: string; kind_name_en: string; kind_name_zh: string; occurred_at: string; location_code: string | null
    location_name: string | null; equipment_id: string | null; equipment_code: string | null; equipment_name: string | null; duration_min: number | null
    what_happened: string; immediate_action: string; responsible_label: string | null; nea_reportable: boolean; source: string
    downtime_id: string | null; downtime_started_at: string | null; run_event_id: number | null; run_event_run_id: string | null
    run_event_run_code: string | null; run_event_occurred_at: string | null; recorded_at: string; corrections: number
    notified_at: string | null; notified_reference: string | null; report_submitted_at: string | null; report_reference: string | null
    closed_at: string | null; closed_summary: string | null; report_deadline: string | null; deadline_state: string; deadline_working_days: number | null
    deadline_confirmed: boolean; injury_visible: boolean; injured_employee_id: string | null; injured_employee_label: string | null
    injured_person_name: string | null; injury_nature: string | null; injury_treatment: string | null; days_lost: number | null
    days_lost_recorded: number | null; days_lost_corrections: number | null
}

const COLS = 'id, code, kind_code, kind_name_en, kind_name_zh, occurred_at, location_code, location_name, equipment_id, equipment_code, equipment_name, duration_min, what_happened, immediate_action, responsible_label, nea_reportable, source, downtime_id, downtime_started_at, run_event_id, run_event_run_id, run_event_run_code, run_event_occurred_at, recorded_at, corrections, notified_at, notified_reference, report_submitted_at, report_reference, closed_at, closed_summary, report_deadline, deadline_state, deadline_working_days, deadline_confirmed, injury_visible, injured_employee_id, injured_employee_label, injured_person_name, injury_nature, injury_treatment, days_lost, days_lost_recorded, days_lost_corrections'

export default async function IncidentPage({ params, searchParams }: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ trail?: string | string[] }>
}) {
    const { id } = await params
    if (!UUID.test(id)) notFound()
    const canView = await can('module.safety.view')
    // 只有受伤的那名员工本人可以不经安全查看码进来;别人照常是那张「受限」页
    const denied = canView ? null : await requireFunction(FN.safetyIncidents)
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const n = mustOne(await supabase.from('incident_rows').select(COLS).eq('id', id).maybeSingle(), 'incident_rows') as I | null
    if (!n) { if (denied) return denied; notFound() }
    const selfOnly = !canView

    const kindLabel = locale === 'zh' ? n.kind_name_zh : n.kind_name_en
    const num = (v: number | null) => (v == null ? '—' : String(Number(v)))
    const fields = [
        { label: t('safety.incident.kind'), value: kindLabel },
        { label: t('safety.incident.occurredAt'), value: formatAuditStamp(n.occurred_at) },
        { label: t('safety.incident.location'), value: n.location_code ? `${n.location_code} · ${n.location_name}` : '—' },
        { label: t('safety.incident.machine'), value: n.equipment_id
            ? (selfOnly ? `${n.equipment_code}` : <Link href={`/operation/equipment/${n.equipment_id}`} className="app-link hover:underline">{n.equipment_code}</Link>) : '—' },
        { label: t('safety.incident.durationMin'), value: num(n.duration_min) },
        { label: t('safety.incident.responsible'), value: n.responsible_label ?? '—' },
        { label: t('safety.incident.source'), value: n.source === 'device' ? t('safety.source.device') : t('safety.source.manual') },
        { label: t('safety.incident.recordedAt'), value: formatAuditStamp(n.recorded_at) },
    ]

    const injury = (
        <section className="mt-6" data-section="injury">
            <h2 className="mb-1">{t('safety.incident.injuryTitle')}</h2>
            {n.injury_visible ? (
                (n.injured_employee_id || n.injured_person_name) ? (
                    <RecordHeader fields={[
                        { label: t('safety.incident.injuredPerson'), value: n.injured_employee_label ?? n.injured_person_name ?? '—' },
                        { label: t('safety.incident.injuryNature'), value: n.injury_nature ?? '—' },
                        { label: t('safety.incident.injuryTreatment'), value: n.injury_treatment ?? '—' },
                        // ESG-2(Q7):现在的值是最后一次更正;更正过就把记下时的那个数与次数一起写出来
                        { label: t('safety.incident.daysLost'), value: (n.days_lost_corrections ?? 0) > 0
                            ? <span data-days-lost-corrected="1">{num(n.days_lost)} <span className="text-xs text-[color:var(--brand-muted-text)]">{t('safety.daysLost.correctedFrom', { recorded: num(n.days_lost_recorded), n: n.days_lost_corrections ?? 0 })}</span></span>
                            : num(n.days_lost) },
                    ]} />
                ) : <p className="text-sm text-[color:var(--brand-muted-text)]" data-value="no-injury">{t('safety.incident.noInjury')}</p>
            ) : (
                <p className="text-sm" data-restricted="injury">
                    <span className="font-medium">{t('common.restricted')}</span>{' — '}{t('safety.incident.injuryRestricted')}
                </p>
            )}
        </section>
    )

    if (selfOnly) {
        return (
            <ListPage maxWidth="max-w-5xl" title={<span>{n.code}</span>} intro={t('safety.incident.selfIntro')} state={{ kind: 'ok' }}>
                <RecordHeader fields={fields} />
                <h2 className="mt-6 mb-1">{t('safety.incident.whatHappened')}</h2>
                <p className="text-sm whitespace-pre-wrap">{n.what_happened}</p>
                {injury}
            </ListPage>
        )
    }

    const [canEdit, canQualityEdit, kindsRes, updRes, linkRes, hoRes, ncrRes] = await Promise.all([
        can('module.safety.edit'), can('module.quality.edit'),
        supabase.from('incident_kinds').select('code, name_en, name_zh, is_active').order('sort_order'),
        supabase.from('incident_updates').select('id, kind, occurred_at, reference, field, new_value, reason, summary, recorded_at').eq('incident_id', id).order('id'),
        supabase.from('incident_batch_rows').select('id, batch_kind, batch_id, batch_code, material_name, basis, linked_at, unlinked_at, unlink_reason, active').eq('incident_id', id).order('id'),
        supabase.from('shift_handover_incident_refs').select('handover_id, shift_handovers ( handover_date, shift_code )').eq('incident_id', id),
        supabase.from('ncr_rows').select('id, code, status, batch_code, holding').eq('incident_id', id).order('opened_at'),
    ])
    const kinds = mustRows(kindsRes, 'incident_kinds') as { code: string; name_en: string; name_zh: string; is_active: boolean }[]
    const kindName = (code: string) => { const k = kinds.find((x) => x.code === code); return k ? (locale === 'zh' ? k.name_zh : k.name_en) : code }
    const updates: UpdateRow[] = (mustRows(updRes, 'incident_updates') as {
        id: number; kind: string; occurred_at: string | null; reference: string | null; field: string | null; new_value: string | null
        reason: string | null; summary: string | null; recorded_at: string }[]).map((u) => ({
        id: u.id,
        kindLabel: t(updateKindKey(u.kind)),
        when: formatAuditStamp(u.occurred_at ?? u.recorded_at),
        detail: u.kind === 'correction'
            ? `${t(fieldKey(u.field ?? ''))}: ${u.field === 'kind_code' ? kindName(u.new_value ?? '')
                : u.field === 'occurred_at' ? formatAuditStamp(u.new_value ?? '')
                : u.field === 'nea_reportable' ? (u.new_value === 'true' ? t('safety.form.neaYes') : t('safety.form.neaNo'))
                : (u.new_value ?? '')}`
            : (u.summary ?? u.reference ?? ''),
        reason: u.reason,
        // TABLE-EXPORT-3c(Tim 2026-10-25):导出读那个时刻本身
        whenRaw: u.occurred_at ?? u.recorded_at,
    }))
    const links: LinkRow[] = (mustRows(linkRes, 'incident_batch_rows') as {
        id: number; batch_kind: string; batch_id: string; batch_code: string; material_name: string | null; basis: string; linked_at: string
        unlinked_at: string | null; unlink_reason: string | null; active: boolean }[]).map((l) => ({
        id: l.id, batchKind: l.batch_kind as 'inbound' | 'output', batchId: l.batch_id, batchCode: l.batch_code, material: l.material_name ?? '',
        basis: l.basis, linkedAt: formatAuditStamp(l.linked_at), unlinkedAt: l.unlinked_at ? formatAuditStamp(l.unlinked_at) : null,
        unlinkReason: l.unlink_reason, active: l.active, href: batchHref(l.batch_kind, l.batch_id),
        // TABLE-EXPORT-3c(Tim 2026-10-25):导出读链上的那个时刻本身
        linkedAtRaw: l.linked_at,
    }))
    const sugRes = await readAll(() => supabase.rpc('suggest_incident_batches', { p_incident_id: id }), { label: 'suggest_incident_batches', key: ['batch_kind', 'batch_id', 'batch_code', 'basis', 'evidence', 'qty', 'already_linked'] })
    const suggestions: SuggestionRow[] = (mustRows(sugRes, 'suggest_incident_batches') as {
        batch_kind: string; batch_id: string; batch_code: string; basis: string; evidence: string; qty: number; already_linked: boolean }[]).map((s) => ({
        batchKind: s.batch_kind as 'inbound' | 'output', batchId: s.batch_id, batchCode: s.batch_code, basis: s.basis,
        evidence: s.evidence, qty: String(Number(s.qty)), linked: s.already_linked, href: batchHref(s.batch_kind, s.batch_id),
    }))
    const batchOptions = await loadBatchOptions(supabase)
    const handovers = (mustRows(hoRes, 'shift_handover_incident_refs') as { handover_id: string; shift_handovers: { handover_date: string; shift_code: string } | null }[])
    const ncrs = mustRows(ncrRes, 'ncr_rows') as { id: string; code: string; status: string; batch_code: string; holding: boolean }[]
    const activeKinds = kinds.filter((k) => k.is_active).map((k) => ({ id: k.code, label: locale === 'zh' ? k.name_zh : k.name_en }))

    return (
        <ListPage
            maxWidth="max-w-5xl"
            breadcrumb={<Link href="/safety/incidents" className="hover:underline text-sm app-link">{t('common.back')}</Link>}
            title={<span>{n.code}</span>}
            actions={
                <span className={`px-3 py-1 rounded text-sm ${n.closed_at ? 'bg-gray-200' : 'bg-amber-100'}`} data-value="status">
                    {n.closed_at ? t('safety.status.closed', { date: formatAuditStamp(n.closed_at) }) : t('safety.status.open')}
                </span>
            }
            state={{ kind: 'ok' }}
            notices={
                n.nea_reportable && (!n.notified_at || !n.report_submitted_at) ? (
                    <div className="bg-amber-50 border border-amber-300 px-4 py-3 rounded mb-4 text-sm" data-notice="nea">
                        {neaStatusLabel(t, locale, n)}
                    </div>
                ) : null
            }
        >
            <RecordHeader fields={fields} />
            {n.corrections > 0 && <p className="text-xs text-[color:var(--brand-muted-text)] mt-2">{t('safety.incident.correctedNote', { n: String(n.corrections) })}</p>}

            <h2 className="mt-6 mb-1">{t('safety.incident.whatHappened')}</h2>
            <p className="text-sm whitespace-pre-wrap" data-field="what_happened">{n.what_happened}</p>
            <h2 className="mt-4 mb-1">{t('safety.incident.immediateAction')}</h2>
            <p className="text-sm whitespace-pre-wrap" data-field="immediate_action">{n.immediate_action}</p>

            {(n.downtime_id || n.run_event_id) && (
                <section className="mt-6" data-section="citations">
                    <h2 className="mb-1">{t('safety.incident.citationsTitle')}</h2>
                    <RecordHeader fields={[
                        { label: t('safety.incident.downtime'), value: n.downtime_id && n.equipment_id
                            ? <Link href={`/operation/equipment/${n.equipment_id}`} className="app-link hover:underline">{formatAuditStamp(n.downtime_started_at ?? '')}</Link> : '—' },
                        { label: t('safety.incident.runEvent'), value: n.run_event_run_id
                            ? <Link href={`/operation/processing/${n.run_event_run_id}`} className="app-link hover:underline">{`${n.run_event_run_code} · ${formatAuditStamp(n.run_event_occurred_at ?? '')}`}</Link> : '—' },
                    ]} />
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('safety.incident.citationsNote')}</p>
                </section>
            )}

            {injury}
            {/* ESG-2(Q7):误工天数的更正 —— 只在没关闭、而且(读得到受伤细节时)确实有受伤的人的事故上;读不到受伤细节的编辑者照样能更正(库判有没有受伤的人) */}
            {!n.closed_at && (!n.injury_visible || n.injured_employee_id || n.injured_person_name) && (
                <DaysLostCorrectionForm incidentId={n.id} canEdit={canEdit} />
            )}

            <section className="mt-8" data-section="nea">
                <h2 className="mb-1">{t('safety.incident.neaTitle')}</h2>
                <RecordHeader fields={[
                    { label: t('safety.incident.neaReportable'), value: n.nea_reportable ? t('safety.form.neaYes') : t('safety.form.neaNo') },
                    ...(n.nea_reportable ? [
                        { label: t('safety.incident.notifiedAt'), value: n.notified_at ? `${formatAuditStamp(n.notified_at)}${n.notified_reference ? ` · ${n.notified_reference}` : ''}` : t('safety.nea.notifyDue') },
                        { label: t('safety.incident.reportDeadline'), value: <span data-value="deadline">{deadlineLabel(t, locale, n)}</span> },
                        { label: t('safety.incident.reportSubmittedAt'), value: n.report_submitted_at ? `${formatAuditStamp(n.report_submitted_at)}${n.report_reference ? ` · ${n.report_reference}` : ''}` : '—' },
                    ] : []),
                ]} />
                {n.nea_reportable && !n.deadline_confirmed && n.deadline_state === 'computed' && (
                    <p className="text-xs text-amber-800 mt-1" data-note="deadline-unconfirmed">{t('safety.nea.unconfirmedNote', { n: String(n.deadline_working_days ?? '') })}</p>
                )}
            </section>

            <IncidentUpdatesPanel
                incidentId={id} incidentCode={n.code} updates={updates} canEdit={canEdit} reportable={n.nea_reportable}
                notified={!!n.notified_at} reportSubmitted={!!n.report_submitted_at} closed={!!n.closed_at} kinds={activeKinds}
            />

            <IncidentBatchesPanel
                incidentId={id} incidentCode={n.code} links={links} suggestions={suggestions} canEdit={canEdit} canQualityEdit={canQualityEdit}
                hasLocation={!!n.location_code} hasMachine={!!n.equipment_id}
                inboundOptions={batchOptions.inbound} outputOptions={batchOptions.output}
            />

            <section className="mt-8" data-section="handovers">
                <h2 className="mb-1">{t('safety.incident.handoversTitle')}</h2>
                {handovers.length === 0 ? <p className="text-sm text-[color:var(--brand-muted-text)]">{t('safety.incident.noHandovers')}</p> : (
                    <ul className="text-sm list-disc pl-5">
                        {handovers.map((h) => (
                            <li key={h.handover_id}>
                                <Link href={`/operation/handovers/${h.handover_id}`} className="app-link hover:underline">
                                    {h.shift_handovers ? `${h.shift_handovers.handover_date} · ${h.shift_handovers.shift_code}` : h.handover_id}
                                </Link>
                            </li>
                        ))}
                    </ul>
                )}
            </section>

            <section className="mt-8" data-section="ncrs">
                <h2 className="mb-1">{t('safety.incident.ncrsTitle')}</h2>
                {ncrs.length === 0 ? <p className="text-sm text-[color:var(--brand-muted-text)]">{t('safety.incident.noNcrs')}</p> : (
                    <ul className="text-sm list-disc pl-5">
                        {ncrs.map((r) => (
                            <li key={r.id}>
                                <Link href={`/quality/ncr/${r.id}`} className="app-link hover:underline">{r.code}</Link>
                                {` · ${r.batch_code} · `}{r.holding ? t('safety.incident.ncrHolding') : t('safety.incident.ncrReleased')}
                            </li>
                        ))}
                    </ul>
                )}
            </section>

            <AuditTrail subject="incident" id={id} show={trailCount((await searchParams).trail)} />
        </ListPage>
    )
}
