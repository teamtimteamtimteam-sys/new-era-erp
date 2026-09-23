'use client'

// app/hr/employees/InitialSalaryForm.tsx
// ROLE-1(Tim 的矩阵 · Q7,2026-09-23):一个人的【第一份】月薪,由财务录一次。
//
// 【为什么需要它】对 employees.monthly_salary 的直连写从 ROLE-1 起一律拒绝
// (guard_employee_salary_write):调薪只走绩效评估,由 CFO 批。而线上六个人的
// 月薪全是空的 —— 没有这扇门,就再也没有任何一条路录得下第一份工资。
// 它只在月薪【还是空的】时出现;有了之后,这一格只说"之后的变动走评估"。
//
// 【两道,缺一不可】生效日决定这份工资从哪个工资期起算,所以:
//   ① 金额或生效日为空时按钮按不动;
//   ② set_initial_salary 自己拒空(SALARY_EFFECTIVE_DATE_REQUIRED)—— 绕开界面也过不去。
// 生效日【不给默认值】(AGENTS.md「Dates and amounts that decide a period」)。
//
// ★【为什么是一张月份下拉,而不是一个日期框】check-date-format 的第三维:原生
//   <input type="date|month">【只许减少】(它们按操作系统 locale 渲染,CSS 与 JS 都够不到)。
//   工资按【整月】的工资期算,set_initial_salary 判"落在已过账的工资期里"也是按月判 ——
//   所以这里要的本来就是【从哪一个工资月起算】,生效日取那个月的 1 号。
//   月份清单由页面按"入职月到下两个月"算好传进来,不在这里编。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { setInitialSalary } from './actions'

export default function InitialSalaryForm({
    employeeId,
    currency,
    months,
}: {
    employeeId: string
    currency: string
    /** 可选的起算月:value = 那个月的 1 号(YYYY-MM-01),label = 按界面语言写好的月份名 */
    months: { value: string; label: string }[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const [amount, setAmount] = useState('')
    const [effective, setEffective] = useState('')
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)

    const ready = amount.trim() !== '' && effective !== ''

    return (
        <div className="mb-6 rounded border border-gray-200 p-4">
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">
                    {error}
                </div>
            )}
            <p className="text-sm mb-3">{t('hr.initialSalary.hint')}</p>
            <div className="flex flex-wrap gap-3 items-end">
                <label className="block">
                    {t('hr.initialSalary.amount', { ccy: currency })}
                    <input
                        type="number"
                        min="0"
                        step="0.01"
                        value={amount}
                        onChange={(e) => setAmount(e.target.value)}
                        className={`${CONTROL_INPUT} mt-1 block w-40`}
                    />
                </label>
                <label className="block">
                    {t('hr.initialSalary.effectiveDate')}
                    <select
                        value={effective}
                        onChange={(e) => setEffective(e.target.value)}
                        className={`${CONTROL_INPUT} mt-1 block`}
                    >
                        <option value="">{t('hr.initialSalary.pickMonth')}</option>
                        {months.map((m) => (
                            <option key={m.value} value={m.value}>{m.label}</option>
                        ))}
                    </select>
                </label>
                <Button
                    type="button"
                    disabled={pending || !ready}
                    onClick={() =>
                        startTransition(async () => {
                            setError(null)
                            const r = await setInitialSalary(employeeId, amount, effective)
                            if (r.error) setError(r.error)
                            else router.refresh()
                        })
                    }
                >
                    {pending ? t('common.saving') : t('hr.initialSalary.submit')}
                </Button>
            </div>
        </div>
    )
}
