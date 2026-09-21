'use client'

// WO-1c:新建工单的表单。
//
// 【三处 why-line,而它们都是这一族反复付过学费的那几条】
//   * 排产日【可空、且不给默认值】—— 它与加工日/开票日不是同一种日期:那些决定
//     汇率与期间(FIN-10),这一个决定不了钱。但同样不默认:一个补出来的今天会把
//     "谁也没排过期"伪装成"排在今天"。空就是"没排"。
//   * 预期产出【整段可以不填】—— 没有行 = 没人估过,不是估了零。表单因此
//     【不预置任何一行】:预置一行等于替人做了一个"这里应该有个数"的判断,
//     而这个库里今天没有任何东西能推出那个数(没有 BOM、投料侧化验来源全空)。
//   * 计划按【物料】写,不按批次 —— 排计划的时候批次往往还不存在。
import { CONTROL_INPUT, CONTROL_SELECT, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { createWorkOrder } from '../actions'
import { Button } from '@/app/components/ui/button'
import { EditableTable, type EditableColumn } from '@/app/components/ui/editable-table'

type Material = { id: string; code: string; name: string }
const LINE_SLOTS = 5
const EXPECTED_SLOTS = 3

/**
 * ★ 画在表里的那一行 = 那个槽的内容 + 它的槽号。
 *
 * 【为什么把下标烧进行里】`EditableTable` 的 `render(row)` / `edit(draft, set)`
 * **都收不到下标**,而 `'page-owned'` 下 `set` 是一条按名拒绝 —— 页面必须走自己的
 * setter,所以这一格非知道「我是第几槽」不可。靠 `indexOf` 捞回来是一条**看不见的、
 * 一次 `map` 就会断掉的**依赖;烧进行里是一条看得见的(与 `#24` 逐字同源)。
 *
 * ★★【这两张表【不需要】uid,而这不是疏忽】★★
 * `#8` / `#9` 各带一个 uid,是为了**删行 / 整个数组换掉**那一刻展开态不会
 * 落到另一行上(DRAFT-2 的 G4)。**这两张是定长空槽(5 / 3):既不加行,
 * 也不删行,也没有任何东西会整片换掉它们** —— 下标从头到尾指着同一个槽,
 * 所以它**就是**一个稳定的键。☞ 给它们补一个 uid 不会让任何东西更对,
 * 只会多一份要维护的状态。**别去"统一"。**
 */
type LineRow = { material_id: string; planned_qty: string; i: number }
type ExpectedRow = {
    material_id: string; expected_qty: string; basis: string; basis_reference: string; i: number
}

export default function NewWorkOrderForm({ materials }: { materials: Material[] }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [scheduled, setScheduled] = useState('')
    const [lines, setLines] = useState(
        Array.from({ length: LINE_SLOTS }, () => ({ material_id: '', planned_qty: '' })))
    // PROC-SUPPORT-1(R3):每一行预期产出都要说出它的【出处】。
    // 【没有预选值 —— 抄 metal_prices.source 那条"没有默认值"】一个预选的
    // planner_estimate 会让"没人想过这个问题"看起来像"有人回答过了",
    // 而这一栏存在的全部理由就是六个月后分得出这两者。
    const [expected, setExpected] = useState(
        Array.from({ length: EXPECTED_SLOTS },
            () => ({ material_id: '', expected_qty: '', basis: '', basis_reference: '' })))
    const [notes, setNotes] = useState('')

    const filledLines = lines.filter((l) => l.material_id && l.planned_qty.trim() !== '')
    // 【禁用条件与服务端的 WO_NO_LINES 是同一件事】—— 服务端仍然独立拒空,
    // 界面这一道不是保护(AGENTS.md 的两道闸)。
    // ★★ DRAFT-3:**这是一处【表外面读表里的数组】** —— 与 `#8` 的比例合计、
    //   `#9` 的 `hasFixed` 同一族。数组仍然由这一页持有,所以搬家动不了它。
    const blocked = filledLines.length === 0

    function patchLine(i: number, patch: Partial<{ material_id: string; planned_qty: string }>) {
        setLines((ls) => ls.map((x, j) => (j === i ? { ...x, ...patch } : x)))
    }
    function patchExpected(i: number, patch: Partial<Omit<ExpectedRow, 'i'>>) {
        setExpected((es) => es.map((x, j) => (j === i ? { ...x, ...patch } : x)))
    }

    /**
     * ★★★ 两张表,**两个 `dirty`,谁都不替谁说话**(Tim 的 Q5)★★★
     *
     * 组件是**每个实例各自**挂一个 `beforeunload`,而且各自由自己那个 `dirty`
     * 把着(`editable-table.tsx:474` 与 `:479-483`)。**浏览器无论有几个监听器
     * 调了 `preventDefault`,只弹一个框** —— 所以这两个值【不需要】合并:
     * 合并反而会让其中一张表声称另一张表的状态。
     *
     * ⚠【它盖不住的两半,照直说】
     *   ① 站内 <Link>(下面那颗「取消」)不拦 —— 组件抬头声明过的限制,
     *      而对一颗取消钮那也正是对的:**明说要走的人不该被再问一遍**;
     *   ② **排产日与备注不在任何一张表里**,只改它们不会有提醒。
     *      ☞ 这仍然**严格好于搬家前** —— 这一页此前**一个提醒都没有**,
     *        也没有 IDLE-DRAFT(它连 `<form>` 元素都没有),关掉标签页静悄悄丢光。
     */
    const linesDirty = lines.some((l) => l.material_id !== '' || l.planned_qty.trim() !== '')
    const expectedDirty = expected.some(
        (e) => e.material_id !== '' || e.expected_qty.trim() !== ''
            || e.basis !== '' || e.basis_reference.trim() !== '')

    const lineRows: LineRow[] = lines.map((l, i) => ({ ...l, i }))
    const expectedRows: ExpectedRow[] = expected.map((e, i) => ({ ...e, i }))

    const materialLabel = (id: string) => {
        const m = materials.find((x) => x.id === id)
        return m ? `${m.code} — ${m.name}` : ''
    }
    /* ★★ Tim 的 Q4:这两处的空【有意思】,所以只读投影里写的是那句话本身,
       **不是一个 `—`**。理由就在本文件 PROC-SUPPORT-1 那段注释里:一个空格子
       读起来像「这一栏不重要」,而这一栏正是六个月后唯一能回答「这个数可不可信」
       的东西。☞ `#24` 用 `—` 是对的(那是一个没挑的物料);**这里照抄它就是错的。** */
    const basisText = (v: string) =>
        v === 'planner_estimate' ? t('processing.wo.basis.planner_estimate')
            : v === 'seeded_industry' ? t('processing.wo.basis.seeded_industry')
                : v === 'calibrated' ? t('processing.wo.basis.calibrated')
                    : t('processing.wo.basis.unstated')

    /* ★ 闸的要求:`columns` 必须是【同一个文件里定位得到的标识符】,而这个文件里
       有**两张**表 —— 所以是两个**互不相同**的名字。写成内联数组字面量时
       `check-editable-name.mjs` 记一条 `unresolved` **并且照旧退出 0**。 */
    const lineColumns: EditableColumn<LineRow, LineRow>[] = [
        {
            key: 'seq',
            header: t('processing.colSeq'),
            priority: true,
            className: 'w-10',
            render: (r) => <span className="text-[color:var(--brand-muted-text)]">{r.i + 1}</span>,
        },
        {
            key: 'material',
            header: t('processing.wo.colMaterial'),
            priority: true,
            // ★ 这一格的空【没有】特别含义:它就是一个没用上的槽,所以是 `—`。
            render: (r) => (r.material_id === '' ? '—' : materialLabel(r.material_id)),
            edit: (r) => (
                <select value={r.material_id} aria-label={t('processing.wo.colMaterial')}
                        className={`${CONTROL_SELECT} w-full`}
                        onChange={(e) => patchLine(r.i, { material_id: e.target.value })}>
                    <option value="">{t('processing.wo.form.selectMaterial')}</option>
                    {materials.map((m) => (
                        <option key={m.id} value={m.id}>{m.code} — {m.name}</option>
                    ))}
                </select>
            ),
        },
        {
            key: 'planned',
            header: t('processing.wo.colPlanned'),
            align: 'right',
            render: (r) => (r.planned_qty.trim() === '' ? '—' : r.planned_qty),
            edit: (r) => (
                <input type="number" step="any" min="0" value={r.planned_qty}
                       aria-label={t('processing.wo.colPlanned')}
                       className={`${CONTROL_INPUT} w-32 text-right tabular-nums`}
                       onChange={(e) => patchLine(r.i, { planned_qty: e.target.value })} />
            ),
        },
    ]

    const expectedColumns: EditableColumn<ExpectedRow, ExpectedRow>[] = [
        {
            key: 'seq',
            header: t('processing.colSeq'),
            priority: true,
            className: 'w-10',
            render: (r) => <span className="text-[color:var(--brand-muted-text)]">{r.i + 1}</span>,
        },
        {
            key: 'material',
            header: t('processing.wo.colMaterial'),
            priority: true,
            // ★ Q4:空 = 「没有预期」,那是一句话,不是一个空格。
            render: (r) => (r.material_id === ''
                ? t('processing.wo.form.noExpectation')
                : materialLabel(r.material_id)),
            edit: (r) => (
                <select value={r.material_id} aria-label={t('processing.wo.colMaterial')}
                        className={`${CONTROL_SELECT} w-full`}
                        onChange={(ev) => patchExpected(r.i, { material_id: ev.target.value })}>
                    <option value="">{t('processing.wo.form.noExpectation')}</option>
                    {materials.map((m) => (
                        <option key={m.id} value={m.id}>{m.code} — {m.name}</option>
                    ))}
                </select>
            ),
        },
        {
            key: 'expected',
            header: t('processing.wo.colExpected'),
            align: 'right',
            render: (r) => (r.expected_qty.trim() === '' ? '—' : r.expected_qty),
            edit: (r) => (
                <input type="number" step="any" min="0" value={r.expected_qty}
                       aria-label={t('processing.wo.colExpected')}
                       className={`${CONTROL_INPUT} w-32 text-right tabular-nums`}
                       onChange={(ev) => patchExpected(r.i, { expected_qty: ev.target.value })} />
            ),
        },
        {
            key: 'basis',
            header: t('processing.wo.colBasis'),
            // ★ Q4:空 = 「还没有人说过」,那是这一栏存在的全部理由。
            render: (r) => basisText(r.basis),
            edit: (r) => (
                <select value={r.basis} aria-label={t('processing.wo.colBasis')}
                        className={`${CONTROL_SELECT} w-full`}
                        onChange={(ev) => patchExpected(r.i, { basis: ev.target.value })}>
                    <option value="">{t('processing.wo.basis.unstated')}</option>
                    <option value="planner_estimate">{t('processing.wo.basis.planner_estimate')}</option>
                    <option value="seeded_industry">{t('processing.wo.basis.seeded_industry')}</option>
                    <option value="calibrated">{t('processing.wo.basis.calibrated')}</option>
                </select>
            ),
        },
        {
            key: 'basisRef',
            header: t('processing.wo.colBasisReference'),
            // ★ 这一格是自由文本的补充说明,它的空【没有】特别含义 —— `—` 是对的。
            render: (r) => (r.basis_reference.trim() === '' ? '—' : r.basis_reference),
            edit: (r) => (
                <input type="text" value={r.basis_reference}
                       aria-label={t('processing.wo.colBasisReference')}
                       placeholder={t('processing.wo.basisReferencePlaceholder')}
                       className={`${CONTROL_INPUT} w-full`}
                       onChange={(ev) => patchExpected(r.i, { basis_reference: ev.target.value })} />
            ),
        },
    ]

    function submit() {
        setError('')
        startTransition(async () => {
            const res = await createWorkOrder({
                lines: filledLines.map((l) => ({
                    material_id: l.material_id, planned_qty: Number(l.planned_qty),
                })),
                expected: expected
                    .filter((e) => e.material_id && e.expected_qty.trim() !== '')
                    .map((e) => ({
                        material_id: e.material_id,
                        expected_qty: Number(e.expected_qty),
                        // 空串原样送上去 —— 服务端按名拒 WO_EXPECTED_BASIS_REQUIRED。
                        // 【不在这里拦】与 process_date / allocation_basis 同一条:
                        // 界面是第一道,函数是权威的那一道。
                        basis: e.basis,
                        basis_reference: e.basis_reference.trim(),
                    })),
                scheduled_date: scheduled.trim() === '' ? null : scheduled,
                notes: notes.trim() === '' ? null : notes,
            })
            if (res?.error) setError(res.error)
        })
    }

    return (
        <div className="p-8 max-w-3xl">
            <div className="mb-6">
                <Link href="/operation/orders" className="hover:underline text-sm app-link">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="mb-6">{t('processing.wo.newTitle')}</h1>

            {error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {error}
                </div>
            )}

            <div className="space-y-5">
                <div>
                    <label className="block mb-1">{t('processing.wo.form.scheduled')}</label>
                    <input type="date" value={scheduled} onChange={(e) => setScheduled(e.target.value)}
                           className={CONTROL_INPUT} />
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('processing.wo.form.scheduledWhy')}</p>
                </div>

                <div>
                    <h2 className="mb-1">{t('processing.wo.form.lines')}</h2>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('processing.wo.form.linesWhy')}</p>
                    <EditableTable<LineRow, LineRow>
                        rows={lineRows}
                        columns={lineColumns}
                        rowKey={(r) => String(r.i)}
                        phone={{ mode: 'columns' }}
                        mode="page-owned"
                        dirty={linesDirty}
                        labels={{ expand: t('common.expandRow') }}
                    />
                </div>

                <div>
                    <h2 className="mb-1">{t('processing.wo.form.expected')}</h2>
                    {/* 【这一段留空是一个正当答案 —— 说出来,而不是让人猜】 */}
                    <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('processing.wo.form.expectedWhy')}</p>
                    {/* PROC-SUPPORT-1(R3):播种的猜测与校准过的数字必须在【屏幕上】分得开,
                        不只是在数据里分得开 —— 六个月后打开这一页的人读的是屏幕。 */}
                    <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('processing.wo.form.basisWhy')}</p>
                    <EditableTable<ExpectedRow, ExpectedRow>
                        rows={expectedRows}
                        columns={expectedColumns}
                        rowKey={(r) => String(r.i)}
                        phone={{ mode: 'columns' }}
                        mode="page-owned"
                        dirty={expectedDirty}
                        labels={{ expand: t('common.expandRow') }}
                    />
                </div>

                <div>
                    <label className="block mb-1">{t('processing.wo.form.notes')}</label>
                    <textarea value={notes} onChange={(e) => setNotes(e.target.value)}
                              className={`${CONTROL_TEXTAREA} w-full`} />
                </div>

                <p className="text-xs text-[color:var(--brand-muted-text)]">{t('processing.wo.form.savesAsDraft')}</p>
                <div className="flex gap-3">
                    <Button type="button" onClick={submit} disabled={isPending || blocked}>
                        {isPending ? t('common.saving') : t('processing.wo.form.save')}
                    </Button>
                    <Button asChild variant="secondary">
                        <Link href="/operation/orders">
                            {t('common.cancel')}
                        </Link>
                    </Button>
                </div>
                {blocked && <p className="text-xs text-amber-700">{t('processing.wo.form.blockedNoLines')}</p>}
            </div>
        </div>
    )
}
