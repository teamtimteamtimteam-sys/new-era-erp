// app/hr/kpi/score/page.tsx
// C-2:Sandra 录一个月的分 —— /hr/kpi 是报告体,这一屏是登记簿。
//
// ★★【月份【永远】不默认成当月 —— 这是本页最重要的一条】★★
//   Tim 的裁定:一次录入 = 一个月,而那个月是【一件已经发生的事】,
//   不是系统可以替她填的时间戳。九月三十号傍晚打开这一屏的人,可能是在补八月,
//   也可能是在录九月 —— 系统猜错的那一次,分数会落在错的月份上,
//   而错的月份看起来和对的月份一模一样。
//   所以:没有 ?cycle= 就【不画表】,只画选择器和一句话。**没有默认值。**
//
// ★【整页服务端渲染,没有客户端开关】★ 与 /hr/kpi 同一条:藏在开关后面的东西
//   fetch 冒烟永远看不见。刻度表、目标原文、缺席名单全部在初次 HTML 里。
//
// ★【刻度与封顶规则读的是 kpi_score_rubric,不是写死的文案】★
//   打分的规则要能不发版就改正 —— 与公共假期同一条论证(它们都是【数据】)。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import ScoreEditor, { type ScoreRow } from './ScoreEditor'
import GenerateMissing, { type MissingPerson } from './GenerateMissing'

type Cycle = {
    id: string; name: string; period_start: string; period_end: string
    gate: string | null; status: string; locked_at: string | null
}
type Entry = {
    id: string; employee_id: string; source_position_id: string
    kpi_ref: string; title: string; weight_pct: number
    target_text: string; evidence_source: string | null
    is_provisional: boolean; provisional_note: string | null
    org_codes: string[]
    score: number | null; evidence_note: string | null; feedback_note: string | null
    override_cap: number | null; override_reason: string | null
}
type Org = { code: string; title: string; month3_target: string; month6_target: string }
type Rubric = {
    score: number; band_en: string; band_zh: string
    evidence_standard_en: string; management_action_en: string; veto_rule_en: string
}
type Emp = { id: string; legal_name: string; position_id: string | null }

