// app/finance/assets/page.tsx
// 固定资产台账(FIN-22)+ 月度折旧面板。
// 台账列:编号/描述/类别/购置日/在役日/成本(原币,带币种)/本位币成本/寿命/
// 累计折旧/净值/状态。成本按【购置日】汇率定格(非货币,永不重估)——
// 币种随行标注,formatAmount,不裸数。
// 折旧面板:期末日期(?date=,预览走 preview_depreciate_fixed_assets ——
// 与真正过账同一份算术,ask-the-database),应提为 0 时按钮禁用(幂等)。
// 资产的创建入口在开支表单的资本分支(/finance/expenses/new)—— 台账不设新增。
import Link from 'next/link'
import { getBaseCurrency } from '@/lib/currency'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { formatMoney, formatAmount } from '@/lib/format'
import { mustRows, mustOne } from '@/lib/db-helpers'
import Subnav from '../Subnav'
import DepreciateButton from './DepreciateButton'

type AssetRow = {
    id: string
    code: string
    description: string
    category: string
    acquisition_date: string
    in_service_date: string | null
    cost_ccy: number
    currency: string
    fx_rate: number
    cost_base: number
    useful_life_months: number
    residual_base: number
    status: string
    expense_id: string
}

type PreviewRow = {
    asset_id: string
    code: string
    description: string
    account: string
    target_base: number
    posted_base: number
    delta_base: number
}

function endOfMonthIso(): string {
    const d = new Date()
    const e = new Date(d.getFullYear(), d.getMonth() + 1, 0)
    return `${e.getFullYear()}-${String(e.getMonth() + 1).padStart(2, '0')}-${String(e.getDate()).padStart(2, '0')}`
}

export default async function AssetsPage({
    searchParams,
}: {
    searchParams: Promise<{ date?: string }>
}) {
    const sp = await searchParams
    const d = sp.date ?? endOfMonthIso()
    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const t = await getTranslations()

    const [assetsRes, depRes] = await Promise.all([
        supabase.from('fixed_assets').select('*').order('code'),
        supabase.from('fixed_asset_depreciation').select('asset_id, amount_base'),
    ])
    const assets = (mustRows(assetsRes) as unknown as AssetRow[])
    const accumByAsset = new Map<string, number>()
    for (const r of mustRows(depRes) as { asset_id: string; amount_base: number }[]) {
        accumByAsset.set(r.asset_id, Math.round(((accumByAsset.get(r.asset_id) ?? 0) + r.amount_base) * 100) / 100)
    }

    // 折旧预览:与 depreciate_fixed_assets 同一份算术(它内部就是先问这个)
    const preview = mustOne(
        await supabase.rpc('preview_depreciate_fixed_assets', { p_period_end: d }),
        'preview_depreciate_fixed_assets'
    ) as unknown as { rows: PreviewRow[]; total_delta: number } | null
    const previewRows = (preview?.rows ?? []).filter((r) => r.delta_base > 0)
    const totalDelta = preview?.total_delta ?? 0

    return (
        <div className="p-8">
            <h1 className="text-2xl font-bold mb-4">{t('assets.title')}</h1>
            <Subnav />

            <table className="w-full border-collapse border border-gray-300 mb-8">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('finance.colCode')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('assets.colDescription')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('assets.colCategory')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('assets.colAcquired')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('assets.colInService')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('assets.colCost')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('finance.colAmount', { ccy: baseCurrency })}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('assets.colLife')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('assets.colAccum')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('assets.colNbv')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('finance.colStatus')}</th>
                    </tr>
                </thead>
                <tbody>
                    {assets.map((a) => {
                        const accum = accumByAsset.get(a.id) ?? 0
                        const nbv = Math.round((a.cost_base - accum) * 100) / 100
                        return (
                            <tr key={a.id} className={a.status === 'disposed' ? 'text-gray-400' : ''}>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-sm">
                                    <Link href={`/finance/expenses/${a.expense_id}`} className="text-blue-600 hover:underline">
                                        {a.code}
                                    </Link>
                                </td>
                                <td className="border border-gray-300 px-3 py-2">{a.description}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{t('assets.category.' + a.category)}</td>
                                <td className="border border-gray-300 px-3 py-2">{a.acquisition_date}</td>
                                <td className="border border-gray-300 px-3 py-2">
                                    {a.in_service_date ?? <span className="text-amber-700 text-xs">{t('assets.notInService')}</span>}
                                </td>
                                {/* 原币成本:购置日汇率定格(非货币)—— 与本位币两列并排,各带各的币种 */}
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                    {formatAmount(a.cost_ccy, a.currency)}
                                    {a.currency !== baseCurrency && (
                                        <span className="ml-1 text-xs text-gray-500">@ {a.fx_rate}</span>
                                    )}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                    {formatMoney(a.cost_base)}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                    {a.useful_life_months}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                    {formatMoney(accum)}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm font-medium">
                                    {formatMoney(nbv)}
                                </td>
                                <td className="border border-gray-300 px-3 py-2">
                                    <span className={'px-2 py-1 rounded text-xs ' +
                                        (a.status === 'active' ? 'bg-green-100 text-green-800' : 'bg-gray-200 text-gray-600')}>
                                        {t('assets.status.' + a.status)}
                                    </span>
                                </td>
                            </tr>
                        )
                    })}
                    {assets.length === 0 && (
                        <tr>
                            <td colSpan={11} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('assets.empty')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>

            {/* ── 月度折旧 ── */}
            <h2 className="text-xl font-bold mb-3">{t('assets.depTitle')}</h2>
            <form method="get" className="mb-3">
                <label className="text-sm mr-2">{t('assets.depPeriodEnd')}</label>
                <input type="date" name="date" defaultValue={d}
                       className="border border-gray-300 rounded px-2 py-1 text-sm" />
                <button type="submit" className="ml-2 border border-gray-300 rounded px-3 py-1 text-sm">
                    {t('finance.reval.preview')}
                </button>
            </form>
            {previewRows.length > 0 ? (
                <table className="w-auto min-w-[32rem] border-collapse border border-gray-300 mb-3">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('finance.colCode')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('assets.colAccount')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('assets.colDelta', { ccy: baseCurrency })}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {previewRows.map((r) => (
                            <tr key={r.asset_id}>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-sm">{r.code}</td>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-sm">{r.account}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">{formatMoney(r.delta_base)}</td>
                            </tr>
                        ))}
                        <tr className="bg-gray-50 font-medium">
                            <td colSpan={2} className="border border-gray-300 px-3 py-2">{t('finance.totalsLabel')}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">{formatMoney(totalDelta)}</td>
                        </tr>
                    </tbody>
                </table>
            ) : (
                <p className="text-sm text-gray-500 mb-3">{t('assets.nothingToDepreciate', { 0: d })}</p>
            )}
            <DepreciateButton periodEnd={d} disabled={totalDelta === 0} />
        </div>
    )
}
