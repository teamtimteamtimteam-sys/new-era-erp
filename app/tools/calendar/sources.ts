// app/tools/calendar/sources.ts — 日历的取数,以及【它为什么不需要自己的权限模型】。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【全部保证就这一句:每一条查询都以【读者自己的会话】发出】★★
// 所以一件事出现在日历上,当且仅当【这个读者本来就能在它自己的模块里看见它】。
// RLS / 遮蔽视图 / 模块判据一个都没有被绕开,也没有被重新实现一遍。
//
// 【为什么这是对的,而"给日历铸一个权限码"是错的】
//   一个日历码只有两种下场:比来源松 → 它把别的模块的东西漏出来;
//   比来源紧 → 一个本来看得见的人在日历上看不见它,而那是一处【无声的缺席】。
//   本仓库对"无声的缺席"付过很多次账(xmodule 那一族)。
//   **不铸码,让每个来源自己说话** —— 这也是 ② 把日历定成【只读】的原因:
//   一旦能编辑,它就必须有自己的写权限模型,那个便宜就没有了。
//
// 【并发取数 —— CHART-1 ② 那一课就在隔壁】
//   七个来源串行取,就是 /settings/dictionaries 那 85 次串行往返的同一个形状
//   (实测 24.9 秒)。这里用 pMap 并发,上限与那一刀同一个常数。
//
// ════════════════════════════════════════════════════════════════════════════
// 【实测(2026-09-03,线上):哪些来源真的存在,哪些【没有日期可以放】】
//
//   ✓ public_holidays              14 行   公共假期
//   ✓ invoices.due_date             9 行   应收到期
//   ✓ containers.expected_arrival   4 行   到港预计
//   ✓ gst_periods.period_end        1 行   申报期结束(期间关闭)
//   ✓ tasks.due_date                1 行   任务到期
//   ✓ leave_calendar                0 行   员工请假(视图在,今天没有行)
//
//   ✗ 审批期限 —— **这个系统里没有这样东西**。带 approval 的表只有 approval_log,
//     那是一本【流水账】(谁在什么时候批的),它没有"什么时候之前要批完"这一列。
//     所以日历上没有这一类,**不是漏了,是没有可放的日期**。要有它,得先有人
//     决定"一条审批的期限从哪来" —— 那是一次产品决定,不是一次取数。
//
//   ✗ 设备保养 —— **它没有到期【日期】**。equipment_service_status 的到期是
//     `due_kg` / `due_days`(EQP-2c:保养间隔按【处理吨数】,因为加工这一族里
//     没有任何工时记录),日期列只有 acquisition_date / last_service_date /
//     baseline_date。把"再加工 3000 公斤就该保养"钉到某一天上【需要一个产量预测】,
//     而那个预测这个系统today 给不出来。**放一个算出来的假日期比不放更坏。**
// ════════════════════════════════════════════════════════════════════════════
import { createClient } from '@/lib/supabase/server'
import { pMap, DEFAULT_QUERY_CONCURRENCY } from '@/lib/pMap'
import type { CalendarItem } from '@/app/components/calendar/MonthGrid'

/** 来源键 —— 也是筛选器的取值。**顺序即图例顺序。** */
export const CALENDAR_KINDS = [
    'holiday', 'leave', 'task', 'invoiceDue', 'containerEta', 'periodClose',
] as const
export type CalendarKind = (typeof CALENDAR_KINDS)[number]

/** 每一类的颜色 —— 全部来自品牌 token,没有第七种颜色被发明出来。 */
export const KIND_COLOR: Record<CalendarKind, string> = {
    holiday: 'var(--brand-accent)',
    leave: 'var(--brand-forest-fill)',
    task: 'var(--brand-ocean-fill)',
    invoiceDue: 'var(--brand-destructive-fill)',
    containerEta: 'var(--brand-muted)',
    periodClose: 'var(--brand-border-strong)',
}

type Row = Record<string, unknown>

/**
 * 把一个区间铺成它覆盖的每一天,并【裁到本月之内】。
 * 【为什么裁】一段跨月的假,在这个月里只应该出现它落在这个月的那几天;
 * 不裁的话上个月的日期会被塞进本月的格子里(而那个格子根本不存在)。
 */
export function expandRange(start: string, end: string, lo: string, hi: string): string[] {
    const from = start > lo ? start : lo
    const to = end < hi ? end : hi
    if (from > to) return []
    const out: string[] = []
    const d = new Date(from + 'T00:00:00')
    const stop = new Date(to + 'T00:00:00')
    while (d <= stop) {
        out.push(`${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`)
        d.setDate(d.getDate() + 1)
    }
    return out
}

