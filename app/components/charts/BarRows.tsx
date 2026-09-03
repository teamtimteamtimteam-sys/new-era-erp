// app/components/charts/BarRows.tsx — 横条图。
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么横条,不是饼】CHART-0 第三节把这一条论证过两遍,照录结论:
//   · 账龄的桶是**有序的**(0-30 → 90+),饼图会把顺序丢掉;
//   · 类别多、标签长时(12 种 movement_type)饼图读不出来;
//   · 读者要比的是"90+ 那根有多长",**长度比角度好比**。
//
// ★★【颜色不承担区分,标签承担】★★(CHART-0 第五节)
// 12 个可辨的品牌色推不出来,而**横条本来就不需要** —— 一根条一个标签。
// 所以这里**全部用同一个 ocean**,一个色号都不轮换。
// **这正是"图表库让什么变容易"与 R5 相撞的那一处**:库会默认给 12 个彩虹色,
// 而正确答案是一个颜色。`emphasis` 只留给【一根】需要被指出来的条(90+ 那根)。
//
// 【为什么是 CSS 宽度,不是 SVG —— 一处与 CHART-0 措辞的偏离,写在这里】
// CHART-0 建议"内联 SVG 自绘",而它的论据是**不要装图表库**(client-only、
// 默认调色板、JS 体积)—— 那三条这里一条都不违反:本文件零依赖、零 JS、
// 服务端渲染、颜色 100% 是品牌 token。
// 选 CSS 而不是 SVG 的理由是**手机**(Tim 的 R,以及 ③ 的 390px 要求):
// 一张固定 viewBox 的 SVG 要么把文字一起缩放(桌面上字被放大到难看),
// 要么横向溢出要人左右拖 —— 后者正是本刀 Q5 明确否掉的那种做法。
// **而这两条比例条【已经是这个仓库的既有写法】**(采购收货、银行对账),
// 本文件是把那个写法收成一个组件,新图与旧图因此是同一套东西,不是两套。
// 真正需要 2D 的那张图(组织树)仍然用 SVG —— 见 OrgChart.tsx。
// ════════════════════════════════════════════════════════════════════════════

export type BarRow = {
    /** 这根条的标签 —— 颜色不区分,全靠它 */
    label: string
    /** 数值,用来算长度。**负数按 0 画**(见下) */
    value: number
    /** 印在条子右边的那个数(已格式化;可能带货币符号) */
    display: string
    /** 要不要把这一根指出来(比如账龄的 90+)。**整张图最多用一次** */
    emphasis?: boolean
}

export default function BarRows({ rows, max }: {
    rows: BarRow[]
    /**
     * 分母。**显式传进来,不在这里算** —— 账龄的分母是"四桶之和",
     * 而流水构成的分母是"最大的那一类",两者不同,由调用方决定才说得清。
     */
    max: number
}) {
    // 【分母为 0 时不画 0/0】所有条都是 0 长,而不是 NaN%。
    // 这一支今天走得到:一个未结额恰好为零的账龄表就是它。
    const denom = max > 0 ? max : 1

    return (
        // data-chart-bars:给冒烟的内容判据用的【机器标记】。
        // 靠认中文/英文文案去分辨"图画出来了没有"会随文案改动而失效,
        // 而这个标记跟着组件走(与 moduleGuard 的 data-access-denied 同一条理由)。
        <div className="flex flex-col gap-2" data-chart-bars={rows.length}>
            {rows.map((r) => {
                // 【负数按 0 画,而不是画一根反向的条】负的账龄桶不该存在;
                // 真出现了,数字那一栏仍然照实印负数 —— 图形保守,数字诚实。
                const pct = Math.max(0, Math.min(100, (r.value / denom) * 100))
                return (
                    <div key={r.label} className="flex items-center gap-3 text-sm">
                        <span className="w-40 shrink-0 truncate sm:w-56" title={r.label}
                              style={{ color: 'var(--brand-text)' }}>
                            {r.label}
                        </span>
                        <span className="h-3 flex-1 rounded overflow-hidden"
                              style={{ background: 'var(--brand-muted)' }}>
                            <span className="block h-full rounded"
                                  style={{
                                      width: `${pct}%`,
                                      background: r.emphasis
                                          ? 'var(--brand-destructive-fill)'
                                          : 'var(--brand-ocean-fill)',
                                  }} />
                        </span>
                        {/* ★★【CONV-0 ②d:emphasis 现在也管【那个数字】,不只是条】★★
                            走查报的是「汇总条里 90+ 是红的,图里不是」。实测下来更准确
                            的说法是:**条【本来就是】强调色**(下面那一支),不红的是
                            这一栏的【数字】—— 于是同一个数在同一页上带着两种警戒等级,
                            相距不过六英寸。那才是缺陷。
                            【用的是条子自己那个颜色,不是另挑一个红】数字与它的条从此
                            逐字节同色 —— 一个数,一种画法。
                            【量过】--brand-destructive-fill #B75B53 对卡面 #FFFFFF
                            = 4.53:1 ✓ AA(text-xs 属正文,门槛 4.5)。
                            而 --brand-destructive #C0635A 只有 4.06:1 —— 它是
                            token 表里写着"文字用"的那一个,**但那是对着别的底**;
                            这里不能用它。 */}
                        <span className="w-28 shrink-0 text-right font-mono text-xs"
                              style={{
                                  color: r.emphasis
                                      ? 'var(--brand-destructive-fill)'
                                      : 'var(--brand-text)',
                                  fontWeight: r.emphasis ? 600 : undefined,
                              }}>
                            {r.display}
                        </span>
                    </div>
                )
            })}
        </div>
    )
}
