The script processes **UN energy statistics commodity balance data** and converts it into a **cleaned, standardized, energy-valued intermediate dataset**, prepares three **RAS input tables**, and finally reconstructs a **complete energy balance** using RAS optimisation outputs.

It combines raw UN commodity balance data with several Excel lookup tables to:

- standardize products, transactions, units, and country codes,
- apply sign logic consistently (including commodity-level overrides),
- attach metadata and calorific values (NCVs),
- convert physical quantities into energy terms,
- generate additional transformed rows from rule-based mappings,
- prepare structured inputs for RAS optimisation,
- and rebuild a final consistent energy balance after optimisation.

---

## 1. Libraries

Three packages are used:

- **`data.table`** for fast joins, grouping, mutation, and export
- **`openxlsx2`** to read named Excel tables efficiently
- **`readxl`** for reading the UN NCV sheet

---

## 2. Helper Functions

### `read_excel_table(path, table_name)`

Reads a named Excel region and converts it into a `data.table`.

### `first_non_blank(x)`

Returns the first valid (non-empty, non-NA) value.

Used systematically to:

- prevent artificial data creation
- enforce deterministic lookup mappings
- avoid many-to-many joins

---

## 3. Input Data Loaded

The script loads **nine** source objects:

|Object|Purpose|
|---|---|
|`rules`|Commodity/transaction transformation rules|
|`sign_switch`|Commodity-transaction sign overrides|
|`prod_cleanup`|Product name → `ProdCode` mapping|
|`products`|Product metadata and NCVs|
|`transactions`|Transaction metadata and classification|
|`MERGE_processes`|Mapping to MERGE processes|
|`country_cleanup`|Country → ISO3 mapping|
|`countries`|ISO3 ↔ M49 reference|
|`UN_NCV`|Country-level NCV factors|
|`balance`|Raw UN commodity balance|

---

## 4. Type Stabilization

All tables are explicitly cast before any operations:

- keys → `character`
- values → `numeric`
- years → `integer`

This prevents silent join failures across heterogeneous sources.

---

## 5. Empty Row Removal

Rows with no meaningful content across key fields are removed.

This is distinct from removing zero flows (handled later).

---

## 6. Lookup Deduplication

All lookup tables are collapsed to **one row per key** using `first_non_blank()`.

This applies to:

- product mappings
- product metadata
- transactions
- countries
- NCV table
- MERGE process mapping

This guarantees:

- stable joins
- no unintended row duplication
- reproducible transformations

---

## 7. Rule Preparation

Transformation rules are prepared by defining:

- `From = Commodity_from + Transaction_from`
- `ID` = unique identifier

Duplicate rules are removed.

---

## 8. NCV Table Enrichment

The NCV table is enriched by:

1. mapping products → `ProdCode`
2. mapping countries → `ISO3`

A unique key is constructed:

NCV-ID = ISO3-Year-ProdCode-TypeCode

Only `(NCV-ID, Factor to TJE)` is retained.

---

## 9. Balance Preprocessing

Core cleaning steps:

- remove zero flows (`OBS_VALUE == 0`)
- normalize units (`TN → kt`, `M3 → kM3`)
- preserve original commodity (`COMMODITY_ORIGINAL`)
- override commodity for specific transactions (162, 1621, 1622 → "2000")
- create `Year`

---

## 10. Product and Transaction Enrichment

### Product mapping

- `COMMODITY → ProdCode`

### Product metadata

Adds:

- `Source type`
- `UNSD NCV`
- recoding fields

### Transaction metadata

Adds:

- `MERGE category`
- `Combustible plant`
- `NCV type`
- `Balance type`
- `Sign`
- `DNI UN Transaction`

### NCV type correction

Fixes inconsistencies for secondary products.

---

## 11. Sign Logic (Two Layers)

### Base sign (transaction level)

Sign == "Negative" → flip sign

### Commodity-level override

Using `sign_switch`:

key = COMMODITY_ORIGINAL + TRANSACTION

If matched:

- sign is flipped again
- `Rule` is updated
- `Data source = "Sign switch"`

---

## 12. Country and NCV Merge

- map `REF_AREA → ISO3`
- build `NCV-ID`
- merge NCV factors

---

## 13. NCV Selection Logic

Priority:

1. Hardcoded override (`113220 → 0.9`) To account for the conversion factor of 1 the UN uses, it should be 0.9 for natural gas to reflect the NCV.
2. UN `CONVERSION_FACTOR`. This is the official conversion factor from the UN.
3. Country NCV. Also official conversion factor from the UN but from a NCV dataset they provide separately. We use as a fallback.
4. Generic NCV. From thermodynamics/known NCVs if all else is missing.

`NCV_SOURCE` records which was used.

---

## 14. Energy Calculation

Compute:

- `TJ`, `PJ`
- `TJ UN`, `PJ UN`
- `TJ diff`

Define flow direction:

io = "out" if TJ ≥ 0  
io = "in"  if TJ < 0

---

## 15. Rule-Based Transformations

Rows are expanded using `rules`:

- join on `From`
- apply `Multiplier`
- replace `COMMODITY` and `TRANSACTION`

Then:

- metadata is refreshed
- product mapping is recomputed
- NCV key is rebuilt

This generates synthetic flows consistent with transformation logic.

---

## 16. Schema Enforcement

Both original and transformed datasets are forced into a common structure (`final_cols`).

Key groups:

- UN identifiers
- energy values
- NCV information
- diagnostics
- RAS fields
- traceability
- data source labels

---

## 17. Intermediate Dataset

UN_energy_stats_intermediate =  balance  + commodity_transformations

This is the **complete pre-RAS dataset**.

---

## 18. RAS Input Tables

Three subsets are extracted:

### `RAS_plant_inputs`

- plant fuel inputs

### `RAS_plant_outputs`

- electricity/heat outputs

### `RAS_fuel_outputs`

- aggregated fuel outputs requiring allocation

These feed the GAMS optimisation.

---

## 19. RAS Reconstruction
After running GAMS: allocated_output.csv is loaded and converted into full dataset format.

### Steps:

1. Rename columns:
    - `(iso, t, p1, f2, Val)` → structured fields
2. Compute:
    - `TJ`, `PJ`
3. Reattach:
    - country
    - product mapping
    - transaction metadata
4. Rebuild structural fields:
    - NCV fields
    - identifiers
    - metadata
5. Label:   Data source = "RAS optimisation"


---

## 20. Final Dataset

UN_energy_stats = UN_energy_stats_intermediate  + RAS_out

This is the **fully reconstructed energy balance**.

---

## 21. Export

The script exports:

### Intermediate

- `UN_energy_stats_intermediate.csv`

### RAS inputs

- `RAS_plant_inputs.csv`
- `RAS_plant_outputs.csv`
- `RAS_fuel_outputs.csv`

### Final

- `UN_energy_stats.csv`

---
# Flow Summary

Raw UN balance + Excel lookups  
        ↓  
Type stabilization  
        ↓  
Lookup deduplication  
        ↓  
Balance cleaning + enrichment  
        ↓  
Sign logic (transaction + commodity overrides)  
        ↓  
NCV selection + energy conversion  
        ↓  
Rule-based transformations  
        ↓  
Intermediate dataset  
        ↓  
RAS input extraction  
        ↓  
GAMS optimisation (external)  
        ↓  
RAS output reconstruction  
        ↓  
Final energy balance
