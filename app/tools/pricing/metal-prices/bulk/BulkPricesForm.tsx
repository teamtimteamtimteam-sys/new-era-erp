'use client'

// 每日行情批量录入表单:一个日期 + 七个金属各一行。
// 每行右侧给出"该日期之前(含当日)最近一次的价格"作为参照 —— 录入时能看清是从多少改到多少。
// 已有当日价格的金属会被预填(于是本页同时也是"改今天的价"的编辑页)。
// 改日期会重新拉取参照价与预填值(走 router.replace 把日期写进 URL,由服务端重取)。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useActionState, useEffect, useState } from 'react'
import { useRouter, usePathname } from 'next/navigation'
import { saveBulkPrices, type BulkPricesState } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import DecimalInput from '@/app/components/forms/DecimalInput'
import type { MetalOption } from '../options'
import AnomalyWarning from '../AnomalyWarning'
import SourcePicker from '../SourcePicker'
import { INDEX_UNSTATED, type MetalPriceIndex } from '../indexOptions'
import { ACK_FIELD, ackSignature } from '../anomaly'
import { EditableTable, type EditableColumn } from '@/app/components/ui/editable-table'

/** 桥上交出去的一行 —— 与搬家前 `metal[]` / `price[]` 逐字同构。 */
type PriceLine = { metal: string; price: string }
/** 渲染用的行。参照价不进桥 —— 它是读的,不是交的。 */
type PriceRow = PriceLine & { lastPrice: number | null; lastDate: string | null }

const initialState: BulkPricesState = {}

export type MetalRowData = {
    metal: string
    // 该日期已录入的价格(预填用),没有则空串
    current: string
    // 参照:该日期之前(含)最近一次的价格与其日期
    lastPrice: number | null
    lastDate: string | null
}

