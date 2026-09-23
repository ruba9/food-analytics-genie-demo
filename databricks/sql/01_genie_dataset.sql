-- Sample sales dataset for the Databricks Genie space.
--
-- Genie reads table and column COMMENT metadata as context when it translates a
-- question into SQL, so the comments here are functional, not decoration. Vague or
-- missing comments are the most common reason Genie answers a question incorrectly.

CREATE CATALOG IF NOT EXISTS food_analytics;
CREATE SCHEMA IF NOT EXISTS food_analytics.sales;

CREATE OR REPLACE TABLE food_analytics.sales.dim_product (
  product_id            INT NOT NULL COMMENT 'Surrogate key for the product.',
  product_name          STRING  COMMENT 'Commercial product name.',
  category              STRING  COMMENT 'Top-level product category: Bakery, Margarine, or Oils & Fats.',
  sub_category          STRING  COMMENT 'Finer product grouping within the category, e.g. Croissants, Puff Pastry, Frying Oil.',
  brand                 STRING  COMMENT 'Brand the product is sold under.',
  list_price_eur_per_kg DECIMAL(10,2) COMMENT 'Standard list price in EUR per kilogram before customer discounts.'
) COMMENT 'Product master data. One row per sellable finished product.';

INSERT INTO food_analytics.sales.dim_product VALUES
  (1,  'Butter Croissant 70g',        'Bakery',        'Croissants',    'Banquet d''Or',  6.80),
  (2,  'Pain au Chocolat 75g',        'Bakery',        'Croissants',    'Banquet d''Or',  7.10),
  (3,  'Puff Pastry Sheet 2kg',       'Bakery',        'Puff Pastry',   'Banquet d''Or',  4.25),
  (4,  'Danish Swirl Raisin 90g',     'Bakery',        'Danish',        'Banquet d''Or',  6.40),
  (5,  'Multigrain Baguette 250g',    'Bakery',        'Bread',         'Vamix',          3.15),
  (6,  'Professional Margarine 10kg', 'Margarine',     'Bakery Fats',   'Contoso Foods',  2.40),
  (7,  'Puff Pastry Margarine 10kg',  'Margarine',     'Bakery Fats',   'Contoso Foods',  2.85),
  (8,  'Cake Margarine 10kg',         'Margarine',     'Bakery Fats',   'Contoso Foods',  2.55),
  (9,  'Liquid Frying Oil 10L',       'Oils & Fats',   'Frying Oil',    'Fritessa',       1.95),
  (10, 'High-Oleic Sunflower Oil 5L', 'Oils & Fats',   'Frying Oil',    'Fritessa',       2.60),
  (11, 'Mayonnaise Base 5L',          'Oils & Fats',   'Dressings',     'Contoso Foods',  3.30),
  (12, 'Vegan Spread 2kg',            'Margarine',     'Plant-Based',   'Alpro Pro',      3.90);

CREATE OR REPLACE TABLE food_analytics.sales.dim_customer (
  customer_id   INT NOT NULL COMMENT 'Surrogate key for the customer.',
  customer_name STRING COMMENT 'Trading name of the customer account.',
  channel       STRING COMMENT 'Route to market: Retail, Foodservice, or Industry.',
  country       STRING COMMENT 'Country where the customer is based.',
  region        STRING COMMENT 'Sales region grouping: Benelux, DACH, France, UK & Ireland, or Southern Europe.'
) COMMENT 'Customer master data. One row per customer account.';

