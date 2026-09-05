// app/components/charts/OrgChart.tsx — 组织架构:宽屏一棵 SVG 树,窄屏一份缩进列表。
//
// ════════════════════════════════════════════════════════════════════════════
// 【两种渲染,同一份数据 —— 而脏数据在【两边】都要看得见】
// Tim 的裁定(CHART-1 Q5):窄屏缩进列表 + 宽屏 SVG 树,并且他点名了代价 ——
// **脏数据的处理必须在两种渲染里各存在一次**。一条汇报环在手机上也必须看得见。
// 这里的做法是把"环"提到**两种渲染之外**:它是一块独立的告示,两种宽度共用,
// 于是它不可能只在其中一种里被记得画。
//
// 【为什么缩进列表不是"降级版"】一个汇报结构**本来就是一份大纲**。
// 手机已经用缩进表达层级(文件夹、回复、目录),列表是它在窄屏上的自然形态,
// 不是把树压扁。反过来,把 SVG 树塞进 390px 只有两种下场:
// 文字跟着缩到看不清,或者要人左右拖 —— 后者正是本刀明确否掉的那种做法。
//
// 【CSS 显隐在这里【不是】AGENTS.md 那条陷阱】
// 那一条讲的是**导航元素**被 `sm:hidden` 藏起来:爬虫读 DOM、人读屏幕,
// 于是一条入口对人不存在、对检查存在。这里两块都**不是导航**,而且它们是
// 同一份数据的两种画法 —— 两块都在 DOM 里是**刻意的**:内容断言因此
// 一次请求就能同时验到两种渲染,不需要一个会改视口的浏览器。
//
// ★★【本页读的员工列,一个遮蔽列都没有】★★(CHART-1 ③)
// 读的是 employees_masked(不是基表 —— 那会撞 check-masked-reads 的棘轮),
// 取的列:id / code / legal_name / preferred_name / department_id /
//         manager_id / employment_status / job_title。
// employees 上被从 authenticated 收回的五列实测是
//   work_email · work_phone · identity_no · work_pass_no · monthly_salary
// (has_column_privilege,2026-09-03)—— **一个都不在上面那一行里。**
// job_title 来自 employees_masked 的派生列(positions.title),不是遮蔽列。
// ════════════════════════════════════════════════════════════════════════════
import { getTranslations } from '@/lib/i18n/server'
import { flattenForList, showsStatus, type OrgNode, type OrgTree } from '@/lib/orgTree'

// ── SVG 几何 ────────────────────────────────────────────────────────────────
const BOX_W = 168
const BOX_H = 46
const COL = BOX_W + 24
const ROW = BOX_H + 42

type Placed = { node: OrgNode; x: number; y: number }

/**
 * 树布局:叶子按顺序占列,内部节点取【第一个与最后一个孩子的中点】。
 * 经典的 Reingold–Tilford 的简化版 —— 够用,而且没有依赖。
 */
function layout(roots: OrgNode[]): { placed: Placed[]; cols: number; rows: number } {
    const placed: Placed[] = []
    let leaf = 0
    let maxDepth = 0
    const place = (n: OrgNode, depth: number): number => {
        if (depth > maxDepth) maxDepth = depth
        let x: number
        if (n.children.length === 0) {
            x = leaf++
        } else {
            const xs = n.children.map((c) => place(c, depth + 1))
            x = (xs[0] + xs[xs.length - 1]) / 2
        }
        placed.push({ node: n, x, y: depth })
        return x
    }
    for (const r of roots) place(r, 0)
    return { placed, cols: Math.max(leaf, 1), rows: maxDepth + 1 }
}

function nameOf(n: OrgNode): string {
    return n.emp.name
}

