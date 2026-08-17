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
import IssuePanel from '@/app/components/IssuePanel'
import ReservationSection from './ReservationSection'
import OrderInvoiceSection from './OrderInvoiceSection'
import ShippingSection from './ShippingSection'

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

    // SO-1b:改单史与事件史【同表】—— 多取三列,因为一行 line_update 的全部内容
    // 就是 "12 → 10" 与那句理由;只印 change_type 等于把留痕做成一个空标签。
    const history = mustRows(
        await supabase.from('sales_order_history')
            .select('change_type, detail, changed_at, line_no, old_quantity, new_quantity, old_unit_price, new_unit_price, amend_reason')
            .eq('sales_order_id', id)
            .order('changed_at', { ascending: false }),
        'sales_order_history') as {
            change_type: string; detail: string | null; changed_at: string
            line_no: number | null
            old_quantity: number | null; new_quantity: number | null
            old_unit_price: number | null; new_unit_price: number | null
            amend_reason: string | null }[]

    const issues = mustRows(
        await supabase.from('so_issues').select('version, file_path, sha256, issued_at')
            .eq('sales_order_id', id).order('version', { ascending: false }),
        'so_issues') as { version: number; file_path: string; sha256: string; issued_at: string }[]

    const dl = locale === 'zh' ? 'zh-CN' : 'en-US'
    const nextStates = SO_ALLOWED_NEXT[o.status] ?? []

    // ════════════════════════════════════════════════════════════════════════
    // SO-1b §0(b):【签发之后又改过】——「客户手里那份」与这张单据分道扬镳的信号。
    //
    // 判据是【最新一次改动 vs 最新一版签发档】,不是一个"脏了"的标志位。
    // 标志位要有人去清,而没有人会记得清它;两个时间戳一比,答案永远是当下的真相。
    // 【只数改单那四种】—— 预留、开票、发货都不改客户手里那张纸上的字。
    const AMEND_TYPES = ['header_update', 'line_update', 'line_add', 'line_remove']
    const lastAmendAt = history.find((h) => AMEND_TYPES.includes(h.change_type))?.changed_at ?? null
    const lastIssueAt = issues.length > 0 ? issues[0].issued_at : null
    const amendedSinceIssue =
        lastIssueAt !== null && lastAmendAt !== null && new Date(lastAmendAt) > new Date(lastIssueAt)

    // SO-4b:【这张单是照哪一张报价下的】—— 反向那半条链。
    // 判据是订单历史里的 converted_from_quote 那一行(它的 detail 就是报价单号),
    // 而不是订单上的一个外键:转换那一刀刻意没有在 sales_orders 上加列 ——
    // "从报价来的"是一个【发生过的事件】,而事件住在历史里。
    const fromQuoteCode = history.find((h) => h.change_type === 'converted_from_quote')?.detail ?? null
    const fromQuote = fromQuoteCode
        ? (mustOne(
              await supabase.from('quotes').select('id, code').eq('code', fromQuoteCode).maybeSingle(),
              'quotes') as { id: string; code: string } | null)
        : null

    // 改单入口的三个状态,与 amend_sales_order 的闸【同一份表】。
    // (shipped 在数据库那边还开着一条"只许加行"的缝,但它今天没有入口 ——
    //  见 docs/known-issues.md。界面永远不该比数据库更宽松,反过来是允许的。)
    const amendable = ['draft', 'confirmed', 'partially_shipped'].includes(o.status)

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
                    {fromQuoteCode && (
                        <div className="col-span-2"><dt className="inline text-gray-500">{t('quotes.fromQuote')}: </dt>
                             <dd className="inline">
                                 {fromQuote ? (
                                     <Link href={`/sales/quotes/${fromQuote.id}`}
                                           className="font-mono text-blue-600 hover:underline">{fromQuote.code}</Link>
                                 ) : (
                                     // 【报价读不到时印单号,不留白】读不到与不存在是两件事,
                                     // 而一片空白会被读成"没有出处"
                                     <span className="font-mono">{fromQuoteCode}</span>
                                 )}
                             </dd></div>
                    )}
                    {o.cancel_reason && (
                        <div className="col-span-2"><dt className="inline text-gray-500">{t('sales.cancelReason')}: </dt>
                             <dd className="inline">{o.cancel_reason}</dd></div>
                    )}
                </dl>

                {/* SO-1b §0(b):签发之后又改过 —— 客户手里那份已经不是这一张了 */}
                {amendedSinceIssue && (
                    <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-4">
                        {t('sales.amend.amendedSinceIssue')}
                    </div>
                )}

                <TransitionPanel orderId={o.id} status={o.status} nextStates={nextStates} />

                {/* SO-1b:改单入口。【与转换按钮并排,但不是一个转换】—— 改单不动状态,
                    它动的是这张单说了什么。三个状态才画,与数据库那道闸同一份表。 */}
                {amendable && (
                    <div className="mt-3 flex flex-wrap items-baseline gap-x-3">
                        <Link href={`/sales/orders/${o.id}/amend`}
                              className="border border-gray-400 px-3 py-1 rounded text-sm hover:bg-gray-50">
                            {o.status === 'draft' ? t('sales.amend.editDraft') : t('sales.amend.action')}
                        </Link>
                        <span className="text-xs text-gray-500">
                            {o.status === 'draft' ? t('sales.amend.editDraftHint') : t('sales.amend.actionHint')}
                        </span>
                    </div>
                )}

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

                {/* SO-3b:发货 —— 选项 C 的第二半。摆在预留【之后】,因为它消耗预留 */}
                <ShippingSection
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
                {/* SO-1b:签发面板【旁边】也说一次 —— 这里正是"要不要重新签发"
                    这个问题被问出来的地方,而它在页面顶部那一句可能早被滚过去了 */}
                {amendedSinceIssue && (
                    <p className="text-sm text-amber-900 bg-amber-50 border border-amber-300 rounded px-3 py-2 mb-2">
                        {t('sales.amend.reissueHint')}
                    </p>
                )}
                {/* 【没有"已发送"标志】系统不知道对方收没收到 —— 见 so_issues 表注释 */}
                {/* EXT-1:入参从 (orderId, status) 换成公共件的形状。
                    禁用条件与文案逐字不变 —— 草稿不给签发,理由摆在旁边。
                    此前 isDraft 写死在组件里,现在由本页说出来:哪一页知道
                    自己什么时候不能签发,就该由哪一页说。 */}
                <IssuePanel
                    pdfHref={`/sales/orders/${o.id}/pdf`}
                    previewLabel={t('sales.previewPdf')}
                    issueLabel={t('sales.issuePdf')}
                    canIssue={o.status !== 'draft'}
                    blockedReason={o.status === 'draft' ? t('sales.issueBlockedDraft') : ''}
                />
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
                    {history.map((h, i) => {
                        // SO-1b:改动的内容【印出来】—— 一行 line_update 的全部意义
                        // 就是 "12 → 10";只印类型名等于把留痕做成一个空标签。
                        const moves: string[] = []
                        if (h.old_quantity !== null || h.new_quantity !== null)
                            moves.push(`${h.old_quantity ?? '—'} → ${h.new_quantity ?? '—'}`)
                        if (h.old_unit_price !== null || h.new_unit_price !== null)
                            moves.push(`@ ${h.old_unit_price ?? '—'} → ${h.new_unit_price ?? '—'}`)
                        return (
                            <li key={i} className="text-gray-600">
                                {new Date(h.changed_at).toLocaleString(dl)}
                                {/* 动态前缀,后缀集合接 sales_order_history 的 CHECK(check-i18n 的清单) */}
                                {' · '}{t('sales.changeType.' + h.change_type)}
                                {h.line_no !== null ? ` · #${h.line_no}` : ''}
                                {moves.length > 0 ? ` · ${moves.join(' ')}` : ''}
                                {h.detail ? ` · ${h.detail}` : ''}
                                {h.amend_reason ? ` · ${h.amend_reason}` : ''}
                            </li>
                        )
                    })}
                </ul>
            </div>
        </>
    )
}
