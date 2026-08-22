-- Where Is Revenue at Risk?
-- Retail customer, product, and cancellation analysis
-- BigQuery Standard SQL

-- =============================================================================
-- Create analysis table
-- Copies cleaned retail transactions into a dedicated BigQuery working table.
-- =============================================================================

CREATE OR REPLACE TABLE
  `projectblue-500000.retail_revenue_risk.retail_transactions_analysis`
AS

SELECT
  *
FROM `projectblue-500000.retail_revenue_risk.retail_transactions`;

-- =============================================================================
-- Dataset validation
-- Confirms row completeness, customer and country counts, and reporting dates.
-- =============================================================================

SELECT
  COUNT(*) AS total_rows,
  COUNTIF(Transaction_Type IS NULL) AS missing_transaction_types,
  COUNTIF(Line_Revenue IS NULL) AS missing_revenue_values,
  COUNT(DISTINCT CustomerID) AS unique_customers,
  COUNT(DISTINCT Country) AS unique_countries,
  MIN(InvoiceDate) AS earliest_transaction,
  MAX(InvoiceDate) AS latest_transaction
FROM `projectblue-500000.retail_revenue_risk.retail_transactions`;

-- =============================================================================
-- Reported revenue baseline
-- Measures merchandise sales, cancellations, net revenue, and cancellation risk.
-- =============================================================================

WITH merchandise_revenue AS (
  SELECT
    COUNTIF(Transaction_Type = 'Merchandise Sale')
      AS merchandise_sale_rows,
    COUNTIF(Transaction_Type = 'Merchandise Cancellation')
      AS merchandise_cancellation_rows,
    SUM(
      CASE
        WHEN Transaction_Type = 'Merchandise Sale'
        THEN Line_Revenue
        ELSE 0
      END
    ) AS gross_merchandise_revenue,
    ABS(
      SUM(
        CASE
          WHEN Transaction_Type = 'Merchandise Cancellation'
          THEN Line_Revenue
          ELSE 0
        END
      )
    ) AS cancellation_value
  FROM `projectblue-500000.retail_revenue_risk.retail_transactions`
)

SELECT
  merchandise_sale_rows,
  merchandise_cancellation_rows,
  ROUND(gross_merchandise_revenue, 2)
    AS gross_merchandise_revenue,
  ROUND(cancellation_value, 2)
    AS cancellation_value,
  ROUND(gross_merchandise_revenue - cancellation_value, 2)
    AS net_merchandise_revenue,
  ROUND(
    SAFE_DIVIDE(cancellation_value, gross_merchandise_revenue) * 100,
    2
  ) AS cancellation_rate_percent
FROM merchandise_revenue;

-- =============================================================================
-- Reported product revenue and cancellation risk
-- Evaluates product-level exposure before exceptional reversals are excluded.
-- =============================================================================

WITH product_metrics AS (
  SELECT
    StockCode,
    ARRAY_AGG(
      Description
      IGNORE NULLS
      ORDER BY InvoiceDate DESC
      LIMIT 1
    )[SAFE_OFFSET(0)] AS product_description,
    COUNTIF(
      Transaction_Type = 'Merchandise Sale'
    ) AS sale_rows,
    COUNTIF(
      Transaction_Type = 'Merchandise Cancellation'
    ) AS cancellation_rows,
    COUNT(
      DISTINCT CASE
        WHEN Transaction_Type = 'Merchandise Sale'
        THEN CustomerID
      END
    ) AS unique_customers,
    SUM(
      CASE
        WHEN Transaction_Type = 'Merchandise Sale'
        THEN Quantity
        ELSE 0
      END
    ) AS units_sold,
    SUM(
      CASE
        WHEN Transaction_Type = 'Merchandise Cancellation'
        THEN ABS(Quantity)
        ELSE 0
      END
    ) AS units_canceled,
    SUM(
      CASE
        WHEN Transaction_Type = 'Merchandise Sale'
        THEN Line_Revenue
        ELSE 0
      END
    ) AS gross_revenue,
    ABS(
      SUM(
        CASE
          WHEN Transaction_Type = 'Merchandise Cancellation'
          THEN Line_Revenue
          ELSE 0
        END
      )
    ) AS cancellation_value
  FROM `projectblue-500000.retail_revenue_risk.retail_transactions`
  WHERE Transaction_Type IN (
    'Merchandise Sale',
    'Merchandise Cancellation'
  )
  GROUP BY StockCode
)

