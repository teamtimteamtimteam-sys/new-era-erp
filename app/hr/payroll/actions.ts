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
    // ★★ DRAFT-6 / Tim 的 Q9(2026-09-21):**读不懂的桥按名拒,而且是【它自己】那一句。**
    //   此前这里与下面「一行都没填」共用 `NO_LINES`,于是两件完全不同的事说同一句话:
    //     · 「一个员工都没填」—— 操作员做的事,改法是去填;
    //     · 「这次提交没有被读懂」—— 这一页坏了,改法是刷新 / 报告。
    //   ☞ 共用一句话会让第二种伪装成第一种,于是人去重填一张他其实已经填好的表。
    //   ☞ 这正是 DRAFT-5 §2.3 为五张表各发一条「读不懂」文案的同一条理由
    //     (`docs/handbacks/DRAFT-5.md`:「空集在每一张表上变成的是【不同的谎】」)。
    try {
        lines = JSON.parse(String(formData.get('lines_json') ?? '[]'))
    } catch {
        return { error: t('hr.errors.LINES_UNREADABLE') }
    }
    // ★ 而「不是一个数组」与「解析不了」是同一件事 —— 桥交出来的形状不对,
    //   底下那句 `.filter` 会当场抛,而抛出来的样子不是一句拒绝。
    if (!Array.isArray(lines)) return { error: t('hr.errors.LINES_UNREADABLE') }
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

// ★ PAYROLL-APR-1(Tim 的矩阵 §5,2026-09-24):工资过账与撤销要 CFO 批准,批之前什么都不过账。
//   提申请 → CFO 批 / 驳 → 财务执行(过账 / 撤销过账)。判据一条都不在这里:谁能批(二级审批角色、
//   不是提单人,按人认)、什么状态能做什么、批的数变没变 —— 全部由库裁,拒绝经 localizeHrError 说成人话。
//   服务端只独立再挡两道:撤销要理由、驳回要理由(对话框已经挡了空白,库里还有一道)。
function refreshPayroll(periodId: string) {
    revalidatePath('/hr/payroll')
    revalidatePath(`/hr/payroll/${periodId}`)
    revalidatePath('/finance/journal')
    revalidatePath('/finance/payroll-payments')
    revalidatePath('/')
}

export async function submitPayrollRequest(
    periodId: string, kind: 'post' | 'reversal', notes: string
): Promise<{ error?: string }> {
    if (kind === 'reversal' && notes.trim() === '') {
        return { error: (await getTranslations())('hr.payrollRequest.reasonRequired') }
    }
    const supabase = await createClient()
    const { error } = await supabase.rpc('submit_payroll_request', {
        p_payroll_period_id: periodId,
        p_kind: kind,
        p_notes: notes.trim() || undefined,
    })
    if (error) return { error: await localizeHrError(error.message) }
    refreshPayroll(periodId)
    return {}
}

export async function decidePayrollRequest(
    periodId: string, requestId: string, approve: boolean, notes: string
): Promise<{ error?: string }> {
    if (!approve && notes.trim() === '') {
        return { error: (await getTranslations())('hr.payrollRequest.rejectReasonRequired') }
    }
    const supabase = await createClient()
    const { error } = await supabase.rpc('decide_payroll_request', {
        p_request_id: requestId,
        p_approve: approve,
        p_notes: notes.trim() || undefined,
    })
    if (error) return { error: await localizeHrError(error.message) }
    refreshPayroll(periodId)
    return {}
}

export async function withdrawPayrollRequest(periodId: string, requestId: string): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('withdraw_payroll_request', { p_request_id: requestId })
    if (error) return { error: await localizeHrError(error.message) }
    refreshPayroll(periodId)
    return {}
}

// 执行:过账要一张【这一期、kind = post】的已批申请;撤销要一张 kind = reversal 的 ——
// 撤销的理由取申请上那一句(CFO 批的就是它),所以这里不再收理由。
export async function postPayroll(periodId: string): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('post_payroll_period', { p_payroll_period_id: periodId })
    if (error) return { error: await localizeHrError(error.message) }
    refreshPayroll(periodId)
    return {}
}

export async function unpostPayroll(periodId: string): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('unpost_payroll_period', { p_id: periodId })
    if (error) return { error: await localizeHrError(error.message) }
    refreshPayroll(periodId)
    return {}
}
