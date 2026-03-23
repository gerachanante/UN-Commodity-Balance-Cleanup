The script processes **UN energy statistics commodity balance data** and converts it into a **cleaned, standardized, energy-valued intermediate dataset**, plus three **RAS input tables** used later to reconcile plant fuel inputs and plant energy outputs.

It combines raw UN commodity balance data with several Excel lookup tables to:

- standardize products, transactions, units, and country codes,
    
- apply sign logic consistently,
    
- attach metadata and calorific values,
    
- convert physical quantities into energy terms,
    
- generate additional transformed rows from rule-based commodity/transaction mappings,
    
- and export both the full intermediate dataset and the RAS subsets.
    

---

## 1. Libraries

Three packages are used:

- **`data.table`** for fast joins, grouping, mutation, and export
    
- **`openxlsx2`** to read named Excel tables efficiently
    
- **`readxl`** for reading the UN NCV sheet
    

---

## 2. Helper Functions

Two helper functions are defined.

### `read_excel_table(path, table_name)`

Reads a named Excel region/table and converts it into a `data.table`.

### `first_non_blank(x)`

Returns the first non-empty, non-`NA` value in a vector after trimming whitespace.

This is used in lookup-table deduplication so that:

- joins remain one-to-many or one-to-one,
    
- row explosion is avoided,
    
- and no fabricated values are introduced.
    

---

## 3. Input Data Loaded

The script loads **eight** source objects, not six:

|Object|File|Purpose|
|---|---|---|
|`rules`|`UN.Energy data codes.xlsx`|Commodity/transaction transformation rules|
|`sign_switch`|`UN.Energy data codes.xlsx`|Commodity-transaction pairs requiring sign reversal|
|`prod_cleanup`|`IRENA.Codes.xlsx`|Product name cleanup / mapping to standardized `ProdCode`|
|`products`|`IRENA.Codes.xlsx`|Product metadata, default NCVs, source type, recoding info|
|`transactions`|`UN.Energy data codes.xlsx`|Transaction metadata, categories, signs, plant logic, DNI flags|
|`country_cleanup`|`Countries.xlsx`|Country name to ISO3 mapping|
|`UN_NCV`|`UN.NCV.xlsx`|Country-year-product NCV factors|
|`balance`|`UN.Commodity balance.csv`|Raw UN commodity balance data|

---

## 4. Type Stabilization

All major tables are explicitly cast to stable types before any joins or calculations.

This includes:

- character coercion for keys and labels,
    
- numeric coercion for values and NCVs,
    
- integer coercion for years.
    

This step is critical because the pipeline merges data from CSV and multiple Excel sources, where silent type mismatches are otherwise common.

---

## 5. Removal of Empty Rows

Before deeper processing, the script removes rows from `balance` that are completely empty across the key identifying/value columns.

This is different from dropping zero-value rows:

- **empty rows** are removed first,
    
- **zero-value rows** are removed later in the balance preprocessing step.
    

---

## 6. Lookup Deduplication

Several lookup tables are collapsed so each key appears only once.

### `prod_cleanup`

Deduplicated by `Product Messy`, keeping the first valid:

- `ProdCode`
    
- `Product`
    

### `products`

Deduplicated by `ProdCode`, keeping the first valid:

- product label,
    
- source type,
    
- generic NCV,
    
- production DNI flag,
    
- production/receipts recoding fields
    

### `country_cleanup`

Deduplicated by country name.

### `transactions`

Deduplicated by transaction code after ensuring required columns exist:

- if `Transaction description` is missing, it is created
    
- if `Balance type` is missing, it is created as `NA`
    

Then the first valid metadata entry is kept for each transaction code.

### `UN_NCV`

Deduplicated by:

- country name,
    
- product name,
    
- year,
    
- type code
    

keeping the first valid NCV factor.

This keeps joins controlled and prevents accidental many-to-many merges.

---

## 7. Rule Preparation

The transformation rules table is prepared by creating:

- **`From`** = concatenation of `Commodity from` + `Transaction from`
    
- **`ID`** = unique rule identifier based on source and target commodity/transaction
    

`Multiplier` is converted to numeric, and duplicate rules are removed by `ID`.

This ensures that transformation expansion later is deterministic.

---

## 8. NCV Table Enrichment

