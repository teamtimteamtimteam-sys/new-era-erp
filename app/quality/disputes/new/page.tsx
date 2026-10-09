// app/quality/disputes/new/page.tsx
// MES-6a-1(MES-6a Step 0 Q16 · Q17):立一件化验争议。两步:先选一批(?batch=;批次与化验页上的入口直接带着它),
//   再在那一批的结果里选我们的与对手方的。被取代的、删掉的结果不进选单。
//   【门】requireFunction(FN.qualityDisputes) = module.quality.view;立案要 module.quality.edit(表单在 PermissionGate 里)。
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
import { loadBatchOptions, loadBatchCode } from '../../samples/batchOptions'
import BatchPicker from '../../samples/BatchPicker'
import OpenDisputeForm, { type AssayOption } from '../OpenDisputeForm'

export default async function NewDisputePage({ searchParams }: { searchParams: Promise<{ batch?: string | string[] }> }) {
    const denied = await requireFunction(FN.qualityDisputes)
    if (denied) return denied
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const ref = parseBatchRef((await searchParams).batch)
    const back = <Link href="/quality/disputes" className="hover:underline text-sm app-link">{t('common.back')}</Link>

    if (!ref) {
        const o = await loadBatchOptions(supabase)
        return (
            <ListPage maxWidth="max-w-4xl" breadcrumb={back} title={t('quality.disputes.newTitle')} intro={t('quality.disputes.pickBatchIntro')} state={{ kind: 'ok' }}>
                <BatchPicker action="/quality/disputes/new" inbound={o.inbound} output={o.output} inboundVisible={o.canIn} outputVisible={o.canOut} />
            </ListPage>
        )
    }
    const code = await loadBatchCode(supabase, ref)
    if (!code) {
        return (
            <ListPage maxWidth="max-w-4xl" breadcrumb={back} title={t('quality.disputes.newTitle')} state={{ kind: 'ok' }}>
                <p className="text-sm text-amber-700">{t('quality.form.batchNotReadable')}</p>
            </ListPage>
        )
    }

    const col = ref.kind === 'inbound' ? 'inbound_batch_id' : 'output_batch_id'
    const [assayRes, soRes, canEdit] = await Promise.all([
        supabase.from('assay_results').select('id, code, result_party, assay_date, lab_name')
            .eq(col, ref.id).is('deleted_at', null).is('superseded_by', null).order('assay_date', { ascending: false }),
        ref.kind === 'output'
            ? supabase.from('sales_orders').select('id, code').is('deleted_at', null).neq('status', 'cancelled').order('created_at', { ascending: false }).limit(200)
            : null,
        can('module.quality.edit'),
    ])
    const assays = mustRows(assayRes, 'assay_results') as { id: string; code: string; result_party: string; assay_date: string; lab_name: string | null }[]
    const opt = (a: (typeof assays)[number]): AssayOption => ({ id: a.id, label: `${a.code} · ${formatDate(a.assay_date, locale)}${a.lab_name ? ` · ${a.lab_name}` : ''}` })
    const salesOrders: AssayOption[] = soRes ? (mustRows(soRes, 'sales_orders') as { id: string; code: string }[]).map((s) => ({ id: s.id, label: s.code })) : []

    return (
        <ListPage
            maxWidth="max-w-4xl"
            breadcrumb={back}
            title={t('quality.disputes.newTitle')}
            intro={<>{t('quality.disputes.newFor')}{' '}<Link href={batchHref(ref.kind, ref.id)} className="app-link hover:underline">{code}</Link></>}
            state={{ kind: 'ok' }}
        >
            <OpenDisputeForm batchKind={ref.kind}
                ours={assays.filter((a) => a.result_party === 'ours').map(opt)}
                counterparty={assays.filter((a) => a.result_party === 'counterparty').map(opt)}
                salesOrders={salesOrders} canEdit={canEdit} />
        </ListPage>
    )
}
