* =============================================================================
* UN ENERGY BALANCE – POWER PLANT FUEL ALLOCATION MODEL
* =============================================================================
*
* PURPOSE
*   Reconciles three structurally inconsistent UN energy-balance datasets by
*   distributing plant-level fuel inputs across the plant-output and fuel-output
*   rows that those inputs plausibly produced. The allocation is framed as a
*   penalised linear programme whose seed (prior) is derived from reported
*   plant efficiencies, so the solver stays close to engineering reality while
*   satisfying every balance constraint exactly.
*
* DATASET STRUCTURE (three partially overlapping tables)
*   plant_input  (iso, t, p1, f)   – detailed process × fuel input rows
*   plant_output (iso, t, p2, f)   – aggregate plant-type × output rows
*   fuel_output  (iso, t, p3, f)   – aggregate fuel-bucket × output rows
*
* INDEX CONVENTION
*   p1  detailed plant process (fine disaggregation, source of input data)
*   p2  aggregate plant-output code (matches plant_output table)
*   p3  aggregate fuel-output bucket (matches fuel_output table)
*   f   energy commodity (fuel, electricity, heat, …)
*
* SOLVER CONFIGURATION
*   Uses CPLEX with IIS generation enabled for infeasibility diagnosis.
*   preind=0 disables pre-solving so that the IIS reflects the original model.
* =============================================================================

$onecho > cplex.opt
iis 1
preind 0
$offEcho

*------------------------------- FILES -------------------------------*
$set SetsData           sets-UNRAS.xlsm
$set ParameterData      parameters-UNRAS.xlsm

$set SetsGDX            sets.gdx
$set ParameterGDX       parameters.gdx
$set ResultsGDX         ras-results.gdx
$set ResultsXLSXpath    T:\Latest datasets\01.Raw data needing conversion\UN.Commodity balance\UN Commodity Balance Cleanup\

*------------------------------- SETS -------------------------------*
* All three plant families (electricity/CHP/heat) share the same set p.
* Membership in the sub-sets pe, pc, ph is derived from the pmap crosswalk
* loaded from Excel. fe and fh similarly restrict the commodity set to the
* two produced energy carriers.

Sets
    t          "model years"                              /1990*2023/
    iso        "ISO-3166-1 alpha-3 country codes"
    p          "UN transformation processes (all granularities)"
    f          "energy commodities"
        fe(f)  "electricity commodity"
        fh(f)  "heat commodity"
    pdesc      "process description labels (informational)"
    ptype      "process classification labels (e.g. Electricity plants)"
    pmap(p<,ptype<) "crosswalk: process → classification bucket"
        pe(p)  "electricity-only plants"
        pc(p)  "combined heat-and-power (CHP) plants"
        ph(p)  "heat-only plants"
;

Alias (p,p1,p2,p3,p1a,p2a,p3a);
Alias (f,f1,f2,f1a,ff);

Sets
    fuel_map(f1,p3)        "manually curated: which input fuel feeds which fuel-output bucket"
    plant_map(p1,p2,p3)    "manually curated: detailed plant → aggregate plant + fuel bucket"

    fuel_map_used(f1,p3)   "augmented fuel map (manual + data-inferred links)"
    plant_map_used(p1,p2,p3) "augmented plant map (manual + data-inferred links)"

    suggest_fuel_map(f1,p3)    "candidate new fuel-map links inferred from co-occurrence in data"
    suggest_plant_map(p1,p2,p3) "candidate new plant-map links inferred from co-occurrence in data"

    iso_t_active(iso,t)    "country-years with at least one non-zero observation in any table"

    allocation_domain(iso,t,p1,f1,p2,p3,f2) "feasible (input, output) pairs: passes fuel-map, plant-map, family and output-type filters. This is the active index set for all model variables."

    unsupported_plant_output(iso,t,p2,f2) "plant-output rows with no feasible allocation path"
    unsupported_fuel_output(iso,t,p3,f2)  "fuel-output rows with no feasible allocation path"
    plant_missing_output(iso,t,p1)        "plants that have input data but zero allocated output"

    iter "iteration counter for iterative map-augmentation loop" /i1*i10/
;

*------------------------------- SCALAR PENALTIES -------------------------------*
$onText
The objective is a weighted sum of soft-constraint violations.
The penalty hierarchy enforces a strict priority ordering without requiring a lexicographic solve: efficiency_excess >> plant_anchor >> seed_deviation.
Values are calibrated so that a 1-unit efficiency overrun costs more than any plausible seed deviation, preserving physical feasibility as the top priority.
$offText

Scalars
    penalty_weight_seed_deviation "weight on absolute deviation from the proportional seed allocation. Set low relative to the anchor so seed is only used as a tiebreaker."
    /1e5/
    penalty_weight_efficiency_excess "weight on slack above the thermodynamic output efficiency bound. Extremely large so that any efficiency violation is catastrophically penalised and effectively forbidden."
    /1e10/
    penalty_weight_plant_anchor "weight on deviation from the input-share-implied plant output target. Acts as a distributional prior: plants that consume more fuel should produce proportionally more output."
    /1e8/
    consistency_tolerance "numerical tolerance for post-solve balance checks (absolute units)."
    /1e-6/
;
*------------------------------- PARAMETERS -------------------------------*
Parameters
* --- Raw input data ----------------------------------------------------------
    plant_input(iso<,t,p1,f)   "detailed input rows: energy consumed by each plant process and fuel"
    plant_output(iso,t,p2,f)  "aggregate output rows: energy produced by each aggregate plant type"
    fuel_output(iso,t,p3,f)   "aggregate fuel-bucket rows: output attributed to each fuel bucket"
    max_efficiency(p)         "upper-bound efficiency by plant type from UN engineering assumptions"

* --- Derived totals ----------------------------------------------------------
    total_input(iso,t,p)              "summed absolute input across all fuels for one plant process"
    total_plant_output(iso,t,f)       "sum of plant_output values across all plant types by commodity"
    total_fuel_output(iso,t,f)        "sum of fuel_output values across all fuel buckets by commodity"

* --- Scaling -----------------------------------------------------------------
    fuel_output_scale(iso,t,f) "multiplicative scale applied to fuel_output to reconcile it with plant_output. Clamped to [0.2, 5] to prevent extreme corrections."
    fuel_output_balanced(iso,t,p3,f)  "fuel_output after reconciliation scaling"

