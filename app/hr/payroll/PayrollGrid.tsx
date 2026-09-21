'use client'

// 薪资录入表格:一名在职员工一行,从【上一期】的数字预填 —— 逐月录入本该是
// "核对"而不是"重敲"。预填的数字上方有明确提示:那是上月的,必须对着服务商的
// 报表逐行核。
//
// 每行实时校验 net =? gross − 员工CPF − 其它扣款:对了给绿勾,错了标红并显示差额,
// 且只要有一行不平就禁用提交 —— DB 的 LINE_NOT_BALANCED 是后墙,不是第一道防线。
// 整行留空的员工不提交(当月没发薪的人不该以 0 混进工资单)。
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useActionState, useState } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatAmount } from '@/lib/format'
import DecimalInput, { parseDecimal } from '@/app/components/forms/DecimalInput'
import { savePayrollPeriod, type PayrollFormState, type PayrollLineInput } from './actions'
import { Button } from '@/app/components/ui/button'
import { EditableTable, type EditableColumn } from '@/app/components/ui/editable-table'
import type { FooterRow } from '@/app/components/ui/data-table'

const initialState: PayrollFormState = {}

export type EmployeeRow = { id: string; code: string; legal_name: string }

const round2 = (n: number) => Math.round(n * 100) / 100

/**
 * ★ DRAFT-6:那五个钱数的键,**一份定义**。
 * 此前它只是 `isBlank` 里的一个内联数组;本刀的 `dirty` 判据要问同一组键
 * (「与进门时那一份比」),而**两份清单会在写下的那天一致、此后各自漂移** ——
 * 漂开之后的样子是:一张改过的表不提醒未保存,或者一张没改过的表一直在提醒。
 */
const MONEY_KEYS = ['gross_pay', 'employee_cpf', 'employer_cpf', 'other_deductions', 'net_pay'] as const

function blankLine(employeeId: string): PayrollLineInput {
    return {
        employee_id: employeeId,
        gross_pay: '',
        employee_cpf: '',
        employer_cpf: '',
        other_deductions: '',
        net_pay: '',
    }
}

