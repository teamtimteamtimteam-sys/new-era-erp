# 看不见就按名拒 · 产出料的安全状态 · 在制品 · "不适用"(PROC-WIRE-1B-ii,2026-08-31)

四件事一刀。**第 2 步是安全项,写在迁移最前面** —— 万一后面任何一步卡在一次
拿不到的裁定上,它可以单独提交(Tim 的 A1 明写了这条退路;最终四件事全部落地)。

上游:[proc-operations-wired.md](proc-operations-wired.md)(1B-i)、
[proc-batch-purpose-and-state-dictionary.md](proc-batch-purpose-and-state-dictionary.md)(1A)、
[proc-loss-and-saleability.md](proc-loss-and-saleability.md)(四条拒绝)。

---

# 零 · ★★ 这一刀纠正了三条【原 brief 里写错的】前提 ★★

**逐条记下来,因为按错的那一条去修,会修出一个看起来绿的洞。**

## 错 1 · "返回 NULL 而不是 0" 这条药方,对一个 `void` 断言是【毒药】

PROC-COST-1 fu2 与 PROC-COST-2 第 4 步都用过那条药方,而它们治的是**返回数字**的
读取器:无权时给 NULL,让「受限」与「没有」分得开。

**本刀这两支函数 `RETURNS void`。** 对一个 void 断言,"返回 NULL"这个动作拼出来
就是【不抛异常地返回】—— **那正是 SALE-BLIND 这个病本身**。照抄那条已经成功两次
的药方,会把这个 bug 重新发布一遍,而且带着两处先例背书。

> ★ **判断标准一句话:问这支函数"无权时它拿什么表示无权"。**
> 有返回值的用 NULL;没有返回值的,只能用一次抛出 ——
> 因为它的"静默"与"通过"是同一个字节。

## 错 2 · SALE-BLIND 不是一处,是三处,其中一处在另一支函数里

实测 `assert_output_batch_saleable` 体内三个依赖各自的 RLS:

| 依赖 | 谁挡着 | 读不到会怎样 |
|---|---|---|
| `output_batches` | `module.output.view` | 第一句 SELECT `NOT FOUND` → `RETURN` → **四条拒绝全部跳过** |
| `materials` | `module.materials.view` | `assert_material_form_saleable` 查不到 → **法律那条拒绝永不触发** |
| `processing_outputs` | `module.processing.view` | `v_from_run` 为假 → `SALE_FORM_NOT_SET` 跳过 |

第二条住在 **`assert_material_form_saleable`**,它【不在】那六支待清理的 RLS 盲函数
名单里 —— 本刀新发现的,而且它扛的是**法律**那条拒绝(没有旁路的那一条)。

> ★ 只修外面那一支,等于发布一道【下一层还漏着】的闸,同时发布一份
> "断言绝不因为看不见而通过"的 fixture —— **那份 fixture 会制造信心,
> 而制造信心比不修更坏。** 所以两支一起修(Tim 的 A2),
> 并且 **fixture 164 两帧分别立臂**:将来把其中一帧重新捅漏的改动,
> 躲不到另一帧还绿的后面。

## 错 3 · 可达路径与钥匙,原 brief 都指错了

`record_output_sale` 与 `ship_order` **都是 SECURITY DEFINER**。一个 INVOKER 触发器
在 DEFINER 函数体内运行时取的是【属主】身份 —— 所以**这两扇前门上 RLS 根本不生效,
断言看得见一切。它们不是那条洞。**

真正可达的是另一条:`sales_records` 有一条面向客户端的 INSERT 策略
(`module.finance.edit`),于是一次直连 PostgREST 的插入会让触发器**以调用者自己的
身份**跑起来。`sales_order_reservations` 没有 INSERT 策略,只有 DEFINER 门。

> ★ **可达路径只有一条,而它的钥匙是 `finance.edit`,不是 `sales.edit`。**
> 结论(洞是真的、可达的)不变,但一个照着原 brief 那条路去设的闸会【设错地方】。

---

# 一 · 第 2 步:两支断言都不许因为看不见而通过

## 改之前实测到的不对称(线上,真角色,全部回滚)

拿 `OUT-2026-0184` 做题,逐字记录:

| 场景 | 读者 | 实得 |
|---|---|---|
| 挂上工序投料指定 | admin(全权) | `SALE_BATCH_EARMARKED\|OUT-2026-0184\|下游工序投料\|Feed for a downstream operation` |
| 同上 | 只有 `processing.view` | **通过,一条拒绝都没有** |
| 形态换成负极片(`may_be_sold = false`) | admin | `SALE_FORM_NOT_SALEABLE\|anode_sheet\|负极片\|Anode sheet` |
| 同上 | **`warehouse`(线上真角色,无 `materials.view`)** | **通过,一条拒绝都没有** |
| 同上,直接调内帧 | `warehouse` | **通过** |

