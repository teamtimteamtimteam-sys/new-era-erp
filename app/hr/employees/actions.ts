'use server'

// 员工的新建/编辑。
//
// ════════════════════════════════════════════════════════════════════════════
// 【任职履历由这里写】—— HR-1a 建了 employment_history 但没有任何东西写它;
// 那张表是不可变的审计轨迹,只能靠应用在改动实质字段时补一行。
//
// 规则:
//   * 新建 → 一行 'hired',effective_date = 入职日;
//   * 编辑 → 当 job_title / department_id / employment_type / employment_status
//     其中【至少一项】变了,补【一行】(不是每个字段一行 —— 一次保存就是一次事件);
//   * change_type 按下面的优先级推断(几项同时变时只能落一个标签,取"最能说明
//     这次变动是什么事"的那个);完整的字段变化写进 notes,所以即便标签只有一个,
//     具体改了什么也不会丢。
//   * effective_date 取表单给的生效日,没给就用今天。
// ════════════════════════════════════════════════════════════════════════════
import { createClient } from '@/lib/supabase/server'
import type { InsertRow } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizeHrError } from '../hrErrorCodes'

export type EmployeeFormState = { error?: string }

type MaterialFields = {
    job_title: string | null
    department_id: string | null
    employment_type: string
    employment_status: string
}

// change_type 的推断优先级(几项同时变时用哪一个)。
// 顺序即"这次变动最应该被记成什么":
//   1. separated   —— 离职是终局事件,压过一切(离职那天往往同时改状态与职务)
//   2. confirmed   —— 试用期转正,是有确切含义的里程碑
//   3. transfer    —— 换部门:组织归属变了,比头衔更结构性
//   4. promotion   —— 换职务
//   5. type_change —— 全职/兼职/合同等雇佣类型变化
//   6. status_change —— 其余任何状态变化(兜底)
function inferChangeType(before: MaterialFields, after: MaterialFields): string | null {
    const statusChanged = before.employment_status !== after.employment_status
    const deptChanged = before.department_id !== after.department_id
    const titleChanged = (before.job_title ?? '') !== (after.job_title ?? '')
    const typeChanged = before.employment_type !== after.employment_type

    if (!statusChanged && !deptChanged && !titleChanged && !typeChanged) return null

    if (statusChanged && after.employment_status === 'separated') return 'separated'
    if (statusChanged && before.employment_status === 'probation' && after.employment_status === 'active') {
        return 'confirmed'
    }
    if (deptChanged) return 'transfer'
    if (titleChanged) return 'promotion'
    if (typeChanged) return 'type_change'
    return 'status_change'
}

// 变化摘要写进 notes —— change_type 只能是一个标签,但改了什么必须一条不落
function describeChanges(before: MaterialFields, after: MaterialFields, deptName: (id: string | null) => string): string {
    const parts: string[] = []
    if (before.employment_status !== after.employment_status) {
        parts.push(`status: ${before.employment_status} → ${after.employment_status}`)
    }
    if (before.department_id !== after.department_id) {
        parts.push(`department: ${deptName(before.department_id)} → ${deptName(after.department_id)}`)
    }
    if ((before.job_title ?? '') !== (after.job_title ?? '')) {
        parts.push(`job title: ${before.job_title || '—'} → ${after.job_title || '—'}`)
    }
    if (before.employment_type !== after.employment_type) {
        parts.push(`employment type: ${before.employment_type} → ${after.employment_type}`)
    }
    return parts.join('; ')
}

function readForm(formData: FormData) {
    const s = (k: string) => String(formData.get(k) ?? '').trim()
    const residency = s('residency_status')
    const status = s('employment_status')
    return {
        legal_name: s('legal_name'),
        preferred_name: s('preferred_name') || null,
        department_id: s('department_id') || null,
        job_title: s('job_title') || null,
        manager_id: s('manager_id') || null,
        employment_type: s('employment_type'),
        work_category: s('work_category'),
        hire_date: s('hire_date'),
        probation_end_date: s('probation_end_date') || null,
        employment_status: status,
        separation_date: status === 'separated' ? s('separation_date') || null : null,
        separation_type: status === 'separated' ? s('separation_type') || null : null,
        separation_notes: status === 'separated' ? s('separation_notes') || null : null,
        work_email: s('work_email') || null,
        work_phone: s('work_phone') || null,
        residency_status: residency || null,
        identity_no: s('identity_no') || null,
        work_pass_type: residency === 'work_pass' ? s('work_pass_type') || null : null,
        work_pass_no: residency === 'work_pass' ? s('work_pass_no') || null : null,
        work_pass_issue_date: residency === 'work_pass' ? s('work_pass_issue_date') || null : null,
        work_pass_expiry_date: residency === 'work_pass' ? s('work_pass_expiry_date') || null : null,
        notes: s('notes') || null,
        effective_date: s('effective_date') || null,
        // 【不进 employees 的 payload】—— 见 applyAccountLink 的抬头
        user_id: s('user_id') || null,
    }
}