export default function PayrollGrid({
    employees,
    prefill,
    defaults,
    monthLocked = false,
    hasPrefill,
}: {
    employees: EmployeeRow[]
    // 上一期的数字(employee_id → 各列字符串);没有上一期时为空
    prefill: Record<string, Partial<PayrollLineInput>>
    // 抬头默认值(全部用字符串:空串 = 让用户填,不会预填出 0 这种非法汇率)
    defaults: {
        period_month: string // 'YYYY-MM'
        payment_date: string
        currency: string
        fx_rate: string
        source_note: string
        notes: string
    }
    // 编辑既有期间时月份不可改 —— 换月份等于换一张单,应该另建
    monthLocked?: boolean
    hasPrefill: boolean
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(savePayrollPeriod, initialState)

    // 币种受控:预期实发与合计行都要【带着币种】显示,而这张单的币种就是抬头这个
    // 下拉里选的那个 —— 不是本位币,也不是任何常量。下拉一改,下面的数字跟着改口径,
    // 所以它必须是 state,不能停在 defaultValue 上。
    const [currency, setCurrency] = useState(defaults.currency)

    const buildLines = () => {
        const out: Record<string, PayrollLineInput> = {}
        for (const e of employees) {
            const p = prefill[e.id] ?? {}
            out[e.id] = { ...blankLine(e.id), ...p, employee_id: e.id }
        }
        return out
    }

    const [lines, setLines] = useState<Record<string, PayrollLineInput>>(buildLines)
    /* ★★ DRAFT-6 · `EditableTable` 的 `page-owned` 要一个【必填】的 `dirty`,
       而这张表的判据是「**与进门时那一份比**」,不是「有没有字」——
       ☞ 理由是这一页【进门时格子里就有字】:`prefill` 预填的是**上一期**的数字
         (见本文件抬头那段「逐月录入本该是核对而不是重敲」)。
         按「有没有字」算,一张什么都没改的表会**一进门就是脏的**,
         而一个恒亮的「未保存」提醒等于没有提醒。
       ☞ 与 `#9 TemplateForm` 的判据同源(DRAFT-3 §3.1:同时服务 /new 与 /[id]/edit
         的表单必须与进门那一份比),而这里连 `/[id]/edit` 都不必提 —— 预填本身
         就够让「有没有字」失效。
       ★ 快照只取一次(lazy initializer),与 `lines` 用**同一个构造函数** ——
         两份各写一遍会在 `prefill` 的形状变化时悄悄分开。 */
    const [initialLines] = useState<Record<string, PayrollLineInput>>(buildLines)

    function patch(empId: string, key: keyof PayrollLineInput, value: string) {
        setLines((ls) => ({ ...ls, [empId]: { ...ls[empId], [key]: value } }))
    }

    const isBlank = (l: PayrollLineInput) =>
        MONEY_KEYS.every((k) => ((l as unknown as Record<string, string>)[k] ?? '').trim() === '')

    // 每行的自洽校验:留空行不参与
    const rowCheck = (l: PayrollLineInput) => {
        if (isBlank(l)) return { skip: true, ok: true, delta: 0, expected: 0 }
        const gross = parseDecimal(l.gross_pay) ?? 0
        const eeCpf = parseDecimal(l.employee_cpf) ?? 0
        const other = parseDecimal(l.other_deductions) ?? 0
        const net = parseDecimal(l.net_pay) ?? 0
        const expected = round2(gross - eeCpf - other)
        return { skip: false, ok: expected === round2(net), delta: round2(net - expected), expected }
    }

    const active = employees.map((e) => lines[e.id]).filter((l) => !isBlank(l))
    const anyBad = active.some((l) => !rowCheck(l).ok)
    const totals = active.reduce(
        (acc, l) => ({
            gross: round2(acc.gross + (parseDecimal(l.gross_pay) ?? 0)),
            eeCpf: round2(acc.eeCpf + (parseDecimal(l.employee_cpf) ?? 0)),
            erCpf: round2(acc.erCpf + (parseDecimal(l.employer_cpf) ?? 0)),
            other: round2(acc.other + (parseDecimal(l.other_deductions) ?? 0)),
            net: round2(acc.net + (parseDecimal(l.net_pay) ?? 0)),
        }),
        { gross: 0, eeCpf: 0, erCpf: 0, other: 0, net: 0 }
    )

    const cell = 'w-24 text-right'

    /* ★ 见 `initialLines` 那一段:与进门时那一份逐键比。
       ⚠ 照直记一条组件抬头声明过的限制:**站内 `<Link>`(取消钮)不拦** ——
         `beforeunload` 只管关标签页与刷新。 */
    const linesDirty = employees.some((e) => {
        const cur = lines[e.id] as unknown as Record<string, string>
        const was = initialLines[e.id] as unknown as Record<string, string>
        if (!cur || !was) return false
        return MONEY_KEYS.some((k) => (cur[k] ?? '') !== (was[k] ?? ''))
    })

    /* ════════════════════════════════════════════════════════════════════════
       ★★★【`#3` 的列 —— 而这一张的难处全在【核对】那一列上】★★★

       `page-owned` 下 `editing` 恒为真,展开区只画**有 `edit` 的列**
       (`editable-table.tsx` 的 `phoneCols`)—— 一个**只读且非 priority** 的列
       在 390px 上**整个消失**(DRAFT-3 §0 的 G1;`#8` 的金额列为它付过一次账)。
       ☞ 而这张表的【核对】列正是这一种,**且它是这一页存在的理由**:
         本文件抬头写着「每行实时校验 net =? gross − 员工CPF − 其它扣款」。
         让它消失,就等于在手机上把这张表变回一张单纯的录入表。

       ★★ **裁定(Tim 的 Q7,DRAFT-6):不把它 priority 掉,而是【叠进员工那一格】** ——
         照 `TABLE-PHONE-4` 今天已经在做的那样,与 `#22` 的三列只读的数同一条。
         理由有两层:
         ① 四个 priority 列正是这次搬家要治的那种溢出(`known-issues.md:7497`:
            「390px 上横拖 414px 才看得到最后一列,而那时**身份列早已离场**」);
         ② 它本来就是**words**(`hr.expectedNet`),叠加块装得下,不必现造文案。

       ★ **而叠加块只在【有话可说】时才画**:整行留空的员工没有可核对的东西,
         画一个「核对:—」是把一格噪音发给每一个这个月没发薪的人。

       ★★★ **身份列 priority,而这正是 R12 那笔欠账要还的东西:**
         那条在册的读数说的不是「要横拖 414px」,是**「而那时打字的人屏幕上
         没有任何东西说这一行是谁」**。身份列留在明面上,那句话就不再成立。
       ════════════════════════════════════════════════════════════════════════ */
    const employeeColumns: EditableColumn<EmployeeRow, EmployeeRow>[] = [
        {
            key: 'employee',
            header: t('hr.colEmployee'),
            priority: true,
            render: (e) => {
                const check = rowCheck(lines[e.id])
                return (
                    <>
                        <span className="text-xs text-gray-500 mr-2">{e.code}</span>
                        {e.legal_name}
                        {/* ★★ TABLE-PHONE-4 的叠加块:手机档拿掉的【核对】列叠在这里,
                            **零次点按**。⚠ 它【不能】改走展开区:`page-owned` 下
                            展开区只画有 `edit` 的列,而核对是只读的 —— 走过去等于
                            让这一页最要紧的那个判断整个消失。 */}
                        {!check.skip && (
                            <div className="sm:hidden mt-1 font-sans text-xs text-gray-600">
                                <span className="text-gray-500">{t('hr.colCheck')}: </span>
                                {check.ok ? (
                                    <span className="text-green-700">✓</span>
                                ) : (
                                    <span className="text-red-700">
                                        {t('hr.expectedNet', { amount: formatAmount(check.expected, currency) })}
                                    </span>
                                )}
                            </div>
                        )}
                    </>
                )
            },
        },
        /* ★ 五个钱数。`render` 画的是**草稿的投影**(不是库里的值)——
           `page-owned` 下桌面格画 `edit`、手机行画 `render`,而这五列不是 priority,
           所以 `render` 今天只在 `canEdit=false` 那一支才看得见。
           ⚠ 照直记:**这张表没有 `canEdit`**,于是这五个 `render` 在屏幕上
             一次都渲染不到。它们仍然是必填的(列描述符的契约),
             而写成「投影草稿」而不是写死一句话,是为了它哪天真的被画出来时
             说的是真话 —— 与 `#10` 的金额列同一条(DRAFT-1 §3.2)。 */
        {
            key: 'gross',
            header: t('hr.colGross'),
            align: 'right',
            render: (e) => lines[e.id]?.gross_pay ?? '',
            edit: (e) => (
                <DecimalInput
                    value={lines[e.id]?.gross_pay ?? ''}
                    onChange={(v) => patch(e.id, 'gross_pay', v)}
                    className={cell}
                />
            ),
        },
        {
            key: 'eeCpf',
            header: t('hr.colEmployeeCpf'),
            align: 'right',
            render: (e) => lines[e.id]?.employee_cpf ?? '',
            edit: (e) => (
                <DecimalInput
                    value={lines[e.id]?.employee_cpf ?? ''}
                    onChange={(v) => patch(e.id, 'employee_cpf', v)}
                    className={cell}
                />
            ),
        },
        {
            key: 'erCpf',
            header: t('hr.colEmployerCpf'),
            align: 'right',
            render: (e) => lines[e.id]?.employer_cpf ?? '',
            edit: (e) => (
                <DecimalInput
                    value={lines[e.id]?.employer_cpf ?? ''}
                    onChange={(v) => patch(e.id, 'employer_cpf', v)}
                    className={cell}
                />
            ),
        },
        {
            key: 'other',
            header: t('hr.colDeductions'),
            align: 'right',
            render: (e) => lines[e.id]?.other_deductions ?? '',
            edit: (e) => (
                <DecimalInput
                    value={lines[e.id]?.other_deductions ?? ''}
                    onChange={(v) => patch(e.id, 'other_deductions', v)}
                    className={cell}
                />
            ),
        },
        {
            key: 'net',
            header: t('hr.colNet'),
            align: 'right',
            render: (e) => lines[e.id]?.net_pay ?? '',
            edit: (e) => (
                <DecimalInput
                    value={lines[e.id]?.net_pay ?? ''}
                    onChange={(v) => patch(e.id, 'net_pay', v)}
                    className={cell}
                />
            ),
        },
        {
            /* ★ 核对:桌面一列,手机叠进身份格(见上面那段)。
               ⚠ **留空行那个 `—` 逐字保留** —— 它说的是「这一行没有东西可核对」,
                 而本刀没有裁过它,也没有碰过它。 */
            key: 'check',
            header: t('hr.colCheck'),
            className: 'text-xs',
            render: (e) => {
                const check = rowCheck(lines[e.id])
                return check.skip ? (
                    <span className="text-gray-300">—</span>
                ) : check.ok ? (
                    <span className="text-green-700">✓</span>
                ) : (
                    <span className="text-red-700">
                        {t('hr.expectedNet', { amount: formatAmount(check.expected, currency) })}
                    </span>
                )
            },
        },
    ]

    /* ★★ 能力 C(DRAFT-6):搬家前那一行 `<tfoot>` 逐格搬过来。
       ★ **两个断点的 `colSpan` 从此由组件数,调用方一个数字都不写** ——
         搬家前那一行写死了 7 格(标签 1 + 五个合计 + 一个空的核对格),
         而 390px 上只画两格,于是那五个合计**在手机上整行消失**。
       ☞ 组件把它们叠进手机档的标签格里(`trial-balance:234` 手写的答案)。
       ★ 底色与字重 `bg-gray-100 font-bold` **与搬家前逐字相同** ——
         variant C 对表尾没有标准(`table-style.ts` 抬头),所以它由调用方写。 */
    const totalsRows: FooterRow[] = [
        {
            key: 'totals',
            className: 'bg-gray-100 font-bold',
            label: (
                <>
                    {t('finance.totalsLabel')}
                    <span className="ml-2 font-normal text-gray-500">
                        {t('hr.lineCount', { n: active.length })}
                    </span>
                </>
            ),
            cells: {
                gross: formatAmount(totals.gross, currency),
                eeCpf: formatAmount(totals.eeCpf, currency),
                erCpf: formatAmount(totals.erCpf, currency),
                other: formatAmount(totals.other, currency),
                net: formatAmount(totals.net, currency),
            },
        },
    ]

    return (
        <form action={formAction} className="space-y-4">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}

            <input type="hidden" name="lines_json" value={JSON.stringify(Object.values(lines))} />

            {/* 期间抬头 */}
            <div className="flex flex-wrap gap-4">
                <div>
                    <label className="block mb-1">
                        {t('hr.colPeriod')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="month"
                        name="period_month"
                        required
                        defaultValue={defaults.period_month}
                        readOnly={monthLocked}
                        /* ★★ POLISH-1(2026-09-12,Tim 的裁定 R10 · S3)· 这一行【留着】★★
                           它是全系统**唯一**一个带「只读」底色的控件:`control-style.ts`
                           有 `disabled:` 那一支,**没有 `read-only:` 那一支**
                           (实测:`read-only:` 在整个 `app/` 里只出现这一次)。
                           ☞ 剥掉它,一个**只读**的月份框就和一个**可编辑**的框长得一模一样 ——
                             而这两件事对操作员的含义完全不同。
                           ☞ Tim 2026-09-11(INPUT-3 Q9)裁【留】,POLISH-1 的 R10 又确认了一次。
                           ⚠ **不要把它"顺手统一"进 `control-style.ts`**:那等于替 Tim 裁一条
                             他没有裁的规矩(「这套系统的控件状态有哪几种」),
                             而那条规矩今天还不存在 —— 见 `docs/known-issues.md` 的
                             `POLISH1-CONTROL-STATE-VOCAB`。 */
                        className={`${CONTROL_INPUT} read-only:bg-gray-100`}
                    />
                </div>
                <div>
                    <label className="block mb-1">
                        {t('hr.colPaymentDate')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="date"
                        name="payment_date"
                        required
                        defaultValue={defaults.payment_date}
                        className={CONTROL_INPUT}
                    />
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('hr.paymentDateHint')}</p>
                </div>
                <div>
                    <label className="block mb-1">{t('hr.colCurrency')}</label>
                    <select
                        name="currency"
                        value={currency}
                        onChange={(e) => setCurrency(e.target.value)}
                        className={CONTROL_SELECT}
                    >
                        <option value="SGD">SGD</option>
                        <option value="USD">USD</option>
                    </select>
                </div>
                <div>
                    <label className="block mb-1">
                        {t('hr.colFxRate')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="fx_rate"
                        required
                        inputMode="decimal"
                        defaultValue={defaults.fx_rate}
                        className={`${CONTROL_INPUT} w-28`}
                    />
                </div>
                <div className="flex-1 min-w-[14rem]">
                    <label className="block mb-1">{t('hr.colSourceNote')}</label>
                    <input
                        type="text"
                        name="source_note"
                        defaultValue={defaults.source_note}
                        placeholder={t('hr.sourceNoteHint')}
                        className={`${CONTROL_INPUT} w-full`}
                    />
                </div>
                <div className="flex-1 min-w-[12rem]">
                    <label className="block mb-1">{t('hr.colNotes')}</label>
                    <input
                        type="text"
                        name="notes"
                        defaultValue={defaults.notes}
                        className={`${CONTROL_INPUT} w-full`}
                    />
                </div>
            </div>

            {hasPrefill && (
                <p className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-2 rounded text-sm">
                    {t('hr.prefillNote')}
                </p>
            )}

            {/* ★★ 明细表 —— DRAFT-6:搬上 `<EditableTable>`(`page-owned`)。
                ☞ 桥【不在这里】:`lines_json` 那个隐藏输入画在表**外面**、只画一遍
                  (本文件上面那一行),而格子里一个 `name=` 都没有 ——
                  这正是 `EDITABLETABLE-NAME-DOUBLE-SUBMIT` 的 (b) 裁定要的形状。
                  ⚠ 这张表**搬家前就已经坐在那座桥上**,所以本刀在提交这一侧
                    一个字节都没有改:`Object.values(lines)` 逐字照旧。 */}
            <EditableTable<EmployeeRow, EmployeeRow>
                rows={employees}
                columns={employeeColumns}
                rowKey={(e) => e.id}
                phone={{ mode: 'columns' }}
                mode="page-owned"
                dirty={linesDirty}
                labels={{ expand: t('common.expandRow') }}
                empty={t('hr.employeesEmpty')}
                /* ★ 能力 B:不平的行涂红 —— 与搬家前那个 `bg-red-50` 逐字相同。 */
                rowClassName={(e) => (!rowCheck(lines[e.id]).ok ? 'bg-red-50' : undefined)}
                /* ★★ 能力 C:表尾合计行。见 `totalsRows` 那一段。 */
                totals={totalsRows}
            />

            {anyBad && (
                <p className="text-sm text-red-600">{t('hr.gridHasErrors')}</p>
            )}

            <div className="flex gap-3 pt-2">
                <Button
                    type="submit"
                    disabled={isPending || anyBad || active.length === 0}
                >
                    {isPending ? t('common.saving') : t('common.save')}
                </Button>
                <Button asChild variant="secondary">
                    <Link href="/hr/payroll">
                        {t('common.cancel')}
                    </Link>
                </Button>
            </div>
        </form>
    )
}