* --- Efficiency bounds -------------------------------------------------------
    output_efficiency_upper_bound(p,f) "commodity-specific efficiency cap = min(1.1, max_efficiency × 1.2). The 20 % headroom accommodates rounding and reporting noise."
    total_output_efficiency_upper_bound(p) "plant-level aggregate efficiency cap. CHP is allowed up to 1.2 because combined heat + electricity can together exceed unity."

* --- Seed construction -------------------------------------------------------
    seed_total_output(iso,t,p1,f1,f2) "prior estimate of output f2 attributable to input f1 at plant p1, computed as |input| × max_efficiency with CHP split proportional to observed output shares."
    seed_allocated_output(iso,t,p1,f1,p2,p3,f2) "seed disaggregated to the full allocation domain: the total seed is distributed across (p2,p3) pairs in proportion to plant_output shares."
    seed_deviation_weight(iso,t,p1,f1,p2,p3,f2) "inverse-volume deviation weight with additive penalties for missing manual maps and structural-infeasibility fallbacks. Ensures that well-supported, high-volume cells are held closer to the seed."

* --- Plant output anchor targets --------------------------------------------
    seed_plant_output_target(iso,t,p1) "target total output for plant p1, computed as p1's share of family input × family total output. Used in the plant-anchor equations."
    plant_anchor_weight(iso,t,p1)  "relative anchor weight (currently uniform = 1)"
    plant_input_total(iso,t,p1)    "total combustible input by detailed plant"

* --- Post-solve summaries (populated after solve) ---------------------------
    plant_output_total(iso,t,p1)       "total allocated output by plant"
    plant_output_electricity(iso,t,p1) "allocated electricity output"
    plant_output_heat(iso,t,p1)        "allocated heat output"
    plant_efficiency_total(iso,t,p1)   "realised total efficiency"
    plant_efficiency_electricity(iso,t,p1) "realised electricity efficiency"
    plant_efficiency_heat(iso,t,p1)    "realised heat efficiency"

* --- Pre-solve diagnostics --------------------------------------------------
    pre_missing_plantmap_input(iso,t,p1,f1)      "=1 if detailed input process p1 has no plant_map entry"
    pre_missing_plantmap_output(iso,t,p2,f2)     "=1 if aggregate output p2 has no plant_map entry"
    pre_missing_plantmap_fuelbucket(iso,t,p3,f2) "=1 if fuel bucket p3 has no plant_map entry"

    pre_plantmap_support(iso,t,p2,f2)   "count of plant_map-supported input links for each plant output row"
    pre_fuelmap_support(iso,t,p3,f2)    "count of fuel_map-compatible links for each fuel output row"

    pre_domain_support_plant(iso,t,p2,f2) "count of full domain links for each plant output row"
    pre_domain_support_fuel(iso,t,p3,f2)  "count of full domain links for each fuel output row"

    pre_input_process_has_mapping(iso,t,p1,f1)  "number of plant_map rows reachable from this input"
    pre_output_process_has_mapping(iso,t,p2,f2) "number of plant_map rows feeding this output"

    pre_exact_support_plant(iso,t,p2,f2)  "support count using manual maps only (no augmentation)"
    pre_exact_support_fuel(iso,t,p3,f2)   "support count using manual maps only (no augmentation)"
    pre_used_support_plant(iso,t,p2,f2)   "support count using augmented maps"
    pre_used_support_fuel(iso,t,p3,f2)    "support count using augmented maps"

    pre_structural_infeasibility(iso,t,p2,p3,f2) "=1 when plant_output(p2) and fuel_output(p3) are both non-zero for the same output commodity f2 but no manual map exists that connects them via a consistent input row"

    suggest_plant_map_count(p1,p2,p3) "count of country-years supporting a new plant_map(p1,p2,p3)"
    suggest_fuel_map_count(f1,p3)     "count of country-years supporting a new fuel_map(f1,p3)"
    new_plant_rows(iter)              "new plant_map rows added per augmentation iteration"
    new_fuel_rows(iter)               "new fuel_map rows added per augmentation iteration"
    share_seed_deviation              "aggregate deviation share (populated post-solve)"
;


*------------------------------- LOAD DATA -------------------------------*
$call gdxxrw.exe i=%SetsData% o=%SetsGDX% Index=Summary!A15 maxDupeErrors=10 Acronyms=1 ALLUELS=Y
$call gdxxrw.exe i=%ParameterData% o=%ParameterGDX% Index=Summary!A15 maxDupeErrors=10 Acronyms=1 ALLUELS=Y squeeze=n

$onMultiR
$gdxLoad %SetsGDX% pmap
$gdxLoadAll %SetsGDX%
$offMulti

$onMultiR
$gdxLoadAll %ParameterGDX%
$offMulti

*------------------------------- CLASSIFY PLANTS AND FUELS -------------------------------*
* pe/pc/ph membership is derived from the pmap crosswalk so that adding new process codes in the Excel file automatically propagates here.

pe(p) = yes$[pmap(p,"Electricity plants")];
pc(p) = yes$[pmap(p,"CHP plants")];
ph(p) = yes$[pmap(p,"Heat plants")];
fe(f) = yes$[sameas(f,"Electricity")];
fh(f) = yes$[sameas(f,"Heat")];


*------------------------------- ACTIVE COUNTRY-YEAR PAIRS -------------------------------*
* A country-year is active if at least one non-zero value appears in any of the three input tables. This guards against solving empty sub-problems.

iso_t_active(iso,t) = (
      sum((p1,f), abs(plant_input(iso,t,p1,f)))
    + sum((p2,f), abs(plant_output(iso,t,p2,f)))
    + sum((p3,f), abs(fuel_output(iso,t,p3,f)))
) gt 0;

*------------------------------- TOTALS AND FUEL-OUTPUT RECONCILIATION SCALING -------------------------------*
* The UN reports plant_output and fuel_output independently; they are
* conceptually the same quantity but often differ numerically. We scale
* fuel_output toward plant_output with a clamp of [0.2, 5] to avoid
* extreme distortions while still reconciling obvious unit discrepancies.

