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

export default function ImportForm({ tables }: { tables: string[] }) {
    const t = useTranslations()
    const [table, setTable] = useState(tables[0])
    const [preview, formAction] = useActionState(previewImport, EMPTY)
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
                    <select name="table" value={table} onChange={(e) => setTable(e.target.value)}
                            className="border border-gray-300 rounded px-3 py-2">
                        {tables.map((x) => <option key={x} value={x}>{t(`import.table.${x}`)}</option>)}
                    </select>
                    {/* 模板与这张表【绑在一起】—— 一份通用模板会让人把员工的表头填进物料。 */}
                    <a href={`/settings/import/template/${table}`}
                       className="ml-3 text-sm text-blue-600 hover:underline">
                        {t('import.downloadTemplate')}
                    </a>
                    <p className="text-xs text-gray-500 mt-1">{t('import.templateHint')}</p>
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">{t('import.pickFile')}</label>
                    <input type="file" name="file" accept=".csv,text/csv" className="text-sm" />
                    <p className="text-xs text-gray-500 mt-1">{t('import.oneFilePerTable')}</p>
                </div>
                <button type="submit" className="bg-gray-800 text-white px-4 py-2 rounded text-sm">
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
