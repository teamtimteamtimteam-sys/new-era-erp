'use client'

// 计价器:谈判时真正会用的那个页面。
// 输入公式 / 数量 / 计价日 / 七个金属的化验含量(留空 = 没测,整行忽略),
// 点"计算"走服务端动作调 DB 函数,把返回的【完整明细】原样摊开 —— 客户端不做任何算术。
// 支持 ?formula=&quantity=&ni=&co=… 预填,便于从批次页直接带着化验结果跳进来。
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useActionState, useState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import DecimalInput from '@/app/components/forms/DecimalInput'
import type { MetalOption } from '@/app/tools/pricing/metal-prices/options'
import PriceBreakdown from '@/app/components/pricing/PriceBreakdown'
import { calculatePrice, type CalculatorState } from './actions'
import { Button } from '@/app/components/ui/button'
import { EditableTable, type EditableColumn } from '@/app/components/ui/editable-table'

/** 桥上交出去的一行 —— 与搬家前那两条并列数组逐字同构。
 *  ★ 这一张是 `#18 AssayForm` 的【孪生】:同样的字段名、同样的字典行、
 *    同样的受控 Record。**而它自己有一处收参点**,所以 DRAFT-4 那句
 *    「按字段名 grep 会把它扫进来,别碰」一分钱都没白付 —— 今天轮到它了。 */
type MetalLine = { metal: string; content: string }
/** 渲染用的行:多带一个 labelKey,而它【不进桥】。 */
type MetalRow = MetalLine & { labelKey: string }

const initialState: CalculatorState = {}

export type FormulaOption = {
    id: string
    code: string
    name: string
    direction: string
}

