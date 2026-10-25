'use client'

// 计价明细的共享呈现(逐金属行 + 汇总)。计价器页最先长出这套表格,化验录入的
// 实时预览与化验详情的"立即应用"预览要显示的是【同一份东西】—— 抽出来共用,
// 免得两处慢慢长歪。客户端在这里【不做任何算术】:所有数字都来自
// calculate_metal_price 的返回,本组件只负责摆放。
import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import type { CalcResult, CalcLine } from '@/app/tools/pricing/calculator/actions'
import * as React from 'react'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { formatDate } from '@/lib/dates'
import { useLocale } from '@/lib/i18n/client'
import { xMoney, xNum, xText } from '@/lib/export/cells'
import { sgStamp } from '@/lib/export/write'

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
    const locale = useLocale()
    const t = useTranslations()

    // TABLE-EXPORT-3c(Tim 2026-10-25 Q2(c)):这张预览在它出现的每一页都导出,About 表写明「计价预览,截至 <时刻>」。
    //   那个时刻是【这份结果到手的那一刻】(客户端),不是点导出的那一刻 —— 结果停在屏幕上十分钟,行情可能已经变了,
    //   文件要说出它是哪一刻的数。res 换了(重算、实时预览又来一份)就重记;同一份 res 重画不重记。
    //   (化验详情页的预览是服务端一次算好的,这里记的是它到达浏览器的那一刻 —— 与服务端算的时刻差一个往返。)
    const [stamp, setStamp] = React.useState(() => ({ res, at: new Date().toISOString() }))
    if (stamp.res !== res) setStamp({ res, at: new Date().toISOString() })

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
            <span>{fmt(v)}</span>
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
                <span>
                    {formatMoneyBare(l.price_usd_per_tonne, '列头 pricing.colPrice「行情 (USD/吨)」')}
                </span>
                <span className="text-[color:var(--brand-muted-text)] text-xs ml-2">
                    {formatDate(l.price_date, locale) ?? (l.price_from ? `${l.price_from} – ${l.price_to}` : '')}
                </span>
                {thinWindow(l) && (
                    <span className="text-amber-700 text-xs ml-2" title={t('pricing.thinWindowWhy')}>
                        {t('pricing.thinWindow')}
                    </span>
                )}
            </>
        )
    }

    // ════════════════════════════════════════════════════════════════════
    // TABLE-CONVERT-6 · 计价明细 —— ★ 这张表此前【没有】手机档判断 ★
    // ════════════════════════════════════════════════════════════════════
    // 转换前一处 hidden sm:table-cell 都没有,七列在 390px 上靠外层
    // overflow-x-auto 横着拖。
    //
    // ★【留哪两列 —— 金属 · 金额(USD)】
    //   · 金属:身份(行键就是 l.metal)。
    //   · 金额:结论 —— 这张明细回答的问题是「这一种金属值多少钱」,
    //     而中间那五列(含量% · 计价% · 含金属量 · 计价量 · 单价)是【算给你看的过程】。
    //   ☞ 过程整组折进展开区,各带自己的列头:它们只有连起来读才有意义
    //     (含量 → 含金属量 → 计价% → 计价量 → 单价 → 金额),
    //     单独留一两列反而给人一种"这就是全部"的错觉。
    //   ⚠ 而「说不出口」的那几种答案跟着数字一起进展开区:
    //     termNotStated / noQuoteNotStated 是 ASY-2 的具名空缺(**不是 0**),
    //     它们由 absent() 画在各自的格子里,折进去之后一个字都没变。
    const columns: ExportableColumn<CalcLine>[] = [
        {
            key: 'metal',
            header: t('pricing.form.colMetal'),
            // ★ 身份 —— 手机上留下。
            priority: true,
            render: (l) => (
                <>
                    {t('metals.' + l.metal)}
                    <span className="text-gray-400 text-xs ml-2">{l.metal}</span>
                </>
            ),
            // TABLE-EXPORT-3c(Tim 2026-10-25):一格一个值 —— 写金属的名字(界面语言),旁边那个灰色代码不写
            exportAs: (l) => xText(t('metals.' + l.metal)),
        },
        {
            key: 'content',
            header: t('pricing.colContent'),
            align: 'right',
            // ⚠ 转换前 `text-right font-mono text-sm` —— text-sm 不搬(列描述符不许钉字号)
            //   ★★ FONT-3(2026-09-12):那个继承来的数今天是 **15px**,不再是 14px ——
            //     `TABLE_TEXT` 排在组件 `cn()` 的最后(见 table-style.ts)。
            //     ☞ 这一格**不写字号**仍然是对的做法,而且现在**写了也没有用**。
            render: (l) => l.content_pct,
            exportAs: (l) => xNum(l.content_pct, 'pct'),
        },
        {
            key: 'payablePct',
            header: t('pricing.form.colPayable'),
            align: 'right',
            render: (l) => absent(l.payable_pct, (n) => String(n), t('pricing.termNotStated')),
            // TABLE-EXPORT-3c(Tim 2026-10-25):null =「条款未列明」(屏幕上的「—」)→ 空格,绝不写 0(ASY-2)
            exportAs: (l) => xNum(l.payable_pct, 'pct'),
        },
        {
            key: 'contained',
            header: t('pricing.colContained'),
            align: 'right',
            render: (l) => l.contained_kg,
            exportAs: (l) => xNum(l.contained_kg, 'qty'),
        },
        {
            key: 'payableKg',
            header: t('pricing.colPayableKg'),
            align: 'right',
            render: (l) => absent(l.payable_kg, (n) => String(n), t('pricing.termNotStated')),
            // null = 条款未列明 → 空格,不是 0
            exportAs: (l) => xNum(l.payable_kg, 'qty'),
        },
        {
            key: 'price',
            header: t('pricing.colPrice'),
            render: (l) => priceCell(l),
            // TABLE-EXPORT-3c(Tim 2026-10-25):这一格屏幕上是「行情 + 行情日(或均价起止)+ 窗口太薄的提示」,
            //   导出只写主值 —— 行情那个数(USD/吨,币种与单位在列头上,与屏幕一样)。没有行情 → 空格,不是 0。
            //   日期与「窗口太薄」不写(一列一格;要日期回到屏幕或计价器上看)。
            exportAs: (l) => xMoney(l.price_usd_per_tonne),
        },
        {
            key: 'value',
            header: t('pricing.colValue'),
            // ★ 结论 —— 手机上留下。
            priority: true,
            align: 'right',
            render: (l) =>
                absent(
                    l.metal_value_usd,
                    (n) => formatMoneyBare(n, '列头 pricing.colValue「金额 (USD)」'),
                    l.payable_pct === null ? t('pricing.termNotStated') : t('pricing.noQuoteNotStated')
                ),
            // null = 算不出(条款未列明 / 没有行情)→ 空格,不是 0;币种在列头「金额 (USD)」上
            exportAs: (l) => xMoney(l.metal_value_usd),
        },
    ]

    return (
        <div>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-3">
                <span>{res.formula_code}</span> {res.formula_name}
                <span className="mx-2">·</span>
                {res.price_basis === 'average'
                    ? t('pricing.basis.average', { days: res.average_days ?? 0 })
                    : t('pricing.basis.spot')}
                <span className="mx-2">·</span>
                {res.reference_date}
                <span className="mx-2">·</span>
                <span>{res.quantity_kg} kg</span>
            </p>

            {negativeNote}

            {res.skipped_metals.length > 0 && (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-3 text-sm">
                    {t('pricing.skippedNote', { metals: res.skipped_metals.join(', ') })}
                </div>
            )}
            {res.unpaid_metals.length > 0 && (
                <p className="text-sm text-[color:var(--brand-muted-text)] mb-3">
                    {t('pricing.unpaidNote', { metals: res.unpaid_metals.join(', ') })}
                </p>
            )}

            {/* TABLE-CONVERT-6:转换前【没有空态】—— res.lines 为空时画的是一张
                只有表头的表。组件在没有 empty prop 时会退到它自带的 table.empty,
                所以真遇上零行会多出一句(组件既有的 key,不是我造的新词)。 */}
            <DataTable
                rows={res.lines}
                columns={columns}
                rowKey={(l) => l.metal}
                phone={{ mode: 'columns' }}
                // TABLE-EXPORT-3c(Tim 2026-10-25 Q2(c)):计价器、化验录入、化验详情、进料编辑的重算面板 —— 同一个名字;
                //   About 表写明「计价预览,截至 <时刻>」与这份预览是哪条公式、哪天、多少公斤(表上方那一行)。
                //   下面的汇总(毛值 / 加工费 / 折扣 / 净值 / 单价)不是这张表的行,不写进来。
                exportSpec={{
                    name: 'pricing-price-breakdown',
                    title: t('pricing.calcResult'),
                    aboutExtra: [
                        [t('table.export.aboutPreview'), t('table.export.aboutPricePreviewValue', { at: sgStamp(stamp.at) })],
                        [t('pricing.calcFormula'), `${res.formula_code} ${res.formula_name}`],
                        [t('pricing.calcDate'), res.reference_date],
                        [t('pricing.calcQuantity'), String(res.quantity_kg)],
                    ],
                }}
            />

            <div className="mt-4 max-w-md ml-auto text-sm space-y-1">
                <div className="flex justify-between">
                    <span className="text-[color:var(--brand-muted-text)]">{t('pricing.grossValue')}</span>
                    <span>
                        {formatMoneyBare(res.gross_value_usd, SUMMARY_CCY_STATED_IN)}
                    </span>
                </div>
                <div className="flex justify-between">
                    <span className="text-[color:var(--brand-muted-text)]">{t('pricing.treatmentCharge')}</span>
                    <span>
                        −{formatMoneyBare(res.treatment_usd, SUMMARY_CCY_STATED_IN)}
                    </span>
                </div>
                <div className="flex justify-between">
                    <span className="text-[color:var(--brand-muted-text)]">{t('pricing.discountAmount')}</span>
                    <span>
                        −{formatMoneyBare(res.discount_usd, SUMMARY_CCY_STATED_IN)}
                    </span>
                </div>
                <div className="flex justify-between border-t pt-1 font-bold">
                    <span>{t('pricing.netValue')}</span>
                    <span className={(res.negative_value ? 'text-red-600' : '')}>
                        {formatMoneyBare(res.net_value_usd, SUMMARY_CCY_STATED_IN)}
                    </span>
                </div>
                <div className="flex justify-between font-bold">
                    <span>{t('pricing.unitPrice')}</span>
                    <span className={(res.negative_value ? 'text-red-600' : '')}>
                        {res.unit_price_usd_per_kg}
                    </span>
                </div>
            </div>
        </div>
    )
}
