'use client'

// ════════════════════════════════════════════════════════════════════════════
// BASE-1(2026-09-02)· 表格 —— 【手机上仍然是一张账簿】
// ════════════════════════════════════════════════════════════════════════════
// 全站 201 张表、161 个文件、1,215 个 <td>、990 个 <th>,而库【一个都没有】:
// 0 处排序、0 处列显隐、0 处分页(FE-0 量的)。
//
// ★ 量出来的形状:它们【是同一种东西】★(BASE-1 量的,201 张逐张解析)
//   * 198 / 201 是【会重复的账簿】(块里有 .map);只有 3 张是静态的明细表。
//   * 列数 2–13,众数 5:2–4 列 58 张 · 5–6 列 88 张 · **≥7 列 52 张**。
//   * 最宽的几张:/inbound 13 列 · /finance/assets 12 列 · /materials 与 /output 各 11 列。
//   也就是说【一种答案可以覆盖全部】—— 它们不是"账簿/明细/摘要"三类,
//   它们是同一类,只在【宽度】上不同。真正的难题只有一个:52 张宽表怎么上手机。
//
// ★ R3 · 手机上的画法:【留下的列 + 一行展开】,不是卡片流 ★
//   【为什么不是卡片流】一张账簿存在的意义是【顺着一列往下比】——
//   60 行变成 60 张卡片之后,那一列就再也扫不了了。卡片流是最常见的响应式答案,
//   而它恰好毁掉这张表唯一不可替代的能力。
//   【为什么不是只给横向滚动】那是把桌面版缩小,R3 明确不要。
//   所以:手机上留下【声明过的那几列】(身份 + 那个要紧的数),其余的收进
//   点一下展开的一段带标签的列表。**它在 390px 上仍然是一张表,仍然能顺列扫。**
//
// ★ 列的优先级【每张表自己声明】,组件不猜 ★
//   「猜前 N 列」在有些表上一定会挑错 —— /inbound 的前两列是批次号和日期,
//   而人在手机上要找的是物料和净重。所以:
//   **一张表没有声明任何 priority 列时,本组件【当场按名拒绝】**
//   (`DATATABLE_NO_PHONE_COLUMNS`),而不是默默退回"前 N 列"或"横向滚动"。
//   本仓库对这个形状有一长串先例:不声明重量基准就拒、缺一个交易日就拒、
//   没录上限就拒绝作判断。**一次响亮的拒绝,好过一个悄悄挑错列的默认值。**
//   它拒得起,是因为本刀【没有转换任何页面】:今天没有一个页面会碰到这条路,
//   而每一次转换都会在第一次渲染时就撞上它。
//
// ★ R4 · 排序/筛选/分页/列显隐是【能力】,不是样式 —— 而且默认【全关】★
//   四个开关一律默认 false。把组件换上去【不会改变任何一页现在显示的东西】,
//   要多出一个控件必须是显式打开的。R4 要的就是这个。
//
// ★★ 它【永远不声称排了它没拿到的东西】★★(Tim 的裁定,A1)
//   失败模式是静默的:一页只取了一屏数据,却给出一个排序控件 ——
//   人按下去,以为自己看到了【全体里最大的那个】,其实只是这一屏里最大的。
//   处置放在【类型上】,不是放在注释里,而且比"提示一句"更硬:
//   **客户端排序只接受 coverage: 'complete'。拿到的是一部分,就打不开它 —— 编译期就打不开。**
//   一句提示要人去读;一个类型错误不需要任何人记得。
//
// ★★ 而 FE-0 那句「ZERO 排序、ZERO 分页」是【错的】—— 量出来的 ★★
//   BASE-1 逐页量过:
//     * 排序:**8 页已经有了**(/inbound /materials /output /sales/customers /suppliers
//       /operation/processing /tools/pricing/metal-prices /finance/fx),走的是 URL 参数 + 数据库 ORDER BY;
//     * 分页:**17 页已经有了**,走 .range();
//     * 列显隐:**0 页** —— 这一条 FE-0 说对了。
//   这件事直接改了本组件的形状:那 8 页的排序是【在数据库里对全体排的】,
//   而客户端排序只能对【取回来的那一页】排。把它们换成客户端排序**是一次降级**,
//   而且正好是上面那个静默失败。
//   所以本组件有两种排序模式,且【第二种是给那 17 页留的路】:
//     * mode: 'client' —— 自己排。**类型上只允许 coverage: 'complete'。**
//     * mode: 'server' —— 表头渲染成链接,由页面自己的 URL 参数去数据库排。
//       这时候排序看得见全体,所以【不需要】任何警告;只报"显示第几到第几行"。
//   换句话说:**转换刀不必为了用上这个组件而放弃已经正确的服务端排序。**
// ════════════════════════════════════════════════════════════════════════════

import { useTranslations } from '@/lib/i18n/client'
import * as React from 'react'
import { cn } from '@/lib/utils'
import { compareForSort } from '@/lib/sortCollation'
import { tableC } from '@/app/components/ui/table-style'

