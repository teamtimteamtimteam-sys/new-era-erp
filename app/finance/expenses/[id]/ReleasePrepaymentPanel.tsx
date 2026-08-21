'use client'

// EQP-1c-b(P5):设备侧的"冲抵定金"面板。
// 【两个数各自带着自己的币种,而且【不在这里做任何换算】】——
// 敞口以【单据币种】计(apply_prepayment 的 p_amount 就是这个单位),
// 可用定金以【本位币】计。两者不是同一个空间,页面若替它取 min 就是
// 在 TypeScript 里重算汇率(FIN-12 的老毛病)。上限由服务端拒。
import { useActionState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { releasePrepayment, type ReleaseState } from './releasePrepaymentActions'

export default function ReleasePrepaymentPanel({
    expenseId, poId, poCode, openCcy, currency, remainingBase, baseCurrency, canEdit,
}: {
    expenseId: string; poId: string; poCode: string
    openCcy: number; currency: string
    remainingBase: number; baseCurrency: string
    canEdit: boolean
}) {
    const t = useTranslations()
    const action = releasePrepayment.bind(null, expenseId, poId)
    const [state, formAction, pending] = useActionState<ReleaseState, FormData>(action, {} as ReleaseState)

    const nothingToRelease = remainingBase <= 0
    const nothingOpen = openCcy <= 0

    return (
        <div className="border border-gray-300 rounded-lg p-4 mt-6">
            <h2 className="font-medium mb-1">{t('expense.release.title')}</h2>
            <p className="text-sm text-gray-600 mb-3">
                {t('expense.release.subtitle', { po: poCode })}
            </p>

            <div className="grid grid-cols-2 gap-4 mb-3 text-sm">
                <div>
                    <p className="text-xs text-gray-600">{t('expense.release.openOnThisInvoice')}</p>
                    <p className="text-lg">{openCcy.toFixed(2)} {currency}</p>
                </div>
                <div>
                    <p className="text-xs text-gray-600">{t('expense.release.depositRemaining')}</p>
                    <p className="text-lg">{remainingBase.toFixed(2)} {baseCurrency}</p>
                </div>
            </div>
            {/* 【两个数不同币种,而这要说出来】否则人会以为可以直接相减。 */}
            <p className="text-xs text-gray-600 mb-3">{t('expense.release.twoCurrenciesNote')}</p>

            {state.error && (
                <p className="rounded-md bg-red-50 border border-red-200 px-3 py-2 text-sm text-red-700 mb-3">
                    {state.error}
                </p>
            )}
            {state.success && (
                <p className="rounded-md bg-green-50 border border-green-200 px-3 py-2 text-sm text-green-700 mb-3">
                    {t('expense.release.done')}
                </p>
            )}

            {/* 【每一个禁用都把理由摆在旁边】(CMP-2)—— 按不下去又不说为什么的
                按钮读起来像坏了。 */}
            {!canEdit ? (
                <p className="text-sm text-gray-600">{t('expense.release.noPermission')}</p>
            ) : nothingToRelease ? (
                <p className="text-sm text-gray-600">{t('expense.release.noDeposit')}</p>
            ) : nothingOpen ? (
                <p className="text-sm text-gray-600">{t('expense.release.nothingOpen')}</p>
            ) : (
                <form action={formAction} className="flex flex-wrap gap-3 items-end">
                    <div>
                        <label htmlFor="amount" className="block text-xs text-gray-600 mb-1">
                            {t('expense.release.amount', { ccy: currency })}
                        </label>
                        <input id="amount" name="amount" type="number" step="0.01" min="0.01" required
                            className="w-40 border border-gray-300 px-2 py-1.5 rounded" />
                    </div>
                    <div>
                        <label htmlFor="release_date" className="block text-xs text-gray-600 mb-1">
                            {t('expense.release.date')}
                        </label>
                        <input id="release_date" name="release_date" type="date" required
                            className="border border-gray-300 px-2 py-1.5 rounded" />
                        {/* X1:不预填今天 —— 它决定期间。 */}
                        <p className="mt-1 text-xs text-gray-600">{t('expense.release.dateHint')}</p>
                    </div>
                    <div className="flex-1 min-w-[12rem]">
                        <label htmlFor="notes" className="block text-xs text-gray-600 mb-1">
                            {t('expense.release.notes')}
                        </label>
                        <input id="notes" name="notes"
                            className="w-full border border-gray-300 px-2 py-1.5 rounded" />
                    </div>
                    <button type="submit" disabled={pending}
                        className="bg-blue-600 text-white px-4 py-2 rounded-md disabled:opacity-50">
                        {pending ? t('common.saving') : t('expense.release.submit')}
                    </button>
                </form>
            )}
        </div>
    )
}
