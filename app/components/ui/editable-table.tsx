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
// ════════════════════════════════════════════════════════════════════════════

import { useTranslations } from '@/lib/i18n/client'
import * as React from 'react'
import { cn } from '@/lib/utils'
import type { PhoneTreatment } from '@/app/components/ui/data-table'

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

export type EditableTableProps<T, D> = {
    rows: readonly T[]
    columns: ReadonlyArray<EditableColumn<T, D>>
    rowKey: (row: T) => string
    /** ★ 390px 上怎么办。**必填**,与 DataTable 同一个类型、同一条裁定。 */
    phone: PhoneTreatment
    /** 进入编辑时,把这一行拷成一份草稿。 */
    toDraft: (row: T) => D
    /**
     * ★ Q3:`'one-row'`(默认)= 那个 Record 至多一个键。
     *   `'all-rows'` = 每一行开局就带草稿,没有「编辑」钮 —— 给
     *   /me 那种【长得像表格的表单】用,不是给账簿用。
     */
    mode?: 'one-row' | 'all-rows'
    /**
     * 整行保存。**失败请返回 `{ error }`** —— 组件会把字留住、行留在编辑态。
     * `'all-rows'` 模式下不给它,由 `footer` 里页面自己的提交负责。
     */
    onSave?: (draft: D, row: T) => Promise<SaveResult>
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
    labels: Labels
    caption?: React.ReactNode
    /** 空集不是失败,但它要说出自己是空的。 */
    empty?: React.ReactNode
    className?: string

    // ── ★ Q4:排序与分页在这里【不存在】,而且是编译期不存在 ★ ──────────────
    /** 可编辑的表不排序 —— 见抬头 Q4。写上去编译不过。 */
    sorting?: never
    /** 可编辑的表不分页 —— 见抬头 Q4。写上去编译不过。 */
    pageSize?: never
}

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
        rows, columns, rowKey, phone, toDraft, mode = 'one-row',
        onSave, footer, canEdit = true, isDirty, labels, caption, empty, className,
    } = props

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
    const [drafts, setDrafts] = React.useState<Record<string, D>>(() =>
        mode === 'all-rows'
            ? Object.fromEntries(rows.map((r) => [rowKey(r), toDraft(r)]))
            : {}
    )
    const [savingKey, setSavingKey] = React.useState<string | null>(null)
    const [rowErrors, setRowErrors] = React.useState<Record<string, string>>({})
    const [open, setOpen] = React.useState<ReadonlySet<string>>(() => new Set())

    // all-rows:行的【集合】变了(增行/删行)才补草稿。
    // **不按值重置** —— 那会在保存之后把人正在打的字冲掉。
    const keySig = rows.map(rowKey).join(' ')
    React.useEffect(() => {
        if (mode !== 'all-rows') return
        setDrafts((prev) => {
            const next: Record<string, D> = {}
            let changed = false
            for (const r of rows) {
                const k = rowKey(r)
                if (k in prev) next[k] = prev[k]
                else { next[k] = toDraft(r); changed = true }
            }
            if (!changed && Object.keys(prev).length === Object.keys(next).length) return prev
            return next
        })
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [keySig, mode])

    // ★ Q5:脏 = 现算的比较,不是存下来的 flag。
    const rowIsDirty = React.useCallback((row: T): boolean => {
        const k = rowKey(row)
        const d = drafts[k]
        if (!d) return false
        return isDirty ? isDirty(d, row) : !shallowSame(d, toDraft(row))
    }, [drafts, isDirty, rowKey, toDraft])

    const anyDirty = rows.some(rowIsDirty)

    // ★ Q7:脏着关标签页 / 刷新 —— 浏览器自己的那个提示。**它的措辞我们拥有不了。**
    //   见抬头「记录在案的例外」。站内 <Link> 跳走【盖不住】,那是声明过的限制。
    React.useEffect(() => {
        if (!anyDirty) return
        const onBeforeUnload = (e: BeforeUnloadEvent) => { e.preventDefault(); e.returnValue = '' }
        window.addEventListener('beforeunload', onBeforeUnload)
        return () => window.removeEventListener('beforeunload', onBeforeUnload)
    }, [anyDirty])

    function begin(row: T) {
        const k = rowKey(row)
        setRowErrors((e) => { const n = { ...e }; delete n[k]; return n })
        // ★★ 这一行【就是】Q3 那条约束:整个 Record 被换成【只有一个键】。 ★★
        setDrafts({ [k]: toDraft(row) })
        // 手机上:一进编辑就把这一行展开 —— 编辑发生在展开区里(见抬头 ④)。
        setOpen(new Set([k]))
    }

    function cancel(row: T) {
        const k = rowKey(row)
        setDrafts((d) => { const n = { ...d }; delete n[k]; return n })
        setRowErrors((e) => { const n = { ...e }; delete n[k]; return n })
        setOpen((s) => { const n = new Set(s); n.delete(k); return n })
    }

    function patch(k: string, p: Partial<D>) {
        setDrafts((d) => (d[k] ? { ...d, [k]: { ...d[k], ...p } } : d))
    }

    async function save(row: T) {
        if (!onSave) return
        const k = rowKey(row)
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
            // 成功才收草稿。router.refresh() 由页面自己的 onSave 在成功那一支里调。
            setDrafts((cur) => { const n = { ...cur }; delete n[k]; return n })
            setOpen((s) => { const n = new Set(s); n.delete(k); return n })
        } finally {
            setSavingKey(null)
        }
    }

    const toggleRow = (k: string) =>
        setOpen((s) => { const n = new Set(s); n.has(k) ? n.delete(k) : n.add(k); return n })

    const showActions = canEdit && mode === 'one-row' && !!onSave
    const editableCols = columns.filter((c) => c.edit)
    // 桌面上有动作列;手机上它不出现(动作在展开区末尾)。
    const colCount = columns.length + (showActions ? 1 : 0) + (phoneScroll ? 0 : 1)

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
                            {!phoneScroll && <th className="w-8 px-1 sm:hidden" />}
                            {columns.map((c) => (
                                <th
                                    key={c.key}
                                    scope="col"
                                    className={cn(
                                        'px-3 py-2.5 align-middle font-medium text-[color:var(--brand-text)]',
                                        'sm:whitespace-nowrap',
                                        c.align === 'right' ? 'text-right' : 'text-left',
                                        !isPhoneCol(c) && 'hidden sm:table-cell',
                                        c.className
                                    )}
                                >
                                    {c.header}
                                </th>
                            ))}
                            {/* 动作列在手机上不存在 —— 它正是转换前三页溢出的直接原因。 */}
                            {showActions && <th scope="col" className="hidden px-3 py-2.5 sm:table-cell" />}
                        </tr>
                    </thead>
                    <tbody>
                        {rows.length === 0 && (
                            <tr>
                                <td colSpan={colCount} className="px-3 py-8 text-center text-[color:var(--brand-muted-text)]">
                                    {empty ?? t('table.emptyPlain')}
                                </td>
                            </tr>
                        )}
                        {rows.map((row) => {
                            const k = rowKey(row)
                            const draft = drafts[k]
                            const editing = !!draft && canEdit
                            const dirty = rowIsDirty(row)
                            const isOpen = open.has(k)
                            const err = rowErrors[k]
                            const restCols = phoneScroll ? [] : columns.filter((c) => !c.priority)
                            // 手机展开区里画什么:编辑态是【全部可编辑字段】,
                            // 只读态是【其余各列】。
                            const phoneCols = editing ? editableCols : restCols
                            const hasPhonePanel = phoneCols.length > 0 || showActions
                            return (
                                <React.Fragment key={k}>
                                    <tr className="border-b border-[color:var(--brand-border)]">
                                        {!phoneScroll && (
                                            <td className="px-1 align-middle sm:hidden">
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
                                                    c.className
                                                )}
                                            >
                                                {/* ★ ④:桌面在格子里编辑;手机上【格子永远是只读的】,
                                                    编辑在展开区。 */}
                                                {editing && c.edit ? (
                                                    <>
                                                        <span className="hidden sm:block">
                                                            {c.edit(draft, (p) => patch(k, p))}
                                                        </span>
                                                        <span className="sm:hidden">{c.render(row)}</span>
                                                    </>
                                                ) : (
                                                    c.render(row)
                                                )}
                                                {/* 「未保存」只画在第一列;画在每一列是噪音。 */}
                                                {dirty && c.key === columns[0].key && (
                                                    <span className="ml-2 whitespace-nowrap rounded bg-amber-100 px-1.5 py-0.5 text-[10px] text-amber-900">
                                                        {labels.unsaved}
                                                    </span>
                                                )}
                                            </td>
                                        ))}
                                        {showActions && (
                                            <td className="hidden whitespace-nowrap px-3 py-2.5 align-top sm:table-cell">
                                                {editing ? (
                                                    <>
                                                        <button
                                                            type="button" onClick={() => void save(row)}
                                                            disabled={savingKey === k || !dirty}
                                                            className="base-pressable mr-2 rounded px-1 text-blue-600 hover:underline disabled:cursor-not-allowed disabled:text-[color:var(--brand-disabled-text)] disabled:no-underline"
                                                        >
                                                            {savingKey === k ? labels.saving : labels.save}
                                                        </button>
                                                        <button
                                                            type="button" onClick={() => cancel(row)} disabled={savingKey === k}
                                                            className="base-pressable rounded px-1 text-[color:var(--brand-muted-text)] hover:underline"
                                                        >
                                                            {labels.cancel}
                                                        </button>
                                                    </>
                                                ) : (
                                                    <button
                                                        type="button" onClick={() => begin(row)}
                                                        className="base-pressable rounded px-1 text-blue-600 hover:underline"
                                                    >
                                                        {labels.edit}
                                                    </button>
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
                                                                    {editing && c.edit ? c.edit(draft, (p) => patch(k, p)) : c.render(row)}
                                                                </dd>
                                                            </React.Fragment>
                                                        ))}
                                                    </dl>
                                                )}
                                                {showActions && editing && (
                                                    <div className="mt-3 flex flex-wrap gap-2">
                                                        <button
                                                            type="button" onClick={() => void save(row)}
                                                            disabled={savingKey === k || !dirty}
                                                            className="base-pressable min-h-11 rounded bg-blue-600 px-3 py-1.5 text-sm text-white disabled:cursor-not-allowed disabled:bg-[color:var(--brand-disabled-bg)] disabled:text-[color:var(--brand-disabled-text)]"
                                                        >
                                                            {savingKey === k ? labels.saving : labels.save}
                                                        </button>
                                                        <button
                                                            type="button" onClick={() => cancel(row)} disabled={savingKey === k}
                                                            className="base-pressable min-h-11 rounded border border-[color:var(--brand-border)] px-3 py-1.5 text-sm"
                                                        >
                                                            {labels.cancel}
                                                        </button>
                                                    </div>
                                                )}
                                                {showActions && !editing && (
                                                    <div className="mt-3">
                                                        <button
                                                            type="button" onClick={() => begin(row)}
                                                            className="base-pressable min-h-11 rounded border border-[color:var(--brand-border)] px-3 py-1.5 text-sm text-blue-600"
                                                        >
                                                            {labels.edit}
                                                        </button>
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
