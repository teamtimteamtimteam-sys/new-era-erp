// app/safety/inspections/new/page.tsx
// MES-7b-2(2026-10-16,MES-0 Q72;MES-7b Step 0 Q13 · Q14,Tim):交一次巡检 —— 照 ?template=<清单> 的检查项(此刻的字;交下去那一刻抄进结果);
//   ?corrects=<巡检> 时这一次是对那一次的更正(引用它、要理由;那一次已经被更正过时这一页照直说)。
//   【门】requireFunction(FN.safetyInspections) = module.safety.view;交要 module.safety.edit(表单在 PermissionGate 里)。
//   机器的选项读设备(module.processing.view);读不到时那一格说「受限」。人选框读 incident_people(安全查看码的名单)。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import RunForm from '../RunForm'
import { readAll } from '@/lib/readAll'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const one = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v) ?? ''
type Corrected = { id: string; code: string; template_id: string; corrected_by_run_code: string | null }

export default async function NewRunPage({ searchParams }: { searchParams: Promise<{ template?: string | string[]; corrects?: string | string[] }> }) {
    const denied = await requireFunction(FN.safetyInspections)
    if (denied) return denied
    const t = await getTranslations()
    const sp = await searchParams
    const supabase = await createClient()
    const back = <Link href="/safety/inspections" className="hover:underline text-sm app-link">{t('common.back')}</Link>

    // 更正:从被更正的那一次取它的清单(更正照同一张清单的此刻的样子记)
    const correctsId = one(sp.corrects)
    let corrects: Corrected | null = null
    if (correctsId) {
        if (!UUID.test(correctsId)) notFound()
        corrects = mustOne(await supabase.from('inspection_run_rows').select('id, code, template_id, corrected_by_run_code').eq('id', correctsId).maybeSingle(),
            'inspection_run_rows') as Corrected | null
        if (!corrects) notFound()
    }
    const templateId = corrects?.template_id ?? one(sp.template)
    if (!UUID.test(templateId)) {
        return (
            <ListPage maxWidth="max-w-4xl" breadcrumb={back} title={t('safety.runForm.title')} state={{ kind: 'ok' }}>
                <p className="text-sm">{t('safety.runForm.pickTemplateFirst')}</p>
            </ListPage>
        )
    }
    const tpl = mustOne(await supabase.from('inspection_template_rows').select('id, code, name, area, is_active').eq('id', templateId).maybeSingle(),
        'inspection_template_rows') as { id: string; code: string; name: string; area: string; is_active: boolean } | null
    if (!tpl) notFound()

    const [canEdit, canProcessing] = await Promise.all([can('module.safety.edit'), can('module.processing.view')])
    const [itemsRes, peopleRes, locRes, eqRes] = await Promise.all([
        supabase.from('inspection_template_items').select('position, item_text').eq('template_id', templateId).order('position'),
        supabase.from('incident_people').select('id, code, preferred_name').order('code'),
        supabase.from('storage_locations').select('id, code, name').eq('is_active', true).order('code'),
        canProcessing ? readAll(() => supabase.from('equipment_usage').select('equipment_id, equipment_code, equipment_description')
            .eq('equipment_category', 'equipment').order('equipment_code'), { label: 'equipment_usage', key: ['equipment_id', 'equipment_code', 'equipment_description', 'acquisition_date', 'in_service_date', 'equipment_status', 'run_count', 'input_kg', 'output_kg', 'loss_kg', 'first_run_date', 'last_run_date', 'equipment_category'] }) : null,
    ])
    const items = (mustRows(itemsRes, 'inspection_template_items') as { position: number; item_text: string }[]).map((x) => ({ position: x.position, text: x.item_text }))
    const people = (mustRows(peopleRes, 'incident_people') as { id: string; code: string; preferred_name: string | null }[])
        .map((p) => ({ id: p.id, label: p.preferred_name ? `${p.code} · ${p.preferred_name}` : p.code }))
    const locations = (mustRows(locRes, 'storage_locations') as { id: string; code: string; name: string }[]).map((l) => ({ id: l.id, label: `${l.code} · ${l.name}` }))
    const machines = eqRes ? (mustRows(eqRes, 'equipment_usage') as { equipment_id: string; equipment_code: string; equipment_description: string | null }[])
        .map((m) => ({ id: m.equipment_id, label: m.equipment_description ? `${m.equipment_code} · ${m.equipment_description}` : m.equipment_code })) : []

    const blocked = !tpl.is_active ? t('safety.runForm.templateInactive', { code: tpl.code })
        : corrects?.corrected_by_run_code ? t('safety.runForm.alreadyCorrected', { code: corrects.code, by: corrects.corrected_by_run_code })
        : items.length === 0 ? t('safety.runForm.noItems') : null

    return (
        <ListPage
            maxWidth="max-w-4xl"
            breadcrumb={back}
            title={corrects ? t('safety.runForm.correctTitle', { code: corrects.code }) : t('safety.runForm.title')}
            intro={<>{t('safety.runForm.intro')}{' '}<Link href={`/safety/inspections/templates/${tpl.id}`} className="app-link hover:underline">{`${tpl.code} · ${tpl.name}`}</Link>{` · ${tpl.area}`}</>}
            state={{ kind: 'ok' }}
        >
            {blocked ? <p className="text-sm text-amber-800" data-notice="run-blocked">{blocked}</p> : (
                <RunForm templateId={tpl.id} items={items} people={people} locations={locations} machines={machines}
                         processingRestricted={!canProcessing} correctsRunId={corrects?.id ?? null} correctsRunCode={corrects?.code ?? null} canEdit={canEdit} />
            )}
        </ListPage>
    )
}
