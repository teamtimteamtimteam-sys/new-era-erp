'use client'

// 银行对账单导入表单:单页分步(不做向导路由)。
// (a) 账户 + 映射档 → (b) 选 CSV(Papa.parse,浏览器端)→ (c) 列映射
// → (d) 实时预览(每次改动重跑 buildBankRows)→ (e) 期间/期初期末 + 余额校验
// → (f) 可选保存映射 → (g) 提交。
// 解析失败的行会拦住提交(必须先修);余额不符【不拦】—— DB 的
// STATEMENT_NOT_BALANCED 才是权威判定,这里的指示器只是早一步的反馈。
import { useActionState, useMemo, useState } from 'react'
import Link from 'next/link'
import Papa from 'papaparse'
import { importStatement, type ImportStatementState } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { formatAmount } from '@/lib/format'
import DecimalInput, { parseDecimal } from '@/app/components/forms/DecimalInput'
import {
    DATE_FORMATS,
    buildBankRows,
    type BankMapping,
    type DecimalSeparator,
    type ThousandsSeparator,
} from '@/lib/bankCsv'

const initialState: ImportStatementState = {}

export type ProfileOption = {
    id: string
    bank_account_code: string
    name: string
    mapping: BankMapping
}

const EMPTY_MAPPING: BankMapping = {
    date_column: '',
    description_column: '',
    reference_column: '',
    amount_mode: 'single',
    amount_column: '',
    debit_column: '',
    credit_column: '',
    date_format: 'YYYY-MM-DD',
    decimal_separator: '.',
    thousands_separator: ',',
    sign_convention: 'positive_in',
}

const round2 = (n: number) => Math.round(n * 100) / 100

