// app/hr/org/page.tsx — 组织架构图(CHART-1 ③)。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【这一页画的是【库里的汇报关系】,不是任何文档说的那一套】★★
// CHART-1 ③ 明写:数据与 docs/exec-views-plan.md 不一致时【以数据为准】——
// 那份文档已知有七处过期,更正它是它自己的排队项,本刀不动它。
//
// 【实测,2026-09-03 线上】—— 而这个数【会跳】,所以两个都写出来
//   · 静止时:未删 **6** 行(真人 2:EMP-2026-0001 / 0002;
//     另外 4 行是 `ZZ-2BL-*` 走查账号的员工行,ACCOUNTS-CLEAN 刻意留着,
//     见 docs/known-wrong-until-cutover.md)
//   · **冒烟脚本正在跑的时候是 9 行**(多出 3 行 `ZZ-SMOKE-*`,跑完即删)
//   · 两种情况下 **manager_id 非空都是 0 行** · departments 1 行
//   **本页不过滤那些行**:它们是真的行,而一个按命名规则悄悄藏行的页面
//   比多几行坏得多(check-scratch-rows 那一条:报告,不清扫)。
//   出处那一栏因此写着「测试数据」,把这件事说在屏幕上。
// 也就是说**今天这一页画不出一棵树,它画的是"还没有记录任何汇报关系"**,
// 而那正是它必须说得清楚的那句话。
//
// ★【③ 的前提与实测不符,已由 Tim 更正】③ 原写"departments, employees and
//   reporting lines already exist as real data,所以它是唯一今天完全可用的图"。
//   列在、行不在。Tim 已确认前提有误、指令不变:照数据建,把空的说成空的。
//
// ── 权限:【算出来的,不是假设的】(实测 2026-09-03)────────────────────────
//   · 本页由 module.hr.view 把门(requireModule)。持有它的角色实测有四个:
//     **admin · auditor · gm · hr** —— 他们看到【全部】员工。
//   · employees_masked 自己的 WHERE 是
//     `has_permission('module.hr.view') OR id = current_user_employee()`,
//     也就是说一个不持 module.hr.view 的员工,在那张视图上【只看得见自己】。
//     **但他到不了这一页** —— requireModule 先一步给他一句具名的拒绝。
//     两层的答案因此是一致的,而且是"说出来"而不是"渲染成空"。
//   · departments 的 SELECT 策略同样是 has_permission('module.hr.view')。
//
// ★★【遮蔽列:一个都没读】★★
// employees 上被从 authenticated 收回的五列(has_column_privilege 实测):
//   work_email · work_phone · identity_no · work_pass_no · monthly_salary
// 本页读的是:id · code · legal_name · preferred_name · department_id ·
//            manager_id · employment_status —— **五列一个都不在其中**,
// 而且读的是 employees_masked 而不是基表(check-masked-reads 的棘轮)。
// ════════════════════════════════════════════════════════════════════════════
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { buildOrgTree, type OrgEmployee, type OrgDepartment } from '@/lib/orgTree'
import ChartCard from '@/app/components/charts/ChartCard'
import OrgChart from '@/app/components/charts/OrgChart'

type EmpRow = {
    id: string
    code: string
    legal_name: string
    preferred_name: string | null
    department_id: string | null
    manager_id: string | null
    employment_status: string
}

type DeptRow = { id: string; code: string; name_en: string; name_zh: string }

export default async function OrgPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    // 【两条查询并发,不串行】—— 它们互不依赖(CHART-1 ② 那一课就在隔壁)
    const [empRes, deptRes] = await Promise.all([
        supabase.from('employees_masked')
            .select('id, code, legal_name, preferred_name, department_id, manager_id, employment_status')
            .is('deleted_at', null)
            .order('code'),
        supabase.from('departments')
            .select('id, code, name_en, name_zh')
            .is('deleted_at', null)
            .order('code'),
    ])
    // 【查不到不是零】—— 一张空的架构图与一次读失败必须分得开。
    const empRows = mustRows(empRes, 'employees_masked') as unknown as EmpRow[]
    const deptRows = mustRows(deptRes, 'departments') as unknown as DeptRow[]

    const employees: OrgEmployee[] = empRows.map((e) => ({
        id: e.id,
        code: e.code,
        // 【显示名】有小名用小名,否则用法定姓名 —— 与全站其它地方同一条规矩。
        name: e.preferred_name ?? e.legal_name,
        manager_id: e.manager_id,
        department_id: e.department_id,
        employment_status: e.employment_status,
    }))
    const departments: OrgDepartment[] = deptRows.map((d) => ({
        id: d.id,
        code: d.code,
        name: locale === 'zh' ? d.name_zh : d.name_en,
    }))

    const tree = buildOrgTree(employees, departments)

    return (
        <div className="p-6 max-w-5xl">
            <h1 className="text-2xl font-semibold mb-1">{t('org.title')}</h1>
            <p className="text-sm mb-4" style={{ color: 'var(--brand-muted-text)' }}>{t('org.intro')}</p>

            <ChartCard
                title={t('org.chartTitle')}
                basis={{
                    // 【出处】组织架构不是一段期间,它是【此刻】的状态 —— 说清楚。
                    period: t('org.basisPeriod'),
                    // CONV-0 ②c:此前这里印的是 `employees_masked · departments`。
                    // 【走查只点名了另外两张，这一张是同一个形状，一起改】——
                    // 漏掉它，读者就会问为什么单单这张图在报表名。
                    source: t('charts.shows.org'),
                    // 【暂定】线上未删员工里,**静止时 6 个有 4 个**是走查账号的行
                    // (冒烟在跑时 9 个有 7 个)。那是一个【会影响读数】的事实,
                    // 所以它进出处那一栏,不进脚注 —— 出处是每张图都要说的话。
                    provisional: tree.total > 0 ? t('org.basisProvisional') : null,
                }}
                state={tree.total === 0 ? { kind: 'no-rows' } : { kind: 'ok' }}
            >
                <OrgChart tree={tree} />
            </ChartCard>
        </div>
    )
}
