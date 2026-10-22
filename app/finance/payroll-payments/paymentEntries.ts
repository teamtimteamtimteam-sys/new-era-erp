// PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22):payroll_payment_entries() 回的一行 —— 付薪页上的「每一次付款」与工资期页上那张付款冲销申请
// 读的是同一支(db/functions/payroll_payment_entries.sql),这里只是它的形状。
export type PayrollPaymentEntry = {
    entry_id: string
    code: string
    entry_date: string
    status: string
    payroll_period_id: string
    kind: 'salary' | 'cpf' | 'deductions'
    /** 贷方银行合计,本位币;不持 data.view_pay → null(屏幕印「受限」,不印 0.00) */
    amount: number | null
    /** 工资付款付过几行(含净额为零的行);CPF / 扣款为 null */
    lines_paid: number | null
    /** 银行行配上了哪一张对账单(没配为 null)—— 配着就不冲(Q6) */
    bank_statement: string | null
    bank_statement_status: 'open' | 'reconciled' | null
    /** 这一期挂着的那一张未了结申请(任何一种;一期同时只挂一张) */
    open_request: { id: string; label: string; kind: string; status: string; target_entry_id: string | null } | null
}
