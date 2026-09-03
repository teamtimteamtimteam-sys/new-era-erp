// app/components/charts/ChartCard.tsx — 每一张图共用的外壳。
//
// ════════════════════════════════════════════════════════════════════════════
// 【它承担三件事,而三件都是 CHART-0 第四节点名要的】
//   ① **出处**:这张图画的是哪一段时间、读的哪一个真源、有没有暂定的数。
//   ② **两种空,分开说**:一行都没有 ≠ 有行但不够画。
//   ③ **受限**:读不到底层数据的人拿到一条【具名的限制】,不是一张空图。
//
// 【为什么外壳统一,而不是每张图各写各的】
// 这三件里每一件都是"不写也能上线、写错了也不报错"的那一类。
// 六张图各写一遍,迟早有一张少写一件 —— 而少写的那一张看起来与写全的一模一样。
// 外壳强制:一张图【说不出自己的出处就画不出来】(basis 是必填的 prop)。
//
// ★★【两种空为什么必须分开 —— 这是本仓库反复付账的那条区别】★★
// 「还没开始」和「开始了但太少」是两件事。一条贴着零的线会被读成"生意没了",
// 而真相往往是"这个月才刚开始记"。同一条区别在别处已经写过:
// 受限的 null ≠ 本来就没有的 null(lib/permissions.ts),
// 失败 ≠ 空集(AGENTS.md 的 mustRows 那一条)。**这是它的第三处。**
//
// 【服务端组件,零客户端 JS】没有 'use client'。本批四张图都不需要 hover
// tooltip —— 每根条旁边【已经印着数字】,tooltip 只会把一个看得见的数
// 换成一个要悬停才看得见的数。**唯一真的需要 tooltip 的是折线**(B5),
// 而它这一刀没建。所以本刀新增的客户端边界:**0 个**。
// ════════════════════════════════════════════════════════════════════════════
import { getTranslations } from '@/lib/i18n/server'

/** 这张图的出处。**三格都是必填的**,少一格就写不出来 —— 那是刻意的。 */
export type ChartBasis = {
    /** 哪一段时间 / 截至哪一天 —— 已经格式化好的一句话 */
    period: string
    /**
     * ★★【CONV-0 ②c:这一格改了它问的问题 —— Tim 的走查,2026-09-03】★★
     *
     * 【它此前问的】"读的哪一张表/视图/函数 —— 写真源的名字"。
     * 于是三张图在操作员的屏幕上印出了 `ar_aging_asof(as_of)`、
     * `inventory_movements.movement_type`、`employees_masked · departments`。
     * CHART-1 的委托是「每张图都要说出自己的基准」,而它被读成了
     * 【报出函数名与表名】—— 那是给写代码的人看的字符串。
     * 六位新同事就要到岗,他们会把那样一行读成一条错误信息。
     *
     * 【它现在问的】**用一句人话说,这张图画的是什么。**
     * 例:「未收的款项,按拖欠时间长短分档。」
     * 不是表名,不是函数名,不是"数据库"。
     *
     * 【真源没有丢】哪一张表、哪一个函数,仍然写在各张图自己的文件抬头里 ——
     * 那是给下一个改这张图的人看的,而它本来就该在那里,不在纸面上。
     */
    source: string
    /**
     * 有没有哪个数是【暂定】的。没有就传 null。
     * Tim 的系统在别处到处分「计划 vs 实际」「暂定 vs 最终」,图不给豁免。
     */
    provisional: string | null
}

export type ChartState =
    | { kind: 'ok' }
    /** 读不到底层数据 —— 说出要哪个权限码,不画空图(D5) */
    | { kind: 'restricted'; permission: string }
    /** 一行都没有 —— **不画坐标轴、不画零线** */
    | { kind: 'no-rows' }
    /** 有行,但不够画出那个形状 —— 把 N 说出来 */
    | { kind: 'too-few'; n: number }

export default async function ChartCard({
    title, basis, state, children, footnote,
}: {
    title: string
    basis: ChartBasis
    state: ChartState
    children: React.ReactNode
    /** 图底下那一句解释(可选)—— 比如"超收封顶 100%" */
    footnote?: string
}) {
    const t = await getTranslations()

    return (
        <section className="rounded border p-4 mb-6"
                 style={{ borderColor: 'var(--brand-border)', background: 'var(--brand-surface)' }}>
            <h2 className="text-base font-semibold mb-1" style={{ color: 'var(--brand-text)' }}>{title}</h2>

            {/* 【出处永远画,连受限和空态也画】—— 一张说不出自己出处的空图,
                与一张说不出自己出处的满图一样不可信。 */}
            <p className="text-xs mb-3" style={{ color: 'var(--brand-muted-text)' }}>
                {t('charts.basis.period')}:{basis.period}
                <span className="mx-2" aria-hidden="true">·</span>
                {/* 【mono 包装去掉了】一句人话套在机器字体里,读起来仍然像机器输出 ——
                    换了词却留着那身衣服,等于只改了一半。 */}
                {t('charts.basis.source')}:{basis.source}
            </p>
            {basis.provisional && (
                <p className="text-xs mb-3 rounded px-2 py-1"
                   style={{ background: 'var(--brand-accent)', color: 'var(--brand-text)' }}>
                    {t('charts.basis.provisional')}:{basis.provisional}
                </p>
            )}

            {state.kind === 'restricted' && (
                // D5:具名的限制。措辞与顶栏的「· 受限」逐字同源。
                <p className="text-sm rounded px-3 py-2" data-chart-restricted="1"
                   style={{ background: 'var(--brand-accent)', color: 'var(--brand-text)' }}>
                    <span className="font-medium">{t('common.restricted')}</span>
                    {' — '}{t('dashboard.restrictedHint')}
                    <span className="ml-1 font-mono text-xs">({state.permission})</span>
                </p>
            )}

            {state.kind === 'no-rows' && (
                // 【一行都没有】不画坐标轴、不画零线 —— 一条贴着零的线会被读成"是零"。
                <p className="text-sm rounded px-3 py-2" data-chart-empty="no-rows"
                   style={{ background: 'var(--brand-muted)', color: 'var(--brand-muted-text)' }}>
                    {t('charts.empty.noRows')}
                </p>
            )}

            {state.kind === 'too-few' && (
                // 【有行但不够画】把 N 说出来 —— 与上面那一种必须分得开。
                <p className="text-sm rounded px-3 py-2" data-chart-empty="too-few"
                   style={{ background: 'var(--brand-muted)', color: 'var(--brand-muted-text)' }}>
                    {t('charts.empty.tooFew', { n: String(state.n) })}
                </p>
            )}

            {state.kind === 'ok' && children}

            {footnote && (
                <p className="text-xs mt-2" style={{ color: 'var(--brand-muted-text)' }}>{footnote}</p>
            )}
        </section>
    )
}
