'use client'

// PROC-BUILD-1:一张加工单的【损耗分类】面板。
//
// 【为什么它在这一页】损耗就是在这一页被记下来的 —— 分类如果住在别的地方,
// 它就变成一件"另外要记得做的事",而这个仓库对"要记得做"的处置是把它换成机制。
//
// 【它【不】编辑 loss_qty】MES-4a 起那个数【就是】投入 − 产出,由数据库算。
// 这里记的是【那个数里,我们说得出去向的那一部分】。两者不必相等,而差额
// 由 processing_run_loss_breakdown 说成"还没解释",结算时写解释(平衡那一块)。
//
// ★ MES-4a(Q28):【只追加】。从前这一块直接 upsert / 硬删 —— 改一个数就把旧的抹掉。
//   现在:记一类(record_run_loss)、改一个数 = 更正(correct_run_loss,带理由,旧的留着、看得见)。
//   没有删除:一类"其实没有"就更正成 0,连同为什么。
//
// 【"还没解释"不是"过磅误差"】—— 屏幕上必须照直说。把差额叫成误差,
// 等于把一个记账问题说成一件已经查清的物理事实,而那正是 loss_qty 今天在犯的错。
import { CONTROL_SELECT, CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { recordRunLoss, correctRunLoss, deriveElectrolyteLoss, rederiveElectrolyteLoss } from './lossActions'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'

export type LossCategory = {
    code: string; name_en: string; name_zh: string
    metal_fate: string; is_true_loss: boolean
    /** MES-4b(Q18):这一类能不能算出来(只有电解液挥发) */
    may_be_derived: boolean
}
/** MES-4b(Q17 · Q18):这一炉的工序上「Electrolyte evaporates in this step」与份额(V10;空 = 还没给)。null = 状态改变型,无从谈起。 */
export type ElectrolyteSetting = { applies: boolean; sharePct: number | null; operationCode: string } | null
// MES-4a:一行 = 一类损耗的【当前】那一条(更正链末端);corrected = 它本身是一次更正(理由在 correction_reason)。
export type LossRow = {
    id: number; loss_category_code: string; quantity: number; notes: string | null
    corrected: boolean; correction_reason: string | null
    /** MES-4b(Q16):量出来的(measured)还是算出来的(derived,带当时用的份额) */
    basis: 'measured' | 'derived'; derived_share_pct: number | null
}

export default function LossPanel({
    runId, categories, rows, lossQty, canEdit, canDerive, electrolyte, locale,
}: {
    runId: string
    categories: LossCategory[]
    rows: LossRow[]
    lossQty: number | null
    canEdit: boolean
    /** MES-4b(Q18):算一笔 / 重新算 —— action.processing_aftercare(库里同一个码) */
    canDerive: boolean
    electrolyte: ElectrolyteSetting
    locale: string
}) {
    const t = useTranslations()
    const [error, setError] = useState<string | null>(null)
    const [isPending, startTransition] = useTransition()
    const [formKey, setFormKey] = useState(0)
    // 正在更正的那一行(一次只更正一行)
    const [fixing, setFixing] = useState<number | null>(null)
    const [fixQty, setFixQty] = useState('')
    const [fixReason, setFixReason] = useState('')
    const [deriveNotes, setDeriveNotes] = useState('')

    const label = (c: LossCategory) => (locale === 'zh' ? c.name_zh : c.name_en)
    const byCode = (code: string) => categories.find((c) => c.code === code) ?? null

    const categorised = rows.reduce((s, r) => s + Number(r.quantity), 0)
    // 【空不是零】loss_qty 没记过时,"还没解释多少"这个问题不成立 ——
    // 显示 0 会把它读成"全部解释完了"。视图那一侧也是这么判的。
    const unexplained = lossQty == null ? null : lossQty - categorised

    const lossColumns: Column<LossRow>[] = [
        {
            key: 'category',
            header: t('processing.loss.colCategory'),
            // 身份列:一行损耗的主语是「哪一类去向」。
            priority: true,
            render: (r) => {
                const c = byCode(r.loss_category_code)
                return (
                    <>
                        {c ? label(c) : r.loss_category_code}
                        {/* 【它不是损耗】这句话必须在行上,不在脚注里 ——
                            residue_disposal 记在这里是过渡,不是归宿。 */}
                        {c && !c.is_true_loss && (
                            <span className="ml-2 text-xs text-amber-700">{t('processing.loss.notTrueLoss')}</span>
                        )}
                    </>
                )
            },
        },
        {
            key: 'metalFate', header: t('processing.loss.colMetalFate'), className: 'text-gray-700',
            render: (r) => { const c = byCode(r.loss_category_code); return c ? t('processing.loss.metalFate.' + c.metal_fate) : '—' },
        },
        {
            key: 'qty',
            header: t('processing.loss.colQty'),
            align: 'right',
            // ★ 这张表存在的理由:那一类去向【占了多少】。
            priority: true,
            render: (r) => r.quantity,
        },
        // MES-4b(Q16):每一行说出它是量出来的还是算出来的(算出来的带当时用的份额)
        {
            key: 'basis', header: t('processing.loss.colBasis'),
            render: (r) => (r.basis === 'derived'
                ? t('processing.loss.basisDerived', { share: r.derived_share_pct ?? '' })
                : t('processing.loss.basisMeasured')),
        },
        { key: 'notes', header: t('processing.loss.colNotes'), className: 'text-gray-600', render: (r) => r.notes ?? '—' },
        // MES-4a(Q28):每一行一个「更正」—— 没有删除。更正过的那一行把理由印在行上(旧的数在审计记录里)。
        {
            key: 'correction', header: '', className: 'text-[color:var(--brand-muted-text)]',
            render: (r: LossRow) => (r.corrected ? t('processing.loss.correctedBecause', { reason: r.correction_reason ?? '' }) : ''),
        },
        ...(canEdit ? [{
            key: 'actions',
            header: '',
            align: 'right' as const,
            render: (r: LossRow) => (
                <Button variant="secondary" size="inline" type="button" className="text-sm" disabled={isPending}
                        onClick={() => { setFixing(r.id); setFixQty(String(r.quantity)); setFixReason(''); setError(null) }}>
                    {t('processing.loss.correct')}
                </Button>
            ),
        }] : []),
    ]

    function submit(e: React.FormEvent<HTMLFormElement>) {
        e.preventDefault()
        const fd = new FormData(e.currentTarget)
        setError(null)
        startTransition(async () => {
            const r = await recordRunLoss(runId, fd)
            if (r.error) setError(r.error)
            else setFormKey((k) => k + 1)
        })
    }

    function saveFix() {
        if (fixing === null) return
        setError(null)
        startTransition(async () => {
            const r = await correctRunLoss(runId, fixing, fixQty, fixReason)
            if (r.error) setError(r.error)
            else setFixing(null)
        })
    }
    const fixingRow = rows.find((r) => r.id === fixing) ?? null
    // MES-4b(Q18 · Q19):电解液挥发那一类 —— 能不能算、算过没有、份额在不在
    const derivable = categories.find((c) => c.may_be_derived) ?? null
    const derivedRecorded = derivable ? rows.some((r) => r.loss_category_code === derivable.code) : false
    function derive() {
        setError(null)
        startTransition(async () => {
            const r = await deriveElectrolyteLoss(runId, deriveNotes)
            if (r.error) setError(r.error)
            else setDeriveNotes('')
        })
    }
    function rederive() {
        if (fixing === null) return
        setError(null)
        startTransition(async () => {
            const r = await rederiveElectrolyteLoss(runId, fixing, fixReason)
            if (r.error) setError(r.error)
            else setFixing(null)
        })
    }
    // 已经记过的类别不再出现在"记一类"的下拉里 —— 函数会按名拒(RUN_LOSS_ALREADY_RECORDED);要改它走那一行的「更正」。
    const unrecorded = categories.filter((c) => !rows.some((r) => r.loss_category_code === c.code))

    return (
        <section className="mt-6">
            <h2 className="mb-1">{t('processing.loss.title')}</h2>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-3">{t('processing.loss.intro')}</p>

            <div className="text-sm mb-3 flex flex-wrap gap-x-6 gap-y-1">
                <span><span className="text-[color:var(--brand-muted-text)]">{t('processing.loss.total')}</span>{' '}{lossQty ?? '—'}</span>
                <span><span className="text-[color:var(--brand-muted-text)]">{t('processing.loss.categorised')}</span>{' '}{categorised}</span>
                <span>
                    <span className="text-[color:var(--brand-muted-text)]">{t('processing.loss.unexplained')}</span>{' '}
                    {unexplained ?? t('processing.loss.unexplainedUnknown')}
                </span>
            </div>

            {/* ★ CONV-10:转换前是 {rows.length === 0 ? <p>空</p> : <table>} ——
                两条互斥的分支各画各的。现在表【无条件】画,空态由表自己说,
                于是「这一单没有分类过损耗」和「表画不出来」不再长得一样。
                ☞ 每行的「删」是自成一体的格内控件(状态归本面板,表单在表下面)——
                   留在 DataTable,不是 EditableTable。CONV-8 §④。 */}
            <DataTable
                rows={rows}
                columns={lossColumns}
                rowKey={(r) => String(r.id)}
                phone={{ mode: 'columns' }}
                empty={t('processing.loss.empty')}
            />

            {error && <p className="mt-2 text-sm text-red-700">{error}</p>}

            {fixingRow && (
                <div className="mt-3 border border-gray-200 rounded p-3 flex flex-wrap items-end gap-3" data-loss-fix={fixingRow.id}>
                    <div className="w-full text-sm">
                        {t('processing.loss.correctTitle', { category: byCode(fixingRow.loss_category_code) ? label(byCode(fixingRow.loss_category_code)!) : fixingRow.loss_category_code })}
                    </div>
                    <div>
                        <label className="block mb-1">{t('processing.loss.colQty')}</label>
                        <input type="number" step="any" min="0" value={fixQty} onChange={(e) => setFixQty(e.target.value)}
                               className={`${CONTROL_INPUT} w-32`} />
                    </div>
                    <div className="flex-1 min-w-[12rem]">
                        <label className="block mb-1">{t('processing.loss.correctReason')}</label>
                        <input type="text" value={fixReason} onChange={(e) => setFixReason(e.target.value)}
                               className={`${CONTROL_INPUT} w-full`} />
                    </div>
                    <Button type="button" className="text-sm" disabled={isPending} onClick={saveFix}>
                        {byCode(fixingRow.loss_category_code)?.may_be_derived ? t('processing.loss.saveMeasured') : t('common.save')}
                    </Button>
                    {/* MES-4b(Q19):电解液挥发那一行还可以按现在的份额重新算(同一个理由框) */}
                    {byCode(fixingRow.loss_category_code)?.may_be_derived && electrolyte?.applies && electrolyte.sharePct !== null && canDerive && (
                        <Button type="button" variant="secondary" className="text-sm" disabled={isPending} onClick={rederive}>
                            {t('processing.loss.recalculate', { share: electrolyte.sharePct })}
                        </Button>
                    )}
                    <Button type="button" variant="secondary" className="text-sm" disabled={isPending} onClick={() => setFixing(null)}>
                        {t('common.cancel')}
                    </Button>
                </div>
            )}

            {/* MES-4b(Q17 · Q18):电解液挥发 —— 说明它去了哪(Tim 的工厂事实),以及按份额算一笔的那一格 */}
            {derivable && (
                <div className="mt-4 border border-gray-200 rounded p-3 text-sm" data-section="electrolyte-loss">
                    <p className="mb-2">{t('processing.loss.desc.electrolyte_evaporation')}</p>
                    {electrolyte === null ? null : !electrolyte.applies ? (
                        <p className="text-[color:var(--brand-muted-text)]">{t('processing.loss.deriveNotApplicable')}</p>
                    ) : derivedRecorded ? (
                        <p className="text-[color:var(--brand-muted-text)]">{t('processing.loss.deriveAlreadyRecorded')}</p>
                    ) : electrolyte.sharePct === null ? (
                        <p className="text-amber-700" data-not-set="electrolyte-share">{t('processing.loss.deriveShareUnset')}</p>
                    ) : (
                        <PermissionGate code="action.processing_aftercare" allowed={canDerive}>
                            <div className="flex flex-wrap items-end gap-3">
                                <div className="flex-1 min-w-[12rem]">
                                    <label className="block mb-1">{t('processing.loss.colNotes')}</label>
                                    <input type="text" value={deriveNotes} onChange={(e) => setDeriveNotes(e.target.value)}
                                           className={`${CONTROL_INPUT} w-full`} />
                                </div>
                                <Button type="button" className="text-sm" disabled={isPending} onClick={derive}>
                                    {t('processing.loss.derive', { share: electrolyte.sharePct })}
                                </Button>
                            </div>
                        </PermissionGate>
                    )}
                </div>
            )}

            {/* ROLE-1 Batch 3b:登记损耗是加工善后,归 action.processing_aftercare 或 module.processing.edit
                (canEdit 由页面算好的是两者之一);库里拒的时候点名 aftercare,门上点名的也是它。 */}
            <PermissionGate code="action.processing_aftercare" allowed={canEdit}>
                <form key={formKey} onSubmit={submit} className="mt-3 flex flex-wrap items-end gap-3">
                    <div>
                        <label className="block mb-1">{t('processing.loss.colCategory')}</label>
                        <select name="loss_category_code" required defaultValue=""
                                className={CONTROL_SELECT}>
                            <option value="" disabled>{t('processing.loss.pick')}</option>
                            {unrecorded.map((c) => (
                                <option key={c.code} value={c.code}>{label(c)}</option>
                            ))}
                        </select>
                    </div>
                    <div>
                        <label className="block mb-1">{t('processing.loss.colQty')}</label>
                        <input name="quantity" type="number" step="any" min="0" required
                               className={`${CONTROL_INPUT} w-32`} />
                    </div>
                    <div className="flex-1 min-w-[12rem]">
                        <label className="block mb-1">{t('processing.loss.colNotes')}</label>
                        <input name="notes" type="text"
                               className={`${CONTROL_INPUT} w-full`} />
                    </div>
                    <Button variant="default" className="text-sm" type="submit" disabled={isPending}>
                        {t('common.save')}
                    </Button>
                </form>
            </PermissionGate>
        </section>
    )
}
