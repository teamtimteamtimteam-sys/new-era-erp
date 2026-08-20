// app/sales/shipments/[id]/page.tsx
// EXT-1:发货单详情 —— 这一族缺的【第五张详情页】。
//
// 【它此前为什么不存在,以及那为什么是个问题】SO-3b 建了发货单、发货单行、
// 签发档与 PDF 路由,却没有建详情页:销售订单上的发货那一段只给了一条【直接指向
// PDF 预览】的链接。于是"这张发货单是什么"这个问题,系统里只有一个答案 ——
// 一份渲染出来的纸。签发过哪几版、每一版是什么时候、字节摘要是什么,
// 屏幕上没有任何地方看得到,而那正是这一族其他四个单据都有的东西。
//
// 【本页不改任何规则】发货单【不可作废、没有冲销】(见 shipments 表注释),
// 所以这里没有任何写操作,只有一件事是"动作":签发送货单 —— 而它走的是
// 与另外五个单据同一个公共件 app/components/IssuePanel.tsx。
//
// 【入口】销售订单详情页的发货那一段(app/sales/orders/[id]/ShippingSection.tsx),
// 单号本身现在是链接。这是【手工确认的】——[id] 动态路由上,可达性走查不做
// "打得开却走不到"的断言(SAL-B6 的新建客户页就是这么带着零入口发出去的)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import IssuePanel from '@/app/components/IssuePanel'
import { notFound } from 'next/navigation'

