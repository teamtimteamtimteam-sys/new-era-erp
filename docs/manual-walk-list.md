# 手走清单 —— 只有人点得到的那些断言

`db/fixtures` 问"建出来的库跑起来对不对";`scripts/smoke-routes.mjs` 问"每条路由渲不渲得出来"。
**这份清单问第三个问题:操作员在屏幕上【读到的那句话】是不是人话。**

没有任何自动化跑得到它,原因是具体的而不是懒:

* 冒烟只发 **GET**,它断言 2xx —— 它从不提交任何表单;
* 表单用 `useActionState`(客户端组件),**没有渐进增强的隐藏字段**,所以
  无 JS 的 POST 根本到不了 action;走 Next 的 action 线格式需要客户端 bundle 里的
  action id,而那正是浏览器才有的东西;
* fixture 是 SQL,它够得到 RPC,**够不到 action 与 locale 文件**。

于是"数据库那侧完全正确、而屏幕上是一串机器码"这件事,**只有人点得出来**。
IOD-1b 与 IOD-2 各付过一次账,两次都是人点出来的。

## 什么时候跑

改动了 **action 的错误分支、`*ErrorCodes.ts` 的集合、`messages/*` 里的错误/告警句子**,
或者新加了一个会抛到界面上的 RPC 错误码 —— 跑与之相关的那几条。不必每次全跑。

## 怎么起

```bash
npx next dev -p 3000
```
临时管理员账号自己建(参照 `scripts/smoke-routes.mjs` 的 `signIn`),或用一个真账号。
**被拒的走法不写任何流水**,可以放心在 live 上点;标着【会写库】的那几条会留下
**永久的 `inventory_movements` 行**(台账只进不出,`BEFORE DELETE` 抛 `MOVEMENT_IMMUTABLE`),
所以那几条要么别在 live 上点,要么接受它留下来。

---

## 1 · 库位分类落闸:明确排除 → 拒绝(IOD-2)

**前提**:一个在用库位配了 allowed_classes(例如只允许 `focused`);一个物料的分类
**不在**其中(例如 `non_focused`)。

**走**:`/inbound/new` → 选那个物料、那个库位 → 保存。
**期望**:红条是一句话,并且**说得出三条出路**(换库位 / 把这一类加进该库位 / 改物料分类):

> Location SG… is configured to hold specific material classes, and non_focused is not one of
> them — so nothing was saved. Pick another location, add non_focused to that location under
> Inventory → Storage Locations, or correct this material's classification in the material dictionary.

**不期望**:`IOD_CLASS_EXCLUDED|SG…|non_focused`(机器码原样)。

**为什么在这份清单里**:拒绝由 RPC 抛出(fixture 59 B3/E/F1/F2 已经钉住"抛得对"),
**但"抛完之后有没有被翻成人话"住在 action 的错误分支 + `messages/*` 里** —— fixture 是
SQL,够不到那两处。这一条 2026-08-13 手走时是红的:action 那时用一句手抄的正则挑
错误码,新码没被挑中,于是走了 `saveError` 分支把机器码端了出去。
现在判据改成 `isStockErrorCode()`(与 `STOCK_ERROR_CODES` 同一份),漂开的那条路没有了,
但**"句子长什么样"仍然只有人看得见**。

其余三个落地点同理,改了任何一处错误分支就顺带走一遍:
`/inbound/receive`、`/output/new`、以及批次页上的**转移**面板(它不重定向,告警直接回到面板)。

## 2 · 日期必填:说人话,不说约束名(IOD-2-fu1 / FIN-32)

**走**:`/output/new` → 填物料与数量,**产出日留空** → 保存钮应当是灰的、下面有一句
琥珀色说明;再想办法提交一次(绕过界面那道守卫)。
**期望**:

> Output date is required — the stock movement records the day the goods were actually produced

**不期望**:`new row for relation "inventory_movements" violates check constraint
"inventory_movements_business_date_required"`(约束原文)。

到货日在 `/inbound/new` 与 `/inbound/receive` 上同理。

