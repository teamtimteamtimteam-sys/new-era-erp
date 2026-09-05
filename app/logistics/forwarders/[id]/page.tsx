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
import { can } from '@/lib/permissions'
import { Refusal } from '@/app/components/ui/refusal'
import { formatAmount } from '@/lib/format'
import ForwarderPanels from './ForwarderPanels'

export default async function ForwarderDetailPage({ params }: { params: Promise<{ id: string }> }) {
    const denied = await requireModule(MOD.logistics)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    // ★★【FIX-2a:这一页此前对三个角色是 404 —— 而 404 是一句【断言】】★★
    // 守卫是 module.logistics.view(operations / sales / warehouse 都持有),
    // 但 suppliers 基表挂 module.suppliers.view。他们读回零行,于是下面那句
    // notFound() 触发,屏幕说【这家货代不存在】。
    // 它比一块空面板更硬:空面板说"没有内容",404 说"没有这个东西"。
    // 名字与编号走 supplier_lookup;国别与付款条件是商务数据,单独取,见下。
    const sup = await supabase
        .from('supplier_lookup')
        .select('id, code, legal_name, counterparty_type')
        .eq('id', id)
        .is('deleted_at', null)
        .single()
    // 【不是货代的 id 在这一页上就是 404】—— 供应商有自己的页面
    if (sup.error || !sup.data || sup.data.counterparty_type !== 'forwarder') notFound()

    // 【国别与付款条件不在查名视图里】—— payment_terms 是 FIX-1 点名的六列商务数据
    // 之一,country 同属供应商主数据。持 suppliers.view 的人照旧读得到;
    // 其余的人在抬头那一行看见【具名受限】,而不是一个消失的字段。
    const canCommercial = await can('module.suppliers.view')
    const commercial = canCommercial
        ? (await supabase.from('suppliers').select('country, payment_terms').eq('id', id).maybeSingle()).data
        : null

    const detailsRes = await supabase
        .from('forwarder_details')
        .select('main_routes, ports_served, free_time_terms, dg_classes, notes')
        .eq('supplier_id', id)
        .maybeSingle()
    // 【读失败与"还没填过"不是一回事】。`?? null` 会把一次读取故障显示成
    // 一张空表单,而人会照着它重填一遍 —— 失败必须失败。
    if (detailsRes.error) throw new Error(detailsRes.error.message)
    const details = detailsRes.data

    // 运费单据走查名视图:体内谓词多了 logistics.view(读这一页的守卫码)。
    // 金额那一列【仍然】按 data.view_prices 遮 —— 本刀不改任何一列的遮蔽。
    const freight = mustRows(
        await supabase
            .from('freight_document_lookup')
            .select('id, code, doc_date, amount_ccy, currency, payment_status, status, direction')
            .eq('supplier_id', id)
            .is('deleted_at', null)
            .order('doc_date', { ascending: false }),
        'freight documents'
    )

    // ★★【FIX-2a(b):未结应付【不】放宽 —— 但它必须说出来】★★
    // ap_open_items 挂 module.finance.view。此前读回零行,而下面的 reduce
    // 把零行变成 owedBase = 0,屏幕上是一个自信的「未结应付 0.00」——
    // 对一个根本无权知道这家货代欠没欠钱的人。Tim 的裁定:现场不接触商务数据。
    // 所以先问权限;没有就不读,并把 null 一路传到渲染,由它画具名受限。
    const canMoney = await can('module.finance.view')
    const open = canMoney
        ? mustRows(
              await supabase.from('ap_open_items').select('open_base, currency').eq('counterparty_id', id),
              'ap_open_items'
          )
        : []
    const owedBase = canMoney ? open.reduce((a, o) => a + Number(o.open_base ?? 0), 0) : null
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
            .select('id, lane_id, amount_ccy, currency, valid_from, valid_to, free_days')
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
                {sup.data.code}
                {/* 国别与付款条件:读得到就照印;读不到画【具名受限】,不静静消失 ——
                    一个不见了的字段读起来像"没填",而这里的真相是"你不能看"。 */}
                {' · '}
                {canCommercial ? (
                    <>
                        {commercial?.country}
                        {commercial?.payment_terms ? ` · ${commercial.payment_terms}` : ''}
                    </>
                ) : (
                    <Refusal why={t('logistics.termsRestrictedHint')}>{t('common.restricted')}</Refusal>
                )}
                {' · '}
                {t('logistics.colBalanceOwed')}:{' '}
                {/* ★ owedBase === null 是【扣下了】,0 是【真的不欠】—— 两句话,两个渲染。 */}
                {owedBase === null ? (
                    <Refusal why={t('logistics.owedRestrictedHint')}>{t('common.restricted')}</Refusal>
                ) : owedBase ? (
                    formatAmount(owedBase, baseCcy)
                ) : (
                    t('logistics.noBalance')
                )}
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
                    // 【null 要原样传到底】—— 用 ?? 0 顶一下,三态就在这里塌成两态
                    free_days: q.free_days === null ? null : Number(q.free_days),
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
                    freeDays: t('logistics.quoteFreeDays'),
                    freeDaysHint: t('logistics.quoteFreeDaysHint'),
                    freeDaysNotStated: t('logistics.quoteFreeDaysNotStated'),
                    noEditDoor: t('logistics.quotesNoEditDoor'),
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
                                        {/* LOG-4b:方向一个字。进货运费与出口运费在这张表上
                                            长得一模一样,而它们去的是完全不同的科目。 */}
                                        <td className="border border-gray-300 px-3 py-1 text-xs text-gray-600">
                                            {t('finance.freight.directionShort.' + (f.direction as string))}
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
