# 一串机器字走到人面前 —— 两种形态,一种已挡,一种报数(CCY-1,2026-08-10)

同一个病:**本该是人话的字符串,以机器形态出现在屏幕上**。两种形态都可判定
(拿文件解析就能算出来),但**输入不同、失败方式不同、需要的判断也不同**,
所以是**两个检查,不是一个**。

## 形态一:文案有占位符,调用点没传 —— 已挡(check-i18n 新增一条 FAIL)

解析器对认不出的占位符**原样保留**(`lib/i18n/client.tsx` 的 replace 回调),
于是 `'Accrued selected: {accrued} {ccy}.'` 只传了 `accrued` 时,屏幕上真的印着
**「1,234.00 {ccy}。」**。这与"键不存在就原样印键名"是同一个机制的第二种出口,
而在此之前**没有任何检查看得见它**。

**实测:5 处,2 个文件** —— 而且**其中 3 处是上一刀(ASY-3)自己造的**:
我给 `assay.currentPrice` / `newPrice` / `totalDelta` 加了 `{ccy}`,却只改了影响块
那一个调用点,没改化验详情页"已应用的价格变动"那一块。另外 2 处在现金流量表
(`cashflowFxEffectHint` 的 `{0}`、`colAmount` 的 `{ccy}`)。全部已修。

**检查落在 check-i18n 里**,因为它**已经**在解析这两侧:消息文件(真的 eval 出对象,
不是正则猜)和 `t()` 调用点(含 `(await getTranslations())(…)` 那种写法)。新增的只是
把第二个实参一起收下来比对。

写它的过程里两次**误报**,都当场修掉了 —— 误报比漏报更坏,它教人忽略这条检查:

1. 实参截了 200 字符的窗口 → 跨行的对象字面量被截断,`StatusPanel` 明明传齐了
   三个却被报成"一个都没传"。改成**从源码按花括号配对切**。
2. 实参是变量(`t(key, state.result)`)时静态判不出来,被当成"没传"。改成
   **三态**:没有第二个实参 / 有但不是对象字面量(判不了,不算失败,同 MANIFEST
   的 `'data'` 口径)/ 对象字面量源码。

**已注伤验过**:把现金流量表的 `{ ccy: baseCurrency }` 拿掉 → check-i18n 退出码 1,
点名文件、行号、键、以及后果那句话。

## 形态二:DB 抛出编码错误,却没有任何文案 —— **是一个类,45 处,本刀只报数**

`SUPPLIER_QUALIFICATION_EXPIRED` 与 `PO_NOT_APPROVED`(CMP-2 手工补上的那两个)
不是孤例。全库扫描 `db/functions/*.sql` 与 `db/tables/*.sql` 的 `RAISE EXCEPTION`:

| | 数量 |
|---|---|
| DB 抛出的编码错误(去重) | 300 |
| 其中**两个文案文件里都没有对应文案** | **90** |
| 其中**应用直接 `.rpc()` 调用的函数抛出**(用户点一下就能撞到) | **45** |
| 其中应用直接写的表上的触发器抛出 | 0 |
| 其余(内部函数,或只有直连 SQL 才触发) | 45 |

**45 是"用户点一下就能撞到、而且会看见裸码"的下限**,包括
`CREDIT_LIMIT_EXCEEDED` 与 `CREDIT_HOLD`(**SAL-B 那一刀留下的**,当时写了点名
拒绝却没写文案)、`CLAIM_EXCEEDS_LIMIT`、`INSUFFICIENT_ACCRUED_LEAVE`、
`METAL_PRICE_MISSING`、`EDIT_REQUIRES_VIEW` 等。它们今天走的是各页的
`saveError: '保存失败:{message}'`,于是屏幕上是
「保存失败:CREDIT_LIMIT_EXCEEDED|ZZ-C3|10000|8820|2000」。

**为什么不与形态一合成一个检查**:输入在 SQL 侧(要解析 `RAISE EXCEPTION`)、
判据要一个**可达性模型**(哪些码走得到界面),而且必然需要一份**白名单**——
结构性守卫(`*_APPEND_ONLY`、`*_IMMUTABLE`、只有直连 SQL 才碰得到的那些)
本来就不该有文案,把它们算进失败会逼人写 45 条没人会看见的文案。
白名单的口径是**判断**,不是解析,所以它该有自己的一刀:先定"哪些算面向用户",
再让检查跟着那条线走。这与 `check-currency-literals` 的 ALLOWLIST、
`check_mirrors` 的 `DEFINER_NO_CHECK_ALLOWED` 是同一种东西。
