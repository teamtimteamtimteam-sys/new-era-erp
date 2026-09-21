'use client'

// 付款条款模板表单(新建/编辑共用):名称/说明/启用 + 动态期次表。
// 每行:期次标签、模式单选(比例 | 定额)+ 对应输入、触发事件;fixed_date 另出
// 偏移天数(模板不可能知道具体日期,存"下单日 + N 天",套用时换算)。
// 比例合计实时显示:<100 只提示(余下部分不列入计划是合法的 —— 尾款常常"按化验实算"),
// >100 拦下不让交。行序即期次,提交时按行序重排 seq。
import { CONTROL_CHECKBOX, CONTROL_INPUT, CONTROL_RADIO, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useActionState, useRef, useState } from 'react'
import Link from 'next/link'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { triggerLabel, type PaymentTriggerEvent } from '@/lib/paymentTriggers'
import DecimalInput from '@/app/components/forms/DecimalInput'
import { saveTemplate, type TemplateFormState, type TemplateLineInput } from './actions'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { EditableTable, type EditableColumn } from '@/app/components/ui/editable-table'

const initialState: TemplateFormState = {}

// EQP-PAY-1:那个硬编码的数组退役了 —— 里程碑的真源是 payment_trigger_events。
//
// ★【模板【不】按种类过滤,这是刻意的】★ 一份模板【不属于任何一张采购单】
// (它的抬头就是这么写的:"存在的唯一理由是省去重复录入"),所以它没有种类可言。
// 判据落在【套用的那一刻】:apply_payment_term_template 往
// purchase_order_payment_terms 里插行,而那张表上的 guard_payment_term_applicable
// 会按目标单据的种类按名拒。把一个用不上的组合拦在套用处,而不是拦在模板处,
// 是因为同一份模板可能对材料单成立、对设备单不成立 —— 那不是模板的错。

export function emptyTermLine(): TemplateLineInput {
    return { label: '', mode: 'percentage', percentage: '', fixed_amount: '', trigger_event: 'on_order', days_offset: '' }
}

/**
 * ★★ DRAFT-3 / G4:行键【不用下标,用一个只活在渲染这一侧的 uid】★★
 *
 * `EditableTable` 的展开态是按 `rowKey` 存的(`editable-table.tsx:443`)。
 * 用下标做键时,`removeLine` 会让它后面每一行都在【同一个键底下】换一个内容 ——
 * **一行展开着,显示的却是另一行**(DRAFT-2 的 G4)。数组由页面持有,所以
 * **数据是安全的**;这是一处观感问题,而它靠一个稳定的键【构造上】就消失了。
 *
 * ★★★【uid 不进 `lines_json`】★★★ 交出去的载荷与搬家前【逐字节相同】,
 * 服务端(`parseLines`)因此**一个字都不用改**。剥在桥那一处,只剥一次。
 * ★ 用【单调计数器】而不是 `crypto.randomUUID()`:计数器在服务端渲染与客户端
 *   水合两侧给出同一串值,随机数不会。
 * ⚠ **`#6` / `#7` 不需要它,别去"统一"** —— 那两张是定长空槽(5 / 3),
 *   既不加行也不删行,下标从头到尾不动。**这里的 uid 是为【删行】付的账。**
 */
/**
 * ★★ uid 放在那一行【旁边】,不放进它里面 —— 于是交出去的那个对象
 * **从头到尾没有被碰过**,载荷逐字节相同这件事是【构造上】成立的,
 * 不是靠一次"记得把它剥掉"。☞ 桥那一处写的是 `x.line`,没有任何剥离动作。
 */
type TermLine = { uid: string; line: TemplateLineInput }
/** 画在表里的那一行 = 那一行的内容 + 它的 uid + 它的期次序号。★ 两者都不进载荷。 */
type TermRow = TemplateLineInput & { uid: string; i: number }

