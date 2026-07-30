'use server'

// 银行对账单导入:客户端已在浏览器里解析好 CSV(lib/bankCsv.ts),这里只
// (可选)存映射档 + 调 rpc import_bank_statement(报表、行、余额恒等式一个事务)。
// 余额/日期/金额的权威校验都在 DB 内,错误码本地化后展示;
// 成功跳报表详情,并把重叠期间 / 疑似重复的计数经 ?warn= 带过去(提示,不是错误)。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizeBankError } from '../../bankErrorCodes'
import type { BankMapping, ParsedBankRow } from '@/lib/bankCsv'

export type ImportStatementState = { error?: string }

export async function importStatement(
    _prevState: ImportStatementState,
    formData: FormData
): Promise<ImportStatementState> {
    const t = await getTranslations()

    const bankAccount = String(formData.get('bank_account') ?? '').trim()
    const periodStart = String(formData.get('period_start') ?? '').trim()
    const periodEnd = String(formData.get('period_end') ?? '').trim()
    const openingRaw = String(formData.get('opening_balance') ?? '').trim()
    const closingRaw = String(formData.get('closing_balance') ?? '').trim()
    const fileName = String(formData.get('file_name') ?? '').trim()
    const rowsJson = String(formData.get('rows_json') ?? '')
    const mappingJson = String(formData.get('mapping_json') ?? '')
    const saveMapping = formData.get('save_mapping') === 'on'
    const mappingName = String(formData.get('mapping_name') ?? '').trim()
    const selectedProfileId = String(formData.get('profile_id') ?? '').trim()
    const selectedProfileName = String(formData.get('profile_name') ?? '').trim()

    if (bankAccount !== '1000' && bankAccount !== '1010') {
        return { error: t('bank.errors.BANK_INVALID', { 0: bankAccount || '?' }) }
    }
    if (!periodStart || Number.isNaN(Date.parse(periodStart)) || !periodEnd || Number.isNaN(Date.parse(periodEnd))) {
        return { error: t('finance.errDate') }
    }
    const opening = Number(openingRaw)
    const closing = Number(closingRaw)
    if (!openingRaw || Number.isNaN(opening) || !closingRaw || Number.isNaN(closing)) {
        return { error: t('bank.errBalancesRequired') }
    }

    let rows: ParsedBankRow[] = []
    let mapping: BankMapping | null = null
    try {
        rows = JSON.parse(rowsJson) as ParsedBankRow[]
        mapping = mappingJson ? (JSON.parse(mappingJson) as BankMapping) : null
    } catch {
        return { error: t('bank.errors.NO_LINES') }
    }
    if (!Array.isArray(rows) || rows.length === 0) {
        return { error: t('bank.errors.NO_LINES') }
    }
    if (saveMapping && !mappingName) {
        return { error: t('bank.errMappingNameRequired') }
    }

    const supabase = await createClient()

    // 映射档:选中的档且名字没改 → 更新它的 mapping;否则新增一条。
    if (saveMapping && mapping) {
        if (selectedProfileId && selectedProfileName === mappingName) {
            const { error: upErr } = await supabase
                .from('bank_import_profiles')
                .update({ mapping })
                .eq('id', selectedProfileId)
            if (upErr) return { error: upErr.message }
        } else {
            const { error: insErr } = await supabase.from('bank_import_profiles').insert({
                bank_account_code: bankAccount,
                name: mappingName,
                mapping,
            })
            if (insErr) return { error: insErr.message }
        }
    }

    const { data, error } = await supabase.rpc('import_bank_statement', {
        p_bank_account: bankAccount,
        p_period_start: periodStart,
        p_period_end: periodEnd,
        p_opening: opening,
        p_closing: closing,
        // p_file_name 无 DEFAULT(3a 的函数签名),必传;选了文件才会有行,故这里总是非空
        p_file_name: fileName,
        p_lines: rows.map((r) => ({
            line_date: r.line_date,
            description: r.description,
            reference: r.reference,
            amount: r.amount,
        })),
    })

    if (error) {
        return { error: await localizeBankError(error.message) }
    }

    const result = data as {
        statement_id?: string
        overlapping_statements?: number
        possible_duplicates?: number
    } | null

    revalidatePath('/finance/bank')
    revalidatePath('/finance/bank/statements')

    if (result?.statement_id) {
        // 提示性计数经 query param 带到详情页(横幅,不是错误)
        const warn = new URLSearchParams()
        if (result.overlapping_statements) warn.set('overlap', String(result.overlapping_statements))
        if (result.possible_duplicates) warn.set('dups', String(result.possible_duplicates))
        const qs = warn.toString()
        redirect(`/finance/bank/statements/${result.statement_id}${qs ? `?${qs}` : ''}`)
    }
    redirect('/finance/bank/statements')
}
