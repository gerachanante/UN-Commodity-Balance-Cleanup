# =========================================================
# LIBRARIES
# =========================================================

# data.table: high-performance data manipulation (fast joins, grouping, memory-efficient operations)
library(data.table)

# openxlsx2: efficient reading of Excel named ranges and tables (faster than readxl for structured tables)
library(openxlsx2)

# readxl: used here specifically for simple sheet reads (UN_NCV)
library(readxl)


# =========================================================
# HELPER FUNCTIONS
# =========================================================

# ---------------------------------------------------------
# read_excel_table
# ---------------------------------------------------------
#   Reads a named Excel table (named_region) and converts it into a data.table.
# ---------------------------------------------------------
read_excel_table <- function(path, table_name) {
  wb <- wb_load(path)                                  # Load entire workbook into memory
  as.data.table(wb_to_df(wb, named_region = table_name)) # Extract named table and convert to data.table
}

# ---------------------------------------------------------
# first_non_blank
# ---------------------------------------------------------
#   Returns the first non-empty, non-NA value in a vector.
#   Used for deduplication logic where multiple mappings exist but we want:
#     - no invented values
#     - only the first valid mapping
# ---------------------------------------------------------
first_non_blank <- function(x) {
  x <- as.character(x)      # Force character to avoid type inconsistencies
  x <- trimws(x)            # Remove leading/trailing whitespace
  x[x == ""] <- NA_character_  # Convert empty strings to NA
  y <- x[!is.na(x)]         # Keep only valid values
  if (length(y)) y[1] else NA_character_  # Return first valid or NA
}


# Output path for all generated CSVs
path_out <- "T:/Latest datasets/01.Raw data needing conversion/UN.Commodity balance/UN Commodity balance cleanup/"


# =========================================================
# LOAD INPUT DATA
# =========================================================

# Transformation rules: defines how UN balance rows are expanded into additional flows
rules           <- read_excel_table("T:/Indexes/UN.Energy data codes.xlsx", "Transformation")

# Sign switch: Defines commodity-transaction combinations that need a sign switch from the commodity balance
sign_switch     <- read_excel_table("T:/Indexes/UN.Energy data codes.xlsx", "Signswitch")

# Product cleanup mapping: messy UN product names -> standardized ProdCode
prod_cleanup    <- read_excel_table("T:/Indexes/IRENA.Codes.xlsx", "TechCleanup")

# Product master table: contains metadata like NCV, source type, recoding rules
products        <- read_excel_table("T:/Indexes/IRENA.Codes.xlsx", "Products")

# Transaction metadata: defines categories, sign conventions, plant types, etc.
transactions    <- read_excel_table("T:/Indexes/UN.Energy data codes.xlsx", "Transactions")

# MERGE process allocation table
MERGE_processes <- read_excel_table("T:/Indexes/UN.Energy data codes.xlsx", "MERGE_processes")

# Country mapping: UN country names -> ISO3 codes
country_cleanup <- read_excel_table("T:/Indexes/Countries.xlsx", "CountryCleanup")

# Country master file
countries <- read_excel_table("T:/Indexes/Countries.xlsx", "Countries")

# Country-specific NCV factors (higher priority than generic NCV)
UN_NCV  <- as.data.table(read_excel("T:/Latest datasets/UN.NCV.xlsx", sheet = "Long format"))

# Main UN energy balance dataset (raw input)
balance <- fread("T:/Latest datasets/UN.Commodity balance.csv", blank.lines.skip = TRUE)



# =========================================================
# TYPE STABILIZATION
# =========================================================
#   Force consistent types BEFORE any joins or logic.
#   Prevents silent join failures and numeric coercion bugs.