export default function ImportStatementForm({ profiles }: { profiles: ProfileOption[] }) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(importStatement, initialState)

    const [bankAccount, setBankAccount] = useState('1010')
    const [profileId, setProfileId] = useState('')
    const [mapping, setMapping] = useState<BankMapping>(EMPTY_MAPPING)
    const [headers, setHeaders] = useState<string[]>([])
    const [csvRows, setCsvRows] = useState<Record<string, string>[]>([])
    const [fileName, setFileName] = useState('')
    const [periodStart, setPeriodStart] = useState('')
    const [periodEnd, setPeriodEnd] = useState('')
    const [opening, setOpening] = useState('')
    const [closing, setClosing] = useState('')
    const [saveMapping, setSaveMapping] = useState(false)
    const [mappingName, setMappingName] = useState('')
    // 用户手动改过期间后就不再被预览覆盖
    const [periodTouched, setPeriodTouched] = useState(false)

    const setM = (patch: Partial<BankMapping>) => setMapping((m) => ({ ...m, ...patch }))

    function onProfileChange(id: string) {
        setProfileId(id)
        const p = profiles.find((x) => x.id === id)
        if (p) {
            setMapping({ ...EMPTY_MAPPING, ...p.mapping })
            setMappingName(p.name)
            setBankAccount(p.bank_account_code)
        }
    }

    function onFile(file: File | undefined) {
        if (!file) return
        setFileName(file.name)
        Papa.parse<Record<string, string>>(file, {
            header: true,
            skipEmptyLines: true,
            complete: (res) => {
                setCsvRows(res.data ?? [])
                setHeaders((res.meta.fields ?? []).filter(Boolean))
                setPeriodTouched(false)
            },
        })
    }

    // 每次改动重算预览
    const parsed = useMemo(() => {
        if (!csvRows.length || !mapping.date_column) return { rows: [], errors: [] }
        if (mapping.amount_mode === 'single' && !mapping.amount_column) return { rows: [], errors: [] }
        if (mapping.amount_mode === 'debit_credit' && !mapping.debit_column && !mapping.credit_column) {
            return { rows: [], errors: [] }
        }
        return buildBankRows(csvRows, mapping)
    }, [csvRows, mapping])

    const sum = round2(parsed.rows.reduce((s, r) => s + r.amount, 0))
    const currency = bankAccount === '1000' ? 'SGD' : 'USD'

    // 期间自动填成解析日期的最小/最大值(用户改过之后不再覆盖)
    const dateBounds = useMemo(() => {
        if (!parsed.rows.length) return null
        const dates = parsed.rows.map((r) => r.line_date).sort()
        return { min: dates[0], max: dates[dates.length - 1] }
    }, [parsed.rows])
    const effStart = periodTouched ? periodStart : dateBounds?.min ?? periodStart
    const effEnd = periodTouched ? periodEnd : dateBounds?.max ?? periodEnd

    // 余额早期反馈(不拦提交;DB 的 STATEMENT_NOT_BALANCED 才是权威)
    const openingNum = parseDecimal(opening)
    const closingNum = parseDecimal(closing)
    const computed = openingNum !== null ? round2(openingNum + sum) : null
    const balanced =
        computed !== null && closingNum !== null && Math.round((computed - closingNum) * 100) === 0

    const hasErrors = parsed.errors.length > 0
    const canSubmit = parsed.rows.length > 0 && !hasErrors && !isPending

    const columnSelect = (
        value: string,
        onChange: (v: string) => void,
        opts: { allowNone?: boolean } = {}
    ) => (
        <select
            value={value}
            onChange={(e) => onChange(e.target.value)}
            className="w-full border border-gray-300 px-3 py-2 rounded"
        >
            <option value="">{opts.allowNone ? t('bank.none') : '—'}</option>
            {headers.map((h) => (
                <option key={h} value={h}>
                    {h}
                </option>
            ))}
        </select>
    )

    return (
        <form action={formAction} className="space-y-6">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}

            {/* 提交给 action 的实际载荷(解析结果与映射)*/}
            <input type="hidden" name="rows_json" value={JSON.stringify(parsed.rows)} />
            <input type="hidden" name="mapping_json" value={JSON.stringify(mapping)} />
            <input type="hidden" name="file_name" value={fileName} />
            <input type="hidden" name="profile_id" value={profileId} />
            <input
                type="hidden"
                name="profile_name"
                value={profiles.find((p) => p.id === profileId)?.name ?? ''}
            />
            <input type="hidden" name="period_start" value={effStart} />
            <input type="hidden" name="period_end" value={effEnd} />

            {/* (a) 账户 + 映射档 */}
            <div className="flex flex-wrap gap-4">
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('bank.bankAccount')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="bank_account"
                        value={bankAccount}
                        onChange={(e) => setBankAccount(e.target.value)}
                        className="border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="1010">{t('finance.bank.1010')}</option>
                        <option value="1000">{t('finance.bank.1000')}</option>
                    </select>
                </div>
                <div className="min-w-[16rem]">
                    <label className="block text-sm font-medium mb-1">{t('bank.profile')}</label>
                    <select
                        value={profileId}
                        onChange={(e) => onProfileChange(e.target.value)}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="">{t('bank.profileNew')}</option>
                        {profiles.map((p) => (
                            <option key={p.id} value={p.id}>
                                {p.name} ({p.bank_account_code})
                            </option>
                        ))}
                    </select>
                </div>
                {/* (b) 文件 */}
                <div className="flex-1 min-w-[16rem]">
                    <label className="block text-sm font-medium mb-1">
                        {t('bank.file')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="file"
                        accept=".csv,text/csv"
                        onChange={(e) => onFile(e.target.files?.[0])}
                        className="w-full text-sm file:mr-3 file:rounded file:border-0 file:bg-blue-600 file:px-4 file:py-2 file:text-white hover:file:bg-blue-700"
                    />
                    {headers.length > 0 && (
                        <p className="text-xs text-gray-500 mt-1">
                            {t('bank.detectedColumns', { n: headers.length })} ·{' '}
                            {t('finance.recordCount', { count: csvRows.length })}
                        </p>
                    )}
                </div>
            </div>

            {/* (c) 列映射 */}
            {headers.length > 0 && (
                <div className="border border-gray-300 rounded p-4 space-y-4">
                    <div className="grid gap-4 md:grid-cols-3">
                        <div>
                            <label className="block text-sm font-medium mb-1">
                                {t('bank.dateColumn')} <span className="text-red-600">*</span>
                            </label>
                            {columnSelect(mapping.date_column, (v) => setM({ date_column: v }))}
                        </div>
                        <div>
                            <label className="block text-sm font-medium mb-1">{t('bank.descriptionColumn')}</label>
                            {columnSelect(mapping.description_column, (v) => setM({ description_column: v }))}
                        </div>
                        <div>
                            <label className="block text-sm font-medium mb-1">{t('bank.referenceColumn')}</label>
                            {columnSelect(mapping.reference_column, (v) => setM({ reference_column: v }), {
                                allowNone: true,
                            })}
                        </div>
                    </div>

                    <div>
                        <span className="block text-sm font-medium mb-1">{t('bank.amountMode')}</span>
                        <label className="mr-4 text-sm">
                            <input
                                type="radio"
                                checked={mapping.amount_mode === 'single'}
                                onChange={() => setM({ amount_mode: 'single' })}
                                className="mr-1"
                            />
                            {t('bank.amountModeSingle')}
                        </label>
                        <label className="text-sm">
                            <input
                                type="radio"
                                checked={mapping.amount_mode === 'debit_credit'}
                                onChange={() => setM({ amount_mode: 'debit_credit' })}
                                className="mr-1"
                            />
                            {t('bank.amountModeDebitCredit')}
                        </label>
                    </div>

                    {mapping.amount_mode === 'single' ? (
                        <div className="grid gap-4 md:grid-cols-2">
                            <div>
                                <label className="block text-sm font-medium mb-1">
                                    {t('bank.amountColumn')} <span className="text-red-600">*</span>
                                </label>
                                {columnSelect(mapping.amount_column, (v) => setM({ amount_column: v }))}
                            </div>
                            <div>
                                <span className="block text-sm font-medium mb-1">{t('bank.amountMode')}</span>
                                <label className="mr-4 text-sm">
                                    <input
                                        type="radio"
                                        checked={mapping.sign_convention === 'positive_in'}
                                        onChange={() => setM({ sign_convention: 'positive_in' })}
                                        className="mr-1"
                                    />
                                    {t('bank.signPositiveIn')}
                                </label>
                                <label className="text-sm">
                                    <input
                                        type="radio"
                                        checked={mapping.sign_convention === 'positive_out'}
                                        onChange={() => setM({ sign_convention: 'positive_out' })}
                                        className="mr-1"
                                    />
                                    {t('bank.signPositiveOut')}
                                </label>
                            </div>
                        </div>
                    ) : (
                        <div className="grid gap-4 md:grid-cols-2">
                            {/* 银行视角:Debit = 取款(钱出),Credit = 存款(钱进)*/}
                            <div>
                                <label className="block text-sm font-medium mb-1">{t('bank.debitColumn')}</label>
                                {columnSelect(mapping.debit_column, (v) => setM({ debit_column: v }))}
                            </div>
                            <div>
                                <label className="block text-sm font-medium mb-1">{t('bank.creditColumn')}</label>
                                {columnSelect(mapping.credit_column, (v) => setM({ credit_column: v }))}
                            </div>
                            <p className="md:col-span-2 text-xs text-gray-500">{t('bank.debitCreditHint')}</p>
                        </div>
                    )}

                    <div className="grid gap-4 md:grid-cols-3">
                        <div>
                            <label className="block text-sm font-medium mb-1">{t('bank.dateFormat')}</label>
                            <select
                                value={mapping.date_format}
                                onChange={(e) => setM({ date_format: e.target.value })}
                                className="w-full border border-gray-300 px-3 py-2 rounded"
                            >
                                {DATE_FORMATS.map((f) => (
                                    <option key={f} value={f}>
                                        {f}
                                    </option>
                                ))}
                            </select>
                        </div>
                        <div>
                            <label className="block text-sm font-medium mb-1">{t('bank.decimalSeparator')}</label>
                            <select
                                value={mapping.decimal_separator}
                                onChange={(e) =>
                                    setM({ decimal_separator: e.target.value as DecimalSeparator })
                                }
                                className="w-full border border-gray-300 px-3 py-2 rounded"
                            >
                                <option value=".">.</option>
                                <option value=",">,</option>
                            </select>
                        </div>
                        <div>
                            <label className="block text-sm font-medium mb-1">{t('bank.thousandsSeparator')}</label>
                            <select
                                value={mapping.thousands_separator}
                                onChange={(e) =>
                                    setM({ thousands_separator: e.target.value as ThousandsSeparator })
                                }
                                className="w-full border border-gray-300 px-3 py-2 rounded"
                            >
                                <option value=",">,</option>
                                <option value=".">.</option>
                                <option value=" ">␣</option>
                                <option value="none">{t('bank.sepNone')}</option>
                            </select>
                        </div>
                    </div>
                </div>
            )}

            {/* (d) 预览 */}
            {csvRows.length > 0 && (
                <div>
                    <h2 className="text-lg font-semibold mb-2">{t('bank.preview')}</h2>
                    <p className="text-sm text-gray-600 mb-2">
                        {t('bank.parsedSummary', {
                            ok: parsed.rows.length,
                            failed: parsed.errors.length,
                            total: csvRows.length,
                        })}
                        {parsed.rows.length > 0 && (
                            <span className="ml-3 font-mono">Σ {formatAmount(sum, currency)}</span>
                        )}
                    </p>

                    {hasErrors && (
                        <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-3 text-sm">
                            <p className="font-medium mb-1">{t('bank.fixErrors')}</p>
                            <ul className="list-disc ml-5">
                                {parsed.errors.slice(0, 10).map((e) => (
                                    <li key={e.line_no}>
                                        {t('bank.colLineNo')} {e.line_no}: {t('bank.parseError.' + e.reason)}
                                    </li>
                                ))}
                            </ul>
                        </div>
                    )}

                    {parsed.rows.length > 0 && (
                        <table className="w-full border-collapse border border-gray-300">
                            <thead className="bg-gray-100">
                                <tr>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('bank.colLineNo')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('bank.colDate')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('bank.colDescription')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('bank.colReference')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-right">{t('bank.colAmount')}</th>
                                </tr>
                            </thead>
                            <tbody>
                                {parsed.rows.slice(0, 20).map((r) => (
                                    <tr key={r.line_no}>
                                        <td className="border border-gray-300 px-3 py-1 text-sm text-gray-500">{r.line_no}</td>
                                        <td className="border border-gray-300 px-3 py-1 text-sm">{r.line_date}</td>
                                        <td className="border border-gray-300 px-3 py-1 text-sm">{r.description ?? '—'}</td>
                                        <td className="border border-gray-300 px-3 py-1 text-sm font-mono">{r.reference ?? '—'}</td>
                                        <td
                                            className={
                                                'border border-gray-300 px-3 py-1 text-right font-mono text-sm ' +
                                                (r.amount < 0 ? 'text-red-600' : '')
                                            }
                                        >
                                            {formatAmount(r.amount, null)}
                                        </td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    )}
                </div>
            )}

            {/* (e) 期间 + 期初期末 + 余额校验 */}
            <div className="flex flex-wrap gap-4">
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('bank.periodStart')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="date"
                        value={effStart}
                        onChange={(e) => {
                            setPeriodTouched(true)
                            setPeriodStart(e.target.value)
                        }}
                        className="border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('bank.periodEnd')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="date"
                        value={effEnd}
                        onChange={(e) => {
                            setPeriodTouched(true)
                            setPeriodEnd(e.target.value)
                        }}
                        className="border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('bank.openingBalance')} <span className="text-red-600">*</span>
                    </label>
                    {/* 银行余额可以是负数(透支),故 allowNegative */}
                    <DecimalInput
                        name="opening_balance"
                        required
                        allowNegative
                        value={opening}
                        onChange={setOpening}
                        className="w-40 border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('bank.enteredClosing')} <span className="text-red-600">*</span>
                    </label>
                    <DecimalInput
                        name="closing_balance"
                        required
                        allowNegative
                        value={closing}
                        onChange={setClosing}
                        className="w-40 border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
            </div>

            {/* 两个余额都填了才给反馈(与改造前一致)*/}
            {computed !== null && closingNum !== null && (
                <p className={'text-sm ' + (balanced ? 'text-green-700' : 'text-red-600')}>
                    {balanced
                        ? `✓ ${t('bank.balanceOk')}`
                        : `✗ ${t('bank.balanceMismatch', {
                              computed: formatAmount(computed, currency),
                              entered: formatAmount(closingNum, currency),
                              delta: formatAmount(round2(computed - closingNum), currency),
                          })}`}
                </p>
            )}

            {/* (f) 保存映射 */}
            <div className="flex flex-wrap items-end gap-4">
                <label className="text-sm">
                    <input
                        type="checkbox"
                        name="save_mapping"
                        checked={saveMapping}
                        onChange={(e) => setSaveMapping(e.target.checked)}
                        className="mr-2"
                    />
                    {t('bank.saveMapping')}
                </label>
                {saveMapping && (
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('bank.mappingName')} <span className="text-red-600">*</span>
                        </label>
                        <input
                            type="text"
                            name="mapping_name"
                            required
                            value={mappingName}
                            onChange={(e) => setMappingName(e.target.value)}
                            className="w-64 border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>
                )}
            </div>

            {/* (g) 提交 */}
            <div className="flex gap-3 pt-2">
                <button
                    type="submit"
                    disabled={!canSubmit}
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {isPending ? t('bank.submitting') : t('bank.submit')}
                </button>
                <Link href="/finance/bank" className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50">
                    {t('common.cancel')}
                </Link>
            </div>
        </form>
    )
}
