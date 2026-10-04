-- =====================================================================
-- Mika Shop: TEST DATA for the TEST project only. NEVER run on LIVE.
-- Everything is clearly marked so it's easy to find and remove:
--   categories: name starts with "[TEST]"
--   products:   SKU starts with "TEST-", name starts with "[TEST]"
-- Removal script (run only when Charbel decides): remove_test_data.sql
-- Run:  supabase db query --linked -f supabase/tests/test_data.sql
-- Safe to run twice (skips what already exists).
-- =====================================================================

insert into public.categories (name_en, name_ar, sort)
select v.* from (values
  ('[TEST] Kitchen',  '[تجربة] المطبخ',   10),
  ('[TEST] Clothes',  '[تجربة] ملابس',    20),
  ('[TEST] Gifts',    '[تجربة] هدايا',    30)
) v(name_en, name_ar, sort)
where not exists (select 1 from public.categories c where c.name_en = v.name_en);

insert into public.categories (name_en, name_ar, parent_id, sort)
select '[TEST] T-shirts', '[تجربة] تيشيرتات', id, 1 from public.categories
where name_en = '[TEST] Clothes'
  and not exists (select 1 from public.categories where name_en = '[TEST] T-shirts');

insert into public.products (sku, name_en, name_ar, desc_en, desc_ar, category_id, price, compare_price,
                             stock, has_variants, featured, active, ar_needs_review)
select v.sku, v.name_en, v.name_ar, v.desc_en, v.desc_ar,
       (select id from public.categories where name_en = v.cat), v.price, v.compare_price,
       v.stock, v.has_variants, v.featured, v.active, v.ar_review
from (values
  ('TEST-MUG-01',   '[TEST] Ceramic mug',        '[تجربة] كوب سيراميك',      'White ceramic mug, 350 ml.',      'كوب سيراميك أبيض، 350 مل.',     '[TEST] Kitchen', 8.00,  null::numeric, 25, false, true,  true,  false),
  ('TEST-MUG-02',   '[TEST] Travel mug',         '[تجربة] كوب سفر',          'Keeps drinks hot for 6 hours.',   'يحافظ على المشروبات ساخنة 6 ساعات.', '[TEST] Kitchen', 15.00, 18.00, 3,  false, true,  true,  false),
  ('TEST-PAN-01',   '[TEST] Frying pan 28cm',    '[تجربة] مقلاة 28 سم',      'Non-stick frying pan.',           'مقلاة غير لاصقة.',              '[TEST] Kitchen', 22.50, null, 0,  false, false, true,  false),
  ('TEST-KNIFE-01', '[TEST] Chef knife',         '[تجربة] سكين طبخ',         'Stainless steel, 20 cm blade.',   'ستانلس ستيل، شفرة 20 سم.',      '[TEST] Kitchen', 12.00, null, 10, false, false, true,  true),
  ('TEST-BOARD-01', '[TEST] Cutting board',      '[تجربة] لوح تقطيع',        'Bamboo cutting board.',           'لوح تقطيع من الخيزران.',        '[TEST] Kitchen', 9.00,  null, 7,  false, false, false, false),
  ('TEST-TSHIRT-01','[TEST] Cotton T-shirt',     '[تجربة] تيشيرت قطن',       '100% cotton. Choose size and colour.', 'قطن 100%. اختر المقاس واللون.', '[TEST] T-shirts', 14.00, null, 0, true,  true,  true,  false),
  ('TEST-HOODIE-01','[TEST] Hoodie',             '[تجربة] هودي',             'Warm hoodie with front pocket.',  'هودي دافئ بجيب أمامي.',         '[TEST] Clothes', 30.00, 35.00, 0, true,  true,  true,  false),
  ('TEST-SCARF-01', '[TEST] Wool scarf',         '[تجربة] وشاح صوف',         'Soft wool scarf.',                'وشاح صوف ناعم.',                '[TEST] Clothes', 11.00, null, 1,  false, false, true,  false),
  ('TEST-CANDLE-01','[TEST] Scented candle',     '[تجربة] شمعة معطّرة',      'Vanilla scent, 40 hours.',        'برائحة الفانيلا، 40 ساعة.',     '[TEST] Gifts',   6.50,  null, 40, false, true,  true,  false),
  ('TEST-FRAME-01', '[TEST] Photo frame',        '[تجربة] إطار صور',         '13 x 18 cm wooden frame.',        'إطار خشبي 13 × 18 سم.',         '[TEST] Gifts',   7.00,  null, 12, false, false, true,  true),
  ('TEST-BOX-01',   '[TEST] Gift box',           '[تجربة] علبة هدايا',       'Decorated gift box.',             'علبة هدايا مزيّنة.',            '[TEST] Gifts',   4.00,  null, 100,false, false, true,  false),
  ('TEST-LAST-01',  '[TEST] Last one in stock',  '[تجربة] آخر قطعة',         'Only one left: for the two-browser test.', 'قطعة واحدة فقط: لاختبار المتصفحين.', '[TEST] Gifts', 5.00, null, 1, false, false, true, false)
) v(sku, name_en, name_ar, desc_en, desc_ar, cat, price, compare_price, stock, has_variants, featured, active, ar_review)
on conflict (sku) do nothing;

insert into public.variants (sku, label_en, label_ar, price, stock, sort)
select v.* from (values
  ('TEST-TSHIRT-01', 'Size S / White', 'مقاس S / أبيض', null::numeric, 5, 1),
  ('TEST-TSHIRT-01', 'Size M / White', 'مقاس M / أبيض', null, 0, 2),
  ('TEST-TSHIRT-01', 'Size L / Black', 'مقاس L / أسود', 15.00, 3, 3),
  ('TEST-HOODIE-01', 'Size M',         'مقاس M',        null, 2, 1),
  ('TEST-HOODIE-01', 'Size XL',        'مقاس XL',       32.00, 0, 2)
) v(sku, label_en, label_ar, price, stock, sort)
where not exists (select 1 from public.variants x where x.sku = v.sku and x.label_en = v.label_en);

select (select count(*) from public.products where sku like 'TEST-%') as test_products,
       (select count(*) from public.variants where sku like 'TEST-%') as test_variants,
       (select count(*) from public.categories where name_en like '[TEST]%') as test_categories;
