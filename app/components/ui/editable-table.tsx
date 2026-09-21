'use client'

// ════════════════════════════════════════════════════════════════════════════
// CONV-2(2026-09-03)· 可编辑网格 —— **DataTable 的姊妹件,不是它的变体**
// ════════════════════════════════════════════════════════════════════════════
//
// ★★★【FORK DECISION —— 这是一次【刻意的】分叉,不是没清理干净的重复】★★★
//
//   `DataTable` 的列描述符是 `render: (row: T) => ReactNode`。**那是一个纯只读
//   契约**:它是一个函数,它没有地方存放"这一行正在被编辑"、"这一行有一次
//   pending 的保存"、"这一行上一次保存报了什么错"。把编辑塞进去只有两条路:
//     · 让页面把编辑状态提到外面、再从闭包里捞回来 —— 那等于把状态机摊给每一页;
//     · 给 DataTable 加第二套分支 —— 那会让【只读那一条路】也一起变复杂,
//       而只读那一条路有 70 页在走,可编辑的只有 10 页。
//   **所以这里另起一个组件,而【外壳全部复用】:** ListPage · RefusalBlock ·
//   notices 槽 · `PhoneTreatment` 这个类型本身,全部来自 CONV-1,一件都没有重写。
//
//   ☞ 后来的人:看见两个表格组件时,**不要把它们合起来"整理"**。
//     它们服务两种契约,而这个仓库为"一个组件伺候两个主人"付过五次账。
//
// ────────────────────────────────────────────────────────────────────────────
// ★★ DRAFT-1(2026-09-21,Tim 的 R8)· 这一刀让它更像 DataTable 了 ——
//    **而那条分叉的理由【一个字都没有动】** ★★
//
//   本刀给它加了 `rowActions`(能力 A)、`rowClassName`(能力 B)、
//   `canSave`(能力 E)与 `mode: 'page-owned'`。前两件 `DataTable` 也有,
//   于是两个组件在【功能清单】上更靠近了一步。
//
//   ☞ **那不是分叉的判据,从来都不是。** 判据是【列描述符的契约】:
//        DataTable   `render: (row) => ReactNode`      —— 纯只读,没地方放草稿
//        EditableTable `edit: (draft, set) => ReactNode` —— 编辑态的投影
//     本刀加的四件**没有一件碰到这条分界**:`rowActions` 收的是 `row`,
//     `rowClassName` 收的是 `row`,两件都是只读投影;`canSave` 收的是 `draft`,
//     它只在可编辑那一侧有意义;`'page-owned'` 动的是【谁持有草稿】,
//     而不是【格子回调长什么样】。
//   ☞ 所以那条警告照旧成立:**功能多寡不是合并的理由,契约才是。**
//
// ────────────────────────────────────────────────────────────────────────────
// ★★★【DRAFT-1 的警告:`edit()` 里【不许】放带 `name` 的输入】★★★
//
//   这个组件把 `c.edit(...)` 画【两遍】:`:418` 桌面格(`hidden sm:block` ——
//   **CSS 藏起来,不是移出 DOM**)与 `:489` 手机展开区(`isOpen` 时挂载)。
//   两份读写同一个 store,所以【受控 state】一点问题都没有 —— 这正是
//   DRAFT-0 §3.1 说的那件"双渲染已经解掉了"。
//
//   ⚠ **但那句话只对受控 state 成立,对 `FormData` 不成立。**
//     一个带 `name=` 的输入放进 `edit()`,展开那一行之后它在文档里【有两份】,
//     于是提交时它在 `FormData` 里【出现两次】。两种坏法,都不报错:
//       ① `getAll()` 的并列数组 —— 多出来的那一格把几条数组【错位】,
//          于是 A 行的数量写到 B 行上。**它安静地写错数。**
//       ② `get()` 的具名字段 —— 拿到的是【第一个】,也就是桌面那一份;
//          而手机上人打的字在展开区那一份里。**于是手机上打的字整个丢掉。**
//
//   ☞ 今天这件事【仍然没有发生过】:**七个调用点一个 `name=` 都没有**
//     (DRAFT-2 实测 2026-09-21,7/7 全 0;DRAFT-1 量的是当时的 4 个)。
//     它是一个**埋着的坑**,不是一个在流血的伤口。
//   ☞ 已在册:`docs/known-issues.md` 的 `EDITABLETABLE-NAME-DOUBLE-SUBMIT`。
//
// ────────────────────────────────────────────────────────────────────────────
// ★★★【DRAFT-2 · Tim 的 Q1 裁定(2026-09-21):治法是 **(b)**,八张一次裁完】★★★
//
//   八张并列数组表(`#18` `#20` `#21` `#22` `#23` `#24` `#26` `#27`)此前全卡在上面
//   那条坑上,而 DRAFT-1 把治法押后,要一次裁完。**裁定是 (b):页面持有那个数组,
//   草稿经表【外面】一个隐藏的 `*_json` 交出去,格子里不再有具名输入。**
//
//   ★★ **说清楚 (b) 做了什么、没做什么 —— 这是这条裁定最容易被读错的地方:**
//     **(b) 不修上面那个机制,它拿走那个机制的燃料。** 两份 `c.edit(...)` 照旧都在
//     DOM 里;变的是格子里不再有 `name=`,而那座桥画在表外面,**只画一遍**。
//   ☞ 所以**这个文件里没有一行代码是为 (b) 改的** —— 它改的是调用点的形状。
//
//   ★ **Tim 的三条理由,照他的话记:**
//     ① **它已经是这棵树的形状** —— 六座桥住在五个文件里(`TemplateForm:108` ·
//        `NewOrderForm:371,372` · `PayrollGrid:119` · `ImportStatementForm:177,178`),
//        服务端逐个 `JSON.parse` 收回去。**(b) 不是一个新花样,它是现成那个。**
//     ② **(c) 会在手机转屏时把打的字弄丢。** `sm` = 40rem = **640px**(Tailwind v4 默认,
//        `app/globals.css` 里没有覆盖);一台 390×844 的手机转成横屏是 **844px 宽,
//        它跨过 `sm`**。(c) 在那一刻把活着的那一份卸载、把另一份挂上,而一个**非受控**
//        的 `<input name=…>` 挂上来带的是 `defaultValue` —— **字没了。**
//        ★ **今天的代码【不会】丢**(藏起来的那一份还在 DOM 里拿着那些字)。
//        ☞ **(c) 等于拿一个安静写错数的坑,换一个安静丢字的坑,而后者今天并不存在。**
//     ③ **(c) 要修两遍。** `data-table.tsx` 的同一个机制
//        (`DATATABLE-UNCONTROLLED-NAME-DOUBLE-SUBMIT`)是同一件事的另一头;
//        (b) 让两头对那八张同时失效,因为具名输入根本不进格子。
//
//   ⚠ **(b) 之后这条规矩【没有任何东西守着】,所以它有一道闸:**
//     `scripts/check-editable-name.mjs`(在 `npm run build` 链里)——
//     `<EditableTable>` 的 `columns` 区段里出现 `name=` 就变红。
//     ★ **`render` 与 `edit` 一视同仁**(组件对两者都画两遍);
//     ★ **`footer` 【不】在判据内,而那是刻意的** —— 表尾画在表外面只画一遍,
//       那正是这座 JSON 桥该待的地方。拦下 footer 等于拦掉解法本身。
//     ☞ 实测(DRAFT-2,故障注入):往一个格子里放一个 `name=` → **退出码 1**,
//       点名 `GoalsEditor.tsx:146`;放进 `footer` → **退出码 0**;撤掉 → **0**。
//
//   ⚠ **照直记一句,免得下一个人把它读成"已经验过了":这条裁定【没有】一个
//     跑在真路由上的红→绿测试。** 今天七个调用点一个 `name=` 都没有,所以没有一页
//     今天是红的;而一个数 DOM 的探针**在 (b) 之下会一直红**,因为 (b) 不改那个双渲染。
//     ☞ **那道闸是这条裁定唯一一个真的红得起来的测试。** 浏览器那份证明是
//       **正面证据**(每个字段只提交一次、带着那个断点上打的字),**不是红→绿。**
//
// ────────────────────────────────────────────────────────────────────────────
// ★★【DRAFT-1 欠下的那一处落点,DRAFT-2 付掉了 —— `mode:'page-owned'` 为什么留着】★★
//
//   DRAFT-1 把 `mode:'page-owned'` 建下来时**一个消费者都没有**,而本仓库为
//   「加了一个没有消费者的能力」记过一笔(TABLE-FOOTER-1 的表尾至今零消费者)。
//   那一刀是纯文档刀,不许动 `.tsx`,所以裁定**没有落到这里**;
//   队列第 4 行把这笔账记成「下一刀【凡是打开 editable-table.tsx 的那一刀】来付」。
//
//   ★ **措辞照抄 `docs/handbacks/DRAFT-1.md` §3.1,一字不改:**
//
//     > ### ★★ Tim 的裁定(2026-09-21):**这件零消费者的能力【留着】**
//     > **理由是他的,照他的话记:** 它的消费者 —— **#6 · #7 · #8 · #9 —— 已经排在下一刀了。
//     > 也就是说这是一件【等着一个已排期消费者】的能力,不是一件照着猜建的能力。**
//     > ☞ ★ **这正是它与 TABLE-FOOTER-1 那个表尾的分别:那一件建下来的时候,
//     > 后面【一张排期的表都没有】。**
//
//   ☞ **兑现到哪一步了(DRAFT-2,2026-09-21):** 第一个消费者是 **`#24 NewQuoteForm`**
//     (`app/sales/quotes/new/NewQuoteForm.tsx`)—— 它同时是**验证那条 (b) 裁定的那一张**。
//     **#6 · #7 · #8 · #9 顺延到下一刀**,按 Tim 的停止线:它们**从来不在那条坑的射程里**
//     (#6/#7 连 `<form>` 都没有,#8/#9 早就坐在 JSON 桥上)。
//
// ────────────────────────────────────────────────────────────────────────────
// ★【DRAFT-2 · Q6:`page-owned` 只收得到一个 `expand` 标签】
//
//   那一模式下 `showActions = canEdit && !!onSave` 恒为假(它那一支没有 `onSave`),
//   而逐行的 `dirty` 恒为 `false` —— 于是 `edit` / `save` / `saving` / `cancel` /
//   `unsaved` 这五个标签**一个都渲染不到**。收着它们只会让每个调用点去编五个
//   **永远不会出现在屏幕上**的译文键。
//   ☞ 所以 `labels` 住在判别式里:那一支只要 `{ expand }`。
//     **与 `sorting?: never` 同一条道理 —— 写在类型上,不是写在注释里。**
//

