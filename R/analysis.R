# Retail exploratory analysis using the offline completejourney datasets.
# Run from the repository root with: Rscript R/analysis.R

suppressPackageStartupMessages({
  library(completejourney)
  library(dplyr)
  library(ggplot2)
  library(tidyr)
  library(readr)
  library(lubridate)
  library(scales)
})

set.seed(2026)

dir.create("figures", showWarnings = FALSE, recursive = TRUE)
dir.create("outputs", showWarnings = FALSE, recursive = TRUE)

# Load only data bundled with the package. No download helper is used.
data(
  "transactions_sample",
  "products",
  "demographics",
  "campaigns",
  "campaign_descriptions",
  "coupons",
  "coupon_redemptions",
  "promotions_sample",
  package = "completejourney",
  envir = environment()
)

as_character_ids <- function(x) {
  id_columns <- intersect(
    c(
      "household_id", "store_id", "basket_id", "product_id",
      "manufacturer_id", "campaign_id", "coupon_upc"
    ),
    names(x)
  )

  x |>
    mutate(across(all_of(id_columns), as.character))
}

transactions <- transactions_sample |> as_character_ids()
products <- products |> as_character_ids()
demographics <- demographics |> as_character_ids()
campaigns <- campaigns |> as_character_ids()
campaign_descriptions <- campaign_descriptions |> as_character_ids()
coupons <- coupons |> as_character_ids()
coupon_redemptions <- coupon_redemptions |> as_character_ids()
promotions_sample <- promotions_sample |> as_character_ids()

# Missing product attributes are retained as an explicit category rather than
# silently dropping the associated transactions.
products_clean <- products |>
  distinct(product_id, .keep_all = TRUE) |>
  mutate(
    department = coalesce(department, "UNCLASSIFIED"),
    product_category = coalesce(product_category, "UNCLASSIFIED"),
    brand = as.character(brand),
    brand = coalesce(brand, "Unclassified")
  )

transactions_products <- transactions |>
  left_join(
    products_clean |>
      select(product_id, department, product_category, brand),
    by = "product_id",
    relationship = "many-to-one"
  ) |>
  mutate(
    department = coalesce(department, "UNMATCHED"),
    product_category = coalesce(product_category, "UNMATCHED"),
    brand = coalesce(brand, "Unmatched")
  )

save_plot <- function(filename, plot, width = 10, height = 6) {
  ggsave(
    filename = file.path("figures", filename),
    plot = plot,
    width = width,
    height = height,
    dpi = 300,
    bg = "white"
  )
}

save_table <- function(x, filename) {
  write_csv(x, file.path("outputs", filename), na = "")
}

print_summary <- function(title, x, n = 60) {
  cat("\n", strrep("=", 72), "\n", title, "\n", sep = "")
  print(utils::head(as.data.frame(x), n), row.names = FALSE)
}

# 1. How do weekly sales and the number of shopping baskets evolve?
weekly_summary <- transactions |>
  group_by(week) |>
  summarise(
    sales = sum(sales_value, na.rm = TRUE),
    baskets = n_distinct(basket_id),
    transactions = n(),
    .groups = "drop"
  ) |>
  arrange(week) |>
  mutate(average_basket_value = sales / baskets)

save_table(weekly_summary, "weekly_sales_and_baskets.csv")

weekly_plot_data <- weekly_summary |>
  select(week, sales, baskets) |>
  pivot_longer(
    cols = c(sales, baskets),
    names_to = "metric",
    values_to = "value"
  ) |>
  mutate(
    metric = recode(
      metric,
      sales = "Sales value",
      baskets = "Shopping baskets"
    )
  )