**为什么在这份清单里**:这一条现在**有一半是自动的** —— fixture 25 H 臂断言三个 RPC
少了日期会**按名**拒绝(`ARRIVAL_DATE_REQUIRED` / `OUTPUT_DATE_REQUIRED`),那是
2026-08-13 手走之后补上的:当时 RPC 自己一道守卫都没有,只有 app 那一层有,
于是任何不经过表单的调用者都会撞到 FIN-32 的 CHECK 并拿到约束原文。
**剩下的一半仍然只有人点得到**:那个名字有没有在两个 locale 里接成句子、
以及界面那道守卫(禁用提交 + 说明)是不是真的在。

## 3 · 落地告警:琥珀、成句、一条一行(IOD-2)

**走**:把货收进一个**没配过 allowed_classes** 的库位,或收一个**未分类**的物料。
**期望**:落地页(`/inbound`、`/output`、收货完成页)顶部一条**琥珀色**横幅,
一条告警一行,并且**批次确实建出来了** —— 告警不是拒绝。

【**会写库**】这一条的期望结果是"保存成功",所以它会在 live 上留下永久流水。
2026-08-13 的做法是**只走渲染那一半**:直接请求
`/inbound?warn=%5B%22IOD_CLASS_UNCONFIGURED_LOCATION%7CSG…%22%5D`,
真组件、真本地化、不写库。RPC 会不会吐出这两个码,由 fixture 59 B1/C/E/F3 钉住。
两半合起来等于整条路径,而没有任何一行永久流水。

## 4 · 物料表单的【提交】那一半:安全库存阈值真的落库(SS-1)

**两条,新建与编辑各一条 —— 它们是两段不同的代码**:`app/materials/new/actions.ts`
走 `.insert()`,`app/materials/[id]/edit/actions.ts` 走 `.update()`,各有一份取值、
一份校验、一份写入。走通了一条不代表另一条。

**走 A(新建)**:`/materials/new` → 填必填项 + 安全库存填 `500` → 保存 →
回到列表,该物料那一列应当显示 `500 kg`,**而不是「未监控」**。
**走 B(编辑)**:`/materials/<id>/edit` → 把阈值**清空** → 保存 →
列表那一列应当变成**「未监控」**,而不是 `0`。
**走 C(两条表单各一次)**:阈值填 `0` 或 `-5` → 期望是那句话:
「安全库存必须是大于 0 的数字 —— 不想监控这个物料就留空」,
**不期望**约束原文 `materials_safety_stock_qty_positive`。

**为什么在这份清单里 —— 与前三条同一个理由,而且是同一堵墙**:表单用
`useActionState`(客户端组件),**没有渐进增强的隐藏字段**,所以无 JS 的 POST
到不了 action;走 Next 的 action 线格式又需要客户端 bundle 里的 action id。
冒烟只发 GET,fixture 是 SQL 够不到 action。**2026-08-13 的 SS-1 手走只走到了
渲染那一半**(两张表单的字段与提示句都确认渲染出来了,列表那一列也确认了),
**提交那一半一次都没有人点过** —— 那正是这一条存在的理由,别把它读成"已经走过"。

数据库那一侧不必在这里走:CHECK(NULL 或 > 0)由 fixture 60 F 臂两个方向各拒
一次,告警对 NULL 不响由 D 臂钉死。这一条只问【表单填的值有没有原样落进去】,
以及【拒绝有没有说人话】。

## 5 · 申报量真的落库,而【留空落的是 NULL 不是 0】(GRN-1b)

**两条,两张收货表单各一条 —— 它们是两段不同的代码**:
`app/inbound/new/actions.ts` 走 `create_inbound_batch`,
`app/inbound/receive/actions.ts` 走 `receive_inbound_batch_against_po`,
各有一份取值、一份校验、一份 RPC 调用。走通了一条不代表另一条。

**走 A(填了)**:`/inbound/new` 或 `/inbound/receive` → 申报量填 `1000`、
过磅数量填 `800` → 保存 → 打开该批次详情,「与采购单的对照」一段里应当出现
**「申报与实收不符」**,并写出 `申报 1000 / 磅秤 800 / 差 −200`,以及判它的那两个阈值。

**走 B(留空 —— 这一条才是要害)**:同样两张表单,申报量**什么都不填** →
保存 → 详情页**不许**出现「申报与实收不符」,而且不许出现任何"申报 0"的字样。
库里那一列应当是 `NULL`。**填 0 与留空必须是两种结果**:留空 = 没记录过,
0 = 供应商申报了零(一句没人说过的话)。

