CREATE OR REPLACE FUNCTION public.normalise_counterparty_identity()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 名字:去首尾空白 + 压掉内部连续空白。**不动大小写** ——
    -- 公司名的大小写是它自己的写法("Pte Ltd" vs "PTE LTD" 都是人写下的样子),
    -- 存的时候不该替人改;大小写只在【比较】时折叠(见 app 层的近重复提示)。
    IF NEW.legal_name IS NOT NULL THEN
        NEW.legal_name := regexp_replace(btrim(NEW.legal_name), '\s+', ' ', 'g');
    END IF;
    -- 登记号:去空白 + **大写**。空字符串落成 NULL ——
    -- 「没填」与「填了空」必须是同一件事,否则部分唯一索引会把一堆 '' 当成真值去比。
    IF NEW.tax_id IS NOT NULL THEN
        NEW.tax_id := upper(regexp_replace(btrim(NEW.tax_id), '\s+', '', 'g'));
        IF NEW.tax_id = '' THEN NEW.tax_id := NULL; END IF;
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.normalise_counterparty_identity() IS
    'GO-4:suppliers / customers 写入时规范化 legal_name(去空白)与 tax_id(去空白+大写)。放在触发器而不是只放在服务端动作里,是因为 authenticated 对这两张表持表级 INSERT 授权,只写在 app 里的规范化会被直连写入绕过,而那会让【存进去的值】与【比较用的值】分家 —— 唯一性规则于是静静失效。';