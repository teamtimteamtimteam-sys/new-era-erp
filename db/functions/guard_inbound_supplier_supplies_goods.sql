CREATE OR REPLACE FUNCTION public.guard_inbound_supplier_supplies_goods()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_sup record;
BEGIN
    -- 【只在 INSERT 与【换了供应商】的 UPDATE 上开火】
    -- 写宽一格的代价是具体的:软删是一次 UPDATE,而一条挂在非供货户下的历史收货
    -- 【必须还能被软删掉】——否则本刀第 4 步(清掉那条冒烟残留)会被自己锁死。
    -- 同理,已经在册的历史收货不因为供应商日后被标成非供货而变得不可维护。
    IF TG_OP = 'UPDATE' AND NEW.supplier_id IS NOT DISTINCT FROM OLD.supplier_id THEN
        RETURN NEW;
    END IF;

    SELECT code, legal_name, supplies_goods INTO v_sup
      FROM suppliers WHERE id = NEW.supplier_id;

    -- 查不到供应商不是本守卫的事(外键会管),不越权替它报错
    IF NOT FOUND THEN
        RETURN NEW;
    END IF;

    IF NOT v_sup.supplies_goods THEN
        -- 【按名拒绝,并且说得出是哪一家】一句"不允许"让操作员无从下手:
        -- 要么这一家标错了(去供应商页改),要么收货挑错了户(重选)。
        RAISE EXCEPTION 'RECEIPT_AGAINST_NON_GOODS_VENDOR|%|%', v_sup.code, v_sup.legal_name;
    END IF;

    RETURN NEW;
END;
$function$

;

COMMENT ON FUNCTION public.guard_inbound_supplier_supplies_goods() IS 'SUP-TYPE-1a:不许把货收在一个【不供货】的往来户名下(房东、水电、保险这一类)。按名抛 RECEIPT_AGAINST_NON_GOODS_VENDOR|<code>|<name>。
【为什么是触发器而不是写进两个收货 RPC】实测:以 authenticated 裸 INSERT 会被 RLS 拒(该表没有 INSERT 策略),但 service_role 与 postgres 都 rolbypassrls = true,服务密钥这条路绕得过 RLS。而收货侧现有五条规矩全部是触发器 —— 写进 RPC 既要抄两份(第二份会漂开),又盖不住服务密钥那条路。
【只在 INSERT 与换供应商的 UPDATE 上开火】写宽一格会让挂在非供货户下的历史收货【软删不掉】(软删是一次 UPDATE),那正是本刀清理冒烟残留时会撞上的墙。';
