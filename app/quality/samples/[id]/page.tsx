// app/quality/samples/[id]/page.tsx
// MES-6a-1(2026-10-09,MES-6a Step 0 Q7–Q15,Tim):一份样品 —— 它是谁的、在哪、谁拿着、留到哪一天,以及化验了它的那几份结果。
//   【门】requireFunction(FN.qualitySamples) = module.quality.view;记保管要 module.quality.edit。
//   【这一页不判任何事】状态、实验室、库位、提前处置都读 sample_rows;保管记录读 sample_events(只追加,按 id 记先后)。
//   化验结果的读规则是那一批自己的(进料 / 产出查看码):读不到就是读不到,这里不替它补。
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
import { formatAuditStamp, formatDate, formatDateTime } from '@/lib/dates'
import { businessToday } from '@/lib/format'
import { sampleKindKey, sampleStateKey, sampleEventKey, retentionSourceKey, resultPartyKey, batchHref, assayHref } from '../../qualityTypes'
import SampleEventForm, { type LabOption, type LocationOption } from './SampleEventForm'
import { EventsTable, AssaysTable, type EventRow, type AssayRow } from './SampleTables'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

type Sample = {
    id: string; code: string; kind: string; state: string; batch_kind: string; inbound_batch_id: string | null; output_batch_id: string | null
    batch_code: string; taken_on: string; mass_g: number | null; sales_order_id: string | null; sales_order_code: string | null
    contamination_check_id: number | null; retain_until: string | null; retain_until_source: string; retention_days_at: number | null
    notes: string | null; created_at: string; laboratory_code: string | null; lab_reference: string | null; storage_location_code: string | null
    disposed_at: string | null; disposal_reason: string | null; disposed_early: boolean | null; retention_due: boolean | null
}
type Ev = {
    id: number; event_kind: string; occurred_at: string; laboratory_code: string | null; lab_reference: string | null
    storage_location_id: string | null; reason: string | null; notes: string | null
}

