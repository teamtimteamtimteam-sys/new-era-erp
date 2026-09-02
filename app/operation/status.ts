// app/operation/status.ts
// 加工单状态 → i18n 标签键的反查。列表页与详情页共用同一个 mapper。
// 未知值返回 null,调用方回退成原样显示(不会显示成 key 路径)。
export function processingStatusLabelKey(value: string | null | undefined): string | null {
    if (value === 'committed' || value === 'reversed') {
        return 'processing.status.' + value
    }
    return null
}
