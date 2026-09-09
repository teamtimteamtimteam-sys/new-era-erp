'use client'

// PUR-2:修改采购单的表单。
//
// 【本表单不自己判断能不能改】守卫在触发器上,拒绝由 DB 点名。这里做的只有两件事:
//   * 把【已收多少】写在行上 —— 下限要在动手之前看得见,而不是保存之后才被拒(CMP-2);
//   * 理由必填 —— 一次改动没有理由,历史上就只是一行"数字变了"。
// 真正的把关仍在 DB:表单上的提示是【礼貌】,不是保护。
import { useActionState, useState } from 'react'
import Link from 'next/link'
import { amendOrder, type AmendState } from './actions'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { triggerLabel, type PaymentTriggerEvent } from '@/lib/paymentTriggers'
import DecimalInput from '@/app/components/forms/DecimalInput'
import { Button } from '@/app/components/ui/button'

export type AmendLine = {
    id: string
    line_no: number
    quantity: number
    unit: string
    estimated_unit_price: number | null
    received: number
    // PUR-1:这一行现在的定价状态选择('' = 按事实推导),以及它挂没挂公式。
    price_status: 'fixed' | 'provisional' | ''
    has_formula: boolean
}

/** PUR-1:一期付款 —— 形状与建单那一侧的 OrderTermInput 同族。 */
export type AmendTerm = {
    seq: number
    label: string
    mode: 'percentage' | 'fixed'
    percentage: string
    fixed_amount: string
    trigger_event: string
    due_date: string
}

const initialState: AmendState = {}

