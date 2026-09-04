// app/hr/leave/holidays/page.tsx
// 公共假期维护。【Tim 每年自己补】—— 农历与回历日期要等官方公布,不去算。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import { ListPage } from '@/app/components/ui/list-page'
import LeaveSubnav from '../LeaveSubnav'
import HolidaysEditor from './HolidaysEditor'
import { type HolidayRow } from './HolidaysTable'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function HolidaysPage({
    searchParams,
}: { searchParams: Promise<{ year?: string }> }) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const sp = await searchParams
    const year = Number(sp.year ?? new Date().getFullYear())
    const supabase = await createClient()
    const t = await getTranslations()
    const res = await supabase.from('public_holidays').select('*')
        .gte('holiday_date', `${year}-01-01`).lte('holiday_date', `${year}-12-31`)
        .order('holiday_date')
    // C-2:【所有年份】的键,不只是这一年的 —— 明年那一行要和今年用同一个键,
    // 而按年份筛过的清单恰好看不见去年用的是什么。
    // ★ mustRows,不是 `?? []` —— 一次失败不是一个空集。这一句要是被权限拒了,
    //   `?? []` 会把它变成"一个键都没用过",于是 datalist 空着,而人会照着空的
    //   清单重新打一遍字 —— 正好造出这一列要防的那种不一致。
    const knownKeys = Array.from(
        new Set((mustRows(
            await supabase.from('public_holidays').select('holiday_key'),
            'public_holidays.holiday_key',
        ) as { holiday_key: string }[]).map((r) => r.holiday_key))
    ).sort()

    return (
        <ListPage
            title={t('hr.title')}
            maxWidth="max-w-4xl"
            // ★【子导航 + 年份筛选表单 —— 与 CONV-2 §⑧ 第 2 条同形】★
            //   两者都不是"提示",但都要在状态分支之前渲染:子导航是这一页的
            //   出口(去别的假别子页),筛选表单是 GET 表单,提交就是导航。
            notices={
                <>
                    <LeaveSubnav />
                    <form method="get" className="mb-4 flex items-end gap-2">
                        <label className="text-sm">
                            {t('leave.leaveYear')}
                            <input type="number" name="year" defaultValue={year}
                                   className="mt-1 block w-28 rounded border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] px-2 py-1 text-sm" />
                        </label>
                        <button type="submit" className="rounded border border-[color:var(--brand-border)] px-3 py-1 text-sm">
                            {t('leave.filter')}
                        </button>
                    </form>
                    <p className="mb-4 text-sm text-[color:var(--brand-muted-text)]">{t('leave.holidaysIntro')}</p>
                </>
            }
            // ★【恒为 ok —— 见 HolidaysTable 里的说明】★
            //   「新增假期」那张表单是这一页唯一能加第一行的地方,它住在 children 里。
            //   一年一行都没有时,ListPage 的 empty 分支会把 children 连同这张表单
            //   一起藏掉,所以空态改由 DataTable 自己的 empty prop 说。
            state={{ kind: 'ok' }}
        >
            <HolidaysEditor rows={mustRows(res) as HolidayRow[]} year={year} knownKeys={knownKeys} />
        </ListPage>
    )
}
