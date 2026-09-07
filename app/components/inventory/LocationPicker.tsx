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
            {/* ★ BTN-6/F7(2026-09-07):这一段【不是警告】,所以不再穿警告的颜色。
                它此前是 text-amber-800(走查读成"深红";实测是琥珀 800)。
                而这段话陈述的是【选库位时会做什么检查】—— 它不警告任何事、
                也不链接到任何地方,三态里还有两态是「只记不拒」。
                一段永远在屏幕上的散文穿着状态色,会把状态色本身教成装饰,
                于是真正的警告(上面 blockedCertExpired 那一条红框)就不再显眼。
                改成与它上面那句提示【同一个】ordinary 正文色 —— 两句都是说明,
                本来就该长一样。
                ☞ 这是一处【共用组件】的改动:LocationPicker 有三个调用点
                  (/inbound/receive · /inbound/new · /output/new),
                  所以它按共享层的规矩量,不是只量走查点名的那一页。 */}
            <p className="text-xs text-gray-500 mt-1">{t('stock.receiptLocationClassCheck')}</p>
        </div>
    )
}