/**
 * 取一个月的全部条目。
 *
 * **每一支查询都用传进来的这个 supabase 客户端**(读者的会话)——
 * 这就是"日历没有自己的权限模型"那句话的全部实现。
 */
export async function loadMonth(month: string, locale: string): Promise<{
    items: CalendarItem[]
    /** 逐来源的取数结果 —— 出错要说出来,不能读成"这一类今天没有事" */
    failures: string[]
    ms: number
}> {
    const supabase = await createClient()
    const first = `${month}-01`
    const [y, m] = month.split('-').map(Number)
    const last = `${month}-${String(new Date(y, m, 0).getDate()).padStart(2, '0')}`
    const t0 = Date.now()

    type Spec = {
        kind: CalendarKind
        run: () => Promise<{ data: Row[] | null; error: { message: string } | null }>
        /** 一行可以铺成【多天】—— 请假是区间,不是单日。 */
        map: (r: Row) => CalendarItem[]
    }

    const specs: Spec[] = [
        {
            kind: 'holiday',
            run: () => supabase.from('public_holidays')
                .select('holiday_date, name_en, name_zh')
                .eq('is_active', true).gte('holiday_date', first).lte('holiday_date', last) as never,
            map: (r) => [{
                date: String(r.holiday_date), kind: 'holiday',
                label: String(locale === 'zh' ? r.name_zh : r.name_en),
            }],
        },
        {
            // leave_calendar 是【区间】(start..end),不是单日 —— 展开由下面统一做。
            kind: 'leave',
            run: () => supabase.from('leave_calendar').select('*')
                .lte('start_date', last).gte('end_date', first) as never,
            // ★【请假是一段区间,要【铺满】它覆盖的每一天】★
            // 只放在 start_date 上,一段跨十天的假在日历上只会出现一次 ——
            // 而看排期的人正是要看"这十天里谁不在"。区间要裁到本月之内。
            map: (r) => expandRange(String(r.start_date), String(r.end_date), first, last).map((d) => ({
                date: d, kind: 'leave' as const,
                label: String(r.employee_code ?? r.employee_name ?? '—'),
                href: '/hr/leave',
            })),
        },
        {
            kind: 'task',
            run: () => supabase.from('tasks').select('id, title, due_date')
                .is('deleted_at', null).gte('due_date', first).lte('due_date', last) as never,
            map: (r) => [{
                date: String(r.due_date), kind: 'task', label: String(r.title),
                href: `/tools/tasks/${String(r.id)}`,
            }],
        },
        {
            kind: 'invoiceDue',
            // 【读遮蔽视图,不读基表】invoices 是遮蔽表;而这一页只要
            // 编号与到期日两列(都不是被扣住的列),走 _masked 是免费的。
            run: () => supabase.from('invoices_masked').select('id, code, due_date')
                .gte('due_date', first).lte('due_date', last) as never,
            map: (r) => [{
                date: String(r.due_date), kind: 'invoiceDue', label: String(r.code),
                href: `/finance/invoices/${String(r.id)}`,
            }],
        },
        {
            kind: 'containerEta',
            run: () => supabase.from('containers').select('id, container_no, expected_arrival_date')
                .gte('expected_arrival_date', first).lte('expected_arrival_date', last) as never,
            map: (r) => [{
                date: String(r.expected_arrival_date), kind: 'containerEta',
                label: String(r.container_no), href: `/logistics/containers/${String(r.id)}`,
            }],
        },
        {
            kind: 'periodClose',
            run: () => supabase.from('gst_periods').select('id, period_end')
                .gte('period_end', first).lte('period_end', last) as never,
            map: (r) => [{
                date: String(r.period_end), kind: 'periodClose',
                label: String(r.period_end), href: '/finance/gst',
            }],
        },
    ]

    const results = await pMap(specs, DEFAULT_QUERY_CONCURRENCY, async (s) => {
        const res = await s.run()
        return { kind: s.kind, res, map: s.map }
    })

    const items: CalendarItem[] = []
    const failures: string[] = []
    for (const { kind, res, map } of results) {
        // ★【读不到 ≠ 这一类今天没有事】★ 一个被 RLS 拒掉的读者拿到的是【零行】,
        // 那是对的(他本来就不该看见);而一次真正的【错误】必须说出来 ——
        // 两者在日历上长得一模一样,而含义相反(AGENTS.md 的 mustRows 那一条)。
        if (res.error) { failures.push(`${kind}: ${res.error.message}`); continue }
        for (const r of res.data ?? []) items.push(...map(r))
    }
    items.sort((a, b) => a.date.localeCompare(b.date) || a.label.localeCompare(b.label))
    return { items, failures, ms: Date.now() - t0 }
}