// ────────────────────────────────────────────────────────────────────────────
// ★ Tim 的 Q3:【一次只编辑一行】是默认,【全行同时编辑】是显式的第二种模式 ★
//
//   两种模式**共用同一个状态形状** —— `Record<行键, 草稿>`。
//   **「一次一行」就是这个 Record 被约束到【至多一个键】。**
//   正因为形状同一,它不是两个组件;正因为约束是显式的,它也不是一个含糊的默认值。
//
// ★ Tim 的 Q4:【可编辑的表不许排序、不许分页】—— 写在类型上,不是写在注释里 ★
//
//   CONV-1 点名"正在编辑第 3 行时点了排序会怎样"是没有人设计过的交互。
//   CONV-2 逐个量过那 10 张可编辑网格:**没有一张有用户可控的排序或分页。**
//   也就是说那是一个【零个真实例子】的交互,而照着零个例子做设计,
//   正是 PAGE-0 与 CONV-1 各自付过一次账的那件事。
//
//   所以这里不是"暂不支持",而是 `sorting?: never` / `pageSize?: never` ——
//   **写上去就编译不过**,而且错误停在这段理由旁边。
//   ☞ 它带来一个比任何提示都硬的后果:
//     **「排序/翻页把打了一半的字悄悄丢掉」在这个组件里【构造上不可能发生】。**
//     那条规矩因此不再依赖任何人记得它。
//
// ★ Tim 的 Q5:【脏】是【算】出来的,永远不是一个存下来的 flag ★
//   一个 `dirty` 布尔是第二个真相来源,它可以和它所描述的那些值【不一致】;
//   一次比较不会。草稿与原行本来就都在手边,所以这次比较是免费的。
//
// ★ Tim 的 Q6:整行保存;**失败时【保留】打好的字,行留在编辑态** ★
//   ☞【为什么失败时禁止 router.refresh()】—— 一句话,连着理由一起写下来:
//     **从服务端重画这一行,会把人正要去改的那些输入毁掉。**
//     (一条带着理由的规矩活得下来;一条不带理由的规矩会被后人"顺手整理"掉。)
//   逐格保存被否掉:写库那一侧收的是整行 patch,逐格意味着一次编辑要 N 次往返。
//
// ★ Tim 的 Q7:脏着离开这一页 —— `beforeunload`,并且**这是一条记录在案的例外** ★
//   IDLE-DRAFT【不覆盖】可编辑网格,而且是四条机械上的理由,不是口味:
//     ① `useFormDraft` 靠 `new FormData(form)` 取值 —— 这里【没有 <form> 元素】;
//     ② 它靠往 `form.elements.namedItem(name)` 写 `el.value` 恢复 ——
//        这里的输入是 React 受控的,直接写 DOM 会在下一次渲染被丢掉,
//        **永远到不了 draft 里**;
//     ③ 它按 `name` 属性认字段 —— 这里的输入没有 name;
//     ④ 它的 `subject` 是【一条】记录的 updated_at —— 一张网格有 N 行 N 个指纹,
//        那个陈旧性判据没有一个单一的值可以落。
//   **所以本刀【不给网格留草稿】,这是一条写下来的限制,不是一次疏忽。**
//
//   ☞★【记录在案的例外:这是本系统里唯一一次【说不出理由】的拒绝】★
//     浏览器自己拥有那个对话框的措辞,我们改不动它。也就是说,在一个
//     "处处按名拒绝、拒绝必说明理由"的系统里,这一处拒绝是【哑的】。
//     Tim 的裁定是照收:**把打好的字悄悄弄丢,比一次哑的拒绝更坏,
//     而哑的那个至少看得见。**
//     ☞ 后来的人:这是一条【带理由的例外】,不是一次疏漏 ——
//       也【不能】被引用成"再来一个哑拒绝"的先例。
//
//   ☞【它盖不住的那一半,同样写下来】`beforeunload` 只管关标签页与刷新。
//     Next 16 的 App Router 没有提供稳定的导航拦截,而为此去 monkey-patch
//     `history` 是这个仓库不做的那类事。**所以站内 <Link> 跳走会丢掉半行输入,
//     这是一条声明过的限制。**
//
// ★ Tim 的 Q8:错误落在【那一行】上,而且带 role="alert" ★
//   字段级绑定是第 6 刀的事(PAGE-0 已排队)。这里只做一件不会和它打架的事:
//   因为 Q3 保证同时只有一行在编辑,**"这个错"和"它属于哪一行"本来就没有歧义**,
//   所以错误画在那一行下面,而不是页顶那个红框 —— 比今天严格更近一步,
//   第 6 刀之后可以在行内继续往格子上绑,不需要移动任何东西。
//   PAGE-0 量过:88 个含表单的文件里 `aria-invalid` 只有 1 个,`role="alert"` 是 0 个。
//
// ★ ④ 手机:**编辑发生在展开区里,不在格子里** ★
//   CONV-1 对只读表的答案是"留下的列 + 一行展开"。对编辑,把 `<input>` 挤进
//   390px 的 table-fixed 格子里是不能用的。所以这里:
//     · 桌面 —— 在格子里就地编辑;
//     · 手机 —— 一进编辑态就【自动展开那一行】,把**每一个可编辑字段**
//       画成展开区里带标签的一竖列(dt = 表头,dd = 那个输入),整宽、有标签;
//       priority 列仍然留在上面那一行,只读,用来认清"我在改哪一行"。
//   **也就是说:一行【可以】在展开区里被编辑,而且在手机上那是【唯一】的编辑处。**
//   动作钮同理:桌面在动作列,手机在展开区末尾。
//
// ────────────────────────────────────────────────────────────────────────────
// ★★★【Tim 的 Q7 裁定(2026-09-21):建在 `EditableTable` 上的表,行内动作
//     【就待在手机展开区里】—— `TABLE-STYLE-1 / R1` 那条「动作列在 390px 上不折」
//     对这个组件【不适用】】★★★
//
//   ⚠ **被反转的那一条在案,点名写出来,免得两处读起来像在打架:**
//     `docs/base-components.md` §20.1(`TABLE-STYLE-1 / R1`,Tim 2026-09-09)——
//     「一列如果画的是【要按的控件】,它在手机上永远可见」。
//     ★ 那一条**点名改过三张表的行为**,而其中一张正是
//     `app/sales/orders/[id]/amend/AmendOrderForm`(本族的 `#22`)。
//     ☞ **所以这不是一次含糊的优先级,是一次点名的反转。**
//
//   ★★★ **而它不是「R1 被投票投掉了」—— 是 R1 在这个组件上【根本做不到】:**
//     `:676-679` —— 行格子里,一个可编辑列画的是
//       `<span className="hidden sm:block">{c.edit(…)}</span>` +
//       `<span className="sm:hidden">{c.render(row)}</span>`
//     ☞ **手机上的表格行,每一列都是 `c.render(row)`,只读 —— priority 与否都一样。**
//     **在 `EditableTable` 的手机行里,没有任何办法让一个控件是【按得动】的。**
//     于是 R1 要的那件事(把控件留在明面上、并且够得着)在这里**不是被否决,
//     是无法满足**。把动作列留在明面上只会得到一个**画出来却按不动**的控件 ——
//     那比收进展开区更坏:R1 自己的理由是「够不着的动作等于不存在」,
//     而一个看得见又按不动的控件,是一次**没有理由的拒绝**。
//
//   ☞ **代价照直记:`#22` 的移除勾选从 0 次点按变成 1 次点按**,
//     也就是 R1 当年在这张表上刚刚买下来的那一次。**这是一次有意的回退。**
//   ☞ 后来的人:**这条例外只属于 `EditableTable`。** `DataTable` 与手搓表上
//     R1 一个字都没有变 —— 那两处的格子在手机上不是强制只读的。
// ────────────────────────────────────────────────────────────────────────────
// ════════════════════════════════════════════════════════════════════════════

