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
//   ✗ 不管 `tabular-nums` —— 那是列的意思,不是表的外观。
//     ★★【就地更正 —— FONT-3,2026-09-12】这一行原来还写着 `font-mono`。
//       **`font-mono` 那一族已经不存在了**(范围内 829 个代码点去掉 828 个,
//       留下 `app/settings/reference/PermissionReferenceTable.tsx:29` 那一个)。
//     ★ 而【字号】从 FONT-3 起**由本文件管**,见下面 `TABLE_TEXT`。
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
/**
 * ★★ FONT-3(2026-09-12)· 表格文字的【那一个字号】—— 一处定义,三个文件都指它 ★★
 *
 * 【值】15px。出处 `docs/variant-c-spec.md` §4.3(variant C,MEASURED),
 *   Tim 2026-09-12 Q5 裁定:**表体与表头都是这一个数**,而它不是取样页的多数派
 *   (那一页 `<td>` 的多数派是 14px ×92 : 15px ×25 —— spec §2:多数派不是标准)。
 *
 * 【★ 它为什么必须排在 `cn()` 的【最后】—— 这是 Tim Q16 的那一半】
 *   `cn()` = `twMerge(clsx(…))`,而 twMerge 让**同一族里【后面】那一个类赢**。
 *   于是把这个 token 放在 `c.className` **后面**,一个列定义自己写的
 *   `text-sm` / `text-xs` 就**再也设不了这一格的字号** —— 而那正是 item i:
 *   Tim 看到的三处表头不齐,每一处的元凶都是**调用点在列上写了字号**。
 *   ★ 实测(tailwind-merge 3.6.0,本仓库这一份):
 *     `twMerge('text-xs','text-[15px]')` → `text-[15px]`;
 *     `twMerge('text-[color:var(--brand-text)]','text-[15px]')` → **两条都留着**
 *     (字色与字号不是同一族);
 *     `twMerge('text-sm font-semibold','text-[15px] font-medium')` → **font-semibold 被吃掉**
 *     —— ☞ **所以这里只搬【字号】那一个 token,`font-medium` 留在原位**:
 *     这一刀不裁字重,一个调用点写的 `font-semibold` 照旧赢。
 *
 * 【★ 为什么不写成 `@layer base` 里的一条 `td { font-size: 15px }`】
 *   Tailwind v4 的层序是 theme → base → components → utilities，
 *   `app/globals.css` 自己那一段注释白纸黑字记着这是**刻意的**:base 压不过工具类。
 *   ☞ 于是一条 base 规则会**输给每一个调用点的 `text-xs`** —— item i 一处都修不掉。
 *
 * 【★ 为什么不把 `c.className` 里的字号 token 剥掉】
 *   那要在组件里再写一支 class 串解析器(仓库里的第二份),而且它会**悄悄吃掉**
 *   一个调用点在源码里还看得见的类。排在最后只改一行,而且
 *   **调用点那 294 个字号类一个都不删**(Tim Q15:删掉它们屏幕上什么都不变,
 *   却把证据一起删了)。
 *
 * 【★ 那几个【不渲染文字】的结构格,为什么也拿这个 token(外加一个 `font-medium`)】
 *   两个组件里有四个没有内容的 `<th>`(勾选框列 · 手机展开钮 · 动作列 · 空态),
 *   它们此前渲染成 **UA 默认的 14 / 700 / 20** —— ★ **实测:那正是「改完之后表头
 *   仍然有第二个值」的那几张表的【全部】原因**(desktop 5 张 · phone 82 张)。
 *   ☞ 它们**一个字都不渲染**,所以这两个 token 在屏幕上是零像素;
 *   加上它们,是因为**一条规则不该留四个例外** —— 下一个人不必再判一次
 *   「这一格算不算表头」。⚠ `font-medium` 是这一刀**唯一**一处越出
 *   「字族 · 字号 · 行高 · 数字等宽」四个值的改动,而它落在**没有字的格子**上。
 */
export const TABLE_TEXT = 'text-[15px]'

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
    headCell: `px-3 py-2.5 align-middle ${TABLE_TEXT} font-medium`,

    /**
     * 表体格:内边距 10/12 · 15px · 400 · 行高 21.43(继承自 `root` 的无单位倍数)。
     * spec §4.3「表体格字号 / 字重 / 行高」。
     *
     * ⚠⚠ **【就地更正 —— FONT-3,2026-09-12】这一段原来写着:**
     *   ~~「这一段与 `data-table.tsx:526` 差【一个 token】:组件那边没有 `text-[15px]`,
     *   于是组件的表体今天渲染 14px,而标准要 15px。本刀不改组件。」~~
     *   ★★ **那个差额已经合上了,而合它的不是搬 class,是 `TABLE_TEXT`**:
     *   `data-table.tsx` 与 `editable-table.tsx` 的**表头格与表体格**现在都把
     *   `TABLE_TEXT` 排在 `cn()` 的最后(见上面 `TABLE_TEXT` 的抬头)。
     *   ☞ **于是三个文件今天是同一个数,而且调用点【压不过它】。**
     *   ★ 读数(FONT-3 改前 · desktop · 102 张表):`<td>` 14/400/20 ×3039 ·
     *     15/400/21.43 ×620 · 12/400/16 ×231;`<th>` 15/500/21.43 ×409 ·
     *     14/500/20 ×131 · 12/500/16 ×41 · 14/700/20 ×26。改后的读数见
     *     `docs/handbacks/FONT-3.md`。
     */
    cell: `px-3 py-2.5 align-middle ${TABLE_TEXT}`,

    /**
     * 表体行分隔线 1px。spec §4.3「表体行分隔线」。
     * = data-table.tsx:497。**素表只有这一条线:格子之间没有竖线,行没有斑马纹。**
     */
    bodyRow: 'border-b border-[color:var(--brand-border)]',
} as const

export type TableCPart = keyof typeof tableC
