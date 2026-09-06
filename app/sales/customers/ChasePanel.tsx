'use client'

// app/sales/customers/ChasePanel.tsx
// CHASE-1:客户档案页上的【催收记录】那一段 —— 这条路唯一的入口。
//
// ★【为什么在这里】★ 客户状况页已经是"这个客户的财务仓位"那一屏:身份、
// 信用限额、敞口、未结明细,以及 STATEMENT-1 加上的对账单。催收就是【拿着
// 这个仓位去打那通电话】,而打电话的人需要的每一样东西都已经在这一页上。
// 另起一张催收页要新的导航入口、新的可达性,还要把客户上下文再拼一遍 ——
// 而跨客户的催收工作台真正难的地方是【先催谁】(最久的?最大的?毁过约的?),
// 那是一个还没有答案的排序问题,不该顺手塞进这一刀。
// 逾期的承诺由 operations_now 第 31 支托上首页,不需要一张新页面。
//
// 【冻结的数与今天的数【并排】,谁也不替换谁】—— 与 bank_reconciliations 同一条。
// 一条催收记录里的"欠多少"是【当时告诉客户的那个数】;今天的余额是另一件事。
// 只显示前者会让人拿着过期数字打电话,只显示后者会让记录说不出当时谈的是什么。
import { useState, useTransition } from 'react'
import { recordChase, recordPromiseOutcome } from './chaseActions'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'

type OpenPromise = {
    promise_id: string; chase_id: string; chase_code: string; chased_on: string
    promised_amount_ccy: number; currency: string; promised_amount_base: number
    promised_date: string; is_overdue: boolean; applied_since_base: number
}

type Chase = {
    id: string; code: string; chased_on: string; channel: string
    reached: boolean; contacted_person: string | null; summary: string
    owed_base: number; superseded_at: string | null
    promise: { promised_amount_ccy: number; currency: string
               promised_date: string; outcome: string | null } | null
    documents: { subject_type: string; subject_code: string | null }[]
}

const CHANNELS = ['phone', 'email', 'whatsapp', 'in_person', 'letter'] as const
const OUTCOMES = ['kept', 'broken', 'renegotiated', 'cancelled'] as const

const money = (n: number) =>
    n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