export default function AmendOrderForm({
    poId, code, status, currency, orderDate, expectedDelivery, incoterm, notes,
    deliveryLocation, lines, terms: initialTerms, triggers,
}: {
    poId: string; code: string; status: string; currency: string
    orderDate: string; expectedDelivery: string; incoterm: string; notes: string
    deliveryLocation: string
    lines: AmendLine[]
    terms: AmendTerm[]
    triggers: PaymentTriggerEvent[]
}) {
    const t = useTranslations()
    const locale = useLocale()
    const amendWithId = amendOrder.bind(null, poId)
    const [state, formAction, isPending] = useActionState(amendWithId, initialState)
    const [qty, setQty] = useState<Record<string, string>>(
        () => Object.fromEntries(lines.map((l) => [l.id, String(l.quantity)])))
    const [price, setPrice] = useState<Record<string, string>>(
        () => Object.fromEntries(lines.map((l) => [l.id, l.estimated_unit_price === null ? '' : String(l.estimated_unit_price)])))
    const [remove, setRemove] = useState<Record<string, boolean>>({})
    const [priceStatus, setPriceStatus] = useState<Record<string, string>>(
        () => Object.fromEntries(lines.map((l) => [l.id, l.price_status])))
    // ── PUR-1:付款计划 ─────────────────────────────────────────────────────
    // ★【默认【不】改它,而这是刻意的】★ 一次只想改数量的修改,不该顺手把
    //   付款计划一起提交上去 —— 不勾这个框,actions 就不传那个参数,而 DB 那一侧
    //   NULL = 不动它。勾上之后传的是【下面这份完整的计划】(空的也算数:
    //   把所有期数删光并提交,就是明说"这张单没有分期计划了")。
    const [editTerms, setEditTerms] = useState(false)
    const [terms, setTerms] = useState<AmendTerm[]>(initialTerms)
    const patchTerm = (i: number, p: Partial<AmendTerm>) =>
        setTerms((ts) => ts.map((x, j) => (j === i ? { ...x, ...p } : x)))

    // 已结束/已作废的单不能改 —— 服务端会拒,页面不摆一个注定失败的按钮
    const frozen = status === 'closed' || status === 'cancelled'

    return (
        <div className="max-w-4xl">
            <div className="mb-6">
                <Link href={`/purchasing/orders/${poId}`} className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="text-2xl font-bold mb-2">{t('purchasing.amend.title', { code })}</h1>
            <p className="text-sm text-gray-600 mb-6 max-w-3xl">{t('purchasing.amend.intro')}</p>

            {frozen && (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-4">
                    {t('purchasing.amend.frozen', { status: t('purchasing.status.' + status) })}
                </div>
            )}
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            <form action={formAction} className="space-y-4">
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('purchasing.amend.reason')} <span className="text-red-600">*</span>
                    </label>
                    <input type="text" name="reason" required disabled={frozen}
                        className="w-full border border-gray-300 px-3 py-2 rounded" />
                    <p className="text-xs text-gray-500 mt-1">{t('purchasing.amend.reasonHint')}</p>
                </div>

                <div className="flex flex-wrap gap-4">
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('purchasing.amend.orderDate')}</label>
                        <input type="date" name="order_date" defaultValue={orderDate} disabled={frozen}
                            className="border border-gray-300 px-3 py-2 rounded" />
                        {/* 改单据日会重取牌价 —— 缺牌价即拒,绝不编一个 */}
                        <p className="text-xs text-gray-500 mt-1">{t('purchasing.amend.orderDateHint')}</p>
                    </div>
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('purchasing.amend.expected')}</label>
                        <input type="date" name="expected_delivery_date" defaultValue={expectedDelivery}
                            disabled={frozen} className="border border-gray-300 px-3 py-2 rounded" />
                    </div>
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('purchasing.amend.incoterm')}</label>
                        <input type="text" name="incoterm" defaultValue={incoterm} disabled={frozen}
                            className="border border-gray-300 px-3 py-2 rounded" />
                    </div>
                    {/* PUR-1:交货地点 —— 清空它是一次正当的修改,所以空串照样提交
                        (服务端靠"键在不在"分开"不动它"与"清掉它")。 */}
                    <div className="flex-1 min-w-[16rem]">
                        <label className="block text-sm font-medium mb-1">{t('purchasing.form.deliveryLocation')}</label>
                        <input type="text" name="delivery_location" defaultValue={deliveryLocation}
                            disabled={frozen} className="w-full border border-gray-300 px-3 py-2 rounded" />
                    </div>
                </div>

                {/* ════════════════════════════════════════════════════════════════
                    ★ TABLE-PHONE-4:六列 → 手机档留四列(# · 数量 · 单价 · 价格)。
                    被拿掉的两列(已收 / 删除)一个字段都没丢:带着各自的列头叠在
                    第一格(行号)里 —— ★ 这张表【没有物料列】,行号是它唯一的身份,
                    所以折叠块只能挂在它下面,而它本来就是这一行对外的号码。
                    ☞ 留的三个都是要动手的:数量、单价、定价状态。已收是个读的数,
                      而且真要用到它的那一刻(数量低于已收)那句告警本来就印在数量框底下。
                    ★★【这三列留在明面上不是偏好,是正确性】★★
                      line_quantity / line_price / line_price_status 是三条【并列数组】
                      (见下面 PUR-1 那段原注)。折叠一列是用 CSS 藏,【藏起来的 input
                      照样提交】—— 画两遍就是每行往数组里多塞一格,整组配对当场错位,
                      而那正是 PUR-1 刚修掉的那个错位。带 name 的一个都没被复制。
                      删除那个复选框【不带 name】(值由第一格渲染一次的 hidden
                      line_remove 携带),所以它是这张表里唯一能安全画两份的控件。
                    ★【# 的列头是硬编码的 "#",没有 i18n key】—— 留在明面上,一句都不用造。
                    ════════════════════════════════════════════════════════════════ */}
                <table className="w-full border-collapse border border-gray-300">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-2 sm:px-3 py-2 text-left">#</th>
                            <th className="border border-gray-300 px-2 sm:px-3 py-2 text-right">{t('purchasing.amend.colQty')}</th>
                            <th className="hidden sm:table-cell border border-gray-300 px-3 py-2 text-right">{t('purchasing.amend.colReceived')}</th>
                            <th className="border border-gray-300 px-2 sm:px-3 py-2 text-right">{t('purchasing.amend.colPrice', { ccy: currency })}</th>
                            <th className="border border-gray-300 px-2 sm:px-3 py-2 text-left">{t('purchasing.form.priceStatus')}</th>
                            <th className="hidden sm:table-cell border border-gray-300 px-3 py-2 text-left">{t('purchasing.amend.colRemove')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {/* ★★【PUR-1 顺手修掉的一处既有缺陷 —— 而它是本刀【必须】修的】★★
                            【症状】勾掉一条行、同时改另一条行的数量,那条【没被勾掉】的行
                            会以 quantity = null 提交,被 DB 按名拒(PO_LINE_QUANTITY_INVALID)。
                            【成因】服务端按【并列数组】对齐(line_id / line_quantity /
                            line_price / line_remove 各一份,按下标配对),而
                            DecimalInput 的 hidden input 带着 disabled —— 一个 disabled
                            的字段【根本不提交】。于是被勾掉那一行在 line_quantity 里
                            没有位置,它【后面】每一行的下标全部前移一格。
                            (勾掉最后一行时不会发作 —— 所以它活到了今天。)
                            【为什么本刀必须修】PUR-1 在这里加的是【第三条并列数组】
                            (line_price_status)。不修就是把同一个错位再复制一份。
                            【怎么修】不再按"这一行要删"去禁用输入框:那个禁用是纯装饰
                            (整行本来就已经变灰,而且它马上要被删掉),代价却是让
                            提交上去的数组少一格。frozen 那一半保留 —— 那时整张表单
                            连提交钮都是禁用的,不会有半份负载被送出去。 */}
                        {lines.map((l) => {
                            const below = Number(qty[l.id] || 0) < l.received && !remove[l.id]
                            // ★ TABLE-PHONE-4:两档共用的两份内容【提出来写一次】——
                            //   抄成两份就是让两份将来各走各的,而漂移在桌面上看不见。
                            const receivedText = <>{l.received} {l.unit}</>
                            const removeControl = (
                                <label className="text-sm">
                                    <input type="checkbox" checked={!!remove[l.id]} disabled={frozen || l.received > 0}
                                        onChange={(e) => setRemove((r) => ({ ...r, [l.id]: e.target.checked }))} />
                                    {/* 收过货的行删不掉 —— 复选框直接禁用并说明 */}
                                    <span className="ml-1">
                                        {l.received > 0 ? t('purchasing.amend.cannotRemove') : t('purchasing.amend.remove')}
                                    </span>
                                </label>
                            )
                            return (
                                <tr key={l.id} className={remove[l.id] ? 'bg-gray-100 text-gray-400' : ''}>
                                    <td className="border border-gray-300 px-2 sm:px-3 py-2">
                                        {l.line_no}
                                        <input type="hidden" name="line_id" value={l.id} />
                                        <input type="hidden" name="line_remove" value={remove[l.id] ? '1' : '0'} />
                                        {/* ★ TABLE-PHONE-4:手机档拿掉的两列,带着各自的列头叠在这里。
                                            删除是能点的控件,所以它单独占一行、标签在左、控件在右 ——
                                            一个被挤在窄缝里的复选框不算"还能用"。 */}
                                        <div className="sm:hidden mt-1 space-y-1 font-sans text-xs text-gray-600">
                                            <div className="font-mono">
                                                <span className="font-sans text-gray-500">{t('purchasing.amend.colReceived')}: </span>
                                                {receivedText}
                                            </div>
                                            <div className="flex items-baseline gap-1">
                                                <span className="text-gray-500 shrink-0">{t('purchasing.amend.colRemove')}: </span>
                                                {removeControl}
                                            </div>
                                        </div>
                                    </td>
                                    <td className="border border-gray-300 px-2 sm:px-3 py-2 text-right">
                                        <DecimalInput name="line_quantity" value={qty[l.id] ?? ''}
                                            onChange={(raw) => setQty((q) => ({ ...q, [l.id]: raw }))}
                                            disabled={frozen}
                                            className="w-28 border border-gray-300 px-2 py-1 rounded text-right" />
                                        {/* 下限写在行上 —— 保存之后才被拒是最差的一种告知 */}
                                        {below && (
                                            <p className="text-xs text-red-600 mt-1">
                                                {t('purchasing.amend.belowReceived', { received: l.received })}
                                            </p>
                                        )}
                                    </td>
                                    <td className="hidden sm:table-cell border border-gray-300 px-3 py-2 text-right font-mono text-sm text-gray-600">
                                        {receivedText}
                                    </td>
                                    <td className="border border-gray-300 px-2 sm:px-3 py-2 text-right">
                                        <DecimalInput name="line_price" value={price[l.id] ?? ''}
                                            onChange={(raw) => setPrice((p) => ({ ...p, [l.id]: raw }))}
                                            disabled={frozen}
                                            className="w-28 border border-gray-300 px-2 py-1 rounded text-right" />
                                    </td>
                                    {/* PUR-1:定价状态。挂了公式的行【标不成定价】——
                                        禁用并把理由摆在旁边(CMP-2 的规矩);把关在
                                        guard_po_line_price_status 那道闸上。 */}
                                    <td className="border border-gray-300 px-2 sm:px-3 py-2">
                                        <select name="line_price_status" value={priceStatus[l.id] ?? ''}
                                            disabled={frozen}
                                            onChange={(e) => setPriceStatus((p) => ({ ...p, [l.id]: e.target.value }))}
                                            className="border border-gray-300 px-2 py-1 rounded text-sm">
                                            <option value="">{t('purchasing.form.priceStatusDerive')}</option>
                                            <option value="fixed" disabled={l.has_formula}>
                                                {t('purchasing.form.priceStatusFixed')}
                                            </option>
                                            <option value="provisional">{t('purchasing.form.priceStatusProvisional')}</option>
                                        </select>
                                        {l.has_formula && (
                                            <p className="text-xs text-gray-500 mt-1 max-w-40">
                                                {t('purchasing.form.priceStatusFormulaHint')}
                                            </p>
                                        )}
                                    </td>
                                    <td className="hidden sm:table-cell border border-gray-300 px-3 py-2">
                                        {removeControl}
                                    </td>
                                </tr>
                            )
                        })}
                    </tbody>
                </table>

                {/* ── PUR-1:付款条款 ────────────────────────────────────────
                    【此前改不了,而那不是一道锁】—— 没有参数、没有字段,
                    而 purchase_order_payment_terms 的策略对持采购编辑权的人全开:
                    这条路一直通着,只是走它要直连改库,而且【在档案里完全沉默】。
                    本刀把入口建出来,同时把档案扩到接得住它
                    (trg_po_history_payment_term)。理由与其余修改共用上面那一个。 */}
                <div className="border border-gray-300 rounded p-4">
                    <label className="flex items-center gap-2 text-sm font-medium">
                        <input type="checkbox" name="edit_terms" value="1" checked={editTerms}
                            disabled={frozen}
                            onChange={(e) => setEditTerms(e.target.checked)} />
                        {t('purchasing.amend.editTerms')}
                    </label>
                    <p className="text-xs text-gray-500 mt-1">{t('purchasing.amend.editTermsHint')}</p>

                    {editTerms && (
                        <div className="mt-3 space-y-2">
                            {terms.length === 0 && (
                                <p className="text-xs text-amber-800 bg-amber-50 border border-amber-300 rounded px-3 py-2">
                                    {t('purchasing.amend.termsEmptyWarning')}
                                </p>
                            )}
                            {terms.map((tm, i) => (
                                <div key={i} className="flex flex-wrap items-end gap-2 border-b border-gray-200 pb-2">
                                    <span className="font-mono text-sm text-gray-500 pb-2">{i + 1}.</span>
                                    <div>
                                        <label className="block text-xs text-gray-600 mb-1">{t('purchasing.form.termLabel')}</label>
                                        <input type="text" name="term_label" value={tm.label} disabled={frozen}
                                            onChange={(e) => patchTerm(i, { label: e.target.value })}
                                            className="w-40 border border-gray-300 px-2 py-1.5 rounded" />
                                    </div>
                                    <div>
                                        <label className="block text-xs text-gray-600 mb-1">{t('purchasing.form.termMode')}</label>
                                        <select name="term_mode" value={tm.mode} disabled={frozen}
                                            onChange={(e) => patchTerm(i, { mode: e.target.value as 'percentage' | 'fixed' })}
                                            className="w-28 border border-gray-300 px-2 py-1.5 rounded">
                                            <option value="percentage">%</option>
                                            <option value="fixed">{currency}</option>
                                        </select>
                                    </div>
                                    <div>
                                        <label className="block text-xs text-gray-600 mb-1">
                                            {tm.mode === 'percentage' ? '%' : currency}
                                        </label>
                                        {/* 【两个输入框都在 DOM 里,而只有一个可见】—— 并列数组按
                                            出现顺序对齐,少一个就会整体错位。隐藏那一个仍然提交,
                                            但服务端按 mode 只读它该读的那一个。 */}
                                        <input type="text" name="term_percentage" value={tm.percentage}
                                            disabled={frozen}
                                            onChange={(e) => patchTerm(i, { percentage: e.target.value })}
                                            className={'w-24 border border-gray-300 px-2 py-1.5 rounded text-right ' +
                                                (tm.mode === 'percentage' ? '' : 'hidden')} />
                                        <input type="text" name="term_fixed" value={tm.fixed_amount}
                                            disabled={frozen}
                                            onChange={(e) => patchTerm(i, { fixed_amount: e.target.value })}
                                            className={'w-24 border border-gray-300 px-2 py-1.5 rounded text-right ' +
                                                (tm.mode === 'fixed' ? '' : 'hidden')} />
                                    </div>
                                    <div>
                                        <label className="block text-xs text-gray-600 mb-1">{t('purchasing.form.termTrigger')}</label>
                                        <select name="term_event" value={tm.trigger_event} disabled={frozen}
                                            onChange={(e) => patchTerm(i, { trigger_event: e.target.value })}
                                            className="w-44 border border-gray-300 px-2 py-1.5 rounded">
                                            {triggers.map((ev) => (
                                                <option key={ev.code} value={ev.code}>{triggerLabel(ev, locale)}</option>
                                            ))}
                                        </select>
                                    </div>
                                    <div>
                                        <label className="block text-xs text-gray-600 mb-1">{t('purchasing.form.termDue')}</label>
                                        <input type="date" name="term_due" value={tm.due_date} disabled={frozen}
                                            onChange={(e) => patchTerm(i, { due_date: e.target.value })}
                                            className="border border-gray-300 px-2 py-1.5 rounded" />
                                    </div>
                                    <Button variant="secondary" size="inline" type="button" disabled={frozen}
                                        onClick={() => setTerms((ts) => ts.filter((_, j) => j !== i))}
                                        className="text-sm mb-1">
                                        {t('purchasing.amend.removeTerm')}
                                    </Button>
                                </div>
                            ))}
                            <Button variant="secondary" size="inline" type="button" disabled={frozen}
                                onClick={() => setTerms((ts) => [...ts, {
                                    seq: ts.length + 1, label: '', mode: 'percentage',
                                    percentage: '', fixed_amount: '',
                                    trigger_event: triggers[0]?.code ?? '', due_date: '',
                                }])}
                                className="text-sm">
                                {t('purchasing.amend.addTerm')}
                            </Button>
                        </div>
                    )}
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('purchasing.amend.notes')}</label>
                    <textarea name="notes" rows={2} defaultValue={notes} disabled={frozen}
                        className="w-full border border-gray-300 px-3 py-2 rounded" />
                </div>

                <div className="flex gap-3 pt-2">
                    <Button type="submit" disabled={isPending || frozen}>
                        {isPending ? t('common.saving') : t('purchasing.amend.submit')}
                    </Button>
                    <Button asChild variant="secondary">
                        <Link href={`/purchasing/orders/${poId}`}>
                            {t('common.cancel')}
                        </Link>
                    </Button>
                </div>
            </form>
        </div>
    )
}
