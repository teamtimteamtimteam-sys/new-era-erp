'use client'

// PROC-BUILD-1:一张加工单的【损耗分类】面板。
//
// 【为什么它在这一页】损耗就是在这一页被记下来的 —— 分类如果住在别的地方,
// 它就变成一件"另外要记得做的事",而这个仓库对"要记得做"的处置是把它换成机制。
//
// 【它【不】编辑 loss_qty】那一列是加工单自己的,本刀一列都没动。
// 这里记的是【那个数里,我们说得出去向的那一部分】。两者不必相等,而差额
// 由 processing_run_loss_breakdown 说成"还没解释"。
//
// 【"还没解释"不是"过磅误差"】—— 屏幕上必须照直说。把差额叫成误差,
// 等于把一个记账问题说成一件已经查清的物理事实,而那正是 loss_qty 今天在犯的错。
import { useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { saveRunLoss, deleteRunLoss } from './lossActions'

export type LossCategory = {
    code: string; name_en: string; name_zh: string
    metal_fate: string; is_true_loss: boolean
}
export type LossRow = { loss_category_code: string; quantity: number; notes: string | null }

export default function LossPanel({
    runId, categories, rows, lossQty, canEdit, locale,
}: {
    runId: string
    categories: LossCategory[]
    rows: LossRow[]
    lossQty: number | null
    canEdit: boolean
    locale: string
}) {
    const t = useTranslations()
    const [error, setError] = useState<string | null>(null)
    const [isPending, startTransition] = useTransition()
    const [formKey, setFormKey] = useState(0)

    const label = (c: LossCategory) => (locale === 'zh' ? c.name_zh : c.name_en)
    const byCode = (code: string) => categories.find((c) => c.code === code) ?? null

    const categorised = rows.reduce((s, r) => s + Number(r.quantity), 0)
    // 【空不是零】loss_qty 没记过时,"还没解释多少"这个问题不成立 ——
    // 显示 0 会把它读成"全部解释完了"。视图那一侧也是这么判的。
    const unexplained = lossQty == null ? null : lossQty - categorised

    function submit(e: React.FormEvent<HTMLFormElement>) {
        e.preventDefault()
        const fd = new FormData(e.currentTarget)
        setError(null)
        startTransition(async () => {
            const r = await saveRunLoss(runId, fd)
            if (r.error) setError(r.error)
            else setFormKey((k) => k + 1)
        })
    }

    function remove(code: string) {
        setError(null)
        startTransition(async () => {
            const r = await deleteRunLoss(runId, code)
            if (r.error) setError(r.error)
        })
    }

    return (
        <section className="mt-6">
            <h2 className="text-lg font-semibold mb-1">{t('processing.loss.title')}</h2>
            <p className="text-sm text-gray-600 mb-3">{t('processing.loss.intro')}</p>

            <div className="text-sm mb-3 flex flex-wrap gap-x-6 gap-y-1">
                <span><span className="text-gray-600">{t('processing.loss.total')}</span>{' '}{lossQty ?? '—'}</span>
                <span><span className="text-gray-600">{t('processing.loss.categorised')}</span>{' '}{categorised}</span>
                <span>
                    <span className="text-gray-600">{t('processing.loss.unexplained')}</span>{' '}
                    {unexplained ?? t('processing.loss.unexplainedUnknown')}
                </span>
            </div>

            {rows.length === 0 ? (
                <p className="text-sm text-gray-600 border border-gray-200 rounded px-3 py-2 bg-gray-50">
                    {t('processing.loss.empty')}
                </p>
            ) : (
                <table className="w-full text-sm border border-gray-200">
                    <thead className="bg-gray-50 text-left">
                        <tr>
                            <th className="px-3 py-2">{t('processing.loss.colCategory')}</th>
                            <th className="px-3 py-2">{t('processing.loss.colMetalFate')}</th>
                            <th className="px-3 py-2 text-right">{t('processing.loss.colQty')}</th>
                            <th className="px-3 py-2">{t('processing.loss.colNotes')}</th>
                            {canEdit && <th className="px-3 py-2" />}
                        </tr>
                    </thead>
                    <tbody>
                        {rows.map((r) => {
                            const c = byCode(r.loss_category_code)
                            return (
                                <tr key={r.loss_category_code} className="border-t border-gray-200">
                                    <td className="px-3 py-2">
                                        {c ? label(c) : r.loss_category_code}
                                        {/* 【它不是损耗】这句话必须在行上,不在脚注里 ——
                                            residue_disposal 记在这里是过渡,不是归宿。 */}
                                        {c && !c.is_true_loss && (
                                            <span className="ml-2 text-xs text-amber-700">
                                                {t('processing.loss.notTrueLoss')}
                                            </span>
                                        )}
                                    </td>
                                    <td className="px-3 py-2 text-gray-700">
                                        {c ? t('processing.loss.metalFate.' + c.metal_fate) : '—'}
                                    </td>
                                    <td className="px-3 py-2 text-right">{r.quantity}</td>
                                    <td className="px-3 py-2 text-gray-600">{r.notes ?? '—'}</td>
                                    {canEdit && (
                                        <td className="px-3 py-2 text-right">
                                            <button type="button" disabled={isPending}
                                                onClick={() => remove(r.loss_category_code)}
                                                className="text-sm text-red-700 hover:underline disabled:opacity-50">
                                                {t('common.delete')}
                                            </button>
                                        </td>
                                    )}
                                </tr>
                            )
                        })}
                    </tbody>
                </table>
            )}

            {error && <p className="mt-2 text-sm text-red-700">{error}</p>}

            {canEdit && (
                <form key={formKey} onSubmit={submit} className="mt-3 flex flex-wrap items-end gap-3">
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('processing.loss.colCategory')}</label>
                        <select name="loss_category_code" required defaultValue=""
                                className="border border-gray-300 rounded px-3 py-2 text-sm">
                            <option value="" disabled>{t('processing.loss.pick')}</option>
                            {categories.map((c) => (
                                <option key={c.code} value={c.code}>{label(c)}</option>
                            ))}
                        </select>
                    </div>
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('processing.loss.colQty')}</label>
                        <input name="quantity" type="number" step="any" min="0" required
                               className="border border-gray-300 rounded px-3 py-2 text-sm w-32" />
                    </div>
                    <div className="flex-1 min-w-[12rem]">
                        <label className="block text-sm font-medium mb-1">{t('processing.loss.colNotes')}</label>
                        <input name="notes" type="text"
                               className="border border-gray-300 rounded px-3 py-2 text-sm w-full" />
                    </div>
                    <button type="submit" disabled={isPending}
                            className="bg-gray-900 text-white rounded px-4 py-2 text-sm disabled:opacity-50">
                        {t('common.save')}
                    </button>
                </form>
            )}
        </section>
    )
}