balance[, `:=`(
  REF_AREA          = as.character(REF_AREA),      # Country name
  TRANSACTION       = as.character(TRANSACTION),   # Transaction code
  COMMODITY         = as.character(COMMODITY),     # Commodity code
  UNIT_MEASURE      = as.character(UNIT_MEASURE),  # Unit (kt, m3, etc.)
  CONVERSION_FACTOR = as.numeric(CONVERSION_FACTOR), # UN-provided NCV
  OBS_VALUE         = as.numeric(OBS_VALUE),       # Observed value
  TIME_PERIOD       = as.integer(TIME_PERIOD)      # Year
)]

# Clean product mapping table
prod_cleanup[, `:=`(
  `Product Messy` = as.character(`Product Messy`),
  ProdCode        = as.character(as.integer(ProdCode)), # Force numeric -> character consistency
  Product         = as.character(Product)
)]

# Clean product metadata table
products[, `:=`(
  ProdCode                   = as.character(as.integer(ProdCode)),
  Product                    = as.character(Product),
  `Source type`              = as.character(`Source type`),
  `UNSD NCV (TJ/kt)`         = as.numeric(`UNSD NCV (TJ/kt)`),
  `DNI UNSD Production`      = as.character(`DNI UNSD Production`)
)]

# Clean transaction metadata
transactions[, `:=`(
  `Transaction code`  = as.character(`Transaction code`),
  `MERGE category`    = as.character(`MERGE category`),
  `Combustible plant` = as.character(`Combustible plant`),
  `NCV type`          = as.character(`NCV type`),
  Sign                = as.character(Sign),
  `DNI UN Transaction`= as.character(`DNI UN Transaction`)
)]

# Clean country mapping
country_cleanup[, `:=`(
  Name = as.character(Name),
  ISO3 = as.character(ISO3)
)]

# Clean country table
countries <- unique(countries[, .(
  ISO3 = as.character(ISO3),
  REF_AREA = as.character(M49)
)])

# Clean NCV table
UN_NCV[, `:=`(
  `Country Name`   = as.character(`Country Name`),
  `Product Name`   = as.character(`Product Name`),
  Year             = as.integer(Year),
  `Type Code`      = as.character(`Type Code`),
  `Factor to TJE`  = as.numeric(`Factor to TJE`)
)]

# Clean sign switch table
sign_switch[, `Commodity-transaction` := as.character(`Commodity-transaction`)]

# Clean MERGE process table
MERGE_processes[, `:=`(
  `Transaction code`        = as.character(`Transaction code`),
  `Commodity code`          = as.character(`Commodity code`),
  `Commodity-transaction`   = as.character(`Commodity-transaction`),
  Commodity                 = as.character(Commodity),
  `Transaction description` = as.character(`Transaction description`),
  `MERGE process`           = as.character(`MERGE process`)
)]

# =========================================================
# DROP COMPLETELY EMPTY ROWS
# =========================================================
# Removes rows that contain no meaningful information at all

balance <- balance[
  !(is.na(REF_AREA) &
      is.na(TRANSACTION) &
      is.na(COMMODITY) &
      is.na(TIME_PERIOD) &
      is.na(OBS_VALUE))
]


# =========================================================
# DEDUPLICATION OF LOOKUPS
# =========================================================
# Strategy:
#   - Keep only one mapping per key
#   - Do NOT fabricate values
#   - Always pick first valid entry

# Product cleanup deduplication
prod_cleanup <- prod_cleanup[
  ,
  .(
    ProdCode = first_non_blank(ProdCode),
    Product  = first_non_blank(Product)
  ),
  by = .(`Product Messy`)
]

# Product metadata deduplication
products <- products[
  ,
  .(
    Product                    = first_non_blank(Product),
    `Source type`              = first_non_blank(`Source type`),
    `UNSD NCV (TJ/kt)`         = suppressWarnings(as.numeric(first_non_blank(`UNSD NCV (TJ/kt)`))),
    `DNI UNSD Production`      = first_non_blank(`DNI UNSD Production`)
  ),
  by = .(ProdCode)
]

# Country deduplication
country_cleanup <- country_cleanup[
  !is.na(Name) & trimws(Name) != "",
  .(
    ISO3 = first_non_blank(ISO3)
  ),
  by = .(Name)
]