import { useTranslations } from '@/lib/i18n/client'
import * as React from 'react'
import { cn } from '@/lib/utils'
import { Button } from '@/app/components/ui/button'
import type { PhoneTreatment } from '@/app/components/ui/data-table'
import { TABLE_TEXT } from '@/app/components/ui/table-style'

/**
 * 一列。`render` 是只读时怎么画;`edit` 是编辑时怎么画。
 * **不给 `edit` 就表示这一列不可编辑** —— 例如 code 那种稳定标识:
 * 改了它就等于换了一个东西,而不是修正了一个值。
 */
export type EditableColumn<T, D> = {
    /** 稳定的列键。 */
    key: string
    header: React.ReactNode
    /** ★ 手机上留在表里的列(只读身份列)。至少要有一列 —— 见下面那条按名拒绝。 */
    priority?: boolean
    align?: 'left' | 'right'
    /** 只读时这一格画什么。 */
    render: (row: T) => React.ReactNode
    /**
     * 编辑时这一格画什么。不给 = 这一列不可编辑。
     * `set` 收一个 patch,组件负责合进草稿 —— 页面不碰草稿的容器。
     */
    edit?: (draft: D, set: (patch: Partial<D>) => void) => React.ReactNode
    /** 手机展开区里的标签。不给就用 header。 */
    phoneLabel?: React.ReactNode
    className?: string
}

