library(data.table)
library(openxlsx2)
library(readxl)

# =========================================================
# HELPER
# =========================================================

read_excel_table <- function(path, table_name) {
  wb <- wb_load(path)
  as.data.table(wb_to_df(wb, named_region = table_name))
}

first_non_blank <- function(x) {
  x <- as.character(x)
  x <- trimws(x)
  x[x == ""] <- NA_character_
  y <- x[!is.na(x)]
  if (length(y)) y[1] else NA_character_
}

# =========================================================
# LOAD
# =========================================================

rules           <- read_excel_table("T:/Indexes/UN.Energy data codes.xlsx", "Transformation")
prod_cleanup    <- read_excel_table("T:/Indexes/IRENA.Codes.xlsx", "TechCleanup")
products        <- read_excel_table("T:/Indexes/IRENA.Codes.xlsx", "Products")
transactions    <- read_excel_table("T:/Indexes/UN.Energy data codes.xlsx", "Transactions")
country_cleanup <- read_excel_table("T:/Indexes/Countries.xlsx", "CountryCleanup")

UN_NCV  <- as.data.table(read_excel("T:/Latest datasets/UN.NCV.xlsx", sheet = "Long format"))
balance <- fread("T:/Latest datasets/UN.Commodity balance.csv", blank.lines.skip = TRUE)

# =========================================================
# TYPE STABILIZATION
# =========================================================

balance[, `:=`(
  REF_AREA          = as.character(REF_AREA),
  TRANSACTION       = as.character(TRANSACTION),
  COMMODITY         = as.character(COMMODITY),
  UNIT_MEASURE      = as.character(UNIT_MEASURE),
  CONVERSION_FACTOR = as.numeric(CONVERSION_FACTOR),
  OBS_VALUE         = as.numeric(OBS_VALUE),
  TIME_PERIOD       = as.integer(TIME_PERIOD)
)]

prod_cleanup[, `:=`(
  `Product Messy` = as.character(`Product Messy`),
  ProdCode        = as.character(as.integer(ProdCode)),
  Product         = as.character(Product)
)]

products[, `:=`(
  ProdCode                   = as.character(as.integer(ProdCode)),
  Product                    = as.character(Product),
  `Source type`              = as.character(`Source type`),
  `UNSD NCV (TJ/kt)`         = as.numeric(`UNSD NCV (TJ/kt)`),
  `DNI UNSD Production`      = as.character(`DNI UNSD Production`),
  `UNSD production recoding` = as.character(`UNSD production recoding`),
  `UNSD receipts recoding`   = as.character(`UNSD receipts recoding`)
)]

transactions[, `:=`(
  `Transaction code`  = as.character(`Transaction code`),
  `MERGE category`    = as.character(`MERGE category`),
  `Combustible plant` = as.character(`Combustible plant`),
  `NCV type`          = as.character(`NCV type`),
  Sign                = as.character(Sign),
  DNI                 = as.character(DNI)
)]

country_cleanup[, `:=`(
  Name = as.character(Name),
  ISO3 = as.character(ISO3)
)]

UN_NCV[, `:=`(
  `Country Name`   = as.character(`Country Name`),
  `Product Name`   = as.character(`Product Name`),
  Year             = as.integer(Year),
  `Type Code`      = as.character(`Type Code`),
  `Factor to TJE`  = as.numeric(`Factor to TJE`)
)]

# =========================================================
# DROP ONLY COMPLETELY EMPTY BALANCE ROWS
# =========================================================

balance <- balance[
  !(is.na(REF_AREA) &
      is.na(TRANSACTION) &
      is.na(COMMODITY) &
      is.na(TIME_PERIOD) &
      is.na(OBS_VALUE))
]

# =========================================================
# DEDUP LOOKUPS
# keep first non-empty mapping per join key, do not invent values
# =========================================================

prod_cleanup <- prod_cleanup[
  ,
  .(
    ProdCode = first_non_blank(ProdCode),
    Product  = first_non_blank(Product)
  ),
  by = .(`Product Messy`)
]

products <- products[
  ,
  .(
    Product                    = first_non_blank(Product),
    `Source type`              = first_non_blank(`Source type`),
    `UNSD NCV (TJ/kt)`         = suppressWarnings(as.numeric(first_non_blank(`UNSD NCV (TJ/kt)`))),
    `DNI UNSD Production`      = first_non_blank(`DNI UNSD Production`),
    `UNSD production recoding` = first_non_blank(`UNSD production recoding`),
    `UNSD receipts recoding`   = first_non_blank(`UNSD receipts recoding`)
  ),
  by = .(ProdCode)
]

