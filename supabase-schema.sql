-- ============================================================================
-- 社区团购二维码下单工具 - Supabase 数据库初始化脚本
-- 使用方法：复制到 Supabase SQL Editor 中执行
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 1. 商品表
CREATE TABLE IF NOT EXISTS products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  image TEXT,
  specs JSONB NOT NULL DEFAULT '[]'::jsonb,
  tags JSONB NOT NULL DEFAULT '[]'::jsonb,
  stock NUMERIC(10,3),
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 兼容已创建过的旧表：CREATE TABLE IF NOT EXISTS 不会自动补列。
ALTER TABLE products ADD COLUMN IF NOT EXISTS image TEXT;
ALTER TABLE products ADD COLUMN IF NOT EXISTS specs JSONB NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE products ADD COLUMN IF NOT EXISTS tags JSONB NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE products ADD COLUMN IF NOT EXISTS stock NUMERIC(10,3);
ALTER TABLE products ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE products ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE products ADD COLUMN IF NOT EXISTS round_id UUID REFERENCES rounds(id);
ALTER TABLE products ALTER COLUMN stock TYPE NUMERIC(10,3) USING stock::numeric;

COMMENT ON TABLE products IS '商品表';
COMMENT ON COLUMN products.specs IS '规格数组，如 [{"name":"500g","price":15},{"name":"1kg","price":28}]';
COMMENT ON COLUMN products.tags IS '商品标签数组，如 ["蛋糕","冷藏","山姆"]';
COMMENT ON COLUMN products.stock IS '库存数量，NULL 表示不限库存';
COMMENT ON COLUMN products.is_active IS '是否上架，false 为下架';

-- 2. 订单表
CREATE TABLE IF NOT EXISTS orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_name TEXT NOT NULL,
  items JSONB NOT NULL DEFAULT '[]'::jsonb,
  note TEXT DEFAULT '',
  total_amount NUMERIC(10,2) NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'cancelled')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE orders ADD COLUMN IF NOT EXISTS customer_name TEXT;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS items JSONB NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS note TEXT DEFAULT '';
ALTER TABLE orders ADD COLUMN IF NOT EXISTS total_amount NUMERIC(10,2) NOT NULL DEFAULT 0;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'active';
ALTER TABLE orders ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE orders ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

COMMENT ON TABLE orders IS '订单表';
COMMENT ON COLUMN orders.items IS '购买明细 [{product_id, product_name, spec_name, spec_price, quantity, unit_qty, purchase_qty, subtotal}]，quantity 为购买次数，purchase_qty 为按规格折算后的采购/扣库存份量';
COMMENT ON COLUMN orders.status IS 'active=有效, cancelled=已取消';

-- 3. 设置表
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

COMMENT ON TABLE settings IS '系统设置键值表';

-- 预置默认设置
INSERT INTO settings (key, value) VALUES
  ('admin_password', ''),
  ('round_fees', '{}'),
  ('site_title', '美好小区团购群')
ON CONFLICT (key) DO NOTHING;

