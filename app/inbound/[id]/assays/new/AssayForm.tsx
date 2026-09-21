'use client'

// 化验录入表单 + 实时影响预览。
//
// 金属表以【批次当前已录含量】为起点 —— 化验多半是对既有数字的更正,小改远比重敲省事。
// 含量或日期一变就(防抖后)重算一次预览:调服务端动作走 calculate_metal_price,
// 把完整明细摊开,再给出"如果应用"的对比 —— 当前单价 / 新单价 / 每公斤差额 /
// 总调整额,以及会怎样拆进存货与销售成本。客户端不做任何算术。
//
// 两个提交按钮:仅记录 / 记录并应用。后者失败时【记录仍然保留】(见 actions.ts)。
import { CONTROL_CHECKBOX, CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useActionState, useEffect, useState } from 'react'
import Link from 'next/link'
import type { DictOption } from '@/app/components/dictionaries/dictionaryQuery'
import { useTranslations } from '@/lib/i18n/client'
import { RefusalBlock } from '@/app/components/ui/refusal'
import DecimalInput from '@/app/components/forms/DecimalInput'
import type { MetalOption } from '@/app/tools/pricing/metal-prices/options'
import AssayImpactPreview from '../AssayImpactPreview'
import {
    submitAssay,
    previewAssayPrice,
    type SubmitAssayState,
    type PreviewState,
} from '../actions'
import { Button } from '@/app/components/ui/button'
import { EditableTable, type EditableColumn } from '@/app/components/ui/editable-table'

/** 桥上交出去的一行。★ 形状与搬家前那两条并列数组【逐字同构】:
 *  一个金属码 + 一个含量字符串,一行一对。服务端因此只换【行从哪来】,
 *  那个 `Record<metal, content>` 与 `metalsPayload` 一个字都没有动。 */
type MetalLine = { metal: string; content: string }
/** 渲染用的行:多带一个 labelKey,而它【不进桥】—— 译名是画出来的,不是交出去的。 */
type MetalRow = MetalLine & { labelKey: string }

const initialState: SubmitAssayState = {}

