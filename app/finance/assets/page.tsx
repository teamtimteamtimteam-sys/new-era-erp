// app/finance/assets/page.tsx
// 固定资产台账(FIN-22)+ 月度折旧面板。
// 台账列:编号/描述/类别/购置日/在役日/成本(原币,带币种)/本位币成本/寿命/
// 累计折旧/净值/状态。成本按【购置日】汇率定格(非货币,永不重估)——
// 币种随行标注,formatAmount,不裸数。
// 折旧面板:期末日期(?date=,预览走 preview_depreciate_fixed_assets ——
// 与真正过账同一份算术,ask-the-database),应提为 0 时按钮禁用(幂等)。
// 资产的创建入口在开支表单的资本分支(/finance/expenses/new)—— 台账不设新增。
//
// ★ CONV-4:资产台账主表【不属于这一套模板的人口】——
//   最后一格挂着 AssetActions,一个真实的、逐行的行内表单(提交按 date/
//   number/select 输入),按【格子里有没有输入控件】这条全仓库统一的判据,
//   它是一张需要 CONV-2 那套"行级编辑态"契约的表,不是这一套只读账簿的模板 ——
//   与 CONV-3 §⑧-1 拒收 /tools/pricing/calculator 是同一条判据。主表按兵不动。
//   月度折旧预览是另一张表,零行内控件,套 CONV-1 模板转换。
//   state 恒为 'ok':这一页没有"整页无内容"这回事,折旧面板总是有得看。
//
// ★★ TABLE-CONVERT-2(2026-09-10)更新了上面那段话的结论:**这张表转了。**
//   CONV-4 当时的判据是「格子里有没有输入控件」,而 AssetActions 让它落在
//   "不转"那一侧。转换这一族用的是另一条判据:**格子里的控件是不是【自带状态的
//   子组件】** —— AssetActions 是一个 'use client' 的独立组件,它自己管自己的
//   对话框与提交,列描述符只要把它画出来就行,不需要组件提供"行级编辑态"。
//   真正拦住 A 类那 14 张的是【并列数组提交】(格子里带 name 的 input 靠
//   同名数组回传),这张表【没有】那个形状。
//   ☞ 表本身搬到了 ./AssetsTable.tsx('use client');本页是 server component,
//     而列描述符带 render 函数,过不了那道边界。
import Link from 'next/link'
import { getBaseCurrency } from '@/lib/currency'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { formatAmount, formatMoneyBare } from '@/lib/format'
import { mustRows, mustOne } from '@/lib/db-helpers'
import DepreciateButton from './DepreciateButton'
import { can } from '@/lib/permissions'
import { inServiceState } from './inServiceState'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import DepreciationPreviewTable, { type DepreciationPreviewRow } from './DepreciationPreviewTable'
import AssetsTable, { type AssetsTableRow } from './AssetsTable'
import { Button } from '@/app/components/ui/button'

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

    const depreciationTableRows: DepreciationPreviewRow[] = [
        ...previewRows.map((r) => ({
            assetId: r.asset_id, code: r.code, account: r.account, deltaBase: r.delta_base,
        })),
        ...(previewRows.length > 0
            ? [{ assetId: '__total__', code: null, account: null, deltaBase: totalDelta, isTotal: true }]
            : []),
    ]

    // FA-1b:处置要 module.finance.edit;有价款时要挑收款账户。
    // 【账户清单从科目表读,而不是写死】—— dispose_fixed_asset 认的是
    // ('1000','1010') 这两个【科目码】(没有 bank_accounts 这张表);
    // 这里按科目自己的 is_cash 标记去查,免得页面与函数各存一份名单。
    // 名单对不上时页面会少给一个选项,而服务端仍然 BANK_INVALID 兜底 ——
    // 页面是体贴,不是安全边界。
    const canEdit = await can('module.finance.edit')
    // ════════════════════════════════════════════════════════════════════════
    // ★ TABLE-CONVERT-2:台账那张表搬进了 AssetsTable('use client')。
    //   本页是 server component,列描述符带 render 函数,过不了那道边界。
    //   ★ 投用日那句话仍然【只算一次】—— TABLE-PHONE-1 当初把它提到格子外面,
    //     正是为了两个断点共用一个值;现在它提到了这里,同一条道理。
    // ════════════════════════════════════════════════════════════════════════
    const assetRows: AssetsTableRow[] = assets.map((a) => {
        const accum = accumByAsset.get(a.id) ?? 0
        const inSvcState = inServiceState(a)
        return {
            id: a.id,
            code: a.code,
            description: a.description,
            category: a.category,
            acquisitionDate: a.acquisition_date,
            inServiceText: inSvcState.params ? t(inSvcState.key, inSvcState.params) : t(inSvcState.key),
            inServicePending: !a.in_service_date,
            costCcy: formatAmount(a.cost_ccy, a.currency),
            fxRate: a.currency !== baseCurrency ? String(a.fx_rate) : null,
            costBase: formatMoneyBare(a.cost_base, '本列列头 金额 ({ccy})'),
            usefulLifeMonths: a.useful_life_months,
            accum: formatAmount(accum, baseCurrency),
            nbv: formatAmount(Math.round((a.cost_base - accum) * 100) / 100, baseCurrency),
            status: a.status,
            inServiceDate: a.in_service_date,
            plannedInServiceDate: a.planned_in_service_date,
            hasCost: Number(a.cost_base) > 0,
        }
    })
    const bankAccounts = (mustRows(
        await supabase.from('accounts').select('code').eq('is_cash', true).order('code'),
        'accounts bank') as unknown as { code: string }[]).map((b) => b.code)

    return (
        <ListPage
            title={t('assets.title')}
            actions={
                // EQP-1c-b(P1):台账此前【没有新增入口】—— 唯一的建卡门在开支表单里,
                // 而那扇门要求同时过一笔账。设备的真实顺序是先下单、后开票,
                // 所以这里是第二扇门的入口。
                canEdit ? (
                    <Button asChild>
                        <Link href="/finance/assets/new">{t('assets.register')}</Link>
                    </Button>
                ) : undefined
            }
            state={{ kind: 'ok' }}
        >
            <div className="mb-8">
                <AssetsTable
                    rows={assetRows}
                    canEdit={canEdit}
                    bankAccounts={bankAccounts}
                    baseCurrency={baseCurrency}
                    empty={t('assets.empty')}
                />
            </div>

            {/* ── 月度折旧 ── */}
            <h2 className="text-xl font-bold mb-3">{t('assets.depTitle')}</h2>
            <form method="get" className="mb-3">
                <label className="text-sm mr-2">{t('assets.depPeriodEnd')}</label>
                <input type="date" name="date" defaultValue={d}
                       className="border border-gray-300 rounded px-2 py-1 text-sm" />
                <Button variant="secondary" type="submit" className="ml-2">
                    {t('finance.reval.preview')}
                </Button>
            </form>
            {previewRows.length > 0 ? (
                <div className="mb-3 max-w-[32rem]">
                    <DepreciationPreviewTable rows={depreciationTableRows} empty={t('assets.nothingToDepreciate', { 0: d })} baseCurrency={baseCurrency} />
                </div>
            ) : (
                <p className="text-sm text-gray-500 mb-3">{t('assets.nothingToDepreciate', { 0: d })}</p>
            )}
            <DepreciateButton canEdit={canEdit} periodEnd={d} disabled={totalDelta === 0} />
        </ListPage>
    )
}