const today = () => {
    const d = new Date()
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

export default function ChasePanel({
    customerId, chases, openPromises, owedToday, baseCurrency, canEdit,
}: {
    customerId: string
    chases: Chase[]
    openPromises: OpenPromise[]
    owedToday: number
    baseCurrency: string
    canEdit: boolean
}) {
    const t = useTranslations()
    const [open, setOpen] = useState(false)
    // 【日期【不】预填成今天】AGENTS.md:一个记录"世界上哪一天发生了什么"的
    // 日期,预填就是奖励留空 —— 服务端也独立地拒空(合取,不是二选一)。
    const [chasedOn, setChasedOn] = useState('')
    const [channel, setChannel] = useState<string>('phone')
    const [reached, setReached] = useState(true)
    const [person, setPerson] = useState('')
    const [summary, setSummary] = useState('')
    const [wantPromise, setWantPromise] = useState(false)
    const [amount, setAmount] = useState('')
    const [currency, setCurrency] = useState(baseCurrency)
    const [promisedDate, setPromisedDate] = useState('')
    const [error, setError] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()

    const run = (fn: () => Promise<{ error?: string }>) => {
        setError(null)
        startTransition(async () => {
            const r = await fn()
            if (r.error) setError(r.error)
            else setOpen(false)
        })
    }

    // 提交控件在必填项为空时【禁用】,而服务端【独立地】拒空 —— 两道,不是一道。
    const canSubmit = chasedOn !== '' && summary.trim() !== ''
        && (!wantPromise || (amount !== '' && promisedDate !== ''))

    return (
        <section className="mb-8">
            <h2 className="text-lg font-semibold mb-2">{t('chases.sectionTitle')}</h2>
            <p className="text-xs text-gray-500 mb-3">{t('chases.sectionHint')}</p>

            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">
                    {error}
                </div>
            )}

            {/* ── 还没了结的承诺:每一个带着它自己的【证据】 ──────────────── */}
            {openPromises.length > 0 && (
                <div className="mb-4 rounded border border-amber-300 bg-amber-50 p-3">
                    <h3 className="text-sm font-semibold mb-2">{t('chases.promisesOpen')}</h3>
                    {openPromises.map((p) => (
                        <div key={p.promise_id} className="mb-3 last:mb-0 text-sm">
                            <div className="flex flex-wrap items-baseline gap-2">
                                <span className="font-mono">{p.promised_amount_ccy.toLocaleString()} {p.currency}</span>
                                <span className="text-gray-600">→ {p.promised_date}</span>
                                {p.is_overdue && (
                                    <span className="px-1.5 py-0.5 rounded text-[11px] bg-red-200 text-red-900">
                                        {t('chases.promiseOverdue')}
                                    </span>
                                )}
                                <span className="text-xs text-gray-500 font-mono">{p.chase_code}</span>
                            </div>
                            <p className="text-xs text-gray-700 mt-1">
                                {t('chases.appliedSince')}:{' '}
                                <span className="font-mono">{money(p.applied_since_base)} {baseCurrency}</span>
                            </p>
                            <p className="text-[11px] text-gray-500">{t('chases.appliedSinceHint')}</p>
                            {canEdit && (
                                <div className="mt-1 flex flex-wrap gap-1">
                                    {OUTCOMES.map((o) => (
                                        <Button variant="secondary" size="xs" key={o} type="button" disabled={pending}
                                            onClick={() => run(() =>
                                                recordPromiseOutcome(customerId, p.promise_id, o, null))}>
                                            {t('chases.outcome_' + o)}
                                        </Button>
                                    ))}
                                </div>
                            )}
                        </div>
                    ))}
                </div>
            )}

            {canEdit && !open && (
                <Button className="mb-4" type="button" onClick={() => setOpen(true)}>
                    {t('chases.record')}
                </Button>
            )}

            {canEdit && open && (
                <div className="mb-4 rounded border border-gray-300 p-3 max-w-2xl">
                    <div className="flex flex-wrap gap-3 mb-3">
                        <label className="text-sm text-gray-600">
                            {t('chases.chasedOn')}
                            <input type="date" value={chasedOn} max={today()}
                                onChange={(e) => setChasedOn(e.target.value)}
                                className="block rounded border border-gray-300 bg-white px-3 py-2" />
                            <span className="block text-[11px] text-gray-500">{t('chases.chasedOnHint')}</span>
                        </label>
                        <label className="text-sm text-gray-600">
                            {t('chases.channel')}
                            <select value={channel} onChange={(e) => setChannel(e.target.value)}
                                className="block rounded border border-gray-300 bg-white px-3 py-2">
                                {CHANNELS.map((c) => (
                                    <option key={c} value={c}>{t('chases.channel_' + c)}</option>
                                ))}
                            </select>
                        </label>
                        <label className="text-sm text-gray-600 self-end pb-2">
                            <input type="checkbox" checked={reached} className="mr-2"
                                onChange={(e) => { setReached(e.target.checked); if (!e.target.checked) setPerson('') }} />
                            {reached ? t('chases.reached') : t('chases.notReached')}
                        </label>
                        {reached && (
                            <label className="text-sm text-gray-600">
                                {t('chases.contactedPerson')}
                                <input value={person} onChange={(e) => setPerson(e.target.value)}
                                    className="block rounded border border-gray-300 bg-white px-3 py-2" />
                            </label>
                        )}
                    </div>
                    <label className="text-sm text-gray-600 block mb-3">
                        {t('chases.summary')}
                        <textarea value={summary} onChange={(e) => setSummary(e.target.value)} rows={3}
                            className="block w-full rounded border border-gray-300 bg-white px-3 py-2" />
                        <span className="block text-[11px] text-gray-500">{t('chases.summaryHint')}</span>
                    </label>

                    {/* 【承诺是有牙齿的那一半】没联系上人时它不出现 —— 服务端也拒 */}
                    {reached && (
                        <label className="text-sm text-gray-600 block mb-2">
                            <input type="checkbox" checked={wantPromise} className="mr-2"
                                onChange={(e) => setWantPromise(e.target.checked)} />
                            {t('chases.addPromise')}
                        </label>
                    )}
                    {reached && wantPromise && (
                        <div className="flex flex-wrap gap-3 mb-3">
                            <label className="text-sm text-gray-600">
                                {t('chases.promiseAmount')}
                                <input type="number" step="0.01" min="0" value={amount}
                                    onChange={(e) => setAmount(e.target.value)}
                                    className="block rounded border border-gray-300 bg-white px-3 py-2 w-40" />
                            </label>
                            <label className="text-sm text-gray-600">
                                {t('chases.promiseCurrency')}
                                <input value={currency} onChange={(e) => setCurrency(e.target.value.toUpperCase())}
                                    className="block rounded border border-gray-300 bg-white px-3 py-2 w-24 font-mono" />
                            </label>
                            <label className="text-sm text-gray-600">
                                {t('chases.promiseDate')}
                                <input type="date" value={promisedDate} min={chasedOn || undefined}
                                    onChange={(e) => setPromisedDate(e.target.value)}
                                    className="block rounded border border-gray-300 bg-white px-3 py-2" />
                            </label>
                        </div>
                    )}
                    <Button type="button" disabled={pending || !canSubmit}
                        onClick={() => run(() => recordChase({
                            customerId, chasedOn, channel, reached, summary,
                            contactedPerson: person,
                            promise: wantPromise
                                ? { amount, currency, promised_date: promisedDate } : null,
                        }))}>
                        {t('chases.record')}
                    </Button>
                </div>
            )}

            {/* ── 记录本身 ───────────────────────────────────────────────── */}
            {chases.length === 0 ? (
                // 【命名的缺席,不是空白】"从没催过"与"读不到"要说得不一样
                <p className="text-sm text-gray-500">{t('chases.none')}</p>
            ) : (
                <table className="w-full border-collapse border border-gray-300 text-sm">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('chases.colCode')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('chases.colDate')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('chases.colChannel')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('chases.colWho')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('chases.colSummary')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('chases.owedAtChase')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('chases.colPromise')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {chases.map((c) => (
                            <tr key={c.id} className={c.superseded_at ? 'text-gray-400' : ''}>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-xs">
                                    {c.code}
                                    {c.superseded_at && (
                                        <span className="ml-2 px-1.5 py-0.5 rounded text-[11px] bg-gray-200 text-gray-700">
                                            {t('chases.superseded')}
                                        </span>
                                    )}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-xs">{c.chased_on}</td>
                                <td className="border border-gray-300 px-3 py-2">{t('chases.channel_' + c.channel)}</td>
                                <td className="border border-gray-300 px-3 py-2">
                                    {c.reached ? (c.contacted_person ?? '—') : t('chases.notReached')}
                                </td>
                                <td className="border border-gray-300 px-3 py-2">
                                    {c.summary}
                                    {c.documents.length > 0 && (
                                        <span className="block text-[11px] text-gray-500 mt-1">
                                            {c.documents.map((d) =>
                                                `${t('chases.subject_' + d.subject_type)} ${d.subject_code ?? ''}`.trim()
                                            ).join(' · ')}
                                        </span>
                                    )}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                    {money(c.owed_base)}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-xs">
                                    {c.promise ? (
                                        <>
                                            <span className="font-mono">
                                                {c.promise.promised_amount_ccy.toLocaleString()} {c.promise.currency}
                                            </span>
                                            <span className="block text-gray-500">→ {c.promise.promised_date}</span>
                                            {c.promise.outcome && (
                                                <span className="block">{t('chases.outcome_' + c.promise.outcome)}</span>
                                            )}
                                        </>
                                    ) : (
                                        <span className="text-gray-400">{t('chases.promiseNone')}</span>
                                    )}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}
            {/* 冻结的数与今天的数【并排】—— 表里那一列是当时告诉客户的数 */}
            {chases.length > 0 && (
                <p className="text-xs text-gray-500 mt-2">
                    {t('chases.owedToday')}: <span className="font-mono">{money(owedToday)} {baseCurrency}</span>
                    {' · '}{t('chases.frozenNote', { date: chases[0].chased_on })}
                </p>
            )}
        </section>
    )
}
