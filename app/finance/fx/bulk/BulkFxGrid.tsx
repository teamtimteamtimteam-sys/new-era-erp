'use client'

// FX-RATES-1:一周的牌价,一张表填完。
// 【这张表只做一件事:填空】已经在册的格子【预填好、只读】,旁边写着去哪里改 ——
// 一个没有相邻解释的只读控件是个死控件。
// 【为什么不让它覆盖】一次"粘贴"如果能悄悄改掉上周的牌价,那就是【看起来像录入的
// 审计线索销毁】。改一条已在册的牌价要说为什么,那条路在单条编辑页上。
import { useState, useTransition } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { recordFxRatesBulk, type BulkCell } from './actions'
import { Button } from '@/app/components/ui/button'

const TYPES = ['tt_buy', 'tt_sell', 'mid'] as const

export type Existing = { rate_date: string; rate_type: string; rate_sgd_per_unit: number; id: string }

export default function BulkFxGrid({
    currencies,
    dates,
    existing,
}: {
    currencies: string[]
    dates: string[]
    existing: Existing[]
}) {
    const t = useTranslations()
    const [currency, setCurrency] = useState(currencies[0] ?? '')
    const [values, setValues] = useState<Record<string, string>>({})
    const [error, setError] = useState<string | null>(null)
    const [done, setDone] = useState<number | null>(null)
    const [isPending, startTransition] = useTransition()

    const byKey = new Map(existing.map((e) => [`${e.rate_date}|${e.rate_type}`, e]))
    const key = (d: string, ty: string) => `${d}|${ty}`

    function submit() {
        setError(null); setDone(null)
        const cells: BulkCell[] = []
        for (const d of dates) {
            for (const ty of TYPES) {
                if (byKey.has(key(d, ty))) continue // 已在册:表格不碰
                const v = values[key(d, ty)]
                if (v && v.trim() !== '') {
                    cells.push({ currency, rate_date: d, rate_type: ty, rate: v })
                }
            }
        }
        startTransition(async () => {
            const r = await recordFxRatesBulk(cells)
            if (r.error) setError(r.error)
            else { setDone(r.recorded ?? 0); setValues({}) }
        })
    }

    return (
        <div>
            <p className="text-sm text-gray-700 mb-1">{t('finance.fxPage.bulk.whatThisIsFor')}</p>
            <p className="text-xs text-gray-600 mb-4">{t('finance.fxPage.bulk.howToCorrect')}</p>

            <div className="mb-4 flex flex-wrap items-center gap-2">
                <label htmlFor="ccy" className="text-sm">{t('finance.fxPage.colCurrency')}</label>
                <select
                    id="ccy" value={currency} onChange={(e) => setCurrency(e.target.value)}
                    className="border border-gray-300 rounded px-2 py-1 text-sm"
                >
                    {currencies.map((c) => <option key={c} value={c}>{c}</option>)}
                </select>
            </div>

            {error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4 text-sm">
                    {error}
                    <p className="mt-1 opacity-80">{t('finance.fxPage.bulk.allOrNothing')}</p>
                </div>
            )}
            {done !== null && (
                <div className="bg-green-50 border border-green-300 text-green-900 px-4 py-3 rounded mb-4 text-sm">
                    {t('finance.fxPage.bulk.saved', { n: done })}
                </div>
            )}

            <div className="overflow-x-auto">
                <table className="text-sm border-collapse">
                    <thead>
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('finance.fxPage.colRateDate')}</th>
                            {TYPES.map((ty) => (
                                <th key={ty} className="border border-gray-300 px-3 py-2 text-left">
                                    {t('finance.fxPage.rateType.' + ty)}
                                </th>
                            ))}
                        </tr>
                    </thead>
                    <tbody>
                        {dates.map((d) => (
                            <tr key={d}>
                                <td className="border border-gray-300 px-3 py-2 font-mono whitespace-nowrap">{d}</td>
                                {TYPES.map((ty) => {
                                    const ex = byKey.get(key(d, ty))
                                    return (
                                        <td key={ty} className="border border-gray-300 px-2 py-1">
                                            {ex ? (
                                                <span className="flex items-center gap-2">
                                                    <span className="font-mono text-gray-600">{ex.rate_sgd_per_unit}</span>
                                                    <Link
                                                        href={`/finance/fx/${ex.id}/edit`}
                                                        className="text-xs text-blue-600 hover:underline"
                                                    >
                                                        {t('finance.fxPage.bulk.alreadyOnFile')}
                                                    </Link>
                                                </span>
                                            ) : (
                                                <input
                                                    type="text" inputMode="decimal"
                                                    aria-label={`${d} ${ty}`}
                                                    value={values[key(d, ty)] ?? ''}
                                                    onChange={(e) =>
                                                        setValues((v) => ({ ...v, [key(d, ty)]: e.target.value }))
                                                    }
                                                    className="border border-gray-200 rounded px-2 py-1 w-28 font-mono"
                                                />
                                            )}
                                        </td>
                                    )
                                })}
                            </tr>
                        ))}
                    </tbody>
                </table>
            </div>

            <div className="mt-4 flex items-center gap-4">
                <Button
                    type="button" onClick={submit} disabled={isPending}
                >
                    {isPending ? t('common.saving') : t('finance.fxPage.bulk.save')}
                </Button>
                <span className="text-xs text-gray-600">{t('finance.fxPage.bulk.blanksSkipped')}</span>
            </div>
        </div>
    )
}