/** 保存的结果。**`{ error }` 表示失败 —— 失败时草稿【不清】。** */
export type SaveResult = { error?: string | null } | void

type Labels = {
    /** 「编辑」 */
    edit: string
    save: string
    saving: string
    cancel: string
    /** 「未保存」—— 画在有改动的那一行上。 */
    unsaved: string
    /** 手机展开钮的无障碍名字。 */
    expand: string
}

/**
 * ★ DRAFT-2 / Q6:`'page-owned'` 那一支只要得到这一个。
 * 另外五个在那一模式下【渲染不到】—— 理由写在本文件抬头的 Q6 那一段。
 */
type PageOwnedLabels = Pick<Labels, 'expand'>

type EditableTableCommon<T, D> = {
    rows: readonly T[]
    columns: ReadonlyArray<EditableColumn<T, D>>
    /**
     * 稳定的行键。★ DRAFT-1:**第二个参数是下标** —— 建单页那种
     * `Array.from({length: N})` 的空槽行,行与行的内容完全相同,
     * 光看 `row` 生不出一个互不相同的键(于是草稿会塌成一个)。
     */
    rowKey: (row: T, index: number) => string
    /** ★ 390px 上怎么办。**必填**,与 DataTable 同一个类型、同一条裁定。 */
    phone: PhoneTreatment
    /**
     * ★★【/me 逼出来的槽 —— 与 CONV-1 的 notices 同源】★★
     * `'all-rows'` 模式下,那一次提交【不属于这张表】:/me 的提交同时带着
     * 表格外面的一段自评正文,而且有两个不同的按钮(存草稿 / 定稿)。
     * 组件因此不能拥有那次保存,但它拥有草稿 —— 所以把草稿递出去,
     * 让页面在这里画自己的提交区。
     * **这是在四页上就被抓到的一处缺口,不是设计出来的。**
     */
    footer?: (drafts: Readonly<Record<string, D>>, anyDirty: boolean) => React.ReactNode
    /** 没有编辑权时传 false —— 整张表退回只读,不画任何编辑入口。 */
    canEdit?: boolean
    /**
     * 两份草稿算不算"不一样"。不给就按【浅比较】。
     * ★ Q5:脏是算出来的,组件里没有任何 dirty flag。
     */
    isDirty?: (draft: D, row: T) => boolean
    /* ★ DRAFT-2 / Q6:`labels` 不住在这里 —— 它住在下面那个判别式里,
       因为两种模式画得出来的标签【不是同一组】。 */
    caption?: React.ReactNode
    /** 空集不是失败,但它要说出自己是空的。 */
    empty?: React.ReactNode
    className?: string

    /**
     * ★★ DRAFT-1 · 能力 A —— **页面自己的行内动作,一个槽,不是三件功能** ★★
     * 画在动作列里,**挨着**组件自己的保存/取消/编辑,不是替掉它们。
     * ☞ 组件【不知道】这颗钮是什么意思:删一行、标记删除、复制一行,
     *   在这里都只是「页面画了点东西」。**业务规则一个字都不进来。**
     * ⚠ 勘察(DRAFT-0 §2.2)把「加行」也算进这一件,但逐张读下来
     *   **没有一张表是在表【内】加行的** —— 三张的加行表单都在表【下面】,
     *   而那正是 `footer` 已经能画的地方。所以这里没有 `onAddRow`。
     */
    rowActions?: (row: T, ctx: { editing: boolean; dirty: boolean; saving: boolean }) => React.ReactNode
    /**
     * ★ DRAFT-1 · 能力 B —— 按行涂色。与 `DataTable` 同一个签名(`data-table.tsx:306`)。
     * 消费者:`AttendanceGrid`(没录过的行 `bg-amber-50`)。
     */
    rowClassName?: (row: T) => string | undefined
    /**
     * ★★ DRAFT-1 · 能力 E —— **这一行现在能不能保存,以及【为什么不能】** ★★
     * 不给 = 只看脏不脏(旧行为)。给了 = `ok` 为假时保存钮按不动,
     * 并且 `why` 就画在钮旁边。
     * ☞ 它存在的理由是 CMP-2 的那条房规:**一个按不下去又不说为什么的钮,
     *   读起来就是坏的。** `GoalsEditor` 的「有数字就必须有单位」是第一个消费者
     *   (约束 `review_goals_unit_required` 的镜像)。
     */
    canSave?: (draft: D, row: T) => { ok: boolean; why?: React.ReactNode }

    // ── ★ Q4:排序与分页在这里【不存在】,而且是编译期不存在 ★ ──────────────
    /** 可编辑的表不排序 —— 见抬头 Q4。写上去编译不过。 */
    sorting?: never
    /** 可编辑的表不分页 —— 见抬头 Q4。写上去编译不过。 */
    pageSize?: never
}

/**
 * ★★★ DRAFT-1:三种模式,而第三种【必须被声明】,不许靠 `toDraft` 恒等推断出来 ★★★
 *
 *   前两种**组件自己持有草稿**,所以「脏」算得出来。
 *   第三种**页面自己持有那个数组**,组件一个草稿都不存 —— 于是「脏」它算不出来,
 *   必须由页面说。**那个 `dirty` 是必填的,不是可选的**:
 *   一个可选的 `dirty` 会让「这张表不需要未保存提醒」和「有人忘了传」
 *   在屏幕上长得一模一样,而 R7 要的正是这两者分得开。
 */