country_cleanup <- country_cleanup[
  !is.na(Name) & trimws(Name) != "",
  .(
    ISO3 = first_non_blank(ISO3)
  ),
  by = .(Name)
]

if (!("Transaction description" %in% names(transactions))) {
  transactions[, `Transaction description` := Transaction]
}

if (!("Balance type" %in% names(transactions))) {
  transactions[, `Balance type` := NA_character_]
}

transactions <- transactions[
  !is.na(`Transaction code`) & trimws(`Transaction code`) != "",
  .(
    `Transaction name` = first_non_blank(
      if ("Transaction name" %in% names(.SD)) `Transaction name` else Transaction
    ),
    `Transaction description` = first_non_blank(`Transaction description`),
    `MERGE category`          = first_non_blank(`MERGE category`),
    `Combustible plant`       = first_non_blank(`Combustible plant`),
    `NCV type`                = first_non_blank(`NCV type`),
    `Balance type`            = first_non_blank(`Balance type`),
    Sign                      = first_non_blank(Sign),
    DNI                       = first_non_blank(DNI)
  ),
  by = .(`Transaction code`)
]

UN_NCV <- UN_NCV[
  ,
  .(
    `Factor to TJE` = suppressWarnings(as.numeric(first_non_blank(`Factor to TJE`)))
  ),
  by = .(`Country Name`, `Product Name`, Year, `Type Code`)
]

# =========================================================
# RULES
# =========================================================

rules[, `:=`(
  Multiplier = as.numeric(Multiplier),
  From       = paste0(`Commodity from`, `Transaction from`),
  ID         = paste0(`Commodity from`, `Transaction from`, `Commodity to`, `Transaction to`)
)]

rules <- unique(rules, by = "ID")

# =========================================================
# UN_NCV ENRICHMENT
# =========================================================

UN_NCV <- merge(
  UN_NCV,
  prod_cleanup[, .(`Product Messy`, ProdCode)],
  by.x = "Product Name",
  by.y = "Product Messy",
  all.x = TRUE,
  sort = FALSE
)

UN_NCV <- merge(
  UN_NCV,
  country_cleanup[, .(Name, ISO3)],
  by.x = "Country Name",
  by.y = "Name",
  all.x = TRUE,
  sort = FALSE
)

UN_NCV[, `NCV-ID` := paste(ISO3, Year, ProdCode, `Type Code`, sep = "-")]

UN_NCV <- UN_NCV[, .(`NCV-ID`, `Factor to TJE`)]
UN_NCV <- unique(UN_NCV, by = "NCV-ID")

# =========================================================
# BALANCE
# =========================================================

balance <- balance[OBS_VALUE != 0]

# Unit normalization
balance[UNIT_MEASURE == "TN", UNIT_MEASURE := "kt"]
balance[UNIT_MEASURE == "M3", UNIT_MEASURE := "kM3"]

# Commodity fixes
setnames(balance, "COMMODITY", "COMMODITY_ORIGINAL")

balance[, COMMODITY := fifelse(
  TRANSACTION %in% c("162", "1621", "1622"),
  "2000",
  COMMODITY_ORIGINAL
)]

balance[COMMODITY == "7000N", COMMODITY := "9101"]
balance[TRANSACTION == "0889H", TRANSACTION := "015HP"]
balance[TRANSACTION == "0889E", TRANSACTION := "015EB"]

balance[, Year := TIME_PERIOD]

# Product mapping
balance <- merge(
  balance,
  prod_cleanup[, .(`Product Messy`, ProdCode)],
  by.x = "COMMODITY",
  by.y = "Product Messy",
  all.x = TRUE,
  sort = FALSE
)

balance <- merge(
  balance,
  products[, .(
    ProdCode,
    Product,
    `Source type`,
    `UNSD NCV (TJ/kt)`,
    `DNI UNSD Production`,
    `UNSD production recoding`,
    `UNSD receipts recoding`
  )],
  by = "ProdCode",
  all.x = TRUE,
  sort = FALSE
)

balance[, ProdCode := as.character(ProdCode)]

# Preserve original transaction before recode
balance[, TRANSACTION_ORIGINAL := TRANSACTION]

balance[, TRANSACTION := fifelse(
  TRANSACTION_ORIGINAL == "01" & !is.na(`UNSD production recoding`),
  `UNSD production recoding`,
  fifelse(
    TRANSACTION_ORIGINAL == "022" & !is.na(`UNSD receipts recoding`),
    `UNSD receipts recoding`,
    TRANSACTION_ORIGINAL
  )
)]

# Remove DNI production rows after recode rule
balance <- balance[paste0(`DNI UNSD Production`, "-", TRANSACTION) != "DNI-01"]

