// app/hr/attendance/page.tsx
// ATTEND-1:考勤底稿列表 —— 一个月一行。
//
// 【这一页的读者要一眼看出的两件事】
//   ① 这个月【记满了没有】(未记行数,而不是"加班工时是不是 0");
//   ② 这个月的工资【过账了没有】—— 过了就不能再重开它的依据。
//
// CONV-5:套 CONV-1 的两文件模板。
// ★ state 恒为 'ok' —— OpenPeriodForm 是这一页【开一个新期间】的唯一出口,
//   而它今天就画在行数判断之外。若按行数走 ListPage 的 empty 分支,
//   一个还没有任何期间的仓库会看到一句"还没有期间"、却没有开期间的地方。
//   这是 CONV-3 §⑧-2 / CONV-4 §⑨-4 那条"空态吞掉出口"的同一条判据,
//   整套推理写在 docs/list-page-template.md,不在这里重复。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import OpenPeriodForm from './OpenPeriodForm'
import AttendanceTable, { type AttendanceRow } from './AttendanceTable'

export default async function AttendancePeriodsPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const rows = mustRows(
        await supabase
            .from('attendance_period_status')
            .select('period_id, code, period_month, status, line_count, unrecorded_count, ot_normal_hours, ot_rest_day_hours, ot_public_holiday_hours, unpaid_days, payroll_posted')
            .order('period_month', { ascending: false }),
    )

    const tableRows: AttendanceRow[] = rows.map((r) => ({
        periodId: r.period_id as string,
        code: r.code as string,
        status: r.status as string,
        lineCount: r.line_count as number,
        unrecordedCount: r.unrecorded_count as number,
        otNormalHours: r.ot_normal_hours as number,
        otRestDayHours: r.ot_rest_day_hours as number,
        otPublicHolidayHours: r.ot_public_holiday_hours as number,
        unpaidDays: r.unpaid_days as number,
        payrollPosted: Boolean(r.payroll_posted),
    }))

    return (
        <ListPage
            title={t('attendance.title')}
            /* 【这张底稿不算工资】—— 政策 7.1:计算在服务商那边。
               把这句话摆在页面顶上,是为了让读者一开始就不去找一个不存在的数字。 */
            intro={t('attendance.subtitle')}
            maxWidth="max-w-5xl"
            state={{ kind: 'ok' }}
        >
            <OpenPeriodForm />
            <AttendanceTable rows={tableRows} empty={t('attendance.empty')} />
        </ListPage>
    )
}
