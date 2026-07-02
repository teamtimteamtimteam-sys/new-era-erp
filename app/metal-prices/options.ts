// app/metal-prices/options.ts
// 金属下拉选项(与 DB 的 7 金属 CHECK 集合一致:ni/co/li/mn/cu/al/fe)。
// value = 存入数据库的规范 code;labelKey = i18n 显示键 'metals.<code>'。
// 后续进料/产出的金属含量面板也会共用这一份定义,避免两边漂移。

export type MetalOption = { value: string; labelKey: string }

export const METAL_OPTIONS: MetalOption[] = [
    { value: 'ni', labelKey: 'metals.ni' },
    { value: 'co', labelKey: 'metals.co' },
    { value: 'li', labelKey: 'metals.li' },
    { value: 'mn', labelKey: 'metals.mn' },
    { value: 'cu', labelKey: 'metals.cu' },
    { value: 'al', labelKey: 'metals.al' },
    { value: 'fe', labelKey: 'metals.fe' },
]

// 合法金属规范值集合(校验下拉/表单传入的值)
export const METAL_VALUES: readonly string[] = METAL_OPTIONS.map((o) => o.value)

// value → labelKey 反查;找不到(未知值)返回 null
export function metalLabelKey(value: string | null | undefined): string | null {
    if (!value) return null
    return METAL_OPTIONS.find((o) => o.value === value)?.labelKey ?? null
}
