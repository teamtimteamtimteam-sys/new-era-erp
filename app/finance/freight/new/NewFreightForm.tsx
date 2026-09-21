'use client'

// 运费单录入表单(FRT-1)。
//
// 【口径是一次选择,不是一个默认值】weight / value / stated 三选一,表单上必须
// 明写选了哪一个 —— 与 allocation_basis 同一条(FIN-36:看得见的默认值才不是假设)。
// 【重量与货值恰恰在最要紧的时候分歧最大】:一批轻而贵的货与一批重而便宜的货同船,
// 两种口径给出的答案差得最远。这句话印在表单上,不是藏在文档里。
//
// 【本表单不自己算分摊】金额、拆账、过账全由 record_freight_document 决定;
// 这里只把选择送下去。两份算术会在写下的那天一致,此后各自漂移。
import { CONTROL_CHECKBOX, CONTROL_INPUT, CONTROL_SELECT, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'
import { useActionState, useState } from 'react'
import Link from 'next/link'
import { createFreightDocument, type FreightState } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import DecimalInput from '@/app/components/forms/DecimalInput'
import { Button } from '@/app/components/ui/button'
import { EditableTable, type EditableColumn } from '@/app/components/ui/editable-table'
import { formatDate } from '@/lib/dates'
import { useLocale } from '@/lib/i18n/client'

export type BatchOption = {
    id: string
    code: string
    quantity: number
    unit: string
    remaining_qty: number
    unit_price: number | null
    arrival_date: string | null
}

export type ContainerOption = {
    id: string
    code: string
    lane: string | null
    departure_date: string
}

const initialState: FreightState = {}

export default function NewFreightForm({
    suppliers,
    batches,
    currencies,
    baseCurrency,
    containers,
}: {
    suppliers: { id: string; code: string; legal_name: string }[]
    batches: BatchOption[]
    currencies: string[]
    baseCurrency: string
    containers: ContainerOption[]
}) {
    const locale = useLocale()
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(createFreightDocument, initialState)
    // LOG-4b:【方向不是一个标签,它决定这笔钱去哪里】。没有默认成"进货"的诱惑:
    // 两个都摆出来,人选一个 —— 与 allocation_basis 同一条(FIN-36)。
    const [direction, setDirection] = useState<'inbound' | 'outbound'>('inbound')
    const outbound = direction === 'outbound'
    const [basis, setBasis] = useState('weight')
    const [paid, setPaid] = useState(false)
    const [picked, setPicked] = useState<Record<string, boolean>>({})
    const [stated, setStated] = useState<Record<string, string>>({})
    const [amount, setAmount] = useState('')

    const chosen = batches.filter((b) => picked[b.id])
    // value 口径遇未计价批次:服务端会点名拒 —— 页面【先说出来】,
    // 不把一张注定被拒的表单摆到人面前(CMP-2 的规矩)
    const unpriced = !outbound && basis === 'value' ? chosen.filter((b) => b.unit_price === null) : []

    // ★ TABLE-PHONE-4:批次表的列数是有条件的 —— 'stated' 那一支多一列「分得」,共 5 列;
    //   另外两支 4 列,本来就在免修档里。折叠只在 5 列那一支生效,写在这里一处,
    //   列头与单元格共用它 —— 两边各写一个条件,就是让它们将来各走各的。
    const stacked = basis === 'stated'

    /* ★★ 桥的载荷。**只送挑中的批次** —— 与搬家前逐字同构:
       那两个具名输入搬家前就是**条件渲染**的(`{picked[b.id] && …}`),
       所以数组里本来就只有挑中的行。这里保留同一条判据。
       ★ `amount` 那个键**跟着口径走**:服务端 `actions.ts:31-33` 写的是
       `...(basis === 'stated' ? { amount_base: … } : {})` —— **键在不在**,
       而不是值。所以这里也只在 'stated' 那一支送它。 */
    const allocPayload = batches
        .filter((b) => picked[b.id])
        .map((b) => ({
            inbound_batch_id: b.id,
            ...(stacked ? { stated_amount: stated[b.id] ?? '' } : {}),
        }))

    /* ★ Q5 的必填 `dirty` —— 这张表单开局一个批次都没挑,
       所以「挑了没有 / 填了没有」就是「与进门时那一份比」。 */
    const allocDirty = batches.some(
        (b) => !!picked[b.id] || (stated[b.id] ?? '').trim() !== '')

    /* ════════════════════════════════════════════════════════════════════════
       ★★★【勾选框【就是】这张表的可编辑列 —— Tim 的 Q2 裁定(DRAFT-5)】★★★
       这张表在 `basis !== 'stated'` 那两支里**一个要打字的格子都没有**,
       而 `EditableTable` 对「一列都不可编辑」是**按名拒绝**的
       (`EDITABLETABLE_NO_EDITABLE_COLUMN`:那是 `DataTable` 的活)。
       ☞ 裁定:**挑一行【就是】在改这份草稿**,所以勾选框是 `edit`,
         而 `render` 画它的只读投影(✓ / —)。
       ☞ 于是四列那两支也有一列可编辑,组件不再有理由拒绝,
         而这句话是**真的**,不是为了绕过一道闸编出来的。

       ★★ 只读列的 390px 处置(Tim 的 Q2):照这个文件**今天已经在做的**那样 ——
         「剩余」带着列头叠进批次那一格(`stacked` 那一支),
         桌面照旧是列,手机零次点按看得见。**不新增 priority 列。**
       ★ 「数量」留在明面上的理由照抄旧注释:分摊运费分的是【这一票走了多少】,
         数量就是分母;剩余是仓里还剩多少,那是另一件事。
       ════════════════════════════════════════════════════════════════════════ */
    const batchColumns: EditableColumn<BatchOption, BatchOption>[] = [
        {
            key: 'pick',
            header: '',
            priority: true,
            render: (b) => (picked[b.id]
                ? <span aria-label={t('common.yes')}>✓</span>
                : <span className="text-gray-400" aria-label={t('common.no')}>—</span>),
            edit: (b) => (
                <input className={CONTROL_CHECKBOX} type="checkbox" checked={!!picked[b.id]}
                       aria-label={b.code}
                       onChange={(e) => setPicked((p) => ({ ...p, [b.id]: e.target.checked }))} />
            ),
        },
        {
            key: 'batch',
            header: t('finance.freight.colBatch'),
            priority: true,
            render: (b) => (
                <>
                    {b.code}
                    {/* ★ TABLE-PHONE-4:5 列那一支手机档拿掉的「剩余」,带着列头叠在这里。 */}
                    {stacked && (
                        <div className="sm:hidden mt-1 space-y-0.5 font-sans text-xs text-gray-600">
                            <div>
                                <span className="font-sans text-gray-500">{t('finance.freight.colRemaining')}: </span>
                                {b.remaining_qty}
                            </div>
                        </div>
                    )}
                </>
            ),
        },
        {
            key: 'qty',
            header: t('finance.freight.colQty'),
            align: 'right',
            priority: true,
            render: (b) => <>{b.quantity} {b.unit}</>,
        },
        {
            key: 'remaining',
            header: t('finance.freight.colRemaining'),
            align: 'right',
            // 4 列那两支它本来就不折叠;5 列那一支叠进批次格里(见上面)。
            priority: !stacked,
            render: (b) => b.remaining_qty,
        },
        ...(stacked
            ? [
                  {
                      key: 'share',
                      header: t('finance.freight.colShare'),
                      align: 'right' as const,
                      render: (b: BatchOption) =>
                          ((stated[b.id] ?? '').trim() === '' ? '—' : stated[b.id]),
                      edit: (b: BatchOption) => (
                          picked[b.id] ? (
                              <DecimalInput
                                  value={stated[b.id] ?? ''}
                                  onChange={(raw) => setStated((s) => ({ ...s, [b.id]: raw }))}
                                  className="w-32" />
                          ) : (
                              /* ★ 没挑中就没有「分得」可填 —— 这一格的空是
                                 「这一行不在这次分摊里」,不是「还没填」。
                                 搬家前它也是条件渲染的,这里逐字同构。 */
                              <span className="text-[color:var(--brand-muted-text)] text-xs">
                                  {t('finance.freight.shareNeedsPick')}
                              </span>
                          )
                      ),
                  },
              ]
            : []),
    ]

    return (
        <div className="max-w-4xl">
            <div className="mb-6">
                <Link href="/finance/freight" className="hover:underline text-sm app-link">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="mb-2">{t('finance.freight.newTitle')}</h1>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-4 max-w-3xl">
                {outbound ? t('finance.freight.exportHint') : t('finance.freight.newIntro')}
            </p>

            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            <form action={formAction} className="space-y-4">
                {/* 【方向先问】它决定后面这张表单是哪一张 —— 分摊那一段在出境时
                    根本不存在,而不是"存在但空着"。 */}
                <div>
                    <label className="block mb-1">
                        {t('finance.freight.colDirection')} <span className="text-red-600">*</span>
                    </label>
                    <select name="direction" value={direction}
                        onChange={(e) => setDirection(e.target.value as 'inbound' | 'outbound')}
                        className={`${CONTROL_SELECT} min-w-96`}>
                        <option value="inbound">{t('finance.freight.direction.inbound')}</option>
                        <option value="outbound">{t('finance.freight.direction.outbound')}</option>
                    </select>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-1 max-w-3xl">{t('finance.freight.directionHint')}</p>
                </div>

                <div className="flex flex-wrap gap-4">
                    <div>
                        <label className="block mb-1">
                            {t('finance.freight.colDate')} <span className="text-red-600">*</span>
                        </label>
                        <input type="date" name="doc_date" required
                            className={CONTROL_INPUT} />
                    </div>
                    <div>
                        <label className="block mb-1">
                            {t('finance.freight.colForwarder')} <span className="text-red-600">*</span>
                        </label>
                        {/* LOG-1b:【空名单要说出它是哪一种空】。这里过滤的是货代,
                            所以空的时候要说"还没有货代",而不是画一个空的下拉框 ——
                            一个空下拉读起来像"选项加载失败",而真相是"还没有人被标成货代"。
                            今天线上货代数为 0,所以这一支【就是当前会看到的那一支】。 */}
                        {suppliers.length === 0 ? (
                            <p className="text-sm text-amber-900 bg-amber-50 border border-amber-300 rounded px-3 py-2 max-w-xl">
                                {t('suppliers.pickerEmptyForwarders')}
                            </p>
                        ) : (
                            <select name="supplier_id" required defaultValue=""
                                className={`${CONTROL_SELECT} min-w-64`}>
                                <option value="" disabled>{t('finance.freight.selectForwarder')}</option>
                                {suppliers.map((s) => (
                                    <option key={s.id} value={s.id}>{s.legal_name}</option>
                                ))}
                            </select>
                        )}
                        {/* 【货代,不是材料供应商】—— 未付运费的应付记在这个人名下 */}
                        <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('finance.freight.forwarderHint')}</p>
                    </div>
                    <div>
                        <label className="block mb-1">
                            {t('finance.freight.colAmount')} <span className="text-red-600">*</span>
                        </label>
                        <div className="flex gap-2">
                            <DecimalInput name="amount" value={amount} onChange={setAmount}
                                className="w-40" />
                            <select name="currency" defaultValue={baseCurrency}
                                className={CONTROL_SELECT}>
                                {currencies.map((c) => (
                                    <option key={c} value={c}>{c}</option>
                                ))}
                            </select>
                        </div>
                    </div>
                </div>

                {/* 口径:一次明写的选择。【出境没有这一项】—— 出口运费不分摊,
                    摆一个禁用的下拉等于说"这里本该有个答案";它本来就不该有。 */}
                {!outbound && <div>
                    <label className="block mb-1">
                        {t('finance.freight.colBasis')} <span className="text-red-600">*</span>
                    </label>
                    <select name="allocation_basis" value={basis} onChange={(e) => setBasis(e.target.value)}
                        className={CONTROL_SELECT}>
                        <option value="weight">{t('finance.freight.basis.weight')}</option>
                        <option value="value">{t('finance.freight.basis.value')}</option>
                        <option value="stated">{t('finance.freight.basis.stated')}</option>
                    </select>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-1 max-w-3xl">{t('finance.freight.basisHint')}</p>
                </div>}

                {/* 付款方式 */}
                <div className="flex flex-wrap gap-4 items-end">
                    <div>
                        <label className="block mb-1">{t('finance.freight.colPayment')}</label>
                        <select name="payment_status" value={paid ? 'paid' : 'unpaid'}
                            onChange={(e) => setPaid(e.target.value === 'paid')}
                            className={CONTROL_SELECT}>
                            <option value="unpaid">{t('finance.freight.payment.unpaid')}</option>
                            <option value="paid">{t('finance.freight.payment.paid')}</option>
                        </select>
                    </div>
                    {paid && (
                        <div>
                            <label className="block mb-1">{t('finance.freight.colBank')}</label>
                            <select name="bank_account_code" defaultValue="1000"
                                className={CONTROL_SELECT}>
                                <option value="1000">1000</option>
                                <option value="1010">1010</option>
                            </select>
                        </div>
                    )}
                </div>

                {/* 【出境:集装箱选择器,而且【没有】任何分摊 UI】。
                    不是"分摊那一段禁用了",是它根本不在这张表单上 —— 出口运费
                    不摊到任何批次,摆一个空的批次表等于暗示这里少填了东西。 */}
                {outbound && (
                    <div>
                        <label className="block mb-1">{t('finance.freight.colContainer')}</label>
                        {containers.length === 0 ? (
                            <p className="text-sm text-amber-900 bg-amber-50 border border-amber-300 rounded px-3 py-2 max-w-xl">
                                {t('finance.freight.noContainers')}
                            </p>
                        ) : (
                            <select name="container_id" defaultValue=""
                                className={`${CONTROL_SELECT} min-w-96`}>
                                {/* 【不指定是一个正当选项】—— 单据才是钱的对象 */}
                                <option value="">{t('finance.freight.selectContainer')}</option>
                                {containers.map((c) => (
                                    <option key={c.id} value={c.id}>
                                        {c.code}{c.lane ? ` · ${c.lane}` : ''} · {formatDate(c.departure_date, locale)}
                                    </option>
                                ))}
                            </select>
                        )}
                        <p className="text-xs text-[color:var(--brand-muted-text)] mt-1 max-w-3xl">{t('finance.freight.containerHint')}</p>
                    </div>
                )}

                {/* 批次(仅进境)*/}
                {!outbound && <div>
                    <p className="block text-sm font-medium mb-1">{t('finance.freight.pickBatches')}</p>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('finance.freight.pickBatchesHint')}</p>
                    {unpriced.length > 0 && (
                        <div className="bg-amber-50 border border-amber-300 text-amber-900 px-3 py-2 rounded mb-2 text-sm">
                            {t('finance.freight.unpricedWarning', { codes: unpriced.map((b) => b.code).join(', ') })}
                        </div>
                    )}
                    <div className="border border-gray-300 rounded max-h-96 overflow-y-auto">
                        {/* ★★ (b) 那座桥 —— 画在表外面,只画一遍。
                            ★ 搬家前那两个具名输入(`batch_id` / `stated_amount`)
                              **都是条件渲染**的 —— 只有挑中的行才进数组,
                              两条数组因此对齐。桥把「对齐」这件事整个取消了:
                              每一行自己带着自己的值。 */}
                        <input type="hidden" name="alloc_json" value={JSON.stringify(allocPayload)} />
                        <EditableTable<BatchOption, BatchOption>
                            rows={batches}
                            columns={batchColumns}
                            rowKey={(b) => b.id}
                            phone={{ mode: 'columns' }}
                            mode="page-owned"
                            dirty={allocDirty}
                            labels={{ expand: t('common.expandRow') }}
                        />
                    </div>
                </div>}

                <div>
                    <label className="block mb-1">{t('finance.freight.colNotes')}</label>
                    <textarea name="notes" className={`${CONTROL_TEXTAREA} w-full`} />
                </div>

                <div className="flex gap-3 pt-2">
                    {/* 【提交条件按方向分】进境必须挑至少一个批次(服务端 FREIGHT_NO_BATCHES);
                        出境没有批次可挑,把那条禁用条件留着会让按钮永远按不下去。 */}
                    <Button type="submit" disabled={isPending || (!outbound && chosen.length === 0)}>
                        {isPending ? t('common.saving') : t('common.save')}
                    </Button>
                    <Button asChild variant="secondary">
                        <Link href="/finance/freight">
                            {t('common.cancel')}
                        </Link>
                    </Button>
                </div>
            </form>
        </div>
    )
}
