// app/finance/cash-forecast/page.tsx
// CASHFLOW-1:13 周现金预测。
//
// 【它与 /finance/cashflow 是两件事,所以是两页】那一页是【现金流量表】——
// 已经发生的钱,按 FIN-30 的三段口径。这一页是【预测】—— 还没发生的钱。
// 两者并排放在子导航里,因为读的人常常先看一眼过去再看未来。
//
// 【页面自己不算任何东西】期初、AR、AP、桶、缓冲,全部来自 cash_forecast_data,
// 而那支函数又调 bank_book_balance_asof / ar_aging_asof / ap_aging_asof ——
// 一份自己算 AR 合计的预测,是对账单印的那个数的第二份实现。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { getBaseCurrency } from '@/lib/currency'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import Subnav from '../Subnav'
import ForecastGrid, { type ForecastData } from './ForecastGrid'
import RecurringLines from './RecurringLines'

export default async function CashForecastPage() {
    const denied = await requireModule(MOD.finance)
    if (denied) return denied
    const t = await getTranslations()
    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const canEdit = await can('module.finance.edit')

    const { data, error } = await supabase.rpc('cash_forecast_data', {})
    // 【查询失败必须失败】—— `?? []` 会把一次权限错误变成"预测是空的",
    // 而那正是一个会被人当真的数字(AGENTS.md 那条)。
    if (error) throw new Error(error.message)
    const forecast = data as unknown as ForecastData

    const lines = mustRows(
        await supabase
            .from('cash_forecast_lines')
            .select('id, label, direction, amount_ccy, currency, cadence, start_date, end_date, is_active')
            .order('start_date')
    ) as unknown as Parameters<typeof RecurringLines>[0]['rows']

    const frozen = mustRows(
        await supabase
            .from('cash_forecasts')
            .select('id, code, week_start, frozen_at, superseded_at')
            .order('week_start', { ascending: false })
            .limit(20)
    ) as unknown as { id: string; code: string; week_start: string
                      frozen_at: string; superseded_at: string | null }[]

    return (
        <div className="p-8">
            <Subnav />
            <h1 className="text-2xl font-bold mb-1">{t('cashForecast.title')}</h1>
            <p className="text-sm text-gray-600 mb-6">{t('cashForecast.subtitle')}</p>

            <p className="text-xs text-gray-500 mb-4">
                {t('cashForecast.weekStart')}: <span className="font-mono">{forecast.week_start}</span>
                {' → '}<span className="font-mono">{forecast.week_end}</span>
            </p>

            <ForecastGrid data={forecast} canFreeze={canEdit} />

            <RecurringLines rows={lines} canEdit={canEdit} baseCurrency={baseCurrency} />

            <h2 className="text-lg font-semibold mb-2">{t('cashForecast.frozenTitle')}</h2>
            {frozen.length === 0 ? (
                // 【命名的缺席,不是空白】
                <p className="text-sm text-gray-500">{t('cashForecast.noneFrozen')}</p>
            ) : (
                <table className="w-full border-collapse border border-gray-300 text-sm max-w-3xl">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('cashForecast.colCode')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('cashForecast.weekStart')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('cashForecast.colFrozen')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {frozen.map((f) => (
                            <tr key={f.id} className={f.superseded_at ? 'text-gray-400' : ''}>
                                <td className="border border-gray-300 px-3 py-2 font-mono">
                                    {f.code}
                                    {f.superseded_at && (
                                        <span className="ml-2 px-1.5 py-0.5 rounded text-[11px] bg-gray-200 text-gray-700">
                                            {t('cashForecast.superseded')}
                                        </span>
                                    )}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-xs">{f.week_start}</td>
                                <td className="border border-gray-300 px-3 py-2 text-xs">{f.frozen_at.slice(0, 10)}</td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}
        </div>
    )
}
