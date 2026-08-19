'use client'

import { useState, useTransition } from 'react'
import { saveForwarderDetails, addRateQuote, removeRateQuote } from './actions'

// LOG-1c:物流属性 + 报价。
//
// 【报价上【没有】任何"付款"或"入账"的手势,而这是有意的】——
// 报价记的是"他说要多少",它不产生分录、不产生应付。实际成本是运费凭证。
// 在报价旁边摆一个"付"按钮,就是让一份说过的话看起来像一笔负债。

type Details = { main_routes: string | null; ports_served: string | null; free_time_terms: string | null; dg_classes: string | null; notes: string | null } | null
type Quote = { id: string; lane_id: string; amount_ccy: string; currency: string; valid_from: string; valid_to: string }

export default function ForwarderPanels({
    supplierId, details, lanes, quotes, currencies, labels,
}: {
    supplierId: string
    details: Details
    lanes: { id: string; label: string }[]
    quotes: Quote[]
    currencies: string[]
    labels: Record<string, string>
}) {
    const [error, setError] = useState<string | null>(null)
    const [pending, start] = useTransition()
    const field = 'w-full rounded border border-gray-300 px-2 py-1 text-sm'
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
            })
            if ('error' in res) setError(res.error)
            else form.reset()
        })
    }

    return (
        <>
            {error && (
                <div className="mb-4 rounded border border-red-400 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}

            <section className="border-t pt-6">
                <h2 className="mb-3 text-xl font-bold">{labels.detailsHeading}</h2>
                <form onSubmit={onSaveDetails} className="max-w-3xl space-y-3">
                    <div>
                        <label className="block text-xs font-medium mb-1">{labels.mainRoutes}</label>
                        <input name="main_routes" defaultValue={details?.main_routes ?? ''} className={field} />
                    </div>
                    <div>
                        <label className="block text-xs font-medium mb-1">{labels.portsServed}</label>
                        <input name="ports_served" defaultValue={details?.ports_served ?? ''} className={field} />
                    </div>
                    <div>
                        <label className="block text-xs font-medium mb-1">{labels.freeTimeTerms}</label>
                        <input name="free_time_terms" defaultValue={details?.free_time_terms ?? ''} className={field} />
                    </div>
                    <div>
                        <label className="block text-xs font-medium mb-1">{labels.dgClasses}</label>
                        <input name="dg_classes" defaultValue={details?.dg_classes ?? ''} className={field} />
                    </div>
                    <div>
                        <label className="block text-xs font-medium mb-1">{labels.notes}</label>
                        <textarea name="notes" rows={2} defaultValue={details?.notes ?? ''} className={field} />
                    </div>
                    {/* 【联系人不在这里,而这是一句要说出来的话】,不是一个空白 */}
                    <p className="text-xs text-gray-500">{labels.contactsNote}</p>
                    <button type="submit" disabled={pending} className="rounded bg-blue-600 px-3 py-1 text-sm text-white disabled:opacity-50">
                        {labels.save}
                    </button>
                </form>
            </section>

            <section className="mt-8 border-t pt-6">
                <h2 className="mb-2 text-xl font-bold">{labels.quotesHeading}</h2>
                {/* 一份报价什么都不入账 —— 说在最显眼的地方 */}
                <p className="mb-3 max-w-3xl text-sm text-gray-600">{labels.booksNothing}</p>

                {lanes.length === 0 ? (
                    <p className="text-sm text-amber-900 bg-amber-50 border border-amber-300 rounded px-3 py-2 max-w-2xl">
                        {labels.noLanes}
                    </p>
                ) : (
                    <form onSubmit={onAddQuote} className="mb-4 flex flex-wrap items-end gap-2">
                        <div>
                            <label className="block text-xs font-medium mb-1">{labels.lane}</label>
                            <select name="lane_id" required className={field}>
                                {lanes.map((l) => <option key={l.id} value={l.id}>{l.label}</option>)}
                            </select>
                        </div>
                        <div>
                            <label className="block text-xs font-medium mb-1">{labels.amount}</label>
                            <input name="amount_ccy" type="number" step="0.01" min="0.01" required className={`${field} w-32`} />
                        </div>
                        <div>
                            <select name="currency" required className={field} defaultValue={currencies[0]}>
                                {currencies.map((c) => <option key={c} value={c}>{c}</option>)}
                            </select>
                        </div>
                        <div>
                            <label className="block text-xs font-medium mb-1">{labels.validFrom}</label>
                            <input name="valid_from" type="date" required className={field} />
                        </div>
                        <div>
                            <label className="block text-xs font-medium mb-1">{labels.validTo}</label>
                            <input name="valid_to" type="date" required className={field} />
                        </div>
                        <button type="submit" disabled={pending} className="rounded bg-blue-600 px-3 py-1 text-sm text-white disabled:opacity-50">
                            {labels.addQuote}
                        </button>
                    </form>
                )}

                {quotes.length === 0 ? (
                    <p className="text-sm text-gray-500">{labels.quotesEmpty}</p>
                ) : (
                    <div className="overflow-x-auto">
                        <table className="w-full border-collapse border border-gray-300 text-sm">
                            <tbody>
                                {quotes.map((q) => (
                                    <tr key={q.id}>
                                        <td className="border border-gray-300 px-3 py-1">{laneLabel.get(q.lane_id) ?? q.lane_id}</td>
                                        <td className="border border-gray-300 px-3 py-1 text-right">{q.amount_ccy} {q.currency}</td>
                                        <td className="border border-gray-300 px-3 py-1">{q.valid_from} → {q.valid_to}</td>
                                        <td className="border border-gray-300 px-3 py-1">
                                            <button
                                                type="button"
                                                disabled={pending}
                                                onClick={() => start(async () => {
                                                    const res = await removeRateQuote(supplierId, q.id)
                                                    if ('error' in res) setError(res.error)
                                                })}
                                                className="text-xs text-red-700 hover:underline"
                                            >
                                                {labels.removeQuote}
                                            </button>
                                        </td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    </div>
                )}
            </section>
        </>
    )
}
