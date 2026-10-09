// app/operation/blending/page.tsx
// MES-5b-3(2026-10-09,MES-5b Step 0 Q17–Q20,Tim):配料计划列表(将来那条线 —— Q16:今天这条线不配料)。
//   【门】requireFunction(FN.blending) = module.processing.view(计划三张表的读策略同一个码)。
//   新建的入口归 action.wo_create —— 缺码时画真的 <Button disabled>,由 PermissionGate 点名那个码(DBLOCK-1)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { ListPage } from '@/app/components/ui/list-page'
import { formatDate } from '@/lib/dates'
import { blendingStatusKey } from './blendingTypes'
import BlendingPlansTable, { type BlendingPlanRow } from './BlendingPlansTable'

export default async function BlendingPlansPage() {
    const denied = await requireFunction(FN.blending)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const plans = mustRows(
        await supabase.from('blending_plans')
            .select('id, code, status, output_material_id, notes, created_at, run_id')
            .order('created_at', { ascending: false }),
        'blending_plans') as { id: string; code: string; status: string; output_material_id: string
                                notes: string | null; created_at: string; run_id: string | null }[]

    // 物料与那一炉:只取名字与编号(查名视图 / 加工单 —— 读计划的人本来就读得到这两样)
    const matIds = [...new Set(plans.map((p) => p.output_material_id))]
    const runIds = plans.map((p) => p.run_id).filter((x): x is string => !!x)
    const materials = matIds.length === 0 ? [] : mustRows(
        await supabase.from('material_lookup').select('id, code, name').in('id', matIds), 'material_lookup') as
        { id: string; code: string; name: string }[]
    const runs = runIds.length === 0 ? [] : mustRows(
        await supabase.from('processing_runs_masked').select('id, code').in('id', runIds), 'processing_runs_masked') as { id: string; code: string }[]
    const matOf = new Map(materials.map((m) => [m.id, `${m.code} — ${m.name}`]))
    const runOf = new Map(runs.map((r) => [r.id, r]))
    const canCreate = await can('action.wo_create')

    const rows: BlendingPlanRow[] = plans.map((p) => ({
        id: p.id,
        code: p.code,
        statusLabel: t(blendingStatusKey(p.status)),
        material: matOf.get(p.output_material_id) ?? '—',
        createdLabel: formatDate(p.created_at.slice(0, 10), locale) ?? '—',
        run: p.run_id ? runOf.get(p.run_id) ?? null : null,
        notes: p.notes ?? '—',
    }))

    return (
        <ListPage
            title={t('blending.listTitle')}
            intro={t('blending.listNote')}
            actions={
                canCreate ? (
                    <Button asChild><Link href="/operation/blending/new">{t('blending.addButton')}</Link></Button>
                ) : (
                    <PermissionGate code="action.wo_create" allowed={false} inline>
                        <Button disabled>{t('blending.addButton')}</Button>
                    </PermissionGate>
                )
            }
            state={{ kind: 'ok' }}
        >
            <BlendingPlansTable rows={rows} empty={t('blending.empty')} />
        </ListPage>
    )
}
