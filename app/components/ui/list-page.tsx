// app/components/ui/list-page.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-1(2026-09-03)· 列表页的外壳 —— 【它逼这一页把四件事都答完】
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么外壳和表格是同一刀 —— Tim 的 Q1=C】
// 分开做意味着每一页要被动两次,而 PAGE-0 数出来:贵的是"页数 × 触碰次数",
// 不是"一次触碰改多少行"。所以表和壳一起换,一页只动一次。
//
// ★★【它照 ChartCard 的办法办:说不出来就画不出来】★★
// ChartCard 把 `basis` 设成必填,于是一张说不出自己出处的图【写不出来】。
// 这里同一招:`state` 是一个必填的联合类型,页面必须在三件事之间做出选择 ——
//   ok         —— 有内容,画它;
//   restricted —— 你进不来。**走 CONV-0 的 <RefusalPage>,不另开一条路**;
//   empty      —— 没有内容,而【为什么没有】要说出口。
// 一个可选的 `empty?` 会被跳过,而 PAGE-0 数出来今天正好有 **38 张账簿一句空态都没有**
// (35 个文件)。**必填是这条判据存在的全部意义。**
//
// ★【两种空,只在【真的分得开】的时候才分】★(CHART-1 的裁定,Tim 在 CONV-1 复述)
//   noRows —— 一行都还没有。
//   tooFew —— 有行,但不够说明问题(例如一条趋势线要 8 个点)。
//   **不要制造这个区别。** 一张四行的评级档位表没有"太少所以没意义"这回事 ——
//   四行就是全部,它是一个真实的、完整的四行。硬给它安一个 tooFew 是噪音,
//   而噪音会教下一个人把这个区别当成模板的仪式而不是一个判断。
//   所以 tooFew 是【可选的一支】,noRows 是必答的那一支。
//
// 【加载态不在这里】Next 的 loading.tsx 是【路由层】的东西,不是组件层的 ——
// 它由 app/**/loading.tsx 提供,而 Tim 的 Q5=B 裁定只给串行深度 ≥5 的 28 页建。
// 本外壳导出 <ListPageSkeleton> 供那些 loading.tsx 使用,于是【骨架与真页面的
// 版式来自同一个文件】—— 两份版式必然漂开,这个仓库为那个形状付过四次账。
import * as React from 'react'
import { RefusalPage, RefusalBlock } from '@/app/components/ui/refusal'

export type ListPageState =
    /** 有内容 —— 画 children。 */
    | { kind: 'ok' }
    /**
     * 进不去。**走 CONV-0 那一份整页拒绝,不另开一条路。**
     * 【为什么外壳也管这一件】165 页已经在页面第一行调 requireModule 并直接 return
     * 那块屏,它们不需要外壳;而 PAGE-0 数出 31 页要新写拒绝判据 —— 对那些页面,
     * 外壳是它们唯一会记得的地方。两条路渲染出来的是【同一个组件】。
     */
    | { kind: 'restricted'; title: React.ReactNode; statement: React.ReactNode; hint?: React.ReactNode; backHomeLabel?: React.ReactNode }
    /** 没有内容,而【为什么没有】说得出口。 */
    | { kind: 'empty'; noRows: React.ReactNode }
    /** 有行但不够用 —— **只在这个区别真的存在时才用它**,见抬头。 */
    | { kind: 'too-few'; n: number; message: React.ReactNode }

export function ListPage({
    title,
    intro,
    actions,
    notices,
    state,
    children,
    maxWidth,
}: {
    title: React.ReactNode
    /** 标题下那一句说明。这一页在解释自己是什么,不给就不画。 */
    intro?: React.ReactNode
    /** 标题右边的动作(新建、导出…)。 */
    actions?: React.ReactNode
    /**
     * ★★【无条件渲染的那些话 —— 空态也要画】★★
     *
     * 【这个槽是被一次真实的回归逼出来的,不是设计出来的】
     * 转 /commissions 时,children 里那两块提示(「它不过账」「计提那一半没建」)
     * 掉了 —— 因为 children 只在 state.kind === 'ok' 时画。而那一页的抬头
     * 白纸黑字写着它们【必须无条件渲染】:
     *     「一条只在有数据时才出现的警告,等于没有警告。」
     * 也就是说外壳的 ok/empty 分支【本身】会把这一类话吃掉,而且是静默地吃掉。
     *
     * 所以 notices 画在状态分支【之前】,空态、受限之外的任何状态都照画。
     * **一页有没有这种话,是它自己知道的事;外壳要做的是不要把它吞掉。**
     */
    notices?: React.ReactNode
    state: ListPageState
    children?: React.ReactNode
    /**
     * 容器宽度。**沿用该页今天的 max-w-*;今天没有的就不要加**
     * —— PAGE-0 §⑨ 写下的那一条,加一个宽度限制是改变现有页面的样子。
     */
    maxWidth?: string
}) {
    if (state.kind === 'restricted') {
        return (
            <RefusalPage
                title={state.title}
                statement={state.statement}
                hint={state.hint}
                backHomeLabel={state.backHomeLabel}
            />
        )
    }

    return (
        <div className={['p-8', maxWidth].filter(Boolean).join(' ')}>
            <div className="mb-4 flex flex-wrap items-baseline justify-between gap-2">
                <h1 className="text-2xl font-bold">{title}</h1>
                {actions}
            </div>
            {intro && <p className="mb-4 text-sm text-gray-600">{intro}</p>}

            {/* ★ 无条件 —— 空态也画。见 notices 的说明。 */}
            {notices}

            {/* ★【空态是一个【具名的答复】,不是一张空表】★
                画的是 CONV-0 的 <RefusalBlock> —— 与「你进不来」同一个块级形状,
                因为读者要读的是同一类东西:**这里为什么没有东西**。
                (颜色也因此是同一种;两种空之间的区别由【词】承担,不由颜色。) */}
            {state.kind === 'empty' && <RefusalBlock statement={state.noRows} />}
            {state.kind === 'too-few' && (
                <RefusalBlock
                    statement={state.message}
                    hint={`目前 ${state.n} 行。`}
                />
            )}
            {state.kind === 'ok' && children}
        </div>
    )
}

/**
 * 路由级 loading.tsx 用的骨架。
 *
 * 【为什么它住在这个文件里】因为它必须和上面那个外壳【长得一样】——
 * 一个和真页面对不上的骨架,会在真页面出现的那一刻整页跳一下,
 * 而那比没有骨架更难受。两份版式放在同一个文件里,改一处就一起改。
 *
 * 【为什么只有几页会用它】Tim 的 Q5=B:只给串行往返深度 ≥5 的 28 页建 loading.tsx。
 * 其余页面上它一闪而过,而一个一闪而过的骨架只是闪烁。
 */
export function ListPageSkeleton({ rows = 6, maxWidth }: { rows?: number; maxWidth?: string }) {
    return (
        <div className={['p-8', maxWidth].filter(Boolean).join(' ')} aria-busy="true" aria-live="polite">
            <div className="mb-4 h-8 w-56 rounded base-skeleton" />
            <div className="mb-6 h-4 w-96 rounded base-skeleton" />
            <div className="space-y-2">
                {Array.from({ length: rows }, (_, i) => (
                    <div key={i} className="h-9 w-full rounded base-skeleton" />
                ))}
            </div>
        </div>
    )
}