SELECT
  StockCode,
  product_description,
  sale_rows,
  cancellation_rows,
  unique_customers,
  units_sold,
  units_canceled,
  ROUND(gross_revenue, 2) AS gross_revenue,
  ROUND(cancellation_value, 2) AS cancellation_value,
  ROUND(
    gross_revenue - cancellation_value,
    2
  ) AS net_revenue,
  ROUND(
    SAFE_DIVIDE(cancellation_value, gross_revenue) * 100,
    2
  ) AS cancellation_rate_percent
FROM product_metrics
ORDER BY
  cancellation_value DESC,
  gross_revenue DESC;

-- =============================================================================
-- High-value cancellation investigation
-- Identifies matched merchandise sales and exceptional full-order reversals.
-- =============================================================================

SELECT
  StockCode,
  Description,
  InvoiceNo,
  InvoiceDate,
  CustomerID,
  Country,
  Transaction_Type,
  Quantity,
  UnitPrice,
  ROUND(Line_Revenue, 2) AS line_revenue
FROM `projectblue-500000.retail_revenue_risk.retail_transactions`
WHERE StockCode IN ('23843', '23166')
  AND Transaction_Type IN (
    'Merchandise Sale',
    'Merchandise Cancellation'
  )
  AND ABS(Line_Revenue) >= 10000
ORDER BY
  StockCode,
  InvoiceDate;

-- =============================================================================
-- Adjusted revenue baseline
-- Compares reported and adjusted merchandise revenue after full-order reversals.
-- =============================================================================

WITH flagged_transactions AS (
  SELECT
    Transaction_Type,
    Line_Revenue,
    CASE
      WHEN StockCode = '23166'
        AND InvoiceNo IN ('541431', 'C541433')
        THEN TRUE
      WHEN StockCode = '23843'
        AND InvoiceNo IN ('581483', 'C581484')
        THEN TRUE
      ELSE FALSE
    END AS is_full_reversal
  FROM `projectblue-500000.retail_revenue_risk.retail_transactions_analysis`
  WHERE Transaction_Type IN (
    'Merchandise Sale',
    'Merchandise Cancellation'
  )
),

revenue_totals AS (
  SELECT
    SUM(
      CASE
        WHEN Transaction_Type = 'Merchandise Sale'
        THEN Line_Revenue
        ELSE 0
      END
    ) AS reported_gross_revenue,
    ABS(
      SUM(
        CASE
          WHEN Transaction_Type = 'Merchandise Cancellation'
          THEN Line_Revenue
          ELSE 0
        END
      )
    ) AS reported_cancellation_value,
    SUM(
      CASE
        WHEN Transaction_Type = 'Merchandise Sale'
          AND is_full_reversal
        THEN Line_Revenue
        ELSE 0
      END
    ) AS reversal_value
  FROM flagged_transactions
)

SELECT
  result.metric,
  ROUND(result.value, 2) AS value
