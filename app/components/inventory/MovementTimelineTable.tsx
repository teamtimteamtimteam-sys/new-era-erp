'use client'

// app/components/inventory/MovementTimelineTable.tsx
// TABLE-CONVERT-6:库存流水时间线那张手搓 <table> 换成 DataTable。
//
// ★★【这张表此前【没有】手机档判断 —— 本刀是第一个做的】★★
//   转换前一处 hidden sm:table-cell 都没有。实测(真路由、线上真数据):
//   390px 上要横拖 389px(/inbound)· 372px(/output),七列全在外层
//   overflow-x-auto 里横着躺着。
//   ⚠ 而它是本族第一批【桌面上本来就在滚】的表:1280px 上也要拖 139px / 122px。
//
// ★【留哪三列 —— 时间 · 类型 · 数量】
//   · 时间:身份。一条流水就是"某一刻发生的一次数量变动",行按 occurred_at DESC 排,
//     除了时间没有别的东西能认出它。
//   · 类型:没有它,一行只剩"某时某刻,±N kg"——【什么事】没了。
//   · 数量:结论。这张表存在的理由就是那个带符号的增减。
//
// ★★【一处要给 Tim 看的取舍:「桶」折进了展开区】★★
//   源码抬头写着 SO-2 的理由:「成对流水的两条腿在此之前读起来完全一样 ——
//   暂扣与预留都是『状态变更(出/进)』」。**桶正是为了拆开这种同形而加的列。**
//   我仍然折了它,理由与那条不冲突,但这是我的判断:
//     · 桶带着自己的列头躺在展开区里,一点就到;
//     · 而在 390px 的 table-fixed 下,第四列要吃掉四分之一屏宽,
//       代价落在【时间/类型/数量】三列的折行上 —— 那三列是每一行都要读的。
//   ☞ 如果 Tim 认为桶必须与类型同屏,那是把它提成 priority 的事,一行改动。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

/** 服务端压平好的一行 —— 一个函数都没有。 */
export type MovementTableRow = {
    key: string
    timeText: string
    typeText: string
    bucketText: string
    /** 带符号 + 单位,服务端拼好(与转换前逐字相同) */
    qtyText: string
    /** 出库(负)红、入库(正)绿 —— 转换前是按行算的 class */
    qtyNegative: boolean
    runHref: string | null
    runCode: string | null
    businessDate: string
    notes: string
}

export default function MovementTimelineTable({ rows }: { rows: readonly MovementTableRow[] }) {
    const t = useTranslations()

    const columns: Column<MovementTableRow>[] = [
        {
            key: 'time',
            header: t('movements.colTime'),
            // ★ 身份 —— 手机上留下。
            priority: true,
            className: 'text-gray-600',
            render: (r) => r.timeText,
        },
        {
            key: 'type',
            header: t('movements.colType'),
            // ★ 这一行【是什么事】—— 手机上留下。
            priority: true,
            render: (r) => r.typeText,
        },
        {
            key: 'bucket',
            header: t('movements.colBucket'),
            render: (r) => r.bucketText,
        },
        {
            key: 'qty',
            header: t('movements.colQty'),
            // ★ 结论 —— 手机上留下。
            priority: true,
            align: 'right',
            className: 'font-mono',
            // ⚠ 转换前颜色按行算(负红/正绿),而组件今天没有按行的格子 className
            //   (已登记的缺口,本刀不修)—— 条件搬进格子里那层 <span>。
            render: (r) => (
                <span className={r.qtyNegative ? 'text-red-600' : 'text-green-700'}>{r.qtyText}</span>
            ),
        },
        {
            key: 'run',
            header: t('movements.colRun'),
            className: 'font-mono',
            render: (r) =>
                r.runHref && r.runCode ? (
                    <Link href={r.runHref} className="text-blue-600 hover:underline">
                        {r.runCode}
                    </Link>
                ) : (
                    '—'
                ),
        },
        {
            key: 'bizDate',
            header: t('movements.colBizDate'),
            render: (r) => r.businessDate,
        },
        {
            key: 'notes',
            header: t('movements.colNotes'),
            render: (r) => r.notes,
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.key}
            phone={{ mode: 'columns' }}
            // 空态从 MovementTimeline 的 `rows.length === 0 ?` 那一支搬进来,【同一个 key】。
            // 旧那一支已经删掉 —— TABLE-CONVERT-3 §6.1 那处死代码不再犯第二次。
            empty={t('movements.empty')}
        />
    )
}
