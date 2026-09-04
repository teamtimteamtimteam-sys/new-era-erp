'use client'

// app/hr/kpi/score/ScoreEditor.tsx
// C-2:一个月的打分网格 —— CONV-2 的 A 型(一次编辑一行)。
//
// 【为什么是 A 型而不是 B 型】一行要填三样(分 / 证据 / 反馈)外加可选的封顶,
// 而且每一行旁边还压着一整段只读的目标原文。全行同时可编辑会把三十行 × 四个输入
// 一起摊在屏幕上,没有人能在那样一张表上知道自己改到哪儿了。
//
// ★★【加权分是【算】出来的,而且【当场】算给她看】★★
//   Tim 的裁定:她不录加权分,系统算。这里把它画成一个随打字变化的只读格 ——
//   **不是等保存之后再回来看**。理由与 EditableTable 的"脏是算出来的"同一条:
//   一个派生值只要还有第二个来源(人手打的、或保存后才刷新的),它就会漂。
//   算式逐字照原表:分 ÷ 5 × 权重,封顶后取 LEAST —— 与 kpi_employee_rollup
//   和 score_kpi_entry 里那两处是同一个式子。
//
// ★【目标原文贴着输入放,不是折叠起来】★
//   Tim:没有它,她得开着表格再开着这一屏。所以 target_text / 证据来源 /
//   所链组织 KPI 的 M3 与 M6 目标,全部画在【她打分那一格的左边】。
import { useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { EditableTable, type EditableColumn } from '@/app/components/ui/editable-table'
import { scoreKpiEntry } from './actions'

/** 一条 KPI 在这一屏上的样子。org 目标是【读出来贴上的】,不是回查模板。 */
export type ScoreRow = {
    id: string
    employeeName: string
    positionCode: string
    kpiRef: string
    title: string
    weightPct: number
    targetText: string
    evidenceSource: string | null
    isProvisional: boolean
    provisionalNote: string | null
    /** 所链组织 KPI 的 M3 / M6 目标 —— 逐条,原文。 */
    orgTargets: { code: string; title: string; month3: string; month6: string }[]
    score: number | null
    evidenceNote: string | null
    feedbackNote: string | null
    overrideCap: number | null
    overrideReason: string | null
}

type Draft = {
    score: number | null
    evidenceNote: string | null
    feedbackNote: string | null
    overrideCap: number | null
    overrideReason: string | null
}

const inp = 'w-full border border-gray-300 rounded px-1 py-0.5 text-xs'
const ta = 'w-full border border-gray-300 rounded px-1 py-0.5 text-xs min-h-[3.5rem]'

/** 分 ÷ 5 × 权重,封顶后取 LEAST —— 与数据库那两处是同一个式子。 */
function weightedOf(score: number | null, cap: number | null, weight: number): number | null {
    if (score === null || Number.isNaN(score)) return null
    const effective = cap === null || Number.isNaN(cap) ? score : Math.min(score, cap)
    return Math.round((effective / 5) * weight * 100) / 100
}

const numOrNull = (v: string): number | null => (v.trim() === '' ? null : Number(v))
const textOrNull = (v: string): string | null => (v.trim() === '' ? null : v)

export default function ScoreEditor({ rows, canEdit }: { rows: ScoreRow[]; canEdit: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [, startTransition] = useTransition()

    const columns: EditableColumn<ScoreRow, Draft>[] = [
        {
            // ★ 身份列:手机上留在表里,用来认清"我在给谁的哪一条打分"。不可编辑。
            key: 'who',
            header: t('kpi.colWho'),
            priority: true,
            className: 'text-sm align-top',
            render: (r) => (
                <>
                    <div className="font-medium">{r.employeeName}</div>
                    <div className="text-xs text-gray-500">
                        <span className="font-mono">{r.positionCode}</span> · <span className="font-mono">{r.kpiRef}</span>
                    </div>
                </>
            ),
        },
        {
            // ★★ 目标原文就住在这里 —— 贴着她打分的地方。见抬头。 ★★
            key: 'kpi',
            header: t('kpi.colKpiAndTarget'),
            priority: true,
            className: 'text-sm align-top max-w-md',
            render: (r) => (
                <>
                    <div className="font-medium">{r.title}</div>
                    <div className="text-xs text-gray-600 mt-0.5">
                        {t('kpi.weightIs', { 0: String(r.weightPct) })}
                    </div>
                    {r.isProvisional && (
                        <span className="inline-block mt-1 text-[10px] bg-amber-100 text-amber-900 border border-amber-300 px-1.5 py-0.5 rounded">
                            {t('kpi.provisionalTag')}
                        </span>
                    )}
                    {r.isProvisional && r.provisionalNote && (
                        <p className="mt-1 text-[10px] text-amber-900 bg-amber-50 border-l-2 border-amber-400 p-1">
                            {r.provisionalNote}
                        </p>
                    )}
                    <dl className="mt-1.5 text-xs">
                        <dt className="text-[10px] text-gray-500">{t('kpi.ownTarget')}</dt>
                        <dd className="text-gray-800">{r.targetText}</dd>
                        <dt className="text-[10px] text-gray-500 mt-1">{t('kpi.evidence')}</dt>
                        {/* ★ 三十格全空是原表的事实,不是一个待办 —— 说出来,不留白 */}
                        <dd className="text-gray-800">{r.evidenceSource ?? t('kpi.noEvidenceSource')}</dd>
                    </dl>
                    {r.orgTargets.map((o) => (
                        <div key={o.code} className="mt-1.5 border-l-2 border-gray-300 pl-2">
                            <div className="text-[10px] text-gray-500">
                                <span className="font-mono">{o.code}</span> · {o.title}
                            </div>
                            <div className="text-xs"><span className="text-gray-500">{t('kpi.month3')}:</span> {o.month3}</div>
                            <div className="text-xs"><span className="text-gray-500">{t('kpi.month6')}:</span> {o.month6}</div>
                        </div>
                    ))}
                </>
            ),
        },
        {
            key: 'score',
            header: t('kpi.colScore'),
            align: 'right',
            className: 'align-top',
            render: (r) => (r.score ?? '—'),
            edit: (d, set) => (
                <input
                    type="number" min="0" max="5" step="1" className={inp} value={d.score ?? ''}
                    aria-label={t('kpi.colScore')}
                    onChange={(e) => set({ score: numOrNull(e.target.value) })}
                />
            ),
        },
        {
            // ★ 只读,而且【当场】算 —— 她不录这个数。
            key: 'weighted',
            header: t('kpi.colWeighted'),
            align: 'right',
            className: 'align-top font-mono text-xs',
            render: (r) => weightedOf(r.score, r.overrideCap, r.weightPct) ?? '—',
            // 没有 edit —— 「不给 edit 就是这一列不可编辑」。
        },
        {
            key: 'evidenceNote',
            header: t('kpi.colEvidenceNote'),
            className: 'align-top text-xs',
            render: (r) => r.evidenceNote ?? '—',
            edit: (d, set) => (
                <textarea
                    className={ta} value={d.evidenceNote ?? ''}
                    aria-label={t('kpi.colEvidenceNote')}
                    onChange={(e) => set({ evidenceNote: textOrNull(e.target.value) })}
                />
            ),
        },
        {
            key: 'feedbackNote',
            header: t('kpi.colFeedback'),
            className: 'align-top text-xs',
            render: (r) => r.feedbackNote ?? '—',
            edit: (d, set) => (
                <textarea
                    className={ta} value={d.feedbackNote ?? ''}
                    aria-label={t('kpi.colFeedback')}
                    onChange={(e) => set({ feedbackNote: textOrNull(e.target.value) })}
                />
            ),
        },
        {
            // ★【封顶是一个动作,不是一个分数】★ 原始分留着,两个数都看得见。
            key: 'cap',
            header: t('kpi.colCap'),
            className: 'align-top text-xs',
            render: (r) =>
                r.overrideCap === null ? '—' : (
                    <>
                        <div className="font-mono">{r.overrideCap}</div>
                        <div className="text-[10px] text-gray-600">{r.overrideReason}</div>
                    </>
                ),
            edit: (d, set) => (
                <>
                    <input
                        type="number" min="0" max="5" step="1" className={inp} value={d.overrideCap ?? ''}
                        aria-label={t('kpi.colCap')}
                        onChange={(e) => set({ overrideCap: numOrNull(e.target.value) })}
                    />
                    <textarea
                        className={ta + ' mt-1'} value={d.overrideReason ?? ''}
                        aria-label={t('kpi.capReason')}
                        placeholder={t('kpi.capReasonPlaceholder')}
                        onChange={(e) => set({ overrideReason: textOrNull(e.target.value) })}
                    />
                    {/* 封顶的规则贴在按下它的地方 —— 页顶那张刻度表是全文,这里是那一句 */}
                    <p className="mt-1 text-[10px] text-gray-600">{t('kpi.capHint')}</p>
                </>
            ),
        },
    ]

    return (
        <EditableTable<ScoreRow, Draft>
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            canEdit={canEdit}
            toDraft={(r) => ({
                score: r.score,
                evidenceNote: r.evidenceNote,
                feedbackNote: r.feedbackNote,
                overrideCap: r.overrideCap,
                overrideReason: r.overrideReason,
            })}
            labels={{
                edit: t('common.edit'), save: t('common.save'), saving: t('common.saving'),
                cancel: t('common.cancel'), unsaved: t('common.unsavedRow'), expand: t('common.expandRow'),
            }}
            empty={t('kpi.scoreNoRows')}
            onSave={async (d, row) => {
                const r = await scoreKpiEntry(row.id, {
                    score: d.score,
                    evidenceNote: d.evidenceNote,
                    feedbackNote: d.feedbackNote,
                    overrideCap: d.overrideCap,
                    overrideReason: d.overrideReason,
                })
                // 失败:字留住、行留在编辑态、【不刷新】。
                if (r.error) return { error: r.error }
                startTransition(() => router.refresh())
            }}
        />
    )
}
