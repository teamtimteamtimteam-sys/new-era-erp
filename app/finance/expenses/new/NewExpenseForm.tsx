'use client'

import { CONTROL_CHECKBOX, CONTROL_INPUT, CONTROL_RADIO, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { CounterpartyOptions } from '@/app/components/finance/counterpartyOptions'
// 开支表单:费用科目(仅 active expense 科目)、金额/币种/汇率(默认 SGD ——
// 本地开销多为新币,与销售面板的 USD 默认刻意不同)、付款状态(默认挂账 ——
// 账单通常先到后付):paid → 银行账户(默认随币种,可改)+ 收款方(可选);
// unpaid → 供应商(必选,后续核销要用)。底部实时 USD 预览 + 将要生成的分录说明。
// 提交走 createExpense(rpc record_expense_document)。
// ★ EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0 Q1–Q16):一张单是【表头 + 行】。表头:日期 · 收款方 · 币种 · 备注
//   (与代扣、资本那两块);每一行:自己的科目 · 税码 · 不含税净额 · 行备注,可加可删,没有上限(Q7)。
//   资本支出单恰好一行(Q1):勾上资本时网格只剩那一行、科目定死 1500,有多行时那个勾选框按不动并说为什么。
//   行网格整份进一个隐藏格子(lines_json)—— 提交读它,草稿也存它;恢复草稿时由 onRestore 把整张网格与
//   受控的表头一起重建,重建不出来就【一个格子都不写】(Q8,IDLE-DRAFT-GRID-HALF-RESTORE 的那一条)。
import { useActionState, useCallback, useState } from 'react'
import { useRef } from 'react'
import { useFormDraft } from '@/lib/useFormDraft'
import DraftBanner from '@/app/components/DraftBanner'
import Link from 'next/link'
import { createExpense, type CreateExpenseState } from './actions'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import DecimalInput from '@/app/components/forms/DecimalInput'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { businessToday } from '@/lib/format'
import { DatePicker } from '@/app/components/ui/date-picker'

// EQP-1c-c:已登记、还能加成本的机器。
// EQP-1c-c:资本支出的两扇门。**这个数组是 expense.form.capitalMode(.Hint) 那两族
// 文案的【真源】** —— scripts/check-i18n.mjs 的 MANIFEST 现读这一行(与
// NewOrderForm 的 ORDER_KINDS 同一手法),将来多一扇门就自动跟着变宽。
const CAPITAL_MODES = ['new', 'existing'] as const

// EQP-1c-c:已登记、还能加成本的机器。
export type AssetOption = { id: string; label: string }
// EQP-1c-c:一条设备采购行 —— 挑它是【可选】的(没有采购单就买断一台机器是合法的)。
export type PoLineOption = {
    id: string; lineNo: number; assetId: string; supplierId: string
    poCode: string; currency: string; estimate: number | null; billedBy: string | null
}

const initialState: CreateExpenseState = {}

export type AccountOption = { code: string; name: string }
// GST-2:供应商带上它的默认进项税码。**null 不是默认值,是一个没人回答过的问题。**
export type SupplierOption = { id: string; name: string; default_tax_code?: string | null
    // WHT-1:这家在新加坡所得税上是不是居民。**三态,NULL = 没有人回答过。**
    // 它只驱动【要不要追问代扣】,不驱动金额 —— 扣多少由 record_expense 解析并冻在单上。
    tax_residence?: string | null }
export type WhtNatureOption = { code: string; name: string }
export type TaxCodeOption = {
    code: string; name_en: string; name_zh: string
    // 【可抵与不可抵要在屏幕上分得开】BL 有税、税率 9%,但那笔税要不回来 ——
    // 它进采购成本、不进 box7。一个只印百分数的下拉说不出这件事。
    is_claimable: boolean
}

// 本地日期(YYYY-MM-DD),用作费用日期默认值(避免 UTC 偏移)。
function todayIsoLocal(): string {
    const d = new Date()
    const yyyy = d.getFullYear()
    const mm = String(d.getMonth() + 1).padStart(2, '0')
    const dd = String(d.getDate()).padStart(2, '0')
    return `${yyyy}-${mm}-${dd}`
}

const round2 = (n: number) => Math.round(n * 100) / 100

// EXPENSE-MULTILINE-1:一行。taxTouched = 这一行的税码被人改过(没改过就跟着供应商的默认走,与单行时同一条)。
type ExpenseLine = { key: string; account: string; taxCode: string; taxTouched: boolean; amount: string; notes: string }
let lineSeq = 0
const newLine = (): ExpenseLine => ({ key: `l${++lineSeq}`, account: '', taxCode: '', taxTouched: false, amount: '', notes: '' })
// 网格进出草稿 / 提交的那一种形状 —— 与 record_expense_document 的 p_lines 逐键相同
type WireLine = { account_code: string; amount: string; tax_code: string; notes: string }
function parseWireLines(raw: string | undefined): ExpenseLine[] | null {
    if (!raw) return null
    let v: unknown
    try { v = JSON.parse(raw) } catch { return null }
    if (!Array.isArray(v) || v.length === 0) return null
    const out: ExpenseLine[] = []
    for (const x of v) {
        if (!x || typeof x !== 'object') return null
        const w = x as Partial<WireLine>
        if (typeof w.account_code !== 'string' || typeof w.amount !== 'string'
            || typeof w.tax_code !== 'string' || typeof w.notes !== 'string') return null
        out.push({ ...newLine(), account: w.account_code, amount: w.amount, taxCode: w.tax_code,
                   taxTouched: w.tax_code !== '', notes: w.notes })
    }
    return out
}

export default function NewExpenseForm({
    accounts,
    suppliers,
    employees,
    baseCurrency,
    assets,
    poLines,
    canSeePurchasing,
    canSeeSuppliers,
    capitalAccountLabel,
    gstRegistered,
    taxCodes,
    whtNatures,
canEdit
}: {
    accounts: AccountOption[]
    suppliers: SupplierOption[]
    employees: SupplierOption[]
    baseCurrency: string
    assets: AssetOption[]
    poLines: PoLineOption[]
    canSeePurchasing: boolean
    /** ★ FIX-2b:供应商名单空着的两种意思,只有服务端答得出是哪一种。 */
    canSeeSuppliers: boolean
    capitalAccountLabel: string
    gstRegistered: boolean
    taxCodes: TaxCodeOption[]
    whtNatures: WhtNatureOption[]

canEdit: boolean
}) {
    const t = useTranslations()
    const locale = useLocale()
    const [state, formAction, isPending] = useActionState(createExpense, initialState)

    // IDLE-DRAFT:草稿留存。受限与否由 lib/maskedTables.ts 推出来,
    // 不在这里声明 —— 见 lib/useFormDraft.ts 抬头。
    const formRef = useRef<HTMLFormElement>(null)

    // EXPENSE-MULTILINE-1:行。GST-2 的进项税码逐行:跟随所选供应商的默认(未手改过时),否则空 ——
    // 空 + 已注册 = 数据库按名拒(TAX_CODE_REQUIRED|supplier),不猜。
    const [lines, setLines] = useState<ExpenseLine[]>(() => [newLine()])
    const setLine = (key: string, patch: Partial<ExpenseLine>) =>
        setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)))
    // WHT-1:代扣裁定的三个部件。【没有默认值】 —— 空是"没有人回答过",
    // 而对一个非居民收款人,record_expense 会按名拒(WHT_NATURE_REQUIRED)。
    const [whtNature, setWhtNature] = useState('')
    const [whtTreatyRate, setWhtTreatyRate] = useState('')
    const [whtTreatyRef, setWhtTreatyRef] = useState('')
    const [currency, setCurrency] = useState('SGD') // 本地开销默认新币(销售面板默认 USD,刻意不同)
    // ★ PAY-REQ-1(Tim 2026-09-23):开支【永远】记成欠收款人的 —— 「已付」那一支退休了。
    //   钱离开要先批:付它走一张付款申请(CFO 批准后由财务付),record_expense 对 'paid' 按名拒。
    // FIN-22:资本性支出 —— 勾上后科目固定 1500(隐藏域),同一事务生成台账行
    const [capital, setCapital] = useState(false)
    // ── EQP-1c-c:资本支出的【两扇门,由人明选】────────────────────────────
    // 【为什么不从"选没选机器"推断】一个推断出来的模式,是一个【没有人选过】的模式:
    // 表单会因为一个下拉框恰好空着,就替人决定这笔钱是买一台新机器还是给旧机器加钱,
    // 而这两件事的后果完全不同 —— 前者会多出一张【撤不回来】的资产卡。
    // 与 /finance/assets/new 上那两扇门同一条:各用一句人话摆在旁边。
    const [capitalMode, setCapitalMode] = useState<'new' | 'existing'>('new')
    const isAppend = capital && capitalMode === 'existing'
    const [assetId, setAssetId] = useState('')
    const [poLineId, setPoLineId] = useState('')
    const [counterparty, setCounterparty] = useState('')
    const [residual, setResidual] = useState('')

    // ★ Q8:草稿【整份恢复,或者一点都不恢复】—— 网格与受控的表头由这里重建;网格解析不出来就返回 false,
    //   useFormDraft 于是一个格子都不写,横幅照直说"没能整份恢复"。非受控的格子(日期、备注)由钩子随后写回。
    const onRestore = useCallback((v: Record<string, string>) => {
        const restoredLines = parseWireLines(v['lines_json'])
        if (!restoredLines) return false
        const isCap = v['capital'] === 'on'
        if (isCap && restoredLines.length !== 1) return false
        setLines(restoredLines)
        setCurrency(v['currency'] || baseCurrency)
        setCounterparty(v['counterparty'] ?? '')
        setCapital(isCap)
        setCapitalMode(v['capital_mode'] === 'existing' ? 'existing' : 'new')
        setAssetId(v['asset_id'] ?? '')
        setPoLineId(v['purchase_order_line_id'] ?? '')
        setResidual(v['asset_residual'] ?? '')
        setWhtNature(v['wht_nature'] ?? '')
        setWhtTreatyRate(v['wht_treaty_rate_pct'] ?? '')
        setWhtTreatyRef(v['wht_treaty_ref'] ?? '')
        return true
    }, [baseCurrency])
    const draft = useFormDraft({ formKey: 'finance/expenses/new', table: 'expenses', subject: null, formRef, onRestore })

    // 银行账户默认跟随币种(SGD → 1000,USD → 1010),之后仍可手动改
    function onCurrencyChange(c: string) {
        setCurrency(c)
    }

    // 实时预览只对本位币直给;外币的 SGD 值由当日牌价决定(DB 侧),预览不猜数。合计 = 各行净额之和。
    const amounts = lines.map((l) => Number(l.amount))
    const amountValid = lines.every((l, i) => !!l.amount && !Number.isNaN(amounts[i]) && amounts[i] > 0)
    const amountNum = round2(amounts.reduce((a, b) => a + (Number.isNaN(b) ? 0 : b), 0))
    const amountSgd = currency === baseCurrency && amountValid ? amountNum : null

    const accountLabel = accounts.find((a) => a.code === lines[0]?.account)
    // D5:资本支出的借方【就是 1500】—— record_expense 把它定死了,而科目下拉在
    // 资本模式下是隐藏的,于是此前这里落到 '…'(走查看到的那个省略号)。
    // 名字由服务端从库里取,不写死。
    const previewAccount = capital
        ? capitalAccountLabel
        : (accountLabel ? `${accountLabel.code} ${accountLabel.name}` : '…')
    // 资本单恰好一行(Q1):有多行时资本那个勾选框按不动
    const capitalBlocked = !capital && lines.length > 1

    // ── D3:这台机器、这家供应商、还没被报销过的设备行 ────────────────────
    // 三个条件全部照抄 record_expense 的守卫,不另想一套(见 page.tsx 的注释)。
    const linesForAsset = poLines.filter((l) => l.assetId === assetId)
    // 【值的格式是 "kind:id"】—— 与 CounterpartyOptions / parseCounterparty 同一份约定。
    // 选的是员工时 supplierId 为 null,于是不按供应商过滤(而服务端会按名拒:
    // 挂在采购单行上的支出必须说出开票的供应商)。
    const supplierId = counterparty.startsWith('supplier:') ? counterparty.slice('supplier:'.length) : null

    // GST-2:所选供应商的默认进项税码 —— 一个【建议】,不是一个悄悄的替代。
    // 【已付的费用单合法地没有供应商】(线上就有两笔),那种单据没有可继承的
    // 对象,于是这里是空的,人必须自己选一个;数据库那边按名拒,不猜。
    const supplierDefaultTaxCode =
        suppliers.find((sp) => sp.id === supplierId)?.default_tax_code ?? null
    const effTax = (l: ExpenseLine) => (l.taxTouched ? l.taxCode : (supplierDefaultTaxCode ?? ''))
    // 提交与草稿读的那一份:表单状态 → p_lines 的形状(资本那一行科目定死 1500)
    const wire: WireLine[] = lines.map((l) => ({
        account_code: capital ? '1500' : l.account, amount: l.amount,
        tax_code: gstRegistered ? effTax(l) : '', notes: l.notes,
    }))

    // ── WHT-1:要不要追问代扣 ────────────────────────────────────────────────
    // ★【判据是【申报过是非居民】,不是"外国供应商"】★ 居民身份是声明的,
    //   country 不是它的代名词 —— 而一个前端条件【代指】某条服务端规矩,
    //   会在数据库那边一改就悄悄错掉(GST-3 的 kind === 'order' 那一课)。
    //   这里问的与 record_expense 问的是【同一个字段】。
    const payeeResidence =
        suppliers.find((sp) => sp.id === supplierId)?.tax_residence ?? null
    const askWht = payeeResidence === 'non_resident'

    // 【已报销的行【留在列表里但禁用】,不是藏起来】—— 本仓库的判据是:
    // 问题【不适用】才隐藏,问题适用但此刻【被挡住】就禁用并把理由摆在旁边。
    // 一条属于这台机器的采购行,"能不能报销它"是一个成立的问题,只是答案是"已经报过了" ——
    // 藏起来会让人以为那条行不存在,而它就在采购单上明摆着。
    // (与下单表单里"已挂在别的单上"的资产同一手法:disabled + 后缀说明。)
    const lineChoices = linesForAsset.filter(
        (l) => supplierId === null || l.supplierId === supplierId)

    return (
        <PermissionGate code="module.finance.edit" allowed={canEdit}>
        <form ref={formRef} action={formAction} className="space-y-4">
                <DraftBanner draft={draft} />
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}

            <div className="flex flex-wrap gap-4">
                {/* 费用日期(默认今天)*/}
                <div>
                    <label className="block mb-1">
                        {t('expense.form.date')} <span className="text-red-600">*</span>
                    </label>
                    <DatePicker
                        name="expense_date"
                        required
                        defaultValue={todayIsoLocal()}
                        max={businessToday()}
                    />
                </div>
                {/* FIN-22:资本性支出开关 —— 勾上后借 1500 而不是费用科目,
                    同一事务生成固定资产台账行(资产不脱离应付/付款存在)*/}
                <div className="self-end pb-2">
                    <label className="inline-flex items-center gap-2">
                        <input className={CONTROL_CHECKBOX} type="checkbox" name="capital" checked={capital}
                               disabled={capitalBlocked}
                               onChange={(e) => setCapital(e.target.checked)} />
                        {t('expense.form.capital')}
                    </label>
                    {capitalBlocked && (
                        <p className="text-xs text-[color:var(--brand-muted-text)] mt-1 max-w-xs">{t('expense.form.capitalOneLine')}</p>
                    )}
                </div>
                {/* 资本行科目固定 1500(EXPENSE-MULTILINE-1:普通费用的科目在下面每一行上)*/}
                {capital && (
                    <p className="flex-1 min-w-[16rem] self-end pb-2 text-sm text-[color:var(--brand-muted-text)]">
                        {t('expense.form.capitalHint')}
                    </p>
                )}
            </div>

            {/* ★★【WHT-1:预提税 —— 只在收款人【申报为非居民】时出现】★★
                这是 4.1 的前半句:**代扣在哪里裁定**。它在这里,而不是在付款屏幕上,
                因为代扣是【债务】的属性(3.1 的裁定):这一刻是收款人身份、款项性质
                与金额三者【同时已知】的唯一一刻,而 IRAS 的纳税时点是「应付」与
                「实付」孰早 —— 那是这张单的日期,不是现金的日期。
                【留空不是"不代扣"】对非居民收款人,服务端按名拒;要表达"不适用",
                选那个显式的「不适用代扣」。 */}
            {askWht && (
                <div className="border border-amber-300 bg-amber-50 rounded p-4">
                    <p className="text-sm font-medium mb-1">{t('expense.form.whtHeading')}</p>
                    <p className="text-xs text-[color:var(--brand-text)] mb-3">{t('expense.form.whtWhy')}</p>
                    <div className="flex flex-wrap gap-4">
                        <div className="flex-1 min-w-[16rem]">
                            <label className="block mb-1">
                                {t('expense.form.whtNature')} <span className="text-red-600">*</span>
                            </label>
                            <select
                                name="wht_nature"
                                value={whtNature}
                                onChange={(e) => setWhtNature(e.target.value)}
                                className={`${CONTROL_SELECT} w-full`}
                            >
                                <option value="">{t('expense.form.whtNaturePick')}</option>
                                {whtNatures.map((n) => (
                                    <option key={n.code} value={n.code}>{n.name}</option>
                                ))}
                            </select>
                            {!whtNature && (
                                <p className="text-xs text-amber-700 mt-1">{t('expense.form.whtNatureRequired')}</p>
                            )}
                        </div>
                        {/* 【协定减免:两个格子要么都填、要么都不填】服务端按名拒
                            (WHT_TREATY_REF_WITHOUT_RATE / WHT_TREATY_REF_REQUIRED),
                            页面不重复判一遍 —— 那就是同一条规矩的第二处实现。 */}
                        <div>
                            <label className="block mb-1">{t('expense.form.whtTreatyRate')}</label>
                            <input
                                name="wht_treaty_rate_pct" type="number" step="0.001" min="0"
                                value={whtTreatyRate}
                                onChange={(e) => setWhtTreatyRate(e.target.value)}
                                className={`${CONTROL_INPUT} w-28`}
                            />
                        </div>
                        <div className="flex-1 min-w-[14rem]">
                            <label className="block mb-1">{t('expense.form.whtTreatyRef')}</label>
                            <input
                                name="wht_treaty_ref"
                                value={whtTreatyRef}
                                onChange={(e) => setWhtTreatyRef(e.target.value)}
                                className={`${CONTROL_INPUT} w-full`}
                            />
                        </div>
                    </div>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-2">{t('expense.form.whtTreatyHint')}</p>
                    {/* 【已付那一支在这里就说出来,不等服务端】它是 record_expense
                        默认参数值那条路,而一条在默认路径上才现身的拒绝最该被提前说明。
                        这【不是】重复实现规则:服务端仍然拒(那是把关的那一道),
                        这里只是把"该怎么走"说在人按下按钮之前。 */}
                </div>
            )}

            <div className="flex flex-wrap gap-4">
                {/* 币种(默认 SGD)*/}
                <div>
                    <label className="block mb-1">{t('expense.form.currency')}</label>
                    <select
                        name="currency"
                        value={currency}
                        onChange={(e) => onCurrencyChange(e.target.value)}
                        className={CONTROL_SELECT}
                    >
                        <option value="SGD">SGD</option>
                        <option value="USD">USD</option>
                    </select>
                </div>
                {/* FIN-0:外币按费用日行方卖出价(tt_sell)自动估值,当天没牌价直接拒 */}
                {currency !== baseCurrency && (
                    <p className="text-xs text-[color:var(--brand-muted-text)] self-end pb-2 max-w-56">{t('common.fxBoardRateHint')}</p>
                )}
                {/* PAY-REQ-1:往来对象恒必选 —— 开支永远挂账,付款走付款申请 */}
                    <div className="flex-1 min-w-[16rem]">
                        {/* PAYEE-1b:挂账的往来对象 —— 供应商【或】员工(报销)。
                            一个下拉、两组选项:一次选择就是一个不可分割的答案,
                            没有第二个字段能和它矛盾(库里那条 XOR 的表单形态)。
                            默认仍是"请选择",供应商在前 —— 既有用法一步没变。 */}
                        <label className="block mb-1">
                            {t('expense.form.counterparty')} <span className="text-red-600">*</span>
                        </label>
                        {/* EQP-1c-c:改成受控 —— 采购行的挑选要按【这家供应商】过滤,
                            而那需要知道当前选的是谁。值的格式一字未改
                            (kind:id,见 CounterpartyOptions),既有提交路径逐字照旧。 */}
                        <select
                            name="counterparty"
                            required
                            value={counterparty}
                            onChange={(e) => { setCounterparty(e.target.value); setPoLineId('') }}
                            className={`${CONTROL_SELECT} w-full`}
                        >
                            <option value="" disabled>
                                {t('expense.form.selectCounterparty')}
                            </option>
                            <CounterpartyOptions
                                suppliers={suppliers}
                                employees={employees}
                                supplierLabel={t('finance.counterpartyKind.supplier')}
                                employeeLabel={t('finance.counterpartyKind.employee')}
                                employeesEmptyLabel={t('finance.employeesEmpty')}
                                suppliersEmptyLabel={canSeeSuppliers
                                    ? t('suppliers.pickerEmptyGoods')
                                    : t('suppliers.pickerRestricted')} />
                        </select>
                        <p className="mt-1 text-xs text-[color:var(--brand-muted-text)]">{t('expense.form.alwaysUnpaidHint')}</p>
                    </div>
            </div>

            {/* ── EXPENSE-MULTILINE-1:行 —— 每一行自己的科目 · 税码 · 不含税净额 · 备注 ──────────────
                【整张网格进一个隐藏格子】提交读它、草稿存它;网格里的控件自己不带 name。
                390px 上每一行是一块会换行的卡片(flex-wrap),桌面上一行排开。 */}
            <input type="hidden" name="lines_json" value={JSON.stringify(wire)} />
            <div className="space-y-2" data-expense-lines="">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                    <h3 className="font-medium">{t('expense.form.linesHeading')}</h3>
                    <p className="text-xs text-[color:var(--brand-muted-text)]">
                        {capital ? t('expense.form.capitalOneLine') : t('expense.form.linesHint')}
                    </p>
                </div>
                {lines.map((l, i) => (
                    <div key={l.key} className="flex flex-wrap items-end gap-2 rounded border border-gray-200 p-2">
                        <span className="w-full text-xs text-[color:var(--brand-muted-text)] sm:w-auto sm:self-center">
                            {t('expense.form.lineNo', { n: i + 1 })}
                        </span>
                        {!capital && (
                            <label className="flex min-w-0 flex-1 basis-56 flex-col text-sm">
                                <span>{t('expense.form.account')} <span className="text-red-600">*</span></span>
                                <select required value={l.account}
                                        onChange={(e) => setLine(l.key, { account: e.target.value })}
                                        className={`${CONTROL_SELECT} w-full`}>
                                    <option value="" disabled>{t('expense.form.selectAccount')}</option>
                                    {accounts.map((a) => (
                                        <option key={a.code} value={a.code}>{a.code} {a.name}</option>
                                    ))}
                                </select>
                            </label>
                        )}
                        {/* ★【GST-2:进项税码 —— 只在已注册时出现】★ 逐行;未注册时这张表单与建 GST 之前一样,连这一格都不长出来 */}
                        {gstRegistered && (
                            <label className="flex min-w-0 flex-1 basis-48 flex-col text-sm">
                                <span>{t('expense.form.taxCode')} <span className="text-red-600">*</span></span>
                                <select value={effTax(l)}
                                        onChange={(e) => setLine(l.key, { taxTouched: true, taxCode: e.target.value })}
                                        className={`${CONTROL_SELECT} w-full`}>
                                    <option value="">{t('expense.form.taxCodePick')}</option>
                                    {taxCodes.map((c) => (
                                        <option key={c.code} value={c.code}>
                                            {/* 【按界面语言选一个,不是把两个拼起来】与仓库里另外 105 处同一个写法。 */}
                                            {c.code} · {locale === 'zh' ? c.name_zh : c.name_en}
                                            {c.is_claimable ? '' : ` — ${t('expense.form.taxCodeBlocked')}`}
                                        </option>
                                    ))}
                                </select>
                                {!effTax(l) && (
                                    <span className="text-xs text-amber-700 mt-1">{t('expense.form.taxCodeNoDefault')}</span>
                                )}
                            </label>
                        )}
                        <label className="flex flex-col text-sm">
                            <span>{t('expense.form.lineAmount')} <span className="text-red-600">*</span></span>
                            <DecimalInput required value={l.amount}
                                          onChange={(v) => setLine(l.key, { amount: v })} className="w-32" />
                        </label>
                        <label className="flex min-w-0 flex-1 basis-40 flex-col text-sm">
                            <span>{t('expense.form.lineNotes')}</span>
                            <input type="text" value={l.notes}
                                   onChange={(e) => setLine(l.key, { notes: e.target.value })}
                                   className={`${CONTROL_INPUT} w-full`} />
                        </label>
                        {lines.length > 1 && (
                            <Button type="button" variant="secondary" size="xs"
                                    aria-label={t('expense.form.removeLineAria', { n: i + 1 })}
                                    onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))}>
                                {t('expense.form.removeLine')}
                            </Button>
                        )}
                    </div>
                ))}
                {gstRegistered && (
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('expense.form.taxCodeNetHint')}</p>
                )}
                {gstRegistered && supplierDefaultTaxCode && lines.some((l) => !l.taxTouched) && (
                    <p className="text-xs text-[color:var(--brand-muted-text)]">
                        {t('expense.form.taxCodeFromSupplier', { code: supplierDefaultTaxCode })}
                    </p>
                )}
                {!capital && (
                    <Button type="button" variant="secondary" size="xs"
                            onClick={() => setLines((ls) => [...ls, newLine()])}>
                        {t('expense.form.addLine')}
                    </Button>
                )}
            </div>

            <div className="flex flex-wrap gap-4">
                {/* 备注 */}
                <div className="flex-1 min-w-[12rem]">
                    <label className="block mb-1">{t('expense.form.notes')}</label>
                    <input
                        type="text"
                        name="notes"
                        className={`${CONTROL_INPUT} w-full`}
                    />
                </div>
            </div>

            {/* ── FIN-22:资产明细(仅资本行)。购置日 = 上面的费用日;
                在役日可留空(未投用不折旧),折旧从【在役日】起算 ── */}
            {capital && (
                <div className="border border-gray-300 rounded p-4 space-y-3">
                    <h3 className="">{t('expense.form.assetSection')}</h3>

                    {/* ── EQP-1c-c(D1):两扇门,【由人明选】────────────────────
                        一个推断出来的模式,是一个没有人选过的模式。选错的代价不对称:
                        "新机器"用在一台已登记的机器上,会多出一张【撤不回来】的资产卡。 */}
                    <div className="rounded border border-blue-200 bg-blue-50 p-3 space-y-2">
                        {CAPITAL_MODES.map((m) => (
                            <label key={m} className="flex items-start gap-2">
                                <input type="radio" name="capital_mode" value={m} className={`${CONTROL_RADIO} mt-1`}
                                       checked={capitalMode === m}
                                       onChange={() => { setCapitalMode(m); setAssetId(''); setPoLineId('') }} />
                                <span>
                                    <span className="font-medium">{t('expense.form.capitalMode.' + m)}</span>
                                    <span className="block text-xs text-blue-900">
                                        {t('expense.form.capitalModeHint.' + m)}
                                    </span>
                                </span>
                            </label>
                        ))}
                    </div>

                    {/* ── 追加模式:挑一台【已登记】的机器 ────────────────────── */}
                    {isAppend && (
                        <div className="space-y-3">
                            <div>
                                <label className="block mb-1">
                                    {t('expense.form.existingAsset')} <span className="text-red-600">*</span>
                                </label>
                                <select name="asset_id" required value={assetId}
                                        onChange={(e) => { setAssetId(e.target.value); setPoLineId('') }}
                                        className={`${CONTROL_SELECT} w-full`}>
                                    <option value="" disabled>—</option>
                                    {assets.map((a) => (
                                        <option key={a.id} value={a.id}>{a.label}</option>
                                    ))}
                                </select>
                                {/* 【列表的判据照抄函数的两条拒绝】—— 已投用 / 已处置的机器不在这里,
                                    因为 record_expense 的追加支对它们按名拒。 */}
                                <p className="mt-1 text-xs text-[color:var(--brand-muted-text)]">{t('expense.form.existingAssetHint')}</p>
                                {assets.length === 0 && (
                                    <p className="mt-1 text-xs text-amber-700">{t('expense.form.noAssetsAppendable')}</p>
                                )}
                            </div>

                            {/* ── D3:采购单行(可选)—— 三种"空"要说清是哪一种 ──── */}
                            <div>
                                <label className="block mb-1">
                                    {t('expense.form.poLine')}
                                </label>
                                <select name="purchase_order_line_id" value={poLineId}
                                        onChange={(e) => setPoLineId(e.target.value)}
                                        className={`${CONTROL_SELECT} w-full`}>
                                    {/* 【挑它是可选的】没有采购单就买断一台机器是合法的,
                                        record_expense 也允许(那一列可空)。 */}
                                    <option value="">{t('expense.form.poLineNone')}</option>
                                    {lineChoices.map((l) => (
                                        <option key={l.id} value={l.id} disabled={l.billedBy !== null}>
                                            {l.poCode} · {t('expense.form.poLineNo', { 0: l.lineNo })}
                                            {l.estimate !== null ? ` · ${l.estimate} ${l.currency}` : ''}
                                            {l.billedBy ? ` — ${t('expense.form.poLineBilledBy', { 0: l.billedBy })}` : ''}
                                        </option>
                                    ))}
                                </select>
                                {/* 【三种空,三条不同的下一步 —— 所以分开说】 */}
                                {lineChoices.length === 0 && (
                                    <p className="mt-1 text-xs text-amber-700">
                                        {!canSeePurchasing
                                            ? t('expense.form.poLineRestricted')
                                            : !assetId
                                                ? t('expense.form.poLinePickAssetFirst')
                                                : t('expense.form.poLineNoOrder')}
                                    </p>
                                )}
                                <p className="mt-1 text-xs text-[color:var(--brand-muted-text)]">{t('expense.form.poLineHint')}</p>
                            </div>
                        </div>
                    )}

                    {/* ── 新建模式:这些字段属于【卡】,不属于这笔支出 ──────────
                        追加时【隐藏,不是禁用】—— 问题不适用,不是"你现在不能填"。 */}
                    {!isAppend && (
                    <div className="flex flex-wrap gap-4">
                        <div className="flex-1 min-w-[16rem]">
                            <label className="block mb-1">
                                {t('assets.colDescription')} <span className="text-red-600">*</span>
                            </label>
                            <input type="text" name="asset_description" required={capital && !isAppend}
                                   className={`${CONTROL_INPUT} w-full`} />
                        </div>
                        <div>
                            <label className="block mb-1">{t('assets.colCategory')}</label>
                            <select name="asset_category" defaultValue="equipment"
                                    className={CONTROL_SELECT}>
                                <option value="equipment">{t('assets.category.equipment')}</option>
                                <option value="vehicle">{t('assets.category.vehicle')}</option>
                                <option value="office">{t('assets.category.office')}</option>
                                <option value="other">{t('assets.category.other')}</option>
                            </select>
                        </div>
                        <div>
                            <label className="block mb-1">{t('assets.colInService')}</label>
                            <DatePicker name="asset_in_service_date" />
                            <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('expense.form.inServiceHint')}</p>
                        </div>
                        <div>
                            <label className="block mb-1">
                                {t('assets.colLife')} <span className="text-red-600">*</span>
                            </label>
                            <input type="number" name="asset_life_months" min={1} step={1} required={capital && !isAppend}
                                   className={`${CONTROL_INPUT} w-28`} />
                        </div>
                        <div>
                            <label className="block mb-1">
                                {t('expense.form.residual', { ccy: baseCurrency })}
                            </label>
                            <DecimalInput name="asset_residual" value={residual} onChange={setResidual}
                                          className="w-32" />
                        </div>
                    </div>
                    )}
                </div>
            )}

            {/* 实时预览:USD 金额 + 将要生成的分录说明 */}
            <div className="bg-gray-50 rounded p-4 text-sm space-y-1">
                <div>
                    <span className="font-medium">
                        {amountSgd !== null
                            ? t('expense.amountPreview', { amount: formatMoneyBare(amountSgd, '同句 amountPreview 文案「金额:{amount} {ccy}」里的 {ccy}'), ccy: baseCurrency })
                            : t('common.fxBoardRateHint')}
                    </span>
                    {currency !== baseCurrency && amountValid && (
                        <span className="text-[color:var(--brand-muted-text)] ml-2">
                            ({currency} {formatMoneyBare(amountNum, '同格内紧邻的 {currency} 前缀')})
                        </span>
                    )}
                </div>
                <p className="text-[color:var(--brand-muted-text)]">
                    {lines.length === 1
                        ? t('expense.previewUnpaid', { account: previewAccount })
                        : t('expense.previewUnpaidLines', { n: lines.length })}
                </p>
            </div>

            <div className="flex gap-3 pt-2">
                <Button
                    type="submit"
                    disabled={isPending}
                >
                    {isPending ? t('expense.form.submitting') : t('expense.form.submit')}
                </Button>
                <Button asChild variant="secondary">
                    <Link
                        href="/finance/expenses"
                    >
                        {t('common.cancel')}
                    </Link>
                </Button>
            </div>
        </form>
        </PermissionGate>
    )
}
