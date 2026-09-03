// app/components/overview/Figure.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-7 ②(2026-09-04)· 一条【陈述】—— Overview 的唯一构件
// ════════════════════════════════════════════════════════════════════════════
//
// ★★【它存在的理由,一句话:让"这个数凭什么出现在 Overview 上"变成一个
//     写不出来就编译不过的问题,而不是一个每页各自把握的分寸。】★★
//
// 【先说清楚 Overview 是什么 —— 完整论证在 docs/module-overview-basis.md】
//   二级菜单已经把这个模块的每一页都列出来了。所以 Overview【不许】是
//   子页面的卡片排列(Tim 的裁定:绝对不能是模块内子页面的卡片排列)。
//   它答的是另一个问题:**这个模块此刻是什么状态** —— 而那些事实的共同点是
//   【它们横跨若干张子页面,任何一张自己都说不出来】。
//   提醒装【在等的事】(/tools/reminders);Overview 装【为真的事】。
//
// ★【三格出处,全部必填 —— 照 ChartCard 的办法办:说不出来就画不出来】★
//   ChartCard 把 basis 设成必填,于是一张说不出自己出处的图写不出来。这里同一招,
//   而且多要一格:
//     · asOf   —— 截至哪一天 / 哪一段期间。一个不说时点的数是一个不能核对的数。
//     · source —— **用一句人话说这个数是什么。** 不是表名、不是函数名。
//                 CONV-0 ②c 已经为"图上印着 ar_aging_asof(as_of)"改过一次口径:
//                 那样一行,新同事会读成一条错误信息。
//     · spans  —— ★【这一格是 Overview 独有的,也是这个组件最要紧的一格】★
//                 **这个数横跨哪几张子页面。** 写不出来,就说明某一张子页面
//                 自己就答得了它 —— 那它属于那一页,不属于 Overview。
//                 没有这一格,Overview 会在三刀之内退化成一排 KPI 卡片,
//                 而那与它被禁掉的那种卡片排列只差一个名字。
//
// ★【三种状态,而第三种【不是】空】★
//   ok           —— 说得出。
//   restricted   —— 你看不见。**具名的权限码**(D5),不是空白、更不是零。
//   unanswerable —— ★【答不上来 ≠ 是零】★ 依据不在,所以这个数没有答案。
//                   先例是 gl_control_reconciliation 对早于今天的存货那一支:
//                   「照答会返回一个自信的 0.00」。同一条在 CHART-1 是
//                   「数据太少就拒绝画」,在 METAL-1 是 no_reference,
//                   在 lib/permissions.ts 是「受限的 null ≠ 本来就没有的 null」。
//                   **这是它的第五处,而它必须【说出为什么】**(why 是必填的)。
//
// 【拒绝的画法不在这里 —— 走 CONV-0 那一份】<Refusal> / <RefusalBlock>。
//   PAGE-0 数过:同一句「受限」曾有 18 种画法。本文件【不新增第 19 种】,
//   它只决定这句话出现在哪个位置,不决定它长什么样。
// ════════════════════════════════════════════════════════════════════════════
import { getTranslations } from '@/lib/i18n/server'
import { Refusal } from '@/app/components/ui/refusal'

/** 一条陈述的出处。**三格都必填**,少一格就写不出来 —— 那是刻意的。 */
export type FigureBasis = {
    /** 截至哪一天 / 哪一段期间 —— 已经格式化好的一句话 */
    asOf: string
    /** **一句人话**:这个数是什么。不是表名,不是函数名。 */
    source: string
    /**
     * ★ 它横跨哪几张子页面 —— 写不出来的数不属于 Overview。★
     * 例:「应收在 /finance/receivables,应付在 /finance/payables —— 两页各说一半。」
     */
    spans: string
}

export type FigureState =
    | { kind: 'ok' }
    /** 看不见 —— 说出要哪个权限码(D5),不画空白,更不画零。 */
    | { kind: 'restricted'; permission: string }
    /** ★ 答不上来 ≠ 是零 ★ —— why 必填。 */
    | { kind: 'unanswerable'; why: string }

export default async function Figure({
    title,
    basis,
    state,
    children,
    action,
}: {
    title: string
    basis: FigureBasis
    state: FigureState
    /** 陈述本身 —— 数、或者一句带数的话。state 为 ok 时才画。 */
    children?: React.ReactNode
    /** 「去哪儿动手」的一条链接(可选)。**它不是一张卡片** —— 见文件抬头。 */
    action?: React.ReactNode
}) {
    const t = await getTranslations()

    return (
        <section
            data-overview-figure={state.kind}
            className="rounded-[var(--brand-radius)] border p-4 mb-4"
            style={{ borderColor: 'var(--brand-border)', background: 'var(--brand-surface)' }}
        >
            <h2 className="text-base font-semibold mb-2" style={{ color: 'var(--brand-text)' }}>
                {title}
            </h2>

            {state.kind === 'ok' && <div className="mb-3">{children}</div>}

            {state.kind === 'restricted' && (
                // D5:具名的限制。措辞与顶栏的「· 受限」、与提醒页的药丸逐字同源。
                <p className="mb-3">
                    <Refusal
                        data-overview-restricted="1"
                        why={`${t('dashboard.restrictedHint')}(${state.permission})`}
                    >
                        {t('common.restricted')}
                        <span className="font-mono opacity-80">({state.permission})</span>
                    </Refusal>
                </p>
            )}

            {state.kind === 'unanswerable' && (
                // ★【这一支不是空态,它是一句陈述】★ 依据不在,所以【没有】这个数 ——
                // 而"没有答案"与"答案是零"在屏幕上必须分得开。
                <p
                    data-overview-unanswerable="1"
                    className="mb-3 rounded px-3 py-2 text-sm"
                    style={{ background: 'var(--brand-muted)', color: 'var(--brand-text)' }}
                >
                    <span className="font-medium">{t('overview.unanswerable')}</span>
                    {' — '}
                    {state.why}
                </p>
            )}

            {/* 【出处永远画,受限与答不上来也画】—— 一条说不出自己出处的空陈述,
                与一条说不出自己出处的满陈述一样不可信。ChartCard 同形。 */}
            <p className="text-xs leading-5" style={{ color: 'var(--brand-muted-text)' }}>
                {t('overview.basis.asOf')}:{basis.asOf}
                <br />
                {t('overview.basis.source')}:{basis.source}
                <br />
                {t('overview.basis.spans')}:{basis.spans}
            </p>

            {action && <div className="mt-3 text-sm">{action}</div>}
        </section>
    )
}
