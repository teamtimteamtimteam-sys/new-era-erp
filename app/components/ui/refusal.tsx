// ════════════════════════════════════════════════════════════════════════════
// BASE-1(2026-09-02)· 拒绝态 —— 【一种画法】,替掉十种
// ════════════════════════════════════════════════════════════════════════════
// ★ 这是这套前端最值钱的东西 ★
// 「受限 / 未记录 / Unexplained / 缺货」不是"没有数据",它们是【系统说得出口的一句话】:
//   * 受限     —— 这是一个权限答案,不是"这张单子干净";
//   * 未记录   —— 没有人填过,不是"填了个空";
//   * Unexplained —— 记了总数、没有分类,不是"分类是 0";
//   * 缺货     —— 一个业务状态,不是查询失败。
// 每一条都在防同一件事:**把"我不能说"印成"没有"**。
//
// ★ 漂的是颜色,不是词 ★(FE-0 量的)
// 词【没有漂】—— 全站走 messages 的同一批 key。漂掉的是它的颜色:
// `t('common.restricted')` 出现 41 处、横跨 32 个文件,而直接包着它的元素上
// 有【12 种】不同的 className 写法 ——
// text-gray-400 / -500 / -600、italic、text-xs、font-mono、甚至 text-3xl。
// 于是同一句话在不同页面上分量完全不同:有的像一句正式的拒绝,有的像一行注释,
// 有的像忘了填。**这个组件只做一件事:把那十几种收敛成一种。**
//
// ★ 为什么四种共用一种颜色,而不是各给一个色 ★
// 「填充色小片」是 Tim 在 sampler 上指的变体 C。四个字眼各配一个颜色听着更"有信息",
// 但那正是**十种画法当初长出来的方式** —— 每一页各自决定这一句该有多重。
// 区分由【词】承担(词没有漂),颜色只承担【这是一句拒绝】。
// 将来若真要分色,那要是一次集中的、看得见的决定,不是十页各挑一个灰。
//
// ★ 量出来的两个数,以及一处【对 sampler 变体 C 的修正】★
//   * 片内文字 --brand-text #182B4B on --brand-accent #E1F5FF = 12.59:1 ✓ AA
//   * ★ 但 sampler 画的那个片【没有边】,而 IA-BUILD-1 之后页面底色是淡蓝
//     #F1F9FE ——【填充色对着页底只有 1.05:1】(对着白面 1.12:1)。
//     也就是说那个"填充小片"在真实页面上**几乎看不出是一个片**。
//     这不算 WCAG 失败(1.4.11 管的是 UI 控件,而它是一段静态文字,文字本身 12.59:1),
//     但它让这个变体**做不到它被选中时要做的那件事**。
//     处置:补一条 1px 边 --brand-muted-text #62738C ——
//       对页底 4.53:1 · 对白面 4.83:1 · 对片内填充 4.30:1,三处都远在 3:1 之上。
//     颜色一个字节没改,只是给它一个看得见的边界。
// ════════════════════════════════════════════════════════════════════════════

import * as React from 'react'
import Link from 'next/link'
import { cn } from '@/lib/utils'

/**
 * 一句拒绝的【唯一】画法。
 *
 * 【它不管词】词从 messages 来,由调用方给 —— 因为词没有漂,不需要收敛;
 * 也因为服务端组件与客户端组件取翻译的路子不同,把翻译塞进来会让这个组件
 * 只能用在其中一边。
 *
 * 用法:`<Refusal>{t('common.restricted')}</Refusal>`
 *
 * @param why 可选的一句解释,进 title —— 「为什么看不到」常常比「看不到」有用得多。
 */
export function Refusal({
    children,
    why,
    className,
    ...props
}: React.ComponentProps<'span'> & { why?: string }) {
    return (
        <span
            data-slot="refusal"
            title={why}
            className={cn(
                'inline-flex items-center gap-1 whitespace-nowrap align-middle',
                'rounded-full border px-2 py-0.5 text-xs font-medium',
                'border-[color:var(--brand-muted-text)]',
                'bg-[color:var(--brand-accent)]',
                'text-[color:var(--brand-text)]',
                // 【不是按钮】没有 hover、没有 pointer —— 它不可点,也不该看起来可点。
                'cursor-default',
                className
            )}
            {...props}
        >
            {children}
        </span>
    )
}

