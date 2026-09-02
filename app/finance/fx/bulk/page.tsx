// app/finance/fx/bulk/page.tsx
// FX-RATES-1:一周牌价的批量录入(服务端壳)。
// 【为什么有这一页】单条录入一直都在,但一周的 USD 是 3 个价种 × 5 天 =
// 15 次表单提交。队列写的"每周一次"要的就是这个 —— 不是一个新能力,是一个可行的节奏。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { getBaseCurrency } from '@/lib/currency'
import { mustRows } from '@/lib/db-helpers'
import BulkFxGrid, { type Existing } from './BulkFxGrid'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

const WINDOW_DAYS = 7

export default async function BulkFxPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    const base = await getBaseCurrency()

    // 【最近 7 天,含今天;不含未来】牌价是已经发生的世界事实,
    // 未来那一格根本不该出现在屏幕上 —— record_fx_rate 也会拒。
    const today = new Date()
    const dates: string[] = []
    for (let i = WINDOW_DAYS - 1; i >= 0; i--) {
        const d = new Date(today)
        d.setDate(d.getDate() - i)
        dates.push(d.toISOString().slice(0, 10))
    }

    const ccyRes = await supabase.from('currencies').select('code, is_base').order('code')
    const currencies = mustRows(ccyRes, 'currencies')
        .filter((c) => !c.is_base)
        .map((c) => c.code)

    const existingRes = await supabase
        .from('fx_rates')
        .select('id, currency, rate_date, rate_type, rate_sgd_per_unit')
        .gte('rate_date', dates[0])
        .lte('rate_date', dates[dates.length - 1])
        .is('deleted_at', null)
    const existingAll = mustRows(existingRes, 'fx_rates')

    return (
        <div className="p-8 max-w-5xl">
            <h1 className="text-2xl font-bold mb-4">{t('finance.fxPage.bulk.title')}</h1>
            <p className="mb-4 text-sm">
                <Link href="/finance/fx" className="text-blue-600 hover:underline">
                    {t('finance.fxPage.bulk.backToList')}
                </Link>
            </p>
            {currencies.length === 0 ? (
                // 【具名的缺席】没有外币就说出来,不要给一张空表格让人猜
                <p className="text-sm text-gray-600">
                    {t('finance.fxPage.bulk.noForeignCurrencies', { 0: base })}
                </p>
            ) : (
                <BulkFxGrid
                    currencies={currencies}
                    dates={dates}
                    existing={existingAll as unknown as Existing[]}
                />
            )}
        </div>
    )
}
