// KPI-1:打分那一侧看的那一屏 —— 组织 KPI、职位模板、联动矩阵、roll-up。
//
// 【两个听众,两块屏幕】被考核的人在 /me 上看自己那五条(my_kpi_entries);
// 这一页是【打分的人】看的:组织记分卡、每个职位的模板、以及谁到了谁没到。
//
// ★【整页服务端渲染,没有客户端开关】★ 昨天记下的第三条冒烟盲区说的就是这个:
//   藏在开关后面的话,fetch 冒烟永远看不见。本页每一句都在初次 HTML 里。
//
// CONV-5:【外壳 + 一张表】。这一页是报告体,不是登记簿:组织记分卡是卡片、
// 在册/出缺是名单,两者都保持原样;只有职位联动矩阵是一张真正的行登记簿,
// 换成 DataTable。CONV-4 §⑨-1 在 gst/cashflow/packs 上用的是同一条切分。
// ★ state 恒为 'ok' —— 卡片与名单在任何行数下都要画,走 empty 分支会把
//   页顶那两句判据(orgWeightTotal / staffingGap)一起吞掉。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import KpiMatrixTable, { type KpiMatrixRow } from './KpiMatrixTable'

type Org = {
    code: string; title: string; weight_pct: number
    definition: string; month3_target: string; month6_target: string
    measurement_evidence: string; criticality_note: string
    is_provisional: boolean; provisional_note: string | null
}
type MatrixRow = {
    position_code: string; position_title: string
    o1_count: number; o2_count: number; o3_count: number; o4_count: number; o5_count: number
    kpi_count: number; weight_total: number
}
type Position = { id: string; code: string; title: string; source_incumbent_name: string | null }

