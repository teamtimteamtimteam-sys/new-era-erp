// app/finance/agingBuckets.ts
// AR/AP 账龄档位共享定义:档位顺序(汇总条展示序)+ 天数彩签样式。
// 档位口径由 ar/ap_open_items 视图给出(bucket 列),前端只负责着色。

export const BUCKETS = ['b0_30', 'b31_60', 'b61_90', 'b90_plus'] as const

export function bucketPillClass(bucket: string): string {
    switch (bucket) {
        case 'b0_30':
            return 'bg-green-100 text-green-800'
        case 'b31_60':
            return 'bg-amber-100 text-amber-800'
        case 'b61_90':
            return 'bg-orange-100 text-orange-800'
        default:
            return 'bg-red-100 text-red-800'
    }
}