export default async function ShipmentDetailPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前。
    const denied = await requireModule(MOD.sales)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dl = locale === 'zh' ? 'zh-CN' : 'en-SG'

    const head = mustOne(
        await supabase
            .from('shipments')
            .select(
                'id, code, ship_date, notes, created_at, container_id, ' +
                'containers ( id, code ), ' +
                'sales_orders ( id, code, customers ( code, legal_name ) )'
            )
            .eq('id', id)
            .maybeSingle(),
        'shipments'
    ) as unknown as {
        id: string
        code: string
        ship_date: string
        notes: string | null
        created_at: string
        container_id: string | null
        containers: { id: string; code: string } | null
        sales_orders: {
            id: string
            code: string
            customers: { code: string; legal_name: string } | null
        } | null
    } | null

    // 【读不到 = 404,不是一张空页】而 mustOne 已经把"查询失败"与"没有这一行"
    // 分开了:失败会抛,到不了这里。
    if (!head) notFound()

    const [linesRes, issuesRes] = await Promise.all([
        supabase
            .from('shipment_lines')
            .select(
                'id, qty, ' +
                'output_batches ( code, unit, materials ( code, name ) ), ' +
                'storage_locations ( code, name ), ' +
                'sales_order_lines ( line_no )'
            )
            .eq('shipment_id', id)
            .order('created_at'),
        supabase
            .from('shipment_issues')
            .select('version, issued_at, sha256')
            .eq('shipment_id', id)
            .order('version', { ascending: false }),
    ])

    const lines = mustRows(linesRes, 'shipment_lines') as unknown as {
        id: string
        qty: number
        output_batches: {
            code: string
            unit: string
            materials: { code: string; name: string } | null
        } | null
        storage_locations: { code: string; name: string } | null
        sales_order_lines: { line_no: number } | null
    }[]
    const issues = mustRows(issuesRes, 'shipment_issues') as unknown as {
        version: number
        issued_at: string
        sha256: string
    }[]

    const order = head.sales_orders
    const customer = order?.customers ?? null

    return (
        <div className="p-8 max-w-4xl">
            <h1 className="text-2xl font-bold mb-1">
                {t('sales.shipDetail.title')} <span className="font-mono">{head.code}</span>
            </h1>
            {/* 【回到订单】发货单永远属于一张订单,所以这条链接总是有意义的 */}
            {order && (
                <p className="text-sm mb-4">
                    <Link href={`/sales/orders/${order.id}`} className="text-blue-600 hover:underline">
                        {t('sales.shipDetail.backToOrder', { code: order.code })}
                    </Link>
                </p>
            )}

            {/* ── 单头 ─────────────────────────────────────────────────────── */}
            <dl className="grid grid-cols-[10rem_1fr] gap-y-1 text-sm mb-6">
                <dt className="text-gray-500">{t('sales.shipDetail.colCustomer')}</dt>
                <dd>
                    {customer ? (
                        <>
                            <span className="font-mono">{customer.code}</span> {customer.legal_name}
                        </>
                    ) : (
                        '—'
                    )}
                </dd>
                <dt className="text-gray-500">{t('sales.shipDetail.colShipDate')}</dt>
                {/* 物理事件日 —— 货是哪天离开仓库的,同时决定收入落进哪个期间 */}
                <dd className="font-mono">{head.ship_date}</dd>
                {/* LOG-2b:【装箱了才出现】。没装箱时这里【什么都不画】——
                    一个空的"集装箱:—"会让人以为漏填了,而真相是这张单还没装箱。 */}
                {head.containers && (
                    <>
                        <dt className="text-gray-500">{t('logistics.containerOf')}</dt>
                        <dd>
                            <Link href={`/logistics/containers/${head.containers.id}`}
                                className="font-mono text-blue-700 hover:underline">
                                {head.containers.code}
                            </Link>
                        </dd>
                    </>
                )}
                <dt className="text-gray-500">{t('sales.shipDetail.colCreatedAt')}</dt>
                <dd>{new Date(head.created_at).toLocaleString(dl)}</dd>
                {head.notes && (
                    <>
                        <dt className="text-gray-500">{t('sales.shipDetail.colNotes')}</dt>
                        <dd>{head.notes}</dd>
                    </>
                )}
            </dl>

            {/* 【发货单不可作废、没有冲销】—— 这一句摆在页面上,而不是只写在表注释里:
                看这一页的人正是会问"能不能撤"的那个人。 */}
            <p className="text-sm text-gray-600 bg-gray-50 border border-gray-200 rounded px-3 py-2 mb-6">
                {t('sales.shipDetail.immutableNote')}
            </p>

            {/* ── 行 ───────────────────────────────────────────────────────── */}
            <h2 className="font-medium mb-2">{t('sales.shipDetail.linesTitle')}</h2>
            {lines.length === 0 ? (
                // 具名的空状态 —— 一张没有行的发货单在结构上不该存在,所以这句话
                // 本身就是一个信号,不是"暂无数据"。
                <p className="text-sm text-gray-500 mb-6">{t('sales.shipDetail.noLines')}</p>
            ) : (
                <table className="w-full border-collapse border border-gray-300 text-sm mb-6">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left">
                                {t('sales.shipDetail.colLineNo')}
                            </th>
                            <th className="border border-gray-300 px-3 py-2 text-left">
                                {t('sales.shipDetail.colMaterial')}
                            </th>
                            <th className="border border-gray-300 px-3 py-2 text-left">
                                {t('sales.shipDetail.colBatch')}
                            </th>
                            <th className="border border-gray-300 px-3 py-2 text-left">
                                {t('sales.shipDetail.colLocation')}
                            </th>
                            <th className="border border-gray-300 px-3 py-2 text-right">
                                {t('sales.shipDetail.colQty')}
                            </th>
                        </tr>
                    </thead>
                    <tbody>
                        {lines.map((l) => (
                            <tr key={l.id}>
                                <td className="border border-gray-300 px-3 py-2 font-mono">
                                    {l.sales_order_lines?.line_no ?? '—'}
                                </td>
                                <td className="border border-gray-300 px-3 py-2">
                                    {l.output_batches?.materials ? (
                                        <>
                                            <span className="font-mono">
                                                {l.output_batches.materials.code}
                                            </span>{' '}
                                            {l.output_batches.materials.name}
                                        </>
                                    ) : (
                                        '—'
                                    )}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 font-mono">
                                    {l.output_batches?.code ?? '—'}
                                </td>
                                {/* 【发货当刻货在哪】—— 这一列是发货行自己记的,不是预留行的
                                    location(那个会随整桶转移改写)。两者日后可以不同。 */}
                                <td className="border border-gray-300 px-3 py-2">
                                    {l.storage_locations ? (
                                        <>
                                            <span className="font-mono">{l.storage_locations.code}</span>{' '}
                                            {l.storage_locations.name}
                                        </>
                                    ) : (
                                        '—'
                                    )}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                    {l.qty} {l.output_batches?.unit ?? ''}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}

            {/* ── 送货单:签发 ─────────────────────────────────────────────── */}
            <h2 className="font-medium mb-2">{t('sales.shipDetail.issuesTitle')}</h2>
            <p className="text-xs text-gray-500 mb-2">{t('sales.shipDetail.issuesNote')}</p>
            {/* EXT-1:与另外五个单据【同一个公共件】。
                一张没有行的发货单不给签发 —— 发出去的会是一张没有内容的送货单。 */}
            <IssuePanel
                pdfHref={`/sales/shipments/${head.id}/pdf`}
                previewLabel={t('sales.shipDetail.previewPdf')}
                issueLabel={t('sales.shipDetail.issuePdf')}
                blockedReason={lines.length === 0 ? t('sales.shipDetail.issueBlockedNoLines') : ''}
                hasLines={lines.length > 0}
            />
            {issues.length === 0 ? (
                <p className="text-sm text-gray-500">{t('sales.shipDetail.neverIssued')}</p>
            ) : (
                <ul className="text-sm space-y-1">
                    {issues.map((iss) => (
                        <li key={iss.version} className="font-mono text-xs">
                            <a
                                href={`/sales/shipments/${head.id}/pdf?version=${iss.version}`}
                                target="_blank"
                                rel="noopener noreferrer"
                                className="text-blue-600 hover:underline"
                            >
                                v{iss.version}
                            </a>
                            {' · '}
                            {new Date(iss.issued_at).toLocaleString(dl)} · {iss.sha256.slice(0, 12)}…
                        </li>
                    ))}
                </ul>
            )}
        </div>
    )
}
