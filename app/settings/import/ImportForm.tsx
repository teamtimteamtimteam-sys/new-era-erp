'use client'

// app/settings/import/ImportForm.tsx —— 选表 → 下模板 → 传文件 → 预览 → 提交。
import { useActionState, useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { previewImport, commitImport } from './actions'
import { issueSentence } from './importErrorCodes'
import type { PreviewResult, ImportIssue } from './types'

const EMPTY: PreviewResult = {
    ok: false, table: '', rowCount: 0, issues: [], nearDuplicates: [], rows: [], fileName: '',
}

export default function ImportForm({
    tables, guide,
}: {
    tables: string[]
    /** 每张表的列指南 —— 与模板同一个 RPC,一份来源两处渲染。 */
    guide: Record<string, {
        status: 'ok' | 'unavailable'
        cols: { column_name: string; is_required: boolean; accepted_values: string[] | null }[]
    }>
}) {
    const t = useTranslations()
    // ══════ 【一个事实,一个变量】(IMPORT-2 修的 4.1)══════════════════════════
    // 此前这里有一个 `useState(tables[0])` 的 `table`,而下面每一处都读
    // `preview.table` —— **服务端真正处理的那张表**。两个变量表示同一件事,
    // 于是上传之后选择器画的是【客户端状态】,其余部分画的是【服务端事实】,
    // 两者可以不一致。走查里屏幕说「物料」而系统处理的是供应商,
    // **一张截图因此被读错了一次**。
    //
    // 这不是一个显示 bug,是"一个事实两处陈述"—— 本仓库反复付账的那个形状。
    // 现在只有一个值:预览存在时以服务端的 `preview.table` 为准,否则是人选的那个。
    const [picked, setPicked] = useState('')
    const [preview, formAction] = useActionState(previewImport, EMPTY)
    const table = preview.table || picked
    const [ack, setAck] = useState(false)
    const [done, setDone] = useState<number | null>(null)
    const [commitIssues, setCommitIssues] = useState<ImportIssue[]>([])
    const [pending, start] = useTransition()

    const hadNear = preview.nearDuplicates.length > 0
    const canCommit = preview.ok && preview.rows.length > 0 && (!hadNear || ack) && done === null

    function onCommit() {
        setCommitIssues([])
        start(async () => {
            const r = await commitImport({
                table: preview.table, rows: preview.rows, fileName: preview.fileName,
                acknowledgedNearDuplicates: ack, hadNearDuplicates: hadNear,
            })
            if (r.ok) setDone(r.imported ?? preview.rows.length)
            else setCommitIssues(r.issues)
        })
    }

    return (
        <div className="space-y-6">
            <form action={formAction} className="space-y-4 border border-gray-300 rounded p-4">
                <div>
                    <label className="block text-sm font-medium mb-1">{t('import.pickTable')}</label>
                    <select name="table" value={table} onChange={(e) => setPicked(e.target.value)}
                            className="border border-gray-300 rounded px-3 py-2">
                        {/* 【不预选】一个预选好的值不是一次选择 —— 本仓库成文的规矩。
                            而且导错表是【不可撤销】的:把供应商导进客户,只要列名恰好
                            对得上就会成功。一次必须点的选择花一下,弄错要花一次清库。 */}
                        <option value="">{t('import.pickNone')}</option>
                        {tables.map((x) => <option key={x} value={x}>{t(`import.table.${x}`)}</option>)}
                    </select>
                    {/* 模板与这张表【绑在一起】—— 一份通用模板会让人把员工的表头填进物料。 */}
                    {table ? (
                        <a href={`/settings/import/template/${table}`}
                           className="ml-3 text-sm text-blue-600 hover:underline">
                            {t('import.downloadTemplate')}
                        </a>
                    ) : (
                        <span className="ml-3 text-sm text-gray-400">{t('import.downloadTemplate')}</span>
                    )}
                    <p className="text-xs text-gray-500 mt-1">{t('import.templateHint')}</p>
                    {/* 【取值受限的列,在【屏幕上】也说一遍】—— 与模板第三行同一个 RPC。
                        走查里 counterparty_type 那三个值是【口头】补上的,那就是这一块的由来。 */}
                    {table && guide[table]?.status === 'unavailable' && (
                        /* 【拿不到 ≠ 没有受限列】—— 说出来,不要让它安静地消失。 */
                        <p className="mt-3 text-xs text-amber-700">{t('import.guideUnavailable')}</p>
                    )}
                    {table && guide[table]?.status === 'ok' && (
                        <div className="mt-3 border border-gray-200 rounded bg-gray-50 p-3 text-xs">
                            <p className="font-medium mb-1">{t('import.guideTitle')}</p>
                            <ul className="space-y-0.5">
                                {guide[table].cols.map((c) => (
                                    <li key={c.column_name}>
                                        <code>{c.column_name}</code>
                                        {c.is_required && <span className="text-red-700"> · {t('import.guideRequired')}</span>}
                                        {c.accepted_values && c.accepted_values.length > 0 &&
                                            <span className="text-gray-600"> · {c.accepted_values.join(' | ')}</span>}
                                    </li>
                                ))}
                            </ul>
                        </div>
                    )}
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">{t('import.pickFile')}</label>
                    {/* 4.2:一个裸 file input 在屏幕上读起来像一行说明文字,不像一个控件。
                        给它边框与内边距,并且**在选表之前禁用** —— 见上面 4.1 那一段。 */}
                    <input type="file" name="file" accept=".csv,text/csv" disabled={!table}
                           className="text-sm block w-full max-w-md border border-gray-300 rounded px-3 py-2
                                      bg-white disabled:bg-gray-100 disabled:text-gray-400
                                      file:mr-3 file:rounded file:border-0 file:bg-gray-800 file:px-3
                                      file:py-1.5 file:text-white file:text-sm" />
                    <p className="text-xs text-gray-500 mt-1">
                        {table ? t('import.oneFilePerTable') : t('import.pickTableFirst')}
                    </p>
                </div>
                <button type="submit" disabled={!table}
                        className="bg-gray-800 text-white px-4 py-2 rounded text-sm disabled:bg-gray-300">
                    {t('import.preview')}
                </button>
            </form>

            {preview.issues.length > 0 && (
                <div className="border border-red-300 bg-red-50 rounded p-4">
                    <p className="font-medium text-red-800 mb-2">
                        {t('import.refused', { n: preview.issues.length })}
                    </p>
                    {/* 【全或全无】—— 说在拒绝旁边,而不是留给人猜。 */}
                    <p className="text-xs text-red-700 mb-3">{t('import.allOrNothing')}</p>
                    <ul className="text-sm text-red-900 space-y-1 max-h-80 overflow-y-auto">
                        {preview.issues.map((it, i) => <li key={i}>· {issueSentence(t, it)}</li>)}
                    </ul>
                </div>
            )}

            {preview.ok && (
                <div className="border border-green-300 bg-green-50 rounded p-4">
                    <p className="font-medium text-green-900">
                        {t('import.previewOk', { n: preview.rowCount, table: t(`import.table.${preview.table}`) })}
                    </p>
                    <p className="text-xs text-green-800 mt-1">{t('import.previewRolledBack')}</p>
                </div>
            )}

            {hadNear && (
                <div className="border border-amber-300 bg-amber-50 rounded p-4">
                    <p className="font-medium text-amber-900 mb-1">{t('import.nearDupTitle')}</p>
                    {/* 【警告,不是拒绝】两家真正不同的公司可以同名 —— 理由在 lib/nearDuplicate.ts。 */}
                    <p className="text-xs text-amber-800 mb-2">{t('import.nearDupWhy')}</p>
                    <ul className="text-sm text-amber-900 space-y-1 mb-3">
                        {preview.nearDuplicates.map((w, i) => (
                            <li key={i}>· {t('import.nearDupRow', {
                                row: w.row, incoming: w.incoming,
                                existing: w.existingName, code: w.existingCode })}</li>
                        ))}
                    </ul>
                    <label className="flex items-start gap-2 text-sm">
                        <input type="checkbox" checked={ack} onChange={(e) => setAck(e.target.checked)}
                               className="mt-1" />
                        <span>{t('import.nearDupAck')}</span>
                    </label>
                </div>
            )}

            {commitIssues.length > 0 && (
                <div className="border border-red-300 bg-red-50 rounded p-4">
                    <p className="font-medium text-red-800 mb-2">{t('import.commitRefused')}</p>
                    <ul className="text-sm text-red-900 space-y-1">
                        {commitIssues.map((it, i) => <li key={i}>· {issueSentence(t, it)}</li>)}
                    </ul>
                </div>
            )}

            {done !== null ? (
                <div className="border border-green-400 bg-green-50 rounded p-4">
                    <p className="font-medium text-green-900">{t('import.committed', { n: done })}</p>
                    <p className="text-xs text-green-800 mt-1">{t('import.committedSequence')}</p>
                </div>
            ) : (
                <button type="button" disabled={!canCommit || pending} onClick={onCommit}
                        className="bg-blue-600 text-white px-4 py-2 rounded text-sm disabled:bg-gray-300">
                    {t('import.commit')}
                </button>
            )}
            {!canCommit && done === null && preview.rowCount > 0 && (
                /* 【一个按不下去的按钮必须说出为什么】 */
                <p className="text-xs text-gray-600">
                    {hadNear && !ack ? t('import.blockedByAck') : t('import.blockedByIssues')}
                </p>
            )}
        </div>
    )
}
