# Where Is Revenue at Risk?

**A Retail Customer, Product, and Cancellation Analysis**

## Business Question

Where is retail merchandise revenue most exposed to cancellations, product losses, and customer concentration?

## Dataset and Tools

- **541,909** original transaction rows; **5,268** exact duplicates removed; **536,641** rows analyzed.
- December 2010–December 2011; **38 countries**; **4,372** distinct customer IDs.
- **Google Sheets, BigQuery SQL, and Tableau Public.**

## Key Findings

- **Cancellation risk:** Two confirmed full-order reversals totaled **245,653.20** and accounted for **51.62%** of reported cancellation value. Excluding these exceptional reversals reduced the cancellation rate from **4.64% to 2.30%**.
- **Revenue:** Adjusted gross merchandise revenue was **10,001,566.12**; net merchandise revenue was **9,771,318.16**.
- **Product risk:** REGENCY CAKESTAND 3 TIER recorded the highest adjusted cancellation value at **9,697.05**.
- **Monthly risk:** April 2011 peaked at **6.46%**. December 2011 includes only nine reporting days.
- **Customer concentration:** The top **10%** of identified customers generated **60.63%** of identified customer revenue.
- **Customer visibility:** **15.10%** of adjusted merchandise revenue—**1,509,991.68**—could not be linked to a customer.

## Approach

Preserved the original data, documented cleaning decisions, validated transaction classifications, investigated exceptional reversals, and built adjusted SQL analyses and an interactive Tableau dashboard.

## Project Files

- [`retail_revenue_risk_analysis.sql`](retail_revenue_risk_analysis.sql) — 12 BigQuery queries covering validation, reversal investigation, revenue, products, customers, monthly trends, and country performance.
