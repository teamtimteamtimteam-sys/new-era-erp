// SO-4b:报价详情 —— 签发、编辑、转换、谢绝,以及"签发之后又改过"那个信号。
//
// 【这一页与订单详情最大的区别:签发之后【仍然改得动】】
// 订单在确认时冻,因为确认之后有钱和货站在那些数字上;报价是谈判过程中的东西,
// 改价改量本来就是它的用途。所以这里没有"冻结"的概念,只有两个提示:
//   * 签发之后又改过 → 琥珀色横幅,提醒重新签发(客户手里那份是某个具体版本);
//   * 转换之后 → 整张单只读,而且说出为什么(它已经变成一张订单了)。
//
// 【每一个禁用条件都把理由写在控件旁边】(CMP-2)—— 转换的四条拒绝在服务端
// 各有名字,这里把同样四句话在按钮按下【之前】就说出来,判据取自
// quote_status.convertible / expired / status,而那三列与服务端的拒绝读的是
// 同一处推导(quote_is_expired)。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { formatAmount } from '@/lib/format'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import Subnav from '@/app/sales/Subnav'
import { quoteStatusKey } from '../quoteTypes'
import IssuePanel from './IssuePanel'
import ConvertControl from './ConvertControl'
import DeclineControl from './DeclineControl'
import QuoteLinesEditor from './QuoteLinesEditor'