total_input(iso,t,p1)$iso_t_active(iso,t) = sum(f, abs(plant_input(iso,t,p1,f)));
total_plant_output(iso,t,f)$iso_t_active(iso,t) = sum(p2, plant_output(iso,t,p2,f));
total_fuel_output(iso,t,f)$iso_t_active(iso,t)  = sum(p3, fuel_output(iso,t,p3,f));

* Default scale = 1 (no adjustment)
fuel_output_scale(iso,t,f) = 1;

fuel_output_scale(iso,t,f)$[
       iso_t_active(iso,t)
   and (total_plant_output(iso,t,f) gt 1e-9)
   and (total_fuel_output(iso,t,f)  gt 1e-9)
] = min(5, max(0.2,
        total_plant_output(iso,t,f)/total_fuel_output(iso,t,f)
    ));

fuel_output_balanced(iso,t,p3,f) = fuel_output(iso,t,p3,f)*fuel_output_scale(iso,t,f);

*------------------------------- PHYSICAL BOUNDS -------------------------------*
* Upper bounds are set 20 % above the engineering maximum to allow for
* reporting noise and gross-to-net differences, while the extreme penalty on
* v_efficiency_excess ensures the bound is effectively binding.

output_efficiency_upper_bound(p,f) = 0;
total_output_efficiency_upper_bound(p) = 0;

* Electricity plants: only electricity output counts
output_efficiency_upper_bound(p,f)$[(pe(p) and fe(f)) or (pc(p) and fe(f))] =
    min(1.1, max_efficiency(p)*1.2);
* Heat plants: only heat output counts
output_efficiency_upper_bound(p,f)$[ph(p) and fh(f)] =
    min(1.1, max_efficiency(p)*1.2);

* Aggregate caps by plant family
total_output_efficiency_upper_bound(p)$pe(p) = min(1.1, max_efficiency(p)*1.2);
total_output_efficiency_upper_bound(p)$ph(p) = min(1.1, max_efficiency(p)*1.2);
total_output_efficiency_upper_bound(p)$pc(p) = 1.2;  


*------------------------------- DATA-IMPLIED MAP AUGMENTATION -------------------------------*
* The augmented maps start identical to the manual maps. The suggestion sets
* and counters are zeroed here; iterative augmentation (not yet active) would
* expand them based on data co-occurrence evidence.

plant_map_used(p1,p2,p3) = plant_map(p1,p2,p3);
fuel_map_used(f1,p3)     = fuel_map(f1,p3);

suggest_plant_map(p1,p2,p3) = no;
suggest_fuel_map(f1,p3)     = no;
suggest_plant_map_count(p1,p2,p3) = 0;
suggest_fuel_map_count(f1,p3)     = 0;
new_plant_rows(iter) = 0;
new_fuel_rows(iter)  = 0;

*------------------------------- PRE-SOLVE DIAGNOSTICS -------------------------------*
$onText
These parameters characterise the mapping coverage BEFORE the solve.
They drive two decisions:
    (a) which rows should trigger the local structural-infeasibility repair, and
    (b) which map additions are most urgently needed (post-solve prioritisation).
$offText

* --- Coverage flags ---------------------------------------------------------
pre_missing_plantmap_input(iso,t,p1,f1)$[plant_input(iso,t,p1,f1)] =
    1$[not sum((p2,p3)$plant_map(p1,p2,p3), 1)];

pre_missing_plantmap_output(iso,t,p2,f2)$[plant_output(iso,t,p2,f2)] =
    1$[not sum((p1,p3)$plant_map(p1,p2,p3), 1)];

pre_missing_plantmap_fuelbucket(iso,t,p3,f2)$[abs(fuel_output_balanced(iso,t,p3,f2))] =
    1$[not sum((p1,p2)$plant_map(p1,p2,p3), 1)];

* --- Mapping-support counts -------------------------------------------------
pre_input_process_has_mapping(iso,t,p1,f1)$[plant_input(iso,t,p1,f1)] =
    sum((p2,p3)$plant_map(p1,p2,p3), 1);

pre_output_process_has_mapping(iso,t,p2,f2)$[plant_output(iso,t,p2,f2)] =
    sum((p1,p3)$plant_map(p1,p2,p3), 1);

pre_plantmap_support(iso,t,p2,f2)$[plant_output(iso,t,p2,f2)] =
    sum((p1,f1,p3)$[
           plant_input(iso,t,p1,f1)
       and plant_map(p1,p2,p3)
       and ((fe(f2) and (pe(p2) or pc(p2))) or (fh(f2) and (ph(p2) or pc(p2))))
    ], 1);

pre_fuelmap_support(iso,t,p3,f2)$[abs(fuel_output_balanced(iso,t,p3,f2))] =
    sum((p1,f1,p2)$[
           plant_input(iso,t,p1,f1)
       and plant_output(iso,t,p2,f2)
       and plant_map(p1,p2,p3)
       and fuel_map(f1,p3)
       and ((fe(f2) and (pe(p2) or pc(p2))) or (fh(f2) and (ph(p2) or pc(p2))))
    ], 1);

* --- Exact (manual-map-only) support ----------------------------------------
pre_exact_support_plant(iso,t,p2,f2)$[plant_output(iso,t,p2,f2)] =
    sum((p1,f1,p3)$[
           plant_input(iso,t,p1,f1)
       and (abs(fuel_output_balanced(iso,t,p3,f2)) gt 0)
       and plant_map(p1,p2,p3) and fuel_map(f1,p3)
       and ((fe(f2) and (pe(p2) or pc(p2)) and (pe(p1) or pc(p1)))
         or (fh(f2) and (ph(p2) or pc(p2)) and (ph(p1) or pc(p1))))
    ], 1);

pre_exact_support_fuel(iso,t,p3,f2)$[(abs(fuel_output_balanced(iso,t,p3,f2)) gt 0)] =
    sum((p1,f1,p2)$[
           plant_input(iso,t,p1,f1)
       and plant_output(iso,t,p2,f2)
       and plant_map(p1,p2,p3) and fuel_map(f1,p3)
       and ((fe(f2) and (pe(p2) or pc(p2)) and (pe(p1) or pc(p1)))
         or (fh(f2) and (ph(p2) or pc(p2)) and (ph(p1) or pc(p1))))
    ], 1);

