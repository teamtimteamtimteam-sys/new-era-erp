// app/components/ui/record-header.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-8(2026-09-04)· 详情页的记录抬头 —— 【一个盒子,不是一份字段表】
// ════════════════════════════════════════════════════════════════════════════
//
// 【它为什么存在,而 CONV-3 的 AddRowPanel 是它的先例】
// 详情页 37 张逐页量过:25 张带一个「记录抬头」(一条记录的若干 标签:值),
// 而它们今天是【三种不同的写法】——
//     flex flex-wrap gap-x-8 的一排 标签:值   ×17
//     grid grid-cols-N                        ×12
//     bg-gray-50 rounded p-4 的一块面板        ×19
//     <dl>                                     ×5
// 同一样东西四种写法,而**没有任何一种是"对"的** —— 它们只是各写各的。
// 本仓库对「同一个形状第三次出现」的处置是把它收敛掉(DataTable 的
// rowClassName 是第 5 处才建的),25 处远过了那道坎。
//
// ★【收敛到【盒子】为止,不收字段 —— 与 AddRowPanel 逐字同一条判据】★
// 25 张抬头的字段【逐页不同】:分录是 单号/日期/来源/状态;采购单是
// 单号/供应商/币种/状态/应付/已付;考勤是 期间/员工/状态。字段数从 2 到 8,
// 有的格子里是徽章、有的是链接、有的是 MaskedValue。
// **把字段也收进来,会逼这个组件去认识二十五种不同的记录形状** ——
// 那正是 editable-table.tsx 抬头拒绝对 DataTable 做的事,换了个更小的场景。
// 所以这里只管:底色、圆角、内距、换行、标签与值的字重、以及动作放哪儿。
//
// ★★【它【不是】'use client' —— 而这一条是本刀最省的一笔】★★
// CONV-1 §① 记下那个没人算过的代价:DataTable 的 `Column.render` 是【函数】,
// RSC 不能把函数传过客户端边界,于是**每一张只读列表页都要多一个客户端文件**
// (129 个)。**本组件的 props 全部是数据与 ReactNode,一个函数都没有**,
// 所以它留在服务端,页面直接在 page.tsx 里用它,**不多一个文件**。
// 这不是省事:它意味着「套抬头」这件事在 37 张详情页上的边际成本接近于零,
// 而多出来的文件只由那些真的有表的页面承担。
//
// ★【手机:抬头才是详情页的溢出元凶,不是表】★
// CONV-5 实测:/settings/deleted 转换后 clippedTables 已经是 0,整页却仍然
// 溢出 27px —— 顶宽的是一条【不折行的筛选行】。DataTable 只管表;
// 一页的手机可用度可以被表以外的东西毁掉,而详情页表以外的东西就是这个抬头。
// 所以本组件在【构造上】不可能顶宽:
//     flex-wrap  —— 字段横排到底,排不下就换行(不是横向滚动);
//     min-w-0 + break-words —— 一个长值(法人全名、备注)不能把行撑开;
//     gap-x-8 gap-y-2 —— 换行之后上下两排不会黏在一起。
// **它不需要一个 phone prop**:DataTable 需要那个 prop 是因为「哪几列留下」
// 是一个【判断】,组件猜不了;而抬头的每一个字段都留下,只是换行而已 ——
// 没有要做的判断,就不该造一个要人回答的必填项。
//
// ★【动作放在抬头里,而那正是详情页版本的「空态吃掉出口」】★
// 列表页的出口是筛选栏/新建钮;**详情页的出口是这条记录的动作**
// (冲销、取消、批准、重开)。实测它们今天就住在抬头那一块里
// (/finance/journal/[id] 的 <ReverseButton> 就在抬头 div 内)。
// 于是 `actions` 是本组件的一个具名槽,而不是让页面把按钮混进 fields ——
// 混进去会让一个【动作】被当成一个【值】排版,而且在手机上跟着字段一起换行。
//
// ☞ 后来的人:详情页不要用 ListPage 的 `empty` 分支。**一条记录存在与否由
//   notFound() 回答,不由空态回答** —— 页面画得出来就说明记录在,
//   空的只可能是它下面某一张子表,那句空态归那张表自己说(DataTable 的 empty)。
//   `state` 恒为 'ok' 于是不是一个权宜之计,是这个形状的正确答案,
//   而它顺带让「出口被空态吃掉」这一类在详情页上【构造上不可能发生】。
import * as React from 'react'
import { cn } from '@/lib/utils'

export type RecordField = {
    /** 这一格的标签。 */
    label: React.ReactNode
    /**
     * 这一格的值。徽章、链接、MaskedValue 都照传 ——
     * 本组件不认识它们,也不该认识。
     */
    value: React.ReactNode
    /**
     * 等宽。单号、批次号、科目代码这一类【稳定标识】用它,
     * 与 EditableTable 里「编号那格仍然是灰色等宽字」是同一个视觉约定。
     */
    mono?: boolean
}

export function RecordHeader({
    fields,
    actions,
    className,
}: {
    /**
     * 这条记录的若干 标签:值。**逐页各写各的** —— 见抬头,
     * 本组件只把它们排开,不认识其中任何一个。
     */
    fields: readonly RecordField[]
    /**
     * 这条记录的动作(冲销、取消、批准…)。
     * 独立于 fields,因为一个动作不是一个值 —— 见抬头那一段。
     */
    actions?: React.ReactNode
    className?: string
}) {
    return (
        <div
            className={cn(
                // bg 用 --brand-muted(#E5EEF4「表头/条纹底」),不是 --brand-surface(纯白):
                // 抬头要与它下面那张表的表头是同一族的底色,而不是与页面底色齐平 ——
                // 转换前那 19 处写的 bg-gray-50 表达的正是这个意思。
                'mb-6 rounded border border-[color:var(--brand-border)] bg-[color:var(--brand-muted)] p-4',
                'flex flex-wrap items-center gap-x-8 gap-y-2 text-sm',
                className,
            )}
        >
            {fields.map((f, i) => (
                // min-w-0 是承重的:没有它,一个长值会把这一格撑到不换行,
                // 整页于是顶出横向滚动 —— 详情页手机溢出的头号来源。
                <div key={i} className="min-w-0">
                    {/* --brand-muted-text,不是 --brand-muted:后者是【底色】(#E5EEF4),
                        拿它当文字色会在白底上几乎看不见。两个名字只差一个词、方向相反。 */}
                    <span className="mr-1 text-[color:var(--brand-muted-text)]">{f.label}:</span>
                    <span
                        className={cn(
                            'break-words text-[color:var(--brand-text)]',
                            f.mono && 'font-mono font-medium',
                        )}
                    >
                        {f.value}
                    </span>
                </div>
            ))}
            {/* ml-auto 只在还排得下时把动作推到右边;换行之后它自然落到下一排开头。 */}
            {actions && <div className="ml-auto flex flex-wrap items-center gap-2">{actions}</div>}
        </div>
    )
}
