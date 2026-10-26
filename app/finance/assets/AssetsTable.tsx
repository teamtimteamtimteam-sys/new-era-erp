'use client'

// app/finance/assets/AssetsTable.tsx
// ★ TABLE-CONVERT-2(2026-09-10):从 app/finance/assets/page.tsx 里搬出来的固资台账。
//
// 【为什么必须是新文件】page.tsx 是 server component,而列描述符带 render 函数 ——
//   函数跨不过 server→client 的边界,留在原地【编译不过】。这个文件里本来就有
//   同一个形状的先例(DepreciationPreviewTable),这一份照着它做。
//   金额、日期、以及"投用日那句话"都在服务端算好格好再过界,屏幕上的字因此不变。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xMoney, xDate, xInt } from '@/lib/export/cells'
import AssetActions from './AssetActions'
import type { ListTotal } from '@/lib/listTotals'
import { totalsFooterRows } from '@/app/components/ui/list-totals'

export type AssetsTableRow = {
    id: string
    code: string
    description: string
    /** 原始 category —— 标签在这一侧翻译,与转换之前同一句 t('assets.category.'+x)。 */
    category: string
    acquisitionDate: string
    /** 投用日那句话,已在服务端算好(inServiceState + t)—— 两档共用同一个值。 */
    inServiceText: string
    /** 没有投用日时那句话画成琥珀小字,与转换之前逐字相同。 */
    inServicePending: boolean
    /** 原币成本,已格式化。 */
    costCcy: string
    /** 非本位币时才画的那个汇率尾巴;本位币是 null。 */
    fxRate: string | null
    costBase: string
    usefulLifeMonths: number
    accum: string
    nbv: string
    status: string
    // ── AssetActions 要的那几个(每行各一份;canEdit 与 bankAccounts 是整张表共用的)──
    inServiceDate: string | null
    plannedInServiceDate: string | null
    hasCost: boolean
    /** APR-9:这台资产上那一张在等的处置申请的 label(处置钮因此按不动并指向它);没有就是 null */
    pendingDisposalLabel: string | null
    // ── TABLE-EXPORT-2a:导出读【原始值】(Excel 里数是数、日期是日期)──
    acquisitionDateRaw: string | null
    inServiceDateRaw: string | null
    currency: string
    costCcyAmt: number | null
    costBaseAmt: number | null
    accumAmt: number
    nbvAmt: number
}