* --- Augmented-map support --------------------------------------------------
pre_used_support_plant(iso,t,p2,f2)$[plant_output(iso,t,p2,f2)] =
    sum((p1,f1,p3)$[
           plant_input(iso,t,p1,f1)
       and (abs(fuel_output_balanced(iso,t,p3,f2)) gt 0)
       and plant_map_used(p1,p2,p3) and fuel_map_used(f1,p3)
       and ((fe(f2) and (pe(p2) or pc(p2)) and (pe(p1) or pc(p1)))
         or (fh(f2) and (ph(p2) or pc(p2)) and (ph(p1) or pc(p1))))
    ], 1);

pre_used_support_fuel(iso,t,p3,f2)$[(abs(fuel_output_balanced(iso,t,p3,f2)) gt 0)] =
    sum((p1,f1,p2)$[
           plant_input(iso,t,p1,f1)
       and plant_output(iso,t,p2,f2)
       and plant_map_used(p1,p2,p3) and fuel_map_used(f1,p3)
       and ((fe(f2) and (pe(p2) or pc(p2)) and (pe(p1) or pc(p1)))
         or (fh(f2) and (ph(p2) or pc(p2)) and (ph(p1) or pc(p1))))
    ], 1);

* --- Structural infeasibility detector --------------------------------------
* A (p2,p3,f2) triple is structurally infeasible when both plant and fuel
* output are non-zero but no manual-map chain connects an input to both.
* The local repair in SECTION 12 then allows any same-family input to cover
* this triple, with a large seed-deviation penalty as a deterrent.

pre_structural_infeasibility(iso,t,p2,p3,f2)$[
       iso_t_active(iso,t)
   and plant_output(iso,t,p2,f2)
   and (abs(fuel_output_balanced(iso,t,p3,f2)) gt 0)
   and not sum((p1,f1)$[
           plant_input(iso,t,p1,f1)
       and plant_map(p1,p2,p3) and fuel_map(f1,p3)
       and ((pe(p1) and pe(p2)) or (pc(p1) and pc(p2)) or (ph(p1) and ph(p2)))
       and ((fe(f2) and (pe(p1) or pc(p1))) or (fh(f2) and (ph(p1) or pc(p1))))
   ], 1)
] = 1;


*------------------------------- ALLOCATION DOMAIN -------------------------------*
$onText
The domain is the feasible set for v_allocated_output. A cell is admitted when ALL of the following hold simultaneously:
    1. Country-year is active.
    2. The target plant-output row is non-zero (something to explain).
    3. The target fuel-output row is non-zero after scaling.
    4. The input fuel f1 is linked to bucket p3 via fuel_map.
    5. Plant p1 and plant p2 belong to the same family (no cross-family flows).
    6. The output commodity f2 is compatible with the plant family (e.g. only electricity plants produce electricity).
    7. Either a manual plant_map supports the (p1,p2,p3) triple, OR the triple belongs to a structurally infeasible (p2,p3,f2) pair and p1 has input
    data (local structural-infeasibility repair).
$offText

allocation_domain(iso,t,p1,f1,p2,p3,f2)$[
       iso_t_active(iso,t)
   and plant_output(iso,t,p2,f2)
   and (abs(fuel_output_balanced(iso,t,p3,f2)) gt 0)
   and fuel_map(f1,p3)
   and ((pe(p1) and pe(p2)) or (pc(p1) and pc(p2)) or (ph(p1) and ph(p2)))
   and ((fe(f2) and (pe(p1) or pc(p1))) or (fh(f2) and (ph(p1) or pc(p1))))
   and (
          plant_map(p1,p2,p3)
       or (pre_structural_infeasibility(iso,t,p2,p3,f2) and plant_input(iso,t,p1,f1))
   )
] = yes;

* --- Domain support counts and unsupported-row flags -----------------------
pre_domain_support_plant(iso,t,p2,f2) = 0;
pre_domain_support_fuel(iso,t,p3,f2)  = 0;
unsupported_plant_output(iso,t,p2,f2) = no;
unsupported_fuel_output(iso,t,p3,f2)  = no;

pre_domain_support_plant(iso,t,p2,f2)$[plant_output(iso,t,p2,f2)] =
    sum((p1,f1,p3)$allocation_domain(iso,t,p1,f1,p2,p3,f2), 1);

pre_domain_support_fuel(iso,t,p3,f2)$[(abs(fuel_output_balanced(iso,t,p3,f2)) gt 0)] =
    sum((p1,f1,p2)$allocation_domain(iso,t,p1,f1,p2,p3,f2), 1);

unsupported_plant_output(iso,t,p2,f2)$[
       plant_output(iso,t,p2,f2)
   and not pre_domain_support_plant(iso,t,p2,f2)
] = yes;

unsupported_fuel_output(iso,t,p3,f2)$[
       (abs(fuel_output_balanced(iso,t,p3,f2)) gt 0)
   and not pre_domain_support_fuel(iso,t,p3,f2)
] = yes;

*------------------------------- PLANT INPUT TOTAL -------------------------------*
plant_input_total(iso,t,p1)$iso_t_active(iso,t) = sum(f, abs(plant_input(iso,t,p1,f)));

*------------------------------- SEED CONSTRUCTION -------------------------------*
* The seed is the Bayesian prior for the allocation. It answers: "if we knew
* nothing except efficiencies and total outputs, how would we distribute the
* inputs?"  The seed is then disaggregated across the allocation domain in
* proportion to observed plant_output shares.
*
* For CHP plants the seed output per commodity is further weighted by the
* observed family-level output mix (electricity vs heat), so that high-
* electricity-CHP countries naturally allocate more to electricity.

seed_total_output(iso,t,p1,f1,f2) = 0;

* Electricity plants produce only electricity
seed_total_output(iso,t,p1,f1,f2)$[plant_input(iso,t,p1,f1) and pe(p1) and fe(f2)] =
    abs(plant_input(iso,t,p1,f1))*max_efficiency(p1);

* Heat plants produce only heat
seed_total_output(iso,t,p1,f1,f2)$[plant_input(iso,t,p1,f1) and ph(p1) and fh(f2)] =
    abs(plant_input(iso,t,p1,f1))*max_efficiency(p1);

