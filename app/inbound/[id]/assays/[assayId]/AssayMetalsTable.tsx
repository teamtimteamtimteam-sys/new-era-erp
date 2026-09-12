'use client'

// app/inbound/[id]/assays/[assayId]/AssayMetalsTable.tsx
// TABLE-CONVERT-4:化验单详情的【金属表】(2 列)从手搓 <table> 换成 DataTable。
//
// 【为什么要多这一个文件】页面是 server component,而 Column.render 是一个函数,
//   函数跨不过 server→client 那道边界(TABLE-CONVERT-1 量到、TABLE-CONVERT-2 §2.2
//   在 20 张表上复核过的同一条)。所以行在【服务端】压平成字符串,这里只负责画。
//
// 【一次判断,两个文件】/output/[id]/assays/[assayId] 那张金属表与这一张
//   标记逐字相同(同样两列、同样的 i18n key、同样没有一处 hidden sm:table-cell)。
//   两处用同一个形状改,免得日后各自漂 —— 与 TABLE-CONVERT-3 的三份
//   AttachmentsPanel 是同一条做法。
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type AssayMetalRow = {
    metal: string
    /** 服务端译好的金属名 —— t() 不跨边界,这里不现译。 */
    metalLabel: string
    /** 服务端格式化好的含量文本;渲染出来的字与转换前逐字相同。 */
    contentPct: string
}

export function AssayMetalsTable({ rows }: { rows: readonly AssayMetalRow[] }) {
    const t = useTranslations()
    const columns: Column<AssayMetalRow>[] = [
        {
            key: 'metal',
            header: t('assay.colMetal'),
            // ★ 两列都 priority。转换前这张表【一处 hidden sm:table-cell 都没有】,
            //   两列在 390px 上本来就都看得见 —— 这里搬的是那个事实,不是一次新判断。
            priority: true,
            render: (r) => (
                <>
                    {r.metalLabel}
                    <span className="text-gray-400 text-xs ml-2">{r.metal}</span>
                </>
            ),
        },
        {
            key: 'content',
            header: t('assay.colContent'),
            align: 'right',
            priority: true,
            // ⚠ 转换前这一格是 `font-mono text-sm`。**text-sm 没有搬过来** ——
            //   验收条款「列定义里不许钉字号」。它本来也是多余的:组件表根就是
            //   text-sm(14px),这一格不写字号继承到的是同一个 14px。
            //   ★★ FONT-3(2026-09-12):那个继承来的数今天是 **15px**,不再是 14px ——
            //     `TABLE_TEXT` 排在组件 `cn()` 的最后(见 table-style.ts)。
            //     ☞ 这一格**不写字号**仍然是对的做法,而且现在**写了也没有用**。
            render: (r) => r.contentPct,
        },
    ]
    // ★ 没有给 empty:转换前 metals 为空时画的是【一张只有表头的表】,
    //   页面没有写过任何空态文案。不替它编一句(委托书:不许无中生有一个空态)。
    //   组件自己会画 table.empty —— 那是组件既有的字,不是本刀新造的词,报在交回报告里。
    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.metal}
            phone={{ mode: 'columns' }}
            className="max-w-md mb-6"
        />
    )
}
