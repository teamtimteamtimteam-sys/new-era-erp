// app/hr/leave/page.tsx
// 请假申请列表 —— 这是一张【待办清单】,所以默认待审在最前。
//
// CONV-5:套 CONV-1 的两文件模板。排序(待审优先)留在服务端,DataTable 不接管。
// ★ state 恒为 'ok' —— 筛选表单与 LeaveSubnav 都是真实出口,筛空了不能一起藏。
//   见 docs/list-page-template.md §⑩-3。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import LeaveSubnav from './LeaveSubnav'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import LeaveRequestsTable, { type LeaveRequestRow } from './LeaveRequestsTable'
import { Button } from '@/app/components/ui/button'
import { CONTROL_SELECT } from '@/app/components/ui/control-style'
import { DatePicker } from '@/app/components/ui/date-picker'
import { formatDate } from '@/lib/dates'

type Row = {
    request_id: string
    code: string
    employee_code: string
    legal_name: string
    leave_type_code: string
    leave_type_en: string
    leave_type_zh: string
    start_date: string
    end_date: string
    days: number
    status: string
}

export default async function LeaveRequestsPage({
    searchParams,
}: {
    searchParams: Promise<{ status?: string; type?: string; employee?: string; from?: string; to?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    let qb = supabase
        .from('leave_requests_masked')
        .select('id, code, employee_id, leave_type_code, start_date, end_date, days, status, is_exception, created_at')
        .is('deleted_at', null)
    if (sp.status) qb = qb.eq('status', sp.status)
    if (sp.type) qb = qb.eq('leave_type_code', sp.type)
    if (sp.employee) qb = qb.eq('employee_id', sp.employee)
    if (sp.from) qb = qb.gte('start_date', sp.from)
    if (sp.to) qb = qb.lte('end_date', sp.to)

    const [reqRes, empRes, typeRes] = await Promise.all([
        qb.order('start_date', { ascending: false }).limit(300),
        supabase.from('employees').select('id, code, legal_name').is('deleted_at', null).order('code'),
        supabase.from('leave_types').select('code, name_en, name_zh').eq('is_active', true).order('sort_order'),
    ])

    const empById = new Map((mustRows(empRes)).map((e) => [e.id, e]))
    const typeByCode = new Map((mustRows(typeRes)).map((x) => [x.code, x]))
    // 待审在最前 —— 这是一张待办清单,不是一份档案
    // U1-A:读 leave_requests_masked(这一页不选被遮的三列);视图的生成类型把每一列都标成可空 —— 这几列由基表的 NOT NULL 保证
    type ReqRow = { id: string; code: string; employee_id: string; leave_type_code: string; start_date: string; end_date: string
                    days: number; status: string; is_exception: boolean; created_at: string }
    const rows = (mustRows(reqRes) as unknown as ReqRow[]).sort((a, b) => {
        if (a.status === 'pending' && b.status !== 'pending') return -1
        if (b.status === 'pending' && a.status !== 'pending') return 1
        return (b.start_date ?? '').localeCompare(a.start_date ?? '')
    })

    const sel = CONTROL_SELECT

    const tableRows: LeaveRequestRow[] = rows.map((r) => {
        const e = empById.get(r.employee_id)
        const ty = typeByCode.get(r.leave_type_code)
        return {
            id: r.id,
            code: r.code,
            isException: Boolean(r.is_exception),
            employeeLabel: e ? `${e.code} — ${e.legal_name}` : '—',
            // 假期类型名的语言在服务端选好 —— locale 不过 RSC 边界
            typeLabel: ty ? (locale === 'zh' ? ty.name_zh : ty.name_en) : r.leave_type_code,
            startDate: formatDate(r.start_date, locale),
            endDate: formatDate(r.end_date, locale),
            days: r.days,
            status: r.status,
        }
    })

    return (
        <ListPage
            title={t('hr.title')}
            maxWidth="max-w-6xl"
            actions={
                <Button asChild>
                    <Link href="/hr/leave/new">{t('leave.recordLeave')}</Link>
                </Button>
            }
            state={{ kind: 'ok' }}
        >
            <LeaveSubnav />

            <form className="flex gap-2 flex-wrap items-end mb-4" method="get">
                <label className="">
                    {t('leave.status')}
                    <select name="status" defaultValue={sp.status ?? ''} className={`block ${sel}`}>
                        <option value="">{t('leave.allStatuses')}</option>
                        {['pending', 'approved', 'rejected', 'cancelled'].map((s) => (
                            <option key={s} value={s}>{t(`leave.status_${s}`)}</option>
                        ))}
                    </select>
                </label>
                <label className="">
                    {t('leave.type')}
                    <select name="type" defaultValue={sp.type ?? ''} className={`block ${sel}`}>
                        <option value="">{t('leave.allTypes')}</option>
                        {(mustRows(typeRes)).map((x) => (
                            <option key={x.code} value={x.code}>
                                {locale === 'zh' ? x.name_zh : x.name_en}
                            </option>
                        ))}
                    </select>
                </label>
                <label className="">
                    {t('leave.employee')}
                    <select name="employee" defaultValue={sp.employee ?? ''} className={`block ${sel}`}>
                        <option value="">{t('leave.allEmployees')}</option>
                        {(mustRows(empRes)).map((e) => (
                            <option key={e.id} value={e.id}>{e.code} — {e.legal_name}</option>
                        ))}
                    </select>
                </label>
                <label className="">
                    {t('leave.from')}
                    <DatePicker name="from" defaultValue={sp.from ?? ''} className="flex" />
                </label>
                <label className="">
                    {t('leave.to')}
                    <DatePicker name="to" defaultValue={sp.to ?? ''} className="flex" />
                </label>
                <Button variant="secondary" type="submit">
                    {t('leave.filter')}
                </Button>
            </form>

            <LeaveRequestsTable rows={tableRows} empty={t('leave.noRequests')} />
        </ListPage>
    )
}
