// app/inbound/options.ts
// 进料/出料模块共享的下拉选项
// value = 写入数据库的规范值(保持不变);labelKey = i18n 显示文案的键

export type InboundOption = { value: string; labelKey: string }

export const STAGE_OPTIONS: InboundOption[] = [
    { value: '待加工', labelKey: 'inbound.stage.toProcess' },
    { value: '加工中', labelKey: 'inbound.stage.processing' },
    { value: '已加工完', labelKey: 'inbound.stage.processed' },
]

// output batches 用(stored 值保持不变;output 模块本地化时再接 labelKey)
export const STATE_OPTIONS: InboundOption[] = [
    { value: '库存中', labelKey: 'output.state.inStock' },
    { value: '部分售出', labelKey: 'output.state.partiallySold' },
    { value: '已售罄', labelKey: 'output.state.soldOut' },
]

// value → labelKey 反查;找不到(自定义/未知值)返回 null
export function labelKeyForValue(
    options: InboundOption[],
    value: string | null | undefined
): string | null {
    if (!value) return null
    return options.find((o) => o.value === value)?.labelKey ?? null
}
