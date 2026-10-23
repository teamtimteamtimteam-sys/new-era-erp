// app/safety/inspections/page.tsx
// MES-7b-2(2026-10-16,MES-0 Q72;MES-7b Step 0 Q13 · Q14 · Q17 · Q20,Tim):安全巡检 —— 巡检清单(频率 V18、到期与否)与每一次巡检
//   (INS-…,合格 / 不合格 / 不适用各几项、发现还开着几条、被哪一次更正)。
//   【门】requireFunction(FN.safetyInspections) = module.safety.view。建清单要 module.safety.edit —— 缺码时画真的 <Button disabled>,
//   由 PermissionGate 点名那个码(DBLOCK-1)。一张清单都不引导(Q13 / V18):清单是安全工程公司给的,空着时这一页照直说。
//   【这一页不判任何事】到期的状态读 inspection_template_rows(库里的 inspection_template_due_all),这里不数日子。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows, mustCount } from '@/lib/db-helpers'
import { RowCapNotice } from '@/app/components/ui/row-cap-notice'
import { RUNS_SHOWN, runsCount, runsPage, shapeRunRows } from './runRows'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { ListPage } from '@/app/components/ui/list-page'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import { dueStateKey } from '../safetyTypes'
import { TemplatesTable, RunsTable, type TemplateRow, type RunRow } from './InspectionTables'

type T = {
    id: string; code: string; name: string; area: string; frequency_days: number | null; is_active: boolean; item_count: number
    last_inspected_at: string | null; next_due_on: string | null; due_state: string
}

export default async function InspectionsPage() {
    const denied = await requireFunction(FN.safetyInspections)
    if (denied) return denied
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    // ★ TABLE-EXPORT-2b-1(Tim Q2):巡检记录的读取与映射搬进 runRows.ts,与导出路由共用;只画最近 RUNS_SHOWN 次,而且说出来。
    const [tplRes, runRes, runTotalRes, canEdit] = await Promise.all([
        supabase.from('inspection_template_rows')
            .select('id, code, name, area, frequency_days, is_active, item_count, last_inspected_at, next_due_on, due_state')
            .order('is_active', { ascending: false }).order('code'),
        runsPage(supabase, 0, RUNS_SHOWN - 1),
        runsCount(supabase),
        can('module.safety.edit'),
    ])
    const templates = mustRows(tplRes, 'inspection_template_rows') as T[]
    const runs = mustRows(runRes, 'inspection_run_rows')
    const runTotal = mustCount(runTotalRes, 'inspection_run_rows count')

    const tplRows: TemplateRow[] = templates.map((x) => ({
        id: x.id, code: x.code, name: x.name, area: x.area,
        frequency: x.frequency_days == null ? t('safety.inspections.notSet') : t('safety.inspections.everyDays', { n: String(x.frequency_days) }),
        items: x.item_count,
        lastRun: x.last_inspected_at ? formatAuditStamp(x.last_inspected_at) : '—',
        due: x.due_state === 'not_due' && x.next_due_on ? t('safety.inspections.nextDue', { date: formatDate(x.next_due_on, locale) })
            : x.due_state === 'due' && x.next_due_on ? t('safety.inspections.dueSince', { date: formatDate(x.next_due_on, locale) })
            : t(dueStateKey(x.due_state)),
        dueFlag: x.is_active && (x.due_state === 'due' || x.due_state === 'never_run'),
        active: x.is_active,
        lastRunAt: x.last_inspected_at,
    }))
    const runRows: RunRow[] = await shapeRunRows(runs)

    return (
        <ListPage
            title={t('safety.inspections.title')}
            intro={t('safety.inspections.intro')}
            actions={
                canEdit ? (
                    <Button asChild><Link href="/safety/inspections/templates/new">{t('safety.inspections.addTemplate')}</Link></Button>
                ) : (
                    <PermissionGate code="module.safety.edit" allowed={false} inline>
                        <Button disabled>{t('safety.inspections.addTemplate')}</Button>
                    </PermissionGate>
                )
            }
            state={{ kind: 'ok' }}
        >
            <section data-section="templates">
                <h2 className="mb-1">{t('safety.inspections.templatesTitle')}</h2>
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('safety.inspections.templatesHint')}</p>
                <TemplatesTable rows={tplRows} empty={t('safety.inspections.noTemplates')} />
            </section>
            <section className="mt-8" data-section="runs">
                <h2 className="mb-1">{t('safety.inspections.runsTitle')}</h2>
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('safety.inspections.runsHint')}</p>
                <RowCapNotice shown={runRows.length} total={runTotal} />
                <RunsTable rows={runRows} empty={t('safety.inspections.noRuns')} serverRows="/safety/inspections/runs/export" />
            </section>
        </ListPage>
    )
}