export default async function QuotePage({ params }: { params: Promise<{ id: string }> }) {
    const denied = await requireModule(MOD.sales)
    if (denied) return denied

    const { id } = await params
    const t = await getTranslations()
    const locale = await getLocale()
    const dl = locale === 'zh' ? 'zh-CN' : 'en-US'
    const supabase = await createClient()

    const q = mustOne(
        await supabase.from('quote_status')
            .select('quote_id, code, customer_code, customer_name, quote_date, valid_until, currency, fx_rate, status, decline_reason, converted_order_id, converted_order_code, expired, convertible, issue_version, amended_since_issue, notes, terms_text')
            .eq('quote_id', id).maybeSingle(),
        'quote_status') as {
            quote_id: string; code: string; customer_code: string; customer_name: string
            quote_date: string; valid_until: string; currency: string; fx_rate: number
            status: string; decline_reason: string | null
            converted_order_id: string | null; converted_order_code: string | null
            expired: boolean; convertible: boolean; issue_version: number | null
            amended_since_issue: boolean; notes: string | null; terms_text: string | null } | null
    if (!q) notFound()

    const lines = mustRows(
        await supabase.from('quote_lines')
            .select('id, line_no, quantity, unit_price, price_source, material_id, materials ( code, name, unit )')
            .eq('quote_id', id).order('line_no'),
        'quote_lines') as unknown as {
            id: string; line_no: number; quantity: number; unit_price: number
            price_source: string | null; material_id: string
            materials: { code: string; name: string; unit: string } | null }[]

    const issues = mustRows(
        await supabase.from('qt_issues').select('version, sha256, issued_at')
            .eq('quote_id', id).order('version', { ascending: false }),
        'qt_issues') as { version: number; sha256: string; issued_at: string }[]

    const history = mustRows(
        await supabase.from('quote_history').select('change_type, detail, changed_at')
            .eq('quote_id', id).order('changed_at', { ascending: false }),
        'quote_history') as { change_type: string; detail: string | null; changed_at: string }[]

    const materials = mustRows(
        await supabase.from('materials').select('id, code, name')
            .is('deleted_at', null).order('code'),
        'materials') as unknown as { id: string; code: string; name: string }[]

    const canEdit = await can('module.sales.edit')
    const isConverted = q.status === 'converted'
    const isDeclined = q.status === 'declined'
    // 【转过、谢绝了的都不再编辑】前者由数据库的守卫兜底(QT_CONVERTED_IMMUTABLE),
    // 后者数据库并不拦 —— 但给一张已经被拒绝的报价改价,是在改一件已经结束的事,
    // 界面比数据库严一点是允许的,而这里是一个【决定】,不是漏了。
    const editable = canEdit && !isConverted && !isDeclined
    const total = lines.reduce((s, l) => s + Number(l.quantity) * Number(l.unit_price), 0)

    return (
        <>
            <Subnav />
            <div className="p-8 max-w-4xl">
                <div className="mb-6">
                    <Link href="/sales/quotes" className="text-blue-600 hover:underline text-sm">
                        {t('common.back')}
                    </Link>
                </div>
                <div className="flex items-start justify-between mb-4">
                    <div>
                        <h1 className="text-2xl font-bold font-mono">{q.code}</h1>
                        <p className="text-sm text-gray-600 mt-1">
                            {q.customer_code} — {q.customer_name}
                        </p>
                    </div>
                    <div className="flex items-center gap-2">
                        {q.expired && (
                            <span className="px-2 py-1 rounded text-xs bg-amber-100 text-amber-800">
                                {t('quotes.expired')}
                            </span>
                        )}
                        <span className="px-3 py-1 rounded bg-gray-200 text-sm">
                            {t(quoteStatusKey(q.status))}
                        </span>
                    </div>
                </div>

                {/* 【签发之后又改过】客户手里那份已经不是这一张了 —— 与销售订单
                    那条横幅同一个机制(两个时间戳一比,不是一个要人去清的标志位)*/}
                {q.amended_since_issue && (
                    <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-4">
                        {t('quotes.amendedSinceIssue')}
                    </div>
                )}
                {isConverted && (
                    <div className="bg-gray-50 border border-gray-300 text-gray-800 px-4 py-3 rounded mb-4">
                        {t('quotes.convertedBanner', { code: q.converted_order_code ?? '—' })}{' '}
                        {q.converted_order_id && (
                            <Link href={`/sales/orders/${q.converted_order_id}`}
                                  className="text-blue-600 hover:underline font-mono">
                                {q.converted_order_code}
                            </Link>
                        )}
                    </div>
                )}
                {isDeclined && (
                    <div className="bg-gray-50 border border-gray-300 text-gray-800 px-4 py-3 rounded mb-4">
                        {t('quotes.declinedBanner', { reason: q.decline_reason ?? '—' })}
                    </div>
                )}

                <dl className="grid grid-cols-2 gap-x-8 gap-y-1 text-sm mb-6">
                    <div><dt className="inline text-gray-500">{t('quotes.colQuoteDate')}: </dt>
                         <dd className="inline">{new Date(q.quote_date).toLocaleDateString(dl)}</dd></div>
                    <div><dt className="inline text-gray-500">{t('quotes.colValidUntil')}: </dt>
                         <dd className="inline">{new Date(q.valid_until).toLocaleDateString(dl)}</dd></div>
                    <div><dt className="inline text-gray-500">{t('sales.colCurrency')}: </dt>
                         <dd className="inline">{q.currency} @ {q.fx_rate}</dd></div>
                    <div><dt className="inline text-gray-500">{t('quotes.total')}: </dt>
                         <dd className="inline font-mono">{formatAmount(total, q.currency)}</dd></div>
                </dl>

                {/* ── 明细:签发之后仍然改得动 ─────────────────────────────── */}
                <QuoteLinesEditor
                    quoteId={q.quote_id}
                    currency={q.currency}
                    editable={editable}
                    reason={isConverted ? t('quotes.linesLockedConverted')
                            : isDeclined ? t('quotes.linesLockedDeclined')
                            : !canEdit ? `${t('common.restricted')} — ${t('quotes.needsSalesEdit')}` : ''}
                    lines={lines.map((l) => ({
                        id: l.id, line_no: l.line_no,
                        material: l.materials ? `${l.materials.code} — ${l.materials.name}` : '—',
                        unit: l.materials?.unit ?? '',
                        quantity: Number(l.quantity), unit_price: Number(l.unit_price),
                    }))}
                    materials={materials}
                />

                {/* ── 转换 / 谢绝 ──────────────────────────────────────────── */}
                <h2 className="font-medium mt-8 mb-2">{t('quotes.decide')}</h2>
                {!canEdit ? (
                    <p className="text-sm text-gray-600">
                        {t('common.restricted')} — {t('quotes.needsSalesEdit')}
                    </p>
                ) : (
                    <div className="space-y-3">
                        <ConvertControl
                            quoteId={q.quote_id}
                            code={q.code}
                            convertible={q.convertible}
                            status={q.status}
                            expired={q.expired}
                            validUntil={q.valid_until}
                            convertedOrderCode={q.converted_order_code}
                        />
                        {q.status === 'issued' && <DeclineControl quoteId={q.quote_id} />}
                    </div>
                )}

                {/* ── 签发 ─────────────────────────────────────────────────── */}
                <h2 className="font-medium mt-8 mb-2">{t('quotes.issues')}</h2>
                {q.amended_since_issue && (
                    <p className="text-sm text-amber-900 bg-amber-50 border border-amber-300 rounded px-3 py-2 mb-2">
                        {t('quotes.reissueHint')}
                    </p>
                )}
                <IssuePanel
                    quoteId={q.quote_id}
                    canIssue={canEdit && !isConverted && !isDeclined}
                    blockedReason={isConverted ? t('quotes.issueBlockedConverted')
                                   : isDeclined ? t('quotes.issueBlockedDeclined')
                                   : lines.length === 0 ? t('quotes.issueBlockedNoLines') : ''}
                    hasLines={lines.length > 0}
                />
                <p className="text-xs text-gray-500 mb-2">{t('quotes.issuesNote')}</p>
                {issues.length === 0 ? (
                    <p className="text-gray-500 text-sm">{t('quotes.noIssues')}</p>
                ) : (
                    <ul className="text-sm space-y-1">
                        {issues.map((i) => (
                            <li key={i.version} className="font-mono text-xs">
                                <a href={`/sales/quotes/${q.quote_id}/pdf?version=${i.version}`}
                                   target="_blank" rel="noopener noreferrer"
                                   className="text-blue-600 hover:underline">v{i.version}</a>
                                {' · '}{new Date(i.issued_at).toLocaleString(dl)} · {i.sha256.slice(0, 12)}…
                            </li>
                        ))}
                    </ul>
                )}

                <h2 className="font-medium mt-8 mb-2">{t('sales.history')}</h2>
                <ul className="text-sm space-y-1">
                    {history.map((h, i) => (
                        <li key={i} className="text-gray-600">
                            {new Date(h.changed_at).toLocaleString(dl)}
                            {/* 动态前缀,后缀集合接 quote_history 的 CHECK(check-i18n 的清单) */}
                            {' · '}{t('quotes.changeType.' + h.change_type)}
                            {h.detail ? ` · ${h.detail}` : ''}
                        </li>
                    ))}
                </ul>
            </div>
        </>
    )
}
