// app/display/page.tsx
// MES-8b-2(2026-10-17,MES-0 Q83 · MES-8 Step 0 Q19 · Q20 · Q29,Tim):车间大屏 —— 一块墙上的屏,只画计数。
//   读的只有一支 floor_board()(SECURITY DEFINER,门 data.view_floor_board):加工 · 安全 · 库存那几支此刻各有几件事在等人。
//   ★ 只有数:没有钱、没有名字、没有健康信息,也没有任何链接(一块屏没有人去点它;一块大屏的会话也打不开别的页)。
//   ★ 没有外壳:根布局对 /display 不画顶栏、面包屑与告知区;空闲监视器只对【不是大屏】的会话照挂(admin、cfo 打开它时照常空闲登出)。
//   ★ V28 没给:顶上「refreshed at hh:mm」与一颗刷新钮,不自动刷新(Q20);给了之后只画选中的牌子、按间隔自己刷新。
//   ★ V28 的设定一块在最底下,给不是大屏的读者看(持 action.manage_permissions 的才按得动);大屏自己的会话不画它 —— 那是一块挂在墙上的屏。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireFloorBoard } from '@/app/components/moduleGuard'
import { isFloorDisplayOnly } from '@/lib/floorDisplay'
import { toBusinessDateTime } from '@/lib/dates'
import RefreshControls from './RefreshControls'
import DisplaySettingsPanel from './DisplaySettingsPanel'

type Tile = { section: 'processing' | 'safety' | 'inventory'; item_type: string; count: number }
type Board = { as_of: string; tiles: Tile[]; refresh_seconds: number | null; settings_set: boolean }

export default async function DisplayPage() {
    const denied = await requireFloorBoard()
    if (denied) return denied
    const t = await getTranslations()
    const supabase = await createClient()
    const board = mustOne(await supabase.rpc('floor_board'), 'floor_board') as unknown as Board
    const floorSession = await isFloorDisplayOnly()

    const sectionLabel: Record<Tile['section'], string> = {
        processing: t('display.sectionProcessing'),
        safety: t('display.sectionSafety'),
        inventory: t('display.sectionInventory'),
    }
    const sections = (['processing', 'safety', 'inventory'] as const)
        .map((s) => ({ s, tiles: board.tiles.filter((x) => x.section === s) }))
        .filter((g) => g.tiles.length > 0)
    const refreshedAt = toBusinessDateTime(board.as_of)?.time ?? '—'

    let settings: { arms: { item_type: string; label: string }[]; tiles: string[] | null; canEdit: boolean } | null = null
    if (!floorSession) {
        const [armsRes, settingsRes, canEdit] = await Promise.all([
            supabase.rpc('floor_board_arms'),
            supabase.from('floor_board_settings').select('refresh_seconds, tiles').maybeSingle(),
            can('action.manage_permissions'),
        ])
        const arms = mustRows(armsRes, 'floor_board_arms') as { item_type: string; section: string; sort_order: number }[]
        const row = mustOne(settingsRes, 'floor_board_settings') as { refresh_seconds: number | null; tiles: string[] | null } | null
        settings = {
            arms: arms.map((a) => ({ item_type: a.item_type, label: t('dashboard.item.' + a.item_type) })),
            tiles: row?.tiles ?? null,
            canEdit,
        }
    }

    return (
        <main className="min-h-screen bg-gray-50 p-4 sm:p-8 space-y-6" data-page="display">
            <header className="flex flex-wrap items-end justify-between gap-4">
                <h1 className="text-3xl font-bold">{t('display.title')}</h1>
                <RefreshControls refreshedAt={refreshedAt} refreshSeconds={board.refresh_seconds} />
            </header>
            {sections.map(({ s, tiles }) => (
                <section key={s} className="space-y-3" data-section={s}>
                    <h2 className="text-xl font-semibold">{sectionLabel[s]}</h2>
                    <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-3">
                        {tiles.map((x) => (
                            <div key={x.item_type} data-tile={x.item_type}
                                className={'rounded-lg border-2 bg-white p-4 min-w-0 ' + (x.count > 0 ? 'border-amber-400' : 'border-gray-200')}>
                                <p className="text-base text-gray-700 break-words">{t('dashboard.item.' + x.item_type)}</p>
                                <p className="text-5xl font-bold tabular-nums mt-2" data-value={`count-${x.item_type}`}>{x.count}</p>
                            </div>
                        ))}
                    </div>
                </section>
            ))}
            {settings && (
                <section className="border-t border-gray-300 pt-6 space-y-3" data-section="floor-board-settings">
                    <h2 className="text-lg font-semibold">{t('display.settings.title')}</h2>
                    <p className="text-sm text-gray-600">{board.settings_set ? t('display.settings.set') : t('display.settings.notSet')}</p>
                    <DisplaySettingsPanel arms={settings.arms} refreshSeconds={board.refresh_seconds} tiles={settings.tiles} canEdit={settings.canEdit} />
                </section>
            )}
        </main>
    )
}
