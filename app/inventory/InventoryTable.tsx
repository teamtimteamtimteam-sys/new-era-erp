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
import { DataTable, type Column } from '@/app/components/ui/data-table'

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
}

export function InventoryTable({ rows }: { rows: readonly InventoryTableRow[] }) {
    const t = useTranslations()

    // ★ R-Q5:数与单位并成一个值,链接只挂在【数】上 —— 单位不是另一个去处。
    //   转换前这段是提出来写一次的(两档共用同一份节点),这里同样只写一份。
    const qtyNode = (qty: number, unit: string, href: string) => (
        <>
            {qty > 0 ? (
                <Link href={href} className="text-blue-600 hover:underline">
                    {qty}
                </Link>
            ) : (
                qty
            )}
            {' '}{unit}
        </>
    )

    const columns: Column<InventoryTableRow>[] = [
        {
            // 身份列:一行台账的主语是那一种物料。
            key: 'material',
            header: t('inventory.colMaterial'),
            priority: true,
            render: (r) => r.name,
        },
        {
            key: 'category',
            header: t('inventory.colCategory'),
            render: (r) => r.category,
        },
        {
            // ★ 进料库存留在手机上 —— 转换前它就没有 hidden sm:table-cell。
            key: 'inboundStock',
            header: t('inventory.colInboundStock'),
            priority: true,
            render: (r) => qtyNode(r.inboundStock, r.unit, `/inventory/inbound/${r.materialId}`),
        },
        {
            key: 'avgPrice',
            header: t('valuation.colAvgPrice'),
            render: (r) => r.avgPriceText,
        },
        {
            key: 'stockValue',
            header: t('valuation.colStockValue'),
            render: (r) => r.stockValueText,
        },
        {
            // ★ 产出量【连着它的链接一起折】—— 转换前它也是折起来的那五列之一,
            //   而展开区里那条链接点得到。够不着的钻取入口等于没有这个入口,
            //   所以它必须是展开区里【带着链接】的那一份,不是一个光秃秃的数。
            key: 'outputStock',
            header: t('inventory.colOutputStock'),
            render: (r) => qtyNode(r.outputStock, r.unit, `/inventory/output/${r.materialId}`),
        },
        {
            key: 'costValue',
            header: t('valuation.colCostValue'),
            render: (r) => r.costValueText,
        },
        {
            // ★ 市价价值留在手机上 —— 转换前它就没有 hidden sm:table-cell。
            key: 'marketValue',
            header: t('valuation.colMarketValue'),
            priority: true,
            render: (r) => r.marketValueText,
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
        />
    )
}
