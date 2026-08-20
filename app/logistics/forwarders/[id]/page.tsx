// app/logistics/forwarders/[id]/page.tsx
// LOG-1c:货代详情 —— 物流属性、他的运费凭证、未结应付、以及按航段的报价。
//
// 【这里没有采购单、没有合规证书、没有物料类别】。货代在账上是一行 suppliers,
// 在屏幕上不是供应商 —— 见列表页抬头。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { formatAmount } from '@/lib/format'
import ForwarderPanels from './ForwarderPanels'

export default async function ForwarderDetailPage({ params }: { params: Promise<{ id: string }> }) {
    const denied = await requireModule(MOD.logistics)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const sup = await supabase
        .from('suppliers')
        .select('id, code, legal_name, country, payment_terms, counterparty_type')
        .eq('id', id)
        .is('deleted_at', null)
        .single()
    // 【不是货代的 id 在这一页上就是 404】—— 供应商有自己的页面
    if (sup.error || !sup.data || sup.data.counterparty_type !== 'forwarder') notFound()

    const detailsRes = await supabase
        .from('forwarder_details')
        .select('main_routes, ports_served, free_time_terms, dg_classes, notes')
        .eq('supplier_id', id)
        .maybeSingle()
    // 【读失败与"还没填过"不是一回事】。`?? null` 会把一次读取故障显示成
    // 一张空表单,而人会照着它重填一遍 —— 失败必须失败。
    if (detailsRes.error) throw new Error(detailsRes.error.message)
    const details = detailsRes.data

    const freight = mustRows(
        await supabase
            .from('freight_documents')
            .select('id, code, doc_date, amount_ccy, currency, payment_status, status')
            .eq('supplier_id', id)
            .is('deleted_at', null)
            .order('doc_date', { ascending: false }),
        'freight documents'
    )

    const open = mustRows(
        await supabase.from('ap_open_items').select('open_base, currency').eq('counterparty_id', id),
        'ap_open_items'
    )
    const owedBase = open.reduce((a, o) => a + Number(o.open_base ?? 0), 0)
    const baseRow = mustRows(
        await supabase.from('currencies').select('code').eq('is_base', true).limit(1),
        'base currency'
    )
    const baseCcy = (baseRow[0]?.code as string) ?? null

    const lanes = mustRows(
        await supabase
            .from('lanes')
            .select('id, origin_port_id, destination_port_id')
            .is('deleted_at', null),
        'lanes'
    )
    const ports = mustRows(
        await supabase.from('ports').select('id, code, name').is('deleted_at', null),
        'ports'
    )
    const portName = new Map(ports.map((p) => [p.id as string, `${p.code} ${p.name}`]))
    const laneOptions = lanes.map((l) => ({
        id: l.id as string,
        label: `${portName.get(l.origin_port_id as string) ?? '?'} → ${portName.get(l.destination_port_id as string) ?? '?'}`,
    }))

    const quotes = mustRows(
        await supabase
            .from('forwarder_rate_quotes')
            .select('id, lane_id, amount_ccy, currency, valid_from, valid_to')
            .eq('supplier_id', id)
            .is('deleted_at', null)
            .order('valid_from', { ascending: false }),
        'rate quotes'
    )

    const currencies = mustRows(
        await supabase.from('currencies').select('code').order('code'),
        'currencies'
    ).map((c) => c.code as string)

    return (
        <div className="p-8">
            <div className="mb-6">
                <Link href="/logistics/forwarders" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="text-2xl font-bold mb-1">{sup.data.legal_name}</h1>
            <p className="mb-6 text-sm text-gray-500">
                {sup.data.code} · {sup.data.country}
                {sup.data.payment_terms ? ` · ${sup.data.payment_terms}` : ''}
                {' · '}
                {t('logistics.colBalanceOwed')}:{' '}
                {owedBase ? formatAmount(owedBase, baseCcy) : t('logistics.noBalance')}
            </p>

            <ForwarderPanels
                supplierId={id}
                details={details}
                lanes={laneOptions}
                quotes={quotes.map((q) => ({
                    id: q.id as string,
                    lane_id: q.lane_id as string,
                    amount_ccy: String(q.amount_ccy),
                    currency: q.currency as string,
                    valid_from: q.valid_from as string,
                    valid_to: q.valid_to as string,
                }))}
                currencies={currencies}
                labels={{
                    detailsHeading: t('logistics.detailsHeading'),
                    mainRoutes: t('logistics.mainRoutes'),
                    portsServed: t('logistics.portsServed'),
                    freeTimeTerms: t('logistics.freeTimeTerms'),
                    dgClasses: t('logistics.dgClasses'),
                    notes: t('logistics.notes'),
                    contactsNote: t('logistics.contactsNote'),
                    save: t('common.save'),
                    quotesHeading: t('logistics.quotesHeading'),
                    quotesEmpty: t('logistics.quotesEmpty'),
                    booksNothing: t('logistics.quotesBooksNothing'),
                    lane: t('logistics.quoteLane'),
                    amount: t('logistics.quoteAmount'),
                    validFrom: t('logistics.quoteValidFrom'),
                    validTo: t('logistics.quoteValidTo'),
                    addQuote: t('logistics.addQuote'),
                    removeQuote: t('logistics.removeQuote'),
                    noLanes: t('logistics.noLanes'),
                }}
            />

            <section className="mt-8 border-t pt-6">
                <h2 className="mb-3 text-xl font-bold">{t('logistics.freightHeading')}</h2>
                {freight.length === 0 ? (
                    <p className="text-sm text-gray-500">{t('logistics.freightEmpty')}</p>
                ) : (
                    <div className="overflow-x-auto">
                        <table className="w-full border-collapse border border-gray-300 text-sm">
                            <tbody>
                                {freight.map((f) => (
                                    <tr key={f.id as string}>
                                        {/* LOG-2b:运费凭证【有自己的页面】(app/finance/freight/[id]),
                                            所以这里从只读文本变成链接。 */}
                                        <td className="border border-gray-300 px-3 py-1 font-mono text-xs">
                                            <Link href={`/finance/freight/${f.id}`} className="text-blue-700 hover:underline">
                                                {f.code as string}
                                            </Link>
                                        </td>
                                        <td className="border border-gray-300 px-3 py-1">{f.doc_date}</td>
                                        <td className="border border-gray-300 px-3 py-1 text-right">
                                            {formatAmount(Number(f.amount_ccy), f.currency as string)}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-1">{f.payment_status}</td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    </div>
                )}
            </section>
        </div>
    )
}
