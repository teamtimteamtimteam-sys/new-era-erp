// app/stocktakes/status.ts
// 盘点单状态 → i18n 标签键的反查(端口自 processing/status.ts)。列表页与详情页共用。
// 未知值返回 null,调用方回退成原样显示(不会显示成 key 路径)。
export function stocktakeStatusLabelKey(value: string | null | undefined): string | null {
    if (value === 'open' || value === 'posted' || value === 'cancelled') {
        return 'stocktakes.status.' + value
    }
    return null
}