p_weekly <- ggplot(
  weekly_plot_data,
  aes(x = week, y = value, group = metric)
) +
  geom_line(colour = "#176B87", linewidth = 0.8) +
  geom_point(colour = "#176B87", size = 1.4) +
  facet_wrap(~metric, ncol = 1, scales = "free_y") +
  scale_x_continuous(breaks = pretty_breaks()) +
  scale_y_continuous(labels = label_number(big.mark = ",")) +
  labs(
    title = "Weekly sales and shopping baskets",
    subtitle = "Offline transaction sample",
    x = "Week",
    y = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(strip.text = element_text(face = "bold"))

save_plot("01_weekly_sales_and_baskets.png", p_weekly, height = 8)

# 2. Which departments account for most sales? A Pareto view.
department_pareto <- transactions_products |>
  group_by(department) |>
  summarise(sales = sum(sales_value, na.rm = TRUE), .groups = "drop") |>
  arrange(desc(sales), department) |>
  mutate(
    sales_share = sales / sum(sales),
    cumulative_sales_share = cumsum(sales_share)
  )

save_table(department_pareto, "department_sales_pareto.csv")

pareto_scale <- max(department_pareto$sales, na.rm = TRUE)

p_department <- ggplot(
  department_pareto,
  aes(x = reorder(department, -sales), y = sales)
) +
  geom_col(fill = "#64CCC5") +
  geom_line(
    aes(y = cumulative_sales_share * pareto_scale, group = 1),
    colour = "#B04759",
    linewidth = 0.9
  ) +
  geom_point(
    aes(y = cumulative_sales_share * pareto_scale),
    colour = "#B04759",
    size = 1.8
  ) +
  scale_y_continuous(
    labels = label_number(big.mark = ","),
    sec.axis = sec_axis(
      transform = ~ .x / pareto_scale,
      labels = label_percent(),
      name = "Cumulative sales share"
    )
  ) +
  labs(
    title = "Department sales contribution",
    subtitle = "Bars show sales; the line shows cumulative share",
    x = "Department",
    y = "Sales value"
  ) +
  theme_minimal(base_size = 12) +
  theme(axis.text.x = element_text(angle = 45, hjust = 1))

save_plot("02_department_sales_pareto.png", p_department, width = 12)

# 3. How does sales share differ between private-label and national brands?
brand_summary <- transactions_products |>
  group_by(brand) |>
  summarise(
    sales = sum(sales_value, na.rm = TRUE),
    units = sum(quantity, na.rm = TRUE),
    baskets = n_distinct(basket_id),
    .groups = "drop"
  ) |>
  mutate(sales_share = sales / sum(sales)) |>
  arrange(desc(sales))

save_table(brand_summary, "brand_sales_share.csv")

p_brand <- ggplot(
  brand_summary,
  aes(x = reorder(brand, sales_share), y = sales_share, fill = brand)
) +
  geom_col(show.legend = FALSE) +
  geom_text(
    aes(label = percent(sales_share, accuracy = 0.1)),
    hjust = -0.15,
    size = 3.5
  ) +
  coord_flip() +
  scale_y_continuous(
    labels = label_percent(),
    expand = expansion(mult = c(0, 0.15))
  ) +
  scale_fill_manual(
    values = c(
      "National" = "#176B87",
      "Private" = "#64CCC5",
      "Unclassified" = "#B8B8B8",
      "Unmatched" = "#E5E5E5"
    )
  ) +
  labs(
    title = "Sales share by brand type",
    x = NULL,
    y = "Share of sales value"
  ) +
  theme_minimal(base_size = 12)

save_plot("03_brand_sales_share.png", p_brand)

# 4. Does average basket value vary by household income band?
# Unknown income is kept visible so that missing demographic data are auditable.
income_levels <- c(levels(demographics$income), "Unknown")

basket_values <- transactions |>
  group_by(household_id, basket_id) |>
  summarise(
    basket_value = sum(sales_value, na.rm = TRUE),
    .groups = "drop"
  )

income_baskets <- basket_values |>
  left_join(
    demographics |> select(household_id, income),
    by = "household_id",
    relationship = "many-to-one"
  ) |>
  mutate(
    income = as.character(income),
    income = coalesce(income, "Unknown"),
    income = factor(income, levels = income_levels, ordered = TRUE)
  )

income_summary <- income_baskets |>
  group_by(income, .drop = FALSE) |>
  summarise(
    households = n_distinct(household_id),
    baskets = n(),
    sales = sum(basket_value, na.rm = TRUE),
    average_basket_value = if_else(
      baskets > 0,
      sales / baskets,
      NA_real_
    ),
    .groups = "drop"
  )

save_table(income_summary, "income_average_basket_value.csv")

p_income <- ggplot(
  income_summary |> filter(baskets > 0),
  aes(x = income, y = average_basket_value)
) +
  geom_col(fill = "#176B87") +
  geom_text(
    aes(label = number(average_basket_value, accuracy = 0.01)),
    vjust = -0.4,
    size = 3.3
  ) +
  scale_y_continuous(
    labels = label_number(big.mark = ","),
    expand = expansion(mult = c(0, 0.12))
  ) +
  labs(
    title = "Average basket value by income band",
    subtitle = "Baskets are aggregated before calculating group averages",
    x = "Income band",
    y = "Average basket value"
  ) +
  theme_minimal(base_size = 12) +
  theme(axis.text.x = element_text(angle = 35, hjust = 1))

save_plot("04_income_average_basket_value.png", p_income)

# 5. How large are retail and coupon discounts relative to sales?
discount_summary <- transactions |>
  summarise(
    sales = sum(sales_value, na.rm = TRUE),
    retail_discount = sum(retail_disc, na.rm = TRUE),
    coupon_discount = sum(coupon_disc, na.rm = TRUE),
    coupon_match_discount = sum(coupon_match_disc, na.rm = TRUE)
  ) |>
  mutate(
    retail_discount_to_sales = retail_discount / sales,
    coupon_discount_to_sales = coupon_discount / sales,
    total_recorded_discount = retail_discount + coupon_discount +
      coupon_match_discount,
    total_recorded_discount_to_sales = total_recorded_discount / sales
  )

save_table(discount_summary, "discount_summary.csv")

discount_plot_data <- discount_summary |>
  select(retail_discount_to_sales, coupon_discount_to_sales) |>
  pivot_longer(
    cols = everything(),
    names_to = "discount_type",
    values_to = "discount_to_sales"
  ) |>
  mutate(
    discount_type = recode(
      discount_type,
      retail_discount_to_sales = "Retail discount",
      coupon_discount_to_sales = "Coupon discount"
    )
  )

p_discount <- ggplot(
  discount_plot_data,
  aes(x = discount_type, y = discount_to_sales, fill = discount_type)
) +
  geom_col(show.legend = FALSE, width = 0.6) +
  geom_text(
    aes(label = percent(discount_to_sales, accuracy = 0.01)),
    vjust = -0.4
  ) +
  scale_y_continuous(
    labels = label_percent(),
    expand = expansion(mult = c(0, 0.15))
  ) +
  scale_fill_manual(values = c("#176B87", "#64CCC5")) +
  labs(
    title = "Recorded discounts relative to sales value",
    subtitle = "Discount amounts are summed from the transaction sample",
    x = NULL,
    y = "Discount amount / sales value"
  ) +
  theme_minimal(base_size = 12)

save_plot("05_discounts_relative_to_sales.png", p_discount)

# 6. When do households shop? Weekday and hourly basket distributions.
# A basket is counted once per weekday/hour combination. The timestamp is used
# directly; the week field is not assumed to align exactly with calendar weeks.
basket_times <- transactions |>
  filter(!is.na(transaction_timestamp)) |>
  mutate(
    transaction_date = as_date(transaction_timestamp),
    weekday = wday(
      transaction_timestamp,
      label = TRUE,
      abbr = TRUE,
      week_start = 1,
      locale = "C"
    ),
    hour = hour(transaction_timestamp)
  ) |>
  distinct(basket_id, transaction_date, weekday, hour)

weekday_summary <- basket_times |>
  count(weekday, name = "baskets") |>
  mutate(basket_share = baskets / sum(baskets))

hour_summary <- basket_times |>
  count(hour, name = "baskets") |>
  mutate(basket_share = baskets / sum(baskets)) |>
  arrange(hour)

save_table(weekday_summary, "weekday_basket_distribution.csv")
save_table(hour_summary, "hourly_basket_distribution.csv")

shopping_time_summary <- weekday_summary |>
  select(weekday, baskets, basket_share) |>
  mutate(hour = NA_integer_) |>
  bind_rows(
    hour_summary |>
      mutate(weekday = NA) |>
      select(weekday, hour, baskets, basket_share)
  )

save_table(shopping_time_summary, "shopping_time_distributions.csv")

weekday_plot_data <- weekday_summary |>
  mutate(period = "Day of week", time_label = as.character(weekday))

hour_plot_data <- hour_summary |>
  mutate(period = "Hour of day", time_label = sprintf("%02d:00", hour))

time_plot_data <- bind_rows(weekday_plot_data, hour_plot_data) |>
  mutate(
    period = factor(period, levels = c("Day of week", "Hour of day")),
    time_label = factor(
      time_label,
      levels = c(levels(weekday_summary$weekday), sprintf("%02d:00", 0:23))
    )
  )

p_time <- ggplot(
  time_plot_data,
  aes(x = time_label, y = baskets, group = period)
) +
  geom_col(fill = "#176B87") +
  facet_wrap(~period, ncol = 1, scales = "free") +
  scale_y_continuous(labels = label_number(big.mark = ",")) +
  labs(
    title = "Shopping basket timing",
    subtitle = "Each basket is counted once at its transaction timestamp",
    x = NULL,
    y = "Shopping baskets"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    strip.text = element_text(face = "bold"),
    axis.text.x = element_text(angle = 45, hjust = 1)
  )

save_plot("06_shopping_time_distribution.png", p_time, height = 8)

# Auxiliary-table coverage makes the offline inputs and join coverage explicit.
# These campaign, coupon and promotion tables are not used to infer transaction
# outcomes because they do not provide a complete attribution linkage here.
data_coverage <- tibble(
  dataset = c(
    "transactions_sample", "products", "demographics", "campaigns",
    "campaign_descriptions", "coupons", "coupon_redemptions",
    "promotions_sample"
  ),
  rows = c(
    nrow(transactions), nrow(products), nrow(demographics), nrow(campaigns),
    nrow(campaign_descriptions), nrow(coupons), nrow(coupon_redemptions),
    nrow(promotions_sample)
  )
)

join_coverage <- tibble(
  check = c(
    "Transaction rows",
    "Rows with matched product",
    "Rows with missing product department",
    "Baskets with matched household income",
    "Distinct baskets"
  ),
  value = c(
    nrow(transactions_products),
    sum(transactions_products$department != "UNMATCHED"),
    sum(transactions_products$department %in% c("UNCLASSIFIED", "UNMATCHED")),
    nrow(income_baskets |> filter(income != "Unknown")),
    n_distinct(transactions$basket_id)
  )
)

save_table(data_coverage, "offline_data_coverage.csv")
save_table(join_coverage, "join_coverage.csv")

# Print the numerical summaries needed to write evidence-based findings.
print_summary("Offline data coverage", data_coverage)
print_summary("Join coverage", join_coverage)
print_summary("Weekly sales and baskets", weekly_summary)
print_summary("Department sales Pareto", department_pareto)
print_summary("Brand sales share", brand_summary)
print_summary("Average basket value by income", income_summary)
print_summary("Discount summary", discount_summary)
print_summary("Weekday basket distribution", weekday_summary)
print_summary("Hourly basket distribution", hour_summary)

cat(
  "\nAnalysis complete. Figures are in figures/ and tables are in outputs/.\n"
)
