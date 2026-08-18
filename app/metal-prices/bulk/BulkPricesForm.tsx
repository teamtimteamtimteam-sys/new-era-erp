'use client'

// 每日行情批量录入表单:一个日期 + 七个金属各一行。
// 每行右侧给出"该日期之前(含当日)最近一次的价格"作为参照 —— 录入时能看清是从多少改到多少。
// 已有当日价格的金属会被预填(于是本页同时也是"改今天的价"的编辑页)。
// 改日期会重新拉取参照价与预填值(走 router.replace 把日期写进 URL,由服务端重取)。
import { useActionState, useEffect, useState } from 'react'
import { useRouter, usePathname } from 'next/navigation'
import { saveBulkPrices, type BulkPricesState } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import DecimalInput from '@/app/components/forms/DecimalInput'
import { METAL_OPTIONS } from '../options'
import AnomalyWarning from '../AnomalyWarning'
import SourcePicker from '../SourcePicker'
import { INDEX_UNSTATED, type MetalPriceIndex } from '../indexOptions'
import { ACK_FIELD, ackSignature } from '../anomaly'

const initialState: BulkPricesState = {}

export type MetalRowData = {
    metal: string
    // 该日期已录入的价格(预填用),没有则空串
    current: string
    // 参照:该日期之前(含)最近一次的价格与其日期
    lastPrice: number | null
    lastDate: string | null
}

export default function BulkPricesForm({
    priceDate,
    priceIndex,
    indices,
    locale,
    rows,
}: {
    priceDate: string
    priceIndex: string | null
    indices: MetalPriceIndex[]
    locale: string
    rows: MetalRowData[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const pathname = usePathname()
    const [state, formAction, isPending] = useActionState(saveBulkPrices, initialState)

    const [values, setValues] = useState<Record<string, string>>(() =>
        Object.fromEntries(rows.map((r) => [r.metal, r.current]))
    )

    // 服务端换了日期(或保存后 revalidate 重取)→ 用新的预填值刷新输入
    useEffect(() => {
        setValues(Object.fromEntries(rows.map((r) => [r.metal, r.current])))
    }, [rows])

    const metalLabel = (value: string) => t('metals.' + value)

    return (
        <form action={formAction} className="space-y-4 max-w-3xl">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}
            {state.result && (
                <div className="bg-green-50 border border-green-300 text-green-800 px-4 py-3 rounded text-sm">
                    {t('metalPrices.bulk.result', state.result)}
                </div>
            )}

            <div className="flex flex-wrap gap-4">
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('metalPrices.bulk.date')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="date"
                        name="price_date"
                        required
                        value={priceDate}
                        onChange={(e) => {
                            const d = e.target.value
                            if (d) router.replace(`${pathname}?date=${d}&index=${priceIndex ?? INDEX_UNSTATED}`)
                        }}
                        className="border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                {/* METAL-2:整张表属于一个指数。改它要【重取参照价】—— 拿 LME 的
                    上一条去比 SMM 的今天,屏幕上那句"上次 X"就是错的,
                    所以它和日期一样写进 URL,由服务端重取。 */}
                {/* LME-1b:出处三件套(出处 / 指数 / 凭据 / 当天还是延迟)。
                    指数下拉搬进 SourcePicker —— 它只在"发布的指数"时才启用,
                    镜像 1a 那条配对 CHECK。换指数仍然重取参照价。 */}
                <SourcePicker
                    indices={indices}
                    locale={locale}
                    defaultIndex={priceIndex}
                    onIndexChange={(v) => router.replace(`${pathname}?date=${priceDate}&index=${v}`)}
                />
            </div>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('pricing.form.colMetal')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('metalPrices.colPrice')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left" />
                    </tr>
                </thead>
                <tbody>
                    {METAL_OPTIONS.map((opt) => {
                        const row = rows.find((r) => r.metal === opt.value)
                        return (
                            <tr key={opt.value}>
                                <td className="border border-gray-300 px-4 py-2">
                                    {metalLabel(opt.value)}
                                    <span className="text-gray-400 font-mono text-xs ml-2">{opt.value}</span>
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {/* 并列数组:每行都送 metal,价格空串由 DB 侧跳过 */}
                                    <input type="hidden" name="metal" value={opt.value} />
                                    <DecimalInput
                                        name="price"
                                        value={values[opt.value] ?? ''}
                                        onChange={(raw) =>
                                            setValues((v) => ({ ...v, [opt.value]: raw }))
                                        }
                                        className="w-40 border border-gray-300 px-3 py-2 rounded"
                                    />
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-sm text-gray-500">
                                    {row?.lastPrice != null && row.lastDate
                                        ? t('metalPrices.bulk.lastPrice', {
                                              price: row.lastPrice,
                                              date: row.lastDate,
                                          })
                                        : t('metalPrices.bulk.noPrior')}
                                </td>
                            </tr>
                        )
                    })}
                </tbody>
            </table>

            {/* METAL-1:异常提示 —— 出现时这一次【一行都没写】,确认钮才保存整组。
                表单里的值原样留着,人可以先改掉某一个再提交(改了之后签名不同,
                会【再提示一次】—— 确认的是那一组数字,不是"下一次提交")。 */}
            {state.warnings && state.warnings.length > 0 && (
                <>
                    <AnomalyWarning items={state.warnings} />
                    <input type="hidden" name={ACK_FIELD} value={ackSignature(state.warnings)} />
                </>
            )}

            <button
                type="submit"
                disabled={isPending}
                className={
                    'px-4 py-2 rounded text-white disabled:bg-gray-400 ' +
                    (state.warnings?.length
                        ? 'bg-amber-600 hover:bg-amber-700'
                        : 'bg-blue-600 hover:bg-blue-700')
                }
            >
                {isPending
                    ? t('common.saving')
                    : state.warnings?.length
                      ? t('metalPrices.anomaly.confirm')
                      : t('metalPrices.bulk.submit')}
            </button>
        </form>
    )
}
