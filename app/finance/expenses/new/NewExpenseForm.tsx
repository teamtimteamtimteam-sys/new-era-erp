'use client'

import { CounterpartyOptions } from '@/app/components/finance/counterpartyOptions'
// 开支表单:费用科目(仅 active expense 科目)、金额/币种/汇率(默认 SGD ——
// 本地开销多为新币,与销售面板的 USD 默认刻意不同)、付款状态(默认挂账 ——
// 账单通常先到后付):paid → 银行账户(默认随币种,可改)+ 收款方(可选);
// unpaid → 供应商(必选,后续核销要用)。底部实时 USD 预览 + 将要生成的分录说明。
// 提交走 createExpense(rpc record_expense)。
import { useActionState, useState } from 'react'
import { useRef } from 'react'
import { useFormDraft } from '@/lib/useFormDraft'
import DraftBanner from '@/app/components/DraftBanner'
import { bankAccountFor, currencyOfBank } from '@/lib/currencyMap'
import Link from 'next/link'
import { createExpense, type CreateExpenseState } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import DecimalInput from '@/app/components/forms/DecimalInput'

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
export type SupplierOption = { id: string; name: string; default_tax_code?: string | null }
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

export default function NewExpenseForm({
    accounts,
    suppliers,
    employees,
    baseCurrency,
    assets,
    poLines,
    canSeePurchasing,
    capitalAccountLabel,
    gstRegistered,
    taxCodes,
}: {
    accounts: AccountOption[]
    suppliers: SupplierOption[]
    employees: SupplierOption[]
    baseCurrency: string
    assets: AssetOption[]
    poLines: PoLineOption[]
    canSeePurchasing: boolean
    capitalAccountLabel: string
    gstRegistered: boolean
    taxCodes: TaxCodeOption[]
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(createExpense, initialState)

    // IDLE-DRAFT:草稿留存。受限与否由 lib/maskedTables.ts 推出来,
    // 不在这里声明 —— 见 lib/useFormDraft.ts 抬头。
    const formRef = useRef<HTMLFormElement>(null)
    const draft = useFormDraft({ formKey: 'finance/expenses/new', table: 'expenses', subject: null, formRef })

    const [accountCode, setAccountCode] = useState('')
    // GST-2:进项税码。跟随所选供应商的默认(未手改过时),否则空 ——
    // 空 + 已注册 = 数据库按名拒(TAX_CODE_REQUIRED|supplier),不猜。
    const [taxCode, setTaxCode] = useState('')
    const [taxCodeTouched, setTaxCodeTouched] = useState(false)
    const [amount, setAmount] = useState('')
    const [currency, setCurrency] = useState('SGD') // 本地开销默认新币(销售面板默认 USD,刻意不同)
    const [paymentStatus, setPaymentStatus] = useState<'paid' | 'unpaid'>('unpaid')
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
    const [bank, setBank] = useState('1000') // 初始币种 SGD → 1000

    // 银行账户默认跟随币种(SGD → 1000,USD → 1010),之后仍可手动改
    function onCurrencyChange(c: string) {
        setCurrency(c)
        setBank(bankAccountFor(c))
    }

    // 实时预览只对本位币直给;外币的 SGD 值由当日牌价决定(DB 侧),预览不猜数
    const amountNum = Number(amount)
    const amountValid = !!amount && !Number.isNaN(amountNum) && amountNum > 0
    const amountSgd = currency === baseCurrency && amountValid ? round2(amountNum) : null

    const accountLabel = accounts.find((a) => a.code === accountCode)
    // D5:资本支出的借方【就是 1500】—— record_expense 把它定死了,而科目下拉在
    // 资本模式下是隐藏的,于是此前这里落到 '…'(走查看到的那个省略号)。
    // 名字由服务端从库里取,不写死。
    const previewAccount = capital
        ? capitalAccountLabel
        : (accountLabel ? `${accountLabel.code} ${accountLabel.name}` : '…')

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
    const effTaxCode = taxCodeTouched ? taxCode : (supplierDefaultTaxCode ?? '')
    // 【已报销的行【留在列表里但禁用】,不是藏起来】—— 本仓库的判据是:
    // 问题【不适用】才隐藏,问题适用但此刻【被挡住】就禁用并把理由摆在旁边。
    // 一条属于这台机器的采购行,"能不能报销它"是一个成立的问题,只是答案是"已经报过了" ——
    // 藏起来会让人以为那条行不存在,而它就在采购单上明摆着。
    // (与下单表单里"已挂在别的单上"的资产同一手法:disabled + 后缀说明。)
    const lineChoices = linesForAsset.filter(
        (l) => supplierId === null || l.supplierId === supplierId)

    return (
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
                    <label className="block text-sm font-medium mb-1">
                        {t('expense.form.date')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="date"
                        name="expense_date"
                        required
                        defaultValue={todayIsoLocal()}
                        className="border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                {/* FIN-22:资本性支出开关 —— 勾上后借 1500 而不是费用科目,
                    同一事务生成固定资产台账行(资产不脱离应付/付款存在)*/}
                <div className="self-end pb-2">
                    <label className="inline-flex items-center gap-2 text-sm font-medium">
                        <input type="checkbox" name="capital" checked={capital}
                               onChange={(e) => setCapital(e.target.checked)} />
                        {t('expense.form.capital')}
                    </label>
                </div>
                {/* 费用科目(仅 active expense 科目,按编码排序);资本行固定 1500 */}
                {!capital ? (
                    <div className="flex-1 min-w-[16rem]">
                        <label className="block text-sm font-medium mb-1">
                            {t('expense.form.account')} <span className="text-red-600">*</span>
                        </label>
                        <select
                            name="account_code"
                            required
                            value={accountCode}
                            onChange={(e) => setAccountCode(e.target.value)}
                            className="w-full border border-gray-300 px-3 py-2 rounded"
                        >
                            <option value="" disabled>
                                {t('expense.form.selectAccount')}
                            </option>
                            {accounts.map((a) => (
                                <option key={a.code} value={a.code}>
                                    {a.code} {a.name}
                                </option>
                            ))}
                        </select>
                    </div>
                ) : (
                    <p className="flex-1 min-w-[16rem] self-end pb-2 text-sm text-gray-600">
                        {t('expense.form.capitalHint')}
                    </p>
                )}
            </div>

            {/* ★【GST-2:进项税码 —— 只在已注册时出现】★
                未注册时这张表单与建 GST 之前一模一样,连这一格都不长出来。
                【p_amount 始终是不含税净额】税另算,所以这里要把话说清楚,
                否则人会把供应商账单上的总额填进金额栏。 */}
            {gstRegistered && (
                <div className="flex flex-wrap gap-4">
                    <div className="flex-1 min-w-[16rem]">
                        <label className="block text-sm font-medium mb-1">
                            {t('expense.form.taxCode')} <span className="text-red-600">*</span>
                        </label>
                        <select
                            name="tax_code"
                            value={effTaxCode}
                            onChange={(e) => { setTaxCodeTouched(true); setTaxCode(e.target.value) }}
                            className="w-full border border-gray-300 px-3 py-2 rounded"
                        >
                            <option value="">{t('expense.form.taxCodePick')}</option>
                            {taxCodes.map((c) => (
                                <option key={c.code} value={c.code}>
                                    {c.code} · {c.name_zh} / {c.name_en}
                                    {c.is_claimable ? '' : ` — ${t('expense.form.taxCodeBlocked')}`}
                                </option>
                            ))}
                        </select>
                        <p className="text-xs text-gray-500 mt-1">{t('expense.form.taxCodeNetHint')}</p>
                        {!taxCodeTouched && supplierDefaultTaxCode && (
                            <p className="text-xs text-gray-500 mt-1">
                                {t('expense.form.taxCodeFromSupplier', { code: supplierDefaultTaxCode })}
                            </p>
                        )}
                        {!effTaxCode && (
                            <p className="text-xs text-amber-700 mt-1">{t('expense.form.taxCodeNoDefault')}</p>
                        )}
                    </div>
                </div>
            )}

            <div className="flex flex-wrap gap-4">
                {/* 金额(必填,原币)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('expense.form.amount')} <span className="text-red-600">*</span>
                    </label>
                    <DecimalInput
                        name="amount"
                        required
                        value={amount}
                        onChange={setAmount}
                        className="w-36 border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                {/* 币种(默认 SGD)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('expense.form.currency')}</label>
                    <select
                        name="currency"
                        value={currency}
                        onChange={(e) => onCurrencyChange(e.target.value)}
                        className="border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="SGD">SGD</option>
                        <option value="USD">USD</option>
                    </select>
                </div>
                {/* FIN-0:外币按费用日行方卖出价(tt_sell)自动估值,当天没牌价直接拒 */}
                {currency !== baseCurrency && (
                    <p className="text-xs text-gray-500 self-end pb-2 max-w-56">{t('common.fxBoardRateHint')}</p>
                )}
                {/* 付款状态(默认挂账)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('expense.form.paymentStatus')}</label>
                    <select
                        name="payment_status"
                        value={paymentStatus}
                        onChange={(e) => setPaymentStatus(e.target.value === 'paid' ? 'paid' : 'unpaid')}
                        className="border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="unpaid">{t('expense.status.unpaid')}</option>
                        <option value="paid">{t('expense.status.paid')}</option>
                    </select>
                </div>
                {/* paid → 银行账户(默认随币种);unpaid → 供应商(必选)*/}
                {paymentStatus === 'paid' ? (
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('expense.form.bankAccount')}</label>
                        <select
                            name="bank_account"
                            value={bank}
                            onChange={(e) => setBank(e.target.value)}
                            className="border border-gray-300 px-3 py-2 rounded"
                        >
                            <option value="1000">{t('finance.bank.1000')}</option>
                            <option value="1010">{t('finance.bank.1010')}</option>
                        </select>
                    </div>
                ) : (
                    <div className="flex-1 min-w-[16rem]">
                        {/* PAYEE-1b:挂账的往来对象 —— 供应商【或】员工(报销)。
                            一个下拉、两组选项:一次选择就是一个不可分割的答案,
                            没有第二个字段能和它矛盾(库里那条 XOR 的表单形态)。
                            默认仍是"请选择",供应商在前 —— 既有用法一步没变。 */}
                        <label className="block text-sm font-medium mb-1">
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
                            className="w-full border border-gray-300 px-3 py-2 rounded"
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
                                suppliersEmptyLabel={t('suppliers.pickerEmptyGoods')} />
                        </select>
                    </div>
                )}
            </div>

            <div className="flex flex-wrap gap-4">
                {/* 收款方(paid 时可选的自由文本)*/}
                {paymentStatus === 'paid' && (
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('expense.form.payeeName')}</label>
                        <input
                            type="text"
                            name="payee_name"
                            className="w-64 border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>
                )}
                {/* 备注 */}
                <div className="flex-1 min-w-[12rem]">
                    <label className="block text-sm font-medium mb-1">{t('expense.form.notes')}</label>
                    <input
                        type="text"
                        name="notes"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
            </div>

            {/* ── FIN-22:资产明细(仅资本行)。购置日 = 上面的费用日;
                在役日可留空(未投用不折旧),折旧从【在役日】起算 ── */}
            {capital && (
                <div className="border border-gray-300 rounded p-4 space-y-3">
                    <h3 className="text-sm font-bold text-gray-700">{t('expense.form.assetSection')}</h3>

                    {/* ── EQP-1c-c(D1):两扇门,【由人明选】────────────────────
                        一个推断出来的模式,是一个没有人选过的模式。选错的代价不对称:
                        "新机器"用在一台已登记的机器上,会多出一张【撤不回来】的资产卡。 */}
                    <div className="rounded border border-blue-200 bg-blue-50 p-3 space-y-2">
                        {CAPITAL_MODES.map((m) => (
                            <label key={m} className="flex items-start gap-2 text-sm">
                                <input type="radio" name="capital_mode" value={m} className="mt-1"
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
                                <label className="block text-sm font-medium mb-1">
                                    {t('expense.form.existingAsset')} <span className="text-red-600">*</span>
                                </label>
                                <select name="asset_id" required value={assetId}
                                        onChange={(e) => { setAssetId(e.target.value); setPoLineId('') }}
                                        className="w-full border border-gray-300 px-3 py-2 rounded">
                                    <option value="" disabled>—</option>
                                    {assets.map((a) => (
                                        <option key={a.id} value={a.id}>{a.label}</option>
                                    ))}
                                </select>
                                {/* 【列表的判据照抄函数的两条拒绝】—— 已投用 / 已处置的机器不在这里,
                                    因为 record_expense 的追加支对它们按名拒。 */}
                                <p className="mt-1 text-xs text-gray-600">{t('expense.form.existingAssetHint')}</p>
                                {assets.length === 0 && (
                                    <p className="mt-1 text-xs text-amber-700">{t('expense.form.noAssetsAppendable')}</p>
                                )}
                            </div>

                            {/* ── D3:采购单行(可选)—— 三种"空"要说清是哪一种 ──── */}
                            <div>
                                <label className="block text-sm font-medium mb-1">
                                    {t('expense.form.poLine')}
                                </label>
                                <select name="purchase_order_line_id" value={poLineId}
                                        onChange={(e) => setPoLineId(e.target.value)}
                                        className="w-full border border-gray-300 px-3 py-2 rounded">
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
                                <p className="mt-1 text-xs text-gray-600">{t('expense.form.poLineHint')}</p>
                            </div>
                        </div>
                    )}

                    {/* ── 新建模式:这些字段属于【卡】,不属于这笔支出 ──────────
                        追加时【隐藏,不是禁用】—— 问题不适用,不是"你现在不能填"。 */}
                    {!isAppend && (
                    <div className="flex flex-wrap gap-4">
                        <div className="flex-1 min-w-[16rem]">
                            <label className="block text-sm font-medium mb-1">
                                {t('assets.colDescription')} <span className="text-red-600">*</span>
                            </label>
                            <input type="text" name="asset_description" required={capital && !isAppend}
                                   className="w-full border border-gray-300 px-3 py-2 rounded" />
                        </div>
                        <div>
                            <label className="block text-sm font-medium mb-1">{t('assets.colCategory')}</label>
                            <select name="asset_category" defaultValue="equipment"
                                    className="border border-gray-300 px-3 py-2 rounded">
                                <option value="equipment">{t('assets.category.equipment')}</option>
                                <option value="vehicle">{t('assets.category.vehicle')}</option>
                                <option value="office">{t('assets.category.office')}</option>
                                <option value="other">{t('assets.category.other')}</option>
                            </select>
                        </div>
                        <div>
                            <label className="block text-sm font-medium mb-1">{t('assets.colInService')}</label>
                            <input type="date" name="asset_in_service_date"
                                   className="border border-gray-300 px-3 py-2 rounded" />
                            <p className="text-xs text-gray-500 mt-1">{t('expense.form.inServiceHint')}</p>
                        </div>
                        <div>
                            <label className="block text-sm font-medium mb-1">
                                {t('assets.colLife')} <span className="text-red-600">*</span>
                            </label>
                            <input type="number" name="asset_life_months" min={1} step={1} required={capital && !isAppend}
                                   className="w-28 border border-gray-300 px-3 py-2 rounded" />
                        </div>
                        <div>
                            <label className="block text-sm font-medium mb-1">
                                {t('expense.form.residual', { ccy: baseCurrency })}
                            </label>
                            <DecimalInput name="asset_residual" value={residual} onChange={setResidual}
                                          className="w-32 border border-gray-300 px-3 py-2 rounded" />
                        </div>
                    </div>
                    )}
                </div>
            )}

            {/* 实时预览:USD 金额 + 将要生成的分录说明 */}
            <div className="bg-gray-50 rounded p-4 text-sm space-y-1">
                <div>
                    <span className="font-mono font-medium">
                        {amountSgd !== null
                            ? t('expense.amountPreview', { amount: formatMoneyBare(amountSgd, '同句 amountPreview 文案「金额:{amount} {ccy}」里的 {ccy}'), ccy: baseCurrency })
                            : t('common.fxBoardRateHint')}
                    </span>
                    {currency !== baseCurrency && amountValid && (
                        <span className="text-gray-500 ml-2 font-mono">
                            ({currency} {formatMoneyBare(amountNum, '同格内紧邻的 {currency} 前缀')})
                        </span>
                    )}
                </div>
                <p className="text-gray-500">
                    {paymentStatus === 'paid'
                        ? t('expense.previewPaid', {
                              account: previewAccount,
                              bank: t('finance.bank.' + bank),
                          })
                        : t('expense.previewUnpaid', { account: previewAccount })}
                </p>
            </div>

            <div className="flex gap-3 pt-2">
                <button
                    type="submit"
                    disabled={isPending}
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {isPending ? t('expense.form.submitting') : t('expense.form.submit')}
                </button>
                <Link
                    href="/finance/expenses"
                    className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                >
                    {t('common.cancel')}
                </Link>
            </div>
        </form>
    )
}
