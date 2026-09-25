'use server'

// 手工分录:并列数组表单字段(account_code[]/side[]/currency[]/amount_ccy[]/fx_rate[]/line_memo[])
// 组装 lines jsonb → rpc submit_journal_request。
// ★ APR-6(Tim 2026-09-25):一张手工凭证要 CFO 批准才过账。这里【提一张申请】,不再直接过账 ——
//   post_journal_entry 对 authenticated 已收回。提交时库按批准那一刻的同一支过账试跑一遍:借贷不平
//   (JOURNAL_UNBALANCED)、锁定期、1100 / 2000(JE_MANUAL_CONTROL_ACCOUNT)都在这里就按引擎原话回来。
//   审批开着:申请在等 CFO,回到凭证列表、定位到这张申请;关着:生下来就批准并过账,去那张分录。
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizeFinanceError } from '../../financeErrorCodes'

export type CreateEntryState = {
    error?: string
    fieldErrors?: Record<string, string>
}

export async function createManualEntry(
    _prevState: CreateEntryState,
    formData: FormData
): Promise<CreateEntryState> {
    const t = await getTranslations()
    // 本位币从库里取 —— 写死 'USD' 是 FIN-0 之前的残留,基准币行会被误判成需要汇率
    const base = await getBaseCurrency()

    const entry_date = (formData.get('entry_date') as string)?.trim() || ''
    const memo = (formData.get('memo') as string)?.trim() || ''

    const accountCodes = formData.getAll('account_code').map(String)
    const sides = formData.getAll('side').map(String)
    const currencies = formData.getAll('currency').map(String)
    const amounts = formData.getAll('amount_ccy').map(String)
    const fxRates = formData.getAll('fx_rate').map(String) // USD 行提交空 hidden,保持位置对齐
    const lineMemos = formData.getAll('line_memo').map(String)

    const fieldErrors: Record<string, string> = {}
    if (!entry_date || Number.isNaN(Date.parse(entry_date))) {
        fieldErrors.entry_date = t('finance.errDate')
    }
    if (!memo) {
        fieldErrors.memo = t('finance.errMemo')
    }

    // 行校验(与 DB 二道防线一致,先给友好的字段级错误)
    type Line = {
        account_code: string
        side: string
        currency: string
        amount_ccy: number
        fx_rate?: number
        line_memo?: string
    }
    const lines: Line[] = []
    for (let i = 0; i < accountCodes.length; i++) {
        const rowNo = i + 1
        if (!accountCodes[i]) {
            fieldErrors[`line_${i}`] = t('finance.errAccount', { row: rowNo })
            continue
        }
        const amount = Number(amounts[i])
        if (!amounts[i] || Number.isNaN(amount) || amount <= 0) {
            fieldErrors[`line_${i}`] = t('finance.errAmount', { row: rowNo })
            continue
        }
        const currency = currencies[i] || base
        let fx_rate: number | undefined
        if (currency !== base) {
            const fx = Number(fxRates[i])
            if (!fxRates[i] || Number.isNaN(fx) || fx <= 0) {
                fieldErrors[`line_${i}`] = t('finance.errors.FX_RATE_REQUIRED', { 0: currency })
                continue
            }
            fx_rate = fx
        }
        lines.push({
            account_code: accountCodes[i],
            side: sides[i] === 'credit' ? 'credit' : 'debit',
            currency,
            amount_ccy: amount,
            fx_rate,
            line_memo: lineMemos[i]?.trim() || undefined,
        })
    }
    if (lines.length < 2 && Object.keys(fieldErrors).length === 0) {
        fieldErrors.lines = t('finance.errMinLines')
    }

    if (Object.keys(fieldErrors).length > 0) {
        return { fieldErrors }
    }

    const supabase = await createClient()
    const { data, error } = await supabase.rpc('submit_journal_request', {
        p_entry_date: entry_date,
        p_memo: memo,
        p_lines: lines,
    })

    if (error) {
        return { error: await localizeFinanceError(error.message) }
    }

    const r = (data as { request_id?: string; status?: string; entry_id?: string | null } | null) ?? {}

    revalidatePath('/finance')
    revalidatePath('/finance/journal')
    revalidatePath('/')

    if (r.status === 'approved' && r.entry_id) {
        redirect(`/finance/journal/${r.entry_id}`)
    }
    redirect(r.request_id ? `/finance/journal#jr-${r.request_id}` : '/finance/journal')
}