**第二组用的是线上一个真实存在的角色,不是构造出来的。**

## 改之后(同一批,同样回滚)

| 帧 | 读者 | 实得 |
|---|---|---|
| 外 | 只有 `processing.view` | `SALE_CANNOT_ESTABLISH_SALEABILITY\|OUT-2026-0184\|output_batch` |
| 外 | admin / `sales.edit` / `finance.edit` / `output.view` | `SALE_BATCH_EARMARKED\|…`(**真正的**那条拒绝) |
| 内 | `warehouse` | `SALE_FORM_NOT_SALEABLE\|anode_sheet\|负极片\|Anode sheet`(**盲过变成了真拒绝**) |
| 内 | 一把钥匙都没有 | `SALE_CANNOT_ESTABLISH_SALEABILITY\|MAT-2026-0001\|material_form` |

## 第五条拒绝

`SALE_CANNOT_ESTABLISH_SALEABILITY|<主体>|<帧>` —— **五条拒绝,不许再涨,也不许并掉:**

| 拒绝 | 它说的是 | 下一步动作 |
|---|---|---|
| `SALE_FORM_NOT_SALEABLE` | 这东西法律上不许卖 | 没有旁路 |
| `SALE_FORM_NOT_SET` | 形态没设,判断不了 | 去设形态 |
| 库存类 | 数量不够 | 少卖点或换一批 |
| `SALE_BATCH_EARMARKED` | 这一批许给了下游工序 | 释放指定,或换一批 |
| ★ `SALE_CANNOT_ESTABLISH_SALEABILITY` | **调用者没有资格判断** | **去要权限** |

【一个码,两个帧,用载荷区分】第二段是 `output_batch` / `material_form`。
不造第六个码,但两帧必须分得开。

## 白名单,以及每一项在这里的理由

`module.sales.edit` OR `module.finance.edit` OR `module.output.view`

* `finance.edit` —— **唯一那条可达路径的钥匙**(`sales_records` 直插)。
* `sales.edit` —— `quote_lines` 的 INSERT 策略要它;内帧还有两个入口
  (`quote_lines` / `sales_order_lines`,经 `guard_line_form_saleable`)。
  少了它,一次合法的报价会被第五条拒绝挡住。
* `output.view` —— 在批次页上合法看这一批的人,该拿到【真正的】那条拒绝。
* ★ **故意不收 `processing.view`** —— 持有它并不使人成为卖家;收了它就会让上面
  实测到的那个盲读者【通过受众判据】,却依旧看不见 `output_batches`:
  等于把这道闸原样修回成一个哑闸。

## 这里的危险与 PROC-COST-2 的 Q7 【方向相反】

Q7 怕的是一个 NULL 顺着算式传下去,把一笔钱悄悄算小(**静默**)。
★ 本条怕的是相反的一件事:**一个响在合法卖家头上的火警,把一条正常的线停掉**
(**喧哗**)。所以白名单的取舍标准不是"尽量窄",是
**"宽到任何一条合法写入路径的持钥人都不会被它挡住,而不再宽一格"**。
fixture 164 H6 三把钥匙各一个用户,逐个断言他们拿到的是**真正的**那条拒绝。

而 Q7 那种毒 NULL 在这里【按构造不可能】:两支函数都 `RETURNS void`,
**没有任何调用者对它做加法或乘法,因为它根本没有值**(两个调用点都是
BEFORE INSERT 触发器里的 `PERFORM`)。**一个表达不出来的失败,写不出断言** ——
所以这一条没有 fixture,而这句话就是它的记录。

---

# 二 · 第 3 步:产出料也要被问同一个安全问题(R1 / M4)

## 那处不对称,与它被挡在哪一行

`guard_processing_input` 里 PROC-3 那一段**只问 `NEW.inbound_batch_id`**。
原注释自己写着理由:不是"产出批不需要问",是【问不了】—— 安全状态过去只有进料批有。
于是 M4:**买进来的极片要过火闸,自己产的极片连问都问不到。**

★ Tim 的 R1:**抬高产出这一侧,绝不放低进料那一侧。**

## 结构:平行表,共用同一本字典(A3)

新 `output_batch_safety_states`,与 `inbound_batch_safety_states` 同形,
**共用 `inbound_safety_states` 这本字典,一个字不改**。

* ★ **必须不许分叉的是【字典】** —— 它是"一个状态是什么意思"以及"哪道工序受理它"
  的唯一定义;分叉它,同一个码就会有两种意思,而
  `operation_type_safety_states` 的表注已经明令受理只能有一个定义方式。
