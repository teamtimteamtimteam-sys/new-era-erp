'use client'

// 行内转账表单(FIN-1b 遗留的 UI)。两边金额照银行水单录入 —— 不给汇率框,
// 不从牌价折算任何一边(C4);跨币种的隐含汇率由 DB 落账,分录两条银行线各记本币。
// ★ PAY-REQ-1 · Batch B:这张表单提的是一张【转账申请】,不再直接记账 —— CFO 批准之后,
//   财务在申请页上执行并给出实际转账日;分录只在执行那一刻过账。成功由 action 跳到那张申请。
import { useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { businessToday } from '@/lib/format'
import { submitTransferRequest } from './transferActions'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { DatePicker } from '@/app/components/ui/date-picker'

const inp = CONTROL_INPUT
const sel = CONTROL_SELECT


export default function TransferForm({ canEdit }: { canEdit: boolean }) {
    const t = useTranslations()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [from, setFrom] = useState('1010')
    const [to, setTo] = useState('1000')
    const [out, setOut] = useState('')
    const [inn, setInn] = useState('')
    // 预填今天是【便利】不是默认值(清空即禁钮并点名)。Batch B 起它是【计划】转账日 ——
    // 实际转账日在执行那一步给(必填),两者可以不同。
    // FIN-CHAIN-1(Tim Step 0 Q13):预填的是【业务时区】的今天(businessToday),不是浏览器时钟 —— 在 SGT 早上八点之前,
    //   浏览器若在 UTC 会预填出昨天;而计划日晚于今天的申请在提交时就按名拒(DOCUMENT_DATE_IN_FUTURE),所以框也封顶在今天。
    const [date, setDate] = useState(() => businessToday())
    const [ref, setRef] = useState('')
    // DATE-PICK-1:提交走按钮 onClick,不走原生表单 —— 框里是一个敲错的日子时把按钮关掉
    const [dateBad, setDateBad] = useState(false)

    function submit() {
        setError(null)
        start(async () => {
            const r = await submitTransferRequest({ date, from, to, amountOut: out, amountIn: inn, reference: ref })
            if (r?.error) setError(r.error)
        })
    }

    return (
        <div className="rounded border border-gray-200 p-4 mb-6">
            <h3 className="mb-1">{t('finance.transfer.title')}</h3>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-1">{t('finance.transfer.hint')}</p>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-3">{t('finance.transfer.requestNotice')}</p>
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}
            <div className="flex gap-2 flex-wrap items-end text-xs text-[color:var(--brand-muted-text)]">
                <label>{t('finance.transfer.plannedDate')}
                    <DatePicker value={date} max={businessToday()} onChange={setDate} onInvalidChange={setDateBad} className="flex" />
                </label>
                <label>{t('finance.transfer.from')}
                    <select value={from} onChange={(e) => setFrom(e.target.value)} className={`block ${sel}`}>
                        <option value="1000">{t('finance.bank.1000')}</option>
                        <option value="1010">{t('finance.bank.1010')}</option>
                    </select>
                </label>
                <label>{t('finance.transfer.amountOut')}
                    <input type="number" value={out} onChange={(e) => setOut(e.target.value)} className={`block ${inp} w-28 text-right tabular-nums`} />
                </label>
                <label>{t('finance.transfer.to')}
                    <select value={to} onChange={(e) => setTo(e.target.value)} className={`block ${sel}`}>
                        <option value="1000">{t('finance.bank.1000')}</option>
                        <option value="1010">{t('finance.bank.1010')}</option>
                    </select>
                </label>
                <label>{t('finance.transfer.amountIn')}
                    <input type="number" value={inn} onChange={(e) => setInn(e.target.value)} className={`block ${inp} w-28 text-right tabular-nums`} />
                </label>
                <label>{t('finance.transfer.reference')}
                    <input value={ref} onChange={(e) => setRef(e.target.value)} className={`block ${inp} w-36`} />
                </label>
                <PermissionGate code="module.finance.edit" allowed={canEdit}>
                <Button type="button" onClick={submit} disabled={pending || !date || !out || !inn || dateBad}>
                    {pending ? t('common.saving') : t('finance.transfer.submitRequest')}
                </Button>
                </PermissionGate>
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
