// app/quality/samples/new/page.tsx
// MES-6a-1(MES-6a Step 0 Q7–Q10):取一份样品。两步:先选一批(?batch=inbound:<id> / output:<id>;批次页上的入口直接带着它),
//   再按那一批取它自己的清单 —— 库位、(产出批)销售单、(产出批)取过样的交叉污染抽检。
//   【门】requireFunction(FN.qualitySamples) = module.quality.view;存要 module.quality.edit(表单在 PermissionGate 里)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { formatDate } from '@/lib/dates'
import { parseBatchRef, batchHref } from '../../qualityTypes'
import { loadBatchOptions, loadBatchCode } from '../batchOptions'
import BatchPicker from '../BatchPicker'
import SampleForm, { type Option } from '../SampleForm'

export default async function NewSamplePage({ searchParams }: { searchParams: Promise<{ batch?: string | string[] }> }) {
    const denied = await requireFunction(FN.qualitySamples)
    if (denied) return denied
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const ref = parseBatchRef((await searchParams).batch)
    const back = <Link href="/quality/samples" className="hover:underline text-sm app-link">{t('common.back')}</Link>

    if (!ref) {
        const o = await loadBatchOptions(supabase)
        return (
            <ListPage maxWidth="max-w-4xl" breadcrumb={back} title={t('quality.samples.newTitle')} intro={t('quality.samples.pickBatchIntro')} state={{ kind: 'ok' }}>
                <BatchPicker action="/quality/samples/new" inbound={o.inbound} output={o.output} inboundVisible={o.canIn} outputVisible={o.canOut} />
            </ListPage>
        )
    }

    const code = await loadBatchCode(supabase, ref)
    if (!code) {
        return (
            <ListPage maxWidth="max-w-4xl" breadcrumb={back} title={t('quality.samples.newTitle')} state={{ kind: 'ok' }}>
                <p className="text-sm text-amber-700">{t('quality.form.batchNotReadable')}</p>
            </ListPage>
        )
    }

    const [locRes, soRes, checkRes, canEdit] = await Promise.all([
        supabase.from('storage_locations').select('id, code, name').eq('is_active', true).order('code'),
        ref.kind === 'output'
            ? supabase.from('sales_orders').select('id, code').is('deleted_at', null).neq('status', 'cancelled').order('created_at', { ascending: false }).limit(200)
            : null,
        ref.kind === 'output'
            ? supabase.from('contamination_checks').select('id, stream_code, sampled_at, rate_pct').eq('output_batch_id', ref.id).eq('kind', 'sampled').order('id', { ascending: false })
            : null,
        can('module.quality.edit'),
    ])
    const locations: Option[] = (mustRows(locRes, 'storage_locations') as { id: string; code: string; name: string }[])
        .map((l) => ({ id: l.id, label: `${l.code} — ${l.name}` }))
    const salesOrders: Option[] = soRes ? (mustRows(soRes, 'sales_orders') as { id: string; code: string }[]).map((s) => ({ id: s.id, label: s.code })) : []
    const checks: Option[] = checkRes
        ? (mustRows(checkRes, 'contamination_checks') as { id: number; stream_code: string; sampled_at: string | null; rate_pct: number | null }[])
            .map((c) => ({ id: String(c.id), label: `#${c.id} · ${c.stream_code} · ${formatDate(c.sampled_at, locale)}${c.rate_pct == null ? '' : ` · ${Number(c.rate_pct).toFixed(2)} %`}` }))
        : []

    return (
        <ListPage
            maxWidth="max-w-4xl"
            breadcrumb={back}
            title={t('quality.samples.newTitle')}
            intro={<>{t('quality.samples.newFor')}{' '}<Link href={batchHref(ref.kind, ref.id)} className="app-link hover:underline">{code}</Link></>}
            state={{ kind: 'ok' }}
        >
            <SampleForm batchKind={ref.kind} batchId={ref.id} locations={locations} salesOrders={salesOrders} checks={checks} canEdit={canEdit} />
        </ListPage>
    )
}