-- 4. 团购轮次表
CREATE TABLE IF NOT EXISTS rounds (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  cutoff_time TIMESTAMPTZ,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE rounds ADD COLUMN IF NOT EXISTS name TEXT;
ALTER TABLE rounds ADD COLUMN IF NOT EXISTS cutoff_time TIMESTAMPTZ;
ALTER TABLE rounds ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE rounds ADD COLUMN IF NOT EXISTS leader_name TEXT;
ALTER TABLE rounds ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();

COMMENT ON TABLE rounds IS '团购轮次表，每次团购为一个轮次';
COMMENT ON COLUMN rounds.is_active IS '是否为活跃轮次，允许多轮次同时 active';

-- 为 orders 表增加轮次关联（如果列不存在）
DO $$ BEGIN
  ALTER TABLE orders ADD COLUMN round_id UUID REFERENCES rounds(id);
EXCEPTION WHEN duplicate_column THEN NULL;
END $$;

CREATE INDEX IF NOT EXISTS idx_orders_round ON orders (round_id);

-- ============================================================================
-- Row Level Security (RLS) 策略
-- ============================================================================

-- 启用 RLS
ALTER TABLE products ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE rounds ENABLE ROW LEVEL SECURITY;

-- --- 删除已有策略（确保可重复执行）---
DROP POLICY IF EXISTS "Anyone can read active products" ON products;
DROP POLICY IF EXISTS "Allow all read products" ON products;
DROP POLICY IF EXISTS "Allow read all products" ON products;
DROP POLICY IF EXISTS "Allow insert products" ON products;
DROP POLICY IF EXISTS "Allow update products" ON products;
DROP POLICY IF EXISTS "Allow delete products" ON products;
DROP POLICY IF EXISTS "Anyone can read orders" ON orders;
DROP POLICY IF EXISTS "Anyone can insert orders" ON orders;
DROP POLICY IF EXISTS "Anyone can update orders" ON orders;
DROP POLICY IF EXISTS "Anyone can read settings" ON settings;
DROP POLICY IF EXISTS "Allow update settings" ON settings;
DROP POLICY IF EXISTS "Allow insert settings" ON settings;

-- --- Products 策略 ---
CREATE POLICY "Anyone can read active products"
  ON products FOR SELECT
  USING (is_active = true);

-- orders 不创建公开读写策略；顾客查询和管理员查看都通过 RPC。

-- --- Rounds 策略 ---
DROP POLICY IF EXISTS "Anyone can read rounds" ON rounds;
DROP POLICY IF EXISTS "Allow insert rounds" ON rounds;
DROP POLICY IF EXISTS "Allow update rounds" ON rounds;
DROP POLICY IF EXISTS "Allow delete rounds" ON rounds;

CREATE POLICY "Anyone can read rounds"
  ON rounds FOR SELECT
  USING (true);

-- settings 不创建公开策略；通过 RPC 读取必要状态、修改管理员配置。

-- ============================================================================
-- 索引
-- ============================================================================
CREATE INDEX IF NOT EXISTS idx_products_active ON products (is_active);
CREATE INDEX IF NOT EXISTS idx_products_round ON products (round_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders (status);
CREATE INDEX IF NOT EXISTS idx_orders_customer ON orders (customer_name);
CREATE INDEX IF NOT EXISTS idx_orders_created ON orders (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_rounds_active ON rounds (is_active);

-- ============================================================================
-- 自动更新 updated_at 触发器
-- ============================================================================
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_orders_updated_at ON orders;
CREATE TRIGGER trg_orders_updated_at
  BEFORE UPDATE ON orders
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at();

-- ============================================================================
-- 原子库存操作函数（防止并发超卖）
-- ============================================================================
CREATE OR REPLACE FUNCTION deduct_stock(p_id UUID, qty NUMERIC)
RETURNS BOOLEAN AS $$
  WITH updated AS (
  UPDATE products
     SET stock = stock - qty
   WHERE id = p_id
     AND stock IS NOT NULL
     AND stock >= qty
     AND is_active = true
   RETURNING 1
  )
  SELECT EXISTS(SELECT 1 FROM updated);
$$ LANGUAGE sql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION restore_stock(p_id UUID, qty NUMERIC)
RETURNS VOID AS $$
  UPDATE products SET stock = stock + qty
   WHERE id = p_id AND stock IS NOT NULL;
$$ LANGUAGE sql SECURITY DEFINER;

-- ============================================================================
-- 管理员认证（服务端 session token）
-- ============================================================================
CREATE TABLE IF NOT EXISTS admin_sessions (
  token TEXT PRIMARY KEY,
  expires_at TIMESTAMPTZ NOT NULL
);

COMMENT ON TABLE admin_sessions IS '管理员会话表，token 为登录凭证';

-- RLS 启用但不创建任何策略 → 普通客户端无法直接读写
-- 只能通过下面的 SECURITY DEFINER 函数操作
ALTER TABLE admin_sessions ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_sessions_expires ON admin_sessions (expires_at);

-- 登录验证 + 生成 session token
CREATE OR REPLACE FUNCTION admin_login(pw_hash TEXT)
RETURNS TEXT AS $$
DECLARE
  stored_hash TEXT;
  new_token TEXT;
BEGIN
  SELECT value INTO stored_hash FROM settings WHERE key = 'admin_password';
  IF stored_hash IS NULL OR stored_hash = '' THEN
    -- 首次登录：设置密码
    UPDATE settings SET value = pw_hash WHERE key = 'admin_password';
  ELSIF stored_hash <> pw_hash THEN
    RETURN NULL;  -- 密码错误
  END IF;
  -- 生成 32 字节随机 token（hex 编码 64 字符）
  new_token := encode(gen_random_bytes(32), 'hex');
  INSERT INTO admin_sessions (token, expires_at)
  VALUES (new_token, now() + INTERVAL '24 hours');
  RETURN new_token;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 验证 session token 是否有效
CREATE OR REPLACE FUNCTION validate_session(p_token TEXT)
RETURNS BOOLEAN AS $$
  SELECT EXISTS(
    SELECT 1 FROM admin_sessions
    WHERE token = p_token AND expires_at > now()
  );
$$ LANGUAGE sql SECURITY DEFINER;

-- 清除 session（退出登录）
CREATE OR REPLACE FUNCTION clear_session(p_token TEXT)
RETURNS VOID AS $$
  DELETE FROM admin_sessions WHERE token = p_token;
$$ LANGUAGE sql SECURITY DEFINER;

-- 自动清理过期 session
CREATE OR REPLACE FUNCTION cleanup_sessions()
RETURNS VOID AS $$
  DELETE FROM admin_sessions WHERE expires_at < now();
$$ LANGUAGE sql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION require_admin(p_token TEXT)
RETURNS VOID AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM admin_sessions
    WHERE token = p_token AND expires_at > now()
  ) THEN
    RAISE EXCEPTION 'invalid admin session';
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION needs_admin_password()
RETURNS BOOLEAN AS $$
  SELECT NOT EXISTS (
    SELECT 1 FROM settings
    WHERE key = 'admin_password' AND value <> ''
  );
$$ LANGUAGE sql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION get_site_title()
RETURNS TEXT AS $$
  SELECT COALESCE((SELECT value FROM settings WHERE key = 'site_title'), '美好小区团购群');
$$ LANGUAGE sql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_get_products(p_token TEXT, p_round_id UUID DEFAULT NULL)
RETURNS SETOF products AS $$
BEGIN
  PERFORM require_admin(p_token);
  RETURN QUERY SELECT * FROM products
    WHERE (p_round_id IS NULL OR round_id = p_round_id)
    ORDER BY created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_get_product(p_token TEXT, p_id UUID)
RETURNS products AS $$
DECLARE
  row products;
BEGIN
  PERFORM require_admin(p_token);
  SELECT * INTO row FROM products WHERE id = p_id;
  RETURN row;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_get_orders(p_token TEXT, p_round_id UUID)
RETURNS SETOF orders AS $$
BEGIN
  PERFORM require_admin(p_token);
  RETURN QUERY
    SELECT * FROM orders
     WHERE status = 'active'
       AND (p_round_id IS NULL OR round_id = p_round_id)
     ORDER BY created_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION lookup_orders(p_customer_name TEXT, p_round_id UUID)
RETURNS SETOF orders AS $$
BEGIN
  RETURN QUERY
    SELECT * FROM orders
     WHERE customer_name = p_customer_name
       AND (p_round_id IS NULL OR round_id = p_round_id)
     ORDER BY created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 公开：返回某轮次各商品的汇总数量（用于前端显示"已拼满/未拼满"）
CREATE OR REPLACE FUNCTION get_round_order_stats(p_round_id UUID)
RETURNS JSONB AS $$
SELECT COALESCE(jsonb_agg(s), '[]'::jsonb) FROM (
  SELECT it->>'product_id' as product_id,
    SUM(COALESCE((it->>'purchase_qty')::numeric, (it->>'quantity')::numeric, 0)) as qty,
    COUNT(*)::int as order_count
  FROM orders o, jsonb_array_elements(COALESCE(o.items, '[]'::jsonb)) it
  WHERE o.round_id = p_round_id AND o.status = 'active'
    AND (it->>'deleted') IS DISTINCT FROM 'true'
    AND (it->>'product_id') IS NOT NULL
  GROUP BY it->>'product_id'
) s;
$$ LANGUAGE sql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_save_product(
  p_token TEXT,
  p_id UUID,
  p_name TEXT,
  p_image TEXT,
  p_specs JSONB,
  p_tags JSONB,
  p_stock NUMERIC,
  p_is_active BOOLEAN,
  p_round_id UUID DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
  new_id UUID;
BEGIN
  PERFORM require_admin(p_token);
  -- 服务端校验
  IF p_stock IS NOT NULL AND p_stock < 0 THEN
    RAISE EXCEPTION 'stock cannot be negative';
  END IF;
  IF p_specs IS NULL OR jsonb_array_length(p_specs) = 0 THEN
    RAISE EXCEPTION 'specs cannot be empty';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_specs) AS s WHERE (s->>'price')::numeric <= 0 OR (s->>'name') IS NULL OR trim(s->>'name') = '') THEN
    RAISE EXCEPTION 'each spec must have a name and a positive price';
  END IF;
  IF p_id IS NULL THEN
    INSERT INTO products (name, image, specs, tags, stock, is_active, round_id)
    VALUES (p_name, p_image, COALESCE(p_specs, '[]'::jsonb), COALESCE(p_tags, '[]'::jsonb), p_stock, COALESCE(p_is_active, true), p_round_id)
    RETURNING id INTO new_id;
  ELSE
    UPDATE products
       SET name = p_name,
           image = p_image,
           specs = COALESCE(p_specs, '[]'::jsonb),
           tags = COALESCE(p_tags, '[]'::jsonb),
           stock = p_stock,
           is_active = COALESCE(p_is_active, true),
           round_id = COALESCE(p_round_id, round_id)
     WHERE id = p_id
    RETURNING id INTO new_id;
  END IF;
  RETURN new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_toggle_product(p_token TEXT, p_id UUID, p_is_active BOOLEAN)
RETURNS VOID AS $$
BEGIN
  PERFORM require_admin(p_token);
  UPDATE products SET is_active = p_is_active WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_delete_product(p_token TEXT, p_id UUID)
RETURNS VOID AS $$
DECLARE
  active_round_id UUID;
BEGIN
  PERFORM require_admin(p_token);
  -- 标记所有活动订单中该商品的记录为已删除（跨所有轮次）
  WITH rebuilt AS (
    SELECT
      o.id,
      jsonb_agg(
        CASE
          WHEN item->>'product_id' = p_id::text THEN
            item
            || jsonb_build_object(
              'product_name', '商品已删除',
              'spec_price', 0,
              'subtotal', 0,
              'purchase_qty', 0,
              'deleted', true
            )
          ELSE item
        END
      ) AS new_items,
      COALESCE(
        SUM(
          CASE
            WHEN item->>'product_id' <> p_id::text
            THEN COALESCE((item->>'subtotal')::numeric, 0)
            ELSE 0
          END
        ),
        0
      ) AS new_total
    FROM orders o
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(o.items, '[]'::jsonb)) AS item
    WHERE o.status = 'active'
      AND EXISTS (
        SELECT 1
          FROM jsonb_array_elements(COALESCE(o.items, '[]'::jsonb)) AS existing_item
         WHERE existing_item->>'product_id' = p_id::text
      )
    GROUP BY o.id
  )
  UPDATE orders o
     SET items = rebuilt.new_items,
         total_amount = ROUND(rebuilt.new_total, 2),
         updated_at = now()
    FROM rebuilt
   WHERE o.id = rebuilt.id;

  DELETE FROM products WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION mark_missing_order_products_deleted()