export type EditableTableProps<T, D> = EditableTableCommon<T, D> &
    (
        | {
              /**
               * `'one-row'`(默认)= 那个 Record 至多一个键。
               * `'all-rows'` = 每一行开局就带草稿,没有「编辑」钮。
               */
              mode?: 'one-row' | 'all-rows'
              /** 进入编辑时,把这一行拷成一份草稿。 */
              toDraft: (row: T) => D
              /**
               * 整行保存。**失败请返回 `{ error }`** —— 组件会把字留住、行留在编辑态。
               * ★ DRAFT-1 / Q3:`'all-rows'` 模式下**也可以给它** —— 那就是
               *   「整格都在编辑态,而每一行有自己的保存钮」,
               *   `AttendanceGrid` 与 `QuoteLinesEditor` 今天就是这个形状。
               */
              onSave?: (draft: D, row: T) => Promise<SaveResult>
              dirty?: never
              /** 前两种模式画得出全部六个。 */
              labels: Labels
          }
        | {
              /**
               * ★ `'page-owned'` —— **页面持有那个数组,这张表只负责画。**
               * 逼出它的是建单页那几张:它们的值要在表【外面】被读到
               * (`TemplateForm` 的 `hasFixed` 决定表上面那个币种字段要不要出现;
               *  `NewOrderForm` 的金额列由【另一张表】的合计算出来),
               * 而 `footer(drafts)` 只够到表【下面】。
               * ☞ 这一模式下 `edit(draft, set)` 的 `draft` **就是那一行本身**,
               *   `set` 是一条【按名拒绝】:页面必须走自己的 setter。
               */
              mode: 'page-owned'
              toDraft?: never
              onSave?: never
              /** ★ 必填:这张表现在有没有没保存的东西。它只喂 `beforeunload`。 */
              dirty: boolean
              /** ★ DRAFT-2 / Q6:这一支只要一个 `expand` —— 另外五个渲染不到。 */
              labels: PageOwnedLabels
          }
    )

/** 浅比较:草稿 vs 由当前这一行现算出来的草稿。 */
function shallowSame<D extends object>(a: D, b: D): boolean {
    const ka = Object.keys(a)
    const kb = Object.keys(b)
    if (ka.length !== kb.length) return false
    for (const k of ka) {
        if ((a as Record<string, unknown>)[k] !== (b as Record<string, unknown>)[k]) return false
    }
    return true
}