FROM revenue_totals
CROSS JOIN UNNEST([
  STRUCT(
    'Reported gross merchandise revenue' AS metric,
    reported_gross_revenue AS value
  ),
  STRUCT(
    'Reported merchandise cancellation value' AS metric,
    reported_cancellation_value AS value
  ),
  STRUCT(
    'Reported cancellation rate (%)' AS metric,
    SAFE_DIVIDE(
      reported_cancellation_value,
      reported_gross_revenue
    ) * 100 AS value
  ),
  STRUCT(
    'Confirmed full-order reversal value' AS metric,
    reversal_value AS value
  ),
  STRUCT(
    'Cancellation value attributable to reversals (%)' AS metric,
    SAFE_DIVIDE(
      reversal_value,
      reported_cancellation_value
    ) * 100 AS value
  ),
  STRUCT(
    'Adjusted gross merchandise revenue' AS metric,
    reported_gross_revenue - reversal_value AS value
  ),
  STRUCT(
    'Adjusted merchandise cancellation value' AS metric,
    reported_cancellation_value - reversal_value AS value
  ),
  STRUCT(
    'Adjusted cancellation rate (%)' AS metric,
    SAFE_DIVIDE(
      reported_cancellation_value - reversal_value,
      reported_gross_revenue - reversal_value
    ) * 100 AS value
  ),
  STRUCT(
    'Net merchandise revenue' AS metric,
    reported_gross_revenue - reported_cancellation_value AS value
  )
]) AS result
WITH OFFSET AS display_order
ORDER BY display_order;

-- =============================================================================
-- Adjusted product revenue and cancellation risk
-- Ranks product exposure after excluding confirmed full-order reversals.
-- =============================================================================

WITH eligible_transactions AS (
  SELECT
    StockCode,
    Description,
    InvoiceNo,
    InvoiceDate,
    CustomerID,
    Transaction_Type,
    Quantity,
    Line_Revenue
  FROM `projectblue-500000.retail_revenue_risk.retail_transactions_analysis`
  WHERE Transaction_Type IN (
    'Merchandise Sale',
    'Merchandise Cancellation'
  )
    AND NOT (
      (
        StockCode = '23166'
        AND InvoiceNo IN ('541431', 'C541433')
      )
      OR
      (
        StockCode = '23843'
        AND InvoiceNo IN ('581483', 'C581484')
      )
    )
),

product_metrics AS (
  SELECT
    StockCode,
    ARRAY_AGG(
      Description
      IGNORE NULLS
      ORDER BY InvoiceDate DESC
      LIMIT 1
    )[SAFE_OFFSET(0)] AS product_description,
    COUNTIF(
      Transaction_Type = 'Merchandise Sale'
    ) AS sale_rows,
    COUNTIF(
      Transaction_Type = 'Merchandise Cancellation'
    ) AS cancellation_rows,
    COUNT(
      DISTINCT CASE
        WHEN Transaction_Type = 'Merchandise Sale'
        THEN CustomerID
      END
    ) AS unique_customers,
    SUM(
      CASE
        WHEN Transaction_Type = 'Merchandise Sale'
        THEN Quantity
        ELSE 0
      END
    ) AS units_sold,
    SUM(
      CASE
        WHEN Transaction_Type = 'Merchandise Cancellation'
        THEN ABS(Quantity)
        ELSE 0
      END
    ) AS units_canceled,
    SUM(
      CASE
        WHEN Transaction_Type = 'Merchandise Sale'
        THEN Line_Revenue
        ELSE 0
      END
    ) AS gross_revenue,
    ABS(
      SUM(
        CASE
          WHEN Transaction_Type = 'Merchandise Cancellation'
          THEN Line_Revenue
          ELSE 0
        END
      )
    ) AS cancellation_value
  FROM eligible_transactions
  GROUP BY StockCode
)

SELECT
  StockCode,
  product_description,
  sale_rows,
  cancellation_rows,
  unique_customers,
  units_sold,
  units_canceled,
  ROUND(gross_revenue, 2) AS gross_revenue,
  ROUND(cancellation_value, 2) AS cancellation_value,
  ROUND(
    gross_revenue - cancellation_value,
    2
  ) AS net_revenue,
  ROUND(
    SAFE_DIVIDE(cancellation_value, gross_revenue) * 100,
    2
  ) AS cancellation_rate_percent
FROM product_metrics
ORDER BY
  cancellation_value DESC,
  gross_revenue DESC;

-- =============================================================================
-- Customer revenue and cancellation risk
-- Evaluates identified customer exposure after excluding full-order reversals.
-- =============================================================================