* CHP plants: split efficiency by observed electricity/heat mix
seed_total_output(iso,t,p1,f1,f2)$[plant_input(iso,t,p1,f1) and pc(p1) and (fe(f2) or fh(f2))] =
    abs(plant_input(iso,t,p1,f1))
 *max_efficiency(p1)
 *total_plant_output(iso,t,f2)
 /max(1e-9, sum(ff$[(fe(ff) or fh(ff))], total_plant_output(iso,t,ff)));

* --- Plant-output anchor targets -------------------------------------------
* Each plant's target output equals its share of family-level input times the
* family's total observed output. This preserves the relative scale of plants
* within a family while anchoring to the published aggregate.

seed_plant_output_target(iso,t,p1) = 0;

seed_plant_output_target(iso,t,p1)$[(total_input(iso,t,p1) gt 0) and pe(p1)] =
    total_input(iso,t,p1)
 /max(1e-9, sum(p1a$pe(p1a), total_input(iso,t,p1a)))
 *sum((p2,f2)$[pe(p2) and fe(f2)], plant_output(iso,t,p2,f2));

seed_plant_output_target(iso,t,p1)$[(total_input(iso,t,p1) gt 0) and ph(p1)] =
    total_input(iso,t,p1)
 /max(1e-9, sum(p1a$ph(p1a), total_input(iso,t,p1a)))
 *sum((p2,f2)$[ph(p2) and fh(f2)], plant_output(iso,t,p2,f2));

seed_plant_output_target(iso,t,p1)$[(total_input(iso,t,p1) gt 0) and pc(p1)] =
    total_input(iso,t,p1)
 /max(1e-9, sum(p1a$pc(p1a), total_input(iso,t,p1a)))
 *sum((p2,f2)$[pc(p2) and (fe(f2) or fh(f2))], plant_output(iso,t,p2,f2));

plant_anchor_weight(iso,t,p1) = 1;

* --- Disaggregate seed across allocation domain ----------------------------
seed_allocated_output(iso,t,p1,f1,p2,p3,f2) = 0;

seed_allocated_output(iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2) =
    seed_total_output(iso,t,p1,f1,f2)
 *plant_output(iso,t,p2,f2)
 /max(1e-9, sum((p2a,p3a)$allocation_domain(iso,t,p1,f1,p2a,p3a,f2), plant_output(iso,t,p2a,f2)));

* --- Seed deviation weights ------------------------------------------------
* Base weight = 1/max(10, seed value): large-seed cells are pulled less tightly
* toward the seed in absolute terms, maintaining scale invariance.
* Additive penalties for structural quality:
*   +100  missing manual plant_map (structure uncertain)
*   +50   missing manual fuel_map  (fuel routing uncertain)
*   +5000 structural-infeasibility fallback (should rarely be needed)

seed_deviation_weight(iso,t,p1,f1,p2,p3,f2) = 0;

seed_deviation_weight(iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2) =
    (1/max(10, abs(seed_allocated_output(iso,t,p1,f1,p2,p3,f2))))
 *(1
      + 100$[not plant_map(p1,p2,p3)]
      + 50$[not fuel_map(f1,p3)]
      + 5000$[pre_structural_infeasibility(iso,t,p2,p3,f2)]
    );

*------------------------------- EXPORT BEFORE-SOLVE PACKAGE -------------------------------*
execute_unload "data_input.gdx"

*------------------------------- VARIABLES -------------------------------*
Positive Variables
    v_allocated_output(iso,t,p1,f1,p2,p3,f2) "primary decision variable: energy flow attributed to input (p1,f1) and routed to output pair (p2,p3) as commodity f2 [same units as data]"
    v_seed_deviation(iso,t,p1,f1,p2,p3,f2) "absolute deviation of the allocation from the seed at cell level; used as L1 penalty slack (upper + lower triangle linearisation)"
    v_efficiency_excess(iso,t,p1) "slack above the total-output efficiency bound for plant p1; kept in the model so the LP is always feasible, but penalised very heavily so any positive value flags a data anomaly"
    v_plant_output_deviation(iso,t,p1) "absolute deviation from the plant-level anchor target; L1 penalty slack analogous to v_seed_deviation"
;

Variable z "weighted objective (minimise)";

* Warm start from seed
v_allocated_output.l(iso,t,p1,f1,p2,p3,f2)$[allocation_domain(iso,t,p1,f1,p2,p3,f2)] = seed_allocated_output(iso,t,p1,f1,p2,p3,f2);

*------------------------------- EQUATIONS -------------------------------*
Equations
    eq_plant_balance(iso,t,p2,f2) "exact closure on each plant-output row: allocated flows summed over all contributing inputs must equal the published plant_output value"
    eq_fuel_balance(iso,t,p3,f2) "exact closure on each fuel-output bucket: allocated flows summed over all contributing inputs must equal fuel_output_balanced"
    eq_total_output_efficiency_upper_bound(iso,t,p1) "total output ≤ thermodynamic cap × total input + slack; slack is penalised to enforce the bound softly"
    eq_seed_deviation_upper(iso,t,p1,f1,p2,p3,f2) "upper half of the L1-deviation linearisation: v – seed ≤ dev"
    eq_seed_deviation_lower(iso,t,p1,f1,p2,p3,f2) "lower half of the L1-deviation linearisation: seed – v ≤ dev"
    eq_plant_output_anchor_upper(iso,t,p1) "upper half of plant-anchor L1 linearisation: output – target ≤ dev"
    eq_plant_output_anchor_lower(iso,t,p1) "lower half of plant-anchor L1 linearisation: target – output ≤ dev"
    eq_objective "weighted sum of all soft-constraint violations (minimise)"
;

* --- Plant-output balance ---------------------------------------------------
eq_plant_balance(iso,t,p2,f2)$[plant_output(iso,t,p2,f2) and pre_domain_support_plant(iso,t,p2,f2)]..
    sum((p1,f1,p3)$allocation_domain(iso,t,p1,f1,p2,p3,f2), v_allocated_output(iso,t,p1,f1,p2,p3,f2)) =e= plant_output(iso,t,p2,f2);

* --- Fuel-output balance ----------------------------------------------------
eq_fuel_balance(iso,t,p3,f2)$[(abs(fuel_output_balanced(iso,t,p3,f2)) gt 0) and pre_domain_support_fuel(iso,t,p3,f2)]..
    sum((p1,f1,p2)$allocation_domain(iso,t,p1,f1,p2,p3,f2), v_allocated_output(iso,t,p1,f1,p2,p3,f2)) =e= fuel_output_balanced(iso,t,p3,f2);