**走 C(选了采购行之后)**:在 `/inbound/receive` 选一个供应商 → 选一张采购单 →
选一条采购行。**数量框会被预填成剩余量(那是对的,便利)**;
**申报量框必须【仍然是空的】**。这一条是这三条里最重要的:
一个被预填的申报量,是系统替供应商说了话 —— 它会让"申报与实收一致"在没有任何
供应商文件的情况下成立,而那正是这一列存在要回答的问题。

**为什么在这份清单里**:与前四条同一堵墙 —— 表单是 `useActionState`,
冒烟只发 GET,fixture 是 SQL 够不到 action。数据库那一侧由 fixture 87 E 臂
三个方向钉死(没记 = NULL、相符 = 数字 0、超差 = 报),**这一条只问
【表单填的值有没有原样落进去,以及留空有没有真的留空】**。

## 6 · 收错料的那句话说的是【收下了】,不是【被拦住了】(GRN-1b)

**前提**:一张 confirmed/receiving 的采购单,某一行订料 A;现场收到的是料 B。

**走**:`/inbound/receive` → 选那张单、那一行 → **把物料改成 B** → 保存。
**期望两件事,缺一不可**:
1. **保存成功**,批次建出来了 —— 收错料【不拒绝】(换料是可以谈成的正当安排);
2. 批次详情的「与采购单的对照」里出现**「收到的不是订的料」**,写出两个料号,
   并且**明说这批货已经收下、已经入账**。

**为什么第 2 点的措辞是这一条的全部**:告警在屏幕上极容易被读成"这批货被卡住了"。
读错的操作员会去找一个并不存在的放行按钮,或者**更坏:再收一次**。
所以这一条要走的不是"有没有提示",而是**"提示有没有说清楚货已经进来了"**。

【**会写库**】走这一条会留下永久的 `inventory_movements` 行 —— 台账只进不出。
要么别在 live 上点,要么接受它留下来。

## 7 · 供应商模式面板的两个【只有人看得见】的状态(GRN-2)

**为什么这一条必须在这份清单里,而不是做成 fixture**:fixture 88 钉住的是
**视图**那一半 —— 无权读者拿到【0 行】(H 臂)、没有可比对收货的供应商仍然
拿到【一行全 0】(G/J 臂)。但"这一行 0 在屏幕上被印成哪一句话",是
`ReceiptPatternPanel` 里的一个 React 分支,**fixture 是 SQL,够不到它**
(本文件开头那三条理由,第三条)。而这两句话恰恰是这一刀的全部意义。

**走 A(具名空状态)**:`供应商` → **Staff Reimbursements** → 「收货记录」面板。
**期望那一句话是**:
> 最近 180 天里,没有任何一条【有订量可比】的收货 —— 所以这里没有可供评判的东西。
> 这【不是】一份干净的记录:它的意思是,还没有人能够检验这家供应商。

**不期望**:任何一行"短交 0 次 / 超收 0 次"之类的零。**看到零就是这一条失败了** ——
五种差异的计数在这个分支里【整块不渲染】,因为它们的分母是 0,而印出来的零会被
读成"全都合规"。同一块面板下方仍应印出「没法评判:1 条」——
那 1 条正是它唯一的收货。

**走 B(受限)**:用一个持 `module.suppliers.view`、【不持】`module.purchasing.view`
的账号打开任意一家供应商。**期望**:
> 这份记录在采购模块那道门后面,而你没有那个权限。这是一句【权限答复】——
> 它不是在说这家供应商记录干净。

**不期望**:空白、零、或者「这不该发生」。
**这一条今天在线上走不通**:实测五个持 suppliers.view 的角色(admin / auditor /
finance / gm / procurement)【全部】也持 purchasing.view,所以要走它得先临时建一个
只给 suppliers.view 的角色。**记下来而不是省掉**:角色表会变,而那一天没有人会
记得回来补这一条 —— GRN-1b 在批次详情上栽的正是这个分支(当时它渲染的是
「这不该发生」,对着 warehouse 与 operations 两个真实角色天天说)。