* **那张联结表不是字典**,所以它可以分。
* 【为什么是平行表,不是把老表改成 XOR】仓库里两个先例指向两个方向:
  `processing_inputs` 走 XOR,`inbound_batch_metals` / `output_batch_metals` 走平行表。
  **更近的是金属那一对** —— 一个逐批的实测事实,两种出处。改老表要动一个带主键、
  带触发器、有线上行的结构,买到的只是少一条分支。
* 【字典没有改名】只加一句表注说明它讲的是【物料状态】而不是"只属于进料"。
  改名会为了一件纯外观的事 churn 掉每一份 fixture 与那张受理表的外键。

## ★★ 回填决定:一行都不写,而"缺席"必须【拦】(A4)★★

**这是本刀要记住的那个决定,连同它的理由。**

**为什么不回填**
: 线上 20 批产出全是测试残留,产线一天没开过。给它们写上
  `discharged_verified` 等于**记下一次没有人做过的核验** —— 那是一条假记录,
  与把 `ZZ-PROCCOST1-DEMO` 注销掉是同一种错(记一件没发生过的事)。

**为什么缺席必须拦(从"NULL 在闸上是什么意思"论证,不从方便论证)**
: 进料那一侧,"一行安全状态都没有"已经有名字、有拒绝:
  `INPUT_SAFETY_STATE_NOT_RECORDED` —— **没有行 = 没有人看过,不是"安全"**。
  产出这一侧若让同一种缺席变成通过,**同一个"空"在两张表里就有了相反的意思**,
  而那正是本仓库反复付账的那一族(METAL-1 的 `no_reference`、SS-1 的阈值 NULL、
  PROC-1 的 `may_be_processed`)。

**三条产出侧拒绝**(与进料侧同形但不同名 —— 下一步动作差在【去哪块屏幕记】):
`PRODUCED_SAFETY_STATE_NOT_RECORDED` · `PRODUCED_SAFETY_STATE_NOT_FEEDABLE` ·
`PRODUCED_SAFETY_STATE_NOT_ACCEPTED`。

## ★★ 与进料侧【刻意的分歧】:产出侧不看 `has_condition_axes` ★★

**这是一处有意的不同,不是照抄时漏掉的一行。**

进料侧那道闸包在 `IF FOUND AND v_axes IS TRUE` 里。产出侧【不能】照抄,
理由是一次测量:**线上 20 批产出,它们的物料 `kind_code` 全是 NULL** →
`has_condition_axes` 全 NULL → 照抄那一行,**这道闸会对【零】批货生效,
而那份证明它生效的 fixture 会对着空气变绿。**

★ 对产出料,"种类没人分过"的意思是**没有人分过类**,而那【不是许可】。
**这是一道火闸:未知的安全状态不是许可。**

fixture 165 K5 就是那份 fixture 的解药 —— 注入"照抄版"之后它按名报红,
而 K2/K3/K4 在同一次注入下**全部照旧变绿**,那正是 K5 必须单独存在的理由。

(进料侧那个相反的取舍是刻意的、有记录的,本刀不动:那边的空意思是
"这条轴比这行料还年轻",拦掉它等于停掉线上每一笔收货。)

## 本刀因此新拦下什么 —— 线上量过

* 线上 **12** 批活着、还有余量的产出批,**没有一批记过安全状态** ——
  此后把它们中的任何一批再投料,都会被 `PRODUCED_SAFETY_STATE_NOT_RECORDED` 拦下,
  直到有人去记。
* 历史上真实发生过的再加工腿有 **1** 条(FIN-25 那条路是活的,不是理论)。
* 本刀写入 `output_batch_safety_states` 的行数:**0**。
* ★ **今天的代价是零(产线没开,20 批全是测试残留),而这条拒绝要的正是
  "投料之前有人看过这批料"这个动作。**

## fu1:那条占位的拒绝,理由没了,拒绝也跟着走

主刀应用之后才读到:`commit_processing_run` 里有一条**自己写明了在等本刀**的
占位拒绝 —— `STATE_CHANGE_OUTPUT_INPUT_UNSUPPORTED`,注释写着
「这一条等 1B-ii 的 `output_batch_safety_states`」。

★ **它正是 M4 那处不对称本身,只是穿了一件"暂不支持"的外衣** ——
一道工序因为料是"自己产的"就拒绝它。表建好了,那条拒绝的全部理由都不成立。
**留着它比拆掉更坏**:下一个人读到的是"这条路仍然没通",而任何钉着那条拒绝的
fixture 会**对着一条早该消失的拒绝变绿**。