* --- Efficiency upper bound -------------------------------------------------
eq_total_output_efficiency_upper_bound(iso,t,p1)$[(total_output_efficiency_upper_bound(p1) gt 0) and (total_input(iso,t,p1) gt 0)]..
    sum((f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2), v_allocated_output(iso,t,p1,f1,p2,p3,f2))
    =l= total_output_efficiency_upper_bound(p1)*total_input(iso,t,p1) + v_efficiency_excess(iso,t,p1);

* --- L1 seed-deviation linearisation ----------------------------------------
eq_seed_deviation_upper(iso,t,p1,f1,p2,p3,f2)$[allocation_domain(iso,t,p1,f1,p2,p3,f2)]..
    v_allocated_output(iso,t,p1,f1,p2,p3,f2) - seed_allocated_output(iso,t,p1,f1,p2,p3,f2) =l= v_seed_deviation(iso,t,p1,f1,p2,p3,f2);

eq_seed_deviation_lower(iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2)..
    seed_allocated_output(iso,t,p1,f1,p2,p3,f2) - v_allocated_output(iso,t,p1,f1,p2,p3,f2) =l= v_seed_deviation(iso,t,p1,f1,p2,p3,f2);

* --- L1 plant-anchor linearisation ------------------------------------------
eq_plant_output_anchor_upper(iso,t,p1)$[(total_input(iso,t,p1) gt 0) and (seed_plant_output_target(iso,t,p1) gt 0)]..
    sum((f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2), v_allocated_output(iso,t,p1,f1,p2,p3,f2)) - seed_plant_output_target(iso,t,p1)
    =l= v_plant_output_deviation(iso,t,p1);

eq_plant_output_anchor_lower(iso,t,p1)$[(total_input(iso,t,p1) gt 0) and (seed_plant_output_target(iso,t,p1) gt 0)]..
    seed_plant_output_target(iso,t,p1) - sum((f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2), v_allocated_output(iso,t,p1,f1,p2,p3,f2))
    =l= v_plant_output_deviation(iso,t,p1);

* --- Objective --------------------------------------------------------------
eq_objective..
    z =e=
* Term 1: seed deviation (low weight – tiebreaker between feasible solutions)
        penalty_weight_seed_deviation
      *sum((iso,t,p1,f1,p2,p3,f2)$[allocation_domain(iso,t,p1,f1,p2,p3,f2)], seed_deviation_weight(iso,t,p1,f1,p2,p3,f2)*v_seed_deviation(iso,t,p1,f1,p2,p3,f2))

* Term 2: plant-anchor deviation (medium weight – distributional fairness)
      + penalty_weight_plant_anchor
      *sum((iso,t,p1)$[(total_input(iso,t,p1) gt 0) and (seed_plant_output_target(iso,t,p1) gt 0)], plant_anchor_weight(iso,t,p1)*v_plant_output_deviation(iso,t,p1))

* Term 3: efficiency excess (very high weight – physical feasibility gate)
      + penalty_weight_efficiency_excess
      *sum((iso,t,p1)$[total_input(iso,t,p1) gt 0], 10*v_efficiency_excess(iso,t,p1));


*------------------------------- MODEL -------------------------------*
Model plant_allocation /All/;

*------------------------------- SOLVE -------------------------------*
plant_allocation.optfile = 1;

solve plant_allocation using lp minimizing z;

abort$(plant_allocation.modelstat <> 1)
    "Exact feasible allocation not found under current mapping support, scaled margins, and efficiency bounds.";

*------------------------------- POST-SOLVE PARAMETERS -------------------------------*
Parameters
* --- Primary outputs ---------------------------------------------------------
    post_out_allocated_output(iso,t,p1,f1,p2,p3,f2) "optimal allocated flow for each (input, output) combination"
    post_out_allocated_output_export(iso,t,p1,f2) "allocated output summed over intermediate indices for CSV export"
    post_out_plant_input_total(iso,t,p1)       "total input by plant (copy of plant_input_total)"
    post_out_plant_output_total(iso,t,p1)      "total allocated output by plant"
    post_out_plant_output_electricity(iso,t,p1) "allocated electricity output by plant"
    post_out_plant_output_heat(iso,t,p1)        "allocated heat output by plant"
    post_out_plant_efficiency_total(iso,t,p1)   "realised total efficiency"
    post_out_plant_efficiency_electricity(iso,t,p1) "realised electricity efficiency"
    post_out_plant_efficiency_heat(iso,t,p1)    "realised heat efficiency"
    post_out_share_seed_deviation               "share of allocation volume deviating from seed"

* --- Balance diagnostics (should all be ≈ 0 after solve) --------------------
    post_diag_check_plant_balance(iso,t,p2,f)  "residual: plant_output – allocated sum"
    post_diag_check_fuel_balance(iso,t,p3,f)   "residual: fuel_output_balanced – allocated sum"
    post_diag_check_global_balance(iso,t,f)    "difference between plant and fuel totals after scaling"

* --- Mapping quality diagnostics --------------------------------------------
    post_diag_manual_map_share(iso,t,p2,p3,f2) "share of allocated flow that used both manual plant_map and fuel_map"
    post_diag_augmented_map_share(iso,t,p2,p3,f2) "share of allocated flow relying on at least one non-manual map"
    post_diag_missing_manual_plant_map_flow(iso,t,p1,p2,p3,f2) "flow routed via a suggested (non-manual) plant_map link"
    post_diag_missing_manual_fuel_map_flow(iso,t,p1,f1,p3,f2) "flow routed via a suggested (non-manual) fuel_map link"
    post_diag_suggest_plant_map_priority(p1,p2,p3) "total flow supported by a suggested plant_map row (prioritisation)"
    post_diag_suggest_fuel_map_priority(f1,p3) "total flow supported by a suggested fuel_map row (prioritisation)"

* --- Efficiency diagnostics -------------------------------------------------
    post_diag_efficiency_excess(iso,t,p1)       "v_efficiency_excess.l value"
    post_diag_efficiency_excess_share(iso,t,p1) "excess relative to total input"
    post_diag_bound_total_output(iso,t,p1)      "hard RHS of efficiency bound without slack"
    post_diag_actual_total_output(iso,t,p1)     "actual total output entering efficiency bound"

