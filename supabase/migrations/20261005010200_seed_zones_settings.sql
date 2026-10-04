-- =====================================================================
-- Mika Shop: migration 3, starting data.
--
-- delivery_zones: Lebanon's 9 governorates / 26 districts (official
--   administrative list, incl. Keserwan-Jbeil governorate created 2017).
--   *** TO BE CONFIRMED BY CHARBEL ***
--   fee, eta_days and default_carrier are left EMPTY on purpose
--   (business decision, not set yet). Orders to a district with no fee
--   are refused until the fee is set.
--
-- settings: every key from CLAUDE.md section 5 with an EMPTY value.
--   Charbel / Mika fill them in. is_public = readable by the shop.
-- =====================================================================

insert into public.delivery_zones (governorate, governorate_ar, district, district_ar, sort) values
  ('Beirut',          'بيروت',          'Beirut',          'بيروت',          100),
  ('Mount Lebanon',   'جبل لبنان',      'Baabda',          'بعبدا',          200),
  ('Mount Lebanon',   'جبل لبنان',      'Matn',            'المتن',          201),
  ('Mount Lebanon',   'جبل لبنان',      'Aley',            'عاليه',          202),
  ('Mount Lebanon',   'جبل لبنان',      'Chouf',           'الشوف',          203),
  ('Keserwan-Jbeil',  'كسروان - جبيل',  'Keserwan',        'كسروان',         300),
  ('Keserwan-Jbeil',  'كسروان - جبيل',  'Jbeil',           'جبيل',           301),
  ('North',           'الشمال',         'Tripoli',         'طرابلس',         400),
  ('North',           'الشمال',         'Zgharta',         'زغرتا',          401),
  ('North',           'الشمال',         'Koura',           'الكورة',         402),
  ('North',           'الشمال',         'Batroun',         'البترون',        403),
  ('North',           'الشمال',         'Bsharri',         'بشري',           404),
  ('North',           'الشمال',         'Minieh-Danniyeh', 'المنية - الضنية', 405),
  ('Akkar',           'عكار',           'Akkar',           'عكار',           500),
  ('Beqaa',           'البقاع',         'Zahle',           'زحلة',           600),
  ('Beqaa',           'البقاع',         'West Beqaa',      'البقاع الغربي',  601),
  ('Beqaa',           'البقاع',         'Rashaya',         'راشيا',          602),
  ('Baalbek-Hermel',  'بعلبك - الهرمل', 'Baalbek',         'بعلبك',          700),
  ('Baalbek-Hermel',  'بعلبك - الهرمل', 'Hermel',          'الهرمل',         701),
  ('South',           'الجنوب',         'Sidon',           'صيدا',           800),
  ('South',           'الجنوب',         'Tyre',            'صور',            801),
  ('South',           'الجنوب',         'Jezzine',         'جزين',           802),
  ('Nabatieh',        'النبطية',        'Nabatieh',        'النبطية',        900),
  ('Nabatieh',        'النبطية',        'Marjeyoun',       'مرجعيون',        901),
  ('Nabatieh',        'النبطية',        'Hasbaya',         'حاصبيا',         902),
  ('Nabatieh',        'النبطية',        'Bint Jbeil',      'بنت جبيل',       903)
on conflict (governorate, district) do nothing;

insert into public.settings (key, value, is_public) values
  ('shop_name_en',        '', true),
  ('shop_name_ar',        '', true),
  ('currency',            '', true),
  ('whatsapp_number',     '', true),
  ('whish_number',        '', true),
  ('omt_details',         '', true),
  ('unpaid_cancel_hours', '', true),
  ('low_stock_threshold', '', false),
  ('order_prefix',        '', false),
  ('return_policy_en',    '', true),
  ('return_policy_ar',    '', true)
on conflict (key) do nothing;