export type Column<T> = {
    /** 稳定的列键 —— 排序状态与列显隐都按它记。 */
    key: string
    header: React.ReactNode
    /**
     * ★ 手机上留在表里的列。每张表自己声明,组件不猜。至少要有一列。
     *
     * ★★ TABLE-STYLE-1 / R1(Tim 裁定,2026-09-09):
     *   **一列如果画的是【要按的控件】(删除 / 撤回 / 移除 / 下载),它必须 `priority: true`。**
     *   理由:够不着的动作等于不存在(DBLOCK-1 用在版式上)。折进展开区意味着
     *   **要先点开一行才够得着那颗钮** —— 而"折"那几处当时写下的理由,
     *   讲的全是【读哪几列】,没有一条是关于那个控件的。
     *   ☞ 全文与那次两条判断打架的经过,见 docs/base-components.md §二十.1。
     *   ⚠ 这一条【没有仪器】:一列算不算"动作列"没有机械特征,靠人读。
     */
    priority?: boolean
    align?: 'left' | 'right'
    /**
     * 【客户端排序】的比较值。给了才可排;不给这一列就是不可排的
     * —— 而不是排出一个假的顺序。
     */
    sortValue?: (row: T) => string | number | null | undefined
    /**
     * 【服务端排序】用:这一列可以拿去排。
     *
     * 【为什么不复用 sortValue】服务端模式下排序是数据库做的,
     * 组件要的只是"这一列排不排"这个事实和它的 key ——
     * 逼调用方写一个【永远不会被调用】的比较器,是逼他写死代码。
     * 给了 sortValue 的列自动算可排,所以两种模式可以共用一份列定义。
     */
    sortable?: boolean
    render: (row: T) => React.ReactNode
    /** 手机展开区里的标签。不给就用 header —— 但 header 常常是缩写。 */
    phoneLabel?: React.ReactNode
    className?: string
}

/**
 * ★★【CONV-1:这张表在 390px 上【怎么办】—— 必填,而且没有默认值】★★
 *
 * 【为什么是必填的 prop,而不是一个可选项】Tim 的 Q3=C 裁定要求:一张什么都不声明的
 * 表要被【按名拒绝】,而一张选择横向滚动的表可以,只要那是一个【说出来的】决定。
 * 「说出来」如果只是注释,下一个人会漏读;如果只是一道闸,它得等到有人跑闸。
 * **写成必填的 prop,漏掉它就编译不过** —— 那是这三层里唯一一层不需要任何人记得的。
 *
 * 【为什么 scroll 那一支强制带 why】没有它,`mode: 'scroll'` 就是一个比
 * 「什么都不写」更方便的默认值 —— 而那正好把这条裁定倒过来。
 * 带上 why,选择横向滚动就必须当场写下这张表为什么值得让人横着拖,
 * 而这句话会跟着代码走,不会留在某次提交信息里。
 *
 * 【两支各自是什么】
 *   columns —— BASE-1 的做法:手机上只留声明过 priority 的那几列,其余进展开区。
 *              **一列 priority 都没有的表在这里还会撞上第二道网(见下面的按名拒绝)。**
 *   scroll  —— 全部列都留在手机上,靠外层那层 overflow-x 横着拖。
 *              R3 说过这是「把桌面版缩小」,所以它要理由;但对一张 13 列的进料台账,
 *              它可能确实是那个诚实的答案。
 */
export type PhoneTreatment =
    | { mode: 'columns' }
    | { mode: 'scroll'; why: string }

/** 【你拿到的是全部,还是一部分】—— 打开排序就必须回答。 */
export type Coverage = 'complete' | { shown: number; total: number }

// ════════════════════════════════════════════════════════════════════════════
// CONV-3(2026-09-03)· 勾选 → 批量动作 —— 【一个 prop,不是第二个组件】
// ════════════════════════════════════════════════════════════════════════════
// 【为什么不是 CONV-2 那种 FORK DECISION】EditableTable 分岔是因为行内编辑要
// 建三件这个组件完全没有的东西(行级编辑态、脏值追踪、逐行保存)——那是一个新的
// 渲染契约。**勾选不改变契约**:`render: (row) => ReactNode` 一个字都不用动,
// 勾选只是【多一列它自己管的 UI】,而且默认 undefined、零处调用点受影响。
// 与 EditableTable 相反的理由,同一条判据:「这个改动会不会污染只读那条路」。
//
// 【选中集是页面的,不是组件的】—— CONV-2 §① C 已经写清楚:动作按钮在页级。
// 组件只画勾选框、报"这一行选没选",Record/Set 与批量按钮都留在页面那一侧,
// 与今天 PayPanel.tsx / CostSettlePanel.tsx 已经在做的事完全同形。
//
// 【实测更正了委托的一个假设】CONV-2 的原话是「/finance/processing-costs 那一页
// 有两个独立的选中集,所以那个 prop 不能假设『一张表一个选中集』」——
// 听起来像是在要一个【多组】的 prop。**实测(CONV-3)那两个选中集是两张【独立的
// 表】**(CostSettlePanel.tsx:90 与 :107,各自的 <table>,各自的批量按钮),
// 不是一张表要两组勾选。于是"一张表一个选中集"这句话【本来就成立】——
// 两张 DataTable 各给一个 selection prop,天然就是两个独立集合,不需要命名分组。
// **没有証据支持的复杂度不建**,与 PAGE-0/CONV-1/CONV-2 三次「按一个便宜代理
// 指标多算」是同一条教训,换到了设计这一侧。
//
// 【手机上勾选框不藏】—— 与 priority 列不同,它不是"读到这一行才要问的东西",
// 它是这一页存在的理由(选完才有批量动作可言),所以它是独立于 priority 逻辑的
// 一个【永远可见】列,与展开钮那一列同形。
export type Selection = {
    selectedIds: ReadonlySet<string>
    onToggle: (id: string) => void
    /** 表头那枚全选/取消全选。不给就没有全选,只能逐行点。 */
    onToggleAll?: (ids: readonly string[]) => void
    /** 勾选框的无障碍名字前缀;不给用「选中这一行」。 */
    selectRowLabel?: string
    selectAllLabel?: string
}

