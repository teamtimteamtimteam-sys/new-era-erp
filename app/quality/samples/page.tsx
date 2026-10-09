// app/quality/samples/page.tsx
// MES-6a-1(2026-10-09,MES-6a Step 0 Q7–Q15,Tim):样品清单 —— 每一份样品此刻谁拿着、在哪、留到哪一天。
//   【门】requireFunction(FN.qualitySamples) = module.quality.view。取样要 module.quality.edit —— 缺码时画真的 <Button disabled>,
//   由 PermissionGate 点名那个码(DBLOCK-1)。
//   【这一页不判任何事】状态、实验室、库位、留样日到期与提前处置全部读 sample_rows(从最近那一条保管记录读)。
//   V16 那块面板与它自己的审计记录在 notices 里:一份样品都没有的时候照样要能设。
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
import { formatDate } from '@/lib/dates'
import { sampleKindKey, sampleStateKey, batchHref } from '../qualityTypes'
import SamplesTable, { type SampleRow } from './SamplesTable'
import QualitySettingsPanel from './QualitySettingsPanel'

type Row = {
    id: string; code: string; kind: string; state: string; batch_kind: string; inbound_batch_id: string | null; output_batch_id: string | null
    batch_code: string; taken_on: string; retain_until: string | null; retain_until_source: string; laboratory_code: string | null
    storage_location_code: string | null; disposed_at: string | null; disposed_early: boolean | null; retention_due: boolean | null
}

export default async function SamplesPage({ searchParams }: { searchParams: Promise<{ trail?: string }> }) {
    const denied = await requireFunction(FN.qualitySamples)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const [samplesRes, settingsRes, canEdit] = await Promise.all([
        supabase.from('sample_rows')
            .select('id, code, kind, state, batch_kind, inbound_batch_id, output_batch_id, batch_code, taken_on, retain_until, retain_until_source, laboratory_code, storage_location_code, disposed_at, disposed_early, retention_due')
            .order('created_at', { ascending: false }),
        supabase.from('quality_settings').select('internal_retention_days').maybeSingle(),
        can('module.quality.edit'),
    ])
    const samples = mustRows(samplesRes, 'sample_rows') as Row[]
    const settings = mustOne(settingsRes, 'quality_settings') as { internal_retention_days: number | null } | null

    const rows: SampleRow[] = samples.map((s) => ({
        id: s.id,
        code: s.code,
        kindLabel: t(sampleKindKey(s.kind)),
        batchCode: s.batch_code,
        batchHref: batchHref(s.batch_kind, (s.inbound_batch_id ?? s.output_batch_id)!),
        stateLabel: t(sampleStateKey(s.state)),
        where: s.state === 'at_lab' ? (s.laboratory_code ?? '—')
            : s.state === 'disposed' ? (formatDate(s.disposed_at, locale) || '—')
            : (s.storage_location_code ?? t('quality.noLocation')),
        takenLabel: formatDate(s.taken_on, locale) || '—',
        keepUntil: s.retain_until ? formatDate(s.retain_until, locale) || '—' : t('quality.notYetSet'),
        flag: s.retention_due ? 'due' : s.disposed_early ? 'early' : null,
    }))

    return (
        <ListPage
            title={t('quality.samples.title')}
            intro={t('quality.samples.intro')}
            actions={
                canEdit ? (
                    <Button asChild><Link href="/quality/samples/new">{t('quality.samples.add')}</Link></Button>
                ) : (
                    <PermissionGate code="module.quality.edit" allowed={false} inline>
                        <Button disabled>{t('quality.samples.add')}</Button>
                    </PermissionGate>
                )
            }
            notices={
                <>
                    <QualitySettingsPanel days={settings?.internal_retention_days ?? null} canEdit={canEdit} />
                    <div className="mb-6">
                        <AuditTrail subject="quality_settings" id="true" show={trailCount((await searchParams).trail)} />
                    </div>
                </>
            }
            state={{ kind: 'ok' }}
        >
            <SamplesTable rows={rows} empty={t('quality.samples.empty')} />
        </ListPage>
    )
}