同时补上"改状态"在产出批这一侧的落点(与进料侧逐字同形:删掉被解决的状态,
写上 `resulting_safety_state_code`)。★ 不补这一段,一批放完电的【自产】料会
永远带着"未放电" —— **那就是 1B-i 解掉的那个死锁,原样搬到产出批上复发。**
fixture 165 K7 两头都钉住。

---

# 三 · 第 4 步:在制品(R3)—— **不建 WIP 表**

★ PROC-WIRE-1A 已经立过:`purpose_code = 'process_feed'` 的产出批**就是**在制品那一行。
**再建一张表就会重复计数**,因为那一行已经在 `output_batches` 里了。

本刀只加:

* `output_batches.awaiting_operation_type_code`(可空,外键到 `operation_types`)——
  【空 = "还没决定等哪道",**不是**"不适用"】:还没排到具体工序的料仍然是在制品。
  **是不是在制品由 `purpose_code` 回答,等哪一道由本列回答。**
* `guard_output_batch_awaiting_operation` —— 可售库存的批次上本列必须为空,
  否则会长出"既可售、又在排队"的自相矛盾行。
* 视图 `processing_wip` + 屏幕 `/processing/wip`(什么在等 · 多少 · 等哪一道 ·
  安全状态记了没有)。
* `set_output_batch_purpose` 多一个可选参数;**释放指定时由门自己清掉指针** ——
  不是调用者要记得的一步。

fixture 166 L2 **直接对着 `pg_class` 断言库里没有任何 WIP 基表** ——
一份只数视图行数的 fixture 拦不住有人顺手加一张表。

---

# 四 · 第 5 步:"不适用"不再冒充"没测"

状态改变型工序**按定义没有产出腿**(`operation_kinds.produces_outputs = false`),
所以 `recovery_blocked_by` 说 `output_not_measured` 是**不精确**的。

**今天它还不是假话**(两者都导向"回收率算不出来"),但两句话的下一步动作不同:

* `output_not_measured` → 去把产出化验录进来;
* `output_not_applicable` → 什么都不用做,这道工序根本不产出。

★ **产出测量真正要紧的那一天,两者会分道** —— 而那时说错的那一句会教人去补一份
**根本不存在**的化验。趁它还只是不精确的时候修,比等它变成假话之后再修便宜。

【没有工序类型的单仍然报 `output_not_measured`】**说不出"不适用"的时候不许猜它。**
线上 13 张单没有工序类型,它们的答案一个字没变(实测:改动后
`output_not_applicable` 0 行,`output_not_measured` 仍然 9 行 —— 线上今天
一张已提交的状态改变型加工单都没有)。

---

# 五 · 权限

| 动作 | 权限码 | 为什么是它 |
|---|---|---|
| 记 / 撤 产出批安全状态 | `module.output.edit` | 跟着父单据判(与 `inbound_batch_safety_states` 同一条)。**它不是工序决定** —— 看见一批料鼓包了,不是"把它许给产线"。 |
| 读产出批安全状态 | `module.output.view` | 同上 |
| 设 / 释放 工序投料指定 + 在等哪一道 | `module.processing.edit` | 把一批货许给产线是【工序】决定(PROC-WIRE-1A 立的,本刀没动) |
| 读在制品那块屏 | `module.processing.view` | 它回答的是产线的问题("下一炉该跑什么") |

**没有新增权限码。** 四项全部落在已有的码上,所以不需要给任何角色发新权限。

---

# 六 · 仍然开着的东西(别读成关了)

* **六支 RLS 盲函数里还剩五支**(本刀修掉的是名单外新发现的
  `assert_material_form_saleable`,以及名单内的 `assert_output_batch_saleable`):
  `bank_book_balance_asof`、`attendance_unpaid_days`、`sale_settlement_compute`、
  `resolve_review_reviewer`,以及 `journal_activity_lines` 上面那一层。
  排在开账号之前的清理里。
* **客户预留优先于工序指定** —— Tim 已裁定,但 `set_output_batch_purpose`
  今天仍然不检查未了结的预留。**那是 1B-iii,本刀没建。**
* **G29 的质量暂扣那一半**仍然开着(第三条轴,不许并进用途里)。
* **11 个孤儿管理员授权**指向已删除的 auth 用户;`check-scratch-rows.mjs` 看不到那张表。
* **注销分母(÷ quantity)** 在成本已资本化到一批部分消耗过的料上时会少解除。
  已知、继承来的,要一个子批次模型。
* `water_exposed` 仍然一道工序都不受理 —— 等一次裁定,不等一个猜测。
* 五行游离的 scratch 行,检查器报了,刻意没扫。
