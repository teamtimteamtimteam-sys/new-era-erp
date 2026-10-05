'use client'

// app/components/finance/PaymentDateInput.tsx
// PAY-REQ-1(2026-09-23):付款日期那一格,两处共用 —— 收付款登记表(/finance/payments/new)
// 与付款申请的「付款」面板(/finance/payment-requests/[id])。
//
// 【为什么留着这一层】付款日是同一件事的同一格 —— 决定期间与汇率,必填,绝不替人填,而且不许晚于今天
// (AP-RECON-1 Batch B,Tim Q9:收付款是已经发生的事;晚于今天服务端按名拒 DOCUMENT_DATE_IN_FUTURE)。
// 这几条规矩写在一处,两处调用点就不会各记各的。
//
// 【DATE-PICK-1(2026-10-05)】原生日期框换成全站共用的 DatePicker。从前那道 onBlur 回写(React 不拿受控输入的 value
// 与活的 DOM 对账,一个"看起来填好了"的框可以提交出空串)随之删掉:选择器交出去的值只来自 React 的状态,
// 框里的字与它对不上时提交被拦(原生表单靠 setCustomValidity;按钮提交的面板靠 onInvalidChange)。
import { DatePicker } from '@/app/components/ui/date-picker'
import { businessToday } from '@/lib/format'

export function PaymentDateInput({
    name,
    value,
    onChange,
    onInvalidChange,
    className,
}: {
    name: string
    value: string
    onChange: (v: string) => void
    /** 不走原生表单提交的面板(付款申请的「付款」钮)用它关钮 */
    onInvalidChange?: (invalid: boolean) => void
    className?: string
}) {
    return (
        <DatePicker
            name={name}
            required
            max={businessToday()}
            value={value}
            onChange={onChange}
            onInvalidChange={onInvalidChange}
            className={className}
        />
    )
}