// ════════════════════════════════════════════════════════════════════════════
// 【登录账号的关联不写进 employees 的 payload】
//
// user_id 看起来只是 employees 上的一列,直接塞进 insert/update 就行 —— 不行:
//   * set_user_employee_link 把"解掉账号的旧关联"与"绑上新的"放在【同一个事务】里
//     (cut 3 的遗留就是界面用两条语句做、中间失败导致谁也不关联);直接写这一列
//     等于把那个已经修好的毛病重新引进来;
//   * employees.user_id 上是 partial unique index。撞上了,PostgREST 吐的是
//     23505 加索引名,那句话对录入的人完全不可读 —— 函数存在的一半理由就是这个。
// 所以这一栏永远经由 RPC 落地,失败按名翻成一句话。
// ════════════════════════════════════════════════════════════════════════════
async function applyAccountLink(
    supabase: Awaited<ReturnType<typeof createClient>>,
    employeeId: string,
    nextUserId: string | null,
    prevUserId: string | null,
    t: Awaited<ReturnType<typeof getTranslations>>
): Promise<string | null> {
    if ((nextUserId ?? null) === (prevUserId ?? null)) return null

    // 解绑:省略 p_employee_id(函数签名的默认值就是 NULL),把【那个账号】的
    // 关联清掉。走到这里 prevUserId 必然非空 —— 两个值不相等,而 next 是空的。
    if (!nextUserId) {
        if (!prevUserId) return null
        const { error } = await supabase.rpc('set_user_employee_link', {
            p_user_id: prevUserId,
        })
        return error ? await localizeLinkError(error.message, t) : null
    }

    // 【选中的账号已经绑在别人身上】—— 这一条 set_user_employee_link 自己【不拒绝】:
    // 它的语义是"改绑",会把旧员工那一行的 user_id 悄悄清成 NULL。对账号页那一头
    // (一个账号一行、改的就是它绑谁)那是对的;从员工这一头看,它是一次【偷走】。
    // 所以拒绝写在这里,并且说的是哪一名员工。
    const { data: taken } = await supabase
        .from('employees')
        .select('code')
        .eq('user_id', nextUserId)
        .is('deleted_at', null)
        .neq('id', employeeId)
        .maybeSingle()
    if (taken) return t('hr.errAccountAlreadyLinked', { 0: taken.code })

    const { error } = await supabase.rpc('set_user_employee_link', {
        p_user_id: nextUserId,
        p_employee_id: employeeId,
    })
    return error ? await localizeLinkError(error.message, t) : null
}

// 关联这条路上的具名拒绝 → 人话。两条都是 localizeHrError 的集合里没有的,
// 落到它手里会【原样返回一串机器码】,所以在这里先接住。
async function localizeLinkError(
    message: string,
    t: Awaited<ReturnType<typeof getTranslations>>
): Promise<string> {
    const m = /([A-Z_]+)(?:\|(.*))?$/.exec(message)
    if (m?.[1] === 'EMPLOYEE_ALREADY_LINKED') {
        return t('permissions.errEmployeeLinked', { 0: m[2] ?? '' })
    }
    if (m?.[1] === 'PERMISSION_DENIED') return t('permissions.errDenied')
    return await localizeHrError(message)
}