# Ensure required columns exist in transactions
if (!("Transaction description" %in% names(transactions))) {
  transactions[, `Transaction description` := Transaction]
}

if (!("Balance type" %in% names(transactions))) {
  transactions[, `Balance type` := NA_character_]
}

# Deduplicate transactions
transactions <- transactions[
  !is.na(`Transaction code`) & trimws(`Transaction code`) != "",
  .(
    `Transaction name`        = first_non_blank(if ("Transaction name" %in% names(.SD)) `Transaction name` else Transaction),
    `Transaction description` = first_non_blank(`Transaction description`),
    `Parent code`             = first_non_blank(`Parent code`),
    Parent                    = first_non_blank(Parent),
    `MERGE category`          = first_non_blank(`MERGE category`),
    `Combustible plant`       = first_non_blank(`Combustible plant`),
    `NCV type`                = first_non_blank(`NCV type`),
    `Balance type`            = first_non_blank(`Balance type`),
    Sign                      = first_non_blank(Sign),
    `DNI UN Transaction`      = first_non_blank(`DNI UN Transaction`)
  ),
  by = .(`Transaction code`)
]

# Deduplicate NCV
UN_NCV <- UN_NCV[
  ,
  .(`Factor to TJE` = suppressWarnings(as.numeric(first_non_blank(`Factor to TJE`)))),
  by = .(`Country Name`, `Product Name`, Year, `Type Code`)
]

# Deduplicate MERGE process mapping
MERGE_processes <- MERGE_processes[
  !is.na(`Commodity-transaction`) & trimws(`Commodity-transaction`) != "",
  .(
    `Transaction code`        = first_non_blank(`Transaction code`),
    `Commodity code`          = first_non_blank(`Commodity code`),
    Commodity                 = first_non_blank(Commodity),
    `Transaction description` = first_non_blank(`Transaction description`),
    `MERGE process`           = first_non_blank(`MERGE process`)
  ),
  by = .(`Commodity-transaction`)
]

# =========================================================
# RULE PREPARATION
# =========================================================

# Create join key (From) and unique ID for deduplication
rules[, `:=`(
  Multiplier = as.numeric(Multiplier),
  From       = paste0(`Commodity from`, `Transaction from`),
  ID         = paste0(`Commodity from`, `Transaction from`, `Commodity to`, `Transaction to`)
)]

# Remove duplicate rules
rules <- unique(rules, by = "ID")


# =========================================================
# NCV ENRICHMENT
# =========================================================

# Map products to ProdCode
UN_NCV <- merge(
  UN_NCV,
  prod_cleanup[, .(`Product Messy`, ProdCode)],
  by.x = "Product Name",
  by.y = "Product Messy",
  all.x = TRUE,
  sort = FALSE
)

# Map countries to ISO3
UN_NCV <- merge(
  UN_NCV,
  country_cleanup[, .(Name, ISO3)],
  by.x = "Country Name",
  by.y = "Name",
  all.x = TRUE,
  sort = FALSE
)

# Create unique NCV identifier
UN_NCV[, `NCV-ID` := paste(ISO3, Year, ProdCode, `Type Code`, sep = "-")]

# Keep only required columns
UN_NCV <- UN_NCV[, .(`NCV-ID`, `Factor to TJE`)]
UN_NCV <- unique(UN_NCV, by = "NCV-ID")


# =========================================================
# BALANCE PREPROCESSING
# =========================================================

# Remove zero flows
balance <- balance[OBS_VALUE != 0]

# Normalise units
balance[UNIT_MEASURE == "TN", UNIT_MEASURE := "kt"]
balance[UNIT_MEASURE == "M3", UNIT_MEASURE := "kM3"]

# Preserve original commodity
setnames(balance, "COMMODITY", "COMMODITY_ORIGINAL")

# Fix specific commodity inconsistencies
balance[, COMMODITY := fifelse(
  TRANSACTION %in% c("162", "1621", "1622"),
  "2000",
  COMMODITY_ORIGINAL
)]