export default async function KpiScorePage({
    searchParams,
}: {
    searchParams: Promise<{ cycle?: string }>
}) {
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    const { cycle: chosenId } = await searchParams

    // ★【读得进来 ≠ 改得动】module.hr.view 的人(auditor)可以看这一屏,
    //   但不该看到一排会被数据库 42501 掉的编辑钮。导航项挂在 edit 上,
    //   而直接敲 URL 进来的人在这里落到只读 —— 两道都要,因为导航只是界面的门。
    const mayScore = await can('module.hr.edit')

    const cycles = mustRows(
        await supabase.from('kpi_cycles')
            .select('id, name, period_start, period_end, gate, status, locked_at')
            .is('deleted_at', null).order('period_start'),
        'kpi_cycles') as Cycle[]
    const rubric = mustRows(
        await supabase.from('kpi_score_rubric')
            .select('score, band_en, band_zh, evidence_standard_en, management_action_en, veto_rule_en')
            .order('score', { ascending: false }),
        'kpi_score_rubric') as Rubric[]

    // ★ 只认【真的存在】的那个 id —— 一个乱填的 ?cycle= 不该退化成"随便挑一个月"。
    const chosen = chosenId ? cycles.find((c) => c.id === chosenId) ?? null : null

    let rows: ScoreRow[] = []
    let missing: MissingPerson[] = []
    if (chosen) {
        const [entries, orgs, staff] = await Promise.all([
            supabase.from('kpi_entries')
                .select('id, employee_id, source_position_id, kpi_ref, title, weight_pct, target_text, evidence_source, is_provisional, provisional_note, org_codes, score, evidence_note, feedback_note, override_cap, override_reason')
                .eq('cycle_id', chosen.id),
            supabase.from('kpi_organisation').select('code, title, month3_target, month6_target'),
            // 【读遮蔽视图,不直连 employees】被扣下的列按权限呈现为 null,
            // 而不是让整条查询 42501 —— check-masked-reads 守的就是这一条。
            supabase.from('employees_masked').select('id, legal_name, position_id').is('deleted_at', null),
        ])
        const es = mustRows(entries, 'kpi_entries') as Entry[]
        const os = mustRows(orgs, 'kpi_organisation') as Org[]
        const st = mustRows(staff, 'employees_masked') as Emp[]

        const orgBy = new Map(os.map((o) => [o.code, o]))
        const empBy = new Map(st.map((e) => [e.id, e]))
        const posBy = new Map<string, string>()
        if (es.length > 0) {
            const positions = mustRows(
                await supabase.from('positions').select('id, code'), 'positions') as { id: string; code: string }[]
            for (const p of positions) posBy.set(p.id, p.code)
        }

        rows = es.map((e) => ({
            id: e.id,
            employeeName: empBy.get(e.employee_id)?.legal_name ?? t('kpi.unknownEmployee'),
            positionCode: posBy.get(e.source_position_id) ?? '',
            kpiRef: e.kpi_ref,
            title: e.title,
            weightPct: Number(e.weight_pct),
            targetText: e.target_text,
            evidenceSource: e.evidence_source,
            isProvisional: e.is_provisional,
            provisionalNote: e.provisional_note,
            orgTargets: (e.org_codes ?? []).flatMap((c) => {
                const o = orgBy.get(c)
                return o ? [{ code: o.code, title: o.title, month3: o.month3_target, month6: o.month6_target }] : []
            }),
            score: e.score,
            evidenceNote: e.evidence_note,
            feedbackNote: e.feedback_note,
            overrideCap: e.override_cap,
            overrideReason: e.override_reason,
        })).sort((a, b) =>
            a.employeeName.localeCompare(b.employeeName) || a.kpiRef.localeCompare(b.kpiRef))

        // 这个月还没有条目的人 —— ★具名的缺席,不是一张空表★(与 /hr/kpi 同一条)
        const haveEntries = new Set(es.map((e) => e.employee_id))
        missing = st
            .filter((e) => !haveEntries.has(e.id))
            .map((e) => ({
                employeeId: e.id,
                name: e.legal_name,
                positionCode: e.position_id ? posBy.get(e.position_id) ?? null : null,
            }))
            .sort((a, b) => a.name.localeCompare(b.name))
    }

    // ★ 锁了就不许改分 —— 与数据库那道守卫是同一条规则的两面。
    //   界面变只读是【礼貌】,score_kpi_entry 的 RAISE 才是【那扇门】。
    const locked = !!chosen?.locked_at
    const canEdit = mayScore && !!chosen && !locked && chosen.status !== 'closed'

    return (
        <ListPage
            title={t('kpi.scoreTitle')}
            intro={t('kpi.scoreWhat')}
            /* ★ 恒为 ok:选择器在任何情况下都要画,走 empty 分支会把它一起吞掉,
               而它正是这一屏空态唯一的出口(survey-hidden-exits)。 */
            state={{ kind: 'ok' }}
        >
            {/* ── 选月份 ★没有默认值★ ────────────────────────────────────── */}
            <form method="get" className="mb-6 flex flex-wrap items-end gap-2">
                <div>
                    <label htmlFor="cycle" className="block text-xs text-gray-600 mb-1">
                        {t('kpi.chooseMonth')}
                    </label>
                    <select
                        id="cycle" name="cycle" defaultValue={chosen?.id ?? ''}
                        className="border border-gray-300 rounded px-2 py-1 text-sm"
                    >
                        {/* ★ 这个空选项是刻意的:它是"还没选"的样子,不是一个默认月份 */}
                        <option value="">{t('kpi.chooseMonthNone')}</option>
                        {cycles.map((c) => (
                            <option key={c.id} value={c.id}>
                                {c.name}
                                {c.gate ? ` — ${c.gate}` : ''}
                                {c.locked_at ? ` (${t('kpi.lockedTag')})` : ''}
                            </option>
                        ))}
                    </select>
                </div>
                <button type="submit" className="border border-gray-400 rounded px-3 py-1 text-sm bg-white">
                    {t('kpi.chooseMonthGo')}
                </button>
            </form>

            {!chosen && (
                <p className="text-sm text-gray-800 max-w-4xl border-l-4 border-blue-500 bg-blue-50 p-3">
                    {t('kpi.noMonthChosen')}
                </p>
            )}

            {chosen && (
                <>
                    {locked && (
                        <div className="border-l-4 border-gray-500 bg-gray-100 p-3 mb-4 max-w-4xl">
                            <p className="text-sm">{t('kpi.lockedNotice', { 0: chosen.name, 1: chosen.gate ?? '' })}</p>
                        </div>
                    )}
                    {!mayScore && (
                        <div className="border-l-4 border-gray-500 bg-gray-100 p-3 mb-4 max-w-4xl">
                            <p className="text-sm">{t('kpi.readOnlyNotice')}</p>
                        </div>
                    )}
                    {!locked && chosen.status === 'closed' && (
                        <div className="border-l-4 border-gray-500 bg-gray-100 p-3 mb-4 max-w-4xl">
                            <p className="text-sm">{t('kpi.closedNotice', { 0: chosen.name })}</p>
                        </div>
                    )}

                    {/* ── ★★ 打分刻度与封顶规则 —— 就画在她打分的这一屏上 ★★ ──────
                        Tim 的裁定:封顶规则必须在界面里,不能只躺在一份文档里。 */}
                    <h2 className="text-lg font-semibold mb-1">{t('kpi.rubricTitle')}</h2>
                    <p className="text-xs text-gray-600 mb-2 max-w-4xl">{t('kpi.rubricWhat')}</p>
                    <div className="space-y-1.5 mb-6 max-w-4xl">
                        {rubric.map((r) => (
                            <div key={r.score} className="border border-gray-300 rounded p-2 text-xs">
                                <div className="flex flex-wrap items-baseline gap-2">
                                    <span className="font-mono font-semibold">{r.score}</span>
                                    <span className="font-semibold">{r.band_en}</span>
                                    <span className="text-gray-700">{r.evidence_standard_en}</span>
                                </div>
                                <div className="mt-1 text-gray-700">{r.management_action_en}</div>
                                {/* ★ 否决那一栏单独高亮 —— 它不是"又一列",它是那条封顶规则 */}
                                <div className="mt-1 text-amber-900 bg-amber-50 border-l-2 border-amber-400 pl-2 py-0.5">
                                    {r.veto_rule_en}
                                </div>
                            </div>
                        ))}
                    </div>

                    <GenerateMissing people={missing} cycleId={chosen.id} disabled={!canEdit} />

                    <h2 className="text-lg font-semibold mb-1">
                        {t('kpi.scoreGridTitle', { 0: chosen.name })}
                    </h2>
                    <p className="text-xs text-gray-600 mb-3 max-w-4xl">{t('kpi.weightedIsComputed')}</p>
                    <ScoreEditor rows={rows} canEdit={canEdit} />
                </>
            )}
        </ListPage>
    )
}