export default function CalculatorForm({
    substanceOptions,
    formulas,
    prefill,
}: {
    // PROC-4:物质清单由页面从 substances 那张字典读好传进来。
    // 【表单不再自己拿着一份清单】那份清单曾经是这份名单的第五个副本,
    // 而它与库里的顺序【实测已经对不上】(它按重要性,库里的视图按字母序)。
    substanceOptions: MetalOption[]
    formulas: FormulaOption[]
    prefill: { formulaId: string; quantity: string; date: string; assay: Record<string, string> }
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(calculatePrice, initialState)

    const [formulaId, setFormulaId] = useState(prefill.formulaId)
    const [quantity, setQuantity] = useState(prefill.quantity)
    const [assay, setAssay] = useState<Record<string, string>>(prefill.assay)
    const [copied, setCopied] = useState(false)

    const res = state.result

    // ★★★ 桥的行从【页面画出来的那一份 active 名单】来,不从整个 Record 来。
    //   `assay` 的起点是 `prefill.assay`(从 `?ni=&co=…` 查询串带进来的),
    //   它**可以带着一个物质已被停用的金属** —— 那样的金属没有一行画出来,
    //   搬家前也就没有被提交。照整个 Record 造桥,它会**开始被算进价里**。
    const activeOptions = substanceOptions.filter((s) => s.isActive)
    const assayRows: MetalRow[] = activeOptions.map((opt) => ({
        metal: opt.value,
        labelKey: opt.labelKey,
        content: assay[opt.value] ?? '',
    }))

    /* ★ Q5 的必填 `dirty` —— 与进门时那一份比。
       这一页可以带着 `?ni=12.5` 进来,于是**进门时格子里就有字**;
       按「有没有字」算会一进门就脏。
       ⚠ ★★ 照直记一句:**这一页【不写库】** —— `calculatePrice` 只算不写
       (DRAFT-0 §1.2 就是这么记的)。所以这里的 `beforeunload` 拦下的是
       「一次还没算的试算」,不是「一份还没存的数据」。**它仍然值得拦**
       (谈判时手敲七个含量不便宜),而它的份量与别处不同,写下来免得被读重。 */
    const assayDirty = assayRows.some((r) => r.content !== (prefill.assay[r.metal] ?? ''))

    /* ★ 身份列 `priority: true`(Tim 的 Q1):`page-owned` 下展开区只画
       【有 `edit` 的列】(`editable-table.tsx:632`),一个只读且非 priority 的列
       在 390px 上整个消失 —— 金属名是这一行唯一的主语。 */
    const assayColumns: EditableColumn<MetalRow, MetalRow>[] = [
        {
            key: 'metal',
            header: t('pricing.form.colMetal'),
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
            header: t('pricing.colContent'),
            // 留空 = 没测,整行忽略 —— 那句话在表上面的抬头里写着,不在格子里重复。
            render: (r) => (r.content.trim() === '' ? '—' : r.content),
            edit: (r) => (
                <DecimalInput
                    value={r.content}
                    onChange={(raw) => setAssay((a) => ({ ...a, [r.metal]: raw }))}
                    className="w-28"
                />
            ),
        },
    ]

    // 按方向分组,谈采购时不会误选销售公式
    const grouped = [
        { key: 'purchase', items: formulas.filter((f) => f.direction === 'purchase') },
        { key: 'sale', items: formulas.filter((f) => f.direction === 'sale') },
        { key: 'both', items: formulas.filter((f) => f.direction === 'both') },
    ].filter((g) => g.items.length > 0)

    // 纯文本明细:直接粘进给供应商的邮件里,所以只用金属代码 + 数字 + 英文标签
    function breakdownText(): string {
        if (!res) return ''
        const L: string[] = []
        L.push(`${res.formula_code} ${res.formula_name}`)
        L.push(`Reference date: ${res.reference_date}   Quantity: ${res.quantity_kg} kg`)
        L.push('')
        for (const l of res.lines) {
            const price =
                l.price_usd_per_tonne == null
                    ? 'no price'
                    : `${l.price_usd_per_tonne} USD/t${l.price_date ? ` @ ${l.price_date}` : ''}${
                          l.price_from ? ` (${l.price_from}..${l.price_to})` : ''
                      }`
            L.push(
                `${l.metal.toUpperCase().padEnd(3)} content ${l.content_pct}%  payable ${l.payable_pct}%  ` +
                    `contained ${l.contained_kg} kg  payable ${l.payable_kg} kg  ${price}  = ${formatMoneyBare(l.metal_value_usd, '同一行数字后面紧跟的 USD(纯文本明细,逐行自带)')} USD`
            )
        }
        L.push('')
        L.push(`Gross value:     ${formatMoneyBare(res.gross_value_usd, '同一行数字后面紧跟的 USD(纯文本明细,逐行自带)')} USD`)
        L.push(`Treatment:      -${formatMoneyBare(res.treatment_usd, '同一行数字后面紧跟的 USD(纯文本明细,逐行自带)')} USD`)
        L.push(`Discount:       -${formatMoneyBare(res.discount_usd, '同一行数字后面紧跟的 USD(纯文本明细,逐行自带)')} USD`)
        L.push(`Net value:       ${formatMoneyBare(res.net_value_usd, '同一行数字后面紧跟的 USD(纯文本明细,逐行自带)')} USD`)
        L.push(`Unit price:      ${res.unit_price_usd_per_kg} USD/kg`)
        if (res.skipped_metals.length) L.push(`No price: ${res.skipped_metals.join(', ')}`)
        if (res.unpaid_metals.length) L.push(`Not payable: ${res.unpaid_metals.join(', ')}`)
        return L.join('\n')
    }

    async function copyBreakdown() {
        try {
            await navigator.clipboard.writeText(breakdownText())
            setCopied(true)
            setTimeout(() => setCopied(false), 2000)
        } catch {
            /* 剪贴板不可用(非安全上下文)时静默失败 —— 明细本身仍在页面上 */
        }
    }

    return (
        <div className="space-y-6">
            <form action={formAction} className="space-y-4">
                {state.error && (
                    <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                        {state.error}
                    </div>
                )}

                <div className="flex flex-wrap gap-4">
                    <div className="flex-1 min-w-[18rem]">
                        <label className="block mb-1">
                            {t('pricing.calcFormula')} <span className="text-red-600">*</span>
                        </label>
                        <select
                            name="formula_id"
                            required
                            value={formulaId}
                            onChange={(e) => setFormulaId(e.target.value)}
                            className={`${CONTROL_SELECT} w-full`}
                        >
                            <option value="" disabled>
                                {t('pricing.form.name')}
                            </option>
                            {grouped.map((g) => (
                                <optgroup key={g.key} label={t('pricing.direction.' + g.key)}>
                                    {g.items.map((f) => (
                                        <option key={f.id} value={f.id}>
                                            {f.code} — {f.name}
                                        </option>
                                    ))}
                                </optgroup>
                            ))}
                        </select>
                    </div>
                    <div>
                        <label className="block mb-1">
                            {t('pricing.calcQuantity')} <span className="text-red-600">*</span>
                        </label>
                        <DecimalInput
                            name="quantity_kg"
                            required
                            value={quantity}
                            onChange={setQuantity}
                            className="w-36"
                        />
                    </div>
                    <div>
                        <label className="block mb-1">
                            {t('pricing.calcDate')} <span className="text-red-600">*</span>
                        </label>
                        <input
                            type="date"
                            name="reference_date"
                            required
                            defaultValue={prefill.date}
                            className={CONTROL_INPUT}
                        />
                    </div>
                </div>

                <div>
                    <h2 className="mb-2">{t('pricing.calcAssay')}</h2>
                    {/* ★★ (b) 那座桥 —— **画在表外面,只画一遍**(Tim 2026-09-21 的 Q1 裁定)。
                        组件把列回调画两遍(桌面格 `hidden sm:block` + 手机展开区),
                        所以具名输入不许进格子;这一个不在格子里,于是它在 `FormData` 里
                        **只出现一次**。★ 交出去的是 `MetalLine`,`labelKey` 不在里面。 */}
                    <input
                        type="hidden"
                        name="assay_metals_json"
                        value={JSON.stringify(assayRows.map((r) => ({ metal: r.metal, content: r.content })))}
                    />
                    <EditableTable<MetalRow, MetalRow>
                        rows={assayRows}
                        columns={assayColumns}
                        // 金属码即键:行来自物质字典,**定长,不加行不删行** —— 不需要 uid。
                        rowKey={(r) => r.metal}
                        phone={{ mode: 'columns' }}
                        mode="page-owned"
                        dirty={assayDirty}
                        labels={{ expand: t('common.expandRow') }}
                        className="max-w-md"
                    />
                </div>

                <Button
                    type="submit"
                    disabled={isPending}
                    variant="default" size="default"
                >
                    {isPending ? t('common.saving') : t('pricing.calcButton')}
                </Button>
            </form>

            {/* 计价明细 */}
            {res && (
                <section className="border-t pt-6">
                    <div className="flex justify-between items-center mb-3">
                        <h2 className="">{t('pricing.calcResult')}</h2>
                        <Button variant="secondary"
                            type="button"
                            onClick={copyBreakdown}>
                            {copied ? t('pricing.copied') : t('pricing.copyBreakdown')}
                        </Button>
                    </div>

                    {/* 明细表与汇总抽成了共享组件(化验录入/详情的预览用的是同一份) */}
                    <PriceBreakdown
                        res={res}
                        negativeNote={
                            res.negative_value ? (
                                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-3 text-sm">
                                    {t('pricing.negativeValue')}
                                </div>
                            ) : null
                        }
                    />
                </section>
            )}
        </div>
    )
}