balance[, Year := TIME_PERIOD]


# =========================================================
# PRODUCT + TRANSACTION ENRICHMENT
# =========================================================

# Map product codes
balance <- merge(
  balance,
  prod_cleanup[, .(`Product Messy`, ProdCode)],
  by.x = "COMMODITY",
  by.y = "Product Messy",
  all.x = TRUE,
  sort = FALSE
)

# Add product metadata
balance <- merge(
  balance,
  products,
  by = "ProdCode",
  all.x = TRUE,
  sort = FALSE
)

balance[, ProdCode := as.character(ProdCode)]

# Preserve original transaction
balance[, TRANSACTION_ORIGINAL := TRANSACTION]

# # Apply recoding rules
# balance[, TRANSACTION := fifelse(
#   TRANSACTION_ORIGINAL == "01" & !is.na(`UNSD production recoding`),
#   `UNSD production recoding`,
#   fifelse(
#     TRANSACTION_ORIGINAL == "022" & !is.na(`UNSD receipts recoding`),
#     `UNSD receipts recoding`,
#     TRANSACTION_ORIGINAL
#   )
# )]

# Remove invalid production rows
#balance <- balance[paste0(`DNI UNSD Production`, "-", TRANSACTION) != "DNI-01"]

# Add transaction metadata
balance <- merge(
  balance,
  transactions,
  by.x = "TRANSACTION",
  by.y = "Transaction code",
  all.x = TRUE,
  sort = FALSE
)

# Fix NCV type inconsistencies
balance[, `NCV type` := fifelse(
  `Source type` == "Secondary" & `NCV type` == "D",
  "C",
  `NCV type`
)]


# =========================================================
# SIGN + VALUE CORRECTIONS
# =========================================================

balance[, OBS_VALUE_PREV := OBS_VALUE]

# Base UN sign logic
balance[, OBS_VALUE := fifelse(
  TRANSACTION_ORIGINAL != TRANSACTION,
  OBS_VALUE_PREV,
  fifelse(Sign == "Negative", -OBS_VALUE_PREV, OBS_VALUE_PREV)
)]

# ---------------------------------------------------------
# CUSTOM SIGN SWITCH (Commodity-Transaction level)
# ---------------------------------------------------------

balance[, COMMODITY_ORIGINAL := as.character(COMMODITY_ORIGINAL)]
balance[, TRANSACTION := as.character(TRANSACTION)]

# Default
balance[, Rule := "Original"]

if ("Commodity from" %in% names(sign_switch) && "Transaction from" %in% names(sign_switch)) {
  
  sign_switch[, `:=`(
    `Commodity from`   = as.character(`Commodity from`),
    `Transaction from` = as.character(`Transaction from`)
  )]
  
  # Keys
  balance[, key := paste0(COMMODITY_ORIGINAL, TRANSACTION)]
  sign_switch[, key := paste0(`Commodity from`, `Transaction from`)]
  
  # Lookup = use the existing column (no reinvention)
  sign_switch_lookup <- unique(
    sign_switch[, .(key, Rule)],
    by = "key"
  )
  
  # Join
  balance <- merge(
    balance,
    sign_switch_lookup,
    by = "key",
    all.x = TRUE,
    suffixes = c("", "_ss"),
    sort = FALSE
  )
  
  # Apply sign switch ONLY where rule exists
  balance[!is.na(Rule_ss), `:=`(
    OBS_VALUE = -OBS_VALUE,
    Rule      = Rule_ss,
    `Data source` = "Sign switch"
  )]
  
  balance[, c("key","Rule_ss") := NULL]
}

balance[is.na(`Data source`), `Data source` := "Original"]


# =========================================================
# COUNTRY + NCV MERGE
# =========================================================

balance <- merge(
  balance,
  country_cleanup,
  by.x = "REF_AREA",
  by.y = "Name",
  all.x = TRUE,
  sort = FALSE
)