# Transaction metadata
balance <- merge(
  balance,
  transactions[, .(
    `Transaction code`,
    `Transaction name`,
    `Transaction description`,
    `MERGE category`,
    `Combustible plant`,
    `NCV type`,
    `Balance type`,
    Sign,
    DNI
  )],
  by.x = "TRANSACTION",
  by.y = "Transaction code",
  all.x = TRUE,
  sort = FALSE
)

# NCV type correction
balance[, `NCV type` := fifelse(
  `Source type` == "Secondary" & `NCV type` == "D",
  "C",
  `NCV type`
)]

# Sign correction
balance[, OBS_VALUE_PREV := OBS_VALUE]

balance[, OBS_VALUE := fifelse(
  TRANSACTION_ORIGINAL != TRANSACTION,
  OBS_VALUE_PREV,
  fifelse(Sign == "Negative", -OBS_VALUE_PREV, OBS_VALUE_PREV)
)]

# Country mapping
balance <- merge(
  balance,
  country_cleanup[, .(Name, ISO3)],
  by.x = "REF_AREA",
  by.y = "Name",
  all.x = TRUE,
  sort = FALSE
)

# NCV id
balance[, `NCV-ID` := paste(ISO3, Year, ProdCode, `NCV type`, sep = "-")]

# Country NCV join
balance <- merge(
  balance,
  UN_NCV,
  by = "NCV-ID",
  all.x = TRUE,
  sort = FALSE
)

# NCV selection
balance[, `NCV (TJ/kt)` := fifelse(
  TRANSACTION == "01" & COMMODITY == "9101" & UNIT_MEASURE == "GWHR", 10.8,
  fifelse(
    TRANSACTION %in% c("015EB", "015HP") & COMMODITY == "7000", -3.6,
    fifelse(
      ProdCode == "113220", 0.9,
      fifelse(
        !is.na(CONVERSION_FACTOR), CONVERSION_FACTOR,
        fifelse(
          !is.na(`Factor to TJE`), `Factor to TJE`,
          `UNSD NCV (TJ/kt)`
        )
      )
    )
  )
)]

balance[, NCV_SOURCE := fifelse(
  ProdCode == "113220", "GENERIC_NCV",
  fifelse(
    TRANSACTION == "01" & COMMODITY == "9101" & UNIT_MEASURE == "GWHR", "GENERIC_NCV",
    fifelse(
      !is.na(CONVERSION_FACTOR), "UN_CONVERSION_FACTOR",
      fifelse(
        !is.na(`Factor to TJE`), "COUNTRY_NCV",
        fifelse(!is.na(`UNSD NCV (TJ/kt)`), "GENERIC_NCV", "NONE")
      )
    )
  )
)]

# Energy
balance[, TJ := fifelse(NCV_SOURCE != "NONE", `NCV (TJ/kt)` * OBS_VALUE, NA_real_)]
balance[, `TJ UN` := CONVERSION_FACTOR * OBS_VALUE]
balance[, `TJ diff` := TJ - `TJ UN`]
balance[, PJ := TJ / 1000]
balance[, `PJ UN` := `TJ UN` / 1000]
balance[, io := fifelse(is.na(TJ), "NIGO", fifelse(TJ >= 0, "out", "in"))]
balance[, From := paste0(COMMODITY_ORIGINAL, TRANSACTION)]

# =========================================================
# BALANCE FINAL SCHEMA BEFORE TRANSFORMATIONS
# =========================================================

base_cols <- c(
  "NCV-ID",
  "REF_AREA",
  "TRANSACTION",
  "Transaction name",
  "Transaction description",
  "ProdCode",
  "COMMODITY",
  "DATAFLOW",
  "FREQ",
  "COMMODITY_ORIGINAL",
  "TIME_PERIOD",
  "OBS_VALUE",
  "UNIT_MULT",
  "UNIT_MEASURE",
  "OBS_STATUS",
  "CONVERSION_FACTOR",
  "Year",
  "Product",
  "Source type",
  "UNSD NCV (TJ/kt)",
  "DNI UNSD Production",
  "UNSD production recoding",
  "UNSD receipts recoding",
  "TRANSACTION_ORIGINAL",
  "MERGE category",
  "Combustible plant",
  "NCV type",
  "Balance type",
  "Sign",
  "DNI",
  "OBS_VALUE_PREV",
  "ISO3",
  "Factor to TJE",
  "NCV (TJ/kt)",
  "NCV_SOURCE",
  "TJ",
  "TJ UN",
  "TJ diff",
  "PJ",
  "PJ UN",
  "io",
  "From",
  "Commodity to",
  "Transaction to",
  "Multiplier",
  "cto",
  "tto"
)

