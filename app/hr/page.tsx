// app/hr/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-7 ②(2026-09-04)· 人力 Overview —— 【重建】,它此前是一块待办看板
// ════════════════════════════════════════════════════════════════════════════
//
// 【它此前是什么】一块 hr_alerts 的待办看板(准证到期、试用期届满、工资未录),
//   加底下一小条在职人数。抬头写着「这块看板就是本模块值得占一个导航位的理由」。
//
// ★【为什么那块看板离开了这一页,而这【不是】把它删掉】★
//   CONV-7 ① 把全站的【提醒】收拢到 /tools/reminders,理由是信号天生跨模块。
//   hr_alerts 从头到尾就是提醒:每一条都是"有人得去办",而办完就消失。
//   所以它跟着它的性质走 —— **整块搬到提醒页去了,一行都没有丢**,
//   在那里它还多了一样东西:与其余 34 支并排,看的人一次看完。
//   本页因此空出来,由这一刀填上它【真正该答】的那个问题。
//
// ★【那这一页现在答什么 —— 完整论证见 docs/module-overview-basis.md】★
//   二级菜单已经把人力名下 11 条都列了一遍,所以 Overview 不许是它们的卡片排列
//   (Tim 的裁定)。它答的是:**这支队伍此刻是什么状态** —— 而入选的判据只有
//   一条:**这个事实横跨若干张子页面,任何一张自己都说不出来。**
//   /hr/employees 是一本【名册】:它列人,它不陈述构成;
//   /hr/attendance 与 /hr/payroll 各管一段,而"能不能发这个月的工资"
//   取决于两者的关系,两页都不说。
//
// ★★【为什么人力是本刀选的两个之一 —— 它是财务的反面】★★
//   Tim 的话:「只对财务成立的形状不是那个形状。」这个形状必须同时在
//   【钱】和【人】上成立,所以两个一起建:
//     · 财务 31 条二级、六个第三级分组、每个数都是金额;
//     · 人力 11 条平铺、没有一个数是"账面余额",单位是人和天。
//   而人力还多带一样财务没有的东西 —— ↓
//
// ★★【D5 在这一页上有一个【真的】例子,不是构造出来的】★★
//   实测 live 授权(2026-09-04):
//     module.hr.view = admin · auditor · gm · hr
//     data.view_pay  = admin · cfo   · finance · hr
//   **auditor 与 gm 进得来这一页,而【没有】data.view_pay。**
//   于是第三条陈述(月固定工资总额)对他们必须画成【具名的受限】——
//   不是空白,不是 0,而是「受限(data.view_pay)」。
//   这是这套权限模型里少有的一处"同一页、不同人看到不同格数"的地方,
//   而它此前从来没有被任何一页表达过。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD, allows } from '@/lib/modules'
import { getMyPermissions } from '@/lib/permissions'
import { mustRows, mustCount } from '@/lib/db-helpers'
import { formatAmount, businessToday } from '@/lib/format'
import Figure from '@/app/components/overview/Figure'

type DirectoryRow = { employment_status: string; work_category: string }
type PayrollRow = { period_month: string; status: string }
// employees_masked:**monthly_salary 会因权限变成 null,monthly_salary_set 不会**。
// 那个生成列存在的全部理由就是把「有没有」与「是多少」分开(hr_alerts 靠它才不会
// 对所有人 42501)。本页用同一条分界:【几个人录了】人人看得见,【总共多少钱】受限。
type SalaryRow = { monthly_salary: number | null; monthly_salary_set: boolean | null }

// 在册 = 还在这支队伍里。离职的人仍在目录里,但不算在职。
const IN_SERVICE = ['probation', 'active', 'notice']

