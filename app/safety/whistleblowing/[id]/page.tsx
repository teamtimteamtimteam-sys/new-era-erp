// app/safety/whistleblowing/[id]/page.tsx
// ESG-2(Tim 2026-10-31 Q11 – Q14):一件举报 —— 收到的那一天、来源、交的人(系统里交的)或外来的举报人(匿名来源就写匿名来源)、
//   收到的方式、标题与内容、有没有标「涉及 CCO」;它之后的每一个状态(谁、何时、说明);没结案时追加一个状态。
//   【读得到才打开】whistleblowing_report_rows 的行谓词(whistleblowing_report_readable)说了算:读不到的人得到 404 —— 不告诉他那一件存不存在。
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { formatDate, formatDateTime } from '@/lib/dates'
import { loadActorNames } from '@/app/components/ActorName'
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import CellsTable, { type CellRow } from '@/app/operation/equipment/CellsTable'
import { xText, xTime } from '@/lib/export/cells'
import ReportUpdateForm from './ReportUpdateForm'
import { wbStatusKey, wbSourceKey, wbViaKey } from '../whistleblowingTypes'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export default async function WhistleblowingReportPage({ params }: { params: Promise<{ id: string }> }) {
    const denied = await requireFunction(FN.esgWhistleblowing)
    if (denied) return denied
    const { id } = await params
    if (!UUID.test(id)) notFound()
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const r = mustOne(await supabase.from('whistleblowing_report_rows')
        .select('id, source, concerns_cco, filed_by_label, reporter_name, received_via, received_on, subject, details, status, status_at, recorded_at, recorded_by')
        .eq('id', id).maybeSingle(), 'whistleblowing_report_rows') as {
        id: string; source: string; concerns_cco: boolean; filed_by_label: string | null; reporter_name: string | null; received_via: string | null
        received_on: string; subject: string; details: string; status: string; status_at: string; recorded_at: string; recorded_by: string
    } | null
    if (!r) notFound()
    const updRes = await supabase.from('whistleblowing_updates').select('id, status, note, recorded_at, recorded_by').eq('report_id', id).order('id')   // unpaged-ok: 一件举报的状态,至多几条
    const updates = mustRows(updRes, 'whistleblowing_updates') as { id: number; status: string; note: string; recorded_at: string; recorded_by: string }[]
    const names = await loadActorNames(supabase, [r.recorded_by, ...updates.map((u) => u.recorded_by)])
    const who = (u: string | null) => (u && names.names.get(u)) || (names.restricted ? t('common.restricted') : t('esg.someone'))
    const reporter = r.source === 'in_system' ? (r.filed_by_label ?? '—') : r.source === 'outside_named' ? (r.reporter_name ?? '—') : t('esg.whistleblowing.anonymous')

    const rows: CellRow[] = updates.map((u) => ({
        id: String(u.id),
        cells: { status: t(wbStatusKey(u.status)), at: formatDateTime(u.recorded_at, locale), by: who(u.recorded_by), note: <span className="whitespace-pre-wrap">{u.note}</span> },
        exports: { status: xText(t(wbStatusKey(u.status))), at: xTime(u.recorded_at), by: xText(who(u.recorded_by)), note: xText(u.note) },
    }))

    return (
        <ListPage maxWidth="max-w-5xl" title={<span>{r.subject}</span>} intro={t('esg.whistleblowing.reportIntro')} state={{ kind: 'ok' }}>
            <RecordHeader fields={[
                { label: t('esg.whistleblowing.colReceived'), value: formatDate(r.received_on, locale) },
                { label: t('esg.whistleblowing.colSource'), value: t(wbSourceKey(r.source)) },
                { label: t('esg.whistleblowing.colWho'), value: reporter },
                { label: t('esg.whistleblowing.receivedVia'), value: r.received_via ? t(wbViaKey(r.received_via)) : '—' },
                { label: t('esg.whistleblowing.colConcerns'), value: r.concerns_cco ? t('esg.whistleblowing.concernsYesShort') : t('esg.whistleblowing.concernsNoShort') },
                { label: t('esg.whistleblowing.colStatus'), value: t(wbStatusKey(r.status)) },
                { label: t('esg.whistleblowing.recordedBy'), value: `${who(r.recorded_by)} · ${formatDateTime(r.recorded_at, locale)}` },
            ]} />
            <h2 className="mt-6 mb-1">{t('esg.whistleblowing.details')}</h2>
            <p className="text-sm whitespace-pre-wrap break-words" data-wb-details="1">{r.details}</p>
            <h2 className="mt-6 mb-2">{t('esg.whistleblowing.updatesTitle')}</h2>
            <CellsTable
                columns={[
                    { key: 'status', header: t('esg.whistleblowing.colStatus'), priority: true },
                    { key: 'at', header: t('esg.whistleblowing.colStatusAt'), priority: true },
                    { key: 'by', header: t('esg.whistleblowing.colBy') },
                    { key: 'note', header: t('esg.whistleblowing.note') },
                ]}
                rows={rows}
                empty={t('esg.whistleblowing.updatesNone')}
                sorting="client"
                exportSpec={{ name: 'esg-whistleblowing-report', title: r.subject }}
            />
            {r.status === 'closed'
                ? <p className="text-sm mt-4 text-[color:var(--brand-muted-text)]" data-wb-closed="1">{t('esg.whistleblowing.closedNote')}</p>
                : <ReportUpdateForm reportId={r.id} />}
        </ListPage>
    )
}