RETURNS VOID AS $$
BEGIN
  WITH rebuilt AS (
    SELECT
      o.id,
      jsonb_agg(
        CASE
          WHEN COALESCE(item.value->>'product_id', item.value->>'productId') IS NOT NULL
            AND item.value->>'deleted' IS DISTINCT FROM 'true'
            AND NOT EXISTS (
              SELECT 1 FROM products p WHERE p.id::text = COALESCE(item.value->>'product_id', item.value->>'productId')
            )
          THEN
            item.value
            || jsonb_build_object(
              'product_name', '商品已删除',
              'spec_price', 0,
              'subtotal', 0,
              'purchase_qty', 0,
              'deleted', true
            )
          ELSE item.value
        END
        ORDER BY item.ordinality
      ) AS new_items,
      COALESCE(
        SUM(
          CASE
            WHEN item.value->>'deleted' = 'true'
              OR (
                COALESCE(item.value->>'product_id', item.value->>'productId') IS NOT NULL
                AND NOT EXISTS (
                  SELECT 1 FROM products p WHERE p.id::text = COALESCE(item.value->>'product_id', item.value->>'productId')
                )
              )
            THEN 0
            ELSE COALESCE((item.value->>'subtotal')::numeric, 0)
          END
        ),
        0
      ) AS new_total,
      BOOL_OR(
        COALESCE(item.value->>'product_id', item.value->>'productId') IS NOT NULL
        AND item.value->>'deleted' IS DISTINCT FROM 'true'
        AND NOT EXISTS (
          SELECT 1 FROM products p WHERE p.id::text = COALESCE(item.value->>'product_id', item.value->>'productId')
        )
      ) AS has_missing_product,
      BOOL_OR(item.value->>'deleted' = 'true') AS has_deleted_product
    FROM orders o
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(o.items, '[]'::jsonb)) WITH ORDINALITY AS item(value, ordinality)
    WHERE o.status = 'active'
    GROUP BY o.id
  )
  UPDATE orders o
     SET items = rebuilt.new_items,
         total_amount = ROUND(rebuilt.new_total, 2),
         updated_at = now()
    FROM rebuilt
   WHERE o.id = rebuilt.id
     AND (rebuilt.has_missing_product OR rebuilt.has_deleted_product);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