WITH eligible_transactions AS (
  SELECT
    CustomerID,
    Country,
    InvoiceNo,
    InvoiceDate,
    StockCode,
    Transaction_Type,
    Line_Revenue
  FROM `projectblue-500000.retail_revenue_risk.retail_transactions_analysis`
  WHERE CustomerID IS NOT NULL
    AND Transaction_Type IN (
      'Merchandise Sale',
      'Merchandise Cancellation'
    )
    AND NOT (
      (
        StockCode = '23166'
        AND InvoiceNo IN ('541431', 'C541433')
      )
      OR
      (
        StockCode = '23843'
        AND InvoiceNo IN ('581483', 'C581484')
      )
    )
),

customer_metrics AS (
  SELECT
    CustomerID,
    ARRAY_AGG(
      Country
      IGNORE NULLS
      ORDER BY InvoiceDate DESC
      LIMIT 1
    )[SAFE_OFFSET(0)] AS country,
    COUNT(
      DISTINCT CASE
        WHEN Transaction_Type = 'Merchandise Sale'
        THEN InvoiceNo
      END
    ) AS purchase_invoices,
    COUNT(
      DISTINCT CASE
        WHEN Transaction_Type = 'Merchandise Cancellation'
        THEN InvoiceNo
      END
    ) AS cancellation_invoices,
    COUNTIF(
      Transaction_Type = 'Merchandise Sale'
    ) AS purchase_rows,
    COUNTIF(
      Transaction_Type = 'Merchandise Cancellation'
    ) AS cancellation_rows,
    COUNT(
      DISTINCT CASE
        WHEN Transaction_Type = 'Merchandise Sale'
        THEN StockCode
      END
    ) AS products_purchased,
    SUM(
      CASE
        WHEN Transaction_Type = 'Merchandise Sale'
        THEN Line_Revenue
        ELSE 0
      END
    ) AS gross_revenue,
    ABS(
      SUM(
        CASE
          WHEN Transaction_Type = 'Merchandise Cancellation'
          THEN Line_Revenue
          ELSE 0
        END
      )
    ) AS cancellation_value,
    MIN(InvoiceDate) AS first_transaction,
    MAX(InvoiceDate) AS latest_transaction
  FROM eligible_transactions
  GROUP BY CustomerID
)

SELECT
  CustomerID,
  country,
  purchase_invoices,
  cancellation_invoices,
  purchase_rows,
  cancellation_rows,
  products_purchased,
  ROUND(gross_revenue, 2) AS gross_revenue,
  ROUND(cancellation_value, 2) AS cancellation_value,
  ROUND(
    gross_revenue - cancellation_value,
    2
  ) AS net_revenue,
  ROUND(
    SAFE_DIVIDE(cancellation_value, gross_revenue) * 100,
    2
  ) AS cancellation_rate_percent,
  first_transaction,
  latest_transaction
FROM customer_metrics
ORDER BY
  cancellation_value DESC,
  gross_revenue DESC;

-- =============================================================================
-- Monthly revenue and cancellation trends
-- Distinguishes complete months from partial reporting periods.
-- =============================================================================

WITH eligible_transactions AS (
  SELECT
    InvoiceNo,
    InvoiceDate,
    CustomerID,
    StockCode,
    Transaction_Type,
    Line_Revenue
  FROM `projectblue-500000.retail_revenue_risk.retail_transactions_analysis`
  WHERE Transaction_Type IN (
    'Merchandise Sale',
    'Merchandise Cancellation'
  )
    AND NOT (
      (
        StockCode = '23166'
        AND InvoiceNo IN ('541431', 'C541433')
      )
      OR
      (
        StockCode = '23843'
        AND InvoiceNo IN ('581483', 'C581484')
      )
    )
),

date_bounds AS (
  SELECT
    MIN(DATE(InvoiceDate)) AS dataset_start,
    MAX(DATE(InvoiceDate)) AS dataset_end
  FROM eligible_transactions
),

