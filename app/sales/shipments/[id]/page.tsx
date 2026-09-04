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
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import ShipmentLinesTable, { type ShipmentLineRow } from './ShipmentLinesTable'

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

    // ★【行数据在服务端压平】三层嵌套在这里摊平(CONV-1 §①)。
    const tableRows: ShipmentLineRow[] = lines.map((l) => ({
        id: l.id,
        lineNo: l.sales_order_lines?.line_no != null ? String(l.sales_order_lines.line_no) : '—',
        materialCode: l.output_batches?.materials?.code ?? '',
        materialName: l.output_batches?.materials?.name ?? '',
        batchCode: l.output_batches?.code ?? '—',
        locationCode: l.storage_locations?.code ?? '',
        locationName: l.storage_locations?.name ?? '',
        qtyText: `${l.qty} ${l.output_batches?.unit ?? ''}`.trim(),
    }))

    return (
        <ListPage
            maxWidth="max-w-4xl"
            title={
                <>
                    {t('sales.shipDetail.title')} <span className="font-mono">{head.code}</span>
                </>
            }
            // ★★ 详情页恒为 ok —— 这张发货单在不在由上面的 notFound() 回答。
            state={{ kind: 'ok' }}
            notices={
                /* 【回到订单】发货单永远属于一张订单,所以这条链接总是有意义的 */
                order ? (
                    <p className="text-sm mb-4">
                        <Link href={`/sales/orders/${order.id}`} className="text-blue-600 hover:underline">
                            {t('sales.shipDetail.backToOrder', { code: order.code })}
                        </Link>
                    </p>
                ) : undefined
            }
        >
            {/* ★ 记录抬头 —— 转换前是一个 <dl class="grid grid-cols-[10rem_1fr]">,
                也就是 CONV-8 §② 那张表里的第四种写法(<dl>,全仓 5 处)。 */}
            <RecordHeader
                fields={[
                    {
                        label: t('sales.shipDetail.colCustomer'),
                        value: customer ? (
                            <>
                                <span className="font-mono">{customer.code}</span> {customer.legal_name}
                            </>
                        ) : (
                            '—'
                        ),
                    },
                    // 物理事件日 —— 货是哪天离开仓库的,同时决定收入落进哪个期间
                    { label: t('sales.shipDetail.colShipDate'), value: head.ship_date, mono: true },
                    // LOG-2b:【装箱了才出现】。没装箱时这里【什么都不画】——
                    // 一个空的"集装箱:—"会让人以为漏填了,而真相是这张单还没装箱。
                    ...(head.containers
                        ? [{
                            label: t('logistics.containerOf'),
                            value: (
                                <Link href={`/logistics/containers/${head.containers.id}`}
                                    className="font-mono text-blue-700 hover:underline">
                                    {head.containers.code}
                                </Link>
                            ),
                          }]
                        : []),
                    { label: t('sales.shipDetail.colCreatedAt'), value: new Date(head.created_at).toLocaleString(dl) },
                    ...(head.notes ? [{ label: t('sales.shipDetail.colNotes'), value: head.notes }] : []),
                ]}
            />

            {/* 【发货单不可作废、没有冲销】—— 这一句摆在页面上,而不是只写在表注释里:
                看这一页的人正是会问"能不能撤"的那个人。 */}
            <p className="text-sm text-gray-600 bg-gray-50 border border-gray-200 rounded px-3 py-2 mb-6">
                {t('sales.shipDetail.immutableNote')}
            </p>

            {/* ── 行 ───────────────────────────────────────────────────────── */}
            <h2 className="font-medium mb-2">{t('sales.shipDetail.linesTitle')}</h2>
            <div className="mb-6">
                <ShipmentLinesTable rows={tableRows} />
            </div>

            {/* ── 送货单:签发 ─────────────────────────────────────────────── */}
            <h2 className="font-medium mb-2">{t('sales.shipDetail.issuesTitle')}</h2>
            <p className="text-xs text-gray-500 mb-2">{t('sales.shipDetail.issuesNote')}</p>
            {/* EXT-1:与另外五个单据【同一个公共件】。
                一张没有行的发货单不给签发 —— 发出去的会是一张没有内容的送货单。
                ★ 出口检查:这是这一页唯一的出口,住 children;state 恒为 'ok'。 */}
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
        </ListPage>
    )
}