SELECT mark_missing_order_products_deleted();

CREATE OR REPLACE FUNCTION admin_set_password(p_token TEXT, p_pw_hash TEXT)
RETURNS VOID AS $$
BEGIN
  PERFORM require_admin(p_token);
  UPDATE settings SET value = p_pw_hash WHERE key = 'admin_password';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_set_site_title(p_token TEXT, p_title TEXT)
RETURNS VOID AS $$
BEGIN
  PERFORM require_admin(p_token);
  INSERT INTO settings (key, value)
  VALUES ('site_title', NULLIF(TRIM(p_title), ''))
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_get_round_fee_map(p_token TEXT)
RETURNS JSONB AS $$
DECLARE
  raw_value TEXT;
BEGIN
  PERFORM require_admin(p_token);
  SELECT value INTO raw_value FROM settings WHERE key = 'round_fees';
  RETURN COALESCE(raw_value, '{}')::jsonb;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_save_round_fees(p_token TEXT, p_round_id UUID, p_fees JSONB)
RETURNS VOID AS $$
DECLARE
  fee_map JSONB;
BEGIN
  PERFORM require_admin(p_token);
  SELECT COALESCE(value, '{}')::jsonb INTO fee_map FROM settings WHERE key = 'round_fees';
  UPDATE settings
     SET value = jsonb_set(COALESCE(fee_map, '{}'::jsonb), ARRAY[p_round_id::text], COALESCE(p_fees, '{}'::jsonb), true)::text
   WHERE key = 'round_fees';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_create_round(p_token TEXT, p_name TEXT, p_cutoff_time TIMESTAMPTZ, p_leader_name TEXT DEFAULT NULL)
