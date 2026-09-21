'use client'

// 产出化验录入表单。进料侧 AssayForm 是形状的出处,砍掉的是算价预览 ——
// 产出化验不定价。留下的"应用会怎样"是两件事,都在提交【之前】说:
//   * 含量会【整体替换】当前数(化验没报的金属行会消失)—— 对照当前值就在
//     每行旁边(它是录入起点),外加一行明说替换语义;
//   * 过期后果 —— 服务端问库得来(preview_apply_output_assay),这里只显示。
// 两个提交按钮:仅记录 / 记录并应用。后者失败时【记录仍然保留】(见 actions.ts)。
import { CONTROL_CHECKBOX, CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useActionState, useState } from 'react'
import Link from 'next/link'
import type { DictOption } from '@/app/components/dictionaries/dictionaryQuery'
import { useTranslations } from '@/lib/i18n/client'
import DecimalInput from '@/app/components/forms/DecimalInput'
import type { MetalOption } from '@/app/tools/pricing/metal-prices/options'
import { submitOutputAssay, type SubmitOutputAssayState } from '../actions'
import { Button } from '@/app/components/ui/button'
import { EditableTable, type EditableColumn } from '@/app/components/ui/editable-table'

/** 桥上交出去的一行 —— 与搬家前那两条并列数组逐字同构。 */
type MetalLine = { metal: string; content: string }
/** 渲染用的行。`labelKey` 与 `current` 都【不进桥】:一个是译名,一个是对照值,
 *  两个都是画出来的,不是交出去的。 */
type MetalRow = MetalLine & { labelKey: string; current: string | null }

const initialState: SubmitOutputAssayState = {}

