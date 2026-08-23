/**
 * 【近重复:一个定义,两种处置】(GO-4)
 *
 * DICT-ADMIN(2026-08-23 上线)在字典的 code 上建了一道近重复检查:去空白、
 * 不分大小写比一遍、命中就【按名拒绝】并把既有拼法引出来。GO-4 要给
 * suppliers / customers 的 legal_name 加同一种比较 —— 但**处置必须不同**。
 *
 * 把比较逻辑抄第二份,正是两条规矩日后各自演化的由来,所以比较住在这里,只有一份。
 * 而**处置刻意留在各自的调用点**,因为它们的答案是相反的,而且理由值得写在各自现场:
 *
 *   · **字典的 code → 拒绝。** code 是外键指着的那个东西。同一个东西长出第二种
 *     拼法,就是把一部分行挂到了一个新的、意义相同的键上 —— materials.category
 *     曾经长出四种命名法,那是整批 PROC 的起因。那里没有"两个都对"的情形。
 *   · **公司的 legal_name → 只警告,不拦。** 两家【真正不同】的公司可以同名
 *     (不同法域的同一个商号),所以拦住一次正当的第二次录入是错的,而且更坏:
 *     它会把人逼去绕开 —— 改个拼法录进来,于是造出的正是这条规矩要防的那种脏数据。
 *     公司的身份是**登记号**(tax_id),那一条由数据库上的部分唯一索引执行。
 *
 * **两种强度,说清楚:登记号在数据库执行;名字只是表单上的一句提醒。**
 */

/** 去首尾空白 + 把内部连续空白压成一个。**不动大小写** —— 存的是人写下的样子。 */
export function normaliseIdentityText(raw: string): string {
    return raw.trim().replace(/\s+/g, ' ')
}

/** 比较用的折叠形式:规范化之后再折大小写。**只用于比较,绝不用于存储。** */
export function foldForCompare(raw: string): string {
    return normaliseIdentityText(raw).toLowerCase()
}

/**
 * 在 rows 里找出与 candidate 近重复的那一行,返回它【原本的拼法】(要引给人看的那个)。
 * 找不到返回 undefined。
 *
 * 【skip】改一行自己时要把它自己排除掉,否则"改了个别的字段"会撞上自己。
 */
export function findNearDuplicate<T>(
    candidate: string,
    rows: readonly T[],
    pick: (row: T) => string,
    skip?: (row: T) => boolean
): string | undefined {
    const key = foldForCompare(candidate)
    if (!key) return undefined
    for (const row of rows) {
        if (skip?.(row)) continue
        const value = pick(row)
        if (foldForCompare(value) === key) return value
    }
    return undefined
}
