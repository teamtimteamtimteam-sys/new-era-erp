'use client'

// app/components/ui/add-row-panel.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-3(2026-09-03)· 「表下面一张加一行的表单」—— 一个外壳,不是一个表单组件
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么它只是外壳,不吞掉字段】CONV-2 §③ 名下那次「add-a-row 值得收敛」的
// 提名,重新点过数之后(CONV-3)发现它就是【这一刀正在转的 4 张 Kind-E 页】,
// 不是一群还没被数过的别的页 —— 于是「两套模板都要用的共用件」这个前提不成立,
// 收敛的对象缩小成【这 4 页彼此之间】。而这 4 页的字段【逐页不同】
// (假期是日期+双语名+备注;经常性成本是六个字段带一个 cadence 下拉;
// 执照是十个字段外加编辑复用;字典是基础六列外加每张字典自己的 extras)——
// **唯一真的相同的是外壳:一个带框的盒子、一句标题、一条错误位、
// 字段横排到底、保存/取消收在下面。** 收敛做到这里,不做到字段。
// 硬把字段也收进来,会逼这个组件去认识五种不同的状态形状 ——
// 那正是 EditableTable 抬头拒绝对 DataTable 做的事,换了个更小的场景。
import * as React from 'react'
import { cn } from '@/lib/utils'

export function AddRowPanel({
    title,
    error,
    children,
    actions,
    className,
}: {
    /** 面板标题;不给就不画(licences/dictionaries 的表单紧跟在表下面,不另起标题)。 */
    title?: React.ReactNode
    error?: React.ReactNode
    /** 字段本身 —— 逐页各写各的,这里只负责把它们横排到底。 */
    children: React.ReactNode
    /** 保存/取消一类按钮。 */
    actions: React.ReactNode
    className?: string
}) {
    return (
        <div className={cn('rounded border border-[color:var(--brand-border)] p-4', className)}>
            {title && <h3 className="mb-3 text-sm font-bold text-[color:var(--brand-text)]">{title}</h3>}
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800" role="alert">
                    {error}
                </div>
            )}
            <div className="flex flex-wrap items-end gap-3">{children}</div>
            <div className="mt-3 flex gap-2">{actions}</div>
        </div>
    )
}
