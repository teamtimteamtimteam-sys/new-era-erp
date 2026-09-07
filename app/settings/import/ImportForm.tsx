'use client'

// app/settings/import/ImportForm.tsx —— 选表 → 下模板 → 传文件 → 预览 → 提交。
import { useActionState, useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { previewImport, commitImport } from './actions'
import { issueSentence } from './importErrorCodes'
import type { PreviewResult, ImportIssue } from './types'
import { Button } from '@/app/components/ui/button'

const EMPTY: PreviewResult = {
    ok: false, table: '', rowCount: 0, issues: [], nearDuplicates: [], rows: [], fileName: '',
}

// ════════════════════════════════════════════════════════════════════════════
// 【这一页的每一个控件,在每一种状态下是什么样 —— 一张表,而不是散落的条件】(FIX-4)
//
// 走查的最后一条:**提交成功之后那个按钮不见了,刷新一下又回来。**
// 机制不是"按钮坏了",是下面这个三元:`{done !== null ? 成功框 : 提交钮}` ——
// 它把按钮【换掉】了。而真正的毛病比这大一圈:**提交之后这一页没有回到一个
// 自洽的状态** —— `preview` 还攥着旧的行,于是那句绿色的「N 行可以装进…」还在,
// 而它现在是假的(那些行已经进去了);文件框还挂着那个文件;近重复的勾还勾着。
//
// **为什么这比看起来重了一档:** 一个提交完看不见按钮的人,会认为提交没发生,
// **于是他再传一次**。而导入【没有撤回的路】—— 那一次误读的代价是第二批真行。
//
//   状态                     选择器  模板链接  文件框  预览钮  提交钮            重来钮
//   ─────────────────────────────────────────────────────────────────────────────
//   1 没选表                  可改    灰(不可点) 禁用   禁用    禁用 + 说明        —
//   2 选了表、没预览           可改    可点      启用   启用    禁用 + 说明        —
//   3 预览被拒                可改*   可点      启用   启用    禁用 + 说明(去改文件) —
//   4 预览通过、无近重复       可改*   可点      启用   启用    **启用**           —
//   5 预览通过、有近重复未勾    可改*   可点      启用   启用    禁用 + 说明(去勾)  —
//   6 预览通过、有近重复已勾    可改*   可点      启用   启用    **启用**           —
//   7 提交进行中              禁用    可点      禁用   禁用    禁用(进行中)      —
//   8 提交被拒                可改*   可点      启用   启用    **启用**(可重试)   —
//   9 提交成功                禁用    可点      禁用   禁用    **禁用 + "已经导过了"** **在**
//
//   * 改选择器会【清掉预览】—— 见下面 IMPORT-2 那一段的更正。
//
// 【第 9 行是这次修的重点,而且刻意不自动重置】自动重置会把"成功了"那句话一起抹掉,
// 而那句话正是防止他再传一次的东西。所以:成功框留着、提交钮**留在原地但禁用并说明
// 为什么**、重来是一次【明确的点击】。**一个消失的控件与一个禁用并说明的控件,
// 在屏幕上必须分得开** —— 那是这一节的规矩。
export default function ImportForm(props: {
    tables: string[]
    guide: Record<string, {
        status: 'ok' | 'unavailable'
        cols: { column_name: string; is_required: boolean; accepted_values: string[] | null }[]
    }>
}) {
    // 【重来 = 把整个向导重新挂载】useActionState 没有 reset,而"清干净"要连
    // 文件框一起清 —— key 变了就是一次干净的重新开始,不用手写六个 setState。
    const [epoch, setEpoch] = useState(0)
    return <ImportWizard key={epoch} {...props} onReset={() => setEpoch((e) => e + 1)} />
}

function ImportWizard({
    tables, guide, onReset,
}: {
    onReset: () => void
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
    // 【IMPORT-2 的更正:那次修法造出了一个【不听人话】的控件】(FIX-4)
    // IMPORT-2 把两个变量合成一个,写的是 `preview.table || picked` ——
    // **于是只要预览跑过一次,选择器就再也改不动了**:服务端那个值永远赢。
    // 把"一个事实两处陈述"修成"其中一处永远压过另一处",换来的是一个
    // **无视操作员**的控件。一个事实一个变量是对的,而那个变量必须听人的。
    // 现在:`picked` 是唯一的那个值;**改它就清掉预览**(预览属于上一张表,
    // 留着它就又出现两个事实了)。
    const [picked, setPicked] = useState('')
    const [preview, formAction] = useActionState(previewImport, EMPTY)
    const [staleTable, setStaleTable] = useState(false)
    const table = picked

    // ══════ 【staleTable 必须【会被放下】,否则这一页永远提交不了】══════════════
    // 这一条是 FIX-4 自己的缺陷,记下来因为它的形状值得记:**一个只会被【置上】、
    // 从来不被【放下】的标志位。** 改选择器时 setStaleTable(true),而没有任何一处
    // 把它设回 false —— 于是 `previewLive` 在第一次选表之后【永久】为假,
    // 提交钮永久禁用,**整个导入页交付即是死的**。
    //
    // **它比原来那个"按钮不见了"更坏**:按钮不见了的人会刷新一下再试,
    // 而一个永远灰着并说着"先预览一个文件"的按钮,会让他以为是自己的文件不对 ——
    // 他会去改文件,而问题不在文件里。
    //
    // 【为什么在 render 里调整而不是 useEffect】这是 React 官方那条
    // "prop 变了就调整 state" 的写法:新预览一到就把标志放下,同一次渲染里收敛,
    // 不多一帧闪烁。useEffect 会先画一帧【拿着新预览却仍然作废】的画面。
    const [seenPreview, setSeenPreview] = useState(preview)
    if (preview !== seenPreview) {
        setSeenPreview(preview)
        setStaleTable(false)
    }

    // 预览属于哪一张表,与选择器现在指着哪一张 —— 不一致时不猜,把预览作废。
    // 【两道判据各管一件事,都需要】
    //   * `preview.table === picked` 管【预览属于别的表】—— 也管"预览在飞的时候
    //     人又改了选择器"那一种;
    //   * `!staleTable` 管【改走又改回来】—— A 预览过、切到 B、再切回 A:
    //     表名又对上了,而那份预览属于上一个文件。没有它,一份旧预览会诈尸。
    const previewLive = preview.table !== '' && preview.table === picked && !staleTable
    const [ack, setAck] = useState(false)
    const [done, setDone] = useState<number | null>(null)
    const [commitIssues, setCommitIssues] = useState<ImportIssue[]>([])
    const [pending, start] = useTransition()

    const hadNear = previewLive && preview.nearDuplicates.length > 0
    const previewOk = previewLive && preview.ok
    const canCommit = previewOk && preview.rows.length > 0 && (!hadNear || ack) && done === null && !pending

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
                    <select name="table" value={table} disabled={done !== null || pending}
                            onChange={(e) => { setPicked(e.target.value); setStaleTable(true); setAck(false) }}
                            className="border border-gray-300 rounded px-3 py-2 disabled:bg-gray-100">
                        {/* 【不预选】一个预选好的值不是一次选择 —— 本仓库成文的规矩。
                            而且导错表是【不可撤销】的:把供应商导进客户,只要列名恰好
                            对得上就会成功。一次必须点的选择花一下,弄错要花一次清库。 */}
                        <option value="">{t('import.pickNone')}</option>
                        {tables.map((x) => <option key={x} value={x}>{t(`import.table.${x}`)}</option>)}
                    </select>
                    {/* 模板与这张表【绑在一起】—— 一份通用模板会让人把员工的表头填进物料。 */}
                    {table ? (
                        <Button asChild variant="link" size="inline" className="ml-3">
                            <a href={`/settings/import/template/${table}`}>
                                {t('import.downloadTemplate')}
                            </a>
                        </Button>
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
                    <input type="file" name="file" accept=".csv,text/csv"
                           disabled={!table || done !== null || pending}
                           className="text-sm block w-full max-w-md border border-gray-300 rounded px-3 py-2
                                      bg-white disabled:bg-gray-100 disabled:text-gray-400
                                      file:mr-3 file:rounded file:border-0 file:bg-blue-600 file:px-4
                                      file:py-2 file:text-white file:text-sm hover:file:bg-blue-700" />
                    <p className="text-xs text-gray-500 mt-1">
                        {table ? t('import.oneFilePerTable') : t('import.pickTableFirst')}
                    </p>
                </div>
                <Button className="text-sm" type="submit" disabled={!table || done !== null || pending}>
                    {t('import.preview')}
                </Button>
            </form>

            {previewLive && preview.issues.length > 0 && (
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

            {previewOk && done === null && (
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

            {done !== null && (
                <div className="border border-green-400 bg-green-50 rounded p-4">
                    <p className="font-medium text-green-900">{t('import.committed', { n: done })}</p>
                    <p className="text-xs text-green-800 mt-1">{t('import.committedSequence')}</p>
                </div>
            )}

            {/* 【提交钮【永远在原地】,只是会被禁用并说出原因】——
                它此前在成功之后被整个换掉,而一个消失的按钮读起来是"我没点成"。 */}
            <div className="flex items-center gap-3">
                <Button className="text-sm" type="button" disabled={!canCommit} onClick={onCommit}>
                    {t('import.commit')}
                </Button>
                {done !== null && (
                    <Button variant="secondary" className="text-sm" type="button" onClick={onReset}>
                        {t('import.another')}
                    </Button>
                )}
            </div>
            {/* 【禁用必须说出为什么 —— 每一种禁用各有各的话】 */}
            {!canCommit && (
                <p className="text-xs text-gray-600">
                    {done !== null ? t('import.blockedAlreadyImported')
                     : pending ? t('import.blockedWorking')
                     : !table ? t('import.blockedNoTable')
                     : !previewLive ? t('import.blockedNoPreview')
                     : hadNear && !ack ? t('import.blockedByAck')
                     : t('import.blockedByIssues')}
                </p>
            )}
        </div>
    )
}
