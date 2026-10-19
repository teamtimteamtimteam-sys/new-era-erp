import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'

// MES-8b-2:车间大屏一族 DB 函数(floor_board / set_floor_board_settings)抛出的错误码。【逐条从函数体枚举出来的】。
// 不在集合内的是真正未编码的 DB 错误,交给共用兜底 lib/machine-text.ts。
export const FLOOR_BOARD_ERROR_CODES = new Set([
    'FLOOR_BOARD_SETTINGS_PAIR_INCOMPLETE',
    'FLOOR_BOARD_REFRESH_INVALID',
    'FLOOR_BOARD_TILES_EMPTY',
    'FLOOR_BOARD_TILE_UNKNOWN',
    'FLOOR_BOARD_TILE_DUPLICATE',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeFloorBoardError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    if (!match) return await fallbackForRawError(raw, 'localizeFloorBoardError@app/display/displayErrorCodes.ts')
    const t = await getTranslations()
    if (match[1] === 'PERMISSION_DENIED') return t('permissions.errDenied')
    if (!FLOOR_BOARD_ERROR_CODES.has(match[1])) {
        return await fallbackForRawError(raw, 'localizeFloorBoardError@app/display/displayErrorCodes.ts')
    }
    const params: Record<string, string> = {}
    if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return t('display.errors.' + match[1], params)
}
