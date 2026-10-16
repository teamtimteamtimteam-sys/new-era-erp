// app/safety/incidents/new/page.tsx
// MES-7b-1(2026-10-16,MES-0 Q73 · Q76;MES-7b Step 0 Q3 · Q5 · Q6 · Q9 · Q10 · Q28,Tim):记一件事故。
//   【门】requireFunction(FN.safetyIncidents) = module.safety.view;记要 module.safety.edit(表单在 PermissionGate 里)。
//   清单都从库里读:种类(启用的)、库位、机器(equipment_usage 里设备类的)、人(incident_people)、最近的停机与异常事件(可选的引用)。
//   读不到的那几样(没有加工查看码的人读不到机器、停机与事件)说「受限」,不是一个空下拉。
//   受伤的细节谁都记得进去;读回来只给 data.view_health 与受伤的那名员工本人 —— 表单上直说(Q6)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { formatAuditStamp } from '@/lib/dates'
import IncidentForm, { type Opt } from './IncidentForm'

export default async function NewIncidentPage() {
    const denied = await requireFunction(FN.safetyIncidents)
    if (denied) return denied
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const [canEdit, canProcessing] = await Promise.all([can('module.safety.edit'), can('module.processing.view')])
    const [kindsRes, locRes, peopleRes, eqRes, dtRes, evRes] = await Promise.all([
        supabase.from('incident_kinds').select('code, name_en, name_zh').eq('is_active', true).order('sort_order'),
        supabase.from('storage_locations').select('id, code, name').eq('is_active', true).order('code'),
        supabase.from('incident_people').select('id, code, preferred_name').order('code'),
        canProcessing ? supabase.from('equipment_usage').select('equipment_id, equipment_code, equipment_description')
            .eq('equipment_category', 'equipment').order('equipment_code') : null,
        canProcessing ? supabase.from('equipment_downtime').select('id, equipment_id, started_at, reason')
            .is('voided_at', null).order('started_at', { ascending: false }).limit(100) : null,
        canProcessing ? supabase.from('processing_run_events').select('id, run_id, event_type_code, occurred_at, action_taken')
            .eq('withdrawn', false).order('occurred_at', { ascending: false }).limit(100) : null,
    ])
    const kinds: Opt[] = (mustRows(kindsRes, 'incident_kinds') as { code: string; name_en: string; name_zh: string }[])
        .map((k) => ({ id: k.code, label: locale === 'zh' ? k.name_zh : k.name_en }))
    const locations: Opt[] = (mustRows(locRes, 'storage_locations') as { id: string; code: string; name: string }[])
        .map((l) => ({ id: l.id, label: `${l.code} · ${l.name}` }))
    const people: Opt[] = (mustRows(peopleRes, 'incident_people') as { id: string; code: string; preferred_name: string | null }[])
        .map((p) => ({ id: p.id, label: p.preferred_name ? `${p.code} · ${p.preferred_name}` : p.code }))
    const machines: Opt[] = eqRes ? (mustRows(eqRes, 'equipment_usage') as { equipment_id: string; equipment_code: string; equipment_description: string | null }[])
        .map((m) => ({ id: m.equipment_id, label: m.equipment_description ? `${m.equipment_code} · ${m.equipment_description}` : m.equipment_code })) : []
    const downtime = dtRes ? (mustRows(dtRes, 'equipment_downtime') as { id: string; equipment_id: string; started_at: string; reason: string }[])
        .map((d) => ({ id: d.id, machineId: d.equipment_id, label: `${formatAuditStamp(d.started_at)} · ${d.reason}` })) : []
    const evRows = evRes ? mustRows(evRes, 'processing_run_events') as { id: number; run_id: string; event_type_code: string; occurred_at: string; action_taken: string }[] : []
    // 一条事件已经被另一行更正 / 撤回时,说话的是那一行(守卫按名拒引用被取代的那一条)—— 这里只列此刻说话的那几行
    const supersededRes = evRows.length === 0 ? null : await supabase.from('processing_run_events').select('corrects_id').in('corrects_id', evRows.map((e) => e.id))
    const superseded = new Set((supersededRes ? mustRows(supersededRes, 'processing_run_events') as { corrects_id: number }[] : []).map((r) => r.corrects_id))
    const runIds = [...new Set(evRows.map((e) => e.run_id))]
    const runRes = runIds.length === 0 ? null : await supabase.from('processing_runs_masked').select('id, code').in('id', runIds)
    const runCode = new Map((runRes ? mustRows(runRes, 'processing_runs_masked') as { id: string; code: string }[] : []).map((r) => [r.id, r.code]))
    const events: Opt[] = evRows.filter((e) => !superseded.has(e.id))
        .map((e) => ({ id: String(e.id), label: `${runCode.get(e.run_id) ?? '—'} · ${formatAuditStamp(e.occurred_at)} · ${e.action_taken}` }))

    return (
        <ListPage
            maxWidth="max-w-4xl"
            breadcrumb={<Link href="/safety/incidents" className="hover:underline text-sm app-link">{t('common.back')}</Link>}
            title={t('safety.incidents.newTitle')}
            intro={t('safety.incidents.newIntro')}
            state={{ kind: 'ok' }}
        >
            <IncidentForm kinds={kinds} locations={locations} people={people} machines={machines} downtime={downtime} events={events}
                          processingRestricted={!canProcessing} canEdit={canEdit} />
        </ListPage>
    )
}