export default function AssetsTable({
    rows, totals, canEdit, bankAccounts, baseCurrency, empty,
}: {
    rows: AssetsTableRow[]
    /** TABLE-FEATURES-2(Tim Q1):库算的合计(list_totals_fixed_assets)—— 原值每个币种一行;本位币那一行另带本位币原值 · 累计折旧 · 净值 */
    totals: ListTotal[]
    canEdit: boolean
    bankAccounts: string[]
    /** 只用来拼「金额 ({ccy})」那个列头,与转换之前同一个调用。 */
    baseCurrency: string
    empty: React.ReactNode
}) {
    const t = useTranslations()

    // ★ 手机上留【编号 · 净值 · 状态】—— TABLE-PHONE-1 的判断,一个字没改。
    //   其余九列进展开区。
    //
    // ★★【动作列是 priority —— 接着 TABLE-STYLE-1 / R1 往下走】★★
    //   转换之前那一列带着 hidden sm:table-cell,而那颗处置钮【另外画了一份在
    //   身份格里】—— 也就是说它在手机上本来就不用点开任何东西就够得着
    //   (原注释写的正是这个理由:「一个在手机上够不着的处置钮,与没有这个钮
    //   是同一回事」)。组件里没有"叠在身份格里画出来"这一档:要么 priority,
    //   要么进【点一下才展开】的那一段。折进去就等于把 R1 判过的那件事撤销。
    //   ☞ 所以它 priority:true —— "不点就够得着"这件事没有变。
    const columns: ExportableColumn<AssetsTableRow>[] = [
        {
            key: 'code', header: t('finance.colCode'), priority: true,
            exportAs: (a) => xText(a.code),
            render: (a) => (
                <Link href={`/finance/assets/${a.id}`} className="hover:underline app-link">
                    {a.code}
                </Link>
            ),
        },
        { key: 'description', header: t('assets.colDescription'), render: (a) => a.description, exportAs: (a) => xText(a.description) },
        { key: 'category', header: t('assets.colCategory'), render: (a) => t('assets.category.' + a.category), exportAs: (a) => xText(t('assets.category.' + a.category)) },
        { key: 'acquired', header: t('assets.colAcquired'), render: (a) => a.acquisitionDate, exportAs: (a) => xDate(a.acquisitionDateRaw) },
        {
            key: 'inService', header: t('assets.colInService'),
            // TABLE-FEATURES-1 Q9:导出值一时是日期、一时是一句话 —— 排序只按真日期,还没投用的(空)排在最后
            sortValue: (a) => a.inServiceDateRaw,
            // 有投用日就是那个真日期;没有就是屏幕上那句话(「计划 … 投用」之类)
            exportAs: (a) => (a.inServiceDateRaw ? xDate(a.inServiceDateRaw) : xText(a.inServiceText)),
            render: (a) => (a.inServicePending
                ? <span className="text-amber-700 text-xs">{a.inServiceText}</span>
                : <>{a.inServiceText}</>),
        },
        {
            key: 'cost', header: t('assets.colCost'), align: 'right',
            // TABLE-FEATURES-1 Q9(规矩 5):原币成本各带各的币种 —— 按本位币成本排
            sortValue: (a) => a.costBaseAmt,
            // 原币成本带它自己的币种;「@ 汇率」那条尾巴是另一个数,不塞进这一格(本位币那一列就是它乘出来的)
            exportAs: (a) => xMoney(a.costCcyAmt, a.currency),
            render: (a) => (
                <>
                    {a.costCcy}
                    {a.fxRate && <span className="ml-1 text-xs text-gray-500">@ {a.fxRate}</span>}
                </>
            ),
        },
        {
            key: 'costBase', header: t('finance.colAmount', { ccy: baseCurrency }), align: 'right', singleValue: true,  /* ★ POLISH-1 R7 · spec §4.3a:这一格是一个数,不是一段文字 */ render: (a) => a.costBase,
            exportAs: (a) => xMoney(a.costBaseAmt),
        },
        {
            key: 'life', header: t('assets.colLife'), align: 'right',
            render: (a) => a.usefulLifeMonths,
            exportAs: (a) => xInt(a.usefulLifeMonths),
        },
        {
            key: 'accum', header: t('assets.colAccum'), align: 'right',
            render: (a) => a.accum,
            exportAs: (a) => xMoney(a.accumAmt, baseCurrency),
        },
        {
            key: 'nbv', header: t('assets.colNbv'), align: 'right', priority: true,
            className: 'font-medium', render: (a) => a.nbv,
            exportAs: (a) => xMoney(a.nbvAmt, baseCurrency),
        },
        {
            key: 'status', header: t('finance.colStatus'), priority: true,
            exportAs: (a) => xText(t('assets.status.' + a.status)),
            render: (a) => (
                <span className={'px-2 py-1 rounded text-xs ' +
                    (a.status === 'active' ? 'bg-green-100 text-green-800' : 'bg-gray-200 text-gray-600')}>
                    {t('assets.status.' + a.status)}
                </span>
            ),
        },
        {
            key: 'actions', header: t('assets.colActions'), priority: true, exportAs: false,
            render: (a) => (
                <AssetActions
                    assetId={a.id} code={a.code} status={a.status}
                    inServiceDate={a.inServiceDate}
                    plannedInServiceDate={a.plannedInServiceDate}
                    hasCost={a.hasCost}
                    acquisitionDate={a.acquisitionDate}
                    canEdit={canEdit} bankAccounts={bankAccounts}
                    pendingDisposalLabel={a.pendingDisposalLabel} />
            ),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(a) => a.id}
            phone={{ mode: 'columns' }}
            empty={empty}
            rowClassName={(a) => (a.status === 'disposed' ? 'text-gray-400' : undefined)}
            exportSpec={{ name: 'fixed-assets', title: t('assets.title') }}
            // TABLE-FEATURES-1 Q9:台账一次读全(fixed_assets 不翻页)—— 在浏览器里排
            sorting={{ mode: 'client', coverage: 'complete' }}
            footer={() => totalsFooterRows(totals, { cost: 'cost', costBase: 'costBase', accum: 'accum', nbv: 'nbv' }, t)}
        />
    )
}
