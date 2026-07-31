'use client'

// 员工表单(新建/编辑共用),按【身份 / 任职 / 居留 / 离职】分组 ——
// 一屏几十个字段,分组是让人找得到东西的最低成本。
//
// 受限字段(身份证件号、准证号、办公邮箱、办公电话)在标签旁挂一个灰色"受限"标记:
// 这几列在 HR-1a 里被列为受限访问,权限切次会按列管控 —— 录入的人现在就该看见
// 这件事,而不是等到出事才知道。
//
// 居留状态选"工作准证"时才展开准证四项(类型/号码/签发日/到期日),且此时
// 类型与到期日为必填 —— DB 的 employees_work_pass_shape 是后墙。
// 离职组只在状态为"已离职"时出现。
import { useActionState, useState } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import DecimalInput from '@/app/components/forms/DecimalInput'
import {
    EMPLOYMENT_TYPE_OPTIONS,
    WORK_CATEGORY_OPTIONS,
    EMPLOYMENT_STATUS_OPTIONS,
    RESIDENCY_OPTIONS,
    SEPARATION_TYPE_OPTIONS,
    HANDBOOK_LEAVE_DAYS,
} from '../options'
import { createEmployee, updateEmployee, type EmployeeFormState } from './actions'

const initialState: EmployeeFormState = {}

export type EmployeeRecord = {
    id: string
    code: string
    legal_name: string
    preferred_name: string | null
    department_id: string | null
    job_title: string | null
    manager_id: string | null
    employment_type: string
    work_category: string
    hire_date: string
    probation_end_date: string | null
    employment_status: string
    separation_date: string | null
    separation_type: string | null
    separation_notes: string | null
    annual_leave_days: number
    work_email: string | null
    work_phone: string | null
    residency_status: string | null
    identity_no: string | null
    work_pass_type: string | null
    work_pass_no: string | null
    work_pass_issue_date: string | null
    work_pass_expiry_date: string | null
    notes: string | null
}

export type PickOption = { id: string; label: string }