* --- Seed deviation diagnostics ---------------------------------------------
    post_diag_seed_deviation_abs(iso,t,p1,f1,p2,p3,f2)     "absolute cell-level deviation from seed"
    post_diag_seed_deviation_weighted(iso,t,p1,f1,p2,p3,f2) "weighted cell-level deviation"
    post_diag_seed_deviation_by_plant(iso,t,p1)             "sum of deviations by detailed plant"
    post_diag_seed_deviation_by_output(iso,t,p2,p3,f2)      "sum of deviations by output pair"

* --- Flags and repair priorities --------------------------------------------
    post_diag_flag_high_efficiency(iso,t,p1) "non-zero if efficiency excess > 10 % of total input (data anomaly alert)"
    post_diag_flag_extreme_efficiency(iso,t,p1) "non-zero if realised total efficiency > 1.5 (extreme anomaly)"
    post_diag_flag_high_fallback(iso,t,p2,p3,f2) "non-zero if flow heavily relies on structural-infeasibility fallback"
    post_diag_flag_missing_output(iso,t,p1) "non-zero if plant has input but zero allocated output"
    post_diag_flag_augmented_mapping(iso,t,p2,p3,f2) "non-zero if any flow used a non-manual map; value = augmented share"
    post_diag_repair_priority_plantmap(p1,p2,p3) "priority score for curators adding a new plant_map row"
    post_diag_repair_priority_fuelmap(f1,p3) "priority score for curators adding a new fuel_map row"

* --- Scalar KPIs ------------------------------------------------------------
    post_kpi_total_seed_deviation        "total absolute deviation from seed across all cells"
    post_kpi_total_efficiency_excess     "total slack above efficiency bounds across all plants"
    post_kpi_total_fallback_share        "average share of flow using structural fallback"
    post_kpi_total_augmented_share       "average share of flow using any augmented map"
    post_kpi_total_manual_share          "average share of flow using manual maps only"
    post_kpi_objective_breakdown_seed    "objective contribution of seed-deviation term"
    post_kpi_objective_breakdown_efficiency "objective contribution of efficiency-excess term"
;

*------------------------------- OUTPUT/REPORTING -------------------------------*
* Primary outputs
post_out_allocated_output(iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2) =
    v_allocated_output.l(iso,t,p1,f1,p2,p3,f2);