for (nm in setdiff(base_cols, names(balance))) {
  balance[, (nm) := NA]
}

balance <- balance[, ..base_cols]

# =========================================================
# TRANSFORMATIONS (PQ-equivalent, no persistent objects)
# =========================================================

commodity_transformations <- merge(
  balance[, setdiff(names(balance), c("Multiplier", "cto", "tto", "Commodity to", "Transaction to")), with = FALSE],
  rules[, .(
    From,
    `Commodity to`,
    `Transaction to`,
    Multiplier,
    cto,
    tto
  )],
  by = "From",
  allow.cartesian = TRUE,
  sort = FALSE
)
  
# Scale energy (PQ behavior)
commodity_transformations[, TJ := fifelse(is.na(TJ), NA_real_, TJ * Multiplier)]
commodity_transformations[, PJ := fifelse(is.na(PJ), NA_real_, PJ * Multiplier)]
commodity_transformations[, `TJ UN` := fifelse(is.na(`TJ UN`), NA_real_, `TJ UN` * Multiplier)]
commodity_transformations[, `PJ UN` := fifelse(is.na(`PJ UN`), NA_real_, `PJ UN` * Multiplier)]
commodity_transformations[, `TJ diff` := fifelse(is.na(`TJ diff`), NA_real_, `TJ diff` * Multiplier)]

# Replace commodity + transaction
commodity_transformations[, COMMODITY := `Commodity to`]
commodity_transformations[, TRANSACTION := `Transaction to`]

# Remap ProdCode
commodity_transformations[, ProdCode := NULL]

commodity_transformations <- merge(
  commodity_transformations,
  prod_cleanup[, .(`Product Messy`, ProdCode)],
  by.x = "COMMODITY",
  by.y = "Product Messy",
  all.x = TRUE,
  sort = FALSE
)

commodity_transformations[, ProdCode := as.character(ProdCode)]

# Use rule labels (PQ behavior)
commodity_transformations[, Product := cto]
commodity_transformations[, `Transaction description` := tto]

# Recompute io only
commodity_transformations[, io := fifelse(
  is.na(Multiplier),
  "NIGO",
  fifelse(Multiplier < 0, "in", "out")
)]

# Align schema
for (nm in setdiff(base_cols, names(commodity_transformations))) {
  commodity_transformations[, (nm) := NA]
}

commodity_transformations <- commodity_transformations[, ..base_cols]


# =========================================================
# STACK
# =========================================================

UN_energy_stats_intermediate <- rbindlist(
  list(
    copy(balance)[, `Data source` := "Original"],
    copy(commodity_transformations)[, `Data source` := "Added"]
  ),
  use.names = TRUE,
  fill = TRUE
)

UN_energy_stats_intermediate[
  Product %in% c("Heat from combustible fuels", "Thermal electricity"),
  Product := fifelse(Product == "Thermal electricity", "Electricity", "Heat")
]

# =========================================================
# RAS
# remove main activity / autoproducer only at aggregated output stage
# keep detailed plant-fuel inputs
# =========================================================

ras_plant_inputs <- UN_energy_stats_intermediate[
  io == "in" &
    `MERGE category` %in% c("CHP plants", "Electricity plants", "Heat plants") &
    `Combustible plant` == "Yes" &
    TJ != 0
]

ras_plant_outputs <- UN_energy_stats_intermediate[
  io == "out" &
    `MERGE category` %in% c("CHP plants", "Electricity plants", "Heat plants") &
    `Combustible plant` == "Yes" &
    is.na(DNI) &
    TJ != 0
]

ras_fuel_outputs <- UN_energy_stats_intermediate[
  io == "out" &
    `Combustible plant` == "Yes" &
    DNI == "DNI" &
    TJ > 0
]

# =========================================================
# EXPORT
# =========================================================

fwrite(ras_fuel_outputs, "T:/Latest datasets/01.Raw data needing conversion/UN.Commodity balance/UN Commodity Balance Cleanup/ras_fuel_outputs.csv")

fwrite(ras_plant_inputs, "T:/Latest datasets/01.Raw data needing conversion/UN.Commodity balance/UN Commodity Balance Cleanup/ras_plant_inputs.csv")

fwrite(ras_plant_outputs, "T:/Latest datasets/01.Raw data needing conversion/UN.Commodity balance/UN Commodity Balance Cleanup/ras_plant_outputs.csv")

fwrite(UN_energy_stats_intermediate, "T:/Latest datasets/01.Raw data needing conversion/UN.Commodity balance/UN Commodity Balance Cleanup/UN_energy_stats_intermediate.csv")