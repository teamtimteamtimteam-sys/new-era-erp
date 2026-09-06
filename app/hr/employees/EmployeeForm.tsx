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
import { useRef } from 'react'
import { useFormDraft } from '@/lib/useFormDraft'
import DraftBanner from '@/app/components/DraftBanner'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import DecimalInput from '@/app/components/forms/DecimalInput'
import {
    EMPLOYMENT_TYPE_OPTIONS,
    WORK_CATEGORY_OPTIONS,
    EMPLOYMENT_STATUS_OPTIONS,
    RESIDENCY_OPTIONS,
    SEPARATION_TYPE_OPTIONS,
} from '../options'
import { createEmployee, updateEmployee, type EmployeeFormState } from './actions'
import { Button } from '@/app/components/ui/button'

const initialState: EmployeeFormState = {}

export type EmployeeRecord = {
    id: string
    code: string
    legal_name: string
    preferred_name: string | null
    department_id: string | null
    position_id: string | null
    manager_id: string | null
    employment_type: string
    work_category: string
    hire_date: string
    probation_end_date: string | null
    employment_status: string
    separation_date: string | null
    separation_type: string | null
    separation_notes: string | null
    work_email: string | null
    work_phone: string | null
    residency_status: string | null
    identity_no: string | null
    work_pass_type: string | null
    work_pass_no: string | null
    work_pass_issue_date: string | null
    work_pass_expiry_date: string | null
    user_id: string | null
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
    accounts,
    canLinkAccount,
    linkedAccountLabel,
    positions,
}: {
    employee?: EmployeeRecord
    departments: PickOption[]
    // KPI-1:可选的职位。一张【空的】职位表意味着这个下拉只有"未指定"一项 ——
    // 那不该长得像"这个人没有职位",所以下面那句 positionWhat 会说清楚。
    positions: { id: string; code: string; title: string }[]
    // 上级候选:服务端已剔除自己与自己的下属
    managers: PickOption[]
    // 可选的登录账号:服务端只给【还没有关联任何员工】的,外加这名员工当前关联的那个
    accounts: PickOption[]
    // 读得到 user_directory 吗(action.manage_permissions)。false 时不渲染下拉
    canLinkAccount: boolean
    linkedAccountLabel: string | null
}) {
    const t = useTranslations()
    const action = employee ? updateEmployee.bind(null, employee.id) : createEmployee
    const [state, formAction, isPending] = useActionState(action, initialState)

    // IDLE-DRAFT:草稿留存。受限与否由 lib/maskedTables.ts 推出来,
    // 不在这里声明 —— 见 lib/useFormDraft.ts 抬头。
    const formRef = useRef<HTMLFormElement>(null)
    const draft = useFormDraft({ formKey: 'hr/employees/form', table: 'employees', subject: null, formRef })

    const [status, setStatus] = useState(employee?.employment_status ?? 'probation')
    const [residency, setResidency] = useState(employee?.residency_status ?? '')
    const [workCategory, setWorkCategory] = useState(employee?.work_category ?? 'office')

    const label = 'block text-sm font-medium mb-1'
    const field = 'w-full border border-gray-300 px-3 py-2 rounded'

    return (
        <form ref={formRef} action={formAction} className="space-y-6 max-w-4xl">
                <DraftBanner draft={draft} />
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

                {/* ── 登录账号 ─────────────────────────────────────────────────
                    employees.user_id 一直存在(EXEC-2 还给了它外键),但这张表单
                    从来没有一栏能设它 —— 于是这条关联只能从【账号】页那一头做。
                    这里补上从员工这一头的入口;写入仍然走 set_user_employee_link,
                    同一个事实只有一种写法,两个入口。

                    ┌───────────────────────────────────────────────────────────┐
                    │ 【改这一栏之前先读】                                        │
                    │ docs/known-issues.md                                       │
                    │ §「员工 ↔ 登录账号的关联:【两扇门,两套规矩】(LINK-1)」    │
                    │                                                            │
                    │ 那一条说的是:这一栏与账号页那一栏写的是同一个事实,而两边   │
                    │ 对"选中一个已被占用的账号"给出【不同的答案】(那边静默改绑, │
                    │ 这边拒绝)。要统一它们,**第一步是裁定哪一侧的语义是对的**,  │
                    │ 不是在这里再加一条守卫 —— 那只会把不一致从两处变成三处。     │
                    └───────────────────────────────────────────────────────────┘

                    【空是一个有名字的状态,不是一个空白】。没有登录账号的员工是常态
                    (车间的人多半没有),所以第一项写的是"未关联账号"而不是一条
                    破折号 —— 破折号读起来像"还没填",而它其实就是答案。 */}
                <div className="mt-4">
                    <label className={label}>{t('hr.colLoginAccount')}</label>
                    {canLinkAccount ? (
                        <>
                            <select
                                name="user_id"
                                defaultValue={employee?.user_id ?? ''}
                                className={`${field} max-w-md`}
                            >
                                <option value="">{t('hr.loginAccountNone')}</option>
                                {accounts.map((a) => (
                                    <option key={a.id} value={a.id}>
                                        {a.label}
                                    </option>
                                ))}
                            </select>
                            <p className="mt-1 text-sm text-gray-600">{t('hr.loginAccountHelp')}</p>
                        </>
                    ) : (
                        /* 【不渲染一个空的下拉】。user_directory 对没有
                           action.manage_permissions 的人返回【零行而不是报错】,
                           照着渲染就会得到一个空的选择框 —— 那读起来是"没有账号可选",
                           而真相是"你不被允许看"。这正是 lib/permissions.ts 存在的
                           理由:空集不是答案,所以这里把它说出来。 */
                        <p className="text-sm text-gray-600">
                            {linkedAccountLabel
                                ? t('hr.loginAccountCurrent', { 0: linkedAccountLabel })
                                : employee?.user_id
                                  ? t('hr.loginAccountUnknown')
                                  : t('hr.loginAccountNone')}{' '}
                            {t('hr.loginAccountNoPermission')}
                        </p>
                    )}
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
                    {/* ★【KPI-1:头衔从自由文本换成【职位】】★
                        KPI 绑在职位上不绑在人上(规格 §8.1),而自由文本里
                        「CFO」「Chief Financial Officer」「财务总监」是三个不同的值 ——
                        没有一个挂得上模板。**换职位仍然会写一行任职履历**,
                        而履历里存的是【当时那个职位的名称文本】,不是指针。 */}
                    <div className="flex-1 min-w-[14rem]">
                        <label className={label}>{t('hr.colPosition')}</label>
                        <select name="position_id" defaultValue={employee?.position_id ?? ''} className={field}>
                            <option value="">{t('hr.positionNone')}</option>
                            {positions.map((p) => (
                                <option key={p.id} value={p.id}>{p.code} · {p.title}</option>
                            ))}
                        </select>
                        <p className="text-xs text-gray-600 mt-1">{t('hr.positionWhat')}</p>
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
                <Button
                    type="submit"
                    disabled={isPending}
                >
                    {isPending ? t('common.saving') : t('common.save')}
                </Button>
                <Button asChild variant="secondary">
                    <Link
                        href={employee ? `/hr/employees/${employee.id}` : '/hr/employees'}
                    >
                        {t('common.cancel')}
                    </Link>
                </Button>
            </div>
        </form>
    )
}
