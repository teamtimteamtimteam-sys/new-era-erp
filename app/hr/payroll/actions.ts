'use server'

// 薪资期间:导入(整批替换明细)/ 过账 / 撤销过账。
//
// 【本系统不算工资】数字全部来自外包服务商的月度报表,这里只负责录进来、校验自洽、
// 过一张分录。upsert_payroll_period 会再校验一遍每行的 net = gross − 员工CPF −
// 其它扣款(LINE_NOT_BALANCED);表单里的实时校验只是让人【在提交之前】就看见问题,
// DB 那道才是后墙。
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizeHrError } from '../hrErrorCodes'

export type PayrollFormState = { error?: string }

export type PayrollLineInput = {
    employee_id: string
    gross_pay: string
    employee_cpf: string
    employer_cpf: string
    other_deductions: string
    net_pay: string
}

const num = (s: string) => {
    const v = Number((s ?? '').trim())
    return Number.isFinite(v) ? v : 0
}

// 整行留空的员工【不提交】—— 当月没发工资的人(未入职/已离职/无薪假)不该
// 以一串 0 的形式进到工资单里,那会让"这个月发了几个人"这个数字失真。
function isBlank(l: PayrollLineInput): boolean {
    return ['gross_pay', 'employee_cpf', 'employer_cpf', 'other_deductions', 'net_pay'].every(
        (k) => ((l as unknown as Record<string, string>)[k] ?? '').trim() === ''
    )
}

export async function savePayrollPeriod(
    _prevState: PayrollFormState,
    formData: FormData
): Promise<PayrollFormState> {
    const t = await getTranslations()

    const periodMonth = String(formData.get('period_month') ?? '').trim() // 'YYYY-MM'
    const paymentDate = String(formData.get('payment_date') ?? '').trim()
    const currency = String(formData.get('currency') ?? await getBaseCurrency()).trim()
    const fxRaw = String(formData.get('fx_rate') ?? '').trim()
    const sourceNote = String(formData.get('source_note') ?? '').trim()
    const notes = String(formData.get('notes') ?? '').trim()

    if (!/^\d{4}-\d{2}$/.test(periodMonth)) {
        return { error: t('hr.errors.PERIOD_MONTH_INVALID', { 0: periodMonth || '?' }) }
    }
    if (!paymentDate || Number.isNaN(Date.parse(paymentDate))) return { error: t('finance.errDate') }
    const fx = Number(fxRaw)
    if (!fxRaw || Number.isNaN(fx) || fx <= 0) {
        return { error: t('hr.errors.FX_RATE_INVALID', { 0: fxRaw || '?' }) }
    }

    let lines: PayrollLineInput[]
    try {
        lines = JSON.parse(String(formData.get('lines_json') ?? '[]'))
    } catch {
        return { error: t('hr.errors.NO_LINES') }
    }
    const payload = lines
        .filter((l) => !isBlank(l))
        .map((l) => ({
            employee_id: l.employee_id,
            gross_pay: num(l.gross_pay),
            employer_cpf: num(l.employer_cpf),
            employee_cpf: num(l.employee_cpf),
            other_deductions: num(l.other_deductions),
            net_pay: num(l.net_pay),
        }))
    if (payload.length === 0) return { error: t('hr.errors.NO_LINES') }

    const supabase = await createClient()
    // p_source_note / p_notes 在 DB 签名里没有默认值,生成的类型因此标成 required
    // string —— 运行时传 null 完全合法(列可空),此处仅为通过类型检查而窄化断言。
    const { data, error } = await supabase.rpc('upsert_payroll_period', {
        p_period_month: `${periodMonth}-01`,
        p_payment_date: paymentDate,
        p_currency: currency,
        p_fx_rate: fx,
        p_source_note: (sourceNote || null) as unknown as string,
        p_notes: (notes || null) as unknown as string,
        p_lines: payload,
    })

    if (error) {
        return { error: await localizeHrError(error.message) }
    }

    const periodId = (data as { payroll_period_id?: string } | null)?.payroll_period_id
    revalidatePath('/hr/payroll')
    redirect(periodId ? `/hr/payroll/${periodId}` : '/hr/payroll')
}

export async function postPayroll(periodId: string): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('post_payroll_period', { p_payroll_period_id: periodId })
    if (error) return { error: await localizeHrError(error.message) }
    revalidatePath('/hr/payroll')
    revalidatePath(`/hr/payroll/${periodId}`)
    revalidatePath('/finance/journal')
    return {}
}

export async function unpostPayroll(periodId: string, reason: string): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('unpost_payroll_period', {
        p_id: periodId,
        p_reason: reason.trim(),
    })
    if (error) return { error: await localizeHrError(error.message) }
    revalidatePath('/hr/payroll')
    revalidatePath(`/hr/payroll/${periodId}`)
    revalidatePath('/finance/journal')
    return {}
}
