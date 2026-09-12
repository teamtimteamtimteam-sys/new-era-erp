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
import { quoteStatusKey } from '../quoteTypes'
import IssuePanel from '@/app/components/IssuePanel'
import { PermissionGate } from '@/app/components/ui/permission-gate'
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
    // ════════════════════════════════════════════════════════════════════════
    // ★★【ALERT-2d ①(2026-09-09)· 同一条表达式此前写了两遍】★★
    // ════════════════════════════════════════════════════════════════════════
    //   `canEdit && !isConverted && !isDeclined` 在这一页出现过【两次】——
    //   :81 的 `editable` 与 :195 的 `canIssue={…}`,逐字相同。
    //   **两份实现,而它们已经开始分开了:** `QuoteLinesEditor` 那一份的
    //   `reason` 有三支(转过 / 谢绝了 / 没有 module.sales.edit),
    //   `IssuePanel` 那一份的 `blockedReason` **只有两支** ——
    //   一个没有 `module.sales.edit` 的人看到的是一个按不下去的签发钮和一片空白。
    //   ☞ 所以"解决重复"这件事本身就修掉了一个真缺陷,不只是少写一行。
    //
    //   现在:记录状态那一半只算一次,权限那一半只写一次,两个消费者共用。
    const stateAllowsEdit = !isConverted && !isDeclined
    const editable = canEdit && stateAllowsEdit
    const total = lines.reduce((s, l) => s + Number(l.quantity) * Number(l.unit_price), 0)

    return (
        <>
            <div className="p-8 max-w-4xl">
                <div className="mb-6">
                    <Link href="/sales/quotes" className="hover:underline text-sm app-link">
                        {t('common.back')}
                    </Link>
                </div>
                <div className="flex items-start justify-between mb-4">
                    <div>
                        <h1>{q.code}</h1>
                        <p className="text-sm text-[color:var(--brand-muted-text)] mt-1">
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
                    <div className="bg-gray-50 border border-gray-300 text-[color:var(--brand-text)] px-4 py-3 rounded mb-4">
                        {t('quotes.convertedBanner', { code: q.converted_order_code ?? '—' })}{' '}
                        {q.converted_order_id && (
                            <Link href={`/sales/orders/${q.converted_order_id}`}
                                  className="hover:underline app-link app-link-inline">
                                {q.converted_order_code}
                            </Link>
                        )}
                    </div>
                )}
                {isDeclined && (
                    <div className="bg-gray-50 border border-gray-300 text-[color:var(--brand-text)] px-4 py-3 rounded mb-4">
                        {t('quotes.declinedBanner', { reason: q.decline_reason ?? '—' })}
                    </div>
                )}

                <dl className="grid grid-cols-2 gap-x-8 gap-y-1 text-sm mb-6">
                    <div><dt className="inline text-[color:var(--brand-muted-text)]">{t('quotes.colQuoteDate')}: </dt>
                         <dd className="inline">{new Date(q.quote_date).toLocaleDateString(dl)}</dd></div>
                    <div><dt className="inline text-[color:var(--brand-muted-text)]">{t('quotes.colValidUntil')}: </dt>
                         <dd className="inline">{new Date(q.valid_until).toLocaleDateString(dl)}</dd></div>
                    <div><dt className="inline text-[color:var(--brand-muted-text)]">{t('sales.colCurrency')}: </dt>
                         <dd className="inline">{q.currency} @ {q.fx_rate}</dd></div>
                    <div><dt className="inline text-[color:var(--brand-muted-text)]">{t('quotes.total')}: </dt>
                         <dd className="inline">{formatAmount(total, q.currency)}</dd></div>
                </dl>

                {/* ── 明细:签发之后仍然改得动 ─────────────────────────────── */}
                {(() => {
                    const lineProps = {
                        quoteId: q.quote_id,
                        currency: q.currency,
                        lines: lines.map((l) => ({
                            id: l.id, line_no: l.line_no,
                            material: l.materials ? `${l.materials.code} — ${l.materials.name}` : '—',
                            unit: l.materials?.unit ?? '',
                            quantity: Number(l.quantity), unit_price: Number(l.unit_price),
                        })),
                        materials,
                    }
                    // ★★ ALERT-2d ①:两半各归各。
                    //   记录状态那两句(转过 / 谢绝了)**一个字都没改** —— 它们今天说的就是对的。
                    //   权限那一支从 `reason` 里【搬走】,改由 <PermissionGate> 说,
                    //   因为它多说了一件今天缺的事:**这个码由管理员在 Settings → Roles 里给**
                    //   (而且与按下去被拒之后 SILENT-1 说的是同一句话)。
                    //   ☞ 顺带修掉一个藏:此前没有 module.sales.edit 的人看到的是一张
                    //     【干净的只读表】—— 增行、改价、删行三个控件整个不存在,
                    //     而 DBLOCK-1 裁定"看得见、按不动、说出为什么"。
                    return stateAllowsEdit ? (
                        <PermissionGate
                            code="module.sales.edit"
                            allowed={canEdit}
                            className="flex w-full items-stretch"
                        >
                            <QuoteLinesEditor {...lineProps} editable reason="" />
                        </PermissionGate>
                    ) : (
                        <QuoteLinesEditor
                            {...lineProps}
                            editable={false}
                            reason={isConverted ? t('quotes.linesLockedConverted') : t('quotes.linesLockedDeclined')}
                        />
                    )
                })()}

                {/* ── 转换 / 谢绝 ──────────────────────────────────────────── */}
                <h2 className="mt-8 mb-2">{t('quotes.decide')}</h2>
                {!canEdit ? (
                    <p className="text-sm text-[color:var(--brand-muted-text)]">
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
                <h2 className="mt-8 mb-2">{t('quotes.issues')}</h2>
                {q.amended_since_issue && (
                    <p className="text-sm text-amber-900 bg-amber-50 border border-amber-300 rounded px-3 py-2 mb-2">
                        {t('quotes.reissueHint')}
                    </p>
                )}
                <IssuePanel
                    pdfHref={`/sales/quotes/${q.quote_id}/pdf`}
                    previewLabel={t('quotes.previewPdf')}
                    issueLabel={t('quotes.issuePdf')}
                    // ★ ALERT-2d:同一条表达式不再写第二遍 —— 记录状态那一半
                    //   走 stateAllowsEdit,权限那一半走 permission(它此前
                    //   【没有对应的句子】,是这一刀补上的)。
                    canIssue={stateAllowsEdit}
                    permission={{ code: 'module.sales.edit', allowed: canEdit }}
                    blockedReason={isConverted ? t('quotes.issueBlockedConverted')
                                   : isDeclined ? t('quotes.issueBlockedDeclined') : ''}
                    // ★ ④(c):「一行都还没有」不是拒绝,是【还没有东西可签发】。
                    nothingToIssueNote={t('quotes.issueBlockedNoLines')}
                    hasLines={lines.length > 0}
                />
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('quotes.issuesNote')}</p>
                {issues.length === 0 ? (
                    <p className="text-[color:var(--brand-muted-text)] text-sm">{t('quotes.noIssues')}</p>
                ) : (
                    <ul className="text-sm space-y-1">
                        {issues.map((i) => (
                            <li key={i.version} className="text-xs text-[color:var(--brand-muted-text)]">
                                <a href={`/sales/quotes/${q.quote_id}/pdf?version=${i.version}`}
                                   target="_blank" rel="noopener noreferrer"
                                   className="hover:underline app-link app-link-inline">v{i.version}</a>
                                {' · '}{new Date(i.issued_at).toLocaleString(dl)} · {i.sha256.slice(0, 12)}…
                            </li>
                        ))}
                    </ul>
                )}

                <h2 className="mt-8 mb-2">{t('sales.history')}</h2>
                <ul className="text-sm space-y-1">
                    {history.map((h, i) => (
                        <li key={i} className="text-[color:var(--brand-muted-text)]">
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
