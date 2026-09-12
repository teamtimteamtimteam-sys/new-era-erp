'use client'

// app/stocktakes/[id]/PostedLinesTable.tsx
// TABLE-CONVERT-5:盘点单 posted / cancelled 之后那张只读行表换成 DataTable。
//
// ★★【这张表此前【没有】手机档判断 —— 本刀是第一个做的】★★
//   转换前一处 hidden sm:table-cell 都没有,五列在 390px 上靠外层 overflow-x-auto
//   横着拖(TABLE-MEASURE-1 实测 +56px)。而【露一半的那一列正好是 Delta】。
//
// ★★【留哪三列 —— 批次 · 物料 · 差异】★★
//   · 结论是【差异】,而且这一条不用推:**一次盘点的结论就是账面 vs 实盘的差额。**
//     读数说它在 390px 上只露一半 —— 一张盘点表最要紧的那一格在屏幕外。
//   · 身份【真的需要两列】:批次号是个不透明的单号(ST/IN/OUT-…),
//     光有它,人在手机上不知道自己在看什么料;物料名才是那句人话。
//     ☞ 与 /inbound 那张台账写下的同一条理由:「不知道是什么料,一行数字没有意义」。
//
// 【账面 / 实点 为什么折 —— 而且是【成对】折的】
//   差异就是这两个数相减出来的,它们【只有摆在一起才有意义】:
//   单独留一个,人得自己拿差异去倒推另一个。所以要么两个都留、要么两个都折。
//   两个都留就是五列全留(等于没做判断),于是成对折进展开区,各带自己的列头。
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

/** 服务端压平好的一行 —— 差额与带符号显示都在那一侧算完(app/stocktakes/delta.ts)。 */
export type PostedLineRow = {
    key: string
    code: string
    material: string
    /** `${book} ${unit}` —— book 为 null 时与转换前一样只剩单位 */
    book: string
    counted: string
    /** formatSigned(bookDelta);没有差异或账面为 null 时是 null → 画 '—' */
    deltaText: string | null
    /** 盘盈绿、盘亏红 —— 与转换前逐字相同的两个 class */
    deltaPositive: boolean
}

export default function PostedLinesTable({ rows }: { rows: readonly PostedLineRow[] }) {
    const t = useTranslations()

    const columns: Column<PostedLineRow>[] = [
        {
            key: 'batch',
            header: t('stocktakes.colBatch'),
            // ★ 身份之一 —— 手机上留下。
            priority: true,
            // ⚠ 转换前这一格是 `font-mono text-sm`;text-sm 没有搬过来
            //   (列描述符不许钉字号 —— 棘轮会红),字号由组件的表根给。
            render: (r) => r.code,
        },
        {
            key: 'material',
            header: t('stocktakes.colMaterial'),
            // ★ 身份之二 —— 手机上留下。批次号不透明,物料名才是那句人话。
            priority: true,
            render: (r) => r.material,
        },
        {
            key: 'book',
            header: t('stocktakes.bookLabel'),
            render: (r) => r.book,
        },
        {
            key: 'counted',
            header: t('stocktakes.countedLabel'),
            render: (r) => r.counted,
        },
        {
            key: 'delta',
            header: t('stocktakes.deltaLabel'),
            // ★ 结论 —— 手机上留下。读数里被切掉一半的正是这一列。
            priority: true,
            // ⚠ 转换前颜色是【按行算的】(盘盈绿 / 盘亏红),而组件今天没有按行的
            //   格子 className(已登记的缺口,本刀不修)—— 条件搬到格子里那层 <span>,
            //   渲染出来是同一件事。
            render: (r) =>
                r.deltaText !== null ? (
                    <span
                        className={
                            'font-medium ' + (r.deltaPositive ? 'text-green-600' : 'text-red-600')
                        }
                    >
                        {r.deltaText}
                    </span>
                ) : (
                    '—'
                ),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.key}
            phone={{ mode: 'columns' }}
            // 空态从表体里那一行 colSpan={5} 搬进来,【同一个 stocktakes.noLines】。
            // 旧那一支已经删掉 —— 见 TABLE-CONVERT-3 §6.1 那处死代码。
            empty={t('stocktakes.noLines')}
        />
    )
}
