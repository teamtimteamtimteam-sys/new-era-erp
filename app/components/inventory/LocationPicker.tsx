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
            {/* 【这句必须在】选了库位看起来像"系统会检查这里能不能放这类货",
                而那件事今天【不存在】—— 落闸归 IOD-2。不说,这个下拉就在
                暗示一个并不成立的保证。 */}
            <p className="text-xs text-amber-800 mt-1">{t('stock.receiptLocationNoCheck')}</p>
        </div>
    )
}
