// app/purchasing/discrepancies/page.tsx
// GRN-1b:收货差异清单 —— 【一个正常点得到的地方】。
//
// 【为什么需要它,而两张详情页不够】批次详情说得出"这一条怎么了",采购单详情
// 说得出"这一张单怎么了" —— 但两者都要求你【先知道去看哪一张】。线上那几条差异
// 此前没有任何一条路径能把人带到它们跟前:知道它们存在的唯一办法是敲 URL,
// 而那不是导航,那是记忆。所以这一页存在的理由是【被路过】。
//
// 【它显示的是 grn_discrepancies,一条收货一行 —— 连同它说不出的那一类】
// 视图的粒度是一条收货一行,于是一条【一次都没收过】的采购行不产生任何行,
// 而那恰恰是最彻底的短交(GRN-1a 在视图抬头点名的盲区)。这一页因此在末尾
// 明说这件事,并把人送到采购单列表去 —— **绝不**在这里自己补一个"零收货"查询:
// 那就是 GRN-1a 拒绝顺手做掉的那张伴生视图,写在页面里等于把它写成了第二份
// 会漂开的实现(而且是 TypeScript 那一份)。
//
// 【权限】视图自己是属主权限 + has_permission('module.purchasing.view'),
// 所以无权者读到 0 行。但 0 行【不能】被渲染成"没有差异" —— 那正是
// lib/permissions.ts 存在的理由。requireModule 在任何查询之前把这件事
// 变成一句权限答复(OPS-15),于是"看不见"与"没有"从此是两块不同的屏。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows, mustOne } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import ReceivingThresholdPanel from './ReceivingThresholdPanel'
import DiscrepancyKinds, {
    type DiscrepancyRow, type ReceivingThresholds,
} from '@/app/components/receiving/DiscrepancyKinds'

export default async function ReceivingDiscrepanciesPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推(这一页尤其:视图对无权者就是 0 行)。
    const denied = await requireModule(MOD.purchasing)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    // 【两条查询放在一起发】阈值与判词分属两次查询,而判词是【视图用当时那三个数】
    // 算的。同一批发出去,是应用层能做到的最接近"同一时刻"的读法;两者之间有人改了
    // 阈值,屏幕上会显示新阈值配旧判词。这是一个已知的、很窄的窗口,写在这里而不是
    // 假装不存在 —— 真要消除它,视图得把它用的那三个数一起返回(那是一支迁移)。
    const [rowsRes, settingsRes] = await Promise.all([
        supabase
            .from('grn_discrepancies')
            .select('batch_id, batch_code, arrival_date, supplier_name, po_id, po_code, po_status, ' +
                    'line_id, line_no, ordered_material_code, received_material_code, ' +
                    'ordered_qty, ordered_unit, received_qty, received_unit, declared_qty, ' +
                    'line_received_qty, line_receipt_count, line_delta_qty, line_delta_pct, ' +
                    'declared_delta_qty, assay_beyond_tolerance, assay_metals_compared, ' +
                    // PROC-1B-iii:两侧的【原始码】都要取 —— 只取那个布尔的话,
                    // 「没设」与「未评估」在屏幕上就并成一句了(两者的布尔都是 NULL)。
                    'deep_discharge_judged, deep_discharge_actual, deep_discharge_contradicted, kinds')
            .order('arrival_date', { ascending: false }),
        supabase
            .from('receiving_settings')
            .select('grn_short_pct, grn_over_pct, grn_assay_tolerance_pct')
            .maybeSingle(),
    ])

    // 【失败必须失败】读不出来的差异清单必须报错,不许渲染成一张干净的空表 ——
    // 一张说"没有差异"的空表,与一张读不出数据的空表,在屏幕上一模一样。
    const all = mustRows(rowsRes, 'grn_discrepancies') as unknown as (DiscrepancyRow & {
        arrival_date: string | null; supplier_name: string | null; po_id: string; line_id: string
    })[]
    const settings = mustOne(settingsRes, 'receiving_settings') as ReceivingThresholds | null

    // kinds 为空的行是【正常的收货】,不进清单 —— 这一页问的是"哪里不对"。
    const rows = all.filter((r) => r.kinds && r.kinds.length > 0)

    // ── 【页面这道门比服务端那道【窄】,而这是量过的,不是猜的】────────────────
    // 面板画不画成可编辑,取自 module.purchasing.edit(这块屏在采购侧);
    // 真正放行的是 receiving_settings 的 UPDATE 策略,写的是 module.inbound.edit
    // (GRN-1a:收货的设置归收货)。两者【不是同一道】,所以必须回答一句:
    // 会不会摆出一个服务端保证会拒的按钮?
    //   实测(2026-08-17,线上角色表):持 purchasing.edit 的四个角色
    //   (admin / finance / gm / procurement)【全部】也持 inbound.edit ——
    //   所以窄门不会放进任何一个会被拒的人。
    //   反过来那两个只持 inbound.edit 的(operations / warehouse)【不持
    //   purchasing.view】,requireModule 在上面就把他们挡住了,根本到不了这一页。
    // 于是今天两道门没有分歧。**而这是一个观察,不是一条保证** —— 所以判决权
    // 仍然只在服务端:thresholdActions 不自己判权限,它看【回写了几行】,
    // 两道门将来真的分开时,用户拿到的是一句具名拒绝,不是一次静默的无事发生。
    const canEdit = await can('module.purchasing.edit')
    // ★ FIX-2b:receiving_settings 的 RLS 是 module.inbound.view,而本页的门是采购。
    const canSeeReceivingSettings = await can('module.inbound.view')

    return (
        <>
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-2">{t('grn.list.title')}</h1>
                <p className="text-sm text-gray-600 mb-4">{t('grn.list.note')}</p>

                {/* GRN-1b:三个阈值。人人看得见(下面每一条提示出不出现都取决于它),
                    有写权限的人改得动。settings 读不出来时不画面板,而不是画一个
                    填着猜测值的面板 —— 一个显示错阈值的面板比没有面板坏。 */}
                {/* ★ FIX-2b fu:判据是【权限码】,不是 settings 是不是 null ——
                    从空结果倒推正是这一刀在修的那个病。一个持 module.inbound.view
                    却恰好没有那一行的库(全新重建就是),会被倒推法说成「你没有权限」。 */}
                {!canSeeReceivingSettings ? (
                    /* ★★【FIX-2b:上面那句"读不出来时不画面板"漏掉了一种读不出来】★★
                       它写的是「一个显示错阈值的面板比没有面板坏」—— 对的,而
                       receiving_settings 的门是 module.inbound.view,本页的门是采购。
                       于是【一个只有采购权限的读者永远走这一支】,而下面每一条
                       差异提示的分寸都由这三个数定:面板不在,那些提示就成了没有
                       标尺的判断。不画面板仍然对,但要说出为什么它不在。 */
                    <p className="text-sm text-gray-600 border border-gray-300 rounded px-3 py-2 mb-4">
                        {t('grn.po.thresholdsRestricted')}
                    </p>
                ) : settings ? (
                    <ReceivingThresholdPanel
                        shortPct={Number(settings.grn_short_pct)}
                        overPct={Number(settings.grn_over_pct)}
                        assayPct={Number(settings.grn_assay_tolerance_pct)}
                        canEdit={canEdit} />
                ) : null}

                {rows.length === 0 ? (
                    /* 【"没有差异"要说得出它的范围】—— 空表配一句"一切正常"是这一页
                       最容易犯的错:它对那条一次都没收过的采购行是句假话。 */
                    <p className="text-sm text-gray-600 border border-gray-300 rounded px-3 py-2">
                        {t('grn.list.empty')}
                    </p>
                ) : (
                    <div className="space-y-4">
                        {rows.map((r) => (
                            <div key={r.batch_id} className="border border-gray-300 rounded-lg p-4">
                                <div className="flex flex-wrap items-center gap-x-3 gap-y-1 mb-2 text-sm">
                                    <Link href={`/inbound/${r.batch_id}/edit`}
                                          className="font-mono text-blue-600 hover:underline">
                                        {r.batch_code}
                                    </Link>
                                    <span className="text-gray-400">·</span>
                                    <Link href={`/purchasing/orders/${r.po_id}`}
                                          className="font-mono text-blue-600 hover:underline">
                                        {r.po_code}
                                    </Link>
                                    <span className="px-2 py-0.5 bg-gray-200 rounded text-xs">
                                        {t('purchasing.status.' + r.po_status)}
                                    </span>
                                    <span className="text-gray-500">#{r.line_no}</span>
                                    {r.supplier_name && <span className="text-gray-600">{r.supplier_name}</span>}
                                    {r.arrival_date && <span className="text-gray-500">{r.arrival_date}</span>}
                                </div>
                                {settings && (
                                    <DiscrepancyKinds
                                        row={r}
                                        thresholds={settings}
                                        assayHref={`/inbound/${r.batch_id}/edit`} />
                                )}
                            </div>
                        ))}
                    </div>
                )}

                {/* 【这张清单说不出什么 —— GRN-1a 点名的盲区,写在屏幕上】
                    粒度是一条收货一行,所以一条一次都没收过的采购行【根本不产生行】。
                    空白在这里【不是】"没问题",而这一句就是不让它被那样读的全部办法。 */}
                <div className="mt-8 border-t border-gray-200 pt-4 max-w-3xl">
                    <p className="text-sm font-medium text-gray-700">{t('grn.blindSpot.title')}</p>
                    <p className="text-sm text-gray-600 mt-1">{t('grn.blindSpot.body')}</p>
                    <Link href="/purchasing/orders?status=closed"
                          className="text-sm text-blue-600 hover:underline">
                        {t('grn.blindSpot.link')}
                    </Link>
                </div>
            </div>
        </>
    )
}