// ════════════════════════════════════════════════════════════════════════════
// TABLE-FOOTER-1(2026-09-10)· 表尾合计行 —— 【按列给数,colSpan 由组件自己算】
// ════════════════════════════════════════════════════════════════════════════
// 【为什么不是「给我一段 JSX」】那正是 EditableTable 的 `footer` 干的事,而它
// **不是 tfoot**:它在 `</table>` 之后渲染(editable-table.tsx:524),是页面的
// 提交区。要它长在表里,组件就必须知道【每一格贴在哪一列下面】——
// 一段现成的 JSX 说不出这件事,于是 colSpan 只能由调用方写死。
//
// ★★【colSpan 是这件事的全部难处,而它不能随断点变】★★
//   全仓 6 张手搓表为这一条把标签格【写了两份】(trial-balance:234/242 ·
//   payables:309/321 · receivables:300/315 · quotes:190/194),两份的字一模一样,
//   分开的只是它跨几格。**空态那一格躲得过去,是因为它只有一格** ——
//   HTML 会把跨过头的 colSpan 截断,一格跨多了在屏幕上看不出来
//   (data-table.tsx 的空态今天就跨多了,两个断点都多,而它一直是对的)。
//   **表尾躲不过去:它有两格以上,标签跨几格【决定了合计落在哪一列】。**
//   跨多一格,每一个合计就整体右移一列 —— 而它仍然是一张排得整整齐齐的表。
//
//   ☞ 于是本能力要调用方交出的是【列 key → 这一格的内容】,不是 JSX:
//     组件已经知道每个断点上哪几列看得见(`isPhoneCol`,空态与展开区都在用),
//     两个 colSpan 由它自己数出来,**调用方一个数字都不用写。**
//
// ★【手机上被折走的那些列,它们的合计去哪】—— 有先例,不是我挑的
//   trial-balance:234 手写的答案是:**叠进手机档的标签格里,带上列名。**
//   理由是那张表的用处就是"借贷相不相等",而借贷两列在 390px 上不画 ——
//   合计跟着列一起消失,这张表在手机上就不再是试算表。payables:309 同形。
//   ☞ 本能力照抄这个答案:折走的列若有合计,自动叠进手机档标签格。
//     **不是"省略",也不是"塞进展开区"** —— 展开区是每一行自己的,表尾没有行。
//
// ⚠【label 会被渲染两遍】—— 与组件已登记的双渲染同一个形状。
//   手机档一份、桌面档一份(两份靠 sm:hidden / hidden sm:table-cell 分开),
//   所以 **label 里放受控输入会得到两份互相独立的 state**。
//   表尾放输入本来就不是这个能力的用途,但这条陷阱要写下来,不留给下一个人踩。
//
// ⚠【合计的数由调用方算,组件一个字都不加总】——
//   于是它给出的 `rendered` 是【这一屏真的画出来的那些行】(筛过、排过、分过页的)。
//   一张开了 filter / pageSize 的表,拿全体的合计配一屏的行,就是本仓库
//   A1 裁定骂的那种静默的谎。**把那几行交到调用方手里,是让"对得上"成为默认。**
//   ☞ 但组件【不强制】它:balance-sheet 的总资产是服务端算的,不是这几行的和,
//     那也是对的。所以这里给的是一个参数,不是一道闸。
// ════════════════════════════════════════════════════════════════════════════
export type FooterRow = {
    /** 稳定的行键。 */
    key: string
    /** 前导标签。它横跨到【第一个有合计的列】为止,跨几格由组件数。 */
    label: React.ReactNode
    /**
     * 各列的合计:**列的 key → 这一格的内容**。
     * 没列进来的列渲染成空格子(与 trial-balance 末尾那个空的净额格同形)。
     * ★ key 写错会【当场按名拒绝】—— 一个静默消失的合计正是要防的东西。
     */
    cells: Readonly<Record<string, React.ReactNode>>
    /**
     * 整行的类。★ variant C 【没有】表尾底色/字重的标准 ——
     * table-style.ts 抬头与 variant-c-spec.md §6 都明写「取样页里没有这些元素,
     * 于是它没有标准,而不是一个应当由我挑一个值去填的洞」。
     * 所以底色与字重从这里来,由调用方写下它自己那一份(手搓表今天就是这么写的:
     * `bg-gray-100 font-bold`)。**组件不替谁裁这一条。**
     */
    className?: string
}

/** 不排。 */
type SortingOff = { sorting?: undefined }
/** 自己排 —— ★ 类型上只接受"我拿到了全部"。这就是 A1 那条裁定。 */
type SortingClient = { sorting: { mode: 'client'; coverage: 'complete' } }
/** 交给页面已有的 URL 参数去数据库排 —— 排的是全体,所以 coverage 可以是一部分。 */
type SortingServer = {
    sorting: {
        mode: 'server'
        coverage: Coverage
        active: { key: string; dir: 'asc' | 'desc' } | null
        href: (key: string, dir: 'asc' | 'desc') => string
    }
}

