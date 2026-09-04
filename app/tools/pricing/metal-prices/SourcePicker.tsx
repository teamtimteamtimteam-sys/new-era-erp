'use client'

// LME-1b:行情出处的录入控件 —— 两张录入表单共用(批量、单条)。
//
// 【它恢复的是 LME-1a 故意留着不能用的那条路】1a 让 source 必填,而表单还没有
// 这个控件,于是录入当场被拒。这一刀是修复,不是新功能。
//
// 【索引选择器只在"发布的指数"时启用 —— 镜像 1a 那条配对 CHECK】
// 库里的约束是 `source <> 'published_index' OR price_index IS NOT NULL`:
// 选了发布指数就必须说是哪一个。表单把它做成"只有选了它,指数下拉才可用"。
// 【注意这比 CHECK 严】CHECK 允许经纪商报价【也】带一个指数;表单不允许。
// 这是一个刻意的收窄(见 known-issues:若要放开,只改这里一行,库不用动),
// 代价写在这里:经纪商报价因此落在【未标注】那条序列上,而未标注序列按 USD 处理。
//
// 【延迟是三态,不是复选框】当天 / 延迟 / 未记录 —— 一个复选框只有两态,
// 而"没记录过"必须与"记录了否"分得开(1a 的列注释就是这么写的)。
// 默认是【未记录】:不推断,也不替录入的人回答。
import { useState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import IndexPicker from './IndexPicker'
import { type MetalPriceIndex } from './indexOptions'
import {
    NEW_QUOTE_SOURCES, DELAY_UNRECORDED, DELAY_SAME_DAY, DELAY_DELAYED,
} from './sourceOptions'

const fieldCls = 'w-full border border-gray-300 px-3 py-2 rounded'

export default function SourcePicker({
    indices, locale, indexName = 'price_index', onIndexChange, defaultIndex = null, error,
}: {
    indices: MetalPriceIndex[]
    locale: string
    /** 服务端按名拒绝时的那句话 —— 【贴着控件显示】,不要只丢进页顶的红条 */
    error?: string
    indexName?: string
    /** 批量录入页换指数时要重取参照价 —— 与 IndexPicker 原有的 onChange 同一条 */
    onIndexChange?: (value: string) => void
    defaultIndex?: string | null
}) {
    const t = useTranslations()
    const [source, setSource] = useState<string>('')
    const isPublished = source === 'published_index'

    return (
        <div className="space-y-3 border border-gray-200 rounded p-3 bg-gray-50">
            <div>
                <label className="block text-sm font-medium mb-1">
                    {t('metalPrices.source.label')} <span className="text-red-600">*</span>
                </label>
                <select
                    name="quote_source"
                    required
                    value={source}
                    onChange={(e) => setSource(e.target.value)}
                    className={fieldCls}
                >
                    <option value="" disabled>{t('metalPrices.source.choose')}</option>
                    {NEW_QUOTE_SOURCES.map((s) => (
                        <option key={s} value={s}>{t('metalPrices.source.' + s)}</option>
                    ))}
                </select>
                {/* 【"来源未记录"为什么不在选项里】读的人会在列表上看到这个状态,
                    所以它必须在这里被解释一次,而不是留给人猜。 */}
                {error && <p className="text-red-600 text-xs mt-1">{error}</p>}
                <p className="text-xs text-gray-500 mt-1">{t('metalPrices.source.unknownNotOffered')}</p>
            </div>

            <div>
                <label className="block text-sm font-medium mb-1">
                    {t('metalPrices.index.label')}
                    {isPublished && <span className="text-red-600"> *</span>}
                </label>
                {isPublished ? (
                    <IndexPicker
                        name={indexName}
                        indices={indices}
                        defaultValue={defaultIndex}
                        locale={locale}
                        allowUnstated={false}
                        onChange={onIndexChange}
                    />
                ) : (
                    <>
                        {/* 禁用的 select 不会进 FormData —— 服务端因此收到"没有指数",
                            正是我们要的。但【禁用必须说出为什么】(本仓库反复的那一条):
                            一个灰着不语的下拉,操作员分不清是坏了还是不该填。 */}
                        <select disabled className={fieldCls + ' bg-gray-100 text-gray-400'}>
                            <option>{t('metalPrices.index.onlyForPublished')}</option>
                        </select>
                        <p className="text-xs text-gray-500 mt-1">
                            {t('metalPrices.index.onlyForPublishedHint')}
                        </p>
                    </>
                )}
            </div>

            <div>
                <label className="block text-sm font-medium mb-1">
                    {t('metalPrices.source.referenceLabel')}
                </label>
                <input
                    type="text"
                    name="source_reference"
                    className={fieldCls}
                    placeholder={t('metalPrices.source.referencePlaceholder')}
                />
                <p className="text-xs text-gray-500 mt-1">{t('metalPrices.source.referenceHint')}</p>
            </div>

            <div>
                <label className="block text-sm font-medium mb-1">
                    {t('metalPrices.source.delayLabel')}
                </label>
                <select name="quote_delayed" defaultValue={DELAY_UNRECORDED} className={fieldCls}>
                    <option value={DELAY_UNRECORDED}>{t('metalPrices.source.delayUnrecorded')}</option>
                    <option value={DELAY_SAME_DAY}>{t('metalPrices.source.delaySameDay')}</option>
                    <option value={DELAY_DELAYED}>{t('metalPrices.source.delayDelayed')}</option>
                </select>
                <p className="text-xs text-gray-500 mt-1">{t('metalPrices.source.delayHint')}</p>
            </div>
        </div>
    )
}
