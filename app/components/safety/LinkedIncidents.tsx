// app/components/safety/LinkedIncidents.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-7b-1(2026-10-16,MES-7b Step 0 Q7 · §3,Tim)· 一批(或一台机器)上的事故
// ════════════════════════════════════════════════════════════════════════════
// 【住在哪】/inbound/[id]/edit · /output/[id]/edit(这一批链在哪几件事故上,有效的与解开的)· /operation/equipment/[id](点名这台机器的事故)。
// 【谁看得见】批次:持安全查看码、或这一批自己那一页查看码的人(incident_batch_rows 的门是同一句)—— 事故编号、种类、时刻是标签,跟着链接走;
//   指向 /safety 的链接对没有安全码的人是一段字(那一页要 module.safety.view)。机器:只给持安全查看码的人;别人看见「受限」,不是一张空清单。
// 【一条链接不是一个安全状态】这里只说"链在哪件事故上",不说这一批安不安全 —— 扣没扣着是质量那一块(不合格报告)说的。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { formatAuditStamp } from '@/lib/dates'

export default async function LinkedIncidents({ kind, id }: { kind: 'inbound' | 'output' | 'machine'; id: string }) {
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const canSafety = await can('module.safety.view')
    const name = (en: string, zh: string) => (locale === 'zh' ? zh : en)
    const link = (iid: string, code: string) =>
        canSafety ? <Link href={`/safety/incidents/${iid}`} className="app-link hover:underline">{code}</Link> : <span>{code}</span>

    if (kind === 'machine') {
        if (!canSafety) {
            return (
                <section className="mt-8" data-section="machine-incidents">
                    <h2 className="mb-1">{t('safety.linked.machineTitle')}</h2>
                    <p className="text-sm">{t('common.restricted')}</p>
                </section>
            )
        }
        const rows = mustRows(await supabase.from('incident_rows').select('id, code, kind_name_en, kind_name_zh, occurred_at')
            .eq('equipment_id', id).order('occurred_at', { ascending: false }), 'incident_rows') as
            { id: string; code: string; kind_name_en: string; kind_name_zh: string; occurred_at: string }[]
        return (
            <section className="mt-8" data-section="machine-incidents">
                <h2 className="mb-1">{t('safety.linked.machineTitle')}</h2>
                {rows.length === 0 ? <p className="text-sm text-[color:var(--brand-muted-text)]">{t('safety.linked.machineNone')}</p> : (
                    <ul className="text-sm list-disc pl-5">
                        {rows.map((r) => <li key={r.id}>{link(r.id, r.code)}{` — ${name(r.kind_name_en, r.kind_name_zh)} · ${formatAuditStamp(r.occurred_at)}`}</li>)}
                    </ul>
                )}
            </section>
        )
    }

    const rows = mustRows(await supabase.from('incident_batch_rows')
        .select('id, incident_id, incident_code, kind_name_en, kind_name_zh, incident_occurred_at, active, unlink_reason')
        .eq('batch_kind', kind).eq('batch_id', id).order('id'), 'incident_batch_rows') as
        { id: number; incident_id: string; incident_code: string; kind_name_en: string; kind_name_zh: string; incident_occurred_at: string
          active: boolean; unlink_reason: string | null }[]
    return (
        <section className="mt-8" data-section="linked-incidents">
            <h2 className="mb-1">{t('safety.linked.title')}</h2>
            {rows.length === 0 ? <p className="text-sm text-[color:var(--brand-muted-text)]">{t('safety.linked.none')}</p> : (
                <ul className="text-sm list-disc pl-5">
                    {rows.map((r) => (
                        <li key={r.id} className={r.active ? '' : 'text-[color:var(--brand-muted-text)]'}>
                            {link(r.incident_id, r.incident_code)}
                            {` — ${name(r.kind_name_en, r.kind_name_zh)} · ${formatAuditStamp(r.incident_occurred_at)}`}
                            {!r.active && ` · ${t('safety.batches.unlinked', { date: '', reason: r.unlink_reason ?? '' })}`}
                        </li>
                    ))}
                </ul>
            )}
        </section>
    )
}