export type DataTableProps<T> = {
    rows: readonly T[]
    columns: ReadonlyArray<Column<T>>
    rowKey: (row: T) => string
    /** ★ 390px 上怎么办。**必填** —— 见 PhoneTreatment 抬头。 */
    phone: PhoneTreatment
    caption?: React.ReactNode
    /** 空集不是失败,但它要【说出自己是空的】。 */
    empty?: React.ReactNode
    /** 一个文字筛选框;不给就没有筛选。 */
    filter?: { label: string; match: (row: T, q: string) => boolean }
    /** 每页行数;不给就不分页(今天 201 张表全部不分页,默认保持原样)。 */
    pageSize?: number
    /** 列显隐。 */
    columnToggle?: boolean
    /** 手机上展开/收起的无障碍名字。 */
    phoneExpandLabel?: string
    /** ★ 勾选 → 批量动作。不给就没有勾选框,与今天所有表一样。见上面的抬头。 */
    selection?: Selection
    /**
     * ★★【CONV-4:整行样式 —— §⑧-8 记过的缺口,第三次出现之后建的】★★
     * CONV-3 §⑧-8 量到 2 处(RecurringLines 停用行发灰、ForecastGrid 未定日款项
     * 整行琥珀),裁定"2 处不建"。CONV-4 转 finance 时一次量到 5 处(freight
     * 冲销行、close 已重开行、invoices 已作废行、assets 已处置行、cashflow
     * 小计行加粗)—— 同一个形状,不是新形状,清过了"第三次才建"那道坎。
     * 不给就不加 className,与今天所有表一样。
     */
    rowClassName?: (row: T) => string | undefined
    /**
     * ★★【TABLE-FOOTER-1:表尾合计行 —— 见 FooterRow 抬头】★★
     * 不给就没有 `<tfoot>`,与今天 160 个调用点一模一样。
     * @param rendered 这一屏【真的画出来的】那些行(筛过、排过、分过页的)。
     *        合计由调用方自己算 —— 组件不加总,理由见 FooterRow 抬头最后一段。
     */
    footer?: (rendered: readonly T[]) => ReadonlyArray<FooterRow>
    className?: string
} & (SortingOff | SortingClient | SortingServer)

const DIR_NEXT = { none: 'asc', asc: 'desc', desc: 'none' } as const
type Dir = keyof typeof DIR_NEXT

/**
 * 表头那枚全选框。【原生 checkbox 没有 indeterminate 这个 prop】——
 * 只能通过 DOM 引用直接设它,所以这里绕不开 useEffect/ref。
 */
function SelectAllCheckbox({
    total, selected, onChange, label,
}: { total: number; selected: number; onChange: () => void; label: string }) {
    const ref = React.useRef<HTMLInputElement>(null)
    React.useEffect(() => {
        if (ref.current) ref.current.indeterminate = selected > 0 && selected < total
    }, [selected, total])
    return (
        <input
            ref={ref}
            type="checkbox"
            checked={total > 0 && selected === total}
            onChange={onChange}
            aria-label={label}
            className="base-pressable h-4 w-4"
        />
    )
}

