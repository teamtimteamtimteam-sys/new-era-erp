// lib/companyAddress.ts
// EQP-1c-b-fu2:公司抬头地址里,【国家什么时候不该再印一遍】。
//
// 【走查看到的是"25 Haji Lane, Singapore, 189218, Singapore"】。
// 【错的是模板,不是数据 —— 查过了】company_profile 里每一列装的都对:
//     address_lines '25 Haji Lane' · city 'Singapore' · postal_code '189218' · country 'Singapore'
// 新加坡【本来就】既是城市又是国家。所以不能去改数据把 country 清掉 ——
// 那会让"这家公司在哪个国家"这个事实从库里消失,只为了让一张纸好看。
//
// 【两份模板,两种拼法,而且【两份都】重复】——
//   * 采购单:[address_lines, city, postal_code, country].join(', ')
//     → "25 Haji Lane, Singapore, 189218, Singapore"
//   * 发票:城市行 [city, postal_code].join(' ') 之后【另起一行】印 country
//     → "Singapore 189218" / "Singapore"
// 也就是说这【不是】一处共用的抬头,是两份各自长出来的副本 —— 那本身就是一条发现。
//
// 【这个模块只抽出两份都需要的那一条判断,不去统一版式】
// 两份的排版是刻意不同的(一份一行逗号、一份多行叠着),把整块抬头抽出来会
// 改掉发票的样子。所以抽出来的是【那条规则】:国家与城市相同时不再单独印。
// 一条规则,一个实现,两个调用方 —— 版式一个像素都没动。
//
// 【判据是数据驱动的,不写死任何国名】"国家 == 城市"对新加坡成立,对摩纳哥、
// 梵蒂冈同样成立;写死 'Singapore' 会是本仓库那条"币种是数据不是常量"的同一种病。

/** 国家这一行该不该单独印 —— 与城市相同就不印(城邦:印两遍是重复,不是完整)。 */
export function countryIfDistinct(
    company: { city?: string | null; country?: string | null },
): string | null {
    const city = (company.city ?? '').trim()
    const country = (company.country ?? '').trim()
    if (!country) return null
    if (city && city.toLowerCase() === country.toLowerCase()) return null
    return country
}