function todayIsoLocal(): string {
    const d = new Date()
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

// 受限字段的小标记
function Restricted() {
    const t = useTranslations()
    return (
        <span className="ml-2 px-1.5 py-0.5 rounded text-[10px] bg-gray-200 text-gray-600 align-middle">
            {t('hr.restrictedField')}
        </span>
    )
}

export default function EmployeeForm({
    employee,
    departments,
    managers,
}: {
    employee?: EmployeeRecord
    departments: PickOption[]
    // 上级候选:服务端已剔除自己与自己的下属
    managers: PickOption[]
}) {
    const t = useTranslations()
    const action = employee ? updateEmployee.bind(null, employee.id) : createEmployee
    const [state, formAction, isPending] = useActionState(action, initialState)

    const [status, setStatus] = useState(employee?.employment_status ?? 'probation')
    const [residency, setResidency] = useState(employee?.residency_status ?? '')
    const [workCategory, setWorkCategory] = useState(employee?.work_category ?? 'office')
    const [leaveDays, setLeaveDays] = useState(
        employee ? String(employee.annual_leave_days) : ''
    )

    const label = 'block text-sm font-medium mb-1'
    const field = 'w-full border border-gray-300 px-3 py-2 rounded'

    return (
        <form action={formAction} className="space-y-6 max-w-4xl">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}

            {/* ── 身份 ── */}
            <section>
                <h2 className="font-bold mb-3">{t('hr.groupIdentity')}</h2>
                <div className="flex flex-wrap gap-4">
                    <div className="flex-1 min-w-[16rem]">
                        <label className={label}>
                            {t('hr.colLegalName')} <span className="text-red-600">*</span>
                        </label>
                        <input
                            type="text"
                            name="legal_name"
                            required
                            defaultValue={employee?.legal_name ?? ''}
                            className={field}
                        />
                    </div>
                    <div className="flex-1 min-w-[12rem]">
                        <label className={label}>{t('hr.colPreferredName')}</label>
                        <input
                            type="text"
                            name="preferred_name"
                            defaultValue={employee?.preferred_name ?? ''}
                            className={field}
                        />
                    </div>
                </div>
                <div className="flex flex-wrap gap-4 mt-4">
                    <div className="flex-1 min-w-[14rem]">
                        <label className={label}>
                            {t('hr.colWorkEmail')}
                            <Restricted />
                        </label>
                        <input
                            type="email"
                            name="work_email"
                            defaultValue={employee?.work_email ?? ''}
                            className={field}
                        />
                    </div>
                    <div className="flex-1 min-w-[12rem]">
                        <label className={label}>
                            {t('hr.colWorkPhone')}
                            <Restricted />
                        </label>
                        <input
                            type="text"
                            name="work_phone"
                            defaultValue={employee?.work_phone ?? ''}
                            className={field}
                        />
                    </div>
                </div>
            </section>

            {/* ── 任职 ── */}
            <section className="border-t pt-4">
                <h2 className="font-bold mb-3">{t('hr.groupEmployment')}</h2>
                <div className="flex flex-wrap gap-4">
                    <div className="flex-1 min-w-[14rem]">
                        <label className={label}>{t('hr.colDepartment')}</label>
                        <select
                            name="department_id"
                            defaultValue={employee?.department_id ?? ''}
                            className={field}
                        >
                            <option value="">—</option>
                            {departments.map((d) => (
                                <option key={d.id} value={d.id}>
                                    {d.label}
                                </option>
                            ))}
                        </select>
                    </div>
                    <div className="flex-1 min-w-[14rem]">
                        <label className={label}>{t('hr.colJobTitle')}</label>
                        <input
                            type="text"
                            name="job_title"
                            defaultValue={employee?.job_title ?? ''}
                            className={field}
                        />
                    </div>
                    <div className="flex-1 min-w-[14rem]">
                        <label className={label}>{t('hr.colManager')}</label>
                        <select name="manager_id" defaultValue={employee?.manager_id ?? ''} className={field}>
                            <option value="">—</option>
                            {managers.map((m) => (
                                <option key={m.id} value={m.id}>
                                    {m.label}
                                </option>
                            ))}
                        </select>
                    </div>
                </div>

                <div className="flex flex-wrap gap-4 mt-4">
                    <div>
                        <label className={label}>
                            {t('hr.colEmploymentType')} <span className="text-red-600">*</span>
                        </label>
                        <select
                            name="employment_type"
                            required
                            defaultValue={employee?.employment_type ?? 'full_time'}
                            className="border border-gray-300 px-3 py-2 rounded"
                        >
                            {EMPLOYMENT_TYPE_OPTIONS.map((o) => (
                                <option key={o.value} value={o.value}>
                                    {t(o.labelKey)}
                                </option>
                            ))}
                        </select>
                    </div>
                    <div>
                        <label className={label}>
                            {t('hr.colWorkCategory')} <span className="text-red-600">*</span>
                        </label>
                        <select
                            name="work_category"
                            required
                            value={workCategory}
                            onChange={(e) => setWorkCategory(e.target.value)}
                            className="border border-gray-300 px-3 py-2 rounded"
                        >
                            {WORK_CATEGORY_OPTIONS.map((o) => (
                                <option key={o.value} value={o.value}>
                                    {t(o.labelKey)}
                                </option>
                            ))}
                        </select>
                    </div>
                    <div>
                        <label className={label}>
                            {t('hr.colHireDate')} <span className="text-red-600">*</span>
                        </label>
                        <input
                            type="date"
                            name="hire_date"
                            required
                            defaultValue={employee?.hire_date ?? todayIsoLocal()}
                            className="border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>
                    <div>
                        <label className={label}>{t('hr.colProbationEnd')}</label>
                        <input
                            type="date"
                            name="probation_end_date"
                            defaultValue={employee?.probation_end_date ?? ''}
                            className="border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>
                    <div>
                        <label className={label}>{t('hr.colStatus')}</label>
                        <select
                            name="employment_status"
                            value={status}
                            onChange={(e) => setStatus(e.target.value)}
                            className="border border-gray-300 px-3 py-2 rounded"
                        >
                            {EMPLOYMENT_STATUS_OPTIONS.map((o) => (
                                <option key={o.value} value={o.value}>
                                    {t(o.labelKey)}
                                </option>
                            ))}
                        </select>
                    </div>
                    <div>
                        <label className={label}>{t('hr.colAnnualLeave')}</label>
                        <DecimalInput
                            name="annual_leave_days"
                            value={leaveDays}
                            onChange={setLeaveDays}
                            className="w-28 border border-gray-300 px-3 py-2 rounded"
                        />
                        <p className="text-xs text-gray-500 mt-1">
                            {t('hr.leaveHint', { days: HANDBOOK_LEAVE_DAYS[workCategory] ?? 0 })}
                        </p>
                    </div>
                </div>

                {/* 编辑时可以指定履历的生效日;新建时履历生效日 = 入职日 */}
                {employee && (
                    <div className="mt-4">
                        <label className={label}>{t('hr.effectiveDate')}</label>
                        <input
                            type="date"
                            name="effective_date"
                            className="border border-gray-300 px-3 py-2 rounded"
                        />
                        <p className="text-xs text-gray-500 mt-1">{t('hr.effectiveDateHint')}</p>
                    </div>
                )}
            </section>

            {/* ── 居留 ── */}
            <section className="border-t pt-4">
                <h2 className="font-bold mb-3">{t('hr.groupResidency')}</h2>
                <div className="flex flex-wrap gap-4">
                    <div>
                        <label className={label}>{t('hr.colResidency')}</label>
                        <select
                            name="residency_status"
                            value={residency}
                            onChange={(e) => setResidency(e.target.value)}
                            className="border border-gray-300 px-3 py-2 rounded"
                        >
                            <option value="">—</option>
                            {RESIDENCY_OPTIONS.map((o) => (
                                <option key={o.value} value={o.value}>
                                    {t(o.labelKey)}
                                </option>
                            ))}
                        </select>
                    </div>
                    <div className="flex-1 min-w-[14rem]">
                        <label className={label}>
                            {t('hr.colIdentityNo')}
                            <Restricted />
                        </label>
                        <input
                            type="text"
                            name="identity_no"
                            defaultValue={employee?.identity_no ?? ''}
                            className={field}
                        />
                    </div>
                </div>

                {residency === 'work_pass' && (
                    <div className="flex flex-wrap gap-4 mt-4">
                        <div>
                            <label className={label}>
                                {t('hr.colWorkPassType')} <span className="text-red-600">*</span>
                            </label>
                            <input
                                type="text"
                                name="work_pass_type"
                                required
                                defaultValue={employee?.work_pass_type ?? ''}
                                className="w-40 border border-gray-300 px-3 py-2 rounded"
                            />
                        </div>
                        <div>
                            <label className={label}>
                                {t('hr.colWorkPassNo')}
                                <Restricted />
                                <span className="text-red-600"> *</span>
                            </label>
                            <input
                                type="text"
                                name="work_pass_no"
                                required
                                defaultValue={employee?.work_pass_no ?? ''}
                                className="w-44 border border-gray-300 px-3 py-2 rounded"
                            />
                        </div>
                        <div>
                            <label className={label}>
                                {t('hr.colWorkPassIssue')} <span className="text-red-600">*</span>
                            </label>
                            <input
                                type="date"
                                name="work_pass_issue_date"
                                required
                                defaultValue={employee?.work_pass_issue_date ?? ''}
                                className="border border-gray-300 px-3 py-2 rounded"
                            />
                        </div>
                        <div>
                            <label className={label}>
                                {t('hr.colWorkPassExpiry')} <span className="text-red-600">*</span>
                            </label>
                            <input
                                type="date"
                                name="work_pass_expiry_date"
                                required
                                defaultValue={employee?.work_pass_expiry_date ?? ''}
                                className="border border-gray-300 px-3 py-2 rounded"
                            />
                        </div>
                    </div>
                )}
            </section>

            {/* ── 离职(仅在状态为已离职时出现)── */}
            {status === 'separated' && (
                <section className="border-t pt-4">
                    <h2 className="font-bold mb-3">{t('hr.groupSeparation')}</h2>
                    <div className="flex flex-wrap gap-4">
                        <div>
                            <label className={label}>
                                {t('hr.colSeparationDate')} <span className="text-red-600">*</span>
                            </label>
                            <input
                                type="date"
                                name="separation_date"
                                required
                                defaultValue={employee?.separation_date ?? ''}
                                className="border border-gray-300 px-3 py-2 rounded"
                            />
                        </div>
                        <div>
                            <label className={label}>{t('hr.colSeparationType')}</label>
                            <select
                                name="separation_type"
                                defaultValue={employee?.separation_type ?? ''}
                                className="border border-gray-300 px-3 py-2 rounded"
                            >
                                <option value="">—</option>
                                {SEPARATION_TYPE_OPTIONS.map((o) => (
                                    <option key={o.value} value={o.value}>
                                        {t(o.labelKey)}
                                    </option>
                                ))}
                            </select>
                        </div>
                        <div className="flex-1 min-w-[16rem]">
                            <label className={label}>{t('hr.colSeparationNotes')}</label>
                            <input
                                type="text"
                                name="separation_notes"
                                defaultValue={employee?.separation_notes ?? ''}
                                className={field}
                            />
                        </div>
                    </div>
                </section>
            )}

            <section className="border-t pt-4">
                <label className={label}>{t('hr.colNotes')}</label>
                <textarea name="notes" rows={2} defaultValue={employee?.notes ?? ''} className={field} />
            </section>

            <div className="flex gap-3 pt-2">
                <button
                    type="submit"
                    disabled={isPending}
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {isPending ? t('common.saving') : t('common.save')}
                </button>
                <Link
                    href={employee ? `/hr/employees/${employee.id}` : '/hr/employees'}
                    className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                >
                    {t('common.cancel')}
                </Link>
            </div>
        </form>
    )
}
