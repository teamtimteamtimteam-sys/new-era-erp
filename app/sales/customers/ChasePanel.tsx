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
import { CONTROL_INPUT, CONTROL_SELECT, CONTROL_CHECKBOX, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { recordChase, recordPromiseOutcome } from './chaseActions'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { DataTable, type Column } from '@/app/components/ui/data-table'

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

    // ★ TABLE-CONVERT-3:手搓表格 → 组件。
    //   【手机上留哪几列一个字没改】TABLE-PHONE-3 留的是 单号 · 当时欠多少 · 承诺,
    //   折起来的是 日期 · 渠道 · 联系到谁 · 纪要 —— 催收这件事的结果就在最后那一列。
    //   叠在单号格里那一段手写的展开块【拿掉了】:组件自己画那一段。
    //   ★ 「纪要」下面那串关联单据原来在两个断点各画一份,现在只画一次
    //     (组件把同一个 render 用在行里和展开区)。
    const columns: Column<Chase>[] = [
        {
            key: 'code', header: t('chases.colCode'), priority: true,
            render: (c) => (
                <>
                    {c.code}
                    {c.superseded_at && (
                        <span className="ml-2 px-1.5 py-0.5 rounded text-xs bg-gray-200 text-gray-700">
                            {t('chases.superseded')}
                        </span>
                    )}
                </>
            ),
        },
        { key: 'date', header: t('chases.colDate'), render: (c) => c.chased_on },
        { key: 'channel', header: t('chases.colChannel'), render: (c) => t('chases.channel_' + c.channel) },
        {
            key: 'who', header: t('chases.colWho'),
            render: (c) => (c.reached ? (c.contacted_person ?? '—') : t('chases.notReached')),
        },
        {
            key: 'summary', header: t('chases.colSummary'),
            render: (c) => (
                <>
                    {c.summary}
                    {c.documents.length > 0 && (
                        <span className="block text-xs text-gray-500 mt-1">
                            {c.documents.map((d) =>
                                `${t('chases.subject_' + d.subject_type)} ${d.subject_code ?? ''}`.trim()
                            ).join(' · ')}
                        </span>
                    )}
                </>
            ),
        },
        {
            key: 'owed', header: t('chases.owedAtChase'), align: 'right', priority: true, render: (c) => money(c.owed_base),
        },
        {
            key: 'promise', header: t('chases.colPromise'), priority: true,
            render: (c) => (c.promise ? (
                <>
                    <span>
                        {c.promise.promised_amount_ccy.toLocaleString()} {c.promise.currency}
                    </span>
                    <span className="block text-gray-500">→ {c.promise.promised_date}</span>
                    {c.promise.outcome && (
                        <span className="block">{t('chases.outcome_' + c.promise.outcome)}</span>
                    )}
                </>
            ) : (
                <span className="text-gray-400">{t('chases.promiseNone')}</span>
            )),
        },
    ]

    return (
        <section className="mb-8">
            <h2 className="mb-2">{t('chases.sectionTitle')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-3">{t('chases.sectionHint')}</p>

            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">
                    {error}
                </div>
            )}

            {/* ── 还没了结的承诺:每一个带着它自己的【证据】 ──────────────── */}
            {openPromises.length > 0 && (
                <div className="mb-4 rounded border border-amber-300 bg-amber-50 p-3">
                    <h3 className="mb-2">{t('chases.promisesOpen')}</h3>
                    {openPromises.map((p) => (
                        <div key={p.promise_id} className="mb-3 last:mb-0 text-sm">
                            <div className="flex flex-wrap items-baseline gap-2">
                                <span>{p.promised_amount_ccy.toLocaleString()} {p.currency}</span>
                                <span className="text-[color:var(--brand-muted-text)]">→ {p.promised_date}</span>
                                {p.is_overdue && (
                                    <span className="px-1.5 py-0.5 rounded text-xs bg-red-200 text-red-900">
                                        {t('chases.promiseOverdue')}
                                    </span>
                                )}
                                <span className="text-xs text-[color:var(--brand-muted-text)]">{p.chase_code}</span>
                            </div>
                            <p className="text-xs text-[color:var(--brand-text)] mt-1">
                                {t('chases.appliedSince')}:{' '}
                                <span>{money(p.applied_since_base)} {baseCurrency}</span>
                            </p>
                            <p className="text-xs text-[color:var(--brand-muted-text)]">{t('chases.appliedSinceHint')}</p>
                            <PermissionGate code="module.finance.edit" allowed={canEdit}>
                                <div className="mt-1 flex flex-wrap gap-1">
                                    {OUTCOMES.map((o) => (
                                        <Button variant="secondary" size="xs" key={o} type="button" disabled={pending}
                                            onClick={() => run(() =>
                                                recordPromiseOutcome(customerId, p.promise_id, o, null))}>
                                            {t('chases.outcome_' + o)}
                                        </Button>
                                    ))}
                                </div>
                            </PermissionGate>
                        </div>
                    ))}
                </div>
            )}

            {/* ★★ ALERT-2d ④(a):`canEdit && !<开合位>` —— 一个权限答复与
                       【这一次会话里面板开没开】挤在同一个 &&。为假的两个原因
                       后果完全不同,而屏幕上的表现是同一个:**钮不见了**。
                       DBLOCK-1 裁定:注定被拒的控件要【看得见、按不动、说出为什么】。
                       ☞ 改法是**闸归闸、开合归开合** —— 权限的闸装在这个钮上,
                         `open` 照旧只管面板开不开。
                       ☞ 面板【自己不再套闸】:它里面有【取消】,而 `fieldset disabled`
                         会把取消一起禁掉,人就被关在一个既提交不了也关不掉的表单里
                         (DBLOCK-1 量出来的第一条边界)。而它也不需要 ——
                         没有权限的人翻不开这个开合位。 */}
                    {!open && (
                <PermissionGate code="module.finance.edit" allowed={canEdit} inline className="mb-4">
                    <Button type="button" onClick={() => setOpen(true)}>
                        {t('chases.record')}
                    </Button>
                </PermissionGate>
            )}

            {open && (
                <div className="mb-4 rounded border border-gray-300 p-3 max-w-2xl">
                    <div className="flex flex-wrap gap-3 mb-3">
                        <label className="">
                            {t('chases.chasedOn')}
                            <input type="date" value={chasedOn} max={today()}
                                onChange={(e) => setChasedOn(e.target.value)}
                                className={`${CONTROL_INPUT} block`} />
                            <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('chases.chasedOnHint')}</span>
                        </label>
                        <label className="">
                            {t('chases.channel')}
                            <select value={channel} onChange={(e) => setChannel(e.target.value)}
                                className={`${CONTROL_SELECT} block`}>
                                {CHANNELS.map((c) => (
                                    <option key={c} value={c}>{t('chases.channel_' + c)}</option>
                                ))}
                            </select>
                        </label>
                        <label className="self-end pb-2">
                            <input type="checkbox" checked={reached} className={`${CONTROL_CHECKBOX} mr-2`}
                                onChange={(e) => { setReached(e.target.checked); if (!e.target.checked) setPerson('') }} />
                            {reached ? t('chases.reached') : t('chases.notReached')}
                        </label>
                        {reached && (
                            <label className="">
                                {t('chases.contactedPerson')}
                                <input value={person} onChange={(e) => setPerson(e.target.value)}
                                    className={`${CONTROL_INPUT} block`} />
                            </label>
                        )}
                    </div>
                    <label className="block mb-3">
                        {t('chases.summary')}
                        <textarea value={summary} onChange={(e) => setSummary(e.target.value)}
                            className={`${CONTROL_TEXTAREA} block w-full`} />
                        <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('chases.summaryHint')}</span>
                    </label>

                    {/* 【承诺是有牙齿的那一半】没联系上人时它不出现 —— 服务端也拒 */}
                    {reached && (
                        <label className="block mb-2">
                            <input type="checkbox" checked={wantPromise} className={`${CONTROL_CHECKBOX} mr-2`}
                                onChange={(e) => setWantPromise(e.target.checked)} />
                            {t('chases.addPromise')}
                        </label>
                    )}
                    {reached && wantPromise && (
                        <div className="flex flex-wrap gap-3 mb-3">
                            <label className="">
                                {t('chases.promiseAmount')}
                                <input type="number" step="0.01" min="0" value={amount}
                                    onChange={(e) => setAmount(e.target.value)}
                                    className={`${CONTROL_INPUT} block w-40`} />
                            </label>
                            <label className="">
                                {t('chases.promiseCurrency')}
                                <input value={currency} onChange={(e) => setCurrency(e.target.value.toUpperCase())}
                                    className={`${CONTROL_INPUT} block w-24`} />
                            </label>
                            <label className="">
                                {t('chases.promiseDate')}
                                <input type="date" value={promisedDate} min={chasedOn || undefined}
                                    onChange={(e) => setPromisedDate(e.target.value)}
                                    className={`${CONTROL_INPUT} block`} />
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
            <DataTable
                rows={chases}
                columns={columns}
                rowKey={(c) => c.id}
                phone={{ mode: 'columns' }}
                empty={t('chases.none')}
                rowClassName={(c) => (c.superseded_at ? 'text-gray-400' : undefined)}
            />
            {/* 冻结的数与今天的数【并排】—— 表里那一列是当时告诉客户的数 */}
            {chases.length > 0 && (
                <p className="text-xs text-[color:var(--brand-muted-text)] mt-2">
                    {t('chases.owedToday')}: <span>{money(owedToday)} {baseCurrency}</span>
                    {' · '}{t('chases.frozenNote', { date: chases[0].chased_on })}
                </p>
            )}
        </section>
    )
}