export default async function HrOverviewPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const t = await getTranslations()
    const supabase = await createClient()
    const perms = await getMyPermissions()

    // ★【薪酬那一格:先判权限,再决定查不查】★
    //   与提醒页「受限的支根本不开门」逐字同一条规矩。从空结果倒推"你没权限"
    //   是这个仓库反复在治的那个病 —— 而这里它还多错一层:
    //   遮蔽视图对无权读者返回的是 **null**,不是空集,于是"没权限"与
    //   "这个人没录工资"长得一模一样。**必须由权限来分,不能由值来分。**
    const canPay = allows('data.view_pay', perms)

    const [dirRes, attendanceCountRes, payrollRes] = await Promise.all([
        supabase.from('employee_directory').select('employment_status, work_category'),
        supabase.from('attendance_periods').select('id', { count: 'exact', head: true }),
        supabase
            .from('payroll_periods')
            .select('period_month, status')
            .order('period_month', { ascending: false })
            .limit(1),
    ])

    // 【每一支都过 must*】—— 一次失败的查询必须是失败。旧版这一页用的是
    // `?? []`,于是一次 RLS 拒绝会渲染成「0 人在职」。AGENTS.md 那一条。
    const directory = mustRows(dirRes, 'employee_directory') as DirectoryRow[]
    const attendancePeriods = mustCount(attendanceCountRes, 'attendance_periods')
    const payroll = (mustRows(payrollRes, 'payroll_periods') as PayrollRow[])[0] ?? null

    let salaries: SalaryRow[] = []
    if (canPay) {
        salaries = mustRows(
            await supabase
                .from('employees_masked')
                .select('monthly_salary, monthly_salary_set')
                .in('employment_status', IN_SERVICE)
                .is('deleted_at', null),
            'employees_masked salary'
        ) as SalaryRow[]
    }

    const inService = directory.filter((d) => IN_SERVICE.includes(d.employment_status))
    const byStatus = new Map<string, number>()
    for (const d of inService) byStatus.set(d.employment_status, (byStatus.get(d.employment_status) ?? 0) + 1)
    const byCategory = new Map<string, number>()
    for (const d of inService) byCategory.set(d.work_category, (byCategory.get(d.work_category) ?? 0) + 1)
    const separated = directory.length - inService.length

    const salarySet = salaries.filter((s) => s.monthly_salary_set).length
    const salaryTotal = salaries.reduce((n, s) => n + Number(s.monthly_salary ?? 0), 0)

    // 【业务时区的今天】—— 与财务 Overview 同一条,理由在 lib/format.ts。
    // 这一页的今天只进标签,不进谓词,所以它错了不会改变任何数字 ——
    // 但一个【标错日期的基准】比没有基准更坏,而两页写两种今天必然漂开。
    const today = businessToday()
    // 与财务同一条:标签说「时点」,值只给日期(见那一页同一处注释)。
    const asOfLabel = today

    return (
        <div className="p-4 sm:p-8 max-w-3xl">
            <h1 className="text-2xl font-bold mb-1" style={{ color: 'var(--brand-text)' }}>
                {t('nav.hr')}
            </h1>
            <p className="text-sm mb-6 max-w-2xl" style={{ color: 'var(--brand-muted-text)' }}>
                {t('overview.intro')}
            </p>

            {/* ── ① 队伍的构成 ─────────────────────────────────────────── */}
            <Figure
                title={t('hrOverview.headcountTitle')}
                basis={{
                    asOf: asOfLabel,
                    source: t('hrOverview.headcountSource'),
                    spans: t('hrOverview.headcountSpans'),
                }}
                state={
                    directory.length === 0
                        ? /* 【一个人都没有 ≠ 0 人在职】—— 说出为什么 */
                          { kind: 'unanswerable', why: t('hrOverview.headcountEmpty') }
                        : { kind: 'ok' }
                }
                action={
                    <Link href="/hr/employees" className="hover:underline" style={{ color: 'var(--brand-ocean-fill)' }}>
                        {t('hr.subnav.employees')}
                    </Link>
                }
            >
                <p className="text-sm mb-1" style={{ color: 'var(--brand-text)' }}>
                    {t('hrOverview.headcountLine', { n: String(inService.length) })}
                </p>
                <ul className="text-sm space-y-0.5" style={{ color: 'var(--brand-muted-text)' }}>
                    {IN_SERVICE.filter((s) => (byStatus.get(s) ?? 0) > 0).map((s) => (
                        <li key={s}>
                            {t('hr.employmentStatus.' + s)}:
                            <span className="font-mono ml-1">{byStatus.get(s)}</span>
                        </li>
                    ))}
                    {['office', 'shopfloor']
                        .filter((c) => (byCategory.get(c) ?? 0) > 0)
                        .map((c) => (
                            <li key={c}>
                                {t('hr.workCategory.' + c)}:
                                <span className="font-mono ml-1">{byCategory.get(c)}</span>
                            </li>
                        ))}
                    {/* 【离职的人【说出来】,但不并进总数】—— 一个消失的分母
                        比一个说错的分母更难发现。 */}
                    {separated > 0 && <li>{t('hrOverview.separated', { n: String(separated) })}</li>}
                </ul>
            </Figure>

            {/* ── ② 考勤与薪资:两页各管一段,而它们的关系没有页面在说 ──── */}
            {/* 【为什么这两件事画在【同一条】陈述里】因为要紧的是它们之间那件事:
                一个月的工资算不算得出来,取决于那个月的考勤期收没收 ——
                /hr/attendance 只说考勤,/hr/payroll 只说工资,**衔接没有主**。
                拆成两条陈述就等于把这一页也变成两页的复述。 */}
            <Figure
                title={t('hrOverview.cycleTitle')}
                basis={{
                    asOf: asOfLabel,
                    source: t('hrOverview.cycleSource'),
                    spans: t('hrOverview.cycleSpans'),
                }}
                state={{ kind: 'ok' }}
                action={
                    <Link href="/hr/payroll" className="hover:underline" style={{ color: 'var(--brand-ocean-fill)' }}>
                        {t('hr.subnav.payroll')}
                    </Link>
                }
            >
                <p className="text-sm" style={{ color: 'var(--brand-text)' }}>
                    {payroll
                        ? t('hrOverview.payrollLatest', {
                              month: payroll.period_month.slice(0, 7),
                              status: t('hrOverview.payrollStatus.' + payroll.status),
                          })
                        : /* ★【一期都没有跑过 ≠ 这个月没跑】说出是哪一种】★ */
                          t('hrOverview.payrollNever')}
                </p>
                <p className="text-sm mt-1" style={{ color: 'var(--brand-text)' }}>
                    {attendancePeriods === 0
                        ? /* ★【0 个考勤期是一句【关于这套系统还没被用起来】的话】★
                             它不是"这个月的考勤是空的" —— 那两句会引出完全不同的下一步。 */
                          t('hrOverview.attendanceNever')
                        : t('hrOverview.attendanceCount', { n: String(attendancePeriods) })}
                </p>
            </Figure>

            {/* ── ③ 月固定工资总额:本页的 D5 那一格 ────────────────────── */}
            {/* ★【三种状态在这一格上【全都会真的发生】,所以它是这一刀的试金石】★
                  · 受限        —— auditor / gm(实测:有 module.hr.view,无 data.view_pay);
                  · 答不上来    —— 有权限,但在册的人一个都没录(实测:6 人 0 录);
                  · 有答案      —— 录了之后。
                把后两者压成同一个 0,就是把「没有依据」说成「零元」——
                而月固定工资是【假期补偿的取数来源】,一个假的 0 会一路走到钱上。 */}
            <Figure
                title={t('hrOverview.salaryTitle')}
                basis={{
                    asOf: asOfLabel,
                    source: t('hrOverview.salarySource'),
                    spans: t('hrOverview.salarySpans'),
                }}
                state={
                    !canPay
                        ? { kind: 'restricted', permission: 'data.view_pay' }
                        : salarySet === 0
                          ? { kind: 'unanswerable', why: t('hrOverview.salaryNoneSet', { n: String(salaries.length) }) }
                          : { kind: 'ok' }
                }
            >
                <p className="text-sm" style={{ color: 'var(--brand-text)' }}>
                    {t('hrOverview.salaryLine', {
                        amount: formatAmount(salaryTotal, null),
                        set: String(salarySet),
                        total: String(salaries.length),
                    })}
                </p>
            </Figure>

            {/* 【提醒在别处 —— 给一条路,不复制信号】这一页刻意不画任何一条
                hr_alerts:它们【全部】在提醒页上,而两处都画就是两份会各自漂开的实现。 */}
            <p className="text-sm mt-6">
                <Link href="/tools/reminders" className="hover:underline" style={{ color: 'var(--brand-ocean-fill)' }}>
                    {t('reminders.title')}
                </Link>
                <span className="ml-2" style={{ color: 'var(--brand-muted-text)' }}>
                    {t('hrOverview.remindersBoundary')}
                </span>
            </p>
        </div>
    )
}