post_out_allocated_output_export(iso,t,p1,f2) =
    sum((p2,f1,p3)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_out_plant_input_total(iso,t,p1) = total_input(iso,t,p1);
post_out_plant_output_total(iso,t,p1) = sum((f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2), post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));
post_out_plant_output_electricity(iso,t,p1) = sum((f1,p2,p3,f2)$[allocation_domain(iso,t,p1,f1,p2,p3,f2) and fe(f2)], post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));
post_out_plant_output_heat(iso,t,p1) = sum((f1,p2,p3,f2)$[allocation_domain(iso,t,p1,f1,p2,p3,f2) and fh(f2)], post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_out_plant_efficiency_total(iso,t,p1)$total_input(iso,t,p1) =
    post_out_plant_output_total(iso,t,p1)/total_input(iso,t,p1);
post_out_plant_efficiency_electricity(iso,t,p1)$total_input(iso,t,p1) =
    post_out_plant_output_electricity(iso,t,p1)/total_input(iso,t,p1);
post_out_plant_efficiency_heat(iso,t,p1)$total_input(iso,t,p1) =
    post_out_plant_output_heat(iso,t,p1)/total_input(iso,t,p1);

post_out_share_seed_deviation =
    sum((iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        v_seed_deviation.l(iso,t,p1,f1,p2,p3,f2))
 /max(1e-9,
        sum((iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
            abs(seed_allocated_output(iso,t,p1,f1,p2,p3,f2))));

* Balance diagnostics
post_diag_check_plant_balance(iso,t,p2,f2)$plant_output(iso,t,p2,f2) =
    plant_output(iso,t,p2,f2)
  - sum((p1,f1,p3)$allocation_domain(iso,t,p1,f1,p2,p3,f2), post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_diag_check_fuel_balance(iso,t,p3,f2)$abs(fuel_output_balanced(iso,t,p3,f2)) =
    fuel_output_balanced(iso,t,p3,f2)
  - sum((p1,f1,p2)$allocation_domain(iso,t,p1,f1,p2,p3,f2), post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_diag_check_global_balance(iso,t,f) =
    total_plant_output(iso,t,f) - sum(p3, fuel_output_balanced(iso,t,p3,f));

* Mapping quality
post_diag_manual_map_share(iso,t,p2,p3,f2)$[
       (abs(fuel_output_balanced(iso,t,p3,f2)) gt 0) and plant_output(iso,t,p2,f2)
] =
    sum((p1,f1)$[allocation_domain(iso,t,p1,f1,p2,p3,f2) and plant_map(p1,p2,p3) and fuel_map(f1,p3)],
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2))
 /max(1e-9, sum((p1,f1)$allocation_domain(iso,t,p1,f1,p2,p3,f2), post_out_allocated_output(iso,t,p1,f1,p2,p3,f2)));

post_diag_augmented_map_share(iso,t,p2,p3,f2)$[
       (abs(fuel_output_balanced(iso,t,p3,f2)) gt 0) and plant_output(iso,t,p2,f2)
] =
    sum((p1,f1)$[allocation_domain(iso,t,p1,f1,p2,p3,f2) and (not plant_map(p1,p2,p3) or not fuel_map(f1,p3))],
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2))
 /max(1e-9, sum((p1,f1)$allocation_domain(iso,t,p1,f1,p2,p3,f2), post_out_allocated_output(iso,t,p1,f1,p2,p3,f2)));

post_diag_missing_manual_plant_map_flow(iso,t,p1,p2,p3,f2)$[
       not plant_map(p1,p2,p3)
   and sum(f1$allocation_domain(iso,t,p1,f1,p2,p3,f2), 1)
] = sum(f1$allocation_domain(iso,t,p1,f1,p2,p3,f2), post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_diag_missing_manual_fuel_map_flow(iso,t,p1,f1,p3,f2)$[
       not fuel_map(f1,p3)
   and sum(p2$allocation_domain(iso,t,p1,f1,p2,p3,f2), 1)
] = sum(p2$allocation_domain(iso,t,p1,f1,p2,p3,f2), post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_diag_suggest_plant_map_priority(p1,p2,p3)$[not plant_map(p1,p2,p3)] =
    sum((iso,t,f1,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2), post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_diag_suggest_fuel_map_priority(f1,p3)$[not fuel_map(f1,p3)] =
    sum((iso,t,p1,p2,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2), post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

* Efficiency diagnostics
post_diag_efficiency_excess(iso,t,p1)$[total_input(iso,t,p1) gt 0] =
    v_efficiency_excess.l(iso,t,p1);
post_diag_efficiency_excess_share(iso,t,p1)$[total_input(iso,t,p1) gt 0] =
    v_efficiency_excess.l(iso,t,p1)/max(1e-9, total_input(iso,t,p1));
post_diag_bound_total_output(iso,t,p1)$[total_input(iso,t,p1) gt 0] =
    total_output_efficiency_upper_bound(p1)*total_input(iso,t,p1);
post_diag_actual_total_output(iso,t,p1)$[total_input(iso,t,p1) gt 0] =
    sum((f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2), post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

* Seed deviation diagnostics
post_diag_seed_deviation_abs(iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2) =
    v_seed_deviation.l(iso,t,p1,f1,p2,p3,f2);
post_diag_seed_deviation_weighted(iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2) =
    seed_deviation_weight(iso,t,p1,f1,p2,p3,f2)*v_seed_deviation.l(iso,t,p1,f1,p2,p3,f2);
post_diag_seed_deviation_by_plant(iso,t,p1) =
    sum((f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2), v_seed_deviation.l(iso,t,p1,f1,p2,p3,f2));
post_diag_seed_deviation_by_output(iso,t,p2,p3,f2) =
    sum((p1,f1)$allocation_domain(iso,t,p1,f1,p2,p3,f2), v_seed_deviation.l(iso,t,p1,f1,p2,p3,f2));

* Flags
post_diag_flag_high_efficiency(iso,t,p1)$[
       (total_input(iso,t,p1) gt 0)
   and (v_efficiency_excess.l(iso,t,p1) > 0.10*total_input(iso,t,p1))
] = v_efficiency_excess.l(iso,t,p1);

post_diag_flag_extreme_efficiency(iso,t,p1)$[
       (total_input(iso,t,p1) gt 0)
   and (post_out_plant_efficiency_total(iso,t,p1) > 1.5)
] = post_out_plant_efficiency_total(iso,t,p1);

plant_missing_output(iso,t,p1)$[
       (total_input(iso,t,p1) gt 0)
   and (post_out_plant_output_total(iso,t,p1) <= consistency_tolerance)
] = yes;

post_diag_flag_missing_output(iso,t,p1)$plant_missing_output(iso,t,p1)     = 1;
post_diag_flag_augmented_mapping(iso,t,p2,p3,f2)$[post_diag_augmented_map_share(iso,t,p2,p3,f2) gt 0] =
    post_diag_augmented_map_share(iso,t,p2,p3,f2);

post_diag_repair_priority_plantmap(p1,p2,p3)$[not plant_map(p1,p2,p3)] =
    post_diag_suggest_plant_map_priority(p1,p2,p3)
  + penalty_weight_efficiency_excess
 *sum((iso,t)$[total_input(iso,t,p1) gt 0], post_diag_efficiency_excess_share(iso,t,p1));

post_diag_repair_priority_fuelmap(f1,p3)$[not fuel_map(f1,p3)] =
    post_diag_suggest_fuel_map_priority(f1,p3);

* KPIs
post_kpi_total_seed_deviation =
    sum((iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        v_seed_deviation.l(iso,t,p1,f1,p2,p3,f2));

post_kpi_total_efficiency_excess =
    sum((iso,t,p1)$[total_input(iso,t,p1) gt 0], v_efficiency_excess.l(iso,t,p1));

post_kpi_total_augmented_share =
    sum((iso,t,p2,p3,f2), post_diag_augmented_map_share(iso,t,p2,p3,f2))
 /max(1e-9, sum((iso,t,p2,p3,f2), 1$[post_diag_augmented_map_share(iso,t,p2,p3,f2)]));

post_kpi_total_manual_share =
    sum((iso,t,p2,p3,f2), post_diag_manual_map_share(iso,t,p2,p3,f2))
 /max(1e-9, sum((iso,t,p2,p3,f2), 1$[post_diag_manual_map_share(iso,t,p2,p3,f2)]));

post_kpi_objective_breakdown_seed =
    penalty_weight_seed_deviation
 *sum((iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        seed_deviation_weight(iso,t,p1,f1,p2,p3,f2)
     *v_seed_deviation.l(iso,t,p1,f1,p2,p3,f2));

post_kpi_objective_breakdown_efficiency =
    penalty_weight_efficiency_excess
 *sum((iso,t,p1)$[total_input(iso,t,p1) gt 0], v_efficiency_excess.l(iso,t,p1));


*------------------------------- EXPORT -------------------------------*
execute_unload '%ResultsGDX%'
execute 'gdxdump %ResultsGDX% output="allocated_output.csv" symb=post_out_allocated_output_export format=csv';
execute 'gdxdump %ResultsGDX% output="allocated_output_full.csv" symb=post_out_allocated_output format=csv';
*$call gdxdump %ResultsGDX% output="%ResultsXLSXpath%allocated_output.csv" symb=post_out_allocated_output format=csv

*------------------------------- HARD POST-SOLVE CHECKS -------------------------------*
* These abort the run if any balance constraint was violated beyond the
* numerical tolerance, providing an unambiguous quality gate.

abort$(smax((iso,t,p2,f)$plant_output(iso,t,p2,f),
            abs(post_diag_check_plant_balance(iso,t,p2,f))) > consistency_tolerance)
    "Plant-output aggregation is not exact — check solver status and domain coverage.";

abort$(smax((iso,t,p3,f)$abs(fuel_output_balanced(iso,t,p3,f)),
            abs(post_diag_check_fuel_balance(iso,t,p3,f))) > consistency_tolerance)
    "Fuel-output aggregation is not exact — check solver status and domain coverage.";