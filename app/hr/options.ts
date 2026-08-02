// app/hr/options.ts
// HR 各下拉的规范值(与 DB 的 CHECK 集合一一对应;加值时两边一起改)。
// value = 存库的规范值;labelKey = i18n 显示键。

export type Option = { value: string; labelKey: string }

export const EMPLOYMENT_TYPE_OPTIONS: Option[] = [
    { value: 'full_time', labelKey: 'hr.employmentType.full_time' },
    { value: 'part_time', labelKey: 'hr.employmentType.part_time' },
    { value: 'internship', labelKey: 'hr.employmentType.internship' },
    { value: 'contract', labelKey: 'hr.employmentType.contract' },
]

export const WORK_CATEGORY_OPTIONS: Option[] = [
    { value: 'office', labelKey: 'hr.workCategory.office' },
    { value: 'shopfloor', labelKey: 'hr.workCategory.shopfloor' },
]

export const EMPLOYMENT_STATUS_OPTIONS: Option[] = [
    { value: 'probation', labelKey: 'hr.employmentStatus.probation' },
    { value: 'active', labelKey: 'hr.employmentStatus.active' },
    { value: 'notice', labelKey: 'hr.employmentStatus.notice' },
    { value: 'separated', labelKey: 'hr.employmentStatus.separated' },
]

export const RESIDENCY_OPTIONS: Option[] = [
    { value: 'citizen', labelKey: 'hr.residency.citizen' },
    { value: 'pr', labelKey: 'hr.residency.pr' },
    { value: 'work_pass', labelKey: 'hr.residency.work_pass' },
]

export const SEPARATION_TYPE_OPTIONS: Option[] = [
    { value: 'resignation', labelKey: 'hr.separationType.resignation' },
    { value: 'retirement', labelKey: 'hr.separationType.retirement' },
    { value: 'redundancy', labelKey: 'hr.separationType.redundancy' },
    { value: 'dismissal', labelKey: 'hr.separationType.dismissal' },
    { value: 'contract_expiry', labelKey: 'hr.separationType.contract_expiry' },
]

export const TRAINING_CATEGORY_OPTIONS: Option[] = [
    { value: 'induction', labelKey: 'hr.trainingCategory.induction' },
    { value: 'safety', labelKey: 'hr.trainingCategory.safety' },
    { value: 'compliance', labelKey: 'hr.trainingCategory.compliance' },
    { value: 'cybersecurity', labelKey: 'hr.trainingCategory.cybersecurity' },
    { value: 'technical', labelKey: 'hr.trainingCategory.technical' },
    { value: 'leadership', labelKey: 'hr.trainingCategory.leadership' },
    { value: 'other', labelKey: 'hr.trainingCategory.other' },
]

// 手册的年假基数(办公室 24 / 车间 18)。DB 的 BEFORE INSERT 触发器也用这两个数 ——
// 这里只是把同一份约定显示给录入的人看,【不参与任何计算】。
// HANDBOOK_LEAVE_DAYS 已删除(HR-2c):24/18 现在只住在 leave_accrual_rates,
// 由 leave_accrual_rate() 解析。界面要显示费率就读派生列,不再自己存一份。

// 当月最后一个周五 —— 手册约定的发薪日。用作新建薪资期间时 payment_date 的默认值
// (只是默认值,照常可改)。
export function lastFridayOfMonth(year: number, month1to12: number): string {
    const last = new Date(year, month1to12, 0) // 该月最后一天
    const day = last.getDay() // 0=周日 … 5=周五
    const back = (day - 5 + 7) % 7
    last.setDate(last.getDate() - back)
    const pad = (n: number) => String(n).padStart(2, '0')
    return `${last.getFullYear()}-${pad(last.getMonth() + 1)}-${pad(last.getDate())}`
}