INSERT INTO food_analytics.sales.dim_customer VALUES
  (1,  'Delhaize Group',        'Retail',      'Belgium',     'Benelux'),
  (2,  'Colruyt',               'Retail',      'Belgium',     'Benelux'),
  (3,  'Albert Heijn',          'Retail',      'Netherlands', 'Benelux'),
  (4,  'Jumbo Supermarkten',    'Retail',      'Netherlands', 'Benelux'),
  (5,  'Metro Cash & Carry',    'Foodservice', 'Germany',     'DACH'),
  (6,  'Edeka',                 'Retail',      'Germany',     'DACH'),
  (7,  'Transgourmet',          'Foodservice', 'Switzerland', 'DACH'),
  (8,  'Carrefour France',      'Retail',      'France',      'France'),
  (9,  'Brake France',          'Foodservice', 'France',      'France'),
  (10, 'Sysco UK',              'Foodservice', 'United Kingdom', 'UK & Ireland'),
  (11, 'Tesco',                 'Retail',      'United Kingdom', 'UK & Ireland'),
  (12, 'Musgrave',              'Foodservice', 'Ireland',     'UK & Ireland'),
  (13, 'Mercadona',             'Retail',      'Spain',       'Southern Europe'),
  (14, 'Conad',                 'Retail',      'Italy',       'Southern Europe'),
  (15, 'Barilla Industrial',    'Industry',    'Italy',       'Southern Europe');

CREATE OR REPLACE TABLE food_analytics.sales.dim_plant (
  plant_id   INT NOT NULL COMMENT 'Surrogate key for the production plant.',
  plant_name STRING COMMENT 'Name of the manufacturing site.',
  country    STRING COMMENT 'Country where the plant is located.'
) COMMENT 'Manufacturing plants that produce the goods sold.';

INSERT INTO food_analytics.sales.dim_plant VALUES
  (1, 'Ghent Bakery',        'Belgium'),
  (2, 'Izegem Refinery',     'Belgium'),
  (3, 'Lille Bakery',        'France'),
  (4, 'Rotterdam Oils',      'Netherlands');

-- Generated rather than hand-written so the table has enough volume for Genie to
-- produce meaningful aggregates. Revenue is derived from the product list price so
-- margin questions stay internally consistent with dim_product.
CREATE OR REPLACE TABLE food_analytics.sales.fact_sales
COMMENT 'Sales transactions at product, customer, and plant grain. One row per order line. Covers calendar years 2024 and 2025.'
AS
WITH generated AS (
  SELECT explode(sequence(1, 20000)) AS sale_id
),
base AS (
  SELECT
    sale_id,
    date_add(DATE'2024-01-01', CAST(rand() * 730 AS INT)) AS sale_date,
    CAST(rand() * 12 AS INT) + 1  AS product_id,
    CAST(rand() * 15 AS INT) + 1  AS customer_id,
    CAST(rand() * 4  AS INT) + 1  AS plant_id,
    ROUND(50 + rand() * 1950, 1)  AS volume_kg
  FROM generated
)
SELECT
  b.sale_id,
  b.sale_date,
  b.product_id,
  b.customer_id,
  b.plant_id,
  b.volume_kg,
  ROUND(b.volume_kg * p.list_price_eur_per_kg * (0.85 + rand() * 0.30), 2) AS revenue_eur,
  ROUND(b.volume_kg * p.list_price_eur_per_kg * 0.72, 2)                   AS cost_eur
FROM base b
JOIN food_analytics.sales.dim_product p ON p.product_id = b.product_id;

ALTER TABLE food_analytics.sales.fact_sales ALTER COLUMN sale_id       COMMENT 'Unique identifier for the order line.';
ALTER TABLE food_analytics.sales.fact_sales ALTER COLUMN sale_date     COMMENT 'Date the order line was invoiced.';
ALTER TABLE food_analytics.sales.fact_sales ALTER COLUMN product_id    COMMENT 'Foreign key to dim_product.';
ALTER TABLE food_analytics.sales.fact_sales ALTER COLUMN customer_id   COMMENT 'Foreign key to dim_customer.';
ALTER TABLE food_analytics.sales.fact_sales ALTER COLUMN plant_id      COMMENT 'Foreign key to dim_plant.';
ALTER TABLE food_analytics.sales.fact_sales ALTER COLUMN volume_kg     COMMENT 'Quantity sold in kilograms.';
ALTER TABLE food_analytics.sales.fact_sales ALTER COLUMN revenue_eur   COMMENT 'Net invoiced revenue in EUR after customer discount.';
ALTER TABLE food_analytics.sales.fact_sales ALTER COLUMN cost_eur      COMMENT 'Cost of goods sold in EUR. Gross margin is revenue_eur minus cost_eur.';

