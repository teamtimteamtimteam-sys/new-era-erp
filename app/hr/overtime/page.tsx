// app/hr/overtime/page.tsx
// OVERTIME-1(2026-09-28):现场员工的加班 —— 按月一批。财务在这里开批、录行、交去批;
// 仓库从运营菜单进来,在批次页上一次批完或驳回。OS 只报【小时】,不报钱(政策 7.1)。
//
// ★【空态不是一张空下拉】(Tim Q17)一个现场员工都没标的时候,开批钮【看得见、按不动】,
//   旁边一行说没有人被标为现场员工、去哪里标。判断读 overtime_site_staff() —— 与库里
//   create_overtime_batch 的 OVERTIME_NO_SITE_STAFF 是同一件事的两半。
// ★ state 恒为 'ok' —— 开批表单是这一页唯一的出口,画在行数判断之外(与 /hr/attendance 同一条理由)。
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatMonth, toYearMonth } from '@/lib/dates'
import { mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { ListPage } from '@/app/components/ui/list-page'
import NewBatchForm from './NewBatchForm'
import BatchesTable, { type BatchRow } from './BatchesTable'

export default async function OvertimePage() {
    const denied = await requireFunction(FN.overtime)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const [staffRes, batchRes, lineRes, canEnter] = await Promise.all([
        supabase.rpc('overtime_site_staff'),
        supabase.from('overtime_batches')
            .select('id, label, period_month, seq, status, submitted_at, decided_at')
            .order('period_month', { ascending: false })
            .order('seq', { ascending: false }),
        supabase.from('overtime_lines').select('batch_id, employee_id, hours, voided_at'),
        can('action.overtime_enter'),
    ])
    const staff = mustRows(staffRes, 'overtime_site_staff')
    const batches = mustRows(batchRes, 'overtime_batches')
    const lines = mustRows(lineRes, 'overtime_lines')

    // 每一批的行数、人数、小时合计 —— 作废的行(冲销 / 丢弃)照样数,那一批当时说的就是它们
    const agg = new Map<string, { lines: number; people: Set<string>; hours: number }>()
    for (const l of lines) {
        const a = agg.get(l.batch_id) ?? { lines: 0, people: new Set<string>(), hours: 0 }
        a.lines += 1
        a.people.add(l.employee_id)
        a.hours += Number(l.hours)
        agg.set(l.batch_id, a)
    }
    const rows: BatchRow[] = batches.map((b) => ({
        id: b.id,
        label: b.label,
        periodMonth: b.period_month,
        status: b.status,
        lineCount: agg.get(b.id)?.lines ?? 0,
        people: agg.get(b.id)?.people.size ?? 0,
        hours: agg.get(b.id)?.hours ?? 0,
    }))

    // 【月份用一个下拉,不是原生月份框】原生日期控件只许减少(check-date-format 维度③)。
    //   本月与前 11 个月 —— 更早的、或早于系统起点的,库里照样按名拒。
    //   从每月 15 号往回走 30 天,一定落在上一个月里(15 − 30 天 = 上月 13–16 号),所以不会跳月、不会重复。
    const locale = await getLocale()
    const monthOptions: { value: string; label: string }[] = []
    let cursor = Date.parse(toYearMonth(new Date()) + '-15T12:00:00Z')
    for (let i = 0; i < 12; i++) {
        const ym = toYearMonth(new Date(cursor))
        monthOptions.push({ value: ym, label: formatMonth(ym + '-01', locale) })
        cursor -= 30 * 86_400_000
    }

    return (
        <ListPage
            title={t('overtime.title')}
            intro={t('overtime.intro')}
            maxWidth="max-w-5xl"
            state={{ kind: 'ok' }}
        >
            <NewBatchForm canEnter={canEnter} siteStaffCount={staff.length} monthOptions={monthOptions} />
            <BatchesTable rows={rows} empty={t('overtime.empty')} />
        </ListPage>
    )
}
