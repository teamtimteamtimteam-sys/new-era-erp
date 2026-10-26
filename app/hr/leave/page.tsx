// app/hr/leave/page.tsx
// 请假申请列表 —— 这是一张【待办清单】,所以默认待审在最前。
//
// CONV-5:套 CONV-1 的两文件模板。排序(待审优先)留在服务端,DataTable 不接管。
// TABLE-FEATURES-1 Q9/Q12:列排序也在数据库里排(?sort=&dir=);默认的待审优先在截断之前做(leaveRows.ts 的 leavePage)。
// ★ state 恒为 'ok' —— 筛选表单与 LeaveSubnav 都是真实出口,筛空了不能一起藏。
//   见 docs/list-page-template.md §⑩-3。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import LeaveSubnav from './LeaveSubnav'
import { mustRows, mustCount } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import LeaveRequestsTable from './LeaveRequestsTable'
import { RowCapNotice } from '@/app/components/ui/row-cap-notice'
import { LEAVE_SHOWN, leaveCount, leaveFilterFrom, leavePage, leaveQuery, shapeLeaveRows } from './leaveRows'
import { Button } from '@/app/components/ui/button'
import { CONTROL_SELECT } from '@/app/components/ui/control-style'
import { DatePicker } from '@/app/components/ui/date-picker'
import { Suspense } from 'react'
import { DatePresetLinks } from '@/app/components/ui/date-presets'
import { readDatePresets } from '@/lib/datePresetsServer'

export default async function LeaveRequestsPage({
    searchParams,
}: {
    searchParams: Promise<{ status?: string; type?: string; employee?: string; from?: string; to?: string; sort?: string; dir?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    // ★ TABLE-EXPORT-2b-2(Tim Q2):读取、筛选与映射(含「待审在最前」)搬进 leaveRows.ts,与导出路由共用;
    //   只画按开始日最新的 LEAVE_SHOWN 条,而且说出来。
    const f = leaveFilterFrom(sp)
    const [reqRes, totalRes, empRes, typeRes] = await Promise.all([
        leavePage(supabase, f, 0, LEAVE_SHOWN - 1),
        leaveCount(supabase, f),
        supabase.from('employees').select('id, code, legal_name').is('deleted_at', null).order('code'),
        supabase.from('leave_types').select('code, name_en, name_zh').eq('is_active', true).order('sort_order'),
    ])
    const tableRows = await shapeLeaveRows(supabase, mustRows(reqRes, 'leave_requests_masked'))
    const total = mustCount(totalRes, 'leave_requests_masked count')

    const sel = CONTROL_SELECT
    // TABLE-FEATURES-2 Q5:日期快捷区间(新加坡的今天 + 财年年末),服务端算好
    const presets = await readDatePresets(supabase)

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

            <Suspense fallback={<div className="mb-3 h-8" />}>
                <DatePresetLinks presets={presets} fromKey="from" toKey="to" pageKey="page" />
            </Suspense>
            {/* 日期框是不受控的(defaultValue):按快捷区间换了地址之后,用起止两个参数做 key 让表单重挂,框里才显示新日期 */}
            <form key={`${sp.from ?? ''}|${sp.to ?? ''}`} className="flex gap-2 flex-wrap items-end mb-4" method="get">
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

            <RowCapNotice shown={tableRows.length} total={total} />
            <LeaveRequestsTable rows={tableRows} empty={t('leave.noRequests')} exportUrl={`/hr/leave/export${leaveQuery(f)}`}
                                sort={f.sort} shown={tableRows.length} total={total} />
        </ListPage>
    )
}
