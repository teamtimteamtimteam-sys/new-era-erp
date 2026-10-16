// app/safety/inspections/templates/[id]/page.tsx
// MES-7b-2(2026-10-16,MES-0 Q72;MES-7b Step 0 Q13 · Q20,Tim):一张巡检清单 —— 改它(代号、名字、片区、频率 V18、检查项、启用)、
//   照它记一次巡检、看照它巡过的每一次,以及它的审计记录(主语 inspection_template:清单与检查项)。
//   【门】requireFunction(FN.safetyInspections) = module.safety.view;改与记一次巡检要 module.safety.edit —— 控件看得见、按不动、说出码。
//   到期的状态读 inspection_template_rows(一份实现),这里不数日子。
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
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import { dueStateKey } from '../../../safetyTypes'
import TemplateForm from '../../TemplateForm'
import { RunsTable, type RunRow } from '../../InspectionTables'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export default async function TemplatePage({ params, searchParams }: {
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

    const tpl = mustOne(await supabase.from('inspection_template_rows')
        .select('id, code, name, area, frequency_days, is_active, notes, item_count, run_count, last_inspected_at, next_due_on, due_state')
        .eq('id', id).maybeSingle(), 'inspection_template_rows') as {
        id: string; code: string; name: string; area: string; frequency_days: number | null; is_active: boolean; notes: string | null
        item_count: number; run_count: number; last_inspected_at: string | null; next_due_on: string | null; due_state: string
    } | null
    if (!tpl) notFound()
    const [itemsRes, runsRes, canEdit] = await Promise.all([
        supabase.from('inspection_template_items').select('position, item_text').eq('template_id', id).order('position'),
        supabase.from('inspection_run_rows')
            .select('id, code, template_code, template_name, inspected_at, inspector_label, pass_count, fail_count, na_count, finding_count, open_finding_count, corrected_by_run_code')
            .eq('template_id', id).order('inspected_at', { ascending: false }),
        can('module.safety.edit'),
    ])
    const items = (mustRows(itemsRes, 'inspection_template_items') as { position: number; item_text: string }[]).map((x) => x.item_text)
    const runs: RunRow[] = (mustRows(runsRes, 'inspection_run_rows') as {
        id: string; code: string; template_code: string; template_name: string; inspected_at: string; inspector_label: string; pass_count: number
        fail_count: number; na_count: number; finding_count: number; open_finding_count: number; corrected_by_run_code: string | null }[]).map((r) => ({
        id: r.id, code: r.code, checklist: `${r.template_code} · ${r.template_name}`, inspected: formatAuditStamp(r.inspected_at), inspector: r.inspector_label,
        counts: t('safety.inspections.counts', { pass: String(r.pass_count), fail: String(r.fail_count), na: String(r.na_count) }),
        findings: r.finding_count === 0 ? '—' : t('safety.inspections.findingsCount', { n: String(r.finding_count), open: String(r.open_finding_count) }),
        openFindings: r.open_finding_count > 0,
        corrected: r.corrected_by_run_code ? t('safety.inspections.correctedBy', { code: r.corrected_by_run_code }) : null,
    }))
    const due = tpl.due_state === 'not_due' && tpl.next_due_on ? t('safety.inspections.nextDue', { date: formatDate(tpl.next_due_on, locale) })
        : tpl.due_state === 'due' && tpl.next_due_on ? t('safety.inspections.dueSince', { date: formatDate(tpl.next_due_on, locale) })
        : t(dueStateKey(tpl.due_state))
    // 记一次巡检:有码、清单启用 → 一个链接;没有码 → 按不动、点名码;清单停用 → 按不动、下面一句说为什么
    const record = canEdit && tpl.is_active
        ? <Button asChild><Link href={`/safety/inspections/new?template=${id}`}>{t('safety.templates.recordRun')}</Link></Button>
        : !canEdit
            ? <PermissionGate code="module.safety.edit" allowed={false} inline><Button disabled>{t('safety.templates.recordRun')}</Button></PermissionGate>
            : <Button disabled>{t('safety.templates.recordRun')}</Button>

    return (
        <ListPage
            maxWidth="max-w-5xl"
            breadcrumb={<Link href="/safety/inspections" className="hover:underline text-sm app-link">{t('common.back')}</Link>}
            title={<span>{`${tpl.code} · ${tpl.name}`}</span>}
            actions={record}
            state={{ kind: 'ok' }}
        >
            <RecordHeader fields={[
                { label: t('safety.templates.area'), value: tpl.area },
                { label: t('safety.templates.frequency'), value: tpl.frequency_days == null ? t('safety.inspections.notSet') : t('safety.inspections.everyDays', { n: String(tpl.frequency_days) }) },
                { label: t('safety.templates.lastRun'), value: tpl.last_inspected_at ? formatAuditStamp(tpl.last_inspected_at) : '—' },
                { label: t('safety.templates.due'), value: <span data-value="due">{due}</span> },
                { label: t('safety.templates.active'), value: tpl.is_active ? t('common.yes') : t('safety.templates.inactive') },
            ]} />
            {!tpl.is_active && <p className="text-xs text-[color:var(--brand-muted-text)] mt-2">{t('safety.templates.inactiveHint')}</p>}

            <section className="mt-8" data-section="edit">
                <h2 className="mb-2">{t('safety.templates.editTitle')}</h2>
                <TemplateForm init={{ id, code: tpl.code, name: tpl.name, area: tpl.area, frequencyDays: tpl.frequency_days == null ? '' : String(tpl.frequency_days),
                                      isActive: tpl.is_active, notes: tpl.notes ?? '', items }}
                              canEdit={canEdit} hasRuns={tpl.run_count > 0} />
            </section>

            <section className="mt-8" data-section="runs">
                <h2 className="mb-1">{t('safety.templates.runsTitle')}</h2>
                <RunsTable rows={runs} empty={t('safety.templates.noRuns')} />
            </section>

            <AuditTrail subject="inspection_template" id={id} show={trailCount((await searchParams).trail)} />
        </ListPage>
    )
}
