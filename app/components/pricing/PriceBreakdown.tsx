'use client'

// 计价明细的共享呈现(逐金属行 + 汇总)。计价器页最先长出这套表格,化验录入的
// 实时预览与化验详情的"立即应用"预览要显示的是【同一份东西】—— 抽出来共用,
// 免得两处慢慢长歪。客户端在这里【不做任何算术】:所有数字都来自
// calculate_metal_price 的返回,本组件只负责摆放。
import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import type { CalcResult, CalcLine } from '@/app/pricing/calculator/actions'

// 汇总这四行(毛值/加工费/折扣/净值)不各自带币种,因为紧接着的最后一行写着
// 「单价 (USD/公斤)」,而金属计价【全程 USD 进 USD 出】(市场惯例,见 AGENTS.md
// 的 FX 规则)—— 折本位币发生在这块面板【之后】的路径上,不在这里。
const SUMMARY_CCY_STATED_IN = '汇总末行 pricing.unitPrice「单价 (USD/公斤)」;上面四行按同一市场惯例同为 USD'

export default function PriceBreakdown({
    res,
    negativeNote,
}: {
    res: CalcResult
    // 净值 ≤ 0 时的提示。措辞随场景不同(计价器是"这单不值",化验页是"不会自动定价"),
    // 所以由调用方给,位置固定在抬头行之后。
    negativeNote?: React.ReactNode
}) {
    const t = useTranslations()

    // ASY-2:【未列明 ≠ 零】。条款没提到这个金属时 DB 给 NULL,这里渲染成"—"
    // 并挂上 title 说明 —— 应付比例列里的 0 会被读成一条谈定的条款("这个金属
    // 我们不付钱"),而公式只是没提它。PO 单据的 PRICE NOT STATED 是同一个答案。
    // 真的谈定 0% 时 DB 给 0,照旧印 0 —— 那个 0 是有意义的。
    const absent = (v: number | null, fmt: (n: number) => string, note: string) =>
        v === null ? (
            <span className="text-gray-400" title={note}>
                —
            </span>
        ) : (
            <span className="font-mono">{fmt(v)}</span>
        )

    // EXEC-1b:【窗口太薄】—— ASY-3 的另一半。
    //
    // 【为什么它长在这里,而不在看板上】看板那一支(metal_quote_stale)说的是
    // 【维护欠账】:多少天没人录行情了。这一句说的是【这一次计价】:你眼前这个
    // "30 天均价"实际上只有一天的行情在里面 —— 它改变的是这个数字的【含义】,
    // 不只是它的年龄。两个读者、两个位置(ASY-3 的原话)。
    //
    // 【判据是"起止同一天",而不是"报价条数 < 2" —— 差别写下来】
    // ASY-3 写的是"窗口内报价数 < 2"。而 calculate_metal_price 今天【不返回条数】,
    // 只返回参与均值那些行的日期范围。所以这里用它真的知道的那件事:
    // 起止同一天 = 参与均值的行全部来自一天。同一天录了两条时,这句话仍然成立
    // 而"条数 < 2"不成立 —— 那是一个【更宽】的提示,不是一个错的提示,
    // 而且它提示的仍然是同一件事:这个均价没有跨越任何时间。
    // 要精确到条数,得让 calculate_metal_price 多返回一个计数 —— 那是一次
    // 数据库改动,本刀(屏幕)刻意不做,记在这里而不是含糊过去。
    const thinWindow = (l: CalcLine) =>
        l.price_from != null && l.price_to != null && l.price_from === l.price_to

    const priceCell = (l: CalcLine) => {
        if (l.price_usd_per_tonne == null) return <span className="text-gray-400">—</span>
        return (
            <>
                <span className="font-mono">
                    {formatMoneyBare(l.price_usd_per_tonne, '列头 pricing.colPrice「行情 (USD/吨)」')}
                </span>
                <span className="text-gray-500 text-xs ml-2">
                    {l.price_date ?? (l.price_from ? `${l.price_from} – ${l.price_to}` : '')}
                </span>
                {thinWindow(l) && (
                    <span className="text-amber-700 text-xs ml-2" title={t('pricing.thinWindowWhy')}>
                        {t('pricing.thinWindow')}
                    </span>
                )}
            </>
        )
    }

    return (
        <div>
            <p className="text-sm text-gray-600 mb-3">
                <span className="font-mono">{res.formula_code}</span> {res.formula_name}
                <span className="mx-2">·</span>
                {res.price_basis === 'average'
                    ? t('pricing.basis.average', { days: res.average_days ?? 0 })
                    : t('pricing.basis.spot')}
                <span className="mx-2">·</span>
                {res.reference_date}
                <span className="mx-2">·</span>
                <span className="font-mono">{res.quantity_kg} kg</span>
            </p>

            {negativeNote}

            {res.skipped_metals.length > 0 && (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-3 text-sm">
                    {t('pricing.skippedNote', { metals: res.skipped_metals.join(', ') })}
                </div>
            )}
            {res.unpaid_metals.length > 0 && (
                <p className="text-sm text-gray-500 mb-3">
                    {t('pricing.unpaidNote', { metals: res.unpaid_metals.join(', ') })}
                </p>
            )}

            <div className="overflow-x-auto">
                <table className="w-full border-collapse border border-gray-300">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('pricing.form.colMetal')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('pricing.colContent')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('pricing.form.colPayable')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('pricing.colContained')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('pricing.colPayableKg')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('pricing.colPrice')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('pricing.colValue')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {res.lines.map((l) => (
                            <tr key={l.metal}>
                                <td className="border border-gray-300 px-3 py-2">
                                    {t('metals.' + l.metal)}
                                    <span className="text-gray-400 font-mono text-xs ml-2">{l.metal}</span>
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">{l.content_pct}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right text-sm">
                                    {absent(l.payable_pct, (n) => String(n), t('pricing.termNotStated'))}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">{l.contained_kg}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right text-sm">
                                    {absent(l.payable_kg, (n) => String(n), t('pricing.termNotStated'))}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{priceCell(l)}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right text-sm">
                                    {absent(l.metal_value_usd,
                                        (n) => formatMoneyBare(n, '列头 pricing.colValue「金额 (USD)」'),
                                        l.payable_pct === null ? t('pricing.termNotStated') : t('pricing.noQuoteNotStated'))}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            </div>

            <div className="mt-4 max-w-md ml-auto text-sm space-y-1">
                <div className="flex justify-between">
                    <span className="text-gray-600">{t('pricing.grossValue')}</span>
                    <span className="font-mono">
                        {formatMoneyBare(res.gross_value_usd, SUMMARY_CCY_STATED_IN)}
                    </span>
                </div>
                <div className="flex justify-between">
                    <span className="text-gray-600">{t('pricing.treatmentCharge')}</span>
                    <span className="font-mono">
                        −{formatMoneyBare(res.treatment_usd, SUMMARY_CCY_STATED_IN)}
                    </span>
                </div>
                <div className="flex justify-between">
                    <span className="text-gray-600">{t('pricing.discountAmount')}</span>
                    <span className="font-mono">
                        −{formatMoneyBare(res.discount_usd, SUMMARY_CCY_STATED_IN)}
                    </span>
                </div>
                <div className="flex justify-between border-t pt-1 font-bold">
                    <span>{t('pricing.netValue')}</span>
                    <span className={'font-mono ' + (res.negative_value ? 'text-red-600' : '')}>
                        {formatMoneyBare(res.net_value_usd, SUMMARY_CCY_STATED_IN)}
                    </span>
                </div>
                <div className="flex justify-between font-bold">
                    <span>{t('pricing.unitPrice')}</span>
                    <span className={'font-mono ' + (res.negative_value ? 'text-red-600' : '')}>
                        {res.unit_price_usd_per_kg}
                    </span>
                </div>
            </div>
        </div>
    )
}
