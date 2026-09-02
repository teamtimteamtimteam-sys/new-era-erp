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
import { formatAmount, formatMoneyBare } from '@/lib/format'
import { mustRows, mustOne } from '@/lib/db-helpers'
import DepreciateButton from './DepreciateButton'
import { can } from '@/lib/permissions'
import AssetActions from './AssetActions'
import { inServiceState } from './inServiceState'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

type AssetRow = {
    id: string
    code: string
    description: string
    category: string
    acquisition_date: string
    in_service_date: string | null
    planned_in_service_date: string | null
    cost_ccy: number
    currency: string
    fx_rate: number
    cost_base: number
    useful_life_months: number
    residual_base: number
    status: string
    // EQP-1c-a:可空 —— create_fixed_asset 建出来的卡没有出生凭证。
    expense_id: string | null
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
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

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

    // FA-1b:处置要 module.finance.edit;有价款时要挑收款账户。
    // 【账户清单从科目表读,而不是写死】—— dispose_fixed_asset 认的是
    // ('1000','1010') 这两个【科目码】(没有 bank_accounts 这张表);
    // 这里按科目自己的 is_cash 标记去查,免得页面与函数各存一份名单。
    // 名单对不上时页面会少给一个选项,而服务端仍然 BANK_INVALID 兜底 ——
    // 页面是体贴,不是安全边界。
    const canEdit = await can('module.finance.edit')
    const bankAccounts = (mustRows(
        await supabase.from('accounts').select('code').eq('is_cash', true).order('code'),
        'accounts bank') as unknown as { code: string }[]).map((b) => b.code)

    return (
        <div className="p-8">
            <div className="flex items-center justify-between mb-4">
                <h1 className="text-2xl font-bold">{t('assets.title')}</h1>
                {/* EQP-1c-b(P1):台账此前【没有新增入口】—— 唯一的建卡门在开支表单里,
                    而那扇门要求同时过一笔账。设备的真实顺序是先下单、后开票,
                    所以这里是第二扇门的入口。 */}
                {canEdit && (
                    <Link href="/finance/assets/new"
                        className="bg-blue-600 text-white px-4 py-2 rounded-md text-sm">
                        {t('assets.register')}
                    </Link>
                )}
            </div>

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
                        {/* FA-1b:处置终于有了入口 —— 引擎从 FIN-22 起就在,
                            而 FA-0 查出它在 app 里一个调用点都没有。 */}
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('assets.colActions')}</th>
                    </tr>
                </thead>
                <tbody>
                    {assets.map((a) => {
                        const accum = accumByAsset.get(a.id) ?? 0
                        const nbv = Math.round((a.cost_base - accum) * 100) / 100
                        return (
                            <tr key={a.id} className={a.status === 'disposed' ? 'text-gray-400' : ''}>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-sm">
                                    {/* EQP-1c-a:资产编号链到【生出这张卡的那笔支出】,而由
                                        create_fixed_asset 建出来的卡没有那笔支出。没有就不画链接 ——
                                        画一个指向 /finance/expenses/null 的链接,比不画坏得多。 */}
                                    {/* EQP-1c-b:编号链到【这台机器的卡片】。
                                        (EQP-1c-a 之前它链的是"生出这张卡的那笔支出"——
                                         而现在有了卡片页,那笔支出在卡片页上有自己的位置,
                                         并且不是每张卡都有一笔。) */}
                                    <Link href={`/finance/assets/${a.id}`} className="text-blue-600 hover:underline">
                                        {a.code}
                                    </Link>
                                </td>
                                <td className="border border-gray-300 px-3 py-2">{a.description}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{t('assets.category.' + a.category)}</td>
                                <td className="border border-gray-300 px-3 py-2">{a.acquisition_date}</td>
                                <td className="border border-gray-300 px-3 py-2">
                                    {(() => {
                                        // FIX-1(B-D5):与详情页同一份判断。
                                        const st = inServiceState(a)
                                        const txt = st.params ? t(st.key, st.params) : t(st.key)
                                        return a.in_service_date
                                            ? txt
                                            : <span className="text-amber-700 text-xs">{txt}</span>
                                    })()}
                                </td>
                                {/* 原币成本:购置日汇率定格(非货币)—— 与本位币两列并排,各带各的币种 */}
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                    {formatAmount(a.cost_ccy, a.currency)}
                                    {a.currency !== baseCurrency && (
                                        <span className="ml-1 text-xs text-gray-500">@ {a.fx_rate}</span>
                                    )}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                    {formatMoneyBare(a.cost_base, '本列列头 金额 ({ccy})')}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                    {a.useful_life_months}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                    {formatAmount(accum, baseCurrency)}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm font-medium">
                                    {formatAmount(nbv, baseCurrency)}
                                </td>
                                <td className="border border-gray-300 px-3 py-2">
                                    <span className={'px-2 py-1 rounded text-xs ' +
                                        (a.status === 'active' ? 'bg-green-100 text-green-800' : 'bg-gray-200 text-gray-600')}>
                                        {t('assets.status.' + a.status)}
                                    </span>
                                </td>
                                <td className="border border-gray-300 px-3 py-2">
                                    <AssetActions
                                        assetId={a.id} code={a.code} status={a.status}
                                        inServiceDate={a.in_service_date}
                                        plannedInServiceDate={a.planned_in_service_date}
                                        hasCost={Number(a.cost_base) > 0}
                                        acquisitionDate={a.acquisition_date}
                                        canEdit={canEdit} bankAccounts={bankAccounts} />
                                </td>
                            </tr>
                        )
                    })}
                    {assets.length === 0 && (
                        <tr>
                            <td colSpan={12} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
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
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">{formatMoneyBare(r.delta_base, '列头 应提({ccy})')}</td>
                            </tr>
                        ))}
                        <tr className="bg-gray-50 font-medium">
                            <td colSpan={2} className="border border-gray-300 px-3 py-2">{t('finance.totalsLabel')}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">{formatMoneyBare(totalDelta, '列头 应提({ccy})')}</td>
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
