'use client'

// app/finance/packs/PackTables.tsx
// ★ TABLE-CONVERT-2(2026-09-10):从 PackBody.tsx 里搬出来的两张表。
//
// 【为什么必须是新文件】PackBody 是 server component
//   (`export default async function`,await getTranslations()),而表格组件的
//   列描述符带 `render: (row) => ReactNode` —— **函数跨不过 server→client 的边界**,
//   留在原地【编译不过】。这是 TABLE-CONVERT-1 在 app/me/page.tsx 上撞到的同一条,
//   处置也照抄它:金额在服务端格好再过界,过来的只有字符串。
//
// 【两张表住在一个文件里,因为它们本来就住在一个文件里】—— PackBody 那一份是
//   一个不可分的单位(两张表一起转,或者都不转)。
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

/** 勾稽的一行。金额【已经在服务端 formatAmount 过】,这里一个数都不算。 */
export type ReconRow = {
    /** 'ar' | 'ap' —— 原样传过来,标签由这一侧翻译(免得把 key 变成算出来的东西)。 */
    side: string
    controlAccount: string
    ledger: string
    subledger: string
    difference: string
    origination: string
    settlement: string
    revaluation: string
    unexplained: string
    reconciled: boolean
}

export function ReconTable({ rows }: { rows: ReconRow[] }) {
    const t = useTranslations()

    // ★ 手机上留三列 —— TABLE-PHONE-2 的判断,一个字没改:侧别 · 差额 · 未解释。
    //   勾稽这一张存在的理由就是【差额有多少、其中多少解释不掉】,而「未解释」
    //   那一格自己带着红色 —— 状态不在另一列里,就在那个数上。
    const reconColumns: Column<ReconRow>[] = [
        {
            key: 'side', header: t('pack.colSide'), priority: true,
            render: (s) => t(s.side === 'ar' ? 'pack.sideAr' : 'pack.sideAp'),
        },
        { key: 'control', header: t('pack.colControl'), render: (s) => s.controlAccount },
        { key: 'ledger', header: t('pack.colLedger'), align: 'right', render: (s) => s.ledger },
        { key: 'subledger', header: t('pack.colSubledger'), align: 'right', render: (s) => s.subledger },
        {
            key: 'difference', header: t('pack.colDifference'), align: 'right', priority: true, render: (s) => s.difference,
        },
        { key: 'origination', header: t('pack.colOrigination'), align: 'right', render: (s) => s.origination },
        { key: 'settlement', header: t('pack.colSettlement'), align: 'right', singleValue: true,  /* ★ POLISH-1 R7 · spec §4.3a:这一格是一个数,不是一段文字 */ render: (s) => s.settlement },
        { key: 'revaluation', header: t('pack.colRevaluation'), align: 'right', render: (s) => s.revaluation },
        {
            key: 'unexplained', header: t('pack.colUnexplained'), align: 'right', priority: true,
            // ★★【那一格的红【是整格的】,而 Column.className 是每列一份静态字符串】★★
            //   转换之前那是 <td className={… + (reconciled ? '' : 'bg-red-50 …')}> ——
            //   **一个【按行】变的格子底色**,而组件今天没有这个口子
            //   (className 是每列一份;rowClassName 管的是整行,不是一格)。
            //   ☞ 所以底色搬进 render 里的一个 <span>,并且用 block + 与格子相同的
            //     内边距 + 相反的负外边距把它撑回【整格】那么大 ——
            //     红色的那块矩形因此与转换之前【同样大】,而不是缩成数字背后一小条。
            //   ☞ 这一处是量过的,不是推的:交回报告 §5 有两档的矩形读数。
            //   ⚠ 它对 px-3 py-2.5 那两个值【是硬编码的】—— 组件的格子内边距一旦改,
            //     这里要跟着改。已按名登记为一处缺口:组件缺【按行的格子 className】。
            render: (s) => (
                <span className={'block -mx-3 -my-2.5 px-3 py-2.5 ' +
                    (s.reconciled ? '' : 'bg-red-50 text-red-800 font-semibold')}>
                    {s.unexplained}
                </span>
            ),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={reconColumns}
            rowKey={(s) => s.side}
            phone={{ mode: 'columns' }}
        />
    )
}

/** 拆散在两个月的冲销对。日期与金额都已在服务端格好。 */
export type SplitRow = {
    entryCode: string
    entryDate: string
    counterpartCode: string
    counterpartDate: string
    amount: string
}

export function SplitPairsTable({ rows }: { rows: SplitRow[] }) {
    const t = useTranslations()

    // ★ 手机上留三列 —— TABLE-PHONE-2 的判断,一个字没改:分录 · 对手件 · 金额。
    //   这张表的一行【就是一对】,所以两个单号一起构成身份:只留一半的话,
    //   剩下的那半没有对手,这张表也就没有意义了。两个日期进展开区。
    const splitColumns: Column<SplitRow>[] = [
        { key: 'entry', header: t('pack.colEntry'), priority: true, render: (s) => s.entryCode },
        { key: 'date', header: t('pack.colDate'), render: (s) => s.entryDate },
        {
            key: 'counterpart', header: t('pack.colCounterpart'), priority: true,
            render: (s) => s.counterpartCode,
        },
        { key: 'counterpartDate', header: t('pack.colCounterpartDate'), render: (s) => s.counterpartDate },
        {
            key: 'amount', header: t('pack.colAmount'), align: 'right', priority: true,
            render: (s) => s.amount,
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={splitColumns}
            rowKey={(s) => s.entryCode}
            phone={{ mode: 'columns' }}
        />
    )
}
