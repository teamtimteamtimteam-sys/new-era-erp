// app/quality/ncr/new/page.tsx
// MES-6b-1(MES-6b Step 0 Q7):开一张不合格报告。两步(MES-6a-1 的先例):先选一批(?batch=inbound:<id> / output:<id>;批次页与提醒上的入口
//   直接带着它),再按那一批取它自己的清单 —— 化验、化验争议、(产出批)预留过或发过它的销售单。指向都可选;库里再判一次"是不是同一批"。
//   【门】requireFunction(FN.qualityNcr) = module.quality.view;开要 module.quality.edit(表单在 PermissionGate 里)。
//   开下来这一批就在质量暂扣里,直到另一个人决定它 —— 表单上说出来。
// ★ MES-7b-2(2026-10-16,MES-7b Step 0 Q15):?finding=<巡检发现> —— 从巡检页上那条发现开过来:来源定死 inspection、引用那条发现;选批那一步把它带着走。
//   发现读的是 inspection_finding_rows(门 module.safety.view);读不到就照直说,不开。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows, mustOne } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { formatDate } from '@/lib/dates'
import { parseBatchRef, batchHref, resultPartyKey, disputeStatusKey } from '../../qualityTypes'
import { loadBatchOptions, loadBatchCode } from '../../samples/batchOptions'
import BatchPicker from '../../samples/BatchPicker'
import NcrForm, { type Option } from '../NcrForm'
import { readAll } from '@/lib/readAll'

export default async function NewNcrPage({ searchParams }: { searchParams: Promise<{ batch?: string | string[]; finding?: string | string[] }> }) {
    const denied = await requireFunction(FN.qualityNcr)
    if (denied) return denied
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const sp = await searchParams
    const ref = parseBatchRef(sp.batch)
    const back = <Link href="/quality/ncr" className="hover:underline text-sm app-link">{t('common.back')}</Link>
    // MES-7b-2(Q15):从一条巡检发现开过来
    const findingId = (Array.isArray(sp.finding) ? sp.finding[0] : sp.finding) ?? ''
    const finding = findingId && /^[0-9a-f-]{36}$/i.test(findingId)
        ? mustOne(await supabase.from('inspection_finding_rows').select('id, run_id, run_code, position, item_text, is_open').eq('id', findingId).maybeSingle(),
            'inspection_finding_rows') as { id: string; run_id: string; run_code: string; position: number; item_text: string; is_open: boolean } | null
        : null
    if (findingId && !finding) {
        return (
            <ListPage maxWidth="max-w-4xl" breadcrumb={back} title={t('quality.ncr.newTitle')} state={{ kind: 'ok' }}>
                <p className="text-sm text-amber-700">{t('quality.ncr.findingNotReadable')}</p>
            </ListPage>
        )
    }
    const findingNote = finding ? (
        <p className="text-sm mb-3" data-value="from-finding">
            {t('quality.ncr.fromFinding')}{' '}
            <Link href={`/safety/inspections/${finding.run_id}#finding-${finding.id}`} className="app-link hover:underline">
                {t('quality.ncr.findingLabel', { code: finding.run_code, n: String(finding.position) })}</Link>{` — ${finding.item_text}`}
        </p>
    ) : null

    if (!ref) {
        const o = await loadBatchOptions(supabase)
        return (
            <ListPage maxWidth="max-w-4xl" breadcrumb={back} title={t('quality.ncr.newTitle')} intro={t('quality.ncr.pickBatchIntro')} state={{ kind: 'ok' }}>
                {findingNote}
                <BatchPicker action="/quality/ncr/new" inbound={o.inbound} output={o.output} inboundVisible={o.canIn} outputVisible={o.canOut}
                             hidden={finding ? { finding: finding.id } : undefined} />
            </ListPage>
        )
    }

    const code = await loadBatchCode(supabase, ref)
    if (!code) {
        return (
            <ListPage maxWidth="max-w-4xl" breadcrumb={back} title={t('quality.ncr.newTitle')} state={{ kind: 'ok' }}>
                <p className="text-sm text-amber-700">{t('quality.form.batchNotReadable')}</p>
            </ListPage>
        )
    }
    const col = ref.kind === 'inbound' ? 'inbound_batch_id' : 'output_batch_id'
    const [assayRes, disputeRes, resvRes, canEdit, canSales] = await Promise.all([
        readAll(() => supabase.from('assay_results').select('id, code, result_party, assay_date').eq(col, ref.id).is('deleted_at', null).order('assay_date', { ascending: false }), { label: 'assay_results' }),
        readAll(() => supabase.from('assay_dispute_rows').select('id, status, our_assay_code, counterparty_assay_code').eq(col, ref.id).order('created_at', { ascending: false }), { label: 'assay_dispute_rows' }),
        ref.kind === 'output'
            ? supabase.from('sales_order_reservations').select('sales_order_lines ( sales_order_id, sales_orders ( code ) )').eq('output_batch_id', ref.id)
            : null,
        can('module.quality.edit'),
        can('module.sales.view'),
    ])
    const assays: Option[] = (mustRows(assayRes, 'assay_results') as { id: string; code: string; result_party: string; assay_date: string }[])
        .map((a) => ({ id: a.id, label: `${a.code} · ${t(resultPartyKey(a.result_party))} · ${formatDate(a.assay_date, locale)}` }))
    const disputes: Option[] = (mustRows(disputeRes, 'assay_dispute_rows') as { id: string; status: string; our_assay_code: string; counterparty_assay_code: string }[])
        .map((d) => ({ id: d.id, label: `${d.our_assay_code} · ${d.counterparty_assay_code} · ${t(disputeStatusKey(d.status))}` }))
    const orderMap = new Map<string, string>()
    if (resvRes) {
        for (const r of mustRows(resvRes, 'sales_order_reservations') as { sales_order_lines: { sales_order_id: string; sales_orders: { code: string } | null } | null }[]) {
            const l = r.sales_order_lines
            if (l?.sales_order_id) orderMap.set(l.sales_order_id, l.sales_orders?.code ?? l.sales_order_id)
        }
    }
    const salesOrders: Option[] = [...orderMap.entries()].map(([id, label]) => ({ id, label })).sort((a, b) => a.label.localeCompare(b.label))

    return (
        <ListPage
            maxWidth="max-w-4xl"
            breadcrumb={back}
            title={t('quality.ncr.newTitle')}
            intro={<>{t('quality.ncr.newFor')}{' '}<Link href={batchHref(ref.kind, ref.id)} className="app-link hover:underline">{code}</Link></>}
            state={{ kind: 'ok' }}
        >
            {findingNote}
            <NcrForm batchKind={ref.kind} batchId={ref.id} assays={assays} disputes={disputes} salesOrders={salesOrders}
                     salesOrdersRestricted={ref.kind === 'output' && !canSales} canEdit={canEdit} findingId={finding?.id ?? null} />
        </ListPage>
    )
}
