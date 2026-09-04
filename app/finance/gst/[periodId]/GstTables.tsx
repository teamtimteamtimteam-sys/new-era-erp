'use client'

// app/finance/gst/[periodId]/GstTables.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-9(2026-09-04)· 一个 GST 期间的两张表 —— F5 九格 + 钻取明细
// ════════════════════════════════════════════════════════════════════════════
//
// 【一个文件两个表组件】与 CONV-5 的 ContractsTables / SnapshotTables 同形:
// 两张表属于同一页、同一段推导,分成两个文件只会让读的人多跳一次。
// 闸数的是【调用点】,所以这里是 2 个。
//
// ★★【F5 那张表手机上留【格号】与【金额】,而【格名】刻意不留】★★
// 这一条不是本刀拍的板 —— **页面自己已经把理由写下来了**:
//     「**格【号】才是标识**,而它就在左边自己一列;标签是确认用的说明文字。」
// 而这一页被打开的场合就是【把数字敲进 myTax Portal】,那件事要的正好是
// 「第几格 · 多少钱」。所以两列就是这张表在小屏上的全部内容,格名进展开区。
//
// ☞ 一个必须说出口的代价:**「打开」那一列在 390px 上落进展开区。**
//   它仍然点得到(展开区照渲染),但它不再和数字并排。四列里选两列,
//   而这一列是四列中唯一一个【动作】—— 记在人工走查清单里,请人确认
//   在手机上钻取还找得到。(闸测得出"有没有声明",测不出"留下的是不是对的那几列"。)
//
// 【双语标签在服务端就选好了】`locale === 'zh' ? label_zh : label_en` 是
// 一次服务端判断,压平成一个字符串过界 —— 而不是把两个字段都传过来在客户端选。
// (check-bilingual-concat 守的是"两个插值拼一起";这里连拼的机会都没有。)
import * as React from 'react'
import Link from 'next/link'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { useTranslations } from '@/lib/i18n/client'

export type F5BoxRow = {
    id: string
    /** 去掉 'box' 前缀之后的格号,例如 '1'。 */
    boxNo: string
    label: string
    /** 结构性为零 —— 要说出来,不能只显示 0。 */
    notDerived: boolean
    amountText: string
    /** 可钻取的格才给 href。 */
    drillHref: string | null
    highlighted: boolean
}

export function F5BoxesTable({ rows }: { rows: readonly F5BoxRow[] }) {
    const t = useTranslations()

    const columns: Column<F5BoxRow>[] = [
        {
            key: 'box',
            header: t('gst.box'),
            // ★ 身份列 —— 见抬头:格号才是标识,这是页面自己写下的判据。
            priority: true,
            className: 'font-mono',
            render: (r) => r.boxNo,
        },
        {
            key: 'label',
            header: t('gst.boxLabel'),
            render: (r) => (
                <>
                    {r.label}
                    {/* 【结构性为零要说出来,不能只显示 0】 */}
                    {r.notDerived && <span className="block text-xs text-gray-600">{t('gst.notDerived')}</span>}
                </>
            ),
        },
        {
            key: 'amount',
            header: t('gst.amount'),
            align: 'right',
            // ★ 这张表存在的理由:每一格是多少钱。
            priority: true,
            className: 'font-mono',
            render: (r) => r.amountText,
        },
        {
            key: 'openBox',
            header: t('gst.openBox'),
            render: (r) =>
                r.drillHref ? (
                    // 【#box-detail:让链接跳到它打开的那一段】GST-FIX-1 实测:
                    // 钻取确实渲染了,但它落在文档 28% 处 —— 从表格顶上点一下,
                    // 视口一动不动。**一个看起来什么都没做的控件,比一个明确拒绝的更坏。**
                    <Link href={r.drillHref} className="text-blue-600 hover:underline text-xs">
                        {t('gst.openBox')}
                    </Link>
                ) : (
                    <span className="text-xs text-gray-500">{t('gst.notDrillable')}</span>
                ),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            // 被打开的那一格整行淡蓝 —— CONV-4 §⑨-3 的 rowClassName,与转换前同形。
            rowClassName={(r) => (r.highlighted ? 'bg-blue-50' : undefined)}
            empty={t('gst.noBoxes')}
        />
    )
}

export type F5DetailRow = {
    id: string
    docCode: string
    docDate: string
    memo: string
    /** 单据种类 · 税码 —— 已在服务端拼好。 */
    sourceText: string
    amountText: string
}

export function F5BoxDetailTable({ rows, empty }: { rows: readonly F5DetailRow[]; empty: string }) {
    const t = useTranslations()

    // 【GST-2:列是【单据中性】的】销项侧钻回的是发票与贷项凭证,它们不是分录 ——
    // 把一个发票编号印在"分录"那一列下面,正是"机器文字到了人面前"那一类的错。
    const columns: Column<F5DetailRow>[] = [
        {
            key: 'document',
            header: t('gst.document'),
            // 身份列 —— 一行钻取明细的主语是那张单据。
            priority: true,
            className: 'font-mono text-xs',
            render: (r) => r.docCode,
        },
        { key: 'date', header: t('gst.date'), className: 'font-mono text-xs', render: (r) => r.docDate },
        { key: 'memo', header: t('gst.memo'), render: (r) => r.memo },
        { key: 'source', header: t('gst.source'), className: 'text-xs', render: (r) => r.sourceText },
        {
            key: 'amount',
            header: t('gst.amount'),
            align: 'right',
            // ★ 钻取存在的理由:这张单据往这一格里贡献了多少。
            priority: true,
            className: 'font-mono',
            // 贷项凭证是负数 —— 它是一笔【负的供应】,照直印
            render: (r) => r.amountText,
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
        />
    )
}