RETURNS UUID AS $$
DECLARE
  new_id UUID;
BEGIN
  PERFORM require_admin(p_token);
  INSERT INTO rounds (name, cutoff_time, is_active, leader_name)
  VALUES (p_name, p_cutoff_time, false, NULLIF(p_leader_name, ''))
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_update_round(p_token TEXT, p_id UUID, p_name TEXT, p_cutoff_time TIMESTAMPTZ, p_leader_name TEXT DEFAULT NULL)
RETURNS VOID AS $$
BEGIN
  PERFORM require_admin(p_token);
  UPDATE rounds SET name = p_name, cutoff_time = p_cutoff_time, leader_name = NULLIF(p_leader_name, '') WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_activate_round(p_token TEXT, p_id UUID)
RETURNS VOID AS $$
BEGIN
  PERFORM require_admin(p_token);
  UPDATE rounds SET is_active = true WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 管理员砍单（不受截止时间限制，支持备注砍单原因）
CREATE OR REPLACE FUNCTION admin_cancel_order(p_token TEXT, p_order_id UUID, p_note TEXT DEFAULT NULL)
RETURNS BOOLEAN AS $$
DECLARE
  order_row orders;
  item JSONB;
  qty NUMERIC;
BEGIN
  PERFORM require_admin(p_token);
  SELECT * INTO order_row FROM orders WHERE id = p_order_id AND status = 'active' FOR UPDATE;
  IF order_row.id IS NULL THEN RETURN false; END IF;
  UPDATE orders SET
    status = 'cancelled',
    note = CASE
      WHEN p_note IS NOT NULL AND p_note <> '' THEN
        CASE WHEN COALESCE(note, '') <> '' THEN note || ' | ' || p_note ELSE p_note END
      ELSE note
    END
  WHERE id = p_order_id;
  FOR item IN SELECT * FROM jsonb_array_elements(COALESCE(order_row.items, '[]'::jsonb))
  LOOP
    qty := COALESCE((item->>'purchase_qty')::numeric, (item->>'quantity')::numeric, 0);
    IF qty > 0 THEN
      UPDATE products SET stock = stock + qty
       WHERE id = (item->>'product_id')::uuid AND stock IS NOT NULL;
    END IF;
  END LOOP;
  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_stop_round(p_token TEXT, p_id UUID)