function todayIsoLocal(): string {
    const d = new Date()
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

export default function AssayForm({
    labOptions,
    substanceOptions,
    batch,
    formula,
    pricingRestricted = false,
    currentMetals,
    baseCurrency,
}: {
    // PROC-5:实验室字典(值 + 已翻好的名字),由页面读好传进来
    labOptions: DictOption[]
    // PROC-4:物质清单由页面从 substances 那张字典读好传进来。
    // 【表单不再自己拿着一份清单】那份清单曾经是这份名单的第五个副本,
    // 而它与库里的顺序【实测已经对不上】(它按重要性,库里的视图按字母序)。
    substanceOptions: MetalOption[]
    batch: {
        id: string
        code: string
        quantity: number
        unit: string
        unit_price: number | null
        pricing_status: string
    }
    formula: { id: string; code: string; name: string } | null
    /** FIX-2a：读不到计价（module.pricing.view）。null 的 formula 因此
     *  【说不出】这批货有没有公式 —— 那一句必须换成一句拒绝。 */
    pricingRestricted?: boolean
    currentMetals: Record<string, string>
    // ASY-3:影响块用它标出自己的货币(面板在那里换单位)
    baseCurrency: string
}) {
    const t = useTranslations()
    const bound = submitAssay.bind(null, batch.id)
    const [state, formAction, isPending] = useActionState(bound, initialState)

    const [assayDate, setAssayDate] = useState(todayIsoLocal())
    const [metals, setMetals] = useState<Record<string, string>>(currentMetals)
    const [preview, setPreview] = useState<PreviewState>({})
    const [previewing, setPreviewing] = useState(false)

    // 含量/日期变化 → 防抖重算预览。setState 都发生在异步回调里,不在 effect 主体中。
    const metalsKey = JSON.stringify(metals)
    useEffect(() => {
        if (!formula) return
        let cancelled = false
        const timer = setTimeout(() => {
            setPreviewing(true)
            previewAssayPrice({
                batchId: batch.id,
                metals: JSON.parse(metalsKey),
                referenceDate: assayDate,
            })
                .then((res) => {
                    if (!cancelled) {
                        setPreview(res)
                        setPreviewing(false)
                    }
                })
                // ════════════════════════════════════════════════════════
                // ★【CLEANUP-A:这里从前只把转圈关掉,而那比"什么都不说"更坏】★
                //   previewAssayPrice 自己已经把 RPC 的【拒绝】变成 { error },
                //   红横幅也画得出来。会掉进这个 catch 的是【抛出来】的那一支
                //   (网络断、server action 传输失败、动作里意外抛错)。
                //   从前的写法只 setPreviewing(false),于是 preview 保持【上一次的值】——
                //   如果上一次成功,屏幕上继续摆着一个**过期的价格**,而
                //   applyBlocked = !!preview.error 仍然是 false,
                //   **"记录并应用"照样是主按钮**。操作员于是可能按着一个
                //   悄悄没刷新的试算把化验应用下去。
                //   所以:① 说出来;② 【把过期的结果一起清掉】——
                //   只挂横幅而把那个数字留在屏幕上,危险的东西还在原地。
                // ════════════════════════════════════════════════════════
                .catch((e) => {
                    if (cancelled) return
                    console.error('assay pricing preview failed', e)
                    setPreviewing(false)
                    setPreview({ error: t('assay.errPreviewFailed') })
                })
        }, 400)
        return () => {
            cancelled = true
            clearTimeout(timer)
        }
    }, [batch.id, formula, metalsKey, assayDate, t])

    const res = preview.result
    const impact = preview.impact
    const negative = res?.negative_value === true || (res ? res.unit_price_usd_per_kg <= 0 : false)

    // ASY-1:【预览报错 = 应用一定会失败】—— 试算与提交现在走同一段算术、同一批闸
    // (承诺条款、汇率、期间锁/年结),所以预览的红横幅就是提交的拒绝。既然如此,
    // "记录并应用"不该再摆成主按钮:不提供服务端保证会拒的控件。理由横幅已经在
    // 屏幕上说清了,这里只让按钮跟着它走 —— 不另写一句话。
    // 【警告不是拒绝】净值 ≤ 0(negative)照旧可应用:含量要落地,只是不定价。
    const applyBlocked = !!preview.error

    // ★★★【桥的行从【页面画出来的那一份名单】来,不从整个 Record 来】★★★
    //   `metals` 这个 Record 的起点是 `currentMetals` —— 批次上【已经录过】的含量。
    //   一个金属当初录过、而它的物质后来被停用,它在这个 Record 里【还在】,
    //   却【没有一行画出来】(下面这条 `isActive` 过滤)。
    //   ☞ 搬家前那两条并列数组只收得到画出来的那些,所以那个停用金属
    //     **在提交时是被丢掉的**;桥如果照着整个 Record 造,它会**开始被写进去**。
    //   ⚠ 照直记一句,免得下一个人以为这是本刀弄出来的:
    //     **提交与预览今天就对不上** —— `previewAssayPrice` 收的是整个 `metals`
    //     (`:85`),提交收的是过滤后的那一份。**本刀不改这件事,只是不让它变形。**
    const activeOptions = substanceOptions.filter((s) => s.isActive)
    const rows: MetalRow[] = activeOptions.map((opt) => ({
        metal: opt.value,
        labelKey: opt.labelKey,
        content: metals[opt.value] ?? '',
    }))

    /* ★ Q5 的必填 `dirty`:它只喂 `beforeunload`。
       ☞【判据是「与进门时那一份比」,不是「有没有字」】这一页进门时
         **格子里就有字**(`currentMetals` 是批次当前已录的含量,化验多半是
         对既有数字的更正)。按"有没有字"算,一进门就是脏的,提醒立刻变噪音。
         —— 与 `#9 TemplateForm` 同一条判据,理由也是同一条。
       ☞【它盖不住的那一半,照直说】站内 `<Link>`(下面那颗「取消」/ 返回)不拦,
         那是组件抬头声明过的限制。 */
    const metalsDirty = rows.some((r) => r.content !== (currentMetals[r.metal] ?? ''))

    /* ★ 列。**身份列 `priority: true`**(Tim 的 Q1,DRAFT-4):
       `page-owned` 下 `editing` 恒为真,而展开区只画【有 `edit` 的列】
       (`editable-table.tsx:632`)—— 一个只读且非 priority 的列在 390px 上
       **整个消失**。金属名是这一行唯一的主语,它一消失,展开区就没有主语了。 */
    const metalColumns: EditableColumn<MetalRow, MetalRow>[] = [
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
            // 留空 = 没测,整行忽略 —— 那句话在表上面那个标题旁边写着,不在格子里重复。
            render: (r) => (r.content.trim() === '' ? '—' : r.content),
            edit: (r) => (
                <DecimalInput
                    value={r.content}
                    onChange={(raw) => setMetals((m) => ({ ...m, [r.metal]: raw }))}
                    className="w-28"
                />
            ),
        },
    ]

    return (
        <form action={formAction} className="space-y-6">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}

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
                        value={assayDate}
                        onChange={(e) => setAssayDate(e.target.value)}
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

            {/* ── 金属表(留空 = 没测,整行忽略)── */}
            <div>
                <h2 className="mb-2">{t('assay.title')}</h2>
                {/* ★★ (b) 那座桥 —— **画在表外面,只画一遍**(Tim 2026-09-21 的 Q1 裁定)。
                    组件把列回调画两遍(桌面格 `hidden sm:block` + 手机展开区),
                    所以具名输入不许进格子;这一个不在格子里,于是它在 `FormData` 里
                    **只出现一次**。`scripts/check-editable-name.mjs` 守着前半句。
                    ★ 交出去的是 `MetalLine`,**`labelKey` 不在里面** —— 那是画出来的,
                      不是交出去的(与 `#24` 的 `i` 同一条:它不进 `lines_json`)。 */}
                <input
                    type="hidden"
                    name="assay_metals_json"
                    value={JSON.stringify(rows.map((r) => ({ metal: r.metal, content: r.content })))}
                />
                <EditableTable<MetalRow, MetalRow>
                    rows={rows}
                    columns={metalColumns}
                    // 金属码即键:这张表的行来自物质字典,**定长,不加行不删行**
                    // —— 下标从头到尾指着同一个槽,所以它不需要 uid(与 `#6`/`#7` 同理)。
                    rowKey={(r) => r.metal}
                    phone={{ mode: 'columns' }}
                    mode="page-owned"
                    dirty={metalsDirty}
                    labels={{ expand: t('common.expandRow') }}
                    className="max-w-md"
                />
            </div>

            {/* ── 实时预览 ── */}
            {pricingRestricted ? (
                /* ★ FIX-2a(b)：不是「这批货没有计价公式」——那是一句断言，
                   而这个读者根本无从知道。Tim 的 Q4 裁定：价格不给现场，
                   所以这里【不放宽】，只把断言换成一句具名的拒绝。 */
                <RefusalBlock
                    statement={t('assay.pricingRestricted')}
                    hint={t('assay.pricingRestrictedHint')}
                    code="module.pricing.view"
                />
            ) : !formula ? (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded text-sm">
                    {t('assay.noFormula')}
                </div>
            ) : (
                <section className="border-t pt-6">
                    <div className="flex items-center gap-3 mb-3">
                        <h2 className="">{t('assay.impactPreview')}</h2>
                        {previewing && <span className="text-sm text-gray-400">{t('common.saving')}</span>}
                    </div>

                    {preview.error && (
                        <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-3 text-sm">
                            {preview.error}
                        </div>
                    )}

                    {negative && (
                        <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-3 text-sm">
                            {t('assay.negativeValue')}
                        </div>
                    )}

                    {/* impact 可能没有(净值 ≤ 0 时 DB 不给试算)—— 计价明细照常显示 */}
                    {res && <AssayImpactPreview res={res} impact={impact} baseCurrency={baseCurrency} />}
                </section>
            )}

            {/* ── 提交 ── */}
            <div className="flex flex-wrap gap-3 pt-2 border-t">
                {/* 应用被拦时,"仅记录"接过主按钮 —— 它此刻【是】那条可走的路:
                    化验单是实验室出的客观事实,先落库,定价等条款/汇率/期间理顺再说。 */}
                <Button variant={applyBlocked ? 'default' : 'secondary'}
                    type="submit"
                    name="intent"
                    value="record"
                    disabled={isPending}>
                    {t('assay.saveOnly')}
                </Button>
                <Button variant={applyBlocked ? 'secondary' : 'default'}
                    type="submit"
                    name="intent"
                    value="record_apply"
                    disabled={isPending || applyBlocked}>
                    {isPending ? t('common.saving') : t('assay.saveAndApply')}
                </Button>
                <Button asChild variant="secondary">
                    <Link
                        href={`/inbound/${batch.id}/edit`}
                    >
                        {t('common.cancel')}
                    </Link>
                </Button>
            </div>
        </form>
    )
}
