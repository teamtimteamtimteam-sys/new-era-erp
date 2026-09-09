// app/components/ui/table-style.ts
//
// ════════════════════════════════════════════════════════════════════════════
// TABLE-STYLE-1(2026-09-09)· variant C 的表格外观,**一份定义,两条路都指它**
// ════════════════════════════════════════════════════════════════════════════
//
// 【它为什么存在 —— 一句话】
//   这套系统里有 **76 张手搓 `<table>`**,而其中 **23 张【转不成】组件**:
//   14 张的并列数组提交会被拆坏、7 张要 `tfoot` / 分组抬头(组件做不到)、
//   2 张的列数是数据。**而那三条理由没有一条是关于外观的。**
//   variant C 对一张表只提四件事 —— 素表 · 2px Hawaiian Ocean 表头线 ·
//   格子内边距 · 字号字重 —— **四件全是纯呈现,与"这张表怎么渲染出来的"无关。**
//   ☞ 于是那 23 张**留着自己的标记,照样能穿上这身衣服**。本文件就是那身衣服。
//
// 【★ 而它必须是【一份】,不是两份 ★】
//   这一族刀存在的理由,就是同一个外观在仓库里长出了好几份定义然后各自漂。
//   所以本文件的验收条件不是"手搓表能用",是:
//     **`app/components/ui/data-table.tsx` 也能消费它** —— 它今天写死的那几段
//     class 串,与下面的常量【逐 token 相同】(表体字号那一条除外,见下)。
//   ☞ 它住在 `app/components/ui/` 而不是别处,正是为了这件事:
//     组件与手搓表都 import 得到它,而棘轮不扫这个目录(组件库自己该有那一份)。
//
// 【为什么是 Tailwind class 常量,不是 globals.css 里的一个 `.table-c`】
//   CSS 那条路会写成后代选择器(`.table-c th { … }`),而**本仓库刚刚为这条路
//   付过账**:`docs/variant-c-spec.md §7.1` 实测到 `table.tsx` 的
//   `[&_tr]:border-b`(特指度 0,1,1)**压过**行自己的 `border-b-2`(0,1,0),
//   于是 C 的表头线在取样页上渲染成 1px —— **一条从来没在屏幕上出现过的 2px**。
//   ☞ 再造一个后代选择器 = 把那个特指度陷阱原样复刻一遍。
//   class 常量没有这个问题:它就是元素自己身上的类,和组件今天的做法同一种。
//
// 【★ 它【不】管什么 —— 说白,别高估它 ★】
//   ✗ 不管布局:`w-full` / `table-fixed` / `min-w-max` / `sticky` 由调用方加。
//     组件的 `table-fixed sm:table-auto` 是它自己那套手机机制的一部分,不是 C 的规格。
//   ✗ 不管字色:§4.3 记的表头字色是 `--foreground`,而**已上线的组件用的是
//     `--brand-text`**(spec §7.4:两个都明写过、都过 AA)。**本文件不替谁裁这一条**,
//     于是两边今天各自保留原样,一个字节都不碰。
//   ✗ 不管分组抬头行 / tfoot 合计行 / 空态行的底色与字重 —— 取样页里【没有】
//     这些东西(spec §6),对它们的正确答案是「今天没有标准」,不是一个我挑的值。
//   ✗ 不管 `font-mono` / `tabular-nums` —— 那是列的意思,不是表的外观。
//
// 【出处:每一个值都指向 docs/variant-c-spec.md §4.3 的一行(实测,不是推算)】
// ════════════════════════════════════════════════════════════════════════════

/**
 * variant C 的表格呈现 —— 唯一的一份。
 *
 * 用法(手搓表):
 *   <table className={`w-full ${tableC.root}`}>
 *     <thead><tr className={tableC.headRow}>
 *       <th className={`${tableC.headCell} text-left`}>…</th>
 *     </tr></thead>
 *     <tbody><tr className={tableC.bodyRow}>
 *       <td className={tableC.cell}>…</td>
 *     </tr></tbody>
 *   </table>
 */
export const tableC = {
    /**
     * 表根。`text-sm` 在这里【不是字号,是行高的来源】—— 这一条是量出来的,
     * 而本刀第一版把它写错过,照直记下来:
     *
     *   第一版写的是 `text-[15px]`,以为"任意值字号会把 line-height 一并重置"
     *   (那句话抄自 STYLE-2 的实测结论)。**实测下来是反的:**
     *   `text-[15px]` 这类任意值**只设 font-size,不设 line-height**。
     *   于是行高退回继承来的 1.5 倍,22 张表全部渲染成 **22.5px**,
     *   而 spec §4.3 记的是 **21.43px**。
     *
     *   已上线的 `data-table.tsx` 之所以是对的,靠的正是这一条:
     *   它的表根写 `text-sm`,而 Tailwind v4 的 `text-sm` 带的是一个
     *   **无单位的 line-height(1.25/0.875 = 1.42857)**;无单位行高按倍数往下继承,
     *   于是 `<th>` 上的 `text-[15px]` 得到 15 × 1.42857 = **21.4286px**。
     *   实测(/finance/journal,DataTable):th 15px / 行高 21.4286px。**对上了。**
     *
     * ☞ 所以字号住在【格子】上,行高的来源住在【表根】上,两者都与组件逐字节相同。
     *   一个没有拿到 `tableC.cell` 的格子会退成 14px —— 与组件今天的表体一致,
     *   不会退成一个谁都没见过的值。
     */
    root: 'border-collapse text-sm',

    /**
     * 表头行:2px Hawaiian Ocean 下边线。spec §4.3「表头线」+ C 的 `headRow`。
     * ★ C 的 headRow **只有这条线,没有底色** —— 带底色的是变体 B
     *   (`bg-[color:var(--brand-muted)]`,见 brand-sampler/page.tsx)。
     * = data-table.tsx:391 的裸 `<thead><tr>`(实测渲染 2px,spec §7.1)。
     */
    headRow: 'border-b-2 border-[color:var(--brand-ocean)]',

    /**
     * 表头格:内边距 10/12 · 15px · 500。spec §4.3。
     * = data-table.tsx:442 那一段(去掉字色与 `sm:whitespace-nowrap`)。
     * 对齐(`text-left` / `text-right`)由调用方加 —— 那是列的意思。
     */
    headCell: 'px-3 py-2.5 align-middle text-[15px] font-medium',

    /**
     * 表体格:内边距 10/12 · 15px · 400 · 行高 21.43(继承自 `root` 的无单位倍数)。
     * spec §4.3「表体格字号 / 字重 / 行高」。
     *
     * ⚠ **这一段与 `data-table.tsx:526` 差【一个 token】:组件那边没有 `text-[15px]`。**
     *   于是组件的表体今天渲染 **14px**,而标准要 15px —— spec §4.3 自己也记着
     *   「`<td>` 仍然是 14px(STYLE-2 只动了表头)」。
     *   **本刀不改组件**(委托书 R5:不许碰 data-table.tsx 的渲染路径),
     *   所以这是一处【写下来的、两边都量过的】差额,不是一处忘了的:
     *   组件那边把 `px-3 py-2.5 align-middle` 换成 `tableC.cell`,这一条就合上了。
     */
    cell: 'px-3 py-2.5 align-middle text-[15px]',

    /**
     * 表体行分隔线 1px。spec §4.3「表体行分隔线」。
     * = data-table.tsx:497。**素表只有这一条线:格子之间没有竖线,行没有斑马纹。**
     */
    bodyRow: 'border-b border-[color:var(--brand-border)]',
} as const

export type TableCPart = keyof typeof tableC