export default function BulkPricesForm({
    substanceOptions,
    priceDate,
    priceIndex,
    indices,
    locale,
    rows,
}: {
    // PROC-4:物质清单由页面从字典读好传进来(清单与顺序都由它定)。
    substanceOptions: MetalOption[]
    priceDate: string
    priceIndex: string | null
    indices: MetalPriceIndex[]
    locale: string
    rows: MetalRowData[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const pathname = usePathname()
    const [state, formAction, isPending] = useActionState(saveBulkPrices, initialState)

    const [values, setValues] = useState<Record<string, string>>(() =>
        Object.fromEntries(rows.map((r) => [r.metal, r.current]))
    )

    // 服务端换了日期(或保存后 revalidate 重取)→ 用新的预填值刷新输入
    useEffect(() => {
        setValues(Object.fromEntries(rows.map((r) => [r.metal, r.current])))
    }, [rows])

    const metalLabel = (value: string) => t('metals.' + value)

    // ★★★ 桥的行从【页面画出来的那一份名单】来,不从整个 Record 来 ——
    //   理由与 `#18` / `#26` 逐字相同。★ 这一张还多一条:异常判据的那份签名
    //   (`ackSignature`)是按**送上去的那一组数**算的,金属集合一变,
    //   「确认的是这一组数字」那句话就不再成立。
    const metalRows: PriceRow[] = substanceOptions
        .filter((s) => s.isActive)
        .map((opt) => {
            const row = rows.find((r) => r.metal === opt.value)
            return {
                metal: opt.value,
                price: values[opt.value] ?? '',
                lastPrice: row?.lastPrice ?? null,
                lastDate: row?.lastDate ?? null,
            }
        })

    /* ★ Q5 的必填 `dirty` —— 判据是【与 `rows` 那份预填值比】,不是「有没有字」。
       这一页当天已经录过价的金属**进门就是填好的**(本页同时也是「改今天的价」
       的编辑页),按「有没有字」算会一进门就脏。
       ⚠ ★★ **照直记:`beforeunload` 在这一页盖不住最可能丢字的那条路。**
         改日期或改指数走的是 `router.replace`(`:88` / `:103`)—— 一次**站内**导航,
         组件的 `beforeunload` 看不见它;紧接着上面那个 effect 会拿新的 `rows`
         **把 `values` 整个重置**。☞ 打了一半的价格**今天就会被丢掉,搬完之后照旧**。
         这不是本刀弄出来的,也不是本刀修掉的 —— 是照直记下来的一条。 */
    const priceBaseline = Object.fromEntries(rows.map((r) => [r.metal, r.current]))
    const pricesDirty = metalRows.some((r) => r.price !== (priceBaseline[r.metal] ?? ''))

    /* ★★ 三列的 390px 处置(Tim 的 Q1 / Q2,DRAFT-4):
       · 金属名 `priority` —— 这一行的主语;
       · ★ **参照价 `priority`** —— `page-owned` 下展开区只画【有 `edit` 的列】
         (`editable-table.tsx:632`),一个只读且非 priority 的列在 390px 上
         **整个消失**。而本文件抬头写着这一页存在的理由就是
         「录入时能看清是从多少改到多少」。**那个数消失,这一页就只剩一排空格子。**
       ★ 它的列头**今天就是空的**(搬家前是一个 `<th />`),所以这里写 `header: ''`
         —— 与搬家前逐字相同,**一句文案都不用现造**。 */
    const priceColumns: EditableColumn<PriceRow, PriceRow>[] = [
        {
            key: 'metal',
            header: t('pricing.form.colMetal'),
            priority: true,
            render: (r) => (
                <>
                    {metalLabel(r.metal)}
                    <span className="text-gray-400 text-xs ml-2">{r.metal}</span>
                </>
            ),
        },
        {
            key: 'price',
            header: t('metalPrices.colPrice'),
            render: (r) => (r.price.trim() === '' ? '—' : r.price),
            edit: (r) => (
                <DecimalInput
                    value={r.price}
                    onChange={(raw) => setValues((v) => ({ ...v, [r.metal]: raw }))}
                    className="w-40"
                />
            ),
        },
        {
            key: 'reference',
            header: '',
            priority: true,
            className: 'text-gray-500',
            render: (r) =>
                r.lastPrice != null && r.lastDate
                    ? t('metalPrices.bulk.lastPrice', { price: r.lastPrice, date: r.lastDate })
                    : t('metalPrices.bulk.noPrior'),
        },
    ]

    return (
        <form action={formAction} className="space-y-4 max-w-3xl">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}
            {state.result && (
                <div className="bg-green-50 border border-green-300 text-green-800 px-4 py-3 rounded text-sm">
                    {t('metalPrices.bulk.result', state.result)}
                </div>
            )}

            <div className="flex flex-wrap gap-4">
                <div>
                    <label className="block mb-1">
                        {t('metalPrices.bulk.date')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="date"
                        name="price_date"
                        required
                        value={priceDate}
                        onChange={(e) => {
                            const d = e.target.value
                            if (d) router.replace(`${pathname}?date=${d}&index=${priceIndex ?? INDEX_UNSTATED}`)
                        }}
                        className={CONTROL_INPUT}
                    />
                </div>
                {/* METAL-2:整张表属于一个指数。改它要【重取参照价】—— 拿 LME 的
                    上一条去比 SMM 的今天,屏幕上那句"上次 X"就是错的,
                    所以它和日期一样写进 URL,由服务端重取。 */}
                {/* LME-1b:出处三件套(出处 / 指数 / 凭据 / 当天还是延迟)。
                    指数下拉搬进 SourcePicker —— 它只在"发布的指数"时才启用,
                    镜像 1a 那条配对 CHECK。换指数仍然重取参照价。 */}
                <SourcePicker
                    indices={indices}
                    locale={locale}
                    defaultIndex={priceIndex}
                    onIndexChange={(v) => router.replace(`${pathname}?date=${priceDate}&index=${v}`)}
                />
            </div>

            {/* ★★ (b) 那座桥 —— 画在表外面,只画一遍。理由见 `#18` 同一处。
                ★ 价格空串**原样送出**:DB 侧把 null/空当作「这个金属今天没填」,
                  计入 skipped —— 与搬家前逐字相同,这里一个字都没有替它决定。 */}
            <input
                type="hidden"
                name="metal_prices_json"
                value={JSON.stringify(metalRows.map((r) => ({ metal: r.metal, price: r.price })))}
            />
            <EditableTable<PriceRow, PriceRow>
                rows={metalRows}
                columns={priceColumns}
                // 金属码即键:行来自物质字典,定长,不加行不删行 —— 不需要 uid。
                rowKey={(r) => r.metal}
                phone={{ mode: 'columns' }}
                mode="page-owned"
                dirty={pricesDirty}
                labels={{ expand: t('common.expandRow') }}
            />

            {/* METAL-1:异常提示 —— 出现时这一次【一行都没写】,确认钮才保存整组。
                表单里的值原样留着,人可以先改掉某一个再提交(改了之后签名不同,
                会【再提示一次】—— 确认的是那一组数字,不是"下一次提交")。 */}
            {state.warnings && state.warnings.length > 0 && (
                <>
                    <AnomalyWarning items={state.warnings} />
                    <input type="hidden" name={ACK_FIELD} value={ackSignature(state.warnings)} />
                </>
            )}

            <button
                type="submit"
                disabled={isPending}
                className={
                    'px-4 py-2 rounded text-white disabled:bg-gray-400 ' +
                    (state.warnings?.length
                        ? 'bg-amber-600 hover:bg-amber-700'
                        : 'bg-blue-600 hover:bg-blue-700')
                }
            >
                {isPending
                    ? t('common.saving')
                    : state.warnings?.length
                      ? t('metalPrices.anomaly.confirm')
                      : t('metalPrices.bulk.submit')}
            </button>
        </form>
    )
}