monthly_metrics AS (
  SELECT
    DATE_TRUNC(
      DATE(InvoiceDate),
      MONTH
    ) AS month_start,
    COUNTIF(
      Transaction_Type = 'Merchandise Sale'
    ) AS sale_rows,
    COUNTIF(
      Transaction_Type = 'Merchandise Cancellation'
    ) AS cancellation_rows,
    COUNT(
      DISTINCT CASE
        WHEN Transaction_Type = 'Merchandise Sale'
        THEN InvoiceNo
      END
    ) AS purchase_invoices,
    COUNT(
      DISTINCT CASE
        WHEN Transaction_Type = 'Merchandise Cancellation'
        THEN InvoiceNo
      END
    ) AS cancellation_invoices,
    COUNT(
      DISTINCT CustomerID
    ) AS unique_identified_customers,
    SUM(
      CASE
        WHEN Transaction_Type = 'Merchandise Sale'
        THEN Line_Revenue
        ELSE 0
      END
    ) AS gross_revenue,
    ABS(
      SUM(
        CASE
          WHEN Transaction_Type = 'Merchandise Cancellation'
          THEN Line_Revenue
          ELSE 0
        END
      )
    ) AS cancellation_value
  FROM eligible_transactions
  GROUP BY month_start
)

SELECT
  monthly.month_start,
  FORMAT_DATE(
    '%b %Y',
    monthly.month_start
  ) AS month_label,
  CASE
    WHEN (
      monthly.month_start = DATE_TRUNC(
        bounds.dataset_start,
        MONTH
      )
      AND bounds.dataset_start > monthly.month_start
    )
    OR (
      monthly.month_start = DATE_TRUNC(
        bounds.dataset_end,
        MONTH
      )
      AND bounds.dataset_end < LAST_DAY(
        monthly.month_start
      )
    )
    THEN 'Partial Month'
    ELSE 'Complete Month'
  END AS period_status,
  DATE_DIFF(
    LEAST(
      LAST_DAY(monthly.month_start),
      bounds.dataset_end
    ),
    GREATEST(
      monthly.month_start,
      bounds.dataset_start
    ),
    DAY
  ) + 1 AS days_in_reporting_window,
  monthly.sale_rows,
  monthly.cancellation_rows,
  monthly.purchase_invoices,
  monthly.cancellation_invoices,
  monthly.unique_identified_customers,
  ROUND(
    monthly.gross_revenue,
    2
  ) AS gross_revenue,
  ROUND(
    monthly.cancellation_value,
    2
  ) AS cancellation_value,
  ROUND(
    monthly.gross_revenue - monthly.cancellation_value,
    2
  ) AS net_revenue,
  ROUND(
    SAFE_DIVIDE(
      monthly.cancellation_value,
      monthly.gross_revenue
    ) * 100,
    2
  ) AS cancellation_rate_percent
FROM monthly_metrics AS monthly
CROSS JOIN date_bounds AS bounds
ORDER BY monthly.month_start;

-- =============================================================================
-- Country revenue and cancellation performance
-- Compares geographic revenue exposure, cancellation risk, and customer coverage.
-- =============================================================================

WITH eligible_transactions AS (
  SELECT
    Country,
    CustomerID,
    InvoiceNo,
    StockCode,
    Transaction_Type,
    Line_Revenue
  FROM `projectblue-500000.retail_revenue_risk.retail_transactions_analysis`
  WHERE Transaction_Type IN (
    'Merchandise Sale',
    'Merchandise Cancellation'
  )
    AND NOT (
      (
        StockCode = '23166'
        AND InvoiceNo IN ('541431', 'C541433')
      )
      OR
      (
        StockCode = '23843'
        AND InvoiceNo IN ('581483', 'C581484')
      )
    )
),

