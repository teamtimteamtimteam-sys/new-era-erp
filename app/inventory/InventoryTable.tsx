'use client'

// app/inventory/InventoryTable.tsx
// TABLE-CONVERT-4:/inventory 那张 8 列台账从手搓 <table> 换成 DataTable。
//
// 【为什么要多这一个文件】页面是 server component;Column.render 是函数,跨不过
//   server→client 边界。钱与单位在服务端就格式化好(formatMoneyBare 带着它那条
//   「这个数是哪种币」的出处参数),这里拿到的全是【已经成文的字符串】,
//   所以渲染出来的字与转换前逐字相同。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xNum, xMoney, xMasked } from '@/lib/export/cells'
import { totalsFooterRows } from '@/app/components/ui/list-totals'
import type { ListTotal } from '@/lib/listTotals'

export type InventoryTableRow = {
    materialId: string
    /** 转换前就是 `r.name ?? '—'`,横杠在服务端已经落好。 */
    name: string
    category: string
    inboundStock: number
    outputStock: number
    /** unitLabel() 的结果 —— 数与单位是【一个值】(R-Q5),这一条原样保留。 */
    unit: string
    avgPriceText: string
    stockValueText: string
    costValueText: string
    marketValueText: string
    /** TABLE-EXPORT-1:四个钱数的原始值(null = 屏幕上那根「—」)。导出用,不再由那几串字反解。 */
    avgPrice: number | null
    stockValue: number | null
    costValue: number | null
    marketValue: number | null
}

export function InventoryTable({ rows, pricesRestricted, totals }: {
    rows: readonly InventoryTableRow[]
    /**
     * TABLE-FEATURES-2(Tim 2026-10-26):list_totals_inventory() 读回来的表尾合计 —— 取代了页面上那条估值合计条。
     * 本位币一行(库存价值 · 成本价值,读者没有 data.view_prices 时两格「受限」)、USD 一行(市价价值,不遮蔽)。
     * 加权均价是价,不合计。
     */
    totals: readonly ListTotal[]
    /**
     * TABLE-EXPORT-1(Q3):读者没有 data.view_prices(TABLE-FEATURES-2 起按权限判,与表尾「受限」同一个判据)——
     * 均价 · 库存价值 · 成本价值三列被 data.view_prices 管着,读不到时每一行是 null。
     * 导出里那一格写「Restricted」,不是空。市价价值不归这条权限管,照常导出。
     */
    pricesRestricted: boolean
}) {
    const t = useTranslations()

    // ★ R-Q5:数与单位并成一个值,链接只挂在【数】上 —— 单位不是另一个去处。
    //   转换前这段是提出来写一次的(两档共用同一份节点),这里同样只写一份。
    const qtyNode = (qty: number, unit: string, href: string) => (
        <>
            {qty > 0 ? (
                <Link href={href} className="hover:underline app-link">
                    {qty}
                </Link>
            ) : (
                qty
            )}
            {' '}{unit}
        </>
    )

    // ★ TABLE-FEATURES-1 Q9:库存数量逐行带着各自物料的单位 —— 这一屏的行都是同一个单位时才可排
    //   (线上今天 5 种物料全是 kg,以 postgres 读基表,2026-10-25),否则不同单位的数排在一起没有意义。
    const oneUnit = new Set(rows.map((r) => r.unit)).size <= 1
    const columns: ExportableColumn<InventoryTableRow>[] = [
        {
            // 身份列:一行台账的主语是那一种物料。
            key: 'material',
            header: t('inventory.colMaterial'),
            priority: true,
            render: (r) => r.name,
            exportAs: (r) => xText(r.name),
        },
        {
            key: 'category',
            header: t('inventory.colCategory'),
            render: (r) => r.category,
            exportAs: (r) => xText(r.category),
        },
        {
            // ★ 进料库存留在手机上 —— 转换前它就没有 hidden sm:table-cell。
            key: 'inboundStock',
            sortable: oneUnit ? undefined : false,
            header: t('inventory.colInboundStock'),
            priority: true,
            render: (r) => qtyNode(r.inboundStock, r.unit, `/inventory/inbound/${r.materialId}`),
            exportAs: (r) => xNum(r.inboundStock, 'qty', r.unit), // TABLE-EXPORT-1:屏幕上数后跟着单位,一起写
        },
        {
            key: 'avgPrice',
            header: t('valuation.colAvgPrice'),
            render: (r) => r.avgPriceText,
            exportAs: (r) => xMasked(r.avgPrice, !pricesRestricted, xMoney),
        },
        {
            key: 'stockValue',
            header: t('valuation.colStockValue'),
            render: (r) => r.stockValueText,
            exportAs: (r) => xMasked(r.stockValue, !pricesRestricted, xMoney),
        },
        {
            // ★ 产出量【连着它的链接一起折】—— 转换前它也是折起来的那五列之一,
            //   而展开区里那条链接点得到。够不着的钻取入口等于没有这个入口,
            //   所以它必须是展开区里【带着链接】的那一份,不是一个光秃秃的数。
            key: 'outputStock',
            sortable: oneUnit ? undefined : false,
            header: t('inventory.colOutputStock'),
            render: (r) => qtyNode(r.outputStock, r.unit, `/inventory/output/${r.materialId}`),
            exportAs: (r) => xNum(r.outputStock, 'qty', r.unit),
        },
        {
            key: 'costValue',
            header: t('valuation.colCostValue'),
            render: (r) => r.costValueText,
            exportAs: (r) => xMasked(r.costValue, !pricesRestricted, xMoney),
        },
        {
            // ★ 市价价值留在手机上 —— 转换前它就没有 hidden sm:table-cell。
            key: 'marketValue',
            header: t('valuation.colMarketValue'),
            priority: true,
            render: (r) => r.marketValueText,
            exportAs: (r) => xMoney(r.marketValue),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.materialId}
            phone={{ mode: 'columns' }}
            // ★ 空态搬进 prop,用的是同一个 key。转换前它写了【两遍】
            //   (手机 colSpan=3 一份、桌面 colSpan=8 一份),因为 colSpan 不能随
            //   断点变;组件自己按看得见的列数算 colSpan,所以这里只需要一份。
            empty={t('inventory.emptyState')}
            exportSpec={{ name: 'inventory', title: t('inventory.listTitle') }}
            // TABLE-FEATURES-1 Q9:整张台账一次拿全,在浏览器里排。三列钱被 data.view_prices 遮住时导出值是「受限」(null),
            //   永远排在最后 —— 排序不泄露看不见的数。钱都是本位币,可比。
            sorting={{ mode: 'client', coverage: 'complete' }}
            footer={() => totalsFooterRows(totals, { stockValue: 'stockValue', costValue: 'costValue', marketValue: 'marketValue' }, t)}
        />
    )
}
