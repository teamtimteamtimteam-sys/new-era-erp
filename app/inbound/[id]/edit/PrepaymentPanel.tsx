'use client'

// 抵扣预付面板(cut 4c):批次挂在还有未抵扣预付的采购单上且已计价时出现。
// 显示采购单编号 / 该单未抵扣预付 / 本批未结应付 / 可抵扣额(三者都来自
// po_prepayment_applicable —— 与 apply_prepayment 同一口径,页面不自己算资格),
// 金额默认 = 可抵扣额,可改;提交走 applyPrepayment,成功后服务端重读,
// 面板要么显示缩小后的数字,要么(可抵扣归零)整个消失。
// 下方列出本批已有的抵扣记录(金额/日期/分录链接)。
//
// CCY-1:这一块【整块都是本位币】(*_base),而它挂在进料批次编辑页上 —— 那一页
// 上下都是采购单的单据币种口径(批次单价、金额)。面板自己不写币种就等于借了
// 一个说着别的币种的抬头,所以四个数字各自带上币种。
import { useActionState, useState } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatAmount } from '@/lib/format'
import DecimalInput from '@/app/components/forms/DecimalInput'
import { applyPrepayment, type ApplyPrepaymentState } from './prepaymentActions'

const initialState: ApplyPrepaymentState = {}

export type PrepaymentApplicationRow = {
    id: string
    amount_base: number
    created_at_display: string
    journal_id: string | null
    journal_code: string | null
}

export default function PrepaymentPanel({
    batchId,
    applicable,
    history,
    baseCurrency,
}: {
    batchId: string
    applicable: {
        purchase_order_id: string
        po_code: string
        batch_ap_open_base: number
        po_unapplied_prepayment_base: number
        applicable_base: number
    } | null
    history: PrepaymentApplicationRow[]
    /** CCY-1:本面板的金额全是本位币(*_base)。来自 currencies.is_base,
     *  由页面 getBaseCurrency() 后传进来 —— 客户端组件不自己查,也不写死。 */
    baseCurrency: string
}) {
    const t = useTranslations()
    const boundAction = applyPrepayment.bind(null, batchId, applicable?.purchase_order_id ?? '')
    const [state, formAction, isPending] = useActionState(boundAction, initialState)

    if (!applicable && history.length === 0) return null

    return (
        <section className="mt-8 border border-gray-300 rounded p-4">
            <h2 className="font-bold mb-1">{t('purchasing.applyPrepayment')}</h2>
            <p className="text-xs text-gray-500 mb-3">{t('purchasing.applyPrepaymentNote')}</p>

            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-3 text-sm">
                    {state.error}
                </div>
            )}

            {applicable && (
                <form action={formAction} className="space-y-3">
                    <div className="flex flex-wrap gap-x-8 gap-y-1 text-sm">
                        <div>
                            <span className="text-gray-600 mr-1">{t('purchasing.orderDetailTitle')}:</span>
                            <Link
                                href={`/purchasing/orders/${applicable.purchase_order_id}`}
                                className="text-blue-600 hover:underline font-mono"
                            >
                                {applicable.po_code}
                            </Link>
                        </div>
                        <div>
                            <span className="text-gray-600 mr-1">{t('purchasing.remainingLabel')}:</span>
                            <span className="font-mono">{formatAmount(applicable.po_unapplied_prepayment_base, baseCurrency)}</span>
                        </div>
                        <div>
                            <span className="text-gray-600 mr-1">{t('finance.colOpen')}:</span>
                            <span className="font-mono">{formatAmount(applicable.batch_ap_open_base, baseCurrency)}</span>
                        </div>
                        <div>
                            <span className="text-gray-600 mr-1">{t('purchasing.applicableAmount')}:</span>
                            <span className="font-mono font-medium">{formatAmount(applicable.applicable_base, baseCurrency)}</span>
                        </div>
                    </div>
                    <div className="flex items-center gap-2">
                        {/* key 让服务端重读后的新默认值生效(受控默认仅初始一次)*/}
                        <AmountInput key={applicable.applicable_base} defaultAmount={applicable.applicable_base} />
                        {/* EQP-1c-b(X1):冲抵日。【不预填今天】—— 它决定这笔分录
                            落在哪个期间,而一个默认成今天的日期【永远撞不上
                            PERIOD_LOCKED】,于是留空反而比填对更顺(AGENTS.md 那条)。
                            服务端也独立拒空(RELEASE_DATE_REQUIRED)。 */}
                        <label className="text-sm text-gray-600" htmlFor="release_date">
                            {t('purchasing.releaseDate')}
                        </label>
                        <input id="release_date" name="release_date" type="date" required
                            className="border border-gray-300 px-2 py-1.5 rounded text-sm" />
                        <button
                            type="submit"
                            disabled={isPending}
                            className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400 text-sm"
                        >
                            {isPending ? t('common.saving') : t('purchasing.applyPrepayment')}
                        </button>
                    </div>
                </form>
            )}

            {history.length > 0 && (
                <div className="mt-4">
                    <h3 className="text-sm font-bold text-gray-700 mb-2">{t('purchasing.appliedHistory')}</h3>
                    <table className="w-full border-collapse border border-gray-300 text-sm">
                        <tbody>
                            {history.map((h) => (
                                <tr key={h.id}>
                                    <td className="border border-gray-300 px-3 py-1.5 text-right font-mono w-32">
                                        {formatAmount(h.amount_base, baseCurrency)}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-1.5 text-gray-600">
                                        {h.created_at_display}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-1.5">
                                        {h.journal_id ? (
                                            <Link
                                                href={`/finance/journal/${h.journal_id}`}
                                                className="text-blue-600 hover:underline font-mono"
                                            >
                                                {h.journal_code}
                                            </Link>
                                        ) : (
                                            '—'
                                        )}
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </div>
            )}
        </section>
    )
}

// 金额输入拆成小组件:父级用 key={applicable_base} 重挂,接住
// "apply 成功 → 服务端重读 → 可抵扣缩小 → 新默认值"的循环
function AmountInput({ defaultAmount }: { defaultAmount: number }) {
    const [value, setValue] = useState(String(defaultAmount))
    return (
        <DecimalInput
            name="amount"
            required
            value={value}
            onChange={setValue}
            className="w-36 border border-gray-300 px-3 py-2 rounded"
        />
    )
}
