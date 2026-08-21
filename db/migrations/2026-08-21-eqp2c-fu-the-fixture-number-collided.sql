-- EQP-2c-fu(2026-08-21):一处【指错了的指针】—— 本刀的 fixture 撞了号。
--
-- 主迁移里 equipment_service_intervals.lead_kg 的列注释写着"fixture 110 的 F6",
-- 而 **110 这个号已经被 EQP-1c-c-fu 的 `110-the-pickers-read-the-masked-view.sql`
-- 占了**。本刀的那一支因此改号成 111,注释也要跟着改 —— 否则这条注释会把下一个
-- 读它的人送去一份【讲的是别的事】的 fixture。
--
-- 【为什么值得一支迁移,而不是就地改了主迁移文件了事】主迁移已经【提交到线上】了;
-- 改文件不会改线上那条注释,而 check_mirrors 是逐列比 col_description 的 ——
-- 于是"就地改一改"换来的是一次镜像漂移。**迁移文件是变更日志,不是可以回去
-- 重写的稿子**(与 AGENTS.md 那条"提交信息改不了历史文件"同一条)。
--
-- 【号是怎么撞的,记一句免得再来一次】`ls db/fixtures/*.sql | wc -l` 得到 109,
-- 于是下一号看起来是 110。**但那个计数里有一份 README.md,而且 100+ 的文件名
-- 在字典序里排在 92-99 【前面】,`ls | tail` 看不见它们。**
-- 判据应当是 `ls db/fixtures/ | grep -oE '^[0-9]+' | sort -n | tail -1`,不是数个数。

BEGIN;

COMMENT ON COLUMN public.equipment_service_intervals.lead_kg IS
'EQP-2c:还差多少公斤就开始报【将到期】。**这个数是【数据】,推导现读它** ——
fixture 111 的 F6 在同一笔事务里把它调大再调小,看那一支臂两个方向都动。
【0 是一个决定,不是"没填"】0 = 不要提前警告,到期那一刻才上牌;
而 interval_kg 一旦给了,本列就【必须】给(表上那条 CHECK)—— 留空与 0 若都
合法,两种拼法就有了同一个意思,而"没填"会静默地变成"不提前警告"。
【严格小于 interval_kg】等于间隔 = 一盏从第一天起就亮着的灯。';

COMMIT;