country_metrics AS (
  SELECT
    Country,
    COUNT(
      DISTINCT CustomerID
    ) AS unique_identified_customers,
    COUNT(
      DISTINCT CASE
        WHEN Transaction_Type = 'Merchandise Sale'
        THEN InvoiceNo
      END
    ) AS purchase_invoices,
    COUNT(
      DISTINCT CASE
        WHEN Transaction_Type = 'Merchandise Cancellation'
        THEN InvoiceNo
      END
    ) AS cancellation_invoices,
    COUNTIF(
      Transaction_Type = 'Merchandise Sale'
    ) AS sale_rows,
    COUNTIF(
      Transaction_Type = 'Merchandise Cancellation'
    ) AS cancellation_rows,
    COUNTIF(
      CustomerID IS NOT NULL
    ) AS identified_transaction_rows,
    COUNT(*) AS total_transaction_rows,
    SUM(
      CASE
        WHEN Transaction_Type = 'Merchandise Sale'
        THEN Line_Revenue
        ELSE 0
      END
    ) AS gross_revenue,
    ABS(
      SUM(
        CASE
          WHEN Transaction_Type = 'Merchandise Cancellation'
          THEN Line_Revenue
          ELSE 0
        END
      )
    ) AS cancellation_value
  FROM eligible_transactions
  GROUP BY Country
)

SELECT
  Country,
  unique_identified_customers,
  purchase_invoices,
  cancellation_invoices,
  sale_rows,
  cancellation_rows,
  ROUND(
    gross_revenue,
    2
  ) AS gross_revenue,
  ROUND(
    cancellation_value,
    2
  ) AS cancellation_value,
  ROUND(
    gross_revenue - cancellation_value,
    2
  ) AS net_revenue,
  ROUND(
    SAFE_DIVIDE(
      cancellation_value,
      gross_revenue
    ) * 100,
    2
  ) AS cancellation_rate_percent,
  ROUND(
    SAFE_DIVIDE(
      gross_revenue,
      SUM(gross_revenue) OVER ()
    ) * 100,
    2
  ) AS revenue_share_percent,
  ROUND(
    SAFE_DIVIDE(
      identified_transaction_rows,
      total_transaction_rows
    ) * 100,
    2
  ) AS customer_id_coverage_percent
FROM country_metrics
ORDER BY
  cancellation_value DESC,
  gross_revenue DESC;

-- =============================================================================
-- Customer revenue visibility
-- Compares merchandise revenue linked to identified and unidentified customers.
-- =============================================================================

WITH eligible_transactions AS (
  SELECT
    CustomerID,
    InvoiceNo,
    StockCode,
    Transaction_Type,
    Line_Revenue
  FROM `projectblue-500000.retail_revenue_risk.retail_transactions_analysis`
  WHERE Transaction_Type IN (
    'Merchandise Sale',
    'Merchandise Cancellation'
  )
    AND NOT (
      (
        StockCode = '23166'
        AND InvoiceNo IN ('541431', 'C541433')
      )
      OR
      (
        StockCode = '23843'
        AND InvoiceNo IN ('581483', 'C581484')
      )
    )
),

customer_visibility AS (
  SELECT
    CASE
      WHEN CustomerID IS NULL
      THEN 'Unidentified Customer'
      ELSE 'Identified Customer'
    END AS customer_status,
    COUNT(*) AS transaction_rows,
    COUNTIF(
      Transaction_Type = 'Merchandise Sale'
    ) AS sale_rows,
    COUNTIF(
      Transaction_Type = 'Merchandise Cancellation'
    ) AS cancellation_rows,
    COUNT(
      DISTINCT CASE
        WHEN Transaction_Type = 'Merchandise Sale'
        THEN InvoiceNo
      END
    ) AS purchase_invoices,
    COUNT(
      DISTINCT CustomerID
    ) AS unique_customers,
    SUM(
      CASE
        WHEN Transaction_Type = 'Merchandise Sale'
        THEN Line_Revenue
        ELSE 0
      END
    ) AS gross_revenue,
    ABS(
      SUM(
        CASE
          WHEN Transaction_Type = 'Merchandise Cancellation'
          THEN Line_Revenue
          ELSE 0
        END
      )
    ) AS cancellation_value
  FROM eligible_transactions
  GROUP BY customer_status
)

