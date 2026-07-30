// lib/bankCsv.ts
// 银行 CSV 的解析助手(普通模块,客户端可用;导入页在浏览器里跑 Papa.parse
// 再用这里的函数把原始行转成 import_bank_statement 要的行数组)。
// 原则:不做静默猜测 —— 解析不出来就返回 null,由调用方计入错误清单并拦住导入。
//
// 【3c 更正】借贷分列的方向按【银行视角】:对账单上的 Debit = 取款(钱出),
// Credit = 存款(钱进)。3b 初版按会计视角写成 debit − credit,方向是反的,
// 现改为 credit − debit。BankMapping 的字段名保持 debit_column / credit_column
// 不变(已存的映射档仍然有效),变的只是算术方向与界面标签。

// 支持的日期格式。标签在 i18n 里按值取,这里只存格式本身。
export const DATE_FORMATS = [
    'YYYY-MM-DD',
    'DD/MM/YYYY',
    'MM/DD/YYYY',
    'DD-MM-YYYY',
    'DD.MM.YYYY',
    'DD MMM YYYY',
    'DD MMM YY',
] as const

export type DateFormat = (typeof DATE_FORMATS)[number]

const MONTHS_EN = [
    'jan', 'feb', 'mar', 'apr', 'may', 'jun',
    'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
]

// 两位年份 → 2000+YY(银行流水不会出现 19xx)
function expandYear(y: string): number | null {
    if (/^\d{4}$/.test(y)) return Number(y)
    if (/^\d{2}$/.test(y)) return 2000 + Number(y)
    return null
}

function monthFromName(raw: string): number | null {
    const idx = MONTHS_EN.indexOf(raw.toLowerCase().slice(0, 3))
    return idx === -1 ? null : idx + 1
}

// 真实存在性校验:月末溢出(2 月 30 日之类)必须判为无法解析,而不是被 Date 滚动到下个月。
function toIsoIfValid(year: number, month: number, day: number): string | null {
    if (month < 1 || month > 12 || day < 1 || day > 31) return null
    const d = new Date(Date.UTC(year, month - 1, day))
    if (
        d.getUTCFullYear() !== year ||
        d.getUTCMonth() !== month - 1 ||
        d.getUTCDate() !== day
    ) {
        return null
    }
    const mm = String(month).padStart(2, '0')
    const dd = String(day).padStart(2, '0')
    return `${year}-${mm}-${dd}`
}

// 按指定格式解析日期 → 'YYYY-MM-DD';解析不了返回 null(不猜)。
export function parseBankDate(raw: string, format: string): string | null {
    const s = (raw ?? '').trim()
    if (!s) return null

    switch (format) {
        case 'YYYY-MM-DD': {
            const m = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/)
            if (!m) return null
            return toIsoIfValid(Number(m[1]), Number(m[2]), Number(m[3]))
        }
        case 'DD/MM/YYYY': {
            const m = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{2}|\d{4})$/)
            if (!m) return null
            const y = expandYear(m[3])
            return y === null ? null : toIsoIfValid(y, Number(m[2]), Number(m[1]))
        }
        case 'MM/DD/YYYY': {
            const m = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{2}|\d{4})$/)
            if (!m) return null
            const y = expandYear(m[3])
            return y === null ? null : toIsoIfValid(y, Number(m[1]), Number(m[2]))
        }
        case 'DD-MM-YYYY': {
            const m = s.match(/^(\d{1,2})-(\d{1,2})-(\d{2}|\d{4})$/)
            if (!m) return null
            const y = expandYear(m[3])
            return y === null ? null : toIsoIfValid(y, Number(m[2]), Number(m[1]))
        }
        case 'DD.MM.YYYY': {
            const m = s.match(/^(\d{1,2})\.(\d{1,2})\.(\d{2}|\d{4})$/)
            if (!m) return null
            const y = expandYear(m[3])
            return y === null ? null : toIsoIfValid(y, Number(m[2]), Number(m[1]))
        }
        case 'DD MMM YYYY':
        case 'DD MMM YY': {
            // 月份名不区分大小写,三字母前缀即可(Jan / JAN / January 都认)
            const m = s.match(/^(\d{1,2})[\s-]+([A-Za-z]{3,})[\s-]+(\d{2}|\d{4})$/)
            if (!m) return null
            const month = monthFromName(m[2])
            const y = expandYear(m[3])
            if (month === null || y === null) return null
            return toIsoIfValid(y, month, Number(m[1]))
        }
        default:
            return null
    }
}

export type DecimalSeparator = '.' | ','
export type ThousandsSeparator = ',' | '.' | ' ' | 'none'