RETURNS VOID AS $$
BEGIN
  PERFORM require_admin(p_token);
  UPDATE rounds SET is_active = false, cutoff_time = now() WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_delete_round(p_token TEXT, p_id UUID)
RETURNS VOID AS $$
BEGIN
  PERFORM require_admin(p_token);
  IF EXISTS (SELECT 1 FROM rounds WHERE id = p_id AND is_active = true AND (cutoff_time IS NULL OR cutoff_time > now())) THEN
    RAISE EXCEPTION 'cannot delete active round';
  END IF;
  DELETE FROM orders WHERE round_id = p_id;
  DELETE FROM rounds WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION create_order(
  p_customer_name TEXT,
  p_items JSONB,
  p_note TEXT,
  -- 兼容旧前端参数；实际订单金额在数据库端按商品规格重新计算。
  p_total_amount NUMERIC,
  p_round_id UUID
)
RETURNS UUID AS $$
DECLARE
  item JSONB;
  checked_items JSONB := '[]'::jsonb;
  product_row products;
  spec_row JSONB;
  product_id UUID;
  qty NUMERIC;
  count_qty NUMERIC;
  unit_qty NUMERIC;
  price NUMERIC;
  line_total NUMERIC;
  server_total NUMERIC := 0;
  new_id UUID;
  round_row rounds;
