'use client'

// app/finance/wht/WhtControls.tsx
// WHT-1:汇缴控件。**禁用一律说出为什么**(CMP-2 的规矩);拒绝就地显示。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { remitWht } from './actions'

type Month = { month: string; label: string; amount: string }

export function RemitControl({ months }: { months: Month[] }) {
    const t = useTranslations()
    const router = useRouter()
    const [month, setMonth] = useState('')
    const [on, setOn] = useState('')
    const [ref, setRef] = useState('')
    const [bank, setBank] = useState('')
    const [notes, setNotes] = useState('')
    const [err, setErr] = useState('')
    const [ok, setOk] = useState('')
    const [busy, start] = useTransition()

    // 【没有欠款时不给按钮,而是说出为什么】一个点下去只会得到
    // WHT_NOTHING_TO_REMIT 的按钮,是本仓库记过的那条
    // "页面不该 offer 一个服务端一定会拒的动作"。
    if (months.length === 0) {
        return (
            <p className="text-sm text-gray-600">{t('wht.noneTitle')}</p>
        )
    }

    // 【日期不预填今天】它决定这笔汇缴进哪个会计期间,而一个默认成今天的日期
    // 永远撞不上 PERIOD_LOCKED —— 于是留空反而比填对更容易过关(FIN-10)。
    const incomplete = !month || !on || !ref.trim()

    return (
        <div className="border border-gray-300 rounded p-4">
            <div className="flex flex-wrap items-end gap-3">
                <div>
                    <label className="block text-sm font-medium mb-1">{t('wht.remitMonth')}</label>
                    <select value={month} onChange={(e) => setMonth(e.target.value)}
                            name="period_month"
                            className="border border-gray-300 px-3 py-2 rounded">
                        <option value="">—</option>
                        {months.map((m) => (
                            <option key={m.month} value={m.month}>{m.label} · {m.amount}</option>
                        ))}
                    </select>
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">{t('wht.remitOn')}</label>
                    <input type="date" value={on} onChange={(e) => setOn(e.target.value)}
                           className="border border-gray-300 px-3 py-2 rounded" />
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">{t('wht.remitReference')}</label>
                    <input value={ref} onChange={(e) => setRef(e.target.value)}
                           placeholder={t('wht.remitReferenceHint')}
                           className="border border-gray-300 px-3 py-2 rounded" />
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">{t('wht.remitBank')}</label>
                    {/* 【币种是数据,不是这里的字面量】账户码本身是科目码,不是币种;
                        本位币户之外的账户由服务端按名拒(WHT_REMIT_BANK_NOT_BASE)。 */}
                    <input value={bank} onChange={(e) => setBank(e.target.value)}
                           placeholder="1000"
                           className="border border-gray-300 px-3 py-2 rounded w-24" />
                </div>
                <div className="grow">
                    <label className="block text-sm font-medium mb-1">{t('wht.remitNotes')}</label>
                    <input value={notes} onChange={(e) => setNotes(e.target.value)}
                           className="border border-gray-300 px-3 py-2 rounded w-full" />
                </div>
            </div>

            <div className="mt-3 flex items-center gap-3">
                <button type="button" disabled={incomplete || busy}
                        onClick={() => start(async () => {
                            const r = await remitWht(month, on, ref, bank, notes)
                            if (r.error) { setErr(r.error); setOk('') }
                            else {
                                setErr('')
                                setOk(t('wht.remitDone', {
                                    amount: String(r.amount ?? ''),
                                    month: month.slice(0, 7),
                                    code: r.code ?? '',
                                }))
                                setMonth(''); setOn(''); setRef(''); setNotes('')
                                router.refresh()
                            }
                        })}
                        className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400">
                    {busy ? t('common.saving') : t('wht.remitSubmit')}
                </button>
                {/* 【禁用要说出理由,而不是把控件藏起来】 */}
                {incomplete && (
                    <span className="text-sm text-amber-700">
                        {t('wht.remitReferenceHint')}
                    </span>
                )}
            </div>
            {err && <p className="text-sm text-red-700 mt-2">{err}</p>}
            {ok && <p className="text-sm text-green-700 mt-2">{ok}</p>}
        </div>
    )
}