export function DataTable<T>(props: DataTableProps<T>) {
    // COPY-1:这一层外壳的字从前只有中文,而 97 个页面 import 它。
    const t = useTranslations()
    const {
        rows, columns, rowKey, caption, empty, filter, pageSize, phone, selection,
        columnToggle = false, phoneExpandLabel, className, rowClassName, footer,
    } = props
    // ★【CONV-1:scroll 那一支 —— 手机上【每一列都留着】,靠外层横向滚动】★
    //   实现上它就是"把所有列都当成 priority",于是下面那些 `!c.priority` 的
    //   隐藏规则一条都不生效,展开钮那一格也不画(没有东西可展开)。
    //   **注意它不是"关掉手机适配",是【另一种】手机适配** —— 而它必须带 why。
    const phoneScroll = phone.mode === 'scroll'
    const isPhoneCol = (c: Column<T>) => phoneScroll || !!c.priority
    const sorting = props.sorting
    const clientSort = sorting?.mode === 'client'
    const serverSort = sorting?.mode === 'server' ? sorting : null

    // ★ 按名拒绝 —— 见抬头。没有声明手机列,就不要把这张表放到手机上。
    //
    // ★★【CONV-1:这是【第三道网】,不再是唯一的一道】★★
    //   它是一个【渲染期】的 throw —— 也就是说它只在有人真的打开这一页时才响。
    //   对一张少有人访问的列表页,那可能是几个月之后。所以 CONV-1 在它前面加了两道:
    //     ① 类型:phone 是必填的 prop —— 漏掉它【编译不过】(上面那个联合类型);
    //     ② 闸:scripts/check-datatable-phone.mjs 逐个调用点检查
    //        「columns 模式的表至少有一列 priority」,点名 file:line,进 npm run build。
    //   三道网各自看得见对方看不见的东西:类型管"有没有声明",闸管"声明得对不对",
    //   而这个 throw 管【运行期才拼出来的列】(闸是静态解析,它读不出动态生成的列)。
    //   **留着它,理由就是最后这一句。**
    //
    //   scroll 模式【不走这条路】:它已经回答过手机这个问题了,答案是"全部列都留着"。
    const priorityCols = columns.filter((c) => c.priority)
    if (!phoneScroll && priorityCols.length === 0) {
        throw new Error(
            'DATATABLE_NO_PHONE_COLUMNS:这张表没有任何一列声明 priority。' +
            '手机上要留下哪几列是【这张表自己的判断】,组件不替它猜 —— ' +
            '猜「前 N 列」在有些表上一定挑错。给身份列与那个要紧的数字列加 priority: true,' +
            '或者显式声明 phone={{ mode: \'scroll\', why: \'…\' }} 并写下理由。'
        )
    }

    // ★ 又一条按名拒绝:客户端模式下声称可排、却没给比较器,是一个【按下去没反应】的表头。
    //   静默忽略它,人会以为自己排过了 —— 与"排了它没拿到的东西"是同一种谎。
    if (props.sorting?.mode === 'client') {
        const liar = columns.find((c) => c.sortable === true && !c.sortValue)
        if (liar) {
            throw new Error(
                `DATATABLE_SORTABLE_WITHOUT_COMPARATOR:列「${liar.key}」声明了 sortable,` +
                '却没有给 sortValue。客户端排序是本组件自己做的,没有比较器它就排不了 —— ' +
                '而一个按下去没反应的表头,比一个不可点的表头更坏。'
            )
        }
    }

    const [sort, setSort] = React.useState<{ key: string; dir: Dir }>({ key: '', dir: 'none' })
    const [q, setQ] = React.useState('')
    const [page, setPage] = React.useState(0)
    const [hidden, setHidden] = React.useState<ReadonlySet<string>>(() => new Set())
    const [open, setOpen] = React.useState<ReadonlySet<string>>(() => new Set())

    const shownCols = columns.filter((c) => !hidden.has(c.key))

    // ── 筛选 → 排序 → 分页,顺序是固定的 ────────────────────────────────────
    const filtered = React.useMemo(() => {
        if (!filter || !q.trim()) return rows
        return rows.filter((r) => filter.match(r, q.trim()))
    }, [rows, filter, q])

    const sorted = React.useMemo(() => {
        // 服务端模式下【本组件一行都不重排】—— 顺序是数据库给的,重排会把它毁掉。
        if (!clientSort || sort.dir === 'none') return filtered
        const col = columns.find((c) => c.key === sort.key)
        if (!col?.sortValue) return filtered
        const get = col.sortValue
        const sign = sort.dir === 'asc' ? 1 : -1
        return [...filtered].sort((a, b) => {
            const va = get(a), vb = get(b)
            // 【空值永远排在最后,与方向无关】—— 一个空格子不是"最小的数",
            // 让它随方向在两头跳,会让人以为那里有一个真的极值。
            if (va == null && vb == null) return 0
            if (va == null) return 1
            if (vb == null) return -1
            if (typeof va === 'number' && typeof vb === 'number') return (va - vb) * sign
            // 字序走 lib/sortCollation.ts 那条具名规矩(排序永远用英文字序,与界面语言无关)。
            // `{ numeric: true }` 是这一处【原有】的行为,原样保留 —— 这一刀只改字序。
            return compareForSort(String(va), String(vb), { numeric: true }) * sign
        })
    }, [filtered, clientSort, sort, columns])

    const pageCount = pageSize ? Math.max(1, Math.ceil(sorted.length / pageSize)) : 1
    const safePage = Math.min(page, pageCount - 1)
    const visible = pageSize ? sorted.slice(safePage * pageSize, safePage * pageSize + pageSize) : sorted

    // ════════════════════════════════════════════════════════════════════════
    // ★★【TABLE-FOOTER-1:表尾 —— 两个断点各算各的 colSpan】★★(见 FooterRow 抬头)
    // ════════════════════════════════════════════════════════════════════════
    // 交给调用方的是【这一屏真的画出来的那些行】,不是 rows —— 见抬头最后一段。
    const footerRows = footer ? footer(visible) : null

    // ★ 按名拒绝之三:合计挂在一个【不存在的列】上。
    //   静默忽略它 = 一个「调用方以为自己写了、而屏幕上没有」的合计。
    //   与上面两条拒绝同一族:一次响亮的拒绝,好过一个无声消失的数。
    if (footerRows) {
        const known = new Set(columns.map((c) => c.key))
        for (const fr of footerRows) {
            const bad = Object.keys(fr.cells).find((k) => !known.has(k))
            if (bad) {
                throw new Error(
                    `DATATABLE_FOOTER_UNKNOWN_COLUMN:表尾行「${fr.key}」把一个合计挂在列「${bad}」上,` +
                    '而这张表没有这一列。合计是按【列 key】对位的 —— 拼错一个 key,' +
                    '那个数会从屏幕上无声消失,而表看起来完全正常。'
                )
            }
        }
    }

    /**
     * 一行表尾在两个断点上各自怎么排。
     * ★ 格数从【看得见的列】数出来,不是从 `columns` —— 列显隐关掉一列之后
     *   表头少一格,表尾必须跟着少一格(展开区那一处 colSpan 就是为这件事
     *   从 priorityCols 改成 shownCols.filter 的,同一个坑)。
     */
    const footerLayout = (fr: FooterRow) => {
        const has = (c: Column<T>) => Object.prototype.hasOwnProperty.call(fr.cells, c.key)
        const firstIdx = shownCols.findIndex(has)
        if (firstIdx === 0) {
            throw new Error(
                `DATATABLE_FOOTER_NO_LABEL_ROOM:表尾行「${fr.key}」把合计挂在了【第一列】,` +
                '于是前导标签没有格子可待。表尾的形状是「标签 + 从某一列起的合计」——' +
                'balance-sheet / trial-balance / PayrollGrid 三张实表都是这个形状。' +
                '要让第一列也带数,把标签写进那一格的 cells 里,或者给第一列留空。'
            )
        }
        // 一个合计都没有:标签一路跨到底。
        const cut = firstIdx === -1 ? shownCols.length : firstIdx
        const tail = shownCols.slice(cut)
        return {
            has,
            tail,
            // 桌面档:展开钮那一格是 sm:hidden,不算它;勾选列两个断点都在。
            desktopLead: cut + (selection ? 1 : 0),
            // 手机档:前导里【只有留在表内的列】在场,再加勾选列与展开钮那一格。
            phoneLead: shownCols.slice(0, cut).filter(isPhoneCol).length
                + (selection ? 1 : 0) + (phoneScroll ? 0 : 1),
            // 390px 上不画、却有合计的那几列 —— 它们的数叠进手机档标签格。
            folded: tail.filter((c) => !isPhoneCol(c) && has(c)),
        }
    }

    // 【客户端模式永远不会走到这里】类型不允许它拿部分数据,所以没有"排了一半"这回事。
    // 服务端模式下这一行只是【报量】,不是警告:排序看得见全体。
    const cov = sorting?.coverage
    const partial = cov && cov !== 'complete' ? cov : null
    const noticeId = React.useId()

    const toggleSort = (key: string) => {
        setSort((s) => (s.key === key ? { key, dir: DIR_NEXT[s.dir] } : { key, dir: 'asc' }))
        setPage(0)
    }
    const toggleRow = (k: string) =>
        setOpen((s) => { const n = new Set(s); n.has(k) ? n.delete(k) : n.add(k); return n })

    return (
        <div className={cn('w-full', className)}>
            {/* ── 表上方的控件区 ──────────────────────────────────────────── */}
            {(filter || columnToggle || partial) && (
                <div className="mb-2 flex flex-wrap items-center gap-2">
                    {filter && (
                        <input
                            type="search"
                            value={q}
                            onChange={(e) => { setQ(e.target.value); setPage(0) }}
                            aria-label={filter.label}
                            placeholder={filter.label}
                            className="base-pressable min-w-0 flex-1 rounded-[var(--brand-radius)] border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] px-2.5 py-1.5 text-sm text-[color:var(--brand-text)] outline-none focus-visible:border-[color:var(--brand-ring)]"
                        />
                    )}
                    {columnToggle && (
                        <details className="relative">
                            <summary className="base-pressable cursor-pointer list-none rounded-[var(--brand-radius)] border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] px-2.5 py-1.5 text-sm text-[color:var(--brand-text)]">
                                {t('table.columns', { shown: shownCols.length, total: columns.length })}
                            </summary>
                            <div className="nav-glass absolute right-0 z-20 mt-1 min-w-44 rounded-[var(--brand-radius)] border border-[color:var(--brand-border)] p-2 shadow-md">
                                {columns.map((c) => (
                                    <label key={c.key} className="flex items-center gap-2 px-1 py-1 text-sm text-[color:var(--brand-text)]">
                                        <input
                                            type="checkbox"
                                            checked={!hidden.has(c.key)}
                                            onChange={() => setHidden((s) => {
                                                const n = new Set(s); n.has(c.key) ? n.delete(c.key) : n.add(c.key); return n
                                            })}
                                        />
                                        {c.header}
                                    </label>
                                ))}
                            </div>
                        </details>
                    )}
                    {/* ★ 只在服务端模式下出现,而且它【报量,不报警】—— 排序看得见全体。 */}
                    {partial && (
                        <p id={noticeId} className="w-full text-xs text-[color:var(--brand-muted-text)]">
                            {t('table.partialNotice', { shown: partial.shown, total: partial.total })}
                        </p>
                    )}
                </div>
            )}

            <div className="w-full overflow-x-auto">
                <table
                    data-slot="data-table"
                    // ★【手机上用 table-fixed,桌面上恢复 auto】390px 实测逼出来的一条 ★
                    //   auto 布局下,任何一个格子都能把整列撑宽 —— 实测一枚
                    //   「无库存 · out of stock」的小片就把第三列撑到 260px,
                    //   把物料那一列挤成【每行一个字】。在只剩三列的宽度里,
                    //   一个格子有权决定整列宽度是不行的。
                    //   fixed 之下列宽由表宽平分(或由列自己声明),没有哪个格子说了算。
                    //   桌面上列多、内容短,auto 排得更好,所以 sm 以上换回去。
                    className="w-full caption-bottom border-collapse text-sm table-fixed sm:table-auto"
                    aria-describedby={partial ? noticeId : undefined}
                >
                    {caption && <caption className="mt-2 text-sm text-[color:var(--brand-muted-text)]">{caption}</caption>}
                    <thead>
                        <tr className="border-b-2 border-[color:var(--brand-ocean)]">
                            {/* ★ 勾选框列 —— 桌面与手机都画,它不走 priority 那套逻辑
                                (见抬头:选择是这一页存在的理由,不是"读到才要问的东西")。 */}
                            {selection && (
                                <th className="w-8 px-1 align-middle">
                                    {selection.onToggleAll && (
                                        <SelectAllCheckbox
                                            total={visible.length}
                                            selected={visible.filter((r) => selection.selectedIds.has(rowKey(r))).length}
                                            onChange={() => selection.onToggleAll!(visible.map(rowKey))}
                                            label={selection.selectAllLabel ?? t('table.selectAll')}
                                        />
                                    )}
                                </th>
                            )}
                            {/* 手机上多一格放展开钮;桌面上它不存在。 */}
                            {/* scroll 模式下没有展开钮,所以也不留这一格。 */}
                            {!phoneScroll && <th className="w-8 px-1 sm:hidden" />}
                            {shownCols.map((c) => {
                                const activeClient = clientSort && sort.key === c.key && sort.dir !== 'none'
                                const activeServer = serverSort?.active?.key === c.key
                                const active = activeClient || activeServer
                                const dir = activeServer ? serverSort!.active!.dir
                                    : activeClient ? (sort.dir as 'asc' | 'desc') : null
                                // 客户端模式要比较器;服务端模式只要一句"这一列可以排"。
                                const canSort = clientSort ? !!c.sortValue
                                    : !!serverSort && (c.sortable === true || !!c.sortValue)
                                return (
                                    <th
                                        key={c.key}
                                        scope="col"
                                        aria-sort={active ? (dir === 'asc' ? 'ascending' : 'descending') : undefined}
                                        className={cn(
                                            // ★ STYLE-2(2026-09-09):表头字号 14px → 15px。
                                            //   出处是 variant C 自己那一行 spec:`text: 'text-[15px]'`
                                            //   (docs/variant-c-spec.md §4.3)。STYLE-1 实测:685 个 <th> 里
                                            //   **409 个的内边距早就是 C 的 px-3 py-2.5 了 —— 那是本组件干的**,
                                            //   唯一还差的就是这一个数 —— 改这一处,它们【绝大多数】一起到位
                                            //   (不是全部,见下面那条 ⚠)。
                                            //   ★ 只动字号:px-3 py-2.5 一个字节都没碰。
                                            //   ★ 行高【自己跟着走了】—— 这一条是实测,不是推的:
                                            //     我先推断「text-[15px] 只设字号,行高会继承 <table> 的
                                            //     text-sm=20px,于是差 1.43px」。**量出来不是这样:**
                                            //     实测 line-height = 21.4286px,与 spec 的 21.43px 一致
                                            //     (Tailwind v4 的任意值字号会把 line-height 一起重置)。
                                            //     ☞ 于是表头四项(字号 15 / 字重 500 / 行高 21.43 / 内边距 10-12)
                                            //       现在【全部】合 §4.3。**推断错了,读数是对的。**
                                            //   ⚠ 但【调用方写了字号的列不会动】:c.className 排在 cn() 最后,
                                            //     所以 `className: 'font-mono text-sm'` 这类列的表头仍是 14px。
                                            //     实测 28 条路由:102 个本组件的表头里 92 个到了 15px,
                                            //     **10 个没动**,全部是这种列(/finance/fx · /hr/departments · /output)。
                                            'px-3 py-2.5 align-middle text-[15px] font-medium text-[color:var(--brand-text)]',
                                            // 表头【桌面上不折行】—— 实测 1280px 下「库存状态」被折成
                                            // 每行一个字。手机上不加这一条:那里是 table-fixed,
                                            // 列宽是平分的,nowrap 会让表头顶出格子。
                                            'sm:whitespace-nowrap',
                                            c.align === 'right' ? 'text-right' : 'text-left',
                                            // ★ 非 priority 的列在手机上不出现在表里 —— 它们在展开区。
                                            !isPhoneCol(c) && 'hidden sm:table-cell',
                                            c.className
                                        )}
                                    >
                                        {canSort && serverSort ? (
                                            // 服务端模式:表头是一条【链接】—— 与那 8 页今天的做法逐字同形,
                                            // 于是转换刀换掉的只是外观,不是那条已经正确的排序。
                                            <a
                                                href={serverSort.href(c.key, activeServer && dir === 'asc' ? 'desc' : 'asc')}
                                                className="base-pressable inline-flex items-center gap-1 rounded px-1 -mx-1 hover:bg-[color:var(--brand-muted)]"
                                            >
                                                {c.header}
                                                <span aria-hidden className="text-[color:var(--brand-muted-text)]">
                                                    {active ? (dir === 'asc' ? '▲' : '▼') : '↕'}
                                                </span>
                                            </a>
                                        ) : canSort ? (
                                            <button
                                                type="button"
                                                onClick={() => toggleSort(c.key)}
                                                className="base-pressable inline-flex items-center gap-1 rounded px-1 -mx-1 hover:bg-[color:var(--brand-muted)]"
                                            >
                                                {c.header}
                                                <span aria-hidden className="text-[color:var(--brand-muted-text)]">
                                                    {active ? (dir === 'asc' ? '▲' : '▼') : '↕'}
                                                </span>
                                            </button>
                                        ) : c.header}
                                    </th>
                                )
                            })}
                        </tr>
                    </thead>
                    <tbody>
                        {visible.length === 0 && (
                            <tr>
                                <td colSpan={shownCols.length + (phoneScroll ? 0 : 1) + (selection ? 1 : 0)} className="px-3 py-8 text-center text-[color:var(--brand-muted-text)]">
                                    {empty ?? t('table.empty')}
                                </td>
                            </tr>
                        )}
                        {visible.map((row) => {
                            const k = rowKey(row)
                            const isOpen = open.has(k)
                            const restCols = phoneScroll ? [] : shownCols.filter((c) => !c.priority)
                            const rowCls = rowClassName?.(row)
                            return (
                                <React.Fragment key={k}>
                                    <tr className={cn('border-b border-[color:var(--brand-border)]', rowCls)}>
                                        {selection && (
                                            <td className="px-1 align-middle">
                                                <input
                                                    type="checkbox"
                                                    checked={selection.selectedIds.has(k)}
                                                    onChange={() => selection.onToggle(k)}
                                                    aria-label={(selection.selectRowLabel ?? t('table.selectRow'))}
                                                    className="base-pressable h-4 w-4"
                                                />
                                            </td>
                                        )}
                                        {!phoneScroll && <td className="px-1 align-middle sm:hidden">
                                            {restCols.length > 0 && (
                                                <button
                                                    type="button"
                                                    onClick={() => toggleRow(k)}
                                                    aria-expanded={isOpen}
                                                    aria-label={phoneExpandLabel ?? t('table.expandRow')}
                                                    className="base-pressable flex h-7 w-7 items-center justify-center rounded text-[color:var(--brand-muted-text)] hover:bg-[color:var(--brand-muted)]"
                                                >
                                                    <span aria-hidden className={cn('transition-transform', isOpen && 'rotate-90')}>›</span>
                                                </button>
                                            )}
                                        </td>}
                                        {shownCols.map((c) => (
                                            <td
                                                key={c.key}
                                                className={cn(
                                                    'px-3 py-2.5 align-middle text-[color:var(--brand-text)] break-words',
                                                    c.align === 'right' ? 'text-right tabular-nums' : 'text-left',
                                                    !isPhoneCol(c) && 'hidden sm:table-cell',
                                                    c.className
                                                )}
                                            >
                                                {c.render(row)}
                                            </td>
                                        ))}
                                    </tr>
                                    {/* ── 展开区:其余各列,带标签。只在手机上存在。 ────────── */}
                                    {isOpen && restCols.length > 0 && (
                                        <tr className={cn('border-b border-[color:var(--brand-border)] sm:hidden', rowCls)}>
                                            {/* colSpan 跟着【看得见的】priority 列走 ——
                                                用 priorityCols.length 是错的:列显隐关掉一个
                                                priority 列之后,展开区就会比表宽出一格。 */}
                                            <td colSpan={shownCols.filter((c) => c.priority).length + 1 + (selection ? 1 : 0)}
                                                className="bg-[color:var(--brand-muted)] px-3 py-2">
                                                <dl className="base-reveal grid grid-cols-[minmax(6rem,auto)_1fr] gap-x-3 gap-y-1.5 text-sm">
                                                    {restCols.map((c) => (
                                                        <React.Fragment key={c.key}>
                                                            <dt className="text-[color:var(--brand-muted-text)]">{c.phoneLabel ?? c.header}</dt>
                                                            <dd className="text-[color:var(--brand-text)]">{c.render(row)}</dd>
                                                        </React.Fragment>
                                                    ))}
                                                </dl>
                                            </td>
                                        </tr>
                                    )}
                                </React.Fragment>
                            )
                        })}
                    </tbody>
                    {/* ── 表尾:合计行 ────────────────────────────────────────
                        ★ 不给 footer 时【整段不存在】—— 160 个调用点一个 <tfoot> 都不长。
                        shownCols 为空(列显隐把列全关了)时也不画:没有列就没有合计可言,
                        而那时两个前导跨度都会是 0,`colSpan={0}` 不是一个合法的格子。 */}
                    {footerRows && footerRows.length > 0 && shownCols.length > 0 && (
                        <tfoot>
                            {footerRows.map((fr) => {
                                const L = footerLayout(fr)
                                return (
                                    <tr key={fr.key} className={cn(tableC.bodyRow, fr.className)}>
                                        {/* ★ 标签格【写两份】—— 两份的字一模一样,分开的只是它跨几格。
                                            这就是那 6 张手搓表逐张手写的那一份,区别只在于
                                            **这两个数是组件自己数出来的,调用方一个数字都不写。** */}
                                        <td colSpan={L.phoneLead} className={cn(tableC.cell, 'sm:hidden')}>
                                            {fr.label}
                                            {/* 390px 上不画的那几列,合计叠在这里 —— trial-balance:234
                                                手写的答案,照抄。合计跟着列一起消失,那张表在手机上
                                                就不再是试算表。 */}
                                            {L.folded.length > 0 && (
                                                <span className="mt-0.5 block font-mono text-[11px] font-normal text-[color:var(--brand-muted-text)]">
                                                    {L.folded.map((c, i) => (
                                                        <React.Fragment key={c.key}>
                                                            {i > 0 && ' · '}
                                                            {c.phoneLabel ?? c.header}{' '}
                                                            {fr.cells[c.key]}
                                                        </React.Fragment>
                                                    ))}
                                                </span>
                                            )}
                                        </td>
                                        <td colSpan={L.desktopLead} className={cn(tableC.cell, 'hidden sm:table-cell')}>
                                            {fr.label}
                                        </td>
                                        {L.tail.map((c) => (
                                            <td
                                                key={c.key}
                                                className={cn(
                                                    tableC.cell,
                                                    c.align === 'right' ? 'text-right tabular-nums' : 'text-left',
                                                    // 与表体同一条规矩:非 priority 的列在手机上不出现在表里。
                                                    !isPhoneCol(c) && 'hidden sm:table-cell',
                                                    c.className
                                                )}
                                            >
                                                {L.has(c) ? fr.cells[c.key] : null}
                                            </td>
                                        ))}
                                    </tr>
                                )
                            })}
                        </tfoot>
                    )}
                </table>
            </div>

            {pageSize && sorted.length > pageSize && (
                <div className="mt-2 flex items-center justify-between gap-2 text-sm text-[color:var(--brand-muted-text)]">
                    <span>
                        {t('table.range', {
                            from: safePage * pageSize + 1,
                            to: Math.min((safePage + 1) * pageSize, sorted.length),
                            total: sorted.length,
                        })}
                    </span>
                    <span className="flex gap-1">
                        <button
                            type="button" disabled={safePage === 0} onClick={() => setPage(safePage - 1)}
                            className="base-pressable rounded-[var(--brand-radius)] border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] px-2.5 py-1 disabled:cursor-not-allowed disabled:bg-[color:var(--brand-disabled-bg)] disabled:text-[color:var(--brand-disabled-text)]"
                        >{t('table.prevPage')}</button>
                        <button
                            type="button" disabled={safePage >= pageCount - 1} onClick={() => setPage(safePage + 1)}
                            className="base-pressable rounded-[var(--brand-radius)] border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] px-2.5 py-1 disabled:cursor-not-allowed disabled:bg-[color:var(--brand-disabled-bg)] disabled:text-[color:var(--brand-disabled-text)]"
                        >{t('table.nextPage')}</button>
                    </span>
                </div>
            )}
        </div>
    )
}