SELECT
  customer_status,
  transaction_rows,
  sale_rows,
  cancellation_rows,
  purchase_invoices,
  unique_customers,
  ROUND(
    gross_revenue,
    2
  ) AS gross_revenue,
  ROUND(
    cancellation_value,
    2
  ) AS cancellation_value,
  ROUND(
    gross_revenue - cancellation_value,
    2
  ) AS net_revenue,
  ROUND(
    SAFE_DIVIDE(
      cancellation_value,
      gross_revenue
    ) * 100,
    2
  ) AS cancellation_rate_percent,
  ROUND(
    SAFE_DIVIDE(
      gross_revenue,
      SUM(gross_revenue) OVER ()
    ) * 100,
    2
  ) AS revenue_share_percent
FROM customer_visibility
ORDER BY gross_revenue DESC;

-- =============================================================================
-- Customer revenue concentration
-- Excludes confirmed full-order reversals before ranking identified customers.
-- =============================================================================

WITH eligible_transactions AS (
  SELECT
    CustomerID,
    InvoiceNo,
    StockCode,
    Transaction_Type,
    Line_Revenue
  FROM `projectblue-500000.retail_revenue_risk.retail_transactions_analysis`
  WHERE Transaction_Type IN (
    'Merchandise Sale',
    'Merchandise Cancellation'
  )
    AND NOT (
      (
        StockCode = '23166'
        AND InvoiceNo IN ('541431', 'C541433')
      )
      OR
      (
        StockCode = '23843'
        AND InvoiceNo IN ('581483', 'C581484')
      )
    )
),

customer_revenue AS (
  SELECT
    CustomerID,
    SUM(
      CASE
        WHEN Transaction_Type = 'Merchandise Sale'
        THEN Line_Revenue
        ELSE 0
      END
    ) AS gross_revenue,
    ABS(
      SUM(
        CASE
          WHEN Transaction_Type = 'Merchandise Cancellation'
          THEN Line_Revenue
          ELSE 0
        END
      )
    ) AS cancellation_value
  FROM eligible_transactions
  WHERE CustomerID IS NOT NULL
  GROUP BY CustomerID
),

ranked_customers AS (
  SELECT
    CustomerID,
    gross_revenue,
    cancellation_value,
    NTILE(100) OVER (
      ORDER BY
        gross_revenue DESC,
        CustomerID
    ) AS customer_percentile
  FROM customer_revenue
),

customer_segments AS (
  SELECT
    CASE
      WHEN customer_percentile = 1
      THEN 'Top 1%'
      WHEN customer_percentile BETWEEN 2 AND 5
      THEN 'Next 4%'
      WHEN customer_percentile BETWEEN 6 AND 10
      THEN 'Next 5%'
      ELSE 'Remaining 90%'
    END AS customer_segment,
    COUNT(*) AS customer_count,
    SUM(gross_revenue) AS segment_revenue,
    SUM(cancellation_value) AS segment_cancellations
  FROM ranked_customers
  GROUP BY customer_segment
)

SELECT
  customer_segment,
  customer_count,
  ROUND(segment_revenue, 2) AS gross_revenue,
  ROUND(segment_cancellations, 2) AS cancellation_value,
  ROUND(segment_revenue - segment_cancellations, 2) AS net_revenue,
  ROUND(
    SAFE_DIVIDE(segment_cancellations, segment_revenue) * 100,
    2
  ) AS cancellation_rate_percent,
  ROUND(
    SAFE_DIVIDE(
      segment_revenue,
      SUM(segment_revenue) OVER ()
    ) * 100,
    2
  ) AS share_of_identified_customer_revenue_percent
FROM customer_segments
ORDER BY
  CASE customer_segment
    WHEN 'Top 1%' THEN 1
    WHEN 'Next 4%' THEN 2
    WHEN 'Next 5%' THEN 3
    ELSE 4
  END;
