'use client'

// 行内转账表单(FIN-1b 遗留的 UI)。两边金额照银行水单录入 —— 不给汇率框,
// 不从牌价折算任何一边(C4);跨币种的隐含汇率由 DB 落账,分录两条银行线各记本币。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { recordTransfer } from './transferActions'

const inp = 'border border-gray-300 rounded px-2 py-1 text-sm'

function todayIsoLocal(): string {
    const d = new Date()
    const yyyy = d.getFullYear()
    const mm = String(d.getMonth() + 1).padStart(2, '0')
    const dd = String(d.getDate()).padStart(2, '0')
    return `${yyyy}-${mm}-${dd}`
}

export default function TransferForm() {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [from, setFrom] = useState('1010')
    const [to, setTo] = useState('1000')
    const [out, setOut] = useState('')
    const [inn, setInn] = useState('')
    // 预填今天是【便利】不是默认值(清空即禁钮并点名):录转账的通常就是刚在
    // 银行端做完转账的人 —— 这是公司自己的当天动作,不像到货是发生在别处的事。
    const [date, setDate] = useState(todayIsoLocal)
    const [ref, setRef] = useState('')

    function submit() {
        setError(null)
        start(async () => {
            const r = await recordTransfer({ date, from, to, amountOut: out, amountIn: inn, reference: ref })
            if (r.error) setError(r.error)
            else { setOut(''); setInn(''); setRef(''); router.refresh() }
        })
    }

    return (
        <div className="rounded border border-gray-200 p-4 mb-6">
            <h3 className="font-bold mb-1 text-sm">{t('finance.transfer.title')}</h3>
            <p className="text-xs text-gray-500 mb-3">{t('finance.transfer.hint')}</p>
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}
            <div className="flex gap-2 flex-wrap items-end text-xs">
                <label>{t('finance.transfer.date')}
                    <input type="date" value={date} onChange={(e) => setDate(e.target.value)} className={`block ${inp}`} />
                </label>
                <label>{t('finance.transfer.from')}
                    <select value={from} onChange={(e) => setFrom(e.target.value)} className={`block ${inp}`}>
                        <option value="1000">{t('finance.bank.1000')}</option>
                        <option value="1010">{t('finance.bank.1010')}</option>
                    </select>
                </label>
                <label>{t('finance.transfer.amountOut')}
                    <input type="number" value={out} onChange={(e) => setOut(e.target.value)} className={`block ${inp} w-28 text-right`} />
                </label>
                <label>{t('finance.transfer.to')}
                    <select value={to} onChange={(e) => setTo(e.target.value)} className={`block ${inp}`}>
                        <option value="1000">{t('finance.bank.1000')}</option>
                        <option value="1010">{t('finance.bank.1010')}</option>
                    </select>
                </label>
                <label>{t('finance.transfer.amountIn')}
                    <input type="number" value={inn} onChange={(e) => setInn(e.target.value)} className={`block ${inp} w-28 text-right`} />
                </label>
                <label>{t('finance.transfer.reference')}
                    <input value={ref} onChange={(e) => setRef(e.target.value)} className={`block ${inp} w-36`} />
                </label>
                <button type="button" onClick={submit} disabled={pending || !date || !out || !inn}
                        className="bg-gray-900 text-white px-3 py-1.5 rounded text-sm disabled:opacity-50">
                    {t('common.save')}
                </button>
            </div>
            {/* 禁用必须说出为什么(CMP-2):每个禁钮条件都有紧邻的一行字。 */}
            {(!date || !out || !inn) && (
                <div className="mt-2 space-y-0.5">
                    {!date && <p className="text-sm text-amber-700">{t('finance.transfer.blockedDate')}</p>}
                    {!out && <p className="text-sm text-amber-700">{t('finance.transfer.blockedAmountOut')}</p>}
                    {!inn && <p className="text-sm text-amber-700">{t('finance.transfer.blockedAmountIn')}</p>}
                </div>
            )}
        </div>
    )
}