export default async function SamplePage({ params, searchParams }: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ trail?: string | string[] }>
}) {
    const denied = await requireFunction(FN.qualitySamples)
    if (denied) return denied
    const { id } = await params
    if (!UUID.test(id)) notFound()
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const s = mustOne(
        await supabase.from('sample_rows')
            .select('id, code, kind, state, batch_kind, inbound_batch_id, output_batch_id, batch_code, taken_on, mass_g, sales_order_id, sales_order_code, contamination_check_id, retain_until, retain_until_source, retention_days_at, notes, created_at, laboratory_code, lab_reference, storage_location_code, disposed_at, disposal_reason, disposed_early, retention_due')
            .eq('id', id).maybeSingle(),
        'sample_rows') as Sample | null
    if (!s) notFound()
    const batchId = (s.inbound_batch_id ?? s.output_batch_id)!

    const [evRes, labRes, locRes, assayRes, canEdit] = await Promise.all([
        supabase.from('sample_events').select('id, event_kind, occurred_at, laboratory_code, lab_reference, storage_location_id, reason, notes')
            .eq('sample_id', id).order('id'),
        supabase.from('laboratories').select('code, name_en, name_zh, is_active').order('sort_order'),
        supabase.from('storage_locations').select('id, code, name, is_active').order('code'),
        supabase.from('assay_results').select('id, code, result_party, assay_date, lab_name').eq('sample_id', id).is('deleted_at', null).order('assay_date'),
        can('module.quality.edit'),
    ])
    const events = mustRows(evRes, 'sample_events') as Ev[]
    const labs = mustRows(labRes, 'laboratories') as { code: string; name_en: string; name_zh: string; is_active: boolean }[]
    const locs = mustRows(locRes, 'storage_locations') as { id: string; code: string; name: string; is_active: boolean }[]
    const assays = mustRows(assayRes, 'assay_results') as { id: string; code: string; result_party: string; assay_date: string; lab_name: string | null }[]
    const labName = (c: string | null) => { if (!c) return '—'; const l = labs.find((x) => x.code === c); return l ? (locale === 'zh' ? l.name_zh : l.name_en) : c }
    const locName = (lid: string | null) => { if (!lid) return null; const l = locs.find((x) => x.id === lid); return l ? `${l.code} — ${l.name}` : null }

    const eventRows: EventRow[] = events.map((e) => ({
        id: String(e.id),
        when: formatDateTime(e.occurred_at, locale),
        what: t(sampleEventKey(e.event_kind)),
        detail: e.event_kind === 'sent_to_lab'
            ? `${labName(e.laboratory_code)}${e.lab_reference ? ` · ${e.lab_reference}` : ''}`
            : locName(e.storage_location_id) ?? (e.event_kind === 'disposed' ? '—' : t('quality.noLocation')),
        reason: e.reason ?? '—',
        notes: e.notes ?? '—',
    }))
    const assayRows: AssayRow[] = assays.map((a) => ({
        id: a.id, code: a.code, href: assayHref(s.batch_kind, batchId, a.id),
        party: t(resultPartyKey(a.result_party)), date: formatDate(a.assay_date, locale), lab: labName(a.lab_name),
    }))
    const where = s.state === 'at_lab'
        ? `${labName(s.laboratory_code)}${s.lab_reference ? ` · ${s.lab_reference}` : ''}`
        : s.state === 'disposed' ? formatDateTime(s.disposed_at, locale)
        : s.storage_location_code ?? t('quality.noLocation')
    const keepUntil = s.retain_until
        ? `${formatDate(s.retain_until, locale)} · ${t(retentionSourceKey(s.retain_until_source))}${s.retention_days_at ? ` · ${t('quality.settings.days', { n: String(s.retention_days_at) })}` : ''}`
        : `${t('quality.notYetSet')} · ${t(retentionSourceKey(s.retain_until_source))}`
    const labOptions: LabOption[] = labs.filter((l) => l.is_active).map((l) => ({ code: l.code, label: locale === 'zh' ? l.name_zh : l.name_en }))
    const locationOptions: LocationOption[] = locs.filter((l) => l.is_active).map((l) => ({ id: l.id, label: `${l.code} — ${l.name}` }))
    const newAssayHref = s.batch_kind === 'inbound' ? `/inbound/${batchId}/assays/new?sample=${id}` : `/output/${batchId}/assays/new?sample=${id}`

    return (
        <ListPage
            maxWidth="max-w-5xl"
            breadcrumb={<Link href="/quality/samples" className="hover:underline text-sm app-link">{t('common.back')}</Link>}
            title={<span>{s.code}</span>}
            actions={<span className="px-3 py-1 rounded bg-gray-200 text-sm">{t(sampleStateKey(s.state))}</span>}
            state={{ kind: 'ok' }}
            notices={
                <>
                    {s.retention_due && (
                        <div className="bg-amber-50 border border-amber-300 px-4 py-3 rounded mb-4 text-sm" data-notice="retention-due">
                            {t('quality.sample.dueBanner', { date: s.retain_until ? formatDate(s.retain_until, locale) : '—' })}
                        </div>
                    )}
                    {s.disposed_early && (
                        <div className="bg-amber-50 border border-amber-300 px-4 py-3 rounded mb-4 text-sm" data-notice="disposed-early">
                            {t('quality.sample.earlyBanner', { date: s.retain_until ? formatDate(s.retain_until, locale) : '—', reason: s.disposal_reason ?? '—' })}
                        </div>
                    )}
                </>
            }
        >
            <RecordHeader
                fields={[
                    { label: t('quality.samples.colKind'), value: t(sampleKindKey(s.kind)) },
                    { label: t('quality.samples.colBatch'), value: <Link href={batchHref(s.batch_kind, batchId)} className="app-link hover:underline">{s.batch_code}</Link> },
                    { label: t('quality.samples.colTaken'), value: formatDate(s.taken_on, locale) },
                    { label: t('quality.form.massG'), value: s.mass_g == null ? '—' : `${Number(s.mass_g)} g` },
                    { label: t('quality.samples.colWhere'), value: where },
                    { label: t('quality.samples.colKeepUntil'), value: keepUntil },
                    ...(s.batch_kind === 'output' ? [{ label: t('quality.form.salesOrder'), value: s.sales_order_code ?? '—' }] : []),
                    ...(s.contamination_check_id != null ? [{ label: t('quality.form.check'), value: `#${s.contamination_check_id}` }] : []),
                    { label: t('quality.form.notes'), value: s.notes ?? '—' },
                    { label: t('quality.sample.recorded'), value: formatAuditStamp(s.created_at) },
                ]}
            />

            <h2 className="mt-6 mb-1">{t('quality.sample.custodyTitle')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('quality.sample.custodyNote')}</p>
            <EventsTable rows={eventRows} />

            <h2 className="mt-8 mb-2">{t('quality.sample.recordEventTitle')}</h2>
            <SampleEventForm sampleId={id} state={s.state} labs={labOptions} locations={locationOptions}
                beforeRetention={!!s.retain_until && s.retain_until > businessToday()} canEdit={canEdit} />

            <h2 className="mt-8 mb-1">{t('quality.sample.assaysTitle')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">
                {t('quality.sample.assaysNote')}{' '}
                <Link href={newAssayHref} className="app-link hover:underline">{t('quality.sample.recordAssay')}</Link>
            </p>
            <AssaysTable rows={assayRows} empty={t('quality.sample.noAssays')} />

            <AuditTrail subject="sample" id={id} show={trailCount((await searchParams).trail)} />
        </ListPage>
    )
}
