// app/safety/incidents/page.tsx
// MES-7b-1(2026-10-16,MES-0 Q73 · Q74 · Q76;MES-7b Step 0 Q3 · Q10 · Q11 · Q17 · Q28,Tim):事故登记簿 —— 每一件事故一行,连同它的 NEA 状态。
//   【门】requireFunction(FN.safetyIncidents) = module.safety.view。记一件要 module.safety.edit —— 缺码时画真的 <Button disabled>,
//   由 PermissionGate 点名那个码(DBLOCK-1)。V19(书面报告的工作日数)的设定面板与它的审计记录在清单上面(quality_settings 的先例)。
//   【这一页不判任何事】期限、它的状态、未确认与否全部读 incident_rows(库里的 incident_current_all 与 business_days_after),这里不算日子。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows, mustOne } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { ListPage } from '@/app/components/ui/list-page'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import IncidentsTable, { type IncidentRow } from './IncidentsTable'
import SafetySettingsPanel from './SafetySettingsPanel'
import { neaStatusLabel } from './neaStatus'

type Row = {
    id: string; code: string; kind_name_en: string; kind_name_zh: string; occurred_at: string; location_code: string | null
    equipment_code: string | null; what_happened: string; nea_reportable: boolean; notified_at: string | null
    report_submitted_at: string | null; report_deadline: string | null; deadline_state: string; deadline_confirmed: boolean
    closed_at: string | null
}

export default async function IncidentsPage({ searchParams }: { searchParams: Promise<{ trail?: string }> }) {
    const denied = await requireFunction(FN.safetyIncidents)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const [res, settingsRes, canEdit] = await Promise.all([
        supabase.from('incident_rows')
            .select('id, code, kind_name_en, kind_name_zh, occurred_at, location_code, equipment_code, what_happened, nea_reportable, notified_at, report_submitted_at, report_deadline, deadline_state, deadline_confirmed, closed_at')
            .order('occurred_at', { ascending: false }),
        supabase.from('safety_settings')
            .select('nea_report_working_days, nea_report_days_source, nea_report_days_confirmed_at').maybeSingle(),
        can('module.safety.edit'),
    ])
    const incidents = mustRows(res, 'incident_rows') as Row[]
    const settings = mustOne(settingsRes, 'safety_settings') as {
        nea_report_working_days: number | null; nea_report_days_source: string | null; nea_report_days_confirmed_at: string | null
    } | null

    const rows: IncidentRow[] = incidents.map((i) => ({
        id: i.id,
        code: i.code,
        kindLabel: locale === 'zh' ? i.kind_name_zh : i.kind_name_en,
        occurred: formatAuditStamp(i.occurred_at),
        where: [i.location_code, i.equipment_code].filter(Boolean).join(' · ') || '—',
        nea: neaStatusLabel(t, locale, i),
        neaDue: i.nea_reportable && (!i.notified_at || !i.report_submitted_at),
        closed: !!i.closed_at,
        statusLabel: i.closed_at ? t('safety.status.closed', { date: formatDate(i.closed_at, locale) }) : t('safety.status.open'),
        whatHappened: i.what_happened,
    }))

    return (
        <ListPage
            title={t('safety.incidents.title')}
            intro={t('safety.incidents.intro')}
            actions={
                canEdit ? (
                    <Button asChild><Link href="/safety/incidents/new">{t('safety.incidents.add')}</Link></Button>
                ) : (
                    <PermissionGate code="module.safety.edit" allowed={false} inline>
                        <Button disabled>{t('safety.incidents.add')}</Button>
                    </PermissionGate>
                )
            }
            notices={
                <>
                    <SafetySettingsPanel
                        days={settings?.nea_report_working_days ?? null}
                        source={settings?.nea_report_days_source ?? null}
                        confirmedAt={settings?.nea_report_days_confirmed_at ? formatDate(settings.nea_report_days_confirmed_at, locale) : null}
                        canEdit={canEdit}
                    />
                    <div className="mb-6">
                        <AuditTrail subject="safety_settings" id="true" show={trailCount((await searchParams).trail)} />
                    </div>
                </>
            }
            state={{ kind: 'ok' }}
        >
            <IncidentsTable rows={rows} empty={t('safety.incidents.empty')} />
        </ListPage>
    )
}