// ── 一个人的那一格(SVG)──────────────────────────────────────────────────
function NodeBox({ p, t }: { p: Placed; t: (k: string, v?: Record<string, string>) => string }) {
    const cx = p.x * COL
    const cy = p.y * ROW
    const departed = showsStatus(p.node.emp)
    return (
        <g transform={`translate(${cx},${cy})`}>
            <rect width={BOX_W} height={BOX_H} rx="6"
                  fill="var(--brand-surface)" stroke="var(--brand-border-strong)" />
            <text x="10" y="19" fontSize="13" fill="var(--brand-text)">
                {nameOf(p.node).slice(0, 20)}
            </text>
            <text x="10" y="35" fontSize="10" fill="var(--brand-muted-text)" fontFamily="monospace">
                {p.node.emp.code}
                {departed ? ` · ${t('org.status.' + p.node.emp.employment_status)}` : ''}
            </text>
            {/* 【上级看不见】要在【格子上】说出来,不只在列表里 —— 否则宽屏读者
                会把它读成"这个人没有上级",而那是另一句话。 */}
            {p.node.issue?.kind === 'manager_not_visible' && (
                <title>{t('org.managerNotVisible')}</title>
            )}
        </g>
    )
}

// ── 缩进列表的一行 ─────────────────────────────────────────────────────────
function ListRow({ n, t }: { n: OrgNode; t: (k: string, v?: Record<string, string>) => string }) {
    return (
        <li className="py-1" style={{ paddingLeft: `${(n.depth - 1) * 20}px` }}>
            <span className="text-sm" style={{ color: 'var(--brand-text)' }}>{nameOf(n)}</span>
            <span className="ml-2 font-mono text-xs" style={{ color: 'var(--brand-muted-text)' }}>
                {n.emp.code}
                {showsStatus(n.emp) && ` · ${t('org.status.' + n.emp.employment_status)}`}
            </span>
            {n.issue?.kind === 'manager_not_visible' && (
                <span className="ml-2 rounded px-1.5 py-0.5 text-xs"
                      style={{ background: 'var(--brand-accent)', color: 'var(--brand-text)' }}>
                    {t('org.managerNotVisible')}
                </span>
            )}
        </li>
    )
}

