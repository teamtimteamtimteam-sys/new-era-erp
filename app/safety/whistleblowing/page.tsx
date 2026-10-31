// app/safety/whistleblowing/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// ESG-2(Tim 2026-10-30 SYSTEM-MAP-4 Q1 · 2026-10-31 Q11 – Q14)· ESG › 举报登记簿 —— 读者读得到的每一件举报:收到的那一天、标题、来源
//   (员工在系统里交的 · 外来具名 · 外来匿名)、交的人、现在的状态;一件一页(/safety/whistleblowing/[id])追加状态。页底登记外来的举报。
// 【谁读到哪几件】只有库说了算(whistleblowing_report_rows 的行谓词 = whistleblowing_report_readable):没标「涉及 CCO」的 → 持
//   data.view_whistleblowing 的人(cco);标了的 → 只有持 data.view_whistleblowing_escalated 的人(cfo),cco 读不到(Q13)。
//   两个码都不授 admin。门 = 两个码任一(注册表)。
// 【不改、不删】状态是追加的(Q14);举报与状态都不进变更记录(交的人会作为操作人出现在那里 —— db/functions/change_log_exclusions.sql)。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { formatDate, formatDateTime } from '@/lib/dates'
import { readAll } from '@/lib/readAll'
import { ListPage } from '@/app/components/ui/list-page'
import CellsTable, { type CellRow } from '@/app/operation/equipment/CellsTable'
import { xText, xDate, xTime } from '@/lib/export/cells'
import OutsideReportForm from './OutsideReportForm'
import { wbStatusKey, wbSourceKey } from './whistleblowingTypes'

export type WbRow = {
    id: string; source: string; concerns_cco: boolean; filed_by_label: string | null; reporter_name: string | null; received_via: string | null
    received_on: string; subject: string; status: string; status_at: string; updates: number
}

export default async function WhistleblowingLogPage() {
    const denied = await requireFunction(FN.esgWhistleblowing)
    if (denied) return denied
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const [res, canPlain, canEscalated] = await Promise.all([
        readAll(() => supabase.from('whistleblowing_report_rows')
            .select('id, source, concerns_cco, filed_by_label, reporter_name, received_via, received_on, subject, status, status_at, updates')
            .order('received_on', { ascending: false }).order('id'), { label: 'whistleblowing_report_rows' }),
        can('data.view_whistleblowing'),
        can('data.view_whistleblowing_escalated'),
    ])
    const rows = mustRows(res, 'whistleblowing_report_rows') as WbRow[]
    const who = (r: WbRow) => r.source === 'in_system' ? (r.filed_by_label ?? '—')
        : r.source === 'outside_named' ? (r.reporter_name ?? '—') : t('esg.whistleblowing.anonymous')
    const open = rows.filter((r) => r.status !== 'closed').length

    const table: CellRow[] = rows.map((r) => ({
        id: r.id,
        cells: {
            received: formatDate(r.received_on, locale),
            subject: <Link href={`/safety/whistleblowing/${r.id}`} className="app-link hover:underline">{r.subject}</Link>,
            source: t(wbSourceKey(r.source)),
            who: who(r),
            concerns: r.concerns_cco ? <span className="font-medium" data-concerns-cco="1">{t('esg.whistleblowing.concernsYesShort')}</span> : t('esg.whistleblowing.concernsNoShort'),
            status: <span data-wb-status={r.status}>{t(wbStatusKey(r.status))}</span>,
            statusAt: formatDateTime(r.status_at, locale),
        },
        exports: {
            received: xDate(r.received_on), subject: xText(r.subject), source: xText(t(wbSourceKey(r.source))), who: xText(who(r)),
            concerns: xText(r.concerns_cco ? t('esg.whistleblowing.concernsYesShort') : t('esg.whistleblowing.concernsNoShort')),
            status: xText(t(wbStatusKey(r.status))), statusAt: xTime(r.status_at),
        },
    }))

    return (
        <ListPage title={t('esg.whistleblowing.title')} intro={t('esg.whistleblowing.intro')} maxWidth="max-w-6xl" state={{ kind: 'ok' }}>
            <p className="text-sm mb-3" data-wb-open={open}>{t('esg.whistleblowing.openCount', { open, total: rows.length })}</p>
            <CellsTable
                columns={[
                    { key: 'received', header: t('esg.whistleblowing.colReceived'), priority: true },
                    { key: 'subject', header: t('esg.whistleblowing.subject'), priority: true },
                    { key: 'source', header: t('esg.whistleblowing.colSource') },
                    { key: 'who', header: t('esg.whistleblowing.colWho') },
                    { key: 'concerns', header: t('esg.whistleblowing.colConcerns') },
                    { key: 'status', header: t('esg.whistleblowing.colStatus'), priority: true },
                    { key: 'statusAt', header: t('esg.whistleblowing.colStatusAt') },
                ]}
                rows={table}
                empty={t('esg.whistleblowing.none')}
                sorting="client"
                exportSpec={{ name: 'esg-whistleblowing-log', title: t('esg.whistleblowing.title') }}
            />
            <OutsideReportForm canPlain={canPlain} canEscalated={canEscalated} />
        </ListPage>
    )
}