export async function createEmployee(
    _prevState: EmployeeFormState,
    formData: FormData
): Promise<EmployeeFormState> {
    const t = await getTranslations()
    const f = readForm(formData)

    if (!f.legal_name) return { error: t('hr.errNameRequired') }
    if (!f.hire_date) return { error: t('finance.errDate') }
    if (f.residency_status === 'work_pass' && (!f.work_pass_type || !f.work_pass_expiry_date)) {
        return { error: t('hr.errWorkPassRequired') }
    }

    const supabase = await createClient()
    // 年假天数不再是员工档案的字段(HR-2c):它按月累积,费率住在 leave_accrual_rates。
    // code 同样由触发器生成 —— 故断言成 InsertRow(生成的类型不知道触发器的存在)
    const { effective_date: _effective, user_id: _nextUser, ...payload } = f
    void _effective

    // 【拒绝要发生在写之前】。关联失败若发生在 insert 之后,人会拿到一句拒绝、
    // 同时多出一名【建好了却没关联上】的员工 —— 一次操作两个结果。
    if (_nextUser) {
        const { data: taken } = await supabase
            .from('employees')
            .select('code')
            .eq('user_id', _nextUser)
            .is('deleted_at', null)
            .maybeSingle()
        if (taken) return { error: t('hr.errAccountAlreadyLinked', { 0: taken.code }) }
    }
    const { data, error } = await supabase
        .from('employees')
        .insert(payload as InsertRow<'employees'>)
        .select('id')
        .single()

    if (error) {
        if (error.code === '23505') return { error: t('hr.errCodeTaken', { 0: f.legal_name }) }
        return { error: await localizeHrError(error.message) }
    }

    // 入职一行,生效日 = 入职日
    await supabase.from('employment_history').insert({
        employee_id: data.id,
        effective_date: f.hire_date,
        change_type: 'hired',
        job_title: f.job_title,
        department_id: f.department_id,
        employment_type: f.employment_type,
        employment_status: f.employment_status,
    })

    revalidatePath('/hr/employees')
    const linkErr = await applyAccountLink(supabase, data.id, _nextUser, null, t)
    if (linkErr) return { error: linkErr }

    redirect(`/hr/employees/${data.id}`)
}

export async function updateEmployee(
    employeeId: string,
    _prevState: EmployeeFormState,
    formData: FormData
): Promise<EmployeeFormState> {
    const t = await getTranslations()
    const f = readForm(formData)

    if (!f.legal_name) return { error: t('hr.errNameRequired') }
    if (!f.hire_date) return { error: t('finance.errDate') }
    if (f.residency_status === 'work_pass' && (!f.work_pass_type || !f.work_pass_expiry_date)) {
        return { error: t('hr.errWorkPassRequired') }
    }
    if (f.employment_status === 'separated' && !f.separation_date) {
        return { error: t('hr.errSeparationDate') }
    }

    const supabase = await createClient()

    // 改之前先取"实质字段"的旧值 —— 履历要写的是"从什么变成了什么"
    const { data: before } = await supabase
        .from('employees')
        .select('job_title, department_id, employment_type, employment_status, user_id')
        .eq('id', employeeId)
        .is('deleted_at', null)
        .single()
    if (!before) return { error: t('hr.errors.EMPLOYEE_NOT_FOUND', { 0: employeeId }) }

    const { effective_date, user_id: nextUser, ...payload } = f

    // 关联放在字段更新【之前】,好让它的拒绝在任何字段被改动之前就返回。
    //
    // 【但要把话说准:它自己就是一次写入,不是一次纯检查。】所以残留的情形是
    // "关联改成了,随后字段更新失败" —— 一次保存落成了两个结果中的一个。
    // 要让两者同生共死,得有一个把 employees 更新与 set_user_employee_link 装在
    // 一起的库端函数,那超出了本刀(只动渲染层)。已在切次报告里点名。
    const linkErr = await applyAccountLink(supabase, employeeId, nextUser, before.user_id, t)
    if (linkErr) return { error: linkErr }

    const { error } = await supabase.from('employees').update(payload).eq('id', employeeId)
    if (error) {
        return { error: await localizeHrError(error.message) }
    }

    const after: MaterialFields = {
        job_title: f.job_title,
        department_id: f.department_id,
        employment_type: f.employment_type,
        employment_status: f.employment_status,
    }
    const changeType = inferChangeType(before as MaterialFields, after)
    if (changeType) {
        // 部门名用于摘要:两侧 id 都查一次(可能为空)
        const ids = [before.department_id, f.department_id].filter(Boolean) as string[]
        const { data: depts } = ids.length
            ? await supabase.from('departments').select('id, code').in('id', ids)
            : { data: [] as { id: string; code: string }[] }
        const codeById = new Map((depts ?? []).map((d) => [d.id, d.code]))
        const deptName = (id: string | null) => (id ? (codeById.get(id) ?? '?') : '—')

        await supabase.from('employment_history').insert({
            employee_id: employeeId,
            effective_date: effective_date || new Date().toISOString().slice(0, 10),
            change_type: changeType,
            job_title: f.job_title,
            department_id: f.department_id,
            employment_type: f.employment_type,
            employment_status: f.employment_status,
            notes: describeChanges(before as MaterialFields, after, deptName) || null,
        })
    }

    revalidatePath('/hr/employees')
    revalidatePath(`/hr/employees/${employeeId}`)
    redirect(`/hr/employees/${employeeId}`)
}

export async function deleteEmployee(employeeId: string): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase
        .from('employees')
        .update({ deleted_at: new Date().toISOString() })
        .eq('id', employeeId)
    if (error) return { error: await localizeHrError(error.message) }
    revalidatePath('/hr/employees')
    return {}
}