balance[, `NCV-ID` := paste(ISO3, Year, ProdCode, `NCV type`, sep = "-")]

balance <- merge(
  balance,
  UN_NCV,
  by = "NCV-ID",
  all.x = TRUE,
  sort = FALSE
)


# =========================================================
# NCV SELECTION LOGIC
# =========================================================
# Priority:
#   1. Hardcoded fixes
#   2. Conversion factor
#   3. Country NCV
#   4. Generic NCV

balance[, `NCV (TJ/kt)` := fifelse(
  ProdCode == "113220", 0.9,
    fifelse(
      !is.na(CONVERSION_FACTOR), CONVERSION_FACTOR,
        fifelse(
          !is.na(`Factor to TJE`), `Factor to TJE`,
          `UNSD NCV (TJ/kt)`
        )
      )
    )]

# Track NCV source for debugging
balance[, NCV_SOURCE := fifelse(
  ProdCode == "113220", "GENERIC_NCV",
    fifelse(
      !is.na(CONVERSION_FACTOR), "UN_CONVERSION_FACTOR",
      fifelse(
        !is.na(`Factor to TJE`), "COUNTRY_NCV",
        fifelse(!is.na(`UNSD NCV (TJ/kt)`), "GENERIC_NCV", "NONE")
      )
    )
  )]


# =========================================================
# ENERGY CALCULATION
# =========================================================

balance[, TJ := fifelse(NCV_SOURCE != "NONE", `NCV (TJ/kt)` * OBS_VALUE, NA_real_)]
balance[, `TJ UN` := CONVERSION_FACTOR * OBS_VALUE]
balance[, `TJ diff` := TJ - `TJ UN`]
balance[, PJ := TJ / 1000]
balance[, `PJ UN` := `TJ UN` / 1000]

# Flow direction
balance[, io := fifelse(is.na(TJ), "NIGO", fifelse(TJ >= 0, "out", "in"))]

# Rule join key
balance[, From := paste0(COMMODITY_ORIGINAL, TRANSACTION)]


# =========================================================
# TRANSFORMATIONS
# =========================================================

commodity_transformations <- merge(
  balance,
  rules[, .(
    From,
    `Commodity to`,
    `Transaction to`,
    Multiplier,
    cto,
    tto,
    Rule_transform = Rule
  )],
  by = "From",
  allow.cartesian = TRUE,
  sort = FALSE
)

# Rule assignment
commodity_transformations[, Rule := Rule_transform]
commodity_transformations[, Rule_transform := NULL]

# Scale flows
commodity_transformations[, TJ := TJ * Multiplier]
commodity_transformations[, PJ := PJ * Multiplier]
commodity_transformations[, `TJ UN` := `TJ UN` * Multiplier]
commodity_transformations[, `PJ UN` := `PJ UN` * Multiplier]
commodity_transformations[, `TJ diff` := `TJ diff` * Multiplier]


# Replace commodity/transaction
commodity_transformations[, COMMODITY := `Commodity to`]
commodity_transformations[, TRANSACTION := `Transaction to`]

# Remove outdated metadata
commodity_transformations[, c(
  "Transaction name","Transaction description","MERGE category",
  "Combustible plant","NCV type","Balance type","Sign","DNI UN Transaction"
) := NULL]

# Reattach correct metadata
commodity_transformations <- merge(
  commodity_transformations,
  transactions[, .(
    `Transaction code`,
    `MERGE category`,
    `Combustible plant`,
    `NCV type`,
    `Balance type`,
    Sign,
    `DNI UN Transaction`
  )],
  by.x = "TRANSACTION",
  by.y = "Transaction code",
  all.x = TRUE,
  sort = FALSE
)

# Remap products
commodity_transformations[, ProdCode := NULL]

commodity_transformations <- merge(
  commodity_transformations,
  prod_cleanup[, .(`Product Messy`, ProdCode)],
  by.x = "COMMODITY",
  by.y = "Product Messy",
  all.x = TRUE,
  sort = FALSE
)