// 解析金额:去货币符号/空白/千分位,认前后负号与括号负数 "(1,234.56)"。
// 剩下的不是纯数字就返回 null(不猜)。
export function parseBankAmount(
    raw: string,
    decimalSep: DecimalSeparator,
    thousandsSep: ThousandsSeparator
): number | null {
    let s = (raw ?? '').trim()
    if (!s) return null

    // 括号负数(会计写法)
    let negative = false
    if (/^\(.*\)$/.test(s)) {
        negative = true
        s = s.slice(1, -1).trim()
    }

    // 去货币符号与各种空白(含不换行空格);保留数字、分隔符与正负号
    s = s.replace(/[\s  ]/g, '')
    s = s.replace(/[^\d.,'\-+]/g, '')

    // 前置/后置负号(有些银行把负号放在末尾)
    if (s.startsWith('-')) {
        negative = !negative
        s = s.slice(1)
    } else if (s.endsWith('-')) {
        negative = !negative
        s = s.slice(0, -1)
    }
    if (s.startsWith('+')) s = s.slice(1)

    // 去千分位(空格已在上面统一去掉);撇号千分位一并容忍
    if (thousandsSep !== 'none') {
        const sep = thousandsSep === ' ' ? '' : thousandsSep
        if (sep) s = s.split(sep).join('')
    }
    s = s.split("'").join('')

    // 小数点统一成 '.'
    if (decimalSep === ',') {
        s = s.replace(',', '.')
    }

    // 此刻只允许一个小数点 + 数字
    if (!/^\d*\.?\d+$/.test(s) && !/^\d+\.?\d*$/.test(s)) return null
    const n = Number(s)
    if (!Number.isFinite(n)) return null

    return negative ? -n : n
}

export type BankMapping = {
    date_column: string
    description_column: string
    reference_column: string
    amount_mode: 'single' | 'debit_credit'
    amount_column: string
    debit_column: string
    credit_column: string
    date_format: string
    decimal_separator: DecimalSeparator
    thousands_separator: ThousandsSeparator
    sign_convention: 'positive_in' | 'positive_out'
}

export type ParsedBankRow = {
    line_no: number
    line_date: string
    description: string | null
    reference: string | null
    amount: number
}

export type ParseError = { line_no: number; reason: string }

// 把 Papa.parse 的原始行转成待导入行。
// line_no 按【原始 CSV 顺序】1-based —— 错误信息要能指回用户文件里的那一行。
// 符号约定:结果一律"正 = 入账",与 bank_statement_lines.amount 的约定一致。
//   single 模式:按列取值,sign_convention='positive_out' 时取反;
//   debit_credit 模式:amount = (credit || 0) − (debit || 0) —— 按银行视角,
//   Credit/存款列使余额增加,Debit/取款列使余额减少。
// 金额解析为 0 或日期解析失败的行进 errors,不进 rows。
export function buildBankRows(
    csvRows: Record<string, string>[],
    mapping: BankMapping
): { rows: ParsedBankRow[]; errors: ParseError[] } {
    const rows: ParsedBankRow[] = []
    const errors: ParseError[] = []

    csvRows.forEach((raw, i) => {
        const lineNo = i + 1

        const isoDate = parseBankDate(raw[mapping.date_column] ?? '', mapping.date_format)
        if (!isoDate) {
            errors.push({ line_no: lineNo, reason: 'date' })
            return
        }

        let amount: number | null
        if (mapping.amount_mode === 'single') {
            amount = parseBankAmount(
                raw[mapping.amount_column] ?? '',
                mapping.decimal_separator,
                mapping.thousands_separator
            )
            if (amount === null) {
                errors.push({ line_no: lineNo, reason: 'amount' })
                return
            }
            if (mapping.sign_convention === 'positive_out') amount = -amount
        } else {
            // 借贷分列:空单元格当 0(银行通常只填一侧)
            const debitRaw = (raw[mapping.debit_column] ?? '').trim()
            const creditRaw = (raw[mapping.credit_column] ?? '').trim()
            const debit = debitRaw
                ? parseBankAmount(debitRaw, mapping.decimal_separator, mapping.thousands_separator)
                : 0
            const credit = creditRaw
                ? parseBankAmount(creditRaw, mapping.decimal_separator, mapping.thousands_separator)
                : 0
            if (debit === null || credit === null) {
                errors.push({ line_no: lineNo, reason: 'amount' })
                return
            }
            // 银行视角:Credit(存款)进账为正,Debit(取款)出账为负
            amount = credit - debit
        }

        // 0 金额没有对账意义(DB 也有 amount <> 0 的 CHECK)
        if (!amount || Math.round(amount * 100) === 0) {
            errors.push({ line_no: lineNo, reason: 'zero' })
            return
        }

        rows.push({
            line_no: lineNo,
            line_date: isoDate,
            description: (raw[mapping.description_column] ?? '').trim() || null,
            reference: mapping.reference_column
                ? (raw[mapping.reference_column] ?? '').trim() || null
                : null,
            amount: Math.round(amount * 100) / 100,
        })
    })

    return { rows, errors }
}