export function EditableTable<T, D extends object>(props: EditableTableProps<T, D>) {
    // COPY-1:空态那一句从前只有中文。
    const t = useTranslations()
    const {
        rows, columns, rowKey, phone,
        footer, canEdit = true, isDirty, caption, empty, className,
        rowActions, rowClassName, canSave,
    } = props

    // ★ DRAFT-2 / Q6:`'page-owned'` 只交一个 `expand` 上来。那五个在那一模式下
    //   【渲染不到】(见抬头 Q6),所以这里补的空串**进不了 DOM** —— 补它们是为了
    //   让下面的读取处只有一个形状,而不是让屏幕上多出五个空。
    const labels: Labels =
        props.mode === 'page-owned'
            ? { edit: '', save: '', saving: '', cancel: '', unsaved: '', ...props.labels }
            : props.labels

    // ★ DRAFT-1:模式是判别式,三种在这里分岔一次,下面全用分岔后的值。
    const pageOwned = props.mode === 'page-owned'
    const mode = props.mode ?? 'one-row'
    // `'page-owned'` 下草稿【就是那一行本身】—— 页面持有它,组件不拷贝。
    // ★ 恒等那一支要是稳定引用:它进 `rowIsDirty` 的依赖表,
    //   每渲染新造一个会让那个 useCallback 每次都变。
    const identityDraft = React.useCallback((r: T) => r as unknown as D, [])
    const toDraft: (row: T) => D =
        props.mode === 'page-owned' ? identityDraft : props.toDraft
    const onSave = props.mode === 'page-owned' ? undefined : props.onSave
    const pageDirty = props.mode === 'page-owned' ? props.dirty : false

    const phoneScroll = phone.mode === 'scroll'
    const isPhoneCol = (c: EditableColumn<T, D>) => phoneScroll || !!c.priority

    // ★ 与 DataTable 同一条按名拒绝(第三道网:运行期才拼出来的列,静态闸读不出)。
    const priorityCols = columns.filter((c) => c.priority)
    if (!phoneScroll && priorityCols.length === 0) {
        throw new Error(
            'EDITABLETABLE_NO_PHONE_COLUMNS:这张可编辑的表没有任何一列声明 priority。' +
            '手机上留下哪几列是【这张表自己的判断】,组件不替它猜。编辑本身发生在展开区里,' +
            '而留在表里的那几列是用来【认清在改哪一行】的 —— 一列都不留,展开区就没有主语。' +
            '给身份列加 priority: true,或显式声明 phone={{ mode: "scroll", why: "…" }}。'
        )
    }
    // ★ 又一条按名拒绝:一列都不可编辑的表不该用这个组件 —— 它是 DataTable。
    if (canEdit && !columns.some((c) => c.edit)) {
        throw new Error(
            'EDITABLETABLE_NO_EDITABLE_COLUMN:这张表没有任何一列给了 edit,也就是说它是只读的。' +
            '只读账簿请用 <DataTable> —— 两个组件是【刻意的】一对(见本文件抬头的 FORK DECISION),' +
            '拿可编辑的那个去画只读表,会让后来的人以为它们是重复的。'
        )
    }

    // ★★ Q3:两种模式【同一个状态形状】—— 一次一行就是它至多一个键。 ★★
    // ★ DRAFT-1:`'page-owned'` 不进这个容器 —— 它一个草稿都不存。
    const [drafts, setDrafts] = React.useState<Record<string, D>>(() =>
        mode === 'all-rows'
            ? Object.fromEntries(rows.map((r, i) => [rowKey(r, i), toDraft(r)]))
            : {}
    )
    const [savingKey, setSavingKey] = React.useState<string | null>(null)
    const [rowErrors, setRowErrors] = React.useState<Record<string, string>>({})
    const [open, setOpen] = React.useState<ReadonlySet<string>>(() => new Set())

    // all-rows:行的【集合】变了(增行/删行)才补草稿。
    // **不按值重置** —— 那会在保存之后把人正在打的字冲掉。
    const keySig = rows.map((r, i) => rowKey(r, i)).join(' ')
    React.useEffect(() => {
        if (mode !== 'all-rows') return
        setDrafts((prev) => {
            const next: Record<string, D> = {}
            let changed = false
            for (let i = 0; i < rows.length; i++) {
                const r = rows[i]
                const k = rowKey(r, i)
                if (k in prev) next[k] = prev[k]
                else { next[k] = toDraft(r); changed = true }
            }
            if (!changed && Object.keys(prev).length === Object.keys(next).length) return prev
            return next
        })
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [keySig, mode])

    // ★ Q5:脏 = 现算的比较,不是存下来的 flag。
    const rowIsDirty = React.useCallback((row: T, index: number): boolean => {
        const k = rowKey(row, index)
        const d = drafts[k]
        if (!d) return false
        return isDirty ? isDirty(d, row) : !shallowSame(d, toDraft(row))
    }, [drafts, isDirty, rowKey, toDraft])

    // ★ DRAFT-1:`'page-owned'` 算不出脏 —— 它【由页面说】,见那一支的 `dirty`。
    const anyDirty = pageOwned ? pageDirty : rows.some((r, i) => rowIsDirty(r, i))

    // ★ Q7:脏着关标签页 / 刷新 —— 浏览器自己的那个提示。**它的措辞我们拥有不了。**
    //   见抬头「记录在案的例外」。站内 <Link> 跳走【盖不住】,那是声明过的限制。
    React.useEffect(() => {
        if (!anyDirty) return
        const onBeforeUnload = (e: BeforeUnloadEvent) => { e.preventDefault(); e.returnValue = '' }
        window.addEventListener('beforeunload', onBeforeUnload)
        return () => window.removeEventListener('beforeunload', onBeforeUnload)
    }, [anyDirty])

    function begin(row: T, index: number) {
        const k = rowKey(row, index)
        setRowErrors((e) => { const n = { ...e }; delete n[k]; return n })
        // ★★ 这一行【就是】Q3 那条约束:整个 Record 被换成【只有一个键】。 ★★
        setDrafts({ [k]: toDraft(row) })
        // 手机上:一进编辑就把这一行展开 —— 编辑发生在展开区里(见抬头 ④)。
        setOpen(new Set([k]))
    }

    function cancel(row: T, index: number) {
        const k = rowKey(row, index)
        setRowErrors((e) => { const n = { ...e }; delete n[k]; return n })
        if (mode === 'all-rows') {
            // ★ DRAFT-1:整格模式下「取消」不是退出编辑态(没有编辑态可退)——
            //   它是【把这一行退回服务端的值】。删掉键,下面那个 effect 会照
            //   `toDraft(row)` 重新播一份。
            setDrafts((d) => { const n = { ...d }; n[k] = toDraft(row); return n })
            return
        }
        setDrafts((d) => { const n = { ...d }; delete n[k]; return n })
        setOpen((s) => { const n = new Set(s); n.delete(k); return n })
    }

    function patch(k: string, p: Partial<D>) {
        setDrafts((d) => (d[k] ? { ...d, [k]: { ...d[k], ...p } } : d))
    }

    /**
     * ★ 交给 `edit()` 的那个 `set`。`'page-owned'` 下它是一条【按名拒绝】——
     *   那一模式的约定是页面走自己的 setter,而一个默默什么都不做的 `set`
     *   会让「打的字没进去」看起来像组件坏了。
     */
    function setFor(k: string) {
        return (p: Partial<D>) => {
            if (pageOwned) {
                throw new Error(
                    'EDITABLETABLE_PAGE_OWNED_SET:这张表声明了 mode="page-owned",也就是说' +
                    '【那个数组由页面持有】,组件一个草稿都不存 —— 所以 edit() 收到的 set 无处可写。' +
                    '请在 edit() 里直接调页面自己的 setter(它本来就在闭包里),' +
                    '或者去掉 mode="page-owned" 改用 all-rows 让组件持有草稿。'
                )
            }
            patch(k, p)
        }
    }

    async function save(row: T, index: number) {
        if (!onSave) return
        const k = rowKey(row, index)
        const d = drafts[k]
        if (!d) return
        setSavingKey(k)
        setRowErrors((e) => { const n = { ...e }; delete n[k]; return n })
        try {
            const r = await onSave(d, row)
            if (r && r.error) {
                // ★★ Q6:失败 —— 字【留住】,行【留在编辑态】,页面【不刷新】。 ★★
                //    从服务端重画这一行,会把人正要去改的那些输入毁掉。
                setRowErrors((e) => ({ ...e, [k]: r.error as string }))
                return
            }
            // ★★ DRAFT-1 / Q3:整格模式下【草稿不收】★★
            //   收掉它会把这一行踢出编辑态,而整格模式里【每一行本来就该是编辑态】;
            //   而且那个按键集补种的 effect 只在【键集变了】时跑,键集没变,
            //   它补不回来 —— 于是那一行会变成一行读不了也改不了的空壳。
            //   留着草稿是对的:它此刻等于刚存进去的值,页面 refresh 回来之后
            //   `rowIsDirty` 自然变假,「未保存」那块牌子自己就灭了。
            if (mode !== 'all-rows') {
                // 成功才收草稿。router.refresh() 由页面自己的 onSave 在成功那一支里调。
                setDrafts((cur) => { const n = { ...cur }; delete n[k]; return n })
                setOpen((s) => { const n = new Set(s); n.delete(k); return n })
            }
        } finally {
            setSavingKey(null)
        }
    }

    const toggleRow = (k: string) =>
        setOpen((s) => { const n = new Set(s); n.has(k) ? n.delete(k) : n.add(k); return n })

    // ★★ DRAFT-1 / Q3:**`showActions` 不再问模式** ★★
    //   它从前写着 `mode === 'one-row'`,于是整格模式下整条动作列【根本不存在】。
    //   而 `AttendanceGrid` 与 `QuoteLinesEditor` 今天就是「整格都在编辑态 +
    //   每一行一颗保存钮」—— 那条 `mode ===` 把它们挡在门外。
    const showActions = canEdit && !!onSave
    // ★ 能力 A:页面自己的动作,与上面那一组【并存】,不是二选一。
    const showRowActions = canEdit && !!rowActions
    const showActionCol = showActions || showRowActions
    const editableCols = columns.filter((c) => c.edit)
    // 桌面上有动作列;手机上它不出现(动作在展开区末尾)。
    const colCount = columns.length + (showActionCol ? 1 : 0) + (phoneScroll ? 0 : 1)

    return (
        <div className={cn('w-full', className)}>
            <div className="w-full overflow-x-auto">
                <table
                    data-slot="editable-table"
                    // 与 DataTable 同一条:手机 table-fixed,桌面恢复 auto。
                    className="w-full caption-bottom border-collapse text-sm table-fixed sm:table-auto"
                >
                    {caption && <caption className="mt-2 text-sm text-[color:var(--brand-muted-text)]">{caption}</caption>}
                    <thead>
                        <tr className="border-b-2 border-[color:var(--brand-ocean)]">
                            {!phoneScroll && <th className={`w-8 px-1 font-medium sm:hidden ${TABLE_TEXT}`} />}
                            {columns.map((c) => (
                                <th
                                    key={c.key}
                                    scope="col"
                                    className={cn(
                                        'px-3 py-2.5 align-middle font-medium text-[color:var(--brand-text)]',
                                        'sm:whitespace-nowrap',
                                        c.align === 'right' ? 'text-right' : 'text-left',
                                        !isPhoneCol(c) && 'hidden sm:table-cell',
                                        c.className,
                                        // ★★ FONT-3(2026-09-12, Tim Q5/Q11/Q16):**这个组件此前一个字号
                                        //   token 都没有** —— 表头与表体都退成表根的 text-sm(14px),
                                        //   于是 /me · /hr/kpi/score · /hr/leave/types · /hr/reviews/scale
                                        //   四条路由整整比站上每一张表小一档。字号排在最后:调用点压不过它。
                                        TABLE_TEXT,
                                    )}
                                >
                                    {c.header}
                                </th>
                            ))}
                            {/* 动作列在手机上不存在 —— 它正是转换前三页溢出的直接原因。 */}
                            {showActionCol && <th scope="col" className={`hidden px-3 py-2.5 font-medium sm:table-cell ${TABLE_TEXT}`} />}
                        </tr>
                    </thead>
                    <tbody>
                        {rows.length === 0 && (
                            <tr>
                                <td colSpan={colCount} className={`px-3 py-8 text-center text-[color:var(--brand-muted-text)] ${TABLE_TEXT}`}>
                                    {empty ?? t('table.emptyPlain')}
                                </td>
                            </tr>
                        )}
                        {rows.map((row, index) => {
                            const k = rowKey(row, index)
                            // ★ `'page-owned'`:草稿【就是那一行】,而且每一行恒在编辑态。
                            const draft = pageOwned ? toDraft(row) : drafts[k]
                            const editing = !!draft && canEdit
                            const dirty = pageOwned ? false : rowIsDirty(row, index)
                            const isOpen = open.has(k)
                            const err = rowErrors[k]
                            const restCols = phoneScroll ? [] : columns.filter((c) => !c.priority)
                            // 手机展开区里画什么:编辑态是【全部可编辑字段】,
                            // 只读态是【其余各列】。
                            const phoneCols = editing ? editableCols : restCols
                            const hasPhonePanel = phoneCols.length > 0 || showActionCol
                            // ★ 能力 E:这一行能不能存,以及【为什么不能】。
                            const verdict = canSave && draft ? canSave(draft, row) : null
                            const blocked = !!verdict && !verdict.ok
                            const saveDisabled = savingKey === k || !dirty || blocked
                            const actions = showRowActions
                                ? rowActions!(row, { editing, dirty, saving: savingKey === k })
                                : null
                            return (
                                <React.Fragment key={k}>
                                    {/* ★ 能力 B:按行涂色。与 DataTable 同一个签名。 */}
                                    <tr className={cn('border-b border-[color:var(--brand-border)]', rowClassName?.(row))}>
                                        {!phoneScroll && (
                                            <td className={`px-1 align-middle sm:hidden ${TABLE_TEXT}`}>
                                                {hasPhonePanel && (
                                                    <button
                                                        type="button"
                                                        onClick={() => toggleRow(k)}
                                                        aria-expanded={isOpen}
                                                        aria-label={labels.expand}
                                                        className="base-pressable flex h-11 w-11 items-center justify-center rounded text-[color:var(--brand-muted-text)] hover:bg-[color:var(--brand-muted)]"
                                                    >
                                                        <span aria-hidden className={cn('transition-transform', isOpen && 'rotate-90')}>&#8250;</span>
                                                    </button>
                                                )}
                                            </td>
                                        )}
                                        {columns.map((c) => (
                                            <td
                                                key={c.key}
                                                className={cn(
                                                    'px-3 py-2.5 align-top text-[color:var(--brand-text)] break-words',
                                                    c.align === 'right' ? 'text-right tabular-nums' : 'text-left',
                                                    !isPhoneCol(c) && 'hidden sm:table-cell',
                                                    c.className,
                                                    // ★★ FONT-3:与表头同一条。
                                                    TABLE_TEXT,
                                                )}
                                            >
                                                {/* ★ ④:桌面在格子里编辑;手机上【格子永远是只读的】,
                                                    编辑在展开区。 */}
                                                {editing && c.edit ? (
                                                    <>
                                                        <span className="hidden sm:block">
                                                            {c.edit(draft, setFor(k))}
                                                        </span>
                                                        <span className="sm:hidden">{c.render(row)}</span>
                                                    </>
                                                ) : (
                                                    c.render(row)
                                                )}
                                                {/* 「未保存」只画在第一列;画在每一列是噪音。 */}
                                                {dirty && c.key === columns[0].key && (
                                                    <span className="ml-2 whitespace-nowrap rounded bg-amber-100 px-1.5 py-0.5 text-xs text-amber-900">
                                                        {labels.unsaved}
                                                    </span>
                                                )}
                                            </td>
                                        ))}
                                        {showActionCol && (
                                            <td className={`hidden whitespace-nowrap px-3 py-2.5 align-top sm:table-cell ${TABLE_TEXT}`}>
                                                {showActions && (editing ? (
                                                    <>
                                                        <button
                                                            type="button" onClick={() => void save(row, index)}
                                                            disabled={saveDisabled}
                                                            className="base-pressable mr-2 rounded px-1 hover:underline disabled:cursor-not-allowed disabled:text-[color:var(--brand-disabled-text)] disabled:no-underline app-link"
                                                        >
                                                            {savingKey === k ? labels.saving : labels.save}
                                                        </button>
                                                        <button
                                                            type="button" onClick={() => cancel(row, index)} disabled={savingKey === k}
                                                            className="base-pressable rounded px-1 text-[color:var(--brand-muted-text)] hover:underline"
                                                        >
                                                            {labels.cancel}
                                                        </button>
                                                    </>
                                                ) : (
                                                    <button
                                                        type="button" onClick={() => begin(row, index)}
                                                        className="base-pressable rounded px-1 hover:underline app-link"
                                                    >
                                                        {labels.edit}
                                                    </button>
                                                ))}
                                                {/* ★ 能力 A:页面自己的动作,挨着上面那一组。 */}
                                                {actions && <span className={showActions ? 'ml-2' : ''}>{actions}</span>}
                                                {/* ★ 能力 E:按不动就把理由摆在旁边(CMP-2)。 */}
                                                {blocked && verdict?.why && (
                                                    <p className="mt-1 whitespace-normal text-xs text-red-700">{verdict.why}</p>
                                                )}
                                            </td>
                                        )}
                                    </tr>

                                    {/* ★ Q8:错误落在【这一行】下面,带 role="alert"。 */}
                                    {err && (
                                        <tr className="sm:border-b sm:border-[color:var(--brand-border)]">
                                            <td colSpan={colCount} className="px-3 pb-2">
                                                <p role="alert" className="rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">
                                                    {err}
                                                </p>
                                            </td>
                                        </tr>
                                    )}

                                    {/* ── 手机展开区 ────────────────────────────────────────
                                        只读态:其余各列,带标签(与 DataTable 同形)。
                                        编辑态:★【每一个可编辑字段】整宽、带标签 —— 见抬头 ④。 */}
                                    {isOpen && hasPhonePanel && (
                                        <tr className="border-b border-[color:var(--brand-border)] sm:hidden">
                                            <td
                                                colSpan={columns.filter((c) => c.priority).length + 1}
                                                className="bg-[color:var(--brand-muted)] px-3 py-2"
                                            >
                                                {phoneCols.length > 0 && (
                                                    <dl className="base-reveal grid grid-cols-[minmax(6rem,auto)_1fr] gap-x-3 gap-y-1.5 text-sm">
                                                        {phoneCols.map((c) => (
                                                            <React.Fragment key={c.key}>
                                                                <dt className="text-[color:var(--brand-muted-text)]">{c.phoneLabel ?? c.header}</dt>
                                                                <dd className="text-[color:var(--brand-text)]">
                                                                    {editing && c.edit ? c.edit(draft, setFor(k)) : c.render(row)}
                                                                </dd>
                                                            </React.Fragment>
                                                        ))}
                                                    </dl>
                                                )}
                                                {showActions && editing && (
                                                    <div className="mt-3 flex flex-wrap gap-2">
                                                        <button
                                                            type="button" onClick={() => void save(row, index)}
                                                            disabled={saveDisabled}
                                                            className="base-pressable min-h-11 rounded bg-blue-600 px-3 py-1.5 text-sm text-white disabled:cursor-not-allowed disabled:bg-[color:var(--brand-disabled-bg)] disabled:text-[color:var(--brand-disabled-text)]"
                                                        >
                                                            {savingKey === k ? labels.saving : labels.save}
                                                        </button>
                                                        <button
                                                            type="button" onClick={() => cancel(row, index)} disabled={savingKey === k}
                                                            className="base-pressable min-h-11 rounded border border-[color:var(--brand-border)] px-3 py-1.5 text-sm"
                                                        >
                                                            {labels.cancel}
                                                        </button>
                                                    </div>
                                                )}
                                                {/* ★ 能力 E:手机上同样把理由摆出来 —— 桌面有、手机没有,
                                                    就是让 390px 上那颗钮变回「按不动又不说为什么」。 */}
                                                {blocked && verdict?.why && (
                                                    <p className="mt-2 text-xs text-red-700">{verdict.why}</p>
                                                )}
                                                {/* ★ 能力 A:页面自己的动作,画在展开区末尾 ——
                                                    与组件自己那一组同一处,理由见抬头 ④。 */}
                                                {actions && <div className="mt-3 flex flex-wrap gap-2">{actions}</div>}
                                                {/* ★★ BTN-FOLLOWUP(2026-09-20)· Tim 的裁定:这一颗取【触控档】★★
                                                    BTN-TRIGGER-1 §6.2 把它停住了,理由是**档位表里没有 44px**:
                                                    今天这颗的 44 是 `min-h-11` 给的,不是内容给的(内容只有 34px),
                                                    而档位是 24 / 28 / 32 / 36 / 48。三条路都改行高。

                                                    ★ Tim 裁的是 `touch`(48px),而他裁的理由不是"48 最接近 44" ——
                                                    是 **32 与 36 都会把它掉到 44px 触控靶以下**(WCAG 2.5.5 / Apple HIG),
                                                    而**宁可让它长高,也不要让它掉到一条标准以下**。

                                                    ⚠ **代价是量过的、并且是被告知之后接受的,不是被忽略的:**
                                                    `touch` 档同时带着 `text-base` —— 所以这颗钮 **44 → 48px(+4)**,
                                                    **字号 14 → 16px**。那不是这一刀顺手加的:`button.tsx` 抬头写明
                                                    「E6 的裁定原话把三样绑在一起……把字号留在调用点,等于让这一档只搬了裁定的一半」。

                                                    ★★ **在册的量具看不见这一格** —— 它住在 `{isOpen && hasPhonePanel && …}` 里,
                                                    点开才渲染,而 `survey-controls --mode=drift` 只量首屏。
                                                    ☞ 所以本刀另写了一支探针,在 390px 上真的把行点开再量;读数逐条写在
                                                    `docs/handbacks/BTN-FOLLOWUP.md` §2。**一个绿的 (c) 不覆盖这一格。** */}
                                                {showActions && !editing && (
                                                    <div className="mt-3">
                                                        <Button
                                                            type="button" variant="secondary" size="touch"
                                                            onClick={() => begin(row, index)}
                                                        >
                                                            {labels.edit}
                                                        </Button>
                                                    </div>
                                                )}
                                            </td>
                                        </tr>
                                    )}
                                </React.Fragment>
                            )
                        })}
                    </tbody>
                </table>
            </div>

            {/* ★ /me 逼出来的槽 —— 提交不属于这张表时,页面在这里画它自己的。 */}
            {footer && footer(drafts, anyDirty)}
        </div>
    )
}