BEGIN
  SELECT * INTO round_row FROM rounds WHERE id = p_round_id AND is_active = true;
  IF round_row.id IS NULL THEN
    RAISE EXCEPTION 'round is not active';
  END IF;
  IF round_row.cutoff_time IS NOT NULL AND round_row.cutoff_time <= now() THEN
    RAISE EXCEPTION 'round is closed';
  END IF;

  -- 幂等保护：同一顾客 5 秒内在同一轮次重复提交视为重放
  IF EXISTS (
    SELECT 1 FROM orders
    WHERE customer_name = p_customer_name
      AND round_id = p_round_id
      AND status = 'active'
      AND note IS NOT DISTINCT FROM p_note
      AND created_at > now() - INTERVAL '5 seconds'
  ) THEN
    RAISE EXCEPTION 'duplicate order within 5s, please wait';
  END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb))
  LOOP
    product_id := (item->>'product_id')::uuid;
    SELECT * INTO product_row FROM products WHERE id = product_id AND round_id = p_round_id AND is_active = true FOR UPDATE;
    IF product_row.id IS NULL THEN
      RAISE EXCEPTION 'product is not in this round or not active';
    END IF;
    SELECT spec.value INTO spec_row
      FROM jsonb_array_elements(product_row.specs) AS spec(value)
     WHERE spec.value->>'name' = item->>'spec_name'
     LIMIT 1;
    IF spec_row IS NULL THEN
      RAISE EXCEPTION 'invalid product spec';
    END IF;

    count_qty := COALESCE((item->>'quantity')::numeric, 0);
    IF count_qty <= 0 THEN
      RAISE EXCEPTION 'invalid quantity';
    END IF;
    unit_qty := COALESCE((item->>'unit_qty')::numeric, 1);
    qty := COALESCE((item->>'purchase_qty')::numeric, unit_qty * count_qty);
    price := (spec_row->>'price')::numeric;
    line_total := ROUND(price * count_qty, 2);

    IF qty > 0 THEN
      UPDATE products
         SET stock = stock - qty
       WHERE id = product_id
         AND is_active = true
         AND stock IS NOT NULL
         AND stock >= qty;
      IF NOT FOUND AND EXISTS (SELECT 1 FROM products WHERE id = product_id AND stock IS NOT NULL) THEN
        RAISE EXCEPTION 'insufficient stock';
      END IF;
    END IF;

    checked_items := checked_items || jsonb_build_array(jsonb_build_object(
      'product_id', product_row.id,
      'product_name', product_row.name,
      'spec_name', spec_row->>'name',
      'spec_price', price,
      'quantity', count_qty,
      'unit_qty', unit_qty,
      'purchase_qty', qty,
      'subtotal', line_total
    ));
    server_total := server_total + line_total;
  END LOOP;

  INSERT INTO orders (customer_name, items, note, total_amount, status, round_id)
  VALUES (p_customer_name, checked_items, COALESCE(p_note, ''), ROUND(server_total, 2), 'active', p_round_id)
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION cancel_order(p_order_id UUID, p_customer_name TEXT)
RETURNS BOOLEAN AS $$
DECLARE
  order_row orders;
  round_row rounds;
  item JSONB;
  qty NUMERIC;
BEGIN
  SELECT * INTO order_row
    FROM orders
   WHERE id = p_order_id
     AND customer_name = p_customer_name
     AND status = 'active'
   FOR UPDATE;
  IF order_row.id IS NULL THEN
    RETURN false;
  END IF;

  IF order_row.round_id IS NOT NULL THEN
    SELECT * INTO round_row FROM rounds WHERE id = order_row.round_id;
    IF round_row.cutoff_time IS NOT NULL AND round_row.cutoff_time <= now() THEN
      RAISE EXCEPTION 'round is closed';
    END IF;
  END IF;

  UPDATE orders SET status = 'cancelled' WHERE id = p_order_id;

  FOR item IN SELECT * FROM jsonb_array_elements(COALESCE(order_row.items, '[]'::jsonb))
  LOOP
    qty := COALESCE((item->>'purchase_qty')::numeric, (item->>'quantity')::numeric, 0);
    IF qty > 0 THEN
      UPDATE products SET stock = stock + qty
       WHERE id = (item->>'product_id')::uuid AND stock IS NOT NULL;
    END IF;
  END LOOP;
  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION deduct_stock(UUID, NUMERIC) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION restore_stock(UUID, NUMERIC) FROM PUBLIC, anon, authenticated;

-- ============================================================================
-- Storage Bucket: 商品图片存储
-- ============================================================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('product-images', 'product-images', true, 5242880, ARRAY['image/jpeg','image/png','image/gif','image/webp'])
ON CONFLICT (id) DO UPDATE SET public = true;

DROP POLICY IF EXISTS "Anyone can view product images" ON storage.objects;
CREATE POLICY "Anyone can view product images"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'product-images');

DROP POLICY IF EXISTS "Anyone can upload product images" ON storage.objects;
CREATE POLICY "Anyone can upload product images"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'product-images'
    AND (storage.foldername(name))[1] = 'products'
  );