The `UN_NCV` table is enriched in two steps:

1. Product names are mapped to `ProdCode` using `prod_cleanup`
    
2. Country names are mapped to `ISO3` using `country_cleanup`
    

Then a composite key is created:

- **`NCV-ID` = ISO3-Year-ProdCode-TypeCode**
    

Only `NCV-ID` and `Factor to TJE` are retained afterward.

This produces a clean keyed NCV table for later joining into the balance.

---

## 9. Balance Preprocessing

The raw balance undergoes several core cleaning steps.

### Zero rows are removed

Rows with `OBS_VALUE == 0` are dropped.

### Units are normalized

- `TN` → `kt`
    
- `M3` → `kM3`
    

### Original commodity is preserved

The original `COMMODITY` column is renamed to `COMMODITY_ORIGINAL`, and a new working `COMMODITY` column is created.

### Commodity override for transactions 162/1621/1622

For these transactions, commodity is forced to `2000`; otherwise it remains `COMMODITY_ORIGINAL`.

### Year field is created

`Year := TIME_PERIOD`

---

## 10. Product and Transaction Enrichment

### Product mapping

The current working `COMMODITY` is mapped to `ProdCode` through `prod_cleanup`.

### Product metadata

The balance is merged with `products`, adding:

- product label,
    
- source type,
    
- generic NCV,
    
- recoding fields,
    
- production DNI flags
    

### Original transaction is preserved

`TRANSACTION_ORIGINAL := TRANSACTION`


### Transaction metadata

The balance is then merged with `transactions`, adding fields such as:

- `MERGE category`
    
- `Combustible plant`
    
- `NCV type`
    
- `Balance type`
    
- `Sign`
    
- `DNI UN Transaction`
    

### NCV type correction

If:

- `Source type == "Secondary"`
    
- and `NCV type == "D"`
    

then `NCV type` is changed to `"C"`.

This fixes an inconsistency for secondary products.

---

## 11. Sign and Value Corrections

This is now a two-layer sign treatment.

### Step 1: preserve original observed value

`OBS_VALUE_PREV := OBS_VALUE`

### Step 2: apply base transaction sign logic

If the transaction has been recoded, keep the original sign.  
Otherwise:

- if `Sign == "Negative"`, multiply by `-1`
    
- else keep as-is
    

Since transaction recoding is currently disabled, this effectively means the sign is driven by transaction metadata.

### Step 3: apply custom sign-switch overrides

A second sign correction is applied for specific `COMMODITY_ORIGINAL + TRANSACTION` combinations listed in `sign_switch`.

If the pair appears in `sign_switch`, the sign is flipped again.

This is a new explicit layer in the latest code and should be treated as part of the core logic.

---

## 12. Country and NCV Merge

Country names are mapped to `ISO3` using `country_cleanup`.

Then the script creates:

- **`NCV-ID = ISO3-Year-ProdCode-NCV type`**
    

and joins the cleaned `UN_NCV` table back into the balance.

This attaches the country-specific NCV factor where available.

---

## 13. NCV Selection Logic

The script builds a priority order for choosing the NCV used for energy conversion.

### Priority order actually implemented now

1. **Hardcoded override** for `ProdCode == "113220"` → `0.9`
    
2. **UN `CONVERSION_FACTOR`** from the raw balance
    
3. **Country-specific NCV** from `UN_NCV`
    
4. **Generic product NCV** from `products`
    

If none are available, the NCV is effectively missing.

### `NCV_SOURCE`

A source label is recorded for traceability:

- `GENERIC_NCV`
    
- `UN_CONVERSION_FACTOR`
    
- `COUNTRY_NCV`
    
- `NONE`
    

Note that the hardcoded `113220` override is labeled as `GENERIC_NCV` in the current implementation.

---

## 14. Energy Calculation

Using the selected NCV, the script computes:

- **`TJ`** = selected NCV × `OBS_VALUE`
    
- **`TJ UN`** = `CONVERSION_FACTOR × OBS_VALUE`
    
- **`TJ diff`** = `TJ - TJ UN`
    
- **`PJ`** = `TJ / 1000`
    
- **`PJ UN`** = `TJ UN / 1000`
    

### Flow direction

The script derives an `io` direction:

