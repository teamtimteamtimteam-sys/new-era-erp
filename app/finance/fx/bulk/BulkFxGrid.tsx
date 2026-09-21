'use client'

// FX-RATES-1:一周的牌价,一张表填完。
// 【这张表只做一件事:填空】已经在册的格子【预填好、只读】,旁边写着去哪里改 ——
// 一个没有相邻解释的只读控件是个死控件。
// 【为什么不让它覆盖】一次"粘贴"如果能悄悄改掉上周的牌价,那就是【看起来像录入的
// 审计线索销毁】。改一条已在册的牌价要说为什么,那条路在单条编辑页上。
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { recordFxRatesBulk, type BulkCell } from './actions'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { EditableTable, type EditableColumn } from '@/app/components/ui/editable-table'

const TYPES = ['tt_buy', 'tt_sell', 'mid'] as const

export type Existing = { currency: string; rate_date: string; rate_type: string; rate_sgd_per_unit: number; id: string }

/**
 * ★ DRAFT-6:一行 = 一天。**它必须是一个对象,不是那个日期串** ——
 * `EditableTable<T, D extends object>` 的 `page-owned` 那一支里 `D` 就是 `T`,
 * 而一个字符串不是 object。
 */
type RateRow = { date: string }

export default function BulkFxGrid({
    currencies,
    dates,
    existing,
canEdit
}: {
    currencies: string[]
    dates: string[]
    existing: Existing[]

canEdit: boolean
}) {
    const t = useTranslations()
    const [currency, setCurrency] = useState(currencies[0] ?? '')
    const [values, setValues] = useState<Record<string, string>>({})
    const [error, setError] = useState<string | null>(null)
    const [done, setDone] = useState<number | null>(null)
    const [isPending, startTransition] = useTransition()

    /* ════════════════════════════════════════════════════════════════════════
       ★★★【DRAFT-6 / Tim 的 Q19 裁定(2026-09-21):**这两个键此前都不含币种**,
          而那是一处在册之外的缺陷 —— 本刀顺手修掉,连理由一起写下来】★★★

       搬家前 `byKey` 与 `values` 都按 `` `${日期}|${价种}` `` 作键,而这一页的币种
       是【客户端下拉】选出来的。于是两件事同时成立,而两件都不报错:

       ① **一格 USD 已在册的牌价,会让同一天同一价种的 CNY 那一格也显示成
          「已在册」** —— 而且显示的是 **USD 的数字**、链接指向 **USD 那条记录**;
          更坏的是 `submit()` 那一句 `if (byKey.has(...)) continue`
          **会把它跳过去**,于是 **CNY 那一格【永远填不进去】**,
          而屏幕上说的是「它已经录过了」。
       ② 反过来,在 USD 上打了一半的数字,切到 CNY 之后**原样还在那里** ——
          一个为 USD 敲的价,眼看着挂在 CNY 名下。

       ☞ **两处的成因是同一个:键少了一维。** 修法就是把那一维加回去。
       ⚠ **今天在线上看不见它**:窗口内 0 行、且全树 12 行牌价【全是 USD】
          (只读清点,2026-09-21,以 `postgres` 身份读,`rolbypassrls = true`,
          `fx_rates` 是基表 relkind `'r'`)。**所以它的证据是一份代码收据,
          不是一次目击** —— 照直记。
       ★ 顺带:页面那一侧的窗口查询也跟着收窄到这张表画得出来的那几种币
          (`page.tsx` 的 `.in('currency', currencies)`)。
       ════════════════════════════════════════════════════════════════════════ */
    const key = (ccy: string, d: string, ty: string) => `${ccy}|${d}|${ty}`
    const byKey = new Map(existing.map((e) => [key(e.currency, e.rate_date, e.rate_type), e]))

    const rateRows: RateRow[] = dates.map((d) => ({ date: d }))

    /* ★ `page-owned` 的必填 `dirty`:这张表进门时格子全是空的,
       所以「有没有内容」与「与进门时那一份比」在这里是同一件事,取简单的。
       ★ 只问【当前这个币种】那几格 —— 键含币种之后这件事才说得准(见上面 Q19)。
       ⚠ 站内 `<Link>` 不拦,是组件抬头声明过的限制。 */
    const gridDirty = dates.some((d) =>
        TYPES.some((ty) => (values[key(currency, d, ty)] ?? '').trim() !== '')
    )

    /* ════════════════════════════════════════════════════════════════════════
       ★★★【`#1` 的列 —— 三件事叠在一起,而它们互相咬着】★★★

       ① **不能用 `phone={{ mode: 'scroll' }}`。** 那一模式下展开钮根本不画,
          于是展开区永远不挂载,而手机行的格子恒为只读 ——
          一张**看得见、改不动、而且不说为什么**的表
          (`known-issues.md` 的 `EDITABLETABLE-SCROLL-PHONE-UNEDITABLE`;
          那条缺陷此前**零个消费者**,这一张差一点就成了第一个)。
          ☞ 所以是 `columns` 模式,日期是唯一的 priority 列。

       ② ★★ **那道锁是【逐格】的,不是逐列的** —— 同一列里,已在册的那几天
          是只读读数 + 一条「去哪里改」的链接,没在册的那几天是输入框。
          `EditableTable` 的 `edit` 是**列**级回调,而它收得到那一行 ——
          于是判断写在 `edit()` **里面**,一行一行地问。

       ③ ★★★ **读数与链接分开安置**(Tim 的 Q16):
            · **读数是【信息】** → 叠进日期那一格,**零次点按**
              (TABLE-PHONE-4;而这正是 Tim 那条「任何一列这一页存在的理由,
              要么 priority、要么叠进一个 priority 列的 render」);
            · **链接是【动作】** → 只待在展开区里(Q7 —— 手机行的格子恒为只读,
              一条留在明面上的链接倒是点得动,而把它与读数一起叠上去会让
              **同一个数在一屏上印两遍**)。
       ☞ 于是:日期格告诉你「这一天这个价种已经有数了,是多少」;
         点开那一行,才是「而它在哪里改」。

       ★ **`canEdit` 【不传给组件】** —— 这一页今天的 `canEdit` 只管那颗保存钮
         (下面那个 `PermissionGate`),格子对谁都是可填的。传进去会让没有编辑权的人
         看到的从「一排能打字的框」变成「一排只读的字」,那是一次没有人要求的改动。
       ════════════════════════════════════════════════════════════════════════ */
    const rateColumns: EditableColumn<RateRow, RateRow>[] = [
        {
            key: 'date',
            header: t('finance.fxPage.colRateDate'),
            priority: true,
            className: 'whitespace-nowrap',
            render: (r) => {
                const onFile = TYPES.map((ty) => ({ ty, ex: byKey.get(key(currency, r.date, ty)) }))
                    .filter((x) => x.ex)
                return (
                    <>
                        {r.date}
                        {/* ★★ TABLE-PHONE-4 的叠加块:已在册那几格的【读数】叠在这里,
                            零次点按。⚠ 链接【不在】这里 —— 见上面 ③。
                            ★ 一格都没在册时整块不画:一行「已在册:(空)」是噪音。 */}
                        {onFile.length > 0 && (
                            <div className="sm:hidden mt-1 space-y-0.5 font-sans text-xs text-gray-600">
                                {onFile.map(({ ty, ex }) => (
                                    <div key={ty}>
                                        <span className="text-gray-500">
                                            {t('finance.fxPage.rateType.' + ty)}:{' '}
                                        </span>
                                        {ex!.rate_sgd_per_unit}
                                    </div>
                                ))}
                            </div>
                        )}
                    </>
                )
            },
        },
        ...TYPES.map((ty): EditableColumn<RateRow, RateRow> => ({
            key: ty,
            header: t('finance.fxPage.rateType.' + ty),
            render: (r) => {
                const ex = byKey.get(key(currency, r.date, ty))
                return ex ? <span className="text-gray-600">{ex.rate_sgd_per_unit}</span>
                          : (values[key(currency, r.date, ty)] ?? '')
            },
            // ★ 逐【格】判在不在册 —— 见上面 ②。
            edit: (r) => {
                const ex = byKey.get(key(currency, r.date, ty))
                return ex ? (
                    <span className="flex items-center gap-2">
                        <span className="text-gray-600">{ex.rate_sgd_per_unit}</span>
                        <Link
                            href={`/finance/fx/${ex.id}/edit`}
                            className="text-xs hover:underline app-link"
                        >
                            {t('finance.fxPage.bulk.alreadyOnFile')}
                        </Link>
                    </span>
                ) : (
                    <input
                        type="text" inputMode="decimal"
                        aria-label={`${currency} ${r.date} ${ty}`}
                        value={values[key(currency, r.date, ty)] ?? ''}
                        onChange={(e) =>
                            setValues((v) => ({ ...v, [key(currency, r.date, ty)]: e.target.value }))
                        }
                        className={`${CONTROL_INPUT} w-28`}
                    />
                )
            },
        })),
    ]

    function submit() {
        setError(null); setDone(null)
        const cells: BulkCell[] = []
        for (const d of dates) {
            for (const ty of TYPES) {
                if (byKey.has(key(currency, d, ty))) continue // 已在册:表格不碰
                const v = values[key(currency, d, ty)]
                if (v && v.trim() !== '') {
                    cells.push({ currency, rate_date: d, rate_type: ty, rate: v })
                }
            }
        }
        startTransition(async () => {
            const r = await recordFxRatesBulk(cells)
            if (r.error) setError(r.error)
            else { setDone(r.recorded ?? 0); setValues({}) }
        })
    }

    return (
        <div>
            <p className="text-sm text-[color:var(--brand-text)] mb-1">{t('finance.fxPage.bulk.whatThisIsFor')}</p>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-4">{t('finance.fxPage.bulk.howToCorrect')}</p>

            <div className="mb-4 flex flex-wrap items-center gap-2">
                <label htmlFor="ccy" className="">{t('finance.fxPage.colCurrency')}</label>
                <select
                    id="ccy" value={currency} onChange={(e) => setCurrency(e.target.value)}
                    className={CONTROL_SELECT}
                >
                    {currencies.map((c) => <option key={c} value={c}>{c}</option>)}
                </select>
            </div>

            {error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4 text-sm">
                    {error}
                    <p className="mt-1 opacity-80">{t('finance.fxPage.bulk.allOrNothing')}</p>
                </div>
            )}
            {done !== null && (
                <div className="bg-green-50 border border-green-300 text-green-900 px-4 py-3 rounded mb-4 text-sm">
                    {t('finance.fxPage.bulk.saved', { n: done })}
                </div>
            )}

            {/* ★★ DRAFT-6:搬上 `<EditableTable>`(`page-owned`)。
                ☞ 这一页**没有 `<form>`** —— `recordFxRatesBulk(cells)` 收的是带类型的
                  实参,所以**一座桥都不需要**,格子里也不会有 `name=`
                  (与 `#6`/`#7`、`#11` 同一条)。**纯粹的外观 + 手机档的活,零服务端改动。**
                ⚠ 组件自己带 `overflow-x-auto`,所以外面那一层拿掉了。 */}
            <EditableTable<RateRow, RateRow>
                rows={rateRows}
                columns={rateColumns}
                rowKey={(r) => r.date}
                phone={{ mode: 'columns' }}
                mode="page-owned"
                dirty={gridDirty}
                labels={{ expand: t('common.expandRow') }}
            />

            <div className="mt-4 flex items-center gap-4">
                <PermissionGate code="module.finance.edit" allowed={canEdit}>
                <Button
                    type="button" onClick={submit} disabled={isPending}
                >
                    {isPending ? t('common.saving') : t('finance.fxPage.bulk.save')}
                </Button>
                </PermissionGate>
                <span className="text-xs text-[color:var(--brand-muted-text)]">{t('finance.fxPage.bulk.blanksSkipped')}</span>
            </div>
        </div>
    )
}
