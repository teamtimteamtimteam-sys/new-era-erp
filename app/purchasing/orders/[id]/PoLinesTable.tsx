'use client'

// app/purchasing/orders/[id]/PoLinesTable.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-8(2026-09-04)· 采购单明细行 —— 【全仓最大的一页上最难的一张表】
// ════════════════════════════════════════════════════════════════════════════
//
// 这张表是本刀故意去撞的最坏情况(PAGE-0 点名 /purchasing/orders/[id] 是全系统
// 最大的一页)。它一张表上同时有四样别的表都没有的东西,逐条记下处置:
//
// ① **一列是条件列** —— 设备单上没有「计价公式」这一轴(EQP-1c-b-fu2:一台机器
//    上面写着「物料」是一个【说错了的】列头,不是一个空列)。处置是在服务端把
//    `isEquipmentOrder` 传进来,用 `.filter(Boolean)` 把那一列摘掉。
//    ☞ **这仍然被手机闸【读得到】**:闸找的是 `const columns` 的声明文本里有没有
//      `priority: true`(check-datatable-phone.mjs:138-144),条件摘列不影响它。
//      本刀实测注入过一次,红了、点名了、还原后绿 —— 不是假设它会被算上。
//
// ② **三行合计,带 colSpan** —— PO-GST-1 之后表尾是【净额/税额/含税总额】三行
//    (不带税的历史单据只印一行,因为「GST 0.00」会是一句断言,而真相是"这张单
//    没有算过税")。DataTable 没有表尾,也没有 colSpan。
//    处置照 CONV-4 §⑨-3:**合计行是塞进 rows 的数据**,用 rowClassName 区分轻重。
//    代价照直写:**合计标签不再紧贴着数字右对齐,而是落在名称列**。这是本刀
//    唯一一处看得见的版式让步,记在 docs/detail-page-template.md 与人工走查清单。
//
// ③ **格子里有一个会写库的控件**(DeepDischargeJudgementControl)——
//    而这张表的其余部分是【只读】的。Tim 在本刀 Q3 裁定:走 DataTable 的
//    `render`,不升级成 EditableTable。理由是 EditableTable 存在的三件事
//    (行级编辑态、脏值追踪、逐行保存)**这个控件自己全都有**,再套一层
//    只会让两个状态机同时管一行。与 CONV-3 把「勾选」做成 prop 而不是分叉,
//    是同一条判据的同一个答案。
//
// ④ **格子里的副标签** —— 计价条款是否已抄副本(FIN-27)、价的出处(FIN-26)
//    各自在格子里挂一行小字并且【带颜色】。`render: (row) => ReactNode` 原样容得下,
//    一个字都不用改契约。颜色由服务端算成 tone,不把判据搬到客户端。
import * as React from 'react'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { useTranslations } from '@/lib/i18n/client'
import DeepDischargeJudgementControl from './DeepDischargeJudgementControl'

/** 副标签的颜色:判据在服务端算完,客户端只认三个字。 */
export type Tone = 'green' | 'amber' | 'gray'

const TONE_CLASS: Record<Tone, string> = {
    green: 'text-green-700',
    amber: 'text-amber-700',
    gray: 'text-gray-400',
}

export type PoLineRow = {
    id: string
    lineNoText: string
    /** 物料名 / 机器名 —— 服务端按单据种类选好的那一个。 */
    name: string
    expectedAssayText: string | null
    /** 设备行没有深度放电这条轴;为 null 时不画那个控件。 */
    materialId: string | null
    ddCurrent: string | null
    qtyText: string
    formulaText: string
    commitmentText: string | null
    commitmentTone: Tone | null
    unitPriceText: string
    priceSourceText: string | null
    priceSourceTone: Tone | null
    amountText: string
    /** 合计行 —— 见抬头 ②。'grand' 比 'sub' 重。 */
    totalKind?: 'sub' | 'grand'
}

export default function PoLinesTable({
    rows,
    poId,
    ddOptions,
    canEditPurchasing,
    isEquipmentOrder,
}: {
    rows: readonly PoLineRow[]
    poId: string
    ddOptions: { code: string; label: string }[]
    canEditPurchasing: boolean
    isEquipmentOrder: boolean
}) {
    const t = useTranslations()

    const columns: Column<PoLineRow>[] = [
        {
            key: 'no',
            header: '#',
            className: 'text-sm text-gray-500',
            render: (r) => r.lineNoText,
        },
        {
            key: 'name',
            // EQP-1c-b-fu2:表头跟着单据的种类走。
            header: isEquipmentOrder ? t('purchasing.colMachine') : t('purchasing.colMaterial'),
            // 身份列 —— 手机上留下,否则展开区那一竖列没有主语。
            priority: true,
            render: (r) =>
                r.totalKind ? (
                    r.name
                ) : (
                    <>
                        {r.name}
                        {r.expectedAssayText && (
                            <span className="mt-0.5 block text-xs text-gray-500">
                                {t('purchasing.form.expectedAssay')}: {r.expectedAssayText}
                            </span>
                        )}
                        {/* ③ 见抬头:只读表里的一个写库控件,走 render。 */}
                        {r.materialId && (
                            <DeepDischargeJudgementControl
                                poId={poId}
                                lineId={r.id}
                                current={r.ddCurrent}
                                options={ddOptions}
                                canEdit={canEditPurchasing}
                            />
                        )}
                    </>
                ),
        },
        {
            key: 'qty',
            header: t('purchasing.colQuantity'),
            align: 'right',
            className: 'font-mono text-sm',
            render: (r) => r.qtyText,
        },
        // ① 条件列:设备单上这一轴不存在 —— 整列拿掉,不是留着画横杠。
        ...(isEquipmentOrder
            ? []
            : [
                  {
                      key: 'formula',
                      header: t('purchasing.colFormula'),
                      render: (r: PoLineRow) => (
                          <>
                              {r.formulaText}
                              {r.commitmentText && (
                                  <span
                                      className={
                                          'mt-0.5 block text-xs ' +
                                          (r.commitmentTone ? TONE_CLASS[r.commitmentTone] : '')
                                      }
                                  >
                                      {r.commitmentText}
                                  </span>
                              )}
                          </>
                      ),
                  } satisfies Column<PoLineRow>,
              ]),
        {
            key: 'unitPrice',
            header: t('purchasing.colUnitPrice'),
            align: 'right',
            className: 'font-mono text-sm',
            render: (r) => (
                <>
                    {r.unitPriceText}
                    {r.priceSourceText && (
                        <span
                            className={
                                'mt-0.5 block font-sans text-xs ' +
                                (r.priceSourceTone ? TONE_CLASS[r.priceSourceTone] : '')
                            }
                        >
                            {r.priceSourceText}
                        </span>
                    )}
                </>
            ),
        },
        {
            key: 'amount',
            header: t('purchasing.colAmount'),
            align: 'right',
            // ★ 第二列 priority:一张采购单存在的理由就是「这一行要付多少」。
            //   PO-GST-1 之后有三个金额列,而【行金额】才是这一行的那个数
            //   —— 与 CONV-5 给 /purchasing/orders 列表页挑「应付总额」同一条理由。
            priority: true,
            className: 'font-mono text-sm',
            render: (r) => r.amountText,
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            className="mb-6"
            rowClassName={(r) =>
                r.totalKind === 'grand'
                    ? 'font-bold bg-[color:var(--brand-muted)]'
                    : r.totalKind === 'sub'
                      ? 'bg-[color:var(--brand-muted)]'
                      : undefined
            }
            empty={t('purchasing.noLines')}
        />
    )
}