- `out` if `TJ >= 0`
    
- `in` if `TJ < 0`
    
- `NIGO` if `TJ` is missing
    

### Rule join key

- **`From = COMMODITY_ORIGINAL + TRANSACTION`**
    

This is the key used to match balance rows to transformation rules.

---

## 15. Rule-Based Transformations

This is the row-expansion step where new flows are created.

The script merges the enriched balance with `rules` using `From`, allowing cartesian expansion where one source row matches multiple rules.

For each matched rule, a new row is generated.

### What is changed in transformed rows

- `COMMODITY` is replaced with `Commodity to`
    
- `TRANSACTION` is replaced with `Transaction to`
    
- energy values are scaled by `Multiplier`:
    
    - `TJ`
        
    - `PJ`
        
    - `TJ UN`
        
    - `PJ UN`
        
    - `TJ diff`
        

### Metadata refresh

Because the transaction changed, old transaction metadata is removed and rejoined from `transactions`.

### Product remapping

Since the commodity changed, `ProdCode` is dropped and rebuilt by remapping the new `COMMODITY` through `prod_cleanup`.

Then a new `NCV-ID` is created.

This step creates the synthetic rows that represent transformed energy flows, analogous to the earlier Power Query transformation logic.

---

## 16. Final Schema Enforcement

Before stacking the original and transformed data, both tables are forced into the same schema.

A fixed vector `final_cols` defines the final output structure, including:

- raw UN identifiers,
    
- keys,
    
- energy values,
    
- NCV information,
    
- diagnostics,
    
- RAS metadata,
    
- traceability fields,
    
- source labels
    

Missing columns are added as `NA` so that both tables can be row-bound cleanly.

### Source labeling

- original balance rows get `Data source = "Original"` and `Rule = "Original"`
    
- transformed rows get `Data source = "Added"`
    

---

## 17. Final Intermediate Table

The final main output is:

- **`UN_energy_stats_intermediate`**
    

This is built by stacking:

- the cleaned/enriched original balance rows
    
- the rule-generated transformed rows
    

using `rbindlist(..., use.names = TRUE, fill = TRUE)`.

---

## 18. RAS Subset Preparation

Three subsets are extracted from `UN_energy_stats_intermediate` for later RAS allocation logic.

### `ras_plant_inputs`

Fuel inputs going into combustible plants:

- `io == "in"`
    
- `MERGE category` in `CHP plants`, `Electricity plants`, `Heat plants`
    
- `Combustible plant == "Yes"`
    
- `TJ != 0`
    

### `ras_plant_outputs`

Explicit electricity/heat outputs from plant transactions:

- `io == "out"`
    
- `TRANSACTION` in `015CC`, `016CC`, `015CE`, `016CE`, `015CH`, `016CH`
    
- `TJ != 0`
    

### `ras_fuel_outputs`

Fuel-derived output rows that are positive, DNI-flagged, and need reconciliation:

- `io == "out"`
    
- `MERGE category == "Electricity and heat"`
    
- `Combustible plant == "Yes"`
    
- `DNI UN Transaction == "DNI"`
    
- `TRANSACTION != "01SBF"`
    
- `TJ > 0`
    

These are the three core inputs to the downstream plant-fuel allocation procedure.

---

## 19. Export

The script exports four CSV files to the staging folder:

- `ras_fuel_outputs.csv`
    
- `ras_plant_inputs.csv`
    
- `ras_plant_outputs.csv`
    
- `UN_energy_stats_intermediate.csv`
    

---

# Updated Flow Summary

Raw CSV + Excel lookups  
        ↓  
Type stabilization  
        ↓  
Drop empty rows  
        ↓  
Deduplicate lookup tables  
        ↓  
Prepare rules and NCV keys  
        ↓  
Clean balance (drop zeros, normalize units, commodity fixes)  
        ↓  
Map products and transactions  
        ↓  
Apply sign logic  
   - transaction sign metadata  
   - commodity-transaction sign_switch overrides  
        ↓  
Map ISO3 and NCVs  
        ↓  
Select NCV and compute TJ/PJ  
        ↓  
Apply transformation rules to generate added rows  
        ↓  
Standardize schema and stack original + added rows  
        ↓  
Extract RAS subsets  
        ↓  
Export CSVs
