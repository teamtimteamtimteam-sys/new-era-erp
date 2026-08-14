// SO-1:销售订单详情 —— 状态、转换、行、留痕、签发档。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows, mustOne } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import Subnav from '@/app/sales/Subnav'
import { soStatusKey, SO_ALLOWED_NEXT } from '../salesOrderTypes'
import TransitionPanel from './TransitionPanel'
import IssuePanel from './IssuePanel'
import ReservationSection from './ReservationSection'
import OrderInvoiceSection from './OrderInvoiceSection'

export default async function SalesOrderPage({ params }: { params: Promise<{ id: string }> }) {
    const denied = await requireModule(MOD.sales)
    if (denied) return denied
    const { id } = await params
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const order = mustOne(
        await supabase.from('sales_orders')
            .select('id, code, status, order_date, currency, fx_rate, notes, cancel_reason, customers ( code, legal_name )')
            .eq('id', id).is('deleted_at', null).maybeSingle(),
        'sales_orders')
    if (!order) notFound()
    const o = order as unknown as {
        id: string; code: string; status: string; order_date: string; currency: string
        fx_rate: number; notes: string | null; cancel_reason: string | null
        customers: { code: string; legal_name: string } | null }

    // SO-2:多取 id / material_id / 单位 —— 预留挂在【行】上,而单位长在物料上
    // (订单行没有 unit 这一列)。
    const lines = mustRows(
        await supabase.from('sales_order_lines')
            .select('id, line_no, quantity, unit_price, price_source, material_id, materials ( code, name, unit )')
            .eq('sales_order_id', id).order('line_no'),
        'sales_order_lines') as unknown as {
            id: string; line_no: number; quantity: number; unit_price: number; price_source: string | null
            material_id: string
            materials: { code: string; name: string; unit: string } | null }[]

    const history = mustRows(
        await supabase.from('sales_order_history')
            .select('change_type, detail, changed_at').eq('sales_order_id', id)
            .order('changed_at', { ascending: false }),
        'sales_order_history') as { change_type: string; detail: string | null; changed_at: string }[]

    const issues = mustRows(
        await supabase.from('so_issues').select('version, file_path, sha256, issued_at')
            .eq('sales_order_id', id).order('version', { ascending: false }),
        'so_issues') as { version: number; file_path: string; sha256: string; issued_at: string }[]

    const dl = locale === 'zh' ? 'zh-CN' : 'en-US'
    const nextStates = SO_ALLOWED_NEXT[o.status] ?? []

    return (
        <>
            <Subnav />
            <div className="p-8 max-w-4xl">
                <div className="mb-6">
                    <Link href="/sales/orders" className="text-blue-600 hover:underline text-sm">{t('common.back')}</Link>
                </div>
                <div className="flex items-start justify-between mb-4">
                    <div>
                        <h1 className="text-2xl font-bold font-mono">{o.code}</h1>
                        <p className="text-sm text-gray-600 mt-1">
                            {o.customers ? `${o.customers.code} — ${o.customers.legal_name}` : '—'}
                        </p>
                    </div>
                    <span className="px-3 py-1 rounded bg-gray-200 text-sm">{t(soStatusKey(o.status))}</span>
                </div>

                <dl className="grid grid-cols-2 gap-x-8 gap-y-1 text-sm mb-6">
                    <div><dt className="inline text-gray-500">{t('sales.colDate')}: </dt>
                         <dd className="inline">{new Date(o.order_date).toLocaleDateString(dl)}</dd></div>
                    <div><dt className="inline text-gray-500">{t('sales.colCurrency')}: </dt>
                         <dd className="inline">{o.currency} @ {o.fx_rate}</dd></div>
                    {o.cancel_reason && (
                        <div className="col-span-2"><dt className="inline text-gray-500">{t('sales.cancelReason')}: </dt>
                             <dd className="inline">{o.cancel_reason}</dd></div>
                    )}
                </dl>

                <TransitionPanel orderId={o.id} status={o.status} nextStates={nextStates} />

                <h2 className="font-medium mt-8 mb-2">{t('sales.form.lines')}</h2>
                <table className="w-full border-collapse border border-gray-300 text-sm">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left">#</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('sales.colMaterial')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('sales.form.qty')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('sales.form.unitPrice')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {lines.map((l) => (
                            <tr key={l.line_no}>
                                <td className="border border-gray-300 px-3 py-2">{l.line_no}</td>
                                <td className="border border-gray-300 px-3 py-2">
                                    {l.materials ? `${l.materials.code} — ${l.materials.name}` : '—'}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-right">{l.quantity}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right">{l.unit_price}</td>
                            </tr>
                        ))}
                    </tbody>
                </table>

                {/* SO-3a:开票 —— 订单流【先开票后发货】(选项 C),开票即过账 */}
                <OrderInvoiceSection
                    orderId={o.id}
                    status={o.status}
                    lines={lines.map((l) => ({
                        id: l.id,
                        line_no: l.line_no,
                        material_code: l.materials?.code ?? '—',
                        quantity: l.quantity,
                        unit: l.materials?.unit ?? '',
                    }))}
                />

                {/* SO-2:预留 —— 逐行,挨着行表放,因为它回答的正是"这一行由哪几批货满足" */}
                <ReservationSection
                    orderId={o.id}
                    status={o.status}
                    lines={lines.map((l) => ({
                        id: l.id,
                        line_no: l.line_no,
                        quantity: l.quantity,
                        material_id: l.material_id,
                        material_code: l.materials?.code ?? '—',
                        material_name: l.materials?.name ?? '',
                        unit: l.materials?.unit ?? '',
                    }))}
                />

                <h2 className="font-medium mt-8 mb-2">{t('sales.issues')}</h2>
                {/* 【没有"已发送"标志】系统不知道对方收没收到 —— 见 so_issues 表注释 */}
                <IssuePanel orderId={o.id} status={o.status} />
                <p className="text-xs text-gray-500 mb-2">{t('sales.issuesNote')}</p>
                {issues.length === 0 ? (
                    <p className="text-gray-500 text-sm">{t('sales.noIssues')}</p>
                ) : (
                    <ul className="text-sm space-y-1">
                        {issues.map((i) => (
                            <li key={i.version} className="font-mono text-xs">
                                <a href={`/sales/orders/${o.id}/pdf?version=${i.version}`} target="_blank"
                                   rel="noopener noreferrer" className="text-blue-600 hover:underline">
                                    v{i.version}
                                </a>
                                {' · '}{new Date(i.issued_at).toLocaleString(dl)} · {i.sha256.slice(0, 12)}…
                            </li>
                        ))}
                    </ul>
                )}

                <h2 className="font-medium mt-8 mb-2">{t('sales.history')}</h2>
                <ul className="text-sm space-y-1">
                    {history.map((h, i) => (
                        <li key={i} className="text-gray-600">
                            {new Date(h.changed_at).toLocaleString(dl)} · {h.change_type}
                            {h.detail ? ` · ${h.detail}` : ''}
                        </li>
                    ))}
                </ul>
            </div>
        </>
    )
}
