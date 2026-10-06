'use client'

import { useState, useTransition } from 'react'
import { saveForwarderDetails, addRateQuote, removeRateQuote } from './actions'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { CONTROL_INPUT, CONTROL_SELECT, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'
import { DatePicker } from '@/app/components/ui/date-picker'
import { formatDate } from '@/lib/dates'
import { useLocale } from '@/lib/i18n/client'

// LOG-1c:物流属性 + 报价。
//
// 【报价上【没有】任何"付款"或"入账"的手势,而这是有意的】——
// 报价记的是"他说要多少",它不产生分录、不产生应付。实际成本是运费凭证。
// 在报价旁边摆一个"付"按钮,就是让一份说过的话看起来像一笔负债。

type Details = { main_routes: string | null; ports_served: string | null; free_time_terms: string | null; dg_classes: string | null; notes: string | null } | null
// free_days 是【三态】:数字 / null(报价没写)—— 不是 number 就是 null,
// 绝不用 0 顶替 null(列注释与 addRateQuote 里那段是同一条规矩)。
type Quote = { id: string; lane_id: string; amount_ccy: string; currency: string; valid_from: string; valid_to: string; free_days: number | null }

export default function ForwarderPanels({
    supplierId, details, lanes, quotes, currencies, labels,
canEdit
}: {
    supplierId: string
    details: Details
    lanes: { id: string; label: string }[]
    quotes: Quote[]
    currencies: string[]
    labels: Record<string, string>

canEdit: boolean
}) {
    const locale = useLocale()
    const [error, setError] = useState<string | null>(null)
    const [pending, start] = useTransition()
    // 日期框不认 form.reset()(它的字在 React 状态里)—— 加完一份报价换一个 key 让两个日期框回到空
    const [quoteKey, setQuoteKey] = useState(0)
    const field = `${CONTROL_INPUT} w-full`
    const fieldSelect = `${CONTROL_SELECT} w-full`
    const fieldTextarea = `${CONTROL_TEXTAREA} w-full`
    const laneLabel = new Map(lanes.map((l) => [l.id, l.label]))

    function onSaveDetails(e: React.FormEvent<HTMLFormElement>) {
        e.preventDefault()
        const fd = new FormData(e.currentTarget)
        setError(null)
        start(async () => {
            const res = await saveForwarderDetails(supplierId, {
                main_routes: (fd.get('main_routes') as string)?.trim() || null,
                ports_served: (fd.get('ports_served') as string)?.trim() || null,
                free_time_terms: (fd.get('free_time_terms') as string)?.trim() || null,
                dg_classes: (fd.get('dg_classes') as string)?.trim() || null,
                notes: (fd.get('notes') as string)?.trim() || null,
            })
            if ('error' in res) setError(res.error)
        })
    }

    function onAddQuote(e: React.FormEvent<HTMLFormElement>) {
        e.preventDefault()
        const form = e.currentTarget
        const fd = new FormData(form)
        setError(null)
        start(async () => {
            const res = await addRateQuote(supplierId, {
                lane_id: fd.get('lane_id') as string,
                amount_ccy: fd.get('amount_ccy') as string,
                currency: fd.get('currency') as string,
                valid_from: fd.get('valid_from') as string,
                valid_to: fd.get('valid_to') as string,
                // 【原样送下去,不在这里折算】空字符串的含义由服务端那一处判 ——
                // 两处各判一次,迟早各说各话。
                free_days: (fd.get('free_days') as string) ?? '',
            })
            if ('error' in res) setError(res.error)
            else { form.reset(); setQuoteKey((k) => k + 1) }
        })
    }

    function onRemoveQuote(quoteId: string) {
        setError(null)
        start(async () => {
            const res = await removeRateQuote(supplierId, quoteId)
            if ('error' in res) setError(res.error)
        })
    }

    // UNBLOCK-1 Q16:裸 <table> → 共享 DataTable。手机上留航段(身份)与操作列;
    // 操作列画的是【要按的控件】,按 R1 必须 priority —— 折进展开区就等于够不着。
    const quoteColumns: Column<Quote>[] = [
        { key: 'lane', header: labels.lane, priority: true, render: (q) => laneLabel.get(q.lane_id) ?? q.lane_id },
        {
            key: 'amount', header: labels.amount, align: 'right', singleValue: true, className: 'tabular-nums',
            render: (q) => `${q.amount_ccy} ${q.currency}`,
        },
        { key: 'validFrom', header: labels.validFrom, singleValue: true, render: (q) => formatDate(q.valid_from, locale) },
        { key: 'validTo', header: labels.validTo, singleValue: true, render: (q) => formatDate(q.valid_to, locale) },
        {
            // 【三态各有各的样子】数字 / "未写明"。空单元格会被读成 0,而 0 是另一件事。
            key: 'freeDays', header: labels.freeDays, align: 'right', singleValue: true, className: 'tabular-nums',
            render: (q) => q.free_days === null
                ? <span className="text-gray-500 italic">{labels.freeDaysNotStated}</span>
                : q.free_days,
        },
        {
            key: 'actions', header: '', priority: true, className: 'whitespace-nowrap',
            render: (q) => (
                <PermissionGate code="module.purchasing.edit" allowed={canEdit}>
                    {/* 这一列每行都长得一样,所以确认框要说出【哪一份】—— 航段 + 金额 + 有效期 */}
                    <ConfirmButton
                        subject={`${laneLabel.get(q.lane_id) ?? q.lane_id} · ${q.amount_ccy} ${q.currency} · ${formatDate(q.valid_from, locale)} → ${formatDate(q.valid_to, locale)}`}
                        title={labels.removeQuoteConfirm}
                        body={labels.removeQuoteConfirmBody}
                        confirmLabel={labels.removeQuote}
                        tier="destructive"
                        disabled={pending}
                        triggerVariant="destructive" triggerSize="inline"
                        className="text-xs"
                        onConfirm={() => onRemoveQuote(q.id)}
                    >
                        {labels.removeQuote}
                    </ConfirmButton>
                </PermissionGate>
            ),
        },
    ]

    return (
        <>
            {error && (
                <div className="mb-4 rounded border border-red-400 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}

            <section className="border-t pt-6">
                <h2 className="mb-3">{labels.detailsHeading}</h2>
                <form onSubmit={onSaveDetails} className="max-w-3xl space-y-3">
                    <div>
                        <label className="block mb-1">{labels.mainRoutes}</label>
                        <input name="main_routes" defaultValue={details?.main_routes ?? ''} className={field} />
                    </div>
                    <div>
                        <label className="block mb-1">{labels.portsServed}</label>
                        <input name="ports_served" defaultValue={details?.ports_served ?? ''} className={field} />
                    </div>
                    <div>
                        <label className="block mb-1">{labels.freeTimeTerms}</label>
                        <input name="free_time_terms" defaultValue={details?.free_time_terms ?? ''} className={field} />
                    </div>
                    <div>
                        <label className="block mb-1">{labels.dgClasses}</label>
                        <input name="dg_classes" defaultValue={details?.dg_classes ?? ''} className={field} />
                    </div>
                    <div>
                        <label className="block mb-1">{labels.notes}</label>
                        <textarea name="notes" defaultValue={details?.notes ?? ''} className={fieldTextarea} />
                    </div>
                    {/* 【联系人不在这里,而这是一句要说出来的话】,不是一个空白 */}
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{labels.contactsNote}</p>
                    <Button variant="default" className="text-sm" type="submit" disabled={pending}>
                        {labels.save}
                    </Button>
                </form>
            </section>

            <section className="mt-8 border-t pt-6">
                <h2 className="mb-2">{labels.quotesHeading}</h2>
                {/* 一份报价什么都不入账 —— 说在最显眼的地方 */}
                <p className="mb-3 max-w-3xl text-sm text-[color:var(--brand-muted-text)]">{labels.booksNothing}</p>

                {lanes.length === 0 ? (
                    <p className="text-sm text-amber-900 bg-amber-50 border border-amber-300 rounded px-3 py-2 max-w-2xl">
                        {labels.noLanes}
                    </p>
                ) : (
                    <form onSubmit={onAddQuote} className="mb-4 flex flex-wrap items-end gap-2">
                        <div>
                            <label className="block mb-1">{labels.lane}</label>
                            <select name="lane_id" required className={fieldSelect}>
                                {lanes.map((l) => <option key={l.id} value={l.id}>{l.label}</option>)}
                            </select>
                        </div>
                        <div>
                            <label className="block mb-1">{labels.amount}</label>
                            <input name="amount_ccy" type="number" step="0.01" min="0.01" required className={`${field} w-32`} />
                        </div>
                        <div>
                            <select name="currency" required className={fieldSelect} defaultValue={currencies[0]}>
                                {currencies.map((c) => <option key={c} value={c}>{c}</option>)}
                            </select>
                        </div>
                        <div>
                            <label className="block mb-1">{labels.validFrom}</label>
                            <DatePicker key={`from-${quoteKey}`} name="valid_from" required className="flex" />
                        </div>
                        <div>
                            <label className="block mb-1">{labels.validTo}</label>
                            <DatePicker key={`to-${quoteKey}`} name="valid_to" required className="flex" />
                        </div>
                        {/* 【不是 required】—— 留空是一个正当答案("这份报价没写免柜期"),
                            不是漏填。min=0 允许真正的 0,而 0 与留空是两件不同的事。 */}
                        <div>
                            <label className="block mb-1">{labels.freeDays}</label>
                            <input name="free_days" type="number" step="1" min="0"
                                className={`${field} w-24`} />
                        </div>
                        <Button variant="default" className="text-sm" type="submit" disabled={pending}>
                            {labels.addQuote}
                        </Button>
                        <p className="mt-1 w-full text-xs text-[color:var(--brand-muted-text)] max-w-3xl">{labels.freeDaysHint}</p>
                    </form>
                )}

                {/* 【报价没有"改"这扇门】—— 只有新增与撤回(软删)。说出来,
                    否则人会在列表里找一个不存在的编辑按钮。 */}
                <p className="mb-3 text-xs text-[color:var(--brand-muted-text)] max-w-3xl">{labels.noEditDoor}</p>

                {quotes.length === 0 ? (
                    <p className="text-sm text-[color:var(--brand-muted-text)]">{labels.quotesEmpty}</p>
                ) : (
                    <DataTable
                        rows={quotes}
                        columns={quoteColumns}
                        rowKey={(q) => q.id}
                        phone={{ mode: 'columns' }}
                    />
                )}
            </section>
        </>
    )
}
