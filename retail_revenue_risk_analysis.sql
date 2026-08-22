-- Where Is Revenue at Risk?
-- Retail customer, product, and cancellation analysis
-- BigQuery Standard SQL

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
