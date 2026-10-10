// lib/substances.ts — MES-6a-2(2026-10-10,MES-0 Q69;MES-6a Step 0 Q27 · Q29 · Q30,Tim)
//
// 物质字典的【展示】与【分角色】—— 一份实现,所有页面共用。纯函数、不 import 任何 '@/…':
// scripts/check-substance-display.mjs 在构建里直接 import 它,断言下拉的名字来自字典、ppm 写法与"不舍入"。
//
// ① 名字(Q30):下拉的选项读【字典自己的】name_en / name_zh(按读者的语言),不再拼 'metals.<code>' 的文案键 ——
//    以后加一种物质就只是一行,它自己带着名字。(屏幕上把码翻成名字的那几处仍用 metals.* 键;氟、氯两个键与它们的字典行同一刀加上。)
// ② 角色(Q27):定价的那几页只给按含量计价的金属(payable_metal);合同的惩罚条款只给惩罚元素(penalty_element);
//    化验、含量、必测项、预计化验、品位规格、配料目标给全部。服务端(表上的守卫与写入函数)对不该来的按名拒 ——
//    这里只是不把一个必然被拒的选项递给人(AGENTS.md「must not offer it」)。
// ③ ppm(Q29):含量【以 % 存、以 % 录】;惩罚元素在 % 旁边带 ppm(1 % = 10,000 ppm)。【不舍入】:存的是什么就印什么 ——
//    MetalContentPanel 那种 toFixed(2) 会把 0.0050 % 印成 0.01 %,而 50 ppm 正是惩罚条款要比的那个数。
//    换算按十进制字符串移小数点做,不经浮点乘法(实测:0.0029 × 10000 在浮点里是 28.999999999999996,1.005 × 10000 是 10049.999999999998)。

export type SubstanceRole = 'payable_metal' | 'penalty_element' | 'other'
export const SUBSTANCE_ROLES: readonly SubstanceRole[] = ['payable_metal', 'penalty_element', 'other']

export type SubstanceRow = {
    code: string
    name_en: string
    name_zh: string
    symbol: string | null
    is_active: boolean
    role: SubstanceRole
}

/** 下拉 / 复选框的一个选项。label 已经是读者语言的那一份(字典自己的名字)。isActive:能不能【新选】(D5)。 */
export type SubstanceOption = { value: string; label: string; isActive: boolean; role: SubstanceRole }

/** 一行字典 → 读者语言的名字。 */
export function substanceName(row: Pick<SubstanceRow, 'name_en' | 'name_zh'>, locale: string): string {
    return locale === 'zh' ? row.name_zh : row.name_en
}

/** 字典行 → 选项。【停用的行也在里面】(带 isActive = false)—— 选单自己过滤,把码翻成名字的地方不能过滤(D5)。 */
export function toSubstanceOptions(rows: SubstanceRow[], locale: string): SubstanceOption[] {
    return rows.map((r) => ({ value: r.code, label: substanceName(r, locale), isActive: r.is_active, role: r.role }))
}

/** 只留按含量计价的金属 —— 行情、计价器、公式、合同计价条款与精炼费那几页。 */
export function payableOnly<T extends { role: SubstanceRole }>(rows: T[]): T[] {
    return rows.filter((r) => r.role === 'payable_metal')
}

/** 只留惩罚元素 —— 合同的惩罚条款那一页。 */
export function penaltyOnly<T extends { role: SubstanceRole }>(rows: T[]): T[] {
    return rows.filter((r) => r.role === 'penalty_element')
}

export const PPM_PER_PCT = 10000

/** 一个十进制数(数字或它的字符串)原样写出来 —— 不舍入、不补零、不用科学计数法。读不懂的原样还回去。 */
export function plainDecimal(v: number | string): string {
    const s = typeof v === 'number' ? numberToPlain(v) : String(v).trim()
    return /^-?\d+(\.\d+)?$/.test(s) ? trimZeros(s) : s
}

/** 把小数点往右(正)或往左(负)挪 n 位 —— 纯字符串运算,没有浮点误差。 */
export function shiftDecimal(v: number | string, places: number): string {
    const s = plainDecimal(v)
    const m = /^(-?)(\d+)(?:\.(\d+))?$/.exec(s)
    if (!m) return s
    const [, sign, int, frac = ''] = m
    let digits = int + frac
    let point = int.length + places
    if (point <= 0) { digits = '0'.repeat(1 - point) + digits; point = 1 }
    if (point > digits.length) digits = digits + '0'.repeat(point - digits.length)
    const out = trimZeros(`${digits.slice(0, point)}.${digits.slice(point)}`)
    const clean = out.replace(/^0+(?=\d)/, '')
    return clean === '0' ? '0' : sign + clean
}

/** % → ppm(× 10,000),原样精度。 */
export function ppmOf(pct: number | string): string {
    return shiftDecimal(pct, 4)
}

/** 惩罚费率:每个百分点 → 每个 ppm(÷ 10,000)。合同条款的单位不改(Q29),这只是旁边那一格的等值写法。 */
export function perPpmOf(perPct: number | string): string {
    return shiftDecimal(perPct, -4)
}

/** 一个含量怎么印:% 永远印(原样精度);惩罚元素另带 ppm。 */
export function contentDisplay(pct: number | string, role: SubstanceRole | null | undefined): { pct: string; ppm: string | null } {
    return { pct: plainDecimal(pct), ppm: role === 'penalty_element' ? ppmOf(pct) : null }
}

/** 一格【列头已经写着 %】的含量:"0.0123" 或惩罚元素的 "0.0123 (123 ppm)"(化验详情的金属表)。 */
export function contentCell(pct: number | string, role: SubstanceRole | null | undefined): string {
    const d = contentDisplay(pct, role)
    return d.ppm === null ? d.pct : `${d.pct} (${d.ppm} ppm)`
}

/** contentDisplay 的一行字:"0.0123%" 或 "0.0123% (123 ppm)"(与屏幕上别处的 "20.00%" 同一种写法,不加空格)。 */
export function contentText(pct: number | string, role: SubstanceRole | null | undefined): string {
    const d = contentDisplay(pct, role)
    return d.ppm === null ? `${d.pct}%` : `${d.pct}% (${d.ppm} ppm)`
}

function numberToPlain(n: number): string {
    if (!Number.isFinite(n)) return String(n)
    const s = String(n)
    if (!/e/i.test(s)) return s
    // 1e-7 之类:按指数挪小数点
    const [mant, expS] = s.toLowerCase().split('e')
    return shiftDecimal(mant, Number(expS))
}

function trimZeros(s: string): string {
    if (!s.includes('.')) return s
    const t = s.replace(/0+$/, '').replace(/\.$/, '')
    return t === '' || t === '-' ? '0' : t
}