export default async function OrgChart({ tree }: { tree: OrgTree }) {
    const t = await getTranslations()

    // ── ① 一个人都没有 ────────────────────────────────────────────────────
    // (页面外壳已经处理 no-rows,这里是兜底,免得组件单独被用时画出空框)
    if (tree.total === 0) {
        return (
            <p className="text-sm rounded px-3 py-2" data-org-state="no-people"
               style={{ background: 'var(--brand-muted)', color: 'var(--brand-muted-text)' }}>
                {t('charts.empty.noRows')}
            </p>
        )
    }

    const hasStructure = tree.linkedCount > 0 || tree.cycles.length > 0
    const { placed, cols, rows } = layout(tree.roots)
    const flat = flattenForList(tree.roots)

    return (
        <div>
            {/* ══ ② 一条汇报线都没有 —— 线上今天【就是】这一支 ═══════════════
                ★ 绝不把 N 个人平铺成一排画成一棵树 ★(CHART-0 §三-C)
                那会让屏幕说出"这 N 个人都直接向公司汇报",而这套数据
                【没有资格说这句话】—— 它只是没有记录任何汇报关系。
                两件事在屏幕上必须分得开,所以这里根本不画树。 */}
            {!hasStructure && (
                <p className="text-sm rounded px-3 py-2 mb-3" data-org-state="no-lines"
                   style={{ background: 'var(--brand-muted)', color: 'var(--brand-muted-text)' }}>
                    {t('org.noReportingLines', { n: String(tree.total) })}
                </p>
            )}

            {/* ══ ③ 汇报环 —— 两种宽度【共用】这一块,所以不可能只在一边被记得画 ══
                一条环是一处【数据错误】,有人得去改它。静默丢掉环上的人是最省事
                的写法,也是最坏的:那个该去改的人永远不会知道。 */}
            {tree.cycles.length > 0 && (
                <div className="mb-4 rounded border px-3 py-2" data-org-cycle="1"
                     style={{ borderColor: 'var(--brand-destructive)', background: 'var(--brand-accent)' }}>
                    <p className="text-sm font-medium" style={{ color: 'var(--brand-destructive)' }}>
                        {t('org.cycleTitle', { n: String(tree.cycles.length) })}
                    </p>
                    <p className="text-xs mt-1" style={{ color: 'var(--brand-text)' }}>
                        {t('org.cycleBody')}
                    </p>
                    {tree.cycles.map((c, i) => (
                        <div key={i}>
                            <p className="mt-1 font-mono text-xs" style={{ color: 'var(--brand-text)' }}>
                                {c.members.map((m) => `${nameOf(m)} (${m.emp.code})`).join(' → ')}
                                {' → '}{nameOf(c.members[0])}
                            </p>
                            {/* 【挂在环下面的人也要出现】他们不是环的一部分,而树那一半
                                看不见他们(环成员不在 roots 上)。不画在这里,他们就
                                从整个页面上消失了 —— 而"消失"正是本块要防的事。 */}
                            {c.members.some((m) => m.children.length > 0) && (
                                <ul className="mt-1">
                                    {c.members.flatMap((m) => flattenForList(m.children))
                                        .map((n) => <ListRow key={n.emp.id} n={n} t={t} />)}
                                </ul>
                            )}
                        </div>
                    ))}
                </div>
            )}

            {hasStructure && (
                <>
                    {/* ══ 宽屏:SVG 树 ══════════════════════════════════════ */}
                    <div className="hidden overflow-x-auto md:block">
                        <svg width={cols * COL} height={rows * ROW - (ROW - BOX_H)}
                             role="img" aria-label={t('org.title')}>
                            {/* 先画线再画格子 —— 线从孩子的顶边连到父亲的底边 */}
                            {placed.map((p) =>
                                p.node.children.map((c) => {
                                    const cp = placed.find((q) => q.node === c)!
                                    const x1 = p.x * COL + BOX_W / 2
                                    const y1 = p.y * ROW + BOX_H
                                    const x2 = cp.x * COL + BOX_W / 2
                                    const y2 = cp.y * ROW
                                    const mid = (y1 + y2) / 2
                                    return (
                                        <path key={`${p.node.emp.id}-${c.emp.id}`}
                                              d={`M${x1},${y1} V${mid} H${x2} V${y2}`}
                                              fill="none" stroke="var(--brand-border-strong)" strokeWidth="1" />
                                    )
                                }),
                            )}
                            {placed.map((p) => <NodeBox key={p.node.emp.id} p={p} t={t} />)}
                        </svg>
                    </div>

                    {/* ══ 窄屏:缩进列表 —— 同一份数据,手机上的自然形态 ══════ */}
                    <ul className="md:hidden" data-org-list="1">
                        {flat.map((n) => <ListRow key={n.emp.id} n={n} t={t} />)}
                    </ul>
                </>
            )}

            {/* 一条汇报线都没有时,人还是要列出来 —— 否则页面上什么都没有,
                而"没有汇报关系"不等于"没有人"。两种宽度共用这一份。 */}
            {!hasStructure && (
                <ul data-org-list="flat">
                    {flat.map((n) => <ListRow key={n.emp.id} n={n} t={t} />)}
                </ul>
            )}

            {/* ══ ④ 一个成员都没有的部门 ══════════════════════════════════════
                它不在树上(树画的是人),但它是一个【要被看见的事实】:
                一个空部门与一个不存在的部门,在一张只画人的图上长得一模一样。 */}
            {tree.emptyDepartments.length > 0 && (
                <p className="mt-4 text-xs" data-org-empty-depts="1"
                   style={{ color: 'var(--brand-muted-text)' }}>
                    {t('org.emptyDepartments', { n: String(tree.emptyDepartments.length) })}
                    {': '}
                    {tree.emptyDepartments.map((d) => `${d.name} (${d.code})`).join(t('common.listSep'))}
                </p>
            )}

            {/* ══ ⑤ 顶层有几个人 ══════════════════════════════════════════════
                多个根【不是错误】,但它是一句要说出来的话 —— 尤其是全是根的时候。 */}
            <p className="mt-2 text-xs" style={{ color: 'var(--brand-muted-text)' }}>
                {t('org.counts', {
                    total: String(tree.total),
                    roots: String(tree.rootCount),
                    linked: String(tree.linkedCount),
                })}
            </p>
        </div>
    )
}