function todayIsoLocal(): string {
    const d = new Date()
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

export default function OutputAssayForm({
    labOptions,
    substanceOptions,
    batchId,
    currentMetals,
    impact,
}: {
    // PROC-5:实验室字典(值 + 已翻好的名字),由页面读好传进来
    labOptions: DictOption[]
    // PROC-4:物质清单由页面从 substances 那张字典读好传进来。
    // 【表单不再自己拿着一份清单】那份清单曾经是这份名单的第五个副本,
    // 而它与库里的顺序【实测已经对不上】(它按重要性,库里的视图按字母序)。
    substanceOptions: MetalOption[]
    batchId: string
    currentMetals: Record<string, string>
    // 服务端问库得来的应用后果;null = 试算失败(不挡记录,后果标注"未知")
    impact: {
        producing_run_code: string | null
        producing_run_allocated_at: string | null
        producing_run_basis: string | null
        will_flag_stale: boolean
    } | null
}) {
    const t = useTranslations()
    const bound = submitOutputAssay.bind(null, batchId)
    const [state, formAction, isPending] = useActionState(bound, initialState)
    const [metals, setMetals] = useState<Record<string, string>>(currentMetals)

    const hasCurrent = Object.keys(currentMetals).length > 0

    // ★★★ 桥的行从【页面画出来的那一份名单】来,不从整个 Record 来 ——
    //   理由与 `#18` 逐字相同(见 `AssayForm.tsx` 同一处):`currentMetals` 里
    //   可能有一个**物质已被停用**的金属,它没有一行画出来,搬家前也就没有被提交。
    //   照整个 Record 造桥,它会**开始被写进去**。
    const activeOptions = substanceOptions.filter((s) => s.isActive)
    const rows: MetalRow[] = activeOptions.map((opt) => ({
        metal: opt.value,
        labelKey: opt.labelKey,
        content: metals[opt.value] ?? '',
        current: currentMetals[opt.value] ?? null,
    }))

    /* ★ Q5 的必填 `dirty` —— 判据是「与进门时那一份比」。
       这一页进门时格子里就有字(`currentMetals` 是录入起点),
       按"有没有字"算会一进门就脏。站内 `<Link>` 不拦,是声明过的限制。 */
    const metalsDirty = rows.some((r) => r.content !== (currentMetals[r.metal] ?? ''))

    /* ★★★【有条件的那一列写成【数组字面量里的一段展开】,不写成函数,也不写成三元式】★★★
       这张表的对照列是**有条件的**(`hasCurrent`),而三种写法对【两道闸】不是同一回事:

       | 写法(⚠ 照描述写,**不逐字抄那个属性** —— 两道闸都在扫这个区段) | `check-editable-name` | `check-datatable-phone` |
       |---|---|---|
       | 三元式在两个标识符之间挑 | ✗ 定位不到 | ✗ 定位不到 |
       | 一个**返回列数组的函数调用** | ✓ 认得 `IDENT(...)` 那一种 | ⚠ **不认** —— 实测记一条 `unresolved` |
       | ★ **一个具名的数组字面量** + 有条件那一列在字面量里展开 | ✓ | ✓ |

       ⚠ **实测(DRAFT-4):写成函数那一版,`check-datatable-phone` 记下
         `OutputAssayForm.tsx:266 columns 不是一个可静态定位的标识符`,
         而它【照常退出 0】** —— 也就是 DRAFT-3 §0 的 G3 那条坑,换了一道闸回来:
         **一张没有人守着的表,而构建是绿的。**
       ☞ 所以这里退回最朴素的那一种:**一个具名的数组字面量**,
         有条件的那一列用 `...(cond ? [x] : [])` 展开在**字面量里面** ——
         于是两道闸都定位得到,而且**它们扫的区段把那一列也包进去了**。

       ★★★ 三列的 390px 处置(Tim 的 Q1 / Q2,DRAFT-4):
       · 金属名 `priority` —— 它是这一行的主语;
       · ★ **对照值 `priority`** —— `page-owned` 下展开区只画【有 `edit` 的列】
         (`editable-table.tsx:632`),一个只读且非 priority 的列在 390px 上
         **整个消失**。而这一页的抬头写着:含量是**整体替换**当前数,
         对照值就在每行旁边、它是录入起点。**那个数消失,上面那句琥珀色的
         「替换」警告就失去了它的宾语。** 与 `#8` 的金额列同一条裁定。 */
    const assayCols: EditableColumn<MetalRow, MetalRow>[] = [
        {
            key: 'metal',
            header: t('assay.colMetal'),
            priority: true,
            render: (r) => (
                <>
                    {t(r.labelKey)}
                    <span className="text-gray-400 text-xs ml-2">{r.metal}</span>
                </>
            ),
        },
        {
            key: 'content',
            header: t('assay.colContent'),
            render: (r) => (r.content.trim() === '' ? '—' : r.content),
            edit: (r) => (
                <DecimalInput
                    value={r.content}
                    onChange={(raw) => setMetals((m) => ({ ...m, [r.metal]: raw }))}
                    className="w-28"
                />
            ),
        },
        ...(hasCurrent
            ? [
                  {
                      key: 'current',
                      header: t('assay.output.colCurrent'),
                      priority: true,
                      className: 'text-gray-500',
                      /* ★ 这里的 `—` 是**对的**,而这一句要写下来,免得 Tim 的 Q4 裁定
                         (`#7`:空要写那句话本身,永不 `—`)被抄到一个它不管的地方。
                         `#7` 的空是**一句话**(「没有预期」/「还没有人说过」);
                         这一格的空是**真的没有**:这个金属此前没有录过任何含量。
                         **一个真的没有,写 `—` 就是对的。** 同一个符号,两种案情。 */
                      render: (r: MetalRow) => (r.current === null ? '—' : `${r.current}%`),
                  },
              ]
            : []),
    ]

    return (
        <form action={formAction} className="space-y-6">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}

            {/* 产出化验不定价 —— 与进料侧最大的区别,先说出来,免得有人等一个
                不会出现的价格预览 */}
            <p className="text-sm text-[color:var(--brand-muted-text)] bg-gray-50 border border-gray-200 rounded px-3 py-2">
                {t('assay.output.noPricing')}
            </p>

            {/* ── 单据字段 ── */}
            <div className="flex flex-wrap gap-4">
                <div>
                    <label className="block mb-1">
                        {t('assay.assayDate')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="date"
                        name="assay_date"
                        required
                        max={todayIsoLocal()}
                        defaultValue={todayIsoLocal()}
                        className={CONTROL_INPUT}
                    />
                </div>
                    {/* PROC-6:重量基准 —— 必填,【没有默认选中项】。
                        一份没说明基准的含量数字事后还原不出来:干基 30% 与湿基 30%
                        是两个数,差多少取决于水分。 */}
                    <div>
                        <label className="block mb-1">
                            {t('assay.weightBasis')} <span className="text-red-600">*</span>
                        </label>
                        <select name="weight_basis" defaultValue="" required
                                className={`${CONTROL_SELECT} w-full`}>
                            <option value="" disabled>{t('assay.weightBasisPick')}</option>
                            <option value="as_received">{t('assay.basisAsReceived')}</option>
                            <option value="dry">{t('assay.basisDry')}</option>
                        </select>
                    </div>

                    {/* PROC-6:出具方 —— 必填,【刻意没有默认值】。
                        默认成"我们"会让一个忘了改的字段变成"这是我们测的"这句话。 */}
                    <div>
                        <label className="block mb-1">
                            {t('assay.resultParty')} <span className="text-red-600">*</span>
                        </label>
                        <select name="result_party" defaultValue="" required
                                className={`${CONTROL_SELECT} w-full`}>
                            <option value="" disabled>{t('assay.resultPartyPick')}</option>
                            <option value="ours">{t('assay.partyOurs')}</option>
                            <option value="counterparty">{t('assay.partyCounterparty')}</option>
                            <option value="umpire">{t('assay.partyUmpire')}</option>
                        </select>
                    </div>

                    {/* PROC-6:水分 —— 【可空,而空不是零】。没测就留空;
                        库里落 NULL,屏幕上显示成「没测过」。填 0 是一次测量。 */}
                    <div>
                        <label className="block mb-1">{t('assay.moisture')}</label>
                        <input type="number" name="moisture_pct" step="any" min="0" max="100"
                               placeholder={t('assay.moisturePlaceholder')}
                               className={`${CONTROL_INPUT} w-full`} />
                        <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('assay.moistureHint')}</p>
                    </div>

                <div className="flex-1 min-w-[12rem]">
                    <label className="block mb-1">{t('assay.labName')}</label>
                    {/* PROC-5:实验室 —— 字典下拉,不再是自由文本框。
                        【留空仍然合法】那是"没有人记过是哪家出的"(线上 3 行就是这样),
                        而不是"我们自己做的" —— 后者若要成为一个可记录的事实,
                        它是字典里的一行,不是一个空值的含义。 */}
                    <select name="lab_name" defaultValue=""
                            className={`${CONTROL_SELECT} w-full`}>
                        <option value="">{t('assay.labUnknown')}</option>
                        {labOptions.filter((o) => o.isActive).map((o) => (
                            <option key={o.value} value={o.value}>{o.label}</option>
                        ))}
                    </select>
                    {/* DICT-ADMIN:FIX-2 在这里写的是"还没有这个页面" —— 现在有了。
                        **人撞到墙的那一刻就在这儿**,所以链接放在这儿,
                        而不是只放在导航里(可达性不靠单点)。 */}
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">
                        {t('assay.labAddHint')}{' '}
                        <a href="/settings/dictionaries" className="underline app-link app-link-inline">
                            {t('dict.title')}
                        </a>
                    </p>
                </div>
                <div className="flex-1 min-w-[12rem]">
                    <label className="block mb-1">{t('assay.certificateRef')}</label>
                    <input type="text" name="certificate_ref" className={`${CONTROL_INPUT} w-full`} />
                </div>
                <div className="flex-1 min-w-[10rem]">
                    <label className="block mb-1">{t('assay.sampleRef')}</label>
                    <input type="text" name="sample_ref" className={`${CONTROL_INPUT} w-full`} />
                </div>
            </div>

            <div className="flex flex-wrap gap-4 items-start">
                <div>
                    <label className="flex items-center gap-2">
                        <input className={CONTROL_CHECKBOX} type="checkbox" name="is_final" defaultChecked />
                        {t('assay.isFinal')}
                    </label>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('assay.isFinalHint')}</p>
                </div>
                <div className="flex-1 min-w-[16rem]">
                    <label className="block mb-1">{t('assay.notes')}</label>
                    <input type="text" name="notes" className={`${CONTROL_INPUT} w-full`} />
                </div>
            </div>

            {/* ── 金属表(留空 = 没测,整行忽略;当前值在旁边作对照)── */}
            <div>
                <h2 className="mb-2">{t('assay.title')}</h2>
                {hasCurrent && (
                    <p className="text-xs text-amber-800 mb-2">{t('assay.output.replacesAll')}</p>
                )}
                {/* ★★ (b) 那座桥 —— 画在表外面,只画一遍。理由见 `#18` 同一处。 */}
                <input
                    type="hidden"
                    name="assay_metals_json"
                    value={JSON.stringify(rows.map((r) => ({ metal: r.metal, content: r.content })))}
                />
                <EditableTable<MetalRow, MetalRow>
                    rows={rows}
                    columns={assayCols}
                    // 金属码即键:行来自物质字典,定长,不加行不删行 —— 不需要 uid。
                    rowKey={(r) => r.metal}
                    phone={{ mode: 'columns' }}
                    mode="page-owned"
                    dirty={metalsDirty}
                    labels={{ expand: t('common.expandRow') }}
                    className="max-w-xl"
                />
            </div>

            {/* ── 应用的后果(服务端问库;试算失败不挡记录,但要说"后果未知")── */}
            {impact === null ? (
                <p className="text-sm text-amber-800 bg-amber-50 border border-amber-300 rounded px-3 py-2">
                    {t('assay.output.impactUnavailable')}
                </p>
            ) : impact.will_flag_stale ? (
                <p className="text-sm text-amber-900 bg-amber-50 border border-amber-300 rounded px-3 py-2">
                    {t('assay.output.staleWarning', { run: impact.producing_run_code ?? '?' })}
                </p>
            ) : impact.producing_run_code ? (
                <p className="text-sm text-[color:var(--brand-muted-text)]">
                    {t('assay.output.noStaleEffect', { run: impact.producing_run_code })}
                </p>
            ) : null}

            {/* ── 提交 ── */}
            <div className="flex flex-wrap gap-3 pt-2 border-t">
                <Button variant="secondary"
                    type="submit"
                    name="intent"
                    value="record"
                    disabled={isPending}>
                    {t('assay.saveOnly')}
                </Button>
                <Button
                    type="submit"
                    name="intent"
                    value="record_apply"
                    disabled={isPending}
                >
                    {isPending ? t('common.saving') : t('assay.saveAndApply')}
                </Button>
                <Button asChild variant="secondary">
                    <Link
                        href={`/output/${batchId}/edit`}
                    >
                        {t('common.cancel')}
                    </Link>
                </Button>
            </div>
        </form>
    )
}