commodity_transformations[, `NCV-ID` := paste(ISO3, Year, ProdCode, `NCV type`, sep = "-")]

# Change io where needed
commodity_transformations[COMMODITY == "8000" & TRANSACTION %in% c(
  "015GE","016GE","015GC","016GC", # geothermal
  "015ST","016ST" # solar thermal
  ), io := "in"]

commodity_transformations[COMMODITY == "9101" & TRANSACTION %in% c(
  "015NE","016NE","015NC","016NC","015NH","016NH" # nuclear
), io := "in"]


# ---------------------------------------------------------
# ENFORCE FINAL SCHEMA (BOTH TABLES)
# ---------------------------------------------------------

final_cols <- c(
  # UN base
  "DATAFLOW","FREQ","REF_AREA",
  "COMMODITY","TRANSACTION","TIME_PERIOD",
  "OBS_VALUE","UNIT_MULT","UNIT_MEASURE","OBS_STATUS","CONVERSION_FACTOR",
  # Keys
  "ISO3","Year","ProdCode","NCV type","NCV-ID",
  # Energy
  "TJ","PJ","io",
  # NCV inputs
  "Factor to TJE","UNSD NCV (TJ/kt)","NCV_SOURCE",
  # Diagnostics
  "TJ UN","TJ diff","PJ UN","OBS_VALUE_PREV",
  # RAS logic
  "MERGE category","Combustible plant","DNI UN Transaction",
  # Traceability
  "COMMODITY_ORIGINAL","TRANSACTION_ORIGINAL",
  # Optional
  "Data source","Rule"
)

# ---------------------------------------------------------
# ADD DATA SOURCE FIRST
# ---------------------------------------------------------

balance[is.na(`Data source`), `Data source` := "Original"]
commodity_transformations[, `Data source` := "Added"]

# ---------------------------------------------------------
# ENFORCE FINAL SCHEMA
# ---------------------------------------------------------

for (nm in setdiff(final_cols, names(balance))) {
  balance[, (nm) := NA]
}
balance <- balance[, ..final_cols]

for (nm in setdiff(final_cols, names(commodity_transformations))) {
  commodity_transformations[, (nm) := NA]
}
commodity_transformations <- commodity_transformations[, ..final_cols]

# =========================================================
# STACK ORIGINAL + TRANSFORMED
# =========================================================

UN_energy_stats_intermediate <- rbindlist(
  list(balance, commodity_transformations),
  use.names = TRUE,
  fill = TRUE
)


# =========================================================
# RAS INPUT PREPARATION
# =========================================================

RAS_plant_inputs <- UN_energy_stats_intermediate[
  io == "in" &
    `MERGE category` %in% c("CHP plants", "Electricity plants", "Heat plants") &
    `Combustible plant` == "Yes" &
    TJ != 0
]

RAS_plant_outputs <- UN_energy_stats_intermediate[
  io == "out" &
    TRANSACTION %in% c("015CC", "016CC", "015CE", "016CE", "015CH", "016CH") &
    TJ != 0
]

RAS_fuel_outputs <- UN_energy_stats_intermediate[
  io == "out" &
    `MERGE category` %in% c("Electricity and heat") &
    `Combustible plant` == "Yes" &
    `DNI UN Transaction` == "DNI" &
    TRANSACTION != "01SBF" &
    TJ > 0
]



# =========================================================
# EXPORT
# =========================================================

fwrite(RAS_fuel_outputs, paste0(path_out,"RAS_fuel_outputs.csv"))
fwrite(RAS_plant_inputs, paste0(path_out,"RAS_plant_inputs.csv"))
fwrite(RAS_plant_outputs, paste0(path_out,"RAS_plant_outputs.csv"))
fwrite(UN_energy_stats_intermediate, paste0(path_out,"UN_energy_stats_intermediate.csv"))


# =========================================================
# PART II. Complete energy balance rebuild
# =========================================================