// ════════════════════════════════════════════════════════════════════════════
// CONV-0 ①(2026-09-03)· 同一件事的【另外两个尺度】
// ════════════════════════════════════════════════════════════════════════════
// 【为什么 Refusal 一个组件不够 —— 这是采用它之前量出来的,不是设计出来的】
// PAGE-0 数的是「41 个渲染点、18 种画法」。把它们逐一对着上面那个 <span> 比,
// 有三种【它表达不出来】:
//   ① 一段【块级】的拒绝:一句话 + 一句提示(+ 有时一个权限码)。
//      ChartCard 的 restricted 分支、整页拒绝的那个琥珀框,都是这一种。
//      一个 inline 的小药丸装不下两行,硬装就要靠调用方加 className —— 而
//      「各自加 className」正是那 18 种画法当初长出来的方式。
//   ② 【大号数字位】上的拒绝(实测有一处 `text-3xl font-bold text-gray-300`):
//      一个 text-xs 的药丸放进 3xl 的位置读起来像一枚走丢的标签。
//      ★ 本刀【不动它】★ —— 那是一处页面级的决定,而这一刀不转换任何页面。
//      记在这里,给转换到那一页的那一刀。
//   ③ 拒绝【后面跟一段小字证据】(ActorName 的 unrecordedHint)。
//      **证据不进药丸** —— 见 ActorName 抬头。
//
// ★★【两个尺度,两种底色 —— 而它是【两种】,不是十种】★★
// 药丸用 --brand-accent(淡),块级用琥珀(重)。这【不是】BASE-1 抬头反对的那种漂:
// 那里反对的是【同一句话在不同页面上分量不同】。这里分的不是页面,是**两件事**:
//   · 药丸  = 一个【值】被扣下了,而这一页你看得见 —— 语气轻,它是页面的一部分;
//   · 块级  = 【这个地方】你进不来 —— 语气重,它取代了本该在这里的全部内容。
// 把后者也画成淡蓝药丸,会让"你进不去这一页"看起来像一处小小的空缺。
// 琥珀是这三份副本【本来就在用】的颜色,所以合并它们【一个像素都没有动】。
// ════════════════════════════════════════════════════════════════════════════

/**
 * 块级的一句拒绝:一句话 +(可选)一句提示 +(可选)一个权限码。
 *
 * 【为什么 statement 与 hint 是两个 prop 而不是 children】因为它们的分量不同,
 * 而"哪一句重"正是三份副本里唯一没有漂掉的东西 —— 把它交给调用方,它就会漂。
 */
export function RefusalBlock({
    statement,
    hint,
    code,
    className,
    ...props
}: Omit<React.ComponentProps<'div'>, 'children'> & {
    statement: React.ReactNode
    hint?: React.ReactNode
    /** 具名的权限码。ChartCard 那一支就是靠它把"受限"说成一个查得下去的答案。 */
    code?: string
}) {
    return (
        <div
            data-slot="refusal-block"
            className={cn(
                'rounded border border-amber-300 bg-amber-50 px-4 py-3 text-amber-900',
                className
            )}
            {...props}
        >
            <p className="font-medium">
                {statement}
                {code && <span className="ml-1 font-mono text-xs">({code})</span>}
            </p>
            {hint && <p className="mt-1 text-sm">{hint}</p>}
        </div>
    )
}

/**
 * ★ 整页拒绝 —— 【本刀合并掉的那三份逐字副本】★
 *
 * 合并前:app/components/moduleGuard.tsx · app/settings/guard.tsx ·
 * app/settings/import/page.tsx 各写了一遍同一块屏。PAGE-0 记下它们
 * **已经开始漂**:moduleGuard 那份多一条「回首页」,另外两份没有。
 *
 * 【漂的那一处往哪边收 —— 说明白,因为它是一处【可见的】选择】
 * 收到【有链接】那一边。一个刚被挡在门外的人需要一条出去的路,而两份没有它的
 * 副本并不是"决定不要",它们只是**抄的时候少抄了一行**。
 * 于是 /settings 那两页从此也有了这条链接 —— 这是本刀在这三页上唯一的可见变化。
 *
 * 【data-access-denied 必须跟着组件走,不能交给调用方】
 * 它是按角色跑可达性检查时认「拒绝页」的机器标记。REACH-1 首跑靠认文案字符串,
 * 把 /settings/accounts 误判成"打得开" —— 一次漏认就是一次误报。
 */
export function RefusalPage({
    title,
    statement,
    hint,
    backHomeLabel,
}: {
    title: React.ReactNode
    statement: React.ReactNode
    hint?: React.ReactNode
    /** 传了就画「回首页」。不传的调用方要问问自己:被挡住的人怎么离开这一页? */
    backHomeLabel?: React.ReactNode
}) {
    return (
        <div className="p-8 max-w-2xl" data-access-denied="1">
            <h1 className="text-2xl font-bold mb-4">{title}</h1>
            <RefusalBlock statement={statement} hint={hint} />
            {/* 【用 Link,不用裸 <a>】裸 <a> 是一次整页重载 —— 合并三份副本
                不该顺手把 moduleGuard 那份的导航行为改掉。 */}
            {backHomeLabel && (
                <Link href="/" className="inline-block mt-4 text-sm text-blue-600 hover:underline">
                    {backHomeLabel}
                </Link>
            )}
        </div>
    )
}