-- Genie resolves joins far more reliably when the relationships are declared.
ALTER TABLE food_analytics.sales.dim_product  ADD CONSTRAINT pk_dim_product  PRIMARY KEY (product_id);
ALTER TABLE food_analytics.sales.dim_customer ADD CONSTRAINT pk_dim_customer PRIMARY KEY (customer_id);
ALTER TABLE food_analytics.sales.dim_plant    ADD CONSTRAINT pk_dim_plant    PRIMARY KEY (plant_id);

ALTER TABLE food_analytics.sales.fact_sales ADD CONSTRAINT fk_sales_product
  FOREIGN KEY (product_id)  REFERENCES food_analytics.sales.dim_product(product_id);
ALTER TABLE food_analytics.sales.fact_sales ADD CONSTRAINT fk_sales_customer
  FOREIGN KEY (customer_id) REFERENCES food_analytics.sales.dim_customer(customer_id);
ALTER TABLE food_analytics.sales.fact_sales ADD CONSTRAINT fk_sales_plant
  FOREIGN KEY (plant_id)    REFERENCES food_analytics.sales.dim_plant(plant_id);

-- Power BI and Genie both consume this view. Its grain and formulas are the shared
-- semantic contract, preventing either consumer from defining business totals alone.
CREATE OR REPLACE VIEW food_analytics.sales.sales_analytics
COMMENT 'Canonical daily sales metrics for Power BI and Genie. Aggregate only the additive measure columns; gross margin is revenue minus cost.'
AS
SELECT
  f.sale_date,
  YEAR(f.sale_date) AS calendar_year,
  QUARTER(f.sale_date) AS calendar_quarter,
  CONCAT(YEAR(f.sale_date), '-Q', QUARTER(f.sale_date)) AS year_quarter,
  DATE_FORMAT(f.sale_date, 'yyyy-MM') AS year_month,
  p.category,
  p.sub_category,
  p.brand,
  c.channel,
  c.country,
  c.region,
  pl.plant_name,
  COUNT(*) AS order_line_count,
  ROUND(SUM(f.volume_kg), 1) AS sales_volume_kg,
  ROUND(SUM(f.revenue_eur), 2) AS revenue_eur,
  ROUND(SUM(f.cost_eur), 2) AS cost_eur,
  ROUND(SUM(f.revenue_eur - f.cost_eur), 2) AS gross_margin_eur
FROM food_analytics.sales.fact_sales f
JOIN food_analytics.sales.dim_product p ON p.product_id = f.product_id
JOIN food_analytics.sales.dim_customer c ON c.customer_id = f.customer_id
JOIN food_analytics.sales.dim_plant pl ON pl.plant_id = f.plant_id
GROUP BY
  f.sale_date,
  p.category,
  p.sub_category,
  p.brand,
  c.channel,
  c.country,
  c.region,
  pl.plant_name;

CREATE OR REPLACE VIEW food_analytics.sales.sales_kpi
COMMENT 'Canonical all-time dashboard KPI values. Power BI cards and Genie KPI answers must use these rows without recalculating the measures.'
AS
SELECT 'Total Revenue' AS metric_name, CAST(ROUND(SUM(revenue_eur), 2) AS DECIMAL(20,2)) AS metric_value, 'EUR' AS metric_unit
FROM food_analytics.sales.sales_analytics
UNION ALL
SELECT 'Total Cost', CAST(ROUND(SUM(cost_eur), 2) AS DECIMAL(20,2)), 'EUR'
FROM food_analytics.sales.sales_analytics
UNION ALL
SELECT 'Gross Margin', CAST(ROUND(SUM(gross_margin_eur), 2) AS DECIMAL(20,2)), 'EUR'
FROM food_analytics.sales.sales_analytics
UNION ALL
SELECT 'Sales Volume', CAST(ROUND(SUM(sales_volume_kg), 1) AS DECIMAL(20,2)), 'kg'
FROM food_analytics.sales.sales_analytics
UNION ALL
SELECT 'Order Lines', CAST(SUM(order_line_count) AS DECIMAL(20,2)), 'count'
FROM food_analytics.sales.sales_analytics;
