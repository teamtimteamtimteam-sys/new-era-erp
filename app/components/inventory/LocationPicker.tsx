'use client'

// app/components/inventory/LocationPicker.tsx
// IOD-1b:收货表单上的【可选】库位选择。清单由页面(服务端)取好传进来。
//
// 【"未指定"是默认,而且它的措辞是刻意的】选项文案就是"未指定 —— 之后用转移
// 指定":它把不选说成一个【正常的、可补的】答案,而不是一处空白。货是真的,
// 只是还没有记录放在哪(LOC-1/STK-1 的一等状态)。
//
// 【下拉只列在用库位,是便利;拒绝在函数里】停用/不存在的库位由
// resolve_receipt_location 点名拒(IOD_RECEIPT_LOCATION_INACTIVE / _UNKNOWN)——
// 下拉挡不住直接调 RPC 的人,所以判断不能只住在这里。
import { useTranslations } from '@/lib/i18n/client'

export type LocationChoice = { id: string; code: string; name: string }

export default function LocationPicker({ locations }: { locations: LocationChoice[] }) {
    const t = useTranslations()
    return (
        <div>
            <label className="block text-sm font-medium mb-1">{t('stock.receiptLocation')}</label>
            <select name="location_id" defaultValue="" className="w-full border border-gray-300 px-3 py-2 rounded">
                <option value="">{t('stock.receiptLocationUnspecified')}</option>
                {locations.map((l) => (
                    <option key={l.id} value={l.id}>{l.code} — {l.name}</option>
                ))}
            </select>
            <p className="text-xs text-gray-500 mt-1">{t('stock.receiptLocationHint')}</p>
            {/* IOD-2:这句话从"不检查"改成了"检查什么"。留着它的理由变了但没有
                消失 —— 现在它要防的是【反过来那个错觉】:闸落下了,于是看起来
                像"分类被管住了"。管住的只有【新落地的货】,而三态里只有一态会
                真的拒绝。存量冲突今天没有任何东西会说出来(归告警那一刀)。 */}
            <p className="text-xs text-amber-800 mt-1">{t('stock.receiptLocationClassCheck')}</p>
        </div>
    )
}
