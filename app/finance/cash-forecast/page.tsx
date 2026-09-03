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
//
// ★ CONV-3:套 ListPage 外壳。这一页【恒为 ok】—— 预测本身是一次计算的结果,
// 不是一张会"空"的账簿;页面里三张真正的登记簿(冻结历史、经常性成本行、
// ForecastGrid 内的明细/未定日/缓冲)各自的空态住在它们自己的 DataTable.empty
// 里。13 周 × 币种的那张矩阵表【没有】换成 DataTable —— 见 ForecastGrid.tsx
// 的说明,它是一张透视表,不是逐行记录的账簿,DataTable 的行模型装不下它。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { getBaseCurrency } from '@/lib/currency'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import ForecastGrid, { type ForecastData } from './ForecastGrid'
import RecurringLines from './RecurringLines'
import FrozenForecastsTable, { type FrozenRow } from './FrozenForecastsTable'

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
    ) as unknown as FrozenRow[]

    return (
        <ListPage
            title={t('cashForecast.title')}
            intro={t('cashForecast.subtitle')}
            state={{ kind: 'ok' }}
        >
            <p className="mb-4 text-xs text-[color:var(--brand-muted-text)]">
                {t('cashForecast.weekStart')}: <span className="font-mono">{forecast.week_start}</span>
                {' → '}<span className="font-mono">{forecast.week_end}</span>
            </p>

            <ForecastGrid data={forecast} canFreeze={canEdit} />

            <RecurringLines rows={lines} canEdit={canEdit} baseCurrency={baseCurrency} />

            <h2 className="mb-2 text-lg font-semibold">{t('cashForecast.frozenTitle')}</h2>
            <div className="max-w-3xl">
                <FrozenForecastsTable rows={frozen} />
            </div>
        </ListPage>
    )
}