export default async function KpiPage() {
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const orgs = mustRows(
        await supabase.from('kpi_organisation')
            .select('code, title, weight_pct, definition, month3_target, month6_target, measurement_evidence, criticality_note, is_provisional, provisional_note')
            .order('sort_order'), 'kpi_organisation') as Org[]
    const matrix = mustRows(
        await supabase.from('kpi_position_linkage_matrix').select('*').order('position_code'),
        'kpi_position_linkage_matrix') as MatrixRow[]
    const positions = mustRows(
        await supabase.from('positions').select('id, code, title, source_incumbent_name').order('sort_order'),
        'positions') as Position[]
    // 谁到了、谁还没到 —— 4.2/§9.1 之外,这是本页最要紧的一句具名缺席
    const attached = mustRows(
        // 【读遮蔽视图,不直连 employees】被扣下的列按权限呈现为 null,
        // 而不是让整条查询 42501 —— 那正是 _masked 存在的理由(check-masked-reads 抓到过)。
        await supabase.from('employees_masked').select('id, code, legal_name, position_id')
            .not('position_id', 'is', null).is('deleted_at', null),
        'employees_masked') as { id: string; code: string; legal_name: string; position_id: string }[]
    const filledPositions = new Set(attached.map((a) => a.position_id))
    const vacant = positions.filter((p) => !filledPositions.has(p.id))

    const orgTotal = orgs.reduce((s, o) => s + Number(o.weight_pct), 0)

    const matrixRows: KpiMatrixRow[] = matrix.map((m) => ({
        positionCode: m.position_code,
        positionTitle: m.position_title,
        o1: m.o1_count, o2: m.o2_count, o3: m.o3_count, o4: m.o4_count, o5: m.o5_count,
        kpiCount: m.kpi_count,
        weightTotal: m.weight_total,
    }))

    return (
        <ListPage title={t('kpi.title')} intro={t('kpi.what')} state={{ kind: 'ok' }}>

            {/* ── 组织记分卡 ─────────────────────────────────────────────── */}
            <h2 className="text-lg font-semibold mb-1">{t('kpi.orgTitle')}</h2>
            <p className="text-xs text-gray-600 mb-3 max-w-4xl">
                {t('kpi.orgWeightTotal', { total: String(orgTotal) })}
            </p>
            <div className="space-y-4 mb-8">
                {orgs.map((o) => (
                    <div key={o.code} className="border border-gray-300 rounded p-4">
                        <div className="flex flex-wrap items-baseline gap-2 mb-2">
                            <span className="font-mono text-sm text-gray-500">{o.code}</span>
                            <span className="font-semibold">{o.title}</span>
                            <span className="text-sm text-gray-700">— {o.weight_pct}%</span>
                            {/* ★ 4.2:暂定的目标要看得出来,而且要说出【暂定到什么为止】★ */}
                            {o.is_provisional && (
                                <span className="text-xs bg-amber-100 text-amber-900 border border-amber-300 px-2 py-0.5 rounded">
                                    {t('kpi.provisionalTag')}
                                </span>
                            )}
                        </div>
                        <p className="text-sm text-gray-800 mb-2">{o.definition}</p>
                        <dl className="grid gap-2 sm:grid-cols-2 text-sm">
                            <div>
                                <dt className="text-xs text-gray-500">{t('kpi.month3')}</dt>
                                <dd>{o.month3_target}</dd>
                            </div>
                            <div>
                                <dt className="text-xs text-gray-500">{t('kpi.month6')}</dt>
                                <dd>{o.month6_target}</dd>
                            </div>
                            <div>
                                <dt className="text-xs text-gray-500">{t('kpi.evidence')}</dt>
                                <dd>{o.measurement_evidence}</dd>
                            </div>
                            <div>
                                <dt className="text-xs text-gray-500">{t('kpi.criticality')}</dt>
                                <dd>{o.criticality_note}</dd>
                            </div>
                        </dl>
                        {o.is_provisional && o.provisional_note && (
                            /* 【暂定的理由是原表自己的句子,不是本仓库的转述】 */
                            <p className="mt-3 text-xs text-amber-900 bg-amber-50 border-l-4 border-amber-400 p-2">
                                {o.provisional_note}
                            </p>
                        )}
                    </div>
                ))}
            </div>

            {/* ── 联动矩阵(职位级)───────────────────────────────────────── */}
            <h2 className="text-lg font-semibold mb-1">{t('kpi.matrixTitle')}</h2>
            {/* ★★ 这句话必须贴着数字放,原表原文 —— 见 §9.1 ★★ */}
            <div className="border-l-4 border-blue-500 bg-blue-50 p-3 mb-3 max-w-4xl">
                <p className="text-sm">{t('kpi.matrixNotWeights')}</p>
            </div>
            <div className="mb-8">
                <KpiMatrixTable rows={matrixRows} empty={t('kpi.matrixEmpty')} />
            </div>

            {/* ── 谁到了、谁没到 ★具名的缺席,不是一片零★ ──────────────────── */}
            <h2 className="text-lg font-semibold mb-1">{t('kpi.staffingTitle')}</h2>
            <p className="text-sm text-gray-800 mb-2 max-w-4xl">
                {t('kpi.staffingCount', { filled: String(filledPositions.size), total: String(positions.length) })}
            </p>
            {vacant.length > 0 && (
                /* ★ 一张只显示两个人、什么都不说的 roll-up 看起来像是全部 ★ */
                <div className="border-l-4 border-amber-500 bg-amber-50 p-3 mb-8 max-w-4xl">
                    <p className="text-sm">{t('kpi.staffingGap')}</p>
                    <ul className="mt-2 text-sm list-disc list-inside">
                        {vacant.map((p) => (
                            <li key={p.code}>
                                <span className="font-mono text-xs">{p.code}</span> · {p.title}
                                {p.source_incumbent_name && (
                                    <span className="text-gray-600"> — {t('kpi.staffingNamedInSource', { name: p.source_incumbent_name })}</span>
                                )}
                            </li>
                        ))}
                    </ul>
                </div>
            )}
        </ListPage>
    )
}