export default function TemplateForm({
    template,
    currencies,
    triggerEvents,
canEdit
}: {
    template?: {
        id: string
        name: string
        description: string | null
        is_active: boolean
        currency: string | null
        lines: TemplateLineInput[]
    }
    currencies: { code: string }[]
    // EQP-PAY-1:整份字典(模板不按种类过滤 —— 理由见文件顶部)。
    triggerEvents: PaymentTriggerEvent[]

canEdit: boolean
}) {
    const t = useTranslations()
    const locale = useLocale()
    const [state, formAction, isPending] = useActionState(saveTemplate, initialState)

    /* ★ DRAFT-3 / G4:uid 的来源。计数器,不是随机数 —— 理由见上面那段。
       ⚠ 开局那几行的 uid 由【下标】直接给,不走这个计数器:`react-hooks/refs`
       按名拒「渲染期读 ref」,而 `useState` 的初始化器跑在渲染里。
       于是计数器的初值也从 props 算,而它只在事件处理器里被推进。 */
    const initialLines = (): TermLine[] =>
        (template?.lines.length ? template.lines : [emptyTermLine()])
            .map((l, i) => ({ uid: `l${i}`, line: l }))
    const uidSeq = useRef(template?.lines.length || 1)
    const nextUid = () => `l${uidSeq.current++}`
    const [lines, setLines] = useState<TermLine[]>(initialLines)
    const [currency, setCurrency] = useState<string>(template?.currency ?? '')

    // FIN-29:定额腿才需要币种。没有定额腿时整个字段收起来 —— 摆一个用不上的
    // 必填框,人只会随便选一个,而随便选的字段迟早被当真。
    // ★★ DRAFT-3:**这个派生值管着两件东西,不是一件** —— 下面那个币种字段
    //   【存不存在】,以及它不存在时那个补位的隐藏输入。搬家动不了它:数组
    //   仍然由这一页持有,所以它读的还是同一个 `lines`。
    const hasFixed = lines.some((x) => x.line.mode === 'fixed')

    // ★★ DRAFT-3:交出去的那一份【逐字节】还是搬家前那一份 —— uid 在这里剥掉。
    const linesJson = JSON.stringify(lines.map((x) => x.line))
    /**
     * ★ `mode:'page-owned'` 的必填 `dirty`(组件抬头 Q5:脏是【算】出来的)。
     * ☞ 判据是【与进来时那一份比】,不是「有没有字」—— 这张表单同时服务
     *   `/new` 与 `/[id]/edit`,而一张编辑页开局就有字。按"有字"算,
     *   编辑一份既有模板会【一进门就是脏的】,于是那个提醒立刻变成噪音。
     * ⚠【它盖不住的两半,照直说】① 站内 <Link>(下面那颗「取消」)不拦 ——
     *   组件抬头声明过的限制,而对一颗取消钮那也正是对的:**明说要走的人
     *   不该被再问一遍**;② 抬头那几个字段(名称 / 说明 / 启用)**不在这张表里**,
     *   只改它们不会有提醒。**这张表的 `dirty` 只说这张表的事。**
     */
    const [initialJson] = useState(() => JSON.stringify(initialLines().map((x) => x.line)))
    const linesDirty = linesJson !== initialJson

    function patchLine(uid: string, patch: Partial<TemplateLineInput>) {
        setLines((ls) => ls.map((x) => (x.uid === uid ? { uid: x.uid, line: { ...x.line, ...patch } } : x)))
    }
    function removeLine(uid: string) {
        setLines((ls) => (ls.length > 1 ? ls.filter((x) => x.uid !== uid) : ls))
    }

    const pctTotal = Math.round(
        lines.reduce((s, { line: l }) => {
            if (l.mode !== 'percentage') return s
            const n = Number(l.percentage)
            return s + (l.percentage && !Number.isNaN(n) ? n : 0)
        }, 0) * 100
    ) / 100
    const pctOver = pctTotal > 100

    /* ★★ DRAFT-3:那块 `TABLE-PHONE-3` 注释【拆掉了,而它记的事没有丢】★★
       它记的是「手机档被拿掉的那一列(删除)原样叠在序号那一格里 —— 拿掉的是
       那一列,不是那个事实」。组件的**展开区**就是那一份叠加块的正规写法,
       所以这是**换一个写法,不是丢掉那个事实**。逐字的理由搬进了
       `docs/handbacks/DRAFT-3.md`,不许成孤儿。
       ⚠ **代价照直记:** 删除钮从【零次点按】变成【一次点按】(先展开那一行)。 */

    const rows: TermRow[] = lines.map((x, i) => ({ ...x.line, uid: x.uid, i }))

    const shareText = (l: TemplateLineInput) =>
        l.mode === 'percentage'
            ? (l.percentage.trim() === '' ? '—' : `${l.percentage}%`)
            : (l.fixed_amount.trim() === '' ? '—' : l.fixed_amount)
    const triggerText = (l: TemplateLineInput) => {
        const ev = triggerEvents.find((e) => e.code === l.trigger_event)
        const base = ev ? triggerLabel(ev, locale) : l.trigger_event
        return l.trigger_event === 'fixed_date' && l.days_offset.trim() !== ''
            ? `${base} + ${l.days_offset}`
            : base
    }

    /* ★ 闸的要求:`columns` 必须是【同一个文件里定位得到的标识符】——
       写成内联数组字面量时 `check-editable-name.mjs` 记一条 `unresolved`
       **并且照旧退出 0**(`:187` / `:244`),那张表就悄悄没人守了。 */
    const lineColumns: EditableColumn<TermRow, TermRow>[] = [
        {
            key: 'seq',
            header: t('purchasing.colSeq'),
            priority: true,
            className: 'w-10',
            render: (r) => <span className="text-[color:var(--brand-muted-text)]">{r.i + 1}</span>,
        },
        {
            key: 'label',
            header: t('purchasing.colLabel'),
            priority: true,
            render: (r) => (r.label.trim() === '' ? '—' : r.label),
            edit: (r) => (
                <input
                    type="text"
                    value={r.label}
                    aria-label={t('purchasing.colLabel')}
                    onChange={(e) => patchLine(r.uid, { label: e.target.value })}
                    className={`${CONTROL_INPUT} w-full`}
                />
            ),
        },
        {
            key: 'share',
            header: t('purchasing.colShare'),
            render: (r) => shareText(r),
            edit: (r) => (
                <div className="flex flex-wrap items-center gap-2">
                    <label className="flex items-center gap-1">
                        <input
                            className={CONTROL_RADIO}
                            type="radio"
                            checked={r.mode === 'percentage'}
                            onChange={() => patchLine(r.uid, { mode: 'percentage' })}
                        />
                        {t('purchasing.form.modePct')}
                    </label>
                    <label className="flex items-center gap-1">
                        <input
                            className={CONTROL_RADIO}
                            type="radio"
                            checked={r.mode === 'fixed'}
                            onChange={() => patchLine(r.uid, { mode: 'fixed' })}
                        />
                        {t('purchasing.form.modeFixed')}
                    </label>
                    {r.mode === 'percentage' ? (
                        <DecimalInput
                            value={r.percentage}
                            onChange={(v) => patchLine(r.uid, { percentage: v })}
                            placeholder={t('purchasing.form.percentage')}
                            className="w-24"
                        />
                    ) : (
                        <DecimalInput
                            value={r.fixed_amount}
                            onChange={(v) => patchLine(r.uid, { fixed_amount: v })}
                            placeholder={t('purchasing.form.fixedAmount')}
                            className="w-28"
                        />
                    )}
                </div>
            ),
        },
        {
            key: 'trigger',
            header: t('purchasing.colTrigger'),
            render: (r) => triggerText(r),
            edit: (r) => (
                <>
                    <select
                        value={r.trigger_event}
                        aria-label={t('purchasing.colTrigger')}
                        onChange={(e) => patchLine(r.uid, { trigger_event: e.target.value })}
                        className={CONTROL_SELECT}
                    >
                        {triggerEvents.map((ev) => (
                            <option key={ev.code} value={ev.code}>
                                {triggerLabel(ev, locale)}
                            </option>
                        ))}
                    </select>
                    {r.trigger_event === 'fixed_date' && (
                        <span className="ml-2 inline-flex items-center gap-1">
                            <DecimalInput
                                value={r.days_offset}
                                onChange={(v) => patchLine(r.uid, { days_offset: v })}
                                className="w-16"
                            />
                            <span className="text-xs text-[color:var(--brand-muted-text)]">{t('purchasing.daysOffsetHint')}</span>
                        </span>
                    )}
                </>
            ),
        },
    ]

    return (
        <PermissionGate code="module.purchasing.edit" allowed={canEdit}>
        <form action={formAction} className="space-y-4 max-w-3xl">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}

            {template && <input type="hidden" name="template_id" value={template.id} />}
            <input type="hidden" name="lines_json" value={linesJson} />

            <div className="flex flex-wrap gap-4">
                <div className="flex-1 min-w-[16rem]">
                    <label className="block mb-1">
                        {t('purchasing.colName')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="name"
                        required
                        defaultValue={template?.name ?? ''}
                        className={`${CONTROL_INPUT} w-full`}
                    />
                </div>
                <div className="flex-1 min-w-[16rem]">
                    <label className="block mb-1">{t('purchasing.colDescription')}</label>
                    <input
                        type="text"
                        name="description"
                        defaultValue={template?.description ?? ''}
                        className={`${CONTROL_INPUT} w-full`}
                    />
                </div>
                <label className="flex items-end gap-2 pb-2">
                    <input
                        className={CONTROL_CHECKBOX}
                        type="checkbox"
                        name="is_active"
                        defaultChecked={template?.is_active ?? true}
                    />
                    {t('pricing.form.active')}
                </label>
            </div>

            {/* FIN-29:定额腿的币种。模板不属于任何单据,所以定额在被套到某张 PO 上
                之前没有币种可言 —— 声明它,套用时币种不同即拒(不换算:付款条款是
                谈定的承诺,不是算出来的量)。只有比例的模板不需要,字段就不出现。 */}
            {hasFixed && (
                <div className="max-w-xs">
                    <label className="block mb-1">
                        {t('purchasing.form.templateCurrency')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="currency"
                        value={currency}
                        onChange={(e) => setCurrency(e.target.value)}
                        required
                        className={`${CONTROL_SELECT} w-full`}
                    >
                        <option value="">—</option>
                        {currencies.map((c) => (
                            <option key={c.code} value={c.code}>{c.code}</option>
                        ))}
                    </select>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('purchasing.form.templateCurrencyHint')}</p>
                </div>
            )}
            {!hasFixed && <input type="hidden" name="currency" value="" />}

            <h2 className="pt-2">{t('purchasing.form.paymentTerms')}</h2>
            <EditableTable<TermRow, TermRow>
                rows={rows}
                columns={lineColumns}
                rowKey={(r) => r.uid}
                phone={{ mode: 'columns' }}
                mode="page-owned"
                dirty={linesDirty}
                rowActions={(r) => (
                    <Button
                        variant="secondary"
                        size="inline"
                        type="button"
                        onClick={() => removeLine(r.uid)}
                        disabled={lines.length === 1}
                        className="text-sm"
                    >
                        {t('purchasing.form.removeLine')}
                    </Button>
                )}
                labels={{ expand: t('common.expandRow') }}
            />
            <div className="flex items-center justify-between">
                <Button
                    variant="link"
                    size="inline"
                    type="button"
                    onClick={() => setLines((ls) => [...ls, { uid: nextUid(), line: emptyTermLine() }])}
                >
                    {t('purchasing.form.addTerm')}
                </Button>
                {/* 比例合计:>100 拦下;<100 只是提醒(尾款按实算是常态) */}
                {pctOver ? (
                    <p className="text-sm text-red-600">
                        {t('purchasing.errors.TERMS_PCT_EXCEEDS', { 0: pctTotal })}
                    </p>
                ) : pctTotal > 0 && pctTotal < 100 ? (
                    <p className="text-sm text-amber-700">{t('purchasing.pctUnder', { total: pctTotal })}</p>
                ) : pctTotal === 100 ? (
                    <p className="text-sm text-[color:var(--brand-muted-text)]">100%</p>
                ) : null}
            </div>

            <div className="flex gap-3 pt-2">
                <Button
                    type="submit"
                    disabled={isPending || pctOver}
                >
                    {isPending ? t('common.saving') : t('common.save')}
                </Button>
                <Button asChild variant="secondary">
                    <Link
                        href="/purchasing/payment-terms"
                    >
                        {t('common.cancel')}
                    </Link>
                </Button>
            </div>
        </form>
        </PermissionGate>
    )
}