# When updating power plant data or for new years of data, the RAS optimisation should be run in GAMS. 

# The output of the optimisation is what we will now import and append to the UN_energy_stats_intermediate to create a final UN_energy_stats file.

# RAS optimisation output. Load after running GAMS when updating data
RAS_out <- fread(file.path(path_out, "allocated_output.csv"))

# =========================================================
# RAS OUTPUT STANDARDISATION
# =========================================================

# The optimisation output only has a few columns. We recreate here the database columns before appending.
RAS_out <- RAS_out[
  , .(
    ISO3      = iso,
    Year      = t,
    `Transaction description` = p1,
    Product   = f2,
    OBS_VALUE = Val
  )
]

# Energy (already in TJ implicitly)
RAS_out[, `:=`(
  TJ = OBS_VALUE,
  PJ = OBS_VALUE / 1000
)]

# =========================================================
# JOIN LOOKUPS (REUSE SAME OBJECTS FROM MAIN SCRIPT)
# =========================================================

# Country lookup
RAS_out <- merge(
  RAS_out,
  countries[, .(ISO3, REF_AREA)],
  by = "ISO3",
  all.x = TRUE,
  sort = FALSE
)

# Product_cleanup → ProdCode
RAS_out <- merge(
  RAS_out,
  prod_cleanup[, .(`Product Messy`, ProdCode)],
  by.x = "Product",
  by.y = "Product Messy",
  all.x = TRUE,
  sort = FALSE
)

# Products → UNSD NCV
RAS_out <- merge(
  RAS_out,
  products[, .(ProdCode, `UNSD NCV (TJ/kt)`)],
  by = "ProdCode",
  all.x = TRUE,
  sort = FALSE
)

# Add Commodity code
RAS_out[ProdCode == "700000", COMMODITY := "7000"]
RAS_out[ProdCode == "800000", COMMODITY := "8000"]

# Transaction metadata
RAS_out <- merge(
  RAS_out,
  transactions[, .(
    `Transaction name`,
    `Transaction code`,
    `MERGE category`,
    `NCV type`
  )],
  by.x = "Transaction description",
  by.y = "Transaction name",
  all.x = TRUE,
  sort = FALSE
)

setnames(RAS_out, "Transaction code", "TRANSACTION")

# =========================================================
# STRUCTURAL FIELDS
# =========================================================

RAS_out[, `:=`(
  TIME_PERIOD         = Year,
  UNIT_MEASURE        = "TJ",
  CONVERSION_FACTOR   = NA_real_,
  OBS_VALUE_PREV      = NA_real_,
  COMMODITY_ORIGINAL  = COMMODITY,
  `Factor to TJE`     = NA_real_,
  `NCV (TJ/kt)`       = `UNSD NCV (TJ/kt)`,
  NCV_SOURCE          = "NONE",
  `NCV-ID`            = "NONE",
  OBS_STATUS          = "E",
  DATAFLOW            = "UNSD:DF_UNDATA_ENERGY(1.2)",
  FREQ                = "A",
  `TJ UN`             = NA_real_,
  UNIT_MULT           = 1L,
  `TJ diff`           = NA_real_,
  `PJ UN`             = NA_real_,
  `Data source`       = "RAS optimisation",
  Rule                = "RAS optimisation",
  io                  = "out"
)]


# ---------------------------------------------------------
# ENFORCE FINAL SCHEMA
# ---------------------------------------------------------

for (nm in setdiff(final_cols, names(RAS_out))) {
  RAS_out[, (nm) := NA]
}

RAS_out <- RAS_out[, ..final_cols]

# =========================================================
# FINAL STACK
# =========================================================

UN_energy_stats <- rbindlist(
  list(UN_energy_stats_intermediate, RAS_out),
  use.names = TRUE,
  fill = TRUE
)

# =========================================================
# EXPORT
# =========================================================

fwrite(
  UN_energy_stats,
  file.path(path_out, "UN_energy_stats.csv")
)
