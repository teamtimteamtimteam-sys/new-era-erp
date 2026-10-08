'use client'

// MES-5a-1(2026-10-08,规格 §3.1;MES-5a Step 0 Q4 · Q6 · Q13,Tim):批次页上的模组数与逐模组放电结论。
//   【模组数】收货时可选,这里随时补;放电结果记下第一条之前必须有(BATCH_MODULE_COUNT_REQUIRED);不许低于已有结论的模组数;
//   这一批一旦"已放电并核实"就锁住(库里的守卫判,这里不重算)。只对装电芯的形态摆出来(与电芯结构同一个判据)。
//   【谁能改】那个模块的编辑码,或 action.processing_commit(放电站台的操作员)—— 缺码时控件看得见、按不动,说出那个码(PermissionGate)。
//   【逐模组】每个模组此刻的结论(最新一条,任何一炉):通过 / 失败 · 再放电 / 失败 · 隔离 / 已拆去隔离;放过几次;与 V9 矛盾的标出来。
//   结果在放电那一炉的页面上记 —— 这里只读。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import type { BatchDischargeData, ModuleSummaryRow } from './moduleDischargeQuery'
import { setBatchModuleCount } from './moduleCountActions'

export default function ModuleCountPanel({ kind, batchId, current, data, canEdit, gateCode, canOpenRuns }: {
    kind: 'inbound' | 'output'
    batchId: string
    current: number | null
    data: BatchDischargeData
    canEdit: boolean
    /** 缺码时点名的那个码(模块编辑码 —— 另一个能改它的是 action.processing_commit) */
    gateCode: string
    /** 持加工查看码:放电那一炉的单号可以点进去 */
    canOpenRuns: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [value, setValue] = useState(current === null ? '' : String(current))
    const [error, setError] = useState<string | null>(null)
    const st = data.status
    const runLink = (id: string, code: string) => (canOpenRuns
        ? <Link href={`/operation/processing/${id}`} className="hover:underline app-link app-link-inline">{code}</Link>
        : <span>{code}</span>)

    const columns: Column<ModuleSummaryRow>[] = [
        { key: 'module', header: t('discharge.colModule'), priority: true, render: (m) => <span className="font-mono">{m.moduleRef}</span> },
        {
            key: 'verdict', header: t('discharge.colLatest'), priority: true,
            render: (m) => (m.splitOut ? <span className="text-[color:var(--brand-muted-text)]">{t('discharge.verdict.splitOut')}</span>
                : m.verdict === 'pass' ? <span className="text-green-700">{t('discharge.verdict.pass')}</span>
                    : <span className="text-red-700">{m.disposition === 'quarantine' ? t('discharge.verdict.failQuarantine') : t('discharge.verdict.failRedischarge')}</span>),
        },
        { key: 'outlet', header: t('discharge.colOutletV'), render: (m) => `${m.outletV} V` },
        { key: 'flag', header: t('discharge.colV9'), render: (m) => (m.contradicts === true ? <span className="text-red-700">{t('discharge.contradictsShort')}</span> : m.contradicts === null ? t('discharge.notJudged') : '—') },
        { key: 'when', header: t('discharge.colVerdictAt'), render: (m) => m.verdictAt },
        { key: 'run', header: t('discharge.colRun'), render: (m) => runLink(m.runId, m.runCode) },
        { key: 'attempts', header: t('discharge.colAttempts'), render: (m) => String(m.attempts) },
    ]

    return (
        <section className="mb-8" data-section="module-count">
            <h2 className="mb-2">{t('discharge.batchTitle')}</h2>
            <div className="border border-gray-300 rounded p-3 max-w-3xl space-y-3">
                <p className="text-sm">
                    {t('discharge.moduleCount')}: <strong>{current === null ? t('discharge.countNotSet') : current}</strong>
                    {st && st.moduleCount !== null && (
                        <> · {t('discharge.progress', { done: st.passed + st.splitOut, count: st.moduleCount })}</>
                    )}
                    {st && (st.verified
                        ? <span className="ml-2 text-green-700 font-medium" data-verified="yes">{t('discharge.verified')}</span>
                        : st.latestRunId ? <span className="ml-2 text-amber-700" data-verified="no">{t('discharge.notVerified')}</span> : null)}
                </p>
                {st && st.latestRunId && st.latestRunCode && (
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('discharge.latestRun')} {runLink(st.latestRunId, st.latestRunCode)}</p>
                )}
                {data.splitFrom && (
                    <p className="text-sm" data-split-from="1">
                        {t('discharge.splitFromLine', { modules: data.splitFrom.modules.join(', ') })}{' '}
                        {data.splitFrom.splitRunCode ? runLink(data.splitFrom.splitRunId, data.splitFrom.splitRunCode) : null}
                    </p>
                )}
                <PermissionGate code={gateCode} allowed={canEdit}>
                    <div className="flex flex-wrap items-end gap-3">
                        <label className="block">
                            <span className="block text-xs font-medium text-[color:var(--brand-muted-text)] mb-1">{t('discharge.moduleCount')}</span>
                            <input type="number" min="1" step="1" value={value} onChange={(e) => setValue(e.target.value)} className={`${CONTROL_INPUT} w-24`}
                                   disabled={!!st?.verified} />
                        </label>
                        <Button type="button" disabled={pending || !!st?.verified || value === (current === null ? '' : String(current))}
                                onClick={() => {
                                    setError(null)
                                    start(async () => {
                                        const r = await setBatchModuleCount(kind, batchId, value)
                                        if (r.error) { setError(r.error); return }
                                        router.refresh()
                                    })
                                }}>
                            {t('common.save')}
                        </Button>
                    </div>
                </PermissionGate>
                <p className="text-xs text-[color:var(--brand-muted-text)]">{st?.verified ? t('discharge.countLocked') : t('discharge.countHint')}</p>
                {error && <p className="text-sm text-red-700" role="alert">{error}</p>}
                <DataTable rows={data.modules} columns={columns} rowKey={(m) => m.moduleRef} phone={{ mode: 'columns' }} empty={t('discharge.noResultsBatch')} />
            </div>
        </section>
    )
}
