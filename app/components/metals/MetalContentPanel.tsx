'use client'

// 金属含量(化验)面板。进料/产出共用同一份;页面用 .bind 把 batchId 绑进 save/delete 动作,
// 所以面板本身从不接触 id。结构镜像 suppliers 的 AttachmentsPanel(mt-8 pt-8 border-t + 表格 + 录入行)。
import { CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import DecimalInput from '../forms/DecimalInput'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import {
    type MetalContentRow,
    type MetalOption,
} from './metalContentTypes'
import { Button } from '@/app/components/ui/button'

export default function MetalContentPanel({
    rows,
    options,
    saveAction,
    deleteAction,
    priceHref,
    note,
}: {
    rows: MetalContentRow[]
    // PROC-4:物质清单由页面从 substances 那张字典读好传进来(值 + 已翻好的名字)。
    // 面板【不再】自己拿着一份清单 —— 那份清单曾经是第五个副本。
    options: MetalOption[]
    saveAction: (metal: string, contentPct: number) => Promise<{ error?: string }>
    deleteAction: (metal: string) => Promise<{ error?: string }>
    // 带着本批次数量与化验结果跳计价器(新标签页);页面在有化验行时才传。
    priceHref?: string
    // 灰字说明(进料侧 cut 5b 用来交代:含量现在由"应用化验结果"维护,
    // 手工编辑仍然保留给没有实验室结果的批次)。
    note?: string
}) {
    const t = useTranslations()
    const [error, setError] = useState<string | null>(null)
    const [isPending, startTransition] = useTransition()
    // 录入行为受控(为了实时合计);成功后清空即可,无需 formKey。
    const [selectedMetal, setSelectedMetal] = useState('')
    const [pctInput, setPctInput] = useState('')

    // 【翻名字时【不】过滤 isActive】一条记着停用物质的历史行,必须照样显示它的名字。
    // 过滤了就会变成一个光秃秃的 code —— 那看起来像数据坏了,而不是像"不再可选"。
    const keyOf = new Map(options.map((o) => [o.value, o.labelKey]))
    const metalLabel = (value: string) => {
        const k = keyOf.get(value)
        return k ? t(k) : value
    }

    // 已录入的金属集合:录入下拉里给它们加 "(已录)" 后缀提示;仍可选中 —— 选中并保存即覆盖(update)。
    const existing = new Set(rows.map((r) => r.metal))

    // PROC-1b:出处列 —— 化验/手工/未知三种状态要看得见。页面传了才画
    // (标签已在服务端按语言格式化;手工覆盖一行化验值时,出处会当场翻成"手工")。
    const showSource = rows.some((r) => r.source_label)

    // 实时合计:已显示各行之和;若录入的金属已存在(覆盖),用录入值替换该行的旧值,得到"保存后"的合计。
    const displayedTotal = rows.reduce((sum, r) => sum + r.content_pct, 0)
    const pendingNum = Number(pctInput)
    const pendingValid = pctInput !== '' && !Number.isNaN(pendingNum) && pendingNum >= 0
    const replacedPct = selectedMetal
        ? rows.find((r) => r.metal === selectedMetal)?.content_pct ?? 0
        : 0
    const projectedTotal = pendingValid
        ? displayedTotal - replacedPct + pendingNum
        : displayedTotal
    const overHundred = projectedTotal > 100

    function handleSave() {
        if (!selectedMetal) {
            setError(t('metalContent.errInvalid'))
            return
        }
        const n = Number(pctInput)
        if (pctInput === '' || Number.isNaN(n) || n < 0 || n > 100) {
            setError(t('metalContent.errInvalid'))
            return
        }
        setError(null)
        startTransition(async () => {
            const result = await saveAction(selectedMetal, n)
            if (result?.error) {
                setError(result.error)
                return
            }
            // 成功:清空录入行(下拉回到占位、数字清空)
            setSelectedMetal('')
            setPctInput('')
        })
    }

    function handleDelete(metal: string) {
        setError(null)
        startTransition(async () => {
            const result = await deleteAction(metal)
            if (result?.error) setError(result.error)
        })
    }

    // ════════════════════════════════════════════════════════════════════
    // TABLE-CONVERT-6 · 金属含量表 —— ★ 这张表此前【没有】手机档判断 ★
    // ════════════════════════════════════════════════════════════════════
    // 转换前一处 hidden sm:table-cell 都没有;实测 390px 上要横拖 107px。
    //
    // ★【留哪三列 —— 金属 · 含量% · 动作】
    //   · 金属:身份。
    //   · 含量%:结论 —— 这张面板存在的理由就是这个百分比。
    //   · 动作:**R1 强制**。「一列如果画的是【要按的控件】(删除/撤回/移除/下载),
    //     它必须 priority: true」——够不着的动作等于不存在。这里那颗钮是【硬删除】
    //     (走 .delete(),没有墓碑),更不能藏到一次点击之后。
    // ★【出处 · 更新时间 为什么折】两样都是认出这一行之后才问的。
    //   ⚠ 出处那一列分得出「化验 / 手工 / 未知」三种(PROC-1:未知 ≠ 手工),
    //     它带着自己的列头进了展开区,一点就到 —— 三种仍然分得开。
    const columns: Column<MetalContentRow>[] = [
        {
            key: 'metal',
            header: t('metalContent.colMetal'),
            priority: true,
            render: (r) => metalLabel(r.metal),
        },
        {
            key: 'pct',
            header: t('metalContent.colPct'),
            priority: true,
            align: 'right',
            // ⚠ 转换前是 `text-right font-mono text-sm`;text-sm 没有搬过来
            //   (列描述符不许钉字号 —— 棘轮会红),字号由组件表根给。
            className: 'font-mono',
            render: (r) => `${r.content_pct.toFixed(2)}%`,
        },
        ...(showSource
            ? [
                  {
                      key: 'source',
                      header: t('metalContent.colSource'),
                      render: (r: MetalContentRow) =>
                          r.source_kind === 'assay' && r.source_href ? (
                              // 化验来源:标签就是单据号,点过去是那份化验
                              <a
                                  href={r.source_href}
                                  className="px-2 py-0.5 rounded text-xs bg-blue-100 hover:underline font-mono app-link"
                              >
                                  {r.source_label}
                              </a>
                          ) : r.source_kind === 'unknown' ? (
                              // 出处未知(PROC-1 之前录的行)—— 与"手工"是两回事,不能长得一样
                              <span className="px-2 py-0.5 rounded text-xs bg-amber-100 text-amber-800">
                                  {r.source_label}
                              </span>
                          ) : (
                              <span className="px-2 py-0.5 rounded text-xs bg-gray-200 text-gray-600">
                                  {r.source_label}
                              </span>
                          ),
                  } as Column<MetalContentRow>,
              ]
            : []),
        {
            key: 'updated',
            header: t('metalContent.colUpdated'),
            className: 'text-gray-600',
            render: (r) => r.updated_at_display,
        },
        {
            key: 'actions',
            header: t('metalContent.colActions'),
            // ★ R1:动作列在手机上【不折】。
            priority: true,
            render: (r) => (
                /* CONFIRM-1:主语就是那一行的金属 —— 与首列读到的字一样。
                   ★ ALERT-2a:这一处是【硬删除】—— inbound_batch_metals /
                     output_batch_metals 走 `.delete()`,行没了,没有任何地方留副本。 */
                <ConfirmButton
                    subject={metalLabel(r.metal)}
                    title={t('metalContent.deleteConfirm')}
                    body={t('common.hardDeleteNote')}
                    details={
                        <p className="text-sm font-medium text-[color:var(--brand-text)]">
                            {t('metalContent.deleteConsequence')}
                        </p>
                    }
                    confirmLabel={t('common.delete')}
                    tier="destructive"
                    disabled={isPending}
                    className="text-red-600 text-sm hover:underline disabled:text-gray-400"
                    onConfirm={() => handleDelete(r.metal)}
                >
                    {t('common.delete')}
                </ConfirmButton>
            ),
        },
    ]

    return (
        <section className="mt-8 pt-8 border-t">
            <div className="flex justify-between items-center mb-4">
                <h2 className="">{t('metalContent.title')}</h2>
                {priceHref && rows.length > 0 && (
                    <Button asChild variant="outline">
                        <a
                            href={priceHref}
                            target="_blank"
                            rel="noopener noreferrer"
                        >
                            {t('pricing.priceThisBatch')}
                        </a>
                    </Button>
                )}
            </div>

            {note && <p className="text-xs text-[color:var(--brand-muted-text)] mb-3">{note}</p>}

            {error && <p className="text-red-600 text-sm mb-3">{error}</p>}

            {/* ★ 转换前【没有空态】:rows 为空时这一块整个不画。
                组件自带的 table.empty 会新出现一句话,所以【守卫原样留着】——
                委托书:今天画什么都不画的,不要发明一句。 */}
            {rows.length > 0 && (
                <div className="mb-4">
                    <DataTable
                        rows={rows}
                        columns={columns}
                        rowKey={(r) => r.metal}
                        phone={{ mode: 'columns' }}
                    />
                </div>
            )}

            {/* 合计行:实时反映"保存后"的百分比合计;>100 只警告不拦截 */}
            <p className="text-sm mb-4">
                <span className="text-[color:var(--brand-muted-text)] mr-1">{t('metalContent.totalLabel')}:</span>
                <span className={'font-mono ' + (overHundred ? 'text-red-600' : '')}>
                    {projectedTotal.toFixed(2)}%
                </span>
                {overHundred && (
                    <span className="text-red-600 ml-2">{t('metalContent.totalWarning')}</span>
                )}
            </p>

            {/* 录入 / 覆盖行 */}
            <div className="flex flex-wrap gap-2 items-start">
                <select
                    value={selectedMetal}
                    onChange={(e) => setSelectedMetal(e.target.value)}
                    className={CONTROL_SELECT}
                >
                    <option value="" disabled>{t('metalContent.selectMetal')}</option>
                    {/* 【选单只列还能新选的】—— 停用的物质不出现在这里,
                        但上面那张表里它照样有名字。两个动词,两处不同的判断。 */}
                    {options.filter((o) => o.isActive).map((o) => (
                        <option key={o.value} value={o.value}>
                            {t(o.labelKey)}
                            {existing.has(o.value) ? t('metalContent.alreadySet') : ''}
                        </option>
                    ))}
                </select>
                {/* content_pct 在库里是无标度 numeric —— 微量贵金属化验值常到 3~4 位小数
                    (如 0.0035%),用 DecimalInput 不限位数;上下限由 handleSave 校验 */}
                <DecimalInput
                    placeholder={t('metalContent.pctPlaceholder')}
                    value={pctInput}
                    onChange={setPctInput}
                    className="w-32"
                />
                <Button
                    type="button"
                    onClick={handleSave}
                    disabled={isPending}
                >
                    {t('metalContent.save')}
                </Button>
            </div>
        </section>
    )
}
