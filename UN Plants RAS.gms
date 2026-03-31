* =============================================================================
* UN ENERGY BALANCE – POWER PLANT FUEL ALLOCATION MODEL
* =============================================================================
$onText
PURPOSE
  Reconciles three structurally inconsistent UN energy-balance datasets by
  distributing plant-level fuel inputs across the plant-output and fuel-output
  rows that those inputs plausibly produced. The allocation is framed as a
  penalised linear programme whose seed (prior) is derived from reported
  plant efficiencies, so the solver stays close to engineering reality while
  satisfying every balance constraint exactly.

DATASET STRUCTURE (three partially overlapping tables)
  plant_input  (iso, t, p1, f)   – detailed process × fuel input rows
  plant_output (iso, t, p2, f)   – aggregate plant-type × output rows
  fuel_output  (iso, t, p3, f)   – aggregate fuel-bucket rows

INDEX CONVENTION
  p1  detailed plant process (fine disaggregation, source of input data)
  p2  aggregate plant-output code (matches plant_output table)
  p3  aggregate fuel-output bucket (matches fuel_output table)
  f   energy commodity (fuel, electricity, heat, …)

SOLVER CONFIGURATION
  Uses CPLEX with IIS generation enabled for infeasibility diagnosis.
  preind=0 disables pre-solving so that the IIS reflects the original model.
$offText

$eolCom #
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
Sets
    t          "model years" /2000*2023/
    iso        "ISO-3166-1 alpha-3 country codes"
    p          "UN transformation processes (all granularities)"
    f          "energy commodities"
        fe(f)  "electricity commodity"
        fh(f)  "heat commodity"
    ptype      "process classification labels"
    pmap(p<,ptype<) "crosswalk: process → classification bucket"
        pe(p)  "electricity-only plants"
        pc(p)  "combined heat-and-power plants"
        ph(p)  "heat-only plants"
;

Alias (p,p1,p2,p3,p1a,p2a,p3a);
Alias (f,f1,f2,ff);

Sets
    fuel_map(f1,p3)        "manual map: input fuel → fuel-output bucket"
    plant_map(p1,p2,p3)    "manual map: detailed plant → aggregate plant + fuel-output bucket"

    iso_t_active(iso,t)    "country-years with at least one non-zero observation"

    allocation_domain(iso,t,p1,f1,p2,p3,f2) "feasible allocation cells"

    unsupported_plant_output(iso,t,p2,f2) "plant-output rows with no feasible allocation path"
    unsupported_fuel_output(iso,t,p3,f2)  "fuel-output rows with no feasible allocation path"
    plant_missing_output(iso,t,p1)        "plants with input but zero allocated output after solve"

*------------------------------- PRE-SOLVE  SETS -------------------------------*
    pre_raw_totals_mismatch(iso,t,f)       "raw plant totals and raw fuel totals differ"
    pre_scale_hits_lower_bound(iso,t,f)    "fuel-output scale factor hits lower clamp"
    pre_scale_hits_upper_bound(iso,t,f)    "fuel-output scale factor hits upper clamp"

    pre_plant_output_exceeds_feasible_energy(iso,t,p2,f2) "plant-output row exceeds same-family feasible energy"
    pre_fuel_output_exceeds_feasible_energy(iso,t,p3,f2)  "fuel-output row exceeds fuel-map feasible energy"

    pre_no_same_family_support(iso,t,p2,p3,f2)     "no same-family input support exists for this output pair"
    pre_missing_fuel_map_support(iso,t,p2,p3,f2)   "same-family support exists but no fuel_map route exists"
    pre_missing_plant_map_support(iso,t,p2,p3,f2)  "same-family and fuel_map support exist but no plant_map route exists"
    pre_disconnected_mapping_chain(iso,t,p2,p3,f2) "fuel_map and plant_map both exist separately but not on one consistent chain"

*------------------------------- POST-SOLVE  SETS -------------------------------*
    post_high_efficiency_slack(iso,t,p1)            "efficiency slack is materially positive"
    post_extreme_total_efficiency(iso,t,p1)         "realised total efficiency is implausibly high"
    post_non_manual_plant_map_used(iso,t,p2,p3,f2) "output pair receives flow through a non-manual plant_map route"
    post_heavy_structural_fallback_use(iso,t,p2,p3,f2) "output pair relies heavily on structural fallback"
    post_missing_output_after_solve(iso,t,p1)       "plant has input but zero allocated output after solve"

;


*------------------------------- SCALAR PENALTIES -------------------------------*
$onText
The objective is a weighted sum of soft-constraint violations, scaled to be as
dimensionless as possible so large countries / rows do not dominate purely due
to size.

Priority:
  1) fuel-balance mismatch should be very expensive
  2) efficiency violations should also be very expensive
  3) plant-output shortfall for active feasible plants should be strongly penalised
  4) plant-anchor deviations should guide distribution across plants
  5) seed deviations should only act as a tiebreaker
$offText

Scalars
    penalty_weight_seed_deviation      "weight on relative seed deviation" /1/
    penalty_weight_efficiency_excess   "weight on relative efficiency slack" /1e5/
    penalty_weight_plant_anchor        "weight on relative two-sided plant-anchor deviation" /5e4/
    penalty_weight_plant_shortfall     "weight on plant-output shortfall for active feasible plants" /5e5/
    consistency_tolerance              "numerical tolerance for post-solve balance checks (absolute units)" /1e-4/
    penalty_weight_fuel_balance        "weight on relative fuel-balance slack" /1e6/
    min_output_target_share            "minimum share of anchor target that an active feasible plant should deliver" /0.10/
;

*------------------------------- PARAMETERS -------------------------------*
Parameters

* --- Raw input data ----------------------------------------------------------*
    plant_input(iso<,t,p1,f)   "detailed input rows"
    plant_output(iso,t,p2,f)   "aggregate output rows"
    fuel_output(iso,t,p3,f)    "aggregate fuel-output rows"
    max_efficiency(p)          "upper-bound efficiency by plant type"

* --- Derived totals ----------------------------------------------------------*
    total_input(iso,t,p)        "summed absolute input across all fuels for one plant process"
    total_plant_output(iso,t,f) "sum of plant_output values across plant types by commodity"
    total_fuel_output(iso,t,f)  "sum of fuel_output values across fuel-output buckets by commodity"

* --- Scaling -----------------------------------------------------------------*
    fuel_output_scale(iso,t,f)       "multiplicative scale applied to fuel_output"
    fuel_output_balanced(iso,t,p3,f) "fuel_output after reconciliation scaling"

* --- Efficiency bounds -------------------------------------------------------*
    output_efficiency_upper_bound(p,f)     "commodity-specific efficiency cap"
    total_output_efficiency_upper_bound(p) "plant-level aggregate efficiency cap"

* --- Seed construction -------------------------------------------------------*
    seed_total_output(iso,t,p1,f1,f2)           "prior estimate of output attributable to an input row"
    seed_allocated_output(iso,t,p1,f1,p2,p3,f2) "seed disaggregated to the full allocation domain"
    seed_deviation_weight(iso,t,p1,f1,p2,p3,f2) "relative weight for seed deviation"

* --- Plant output anchor targets --------------------------------------------*
    seed_plant_output_target(iso,t,p1) "target total output for plant p1"
    min_output_target(iso,t,p1)        "conservative minimum output target for active feasible plant"
    plant_anchor_weight(iso,t,p1)      "relative anchor weight"
    plant_input_total(iso,t,p1)        "total input by detailed plant"

* --- Objective scaling factors ----------------------------------------------*
    scale_seed_dev(iso,t,p1)        "scale for relative seed deviation"
    scale_plant_anchor(iso,t,p1)    "scale for relative plant-anchor deviation"
    scale_plant_shortfall(iso,t,p1) "scale for relative plant shortfall"
    scale_fuel_balance(iso,t,p3,f2) "scale for relative fuel-balance slack"

* --- Pre-solve plant support -----------------------------------------------*
    pre_domain_count_input_plant(iso,t,p1) "number of feasible allocation cells reachable from active input plant p1"

* --- Post-solve structural fallback diagnostics -----------------------------*
    post_structural_fallback_output(iso,t,p2,p3,f2) "allocated output using structural fallback"
    post_total_pair_output(iso,t,p2,p3,f2)          "total allocated output for output pair"
    post_structural_fallback_share(iso,t,p2,p3,f2)  "share of pair output using structural fallback"

* --- Pre-solve support -------------------------------------------------------*
    pre_domain_support_plant_output(iso,t,p2,f2) "count of feasible allocation-domain links for a plant-output row"
    pre_domain_support_fuel_output(iso,t,p3,f2)  "count of feasible allocation-domain links for a fuel-output row"
    pre_structural_infeasibility(iso,t,p2,p3,f2) "1 if plant-output and fuel-output coexist but no manual full chain connects them"

* --- Minimal pre-solve diagnostics ------------------------------------------*
    pre_raw_total_gap(iso,t,f)            "raw plant total minus raw fuel total"
    pre_raw_total_gap_share(iso,t,f)      "raw gap relative to the larger raw total"
    pre_scale_factor(iso,t,f)             "fuel_output_scale on flagged rows"

    pre_plant_output_feasible_upper_bound(iso,t,p2,f2) "same-family feasible upper bound"
    pre_plant_output_feasible_gap(iso,t,p2,f2)         "plant-output excess above feasible upper bound"

    pre_fuel_output_feasible_upper_bound(iso,t,p3,f2)  "fuel-map feasible upper bound"
    pre_fuel_output_feasible_gap(iso,t,p3,f2)          "fuel-output excess above feasible upper bound"

    pre_fix_priority_fuel_map(f1,p3)     "ranked score for missing fuel_map rows"
    pre_fix_priority_plant_map(p1,p2,p3) "ranked score for missing plant_map rows"

    pre_check_data_plant(iso,t,p2,f2) "plant-output rows likely driven by source-data inconsistency"
    pre_check_data_fuel(iso,t,p3,f2)  "fuel-output rows likely driven by source-data inconsistency"

    pre_kpi_level_0 "count of level-0 s"
    pre_kpi_level_1 "count of level-1 s"
    pre_kpi_level_2 "count of level-2 s"

    pre_kpi_unsupported_plant_output "count of unsupported plant-output rows"
    pre_kpi_unsupported_fuel_output  "count of unsupported fuel-output rows"
    pre_kpi_check_data_plant         "count of plant-output rows flagged for data review"
    pre_kpi_check_data_fuel          "count of fuel-output rows flagged for data review"

* --- Post-solve outputs ------------------------------------------------------*
    post_out_allocated_output(iso,t,p1,f1,p2,p3,f2) "optimal allocated flow"
    post_out_allocated_output_export(iso,t,p1,f2)   "allocated output summed for export"
    post_out_plant_input_total(iso,t,p1)            "total input by plant"
    post_out_plant_output_total(iso,t,p1)           "total allocated output by plant"
    post_out_plant_output_electricity(iso,t,p1)     "allocated electricity output by plant"
    post_out_plant_output_heat(iso,t,p1)            "allocated heat output by plant"
    post_out_plant_efficiency_total(iso,t,p1)       "realised total efficiency"
    post_out_plant_efficiency_electricity(iso,t,p1) "realised electricity efficiency"
    post_out_plant_efficiency_heat(iso,t,p1)        "realised heat efficiency"
    post_out_share_seed_deviation                   "share of allocation volume deviating from seed"

* --- Post-solve diagnostics --------------------------------------------------*
    post_plant_balance_residual(iso,t,p2,f2) "plant-output residual after solve"
    post_fuel_balance_residual(iso,t,p3,f2)  "fuel-output residual after solve"
    post_global_balance_residual(iso,t,f)    "global plant total minus balanced fuel total residual"

    post_efficiency_slack(iso,t,p1)          "efficiency slack value"
    post_efficiency_slack_share(iso,t,p1)    "efficiency slack relative to total input"
    post_realised_total_efficiency(iso,t,p1) "realised total efficiency"

    post_kpi_level_3 "count of level-3 s"

    post_kpi_max_plant_balance_residual       "max absolute plant-balance residual"
    post_kpi_max_fuel_balance_residual        "max absolute fuel-balance residual"
    post_kpi_total_efficiency_slack           "total efficiency slack"
    post_kpi_total_structural_fallback_share  "share of allocated output using structural fallback"
    post_kpi_total_non_manual_plant_map_share "share of allocated output using non-manual plant_map"
    post_kpi_total_seed_deviation             "total absolute seed deviation"

    post_kpi_objective_seed_term         "objective contribution of seed deviation"
    post_kpi_objective_plant_anchor_term "objective contribution of plant anchor"
    post_kpi_objective_efficiency_term   "objective contribution of efficiency slack"

* --- Post-solve plant-use diagnostics ---------------------------------------*
    post_domain_count_input_plant(iso,t,p1) "number of feasible allocation cells reachable from active input plant p1"
    post_output_from_input_plant(iso,t,p1)  "total solved output allocated to input plant p1"

    post_missing_output_no_domain(iso,t,p1)  "active input plant has zero feasible allocation-domain support"
    post_missing_output_has_domain(iso,t,p1) "active input plant has feasible support but still receives zero solved output"

    post_kpi_missing_output_no_domain  "count of active input plants stranded by mappings / structure"
    post_kpi_missing_output_has_domain "count of active input plants ignored by the optimizer despite feasible support"
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
pe(p) = yes$[pmap(p,"Electricity plants")];
pc(p) = yes$[pmap(p,"CHP plants")];
ph(p) = yes$[pmap(p,"Heat plants")];
fe(f) = yes$[sameas(f,"Electricity")];
fh(f) = yes$[sameas(f,"Heat")];

*------------------------------- ACTIVE COUNTRY-YEAR PAIRS -------------------------------*
iso_t_active(iso,t) = (
      sum((p1,f), abs(plant_input(iso,t,p1,f)))
    + sum((p2,f), abs(plant_output(iso,t,p2,f)))
    + sum((p3,f), abs(fuel_output(iso,t,p3,f)))
) gt 0;

*------------------------------- TOTALS AND FUEL-OUTPUT RECONCILIATION SCALING -------------------------------*
total_input(iso,t,p1)$iso_t_active(iso,t)      = sum(f, abs(plant_input(iso,t,p1,f)));
total_plant_output(iso,t,f)$iso_t_active(iso,t) = sum(p2, plant_output(iso,t,p2,f));
total_fuel_output(iso,t,f)$iso_t_active(iso,t)  = sum(p3, fuel_output(iso,t,p3,f));

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
output_efficiency_upper_bound(p,f) = 0;
total_output_efficiency_upper_bound(p) = 0;

* Electricity plants and CHP electricity
output_efficiency_upper_bound(p,f)$[(pe(p) and fe(f)) or (pc(p) and fe(f))] =
    min(1.1, max_efficiency(p)*1.2);

* Heat plants only
output_efficiency_upper_bound(p,f)$[ph(p) and fh(f)] =
    min(1.1, max_efficiency(p)*1.2);

* Aggregate caps by plant family
total_output_efficiency_upper_bound(p)$pe(p) = min(1.1, max_efficiency(p)*1.2);
total_output_efficiency_upper_bound(p)$ph(p) = min(1.1, max_efficiency(p)*1.2);
total_output_efficiency_upper_bound(p)$pc(p) = 1.2;





*------------------------------- PRE-SOLVE DIAGNOSTICS -------------------------------*
$onText
Diagnostic ladder before the solve:

  LEVEL 0  raw totals / scale clamps
  LEVEL 1  physical feasibility
  LEVEL 2  mapping root cause
$offText

* --- Reset sparse  sets ------------------------------------------------*
pre_raw_totals_mismatch(iso,t,f) = no;
pre_scale_hits_lower_bound(iso,t,f) = no;
pre_scale_hits_upper_bound(iso,t,f) = no;

pre_plant_output_exceeds_feasible_energy(iso,t,p2,f2) = no;
pre_fuel_output_exceeds_feasible_energy(iso,t,p3,f2) = no;

pre_no_same_family_support(iso,t,p2,p3,f2) = no;
pre_missing_fuel_map_support(iso,t,p2,p3,f2) = no;
pre_missing_plant_map_support(iso,t,p2,p3,f2) = no;
pre_disconnected_mapping_chain(iso,t,p2,p3,f2) = no;

* --- Reset support parameters -----------------------------------------------*
pre_domain_support_plant_output(iso,t,p2,f2) = 0;
pre_domain_support_fuel_output(iso,t,p3,f2)  = 0;
pre_structural_infeasibility(iso,t,p2,p3,f2) = 0;

* ============================================================================
* LEVEL 0 — RAW TOTALS / SCALING
* ============================================================================

pre_raw_total_gap(iso,t,f)$[
       iso_t_active(iso,t)
   and abs(total_plant_output(iso,t,f) - total_fuel_output(iso,t,f)) gt consistency_tolerance
] =
    total_plant_output(iso,t,f) - total_fuel_output(iso,t,f);

pre_raw_total_gap_share(iso,t,f)$[
       iso_t_active(iso,t)
   and abs(total_plant_output(iso,t,f) - total_fuel_output(iso,t,f)) gt consistency_tolerance
] =
    (total_plant_output(iso,t,f) - total_fuel_output(iso,t,f))
 /max(1e-9, max(abs(total_plant_output(iso,t,f)), abs(total_fuel_output(iso,t,f))));

pre_raw_totals_mismatch(iso,t,f)$[
       iso_t_active(iso,t)
   and abs(total_plant_output(iso,t,f) - total_fuel_output(iso,t,f)) gt consistency_tolerance
] = yes;

pre_scale_hits_lower_bound(iso,t,f)$[
       iso_t_active(iso,t)
   and total_plant_output(iso,t,f) gt 0
   and total_fuel_output(iso,t,f) gt 0
   and fuel_output_scale(iso,t,f) le 0.2 + consistency_tolerance
] = yes;

pre_scale_hits_upper_bound(iso,t,f)$[
       iso_t_active(iso,t)
   and total_plant_output(iso,t,f) gt 0
   and total_fuel_output(iso,t,f) gt 0
   and fuel_output_scale(iso,t,f) ge 5 - consistency_tolerance
] = yes;

pre_scale_factor(iso,t,f)$[
       pre_scale_hits_lower_bound(iso,t,f)
    or pre_scale_hits_upper_bound(iso,t,f)
    or pre_raw_totals_mismatch(iso,t,f)
] = fuel_output_scale(iso,t,f);

* --- Plant-output feasible envelope -----------------------------------------*
pre_plant_output_exceeds_feasible_energy(iso,t,p2,f2)$[
       plant_output(iso,t,p2,f2)
   and (
        plant_output(iso,t,p2,f2)
        >
        sum(p1$[
               total_input(iso,t,p1) gt 0
           and (
                  (pe(p2) and pe(p1) and fe(f2))
               or (ph(p2) and ph(p1) and fh(f2))
               or (pc(p2) and pc(p1) and (fe(f2) or fh(f2)))
           )
        ],
            total_input(iso,t,p1)
           *(
                 output_efficiency_upper_bound(p1,f2)$[(pe(p2) and fe(f2)) or (ph(p2) and fh(f2))]
               + total_output_efficiency_upper_bound(p1)$[pc(p2) and pc(p1) and (fe(f2) or fh(f2))]
            )
        )
        + consistency_tolerance
   )
] = yes;

pre_plant_output_feasible_upper_bound(iso,t,p2,f2)$pre_plant_output_exceeds_feasible_energy(iso,t,p2,f2) =
    sum(p1$[
           total_input(iso,t,p1) gt 0
       and (
              (pe(p2) and pe(p1) and fe(f2))
           or (ph(p2) and ph(p1) and fh(f2))
           or (pc(p2) and pc(p1) and (fe(f2) or fh(f2)))
       )
    ],
        total_input(iso,t,p1)
       *(
             output_efficiency_upper_bound(p1,f2)$[(pe(p2) and fe(f2)) or (ph(p2) and fh(f2))]
           + total_output_efficiency_upper_bound(p1)$[pc(p2) and pc(p1) and (fe(f2) or fh(f2))]
        )
    );

pre_plant_output_feasible_gap(iso,t,p2,f2)$pre_plant_output_exceeds_feasible_energy(iso,t,p2,f2) =
    plant_output(iso,t,p2,f2)
  - pre_plant_output_feasible_upper_bound(iso,t,p2,f2);

* --- Fuel-output feasible envelope ------------------------------------------*
pre_fuel_output_exceeds_feasible_energy(iso,t,p3,f2)$[
       abs(fuel_output_balanced(iso,t,p3,f2)) gt 0
   and (
        abs(fuel_output_balanced(iso,t,p3,f2))
        >
        sum((p1,f1)$[
               plant_input(iso,t,p1,f1)
           and fuel_map(f1,p3)
           and ((fe(f2) and (pe(p1) or pc(p1))) or (fh(f2) and (ph(p1) or pc(p1))))
        ],
            abs(plant_input(iso,t,p1,f1))
           *(
                 output_efficiency_upper_bound(p1,f2)$[(pe(p1) and fe(f2)) or (ph(p1) and fh(f2))]
               + total_output_efficiency_upper_bound(p1)$[pc(p1) and (fe(f2) or fh(f2))]
            )
        )
        + consistency_tolerance
   )
] = yes;

pre_fuel_output_feasible_upper_bound(iso,t,p3,f2)$pre_fuel_output_exceeds_feasible_energy(iso,t,p3,f2) =
    sum((p1,f1)$[
           plant_input(iso,t,p1,f1)
       and fuel_map(f1,p3)
       and ((fe(f2) and (pe(p1) or pc(p1))) or (fh(f2) and (ph(p1) or pc(p1))))
    ],
        abs(plant_input(iso,t,p1,f1))
       *(
             output_efficiency_upper_bound(p1,f2)$[(pe(p1) and fe(f2)) or (ph(p1) and fh(f2))]
           + total_output_efficiency_upper_bound(p1)$[pc(p1) and (fe(f2) or fh(f2))]
        )
    );

pre_fuel_output_feasible_gap(iso,t,p3,f2)$pre_fuel_output_exceeds_feasible_energy(iso,t,p3,f2) =
    abs(fuel_output_balanced(iso,t,p3,f2))
  - pre_fuel_output_feasible_upper_bound(iso,t,p3,f2);

* ============================================================================
* LEVEL 2 — MAPPING ROOT CAUSE
* ============================================================================

pre_structural_infeasibility(iso,t,p2,p3,f2)$[
       iso_t_active(iso,t)
   and plant_output(iso,t,p2,f2)
   and abs(fuel_output_balanced(iso,t,p3,f2)) gt 0
   and not sum((p1,f1)$[
           plant_input(iso,t,p1,f1)
       and plant_map(p1,p2,p3)
       and fuel_map(f1,p3)
       and ((pe(p1) and pe(p2)) or (pc(p1) and pc(p2)) or (ph(p1) and ph(p2)))
       and ((fe(f2) and (pe(p1) or pc(p1))) or (fh(f2) and (ph(p1) or pc(p1))))
   ], 1)
] = 1;

pre_no_same_family_support(iso,t,p2,p3,f2)$[
       plant_output(iso,t,p2,f2)
   and abs(fuel_output_balanced(iso,t,p3,f2)) gt 0
   and not sum((p1,f1)$[
           plant_input(iso,t,p1,f1)
       and ((pe(p1) and pe(p2)) or (pc(p1) and pc(p2)) or (ph(p1) and ph(p2)))
       and ((fe(f2) and (pe(p1) or pc(p1))) or (fh(f2) and (ph(p1) or pc(p1))))
   ], 1)
] = yes;

pre_missing_fuel_map_support(iso,t,p2,p3,f2)$[
       plant_output(iso,t,p2,f2)
   and abs(fuel_output_balanced(iso,t,p3,f2)) gt 0
   and sum((p1,f1)$[
           plant_input(iso,t,p1,f1)
       and ((pe(p1) and pe(p2)) or (pc(p1) and pc(p2)) or (ph(p1) and ph(p2)))
       and ((fe(f2) and (pe(p1) or pc(p1))) or (fh(f2) and (ph(p1) or pc(p1))))
   ], 1)
   and not sum((p1,f1)$[
           plant_input(iso,t,p1,f1)
       and fuel_map(f1,p3)
       and ((pe(p1) and pe(p2)) or (pc(p1) and pc(p2)) or (ph(p1) and ph(p2)))
       and ((fe(f2) and (pe(p1) or pc(p1))) or (fh(f2) and (ph(p1) or pc(p1))))
   ], 1)
] = yes;

pre_missing_plant_map_support(iso,t,p2,p3,f2)$[
       plant_output(iso,t,p2,f2)
   and abs(fuel_output_balanced(iso,t,p3,f2)) gt 0
   and sum((p1,f1)$[
           plant_input(iso,t,p1,f1)
       and fuel_map(f1,p3)
       and ((pe(p1) and pe(p2)) or (pc(p1) and pc(p2)) or (ph(p1) and ph(p2)))
       and ((fe(f2) and (pe(p1) or pc(p1))) or (fh(f2) and (ph(p1) or pc(p1))))
   ], 1)
   and not sum((p1,f1)$[
           plant_input(iso,t,p1,f1)
       and fuel_map(f1,p3)
       and plant_map(p1,p2,p3)
       and ((pe(p1) and pe(p2)) or (pc(p1) and pc(p2)) or (ph(p1) and ph(p2)))
       and ((fe(f2) and (pe(p1) or pc(p1))) or (fh(f2) and (ph(p1) or pc(p1))))
   ], 1)
] = yes;

pre_disconnected_mapping_chain(iso,t,p2,p3,f2)$[
       plant_output(iso,t,p2,f2)
   and abs(fuel_output_balanced(iso,t,p3,f2)) gt 0
   and sum((p1,f1)$[
           plant_input(iso,t,p1,f1)
       and fuel_map(f1,p3)
       and ((pe(p1) and pe(p2)) or (pc(p1) and pc(p2)) or (ph(p1) and ph(p2)))
       and ((fe(f2) and (pe(p1) or pc(p1))) or (fh(f2) and (ph(p1) or pc(p1))))
   ], 1)
   and sum((p1,f1)$[
           plant_input(iso,t,p1,f1)
       and plant_map(p1,p2,p3)
       and ((pe(p1) and pe(p2)) or (pc(p1) and pc(p2)) or (ph(p1) and ph(p2)))
       and ((fe(f2) and (pe(p1) or pc(p1))) or (fh(f2) and (ph(p1) or pc(p1))))
   ], 1)
   and not sum((p1,f1)$[
           plant_input(iso,t,p1,f1)
       and fuel_map(f1,p3)
       and plant_map(p1,p2,p3)
       and ((pe(p1) and pe(p2)) or (pc(p1) and pc(p2)) or (ph(p1) and ph(p2)))
       and ((fe(f2) and (pe(p1) or pc(p1))) or (fh(f2) and (ph(p1) or pc(p1))))
   ], 1)
] = yes;

*------------------------------- PRE-SOLVE KPI SUMMARY -------------------------------*
pre_kpi_level_0 =
      sum((iso,t,f)$pre_raw_totals_mismatch(iso,t,f), 1)
    + sum((iso,t,f)$pre_scale_hits_lower_bound(iso,t,f), 1)
    + sum((iso,t,f)$pre_scale_hits_upper_bound(iso,t,f), 1);

pre_kpi_level_1 =
      sum((iso,t,p2,f2)$pre_plant_output_exceeds_feasible_energy(iso,t,p2,f2), 1)
    + sum((iso,t,p3,f2)$pre_fuel_output_exceeds_feasible_energy(iso,t,p3,f2), 1);

pre_kpi_level_2 =
      sum((iso,t,p2,p3,f2)$pre_no_same_family_support(iso,t,p2,p3,f2), 1)
    + sum((iso,t,p2,p3,f2)$pre_missing_fuel_map_support(iso,t,p2,p3,f2), 1)
    + sum((iso,t,p2,p3,f2)$pre_missing_plant_map_support(iso,t,p2,p3,f2), 1)
    + sum((iso,t,p2,p3,f2)$pre_disconnected_mapping_chain(iso,t,p2,p3,f2), 1);
    

*------------------------------- ALLOCATION DOMAIN -------------------------------*
$onText
allocation_domain defines which detailed input cells are even allowed to send
output to a given aggregate plant-output row p2 and fuel-output bucket p3.

Interpretation:
  (iso,t,p1,f1,p2,p3,f2) is feasible if:
  1) this country-year has any data,
  2) the detailed input row (p1,f1) actually exists in plant_input,
  3) the target plant-output row exists,
  4) the target fuel-output bucket exists after scaling,
  5) the fuel f1 is compatible with the output bucket p3 through fuel_map,
  6) the detailed plant p1 and aggregate plant p2 belong to the same family,
  7) the output commodity f2 is compatible with that plant family,
  8) either:
       - the manual plant_map explicitly supports (p1,p2,p3), or
       - this is a structurally infeasible case and we allow a controlled fallback.

This avoids ghost inputs:
  no allocation route can exist unless the raw input row plant_input(iso,t,p1,f1)
  is present.
$offText

allocation_domain(iso,t,p1,f1,p2,p3,f2)$[
    iso_t_active(iso,t)
    and plant_input(iso,t,p1,f1)
    and plant_output(iso,t,p2,f2)
    and (abs(fuel_output_balanced(iso,t,p3,f2)) gt 0)
    and fuel_map(f1,p3)
    and ((pe(p1) and pe(p2)) or (pc(p1) and pc(p2)) or (ph(p1) and ph(p2)))
    and ((fe(f2) and (pe(p1) or pc(p1))) or (fh(f2) and (ph(p1) or pc(p1))))
    and (
        plant_map(p1,p2,p3)
        or pre_structural_infeasibility(iso,t,p2,p3,f2)
    )
] = yes;

* --- Domain support counts and unsupported-row flags ------------------------*
pre_domain_support_plant_output(iso,t,p2,f2) = 0;
pre_domain_support_plant_output(iso,t,p2,f2)$[plant_output(iso,t,p2,f2)] =
    sum((p1,f1,p3)$allocation_domain(iso,t,p1,f1,p2,p3,f2), 1);

pre_domain_support_fuel_output(iso,t,p3,f2) = 0;
pre_domain_support_fuel_output(iso,t,p3,f2)$[abs(fuel_output_balanced(iso,t,p3,f2)) gt 0] =
    sum((p1,f1,p2)$allocation_domain(iso,t,p1,f1,p2,p3,f2), 1);

unsupported_plant_output(iso,t,p2,f2) = no;
unsupported_plant_output(iso,t,p2,f2)$[
       plant_output(iso,t,p2,f2)
   and not pre_domain_support_plant_output(iso,t,p2,f2)
] = yes;

unsupported_fuel_output(iso,t,p3,f2) = no;
unsupported_fuel_output(iso,t,p3,f2)$[
       abs(fuel_output_balanced(iso,t,p3,f2)) gt 0
   and not pre_domain_support_fuel_output(iso,t,p3,f2)
] = yes;


*------------------------------- PRE-SOLVE TROUBLESHOOTING -------------------------------*
$onText
Minimal troubleshooting outputs.

Interpretation:
  pre_fix_priority_fuel_map(f1,p3)
      Large values suggest a missing fuel_map row is blocking unsupported fuel-output rows.

  pre_fix_priority_plant_map(p1,p2,p3)
      Large values suggest a missing plant_map row is blocking unsupported plant-output rows.

  pre_check_data_plant(iso,t,p2,f2)
      Plant-output rows that still look inconsistent even after checking for plausible mapping support.

  pre_check_data_fuel(iso,t,p3,f2)
      Fuel-output rows that still look inconsistent even after checking for plausible mapping support.
$offText

pre_fix_priority_fuel_map(f1,p3) = 0;
pre_fix_priority_plant_map(p1,p2,p3) = 0;
pre_check_data_plant(iso,t,p2,f2) = 0;
pre_check_data_fuel(iso,t,p3,f2) = 0;

* Unsupported plant-output rows:
* If there exist same-family + fuel-map-compatible raw inputs, the likely fix is plant_map.
pre_fix_priority_plant_map(p1,p2,p3)$[not plant_map(p1,p2,p3)] =
    sum((iso,t,f1,f2)$[
           unsupported_plant_output(iso,t,p2,f2)
       and plant_input(iso,t,p1,f1)
       and abs(fuel_output_balanced(iso,t,p3,f2)) gt 0
       and fuel_map(f1,p3)
       and ((pe(p1) and pe(p2)) or (pc(p1) and pc(p2)) or (ph(p1) and ph(p2)))
       and ((fe(f2) and (pe(p1) or pc(p1))) or (fh(f2) and (ph(p1) or pc(p1))))
    ],
        min(
            abs(plant_input(iso,t,p1,f1)),
            min(plant_output(iso,t,p2,f2), abs(fuel_output_balanced(iso,t,p3,f2)))
        )
    );

pre_check_data_plant(iso,t,p2,f2)$[
       unsupported_plant_output(iso,t,p2,f2)
   and not sum((p1,f1,p3)$[
           plant_input(iso,t,p1,f1)
       and abs(fuel_output_balanced(iso,t,p3,f2)) gt 0
       and fuel_map(f1,p3)
       and ((pe(p1) and pe(p2)) or (pc(p1) and pc(p2)) or (ph(p1) and ph(p2)))
       and ((fe(f2) and (pe(p1) or pc(p1))) or (fh(f2) and (ph(p1) or pc(p1))))
   ], 1)
] = plant_output(iso,t,p2,f2);

* Unsupported fuel-output rows:
* If there exist same-family + plant-map-compatible raw inputs, the likely fix is fuel_map.
pre_fix_priority_fuel_map(f1,p3)$[not fuel_map(f1,p3)] =
    sum((iso,t,p2,f2)$[
           unsupported_fuel_output(iso,t,p3,f2)
       and plant_output(iso,t,p2,f2)
       and sum(p1$[
               plant_input(iso,t,p1,f1)
           and plant_map(p1,p2,p3)
           and ((pe(p1) and pe(p2)) or (pc(p1) and pc(p2)) or (ph(p1) and ph(p2)))
           and ((fe(f2) and (pe(p1) or pc(p1))) or (fh(f2) and (ph(p1) or pc(p1))))
       ], 1)
    ],
        min(abs(fuel_output_balanced(iso,t,p3,f2)), plant_output(iso,t,p2,f2))
    );

pre_check_data_fuel(iso,t,p3,f2)$[
       unsupported_fuel_output(iso,t,p3,f2)
   and not sum((p1,f1,p2)$[
           plant_input(iso,t,p1,f1)
       and plant_output(iso,t,p2,f2)
       and plant_map(p1,p2,p3)
       and ((pe(p1) and pe(p2)) or (pc(p1) and pc(p2)) or (ph(p1) and ph(p2)))
       and ((fe(f2) and (pe(p1) or pc(p1))) or (fh(f2) and (ph(p1) or pc(p1))))
   ], 1)
] = abs(fuel_output_balanced(iso,t,p3,f2));

pre_kpi_unsupported_plant_output =
    sum((iso,t,p2,f2)$unsupported_plant_output(iso,t,p2,f2), 1);

pre_kpi_unsupported_fuel_output =
    sum((iso,t,p3,f2)$unsupported_fuel_output(iso,t,p3,f2), 1);

pre_kpi_check_data_plant =
    sum((iso,t,p2,f2)$[pre_check_data_plant(iso,t,p2,f2) > 0], 1);

pre_kpi_check_data_fuel =
    sum((iso,t,p3,f2)$[pre_check_data_fuel(iso,t,p3,f2) > 0], 1);
    

* --- Input-plant domain support ---------------------------------------------*
pre_domain_count_input_plant(iso,t,p1) = 0;

pre_domain_count_input_plant(iso,t,p1)$[total_input(iso,t,p1) gt 0] =
    sum((f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2), 1);
    
*------------------------------- EXPORT BEFORE-SOLVE PACKAGE -------------------------------*
* Export only copy-paste candidate tables as CSV.
* Everything else remains in %ResultsGDX% for troubleshooting.
execute_unload "%ResultsGDX%";


*------------------------------- PLANT INPUT TOTAL -------------------------------*
plant_input_total(iso,t,p1)$iso_t_active(iso,t) = sum(f, abs(plant_input(iso,t,p1,f)));

*------------------------------- SEED CONSTRUCTION -------------------------------*
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



*------------------------------- PLANT OUTPUT ANCHOR TARGETS -------------------------------*
seed_plant_output_target(iso,t,p1) = 0;

* Electricity family anchor
seed_plant_output_target(iso,t,p1)$[(total_input(iso,t,p1) gt 0) and pe(p1)] =
    total_input(iso,t,p1)
 / max(1e-9, sum(p1a$pe(p1a), total_input(iso,t,p1a)))
 * sum((p2,f2)$[pe(p2) and fe(f2)], plant_output(iso,t,p2,f2));

* Heat family anchor
seed_plant_output_target(iso,t,p1)$[(total_input(iso,t,p1) gt 0) and ph(p1)] =
    total_input(iso,t,p1)
 / max(1e-9, sum(p1a$ph(p1a), total_input(iso,t,p1a)))
 * sum((p2,f2)$[ph(p2) and fh(f2)], plant_output(iso,t,p2,f2));

* CHP family anchor
seed_plant_output_target(iso,t,p1)$[(total_input(iso,t,p1) gt 0) and pc(p1)] =
    total_input(iso,t,p1)
 / max(1e-9, sum(p1a$pc(p1a), total_input(iso,t,p1a)))
 * sum((p2,f2)$[pc(p2) and (fe(f2) or fh(f2))], plant_output(iso,t,p2,f2));

* Conservative minimum target:
* only for plants that actually have feasible allocation routes
min_output_target(iso,t,p1) = 0;

min_output_target(iso,t,p1)$[
       total_input(iso,t,p1) gt 0
   and pre_domain_count_input_plant(iso,t,p1) gt 0
] =
    min_output_target_share * seed_plant_output_target(iso,t,p1);

* Relative scaling
scale_plant_anchor(iso,t,p1)$[seed_plant_output_target(iso,t,p1) gt 0] =
    max(1, seed_plant_output_target(iso,t,p1));
scale_plant_anchor(iso,t,p1)$[seed_plant_output_target(iso,t,p1) le 0] = 1;

scale_plant_shortfall(iso,t,p1)$[min_output_target(iso,t,p1) gt 0] =
    max(1, min_output_target(iso,t,p1));
scale_plant_shortfall(iso,t,p1)$[min_output_target(iso,t,p1) le 0] = 1;

* Anchor weight
plant_anchor_weight(iso,t,p1)$[total_input(iso,t,p1) gt 0] =
    1 + log(1 + total_input(iso,t,p1));
plant_anchor_weight(iso,t,p1)$[total_input(iso,t,p1) le 0] = 0;



*------------------------------- SEED DISAGGREGATION -------------------------------*
seed_allocated_output(iso,t,p1,f1,p2,p3,f2) = 0;

seed_allocated_output(iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2) =
    seed_total_output(iso,t,p1,f1,f2)
  * plant_output(iso,t,p2,f2)
  / max(
        1e-9,
        sum((p2a,p3a)$allocation_domain(iso,t,p1,f1,p2a,p3a,f2),
            plant_output(iso,t,p2a,f2))
    );

* Relative seed scaling: use plant-level target scale, not fragile cell seed scale
scale_seed_dev(iso,t,p1)$[seed_plant_output_target(iso,t,p1) gt 0] =
    max(1, seed_plant_output_target(iso,t,p1));

scale_seed_dev(iso,t,p1)$[seed_plant_output_target(iso,t,p1) le 0] =
    max(1, total_input(iso,t,p1));

* --- Seed deviation weights -------------------------------------------------*
seed_deviation_weight(iso,t,p1,f1,p2,p3,f2) = 0;

seed_deviation_weight(iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2) =
    (1 / scale_seed_dev(iso,t,p1))
 * (
      1
    + 5$[not plant_map(p1,p2,p3)]
    + 20$[pre_structural_infeasibility(iso,t,p2,p3,f2)]
   );

*------------------------------- FUEL-BALANCE SCALING -------------------------------*
scale_fuel_balance(iso,t,p3,f2)$[abs(fuel_output_balanced(iso,t,p3,f2)) gt 0] =
    max(1, abs(fuel_output_balanced(iso,t,p3,f2)));

scale_fuel_balance(iso,t,p3,f2)$[abs(fuel_output_balanced(iso,t,p3,f2)) le 0] = 1;

*------------------------------- HARD PRE-SOLVE SUPPORT CHECKS -------------------------------*
*abort$(sum((iso,t,p2,f2)$unsupported_plant_output(iso,t,p2,f2), 1) > 0)
*    "Unsupported plant-output rows exist. Exact plant-output balance cannot be guaranteed. Fix mappings or source data before solving.";
*
*abort$(sum((iso,t,p3,f2)$unsupported_fuel_output(iso,t,p3,f2), 1) > 0)
*    "Unsupported fuel-output rows exist. Exact fuel-output balance cannot be guaranteed. Fix mappings or source data before solving.";
*------------------------------- VARIABLES -------------------------------*
Positive Variables
    v_allocated_output(iso,t,p1,f1,p2,p3,f2) "primary decision variable: energy flow attributed to input (p1,f1) and routed to output pair (p2,p3) as commodity f2 [same units as data]"
    v_seed_deviation(iso,t,p1,f1,p2,p3,f2)   "absolute deviation of the allocation from the seed at cell level"
    v_efficiency_excess(iso,t,p1)             "slack above the total-output efficiency bound for plant p1"
    v_plant_output_deviation(iso,t,p1)        "absolute deviation from the two-sided plant-level anchor target"
    v_plant_output_shortfall(iso,t,p1)        "shortfall below a conservative minimum output target for active feasible plants"
    v_fuel_balance_plus(iso,t,p3,f2)          "positive residual on fuel-output balance"
    v_fuel_balance_minus(iso,t,p3,f2)         "negative residual on fuel-output balance"
;

Variable z "weighted objective (minimise)";

Variable z "weighted objective (minimise)";

* Warm start from seed
v_allocated_output.l(iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2) =
    seed_allocated_output(iso,t,p1,f1,p2,p3,f2);

*------------------------------- EQUATIONS -------------------------------*
Equations
    eq_plant_balance(iso,t,p2,f2)                "exact closure on each plant-output row"
    eq_fuel_balance(iso,t,p3,f2)                 "exact closure on each fuel-output bucket"
    eq_total_output_efficiency_upper_bound(iso,t,p1) "total output ≤ efficiency cap × total input + slack"
    eq_seed_deviation_upper(iso,t,p1,f1,p2,p3,f2)    "upper half of L1 seed deviation"
    eq_seed_deviation_lower(iso,t,p1,f1,p2,p3,f2)    "lower half of L1 seed deviation"
    eq_plant_output_anchor_upper(iso,t,p1)           "upper half of two-sided anchor deviation"
    eq_plant_output_anchor_lower(iso,t,p1)           "lower half of two-sided anchor deviation"
    eq_plant_output_shortfall(iso,t,p1)              "soft lower bound on output for active feasible plants"
    eq_objective                                      "weighted sum of all soft-constraint violations"
;

* --- Plant-output balance ---------------------------------------------------*
eq_plant_balance(iso,t,p2,f2)$[plant_output(iso,t,p2,f2) and pre_domain_support_plant_output(iso,t,p2,f2)]..
    sum((p1,f1,p3)$allocation_domain(iso,t,p1,f1,p2,p3,f2), v_allocated_output(iso,t,p1,f1,p2,p3,f2)) =e= plant_output(iso,t,p2,f2);

* --- Fuel-output balance ----------------------------------------------------*
eq_fuel_balance(iso,t,p3,f2)$[abs(fuel_output_balanced(iso,t,p3,f2)) gt 0 and pre_domain_support_fuel_output(iso,t,p3,f2)]..
    sum((p1,f1,p2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        v_allocated_output(iso,t,p1,f1,p2,p3,f2))
    + v_fuel_balance_minus(iso,t,p3,f2)
    - v_fuel_balance_plus(iso,t,p3,f2)
    =e= fuel_output_balanced(iso,t,p3,f2);

* --- Efficiency upper bound -------------------------------------------------*
eq_total_output_efficiency_upper_bound(iso,t,p1)$[(total_output_efficiency_upper_bound(p1) gt 0) and (total_input(iso,t,p1) gt 0)]..
    sum((f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        v_allocated_output(iso,t,p1,f1,p2,p3,f2))
    =l= total_output_efficiency_upper_bound(p1)*total_input(iso,t,p1) + v_efficiency_excess(iso,t,p1);

* --- L1 seed-deviation linearisation ----------------------------------------*
eq_seed_deviation_upper(iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2)..
    v_allocated_output(iso,t,p1,f1,p2,p3,f2) - seed_allocated_output(iso,t,p1,f1,p2,p3,f2)
    =l= v_seed_deviation(iso,t,p1,f1,p2,p3,f2);

eq_seed_deviation_lower(iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2)..
    seed_allocated_output(iso,t,p1,f1,p2,p3,f2) - v_allocated_output(iso,t,p1,f1,p2,p3,f2)
    =l= v_seed_deviation(iso,t,p1,f1,p2,p3,f2);

* --- L1 plant-anchor linearisation ------------------------------------------*
eq_plant_output_anchor_upper(iso,t,p1)$[(total_input(iso,t,p1) gt 0) and (seed_plant_output_target(iso,t,p1) gt 0)]..
    sum((f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        v_allocated_output(iso,t,p1,f1,p2,p3,f2))
    - seed_plant_output_target(iso,t,p1)
    =l= v_plant_output_deviation(iso,t,p1);

eq_plant_output_anchor_lower(iso,t,p1)$[(total_input(iso,t,p1) gt 0) and (seed_plant_output_target(iso,t,p1) gt 0)]..
    seed_plant_output_target(iso,t,p1)
    - sum((f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
          v_allocated_output(iso,t,p1,f1,p2,p3,f2))
    =l= v_plant_output_deviation(iso,t,p1);

* --- Soft lower bound for active feasible plants ----------------------------*
eq_plant_output_shortfall(iso,t,p1)$[
       total_input(iso,t,p1) gt 0
   and pre_domain_count_input_plant(iso,t,p1) gt 0
   and min_output_target(iso,t,p1) gt 0
]..
    sum((f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        v_allocated_output(iso,t,p1,f1,p2,p3,f2))
    + v_plant_output_shortfall(iso,t,p1)
    =g= min_output_target(iso,t,p1);
    
* --- Objective --------------------------------------------------------------*
eq_objective..
    z =e=
        penalty_weight_seed_deviation
      * sum((iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
            seed_deviation_weight(iso,t,p1,f1,p2,p3,f2)
          * v_seed_deviation(iso,t,p1,f1,p2,p3,f2))

      + penalty_weight_plant_anchor
      * sum((iso,t,p1)$[
              total_input(iso,t,p1) gt 0
          and seed_plant_output_target(iso,t,p1) gt 0
        ],
            (plant_anchor_weight(iso,t,p1) / scale_plant_anchor(iso,t,p1))
          * v_plant_output_deviation(iso,t,p1))

      + penalty_weight_plant_shortfall
      * sum((iso,t,p1)$[
              total_input(iso,t,p1) gt 0
          and pre_domain_count_input_plant(iso,t,p1) gt 0
          and min_output_target(iso,t,p1) gt 0
        ],
            v_plant_output_shortfall(iso,t,p1)
          / scale_plant_shortfall(iso,t,p1))

      + penalty_weight_efficiency_excess
      * sum((iso,t,p1)$[total_input(iso,t,p1) gt 0],
            v_efficiency_excess(iso,t,p1) / max(1, total_input(iso,t,p1)))

      + penalty_weight_fuel_balance
      * sum((iso,t,p3,f2)$[
              abs(fuel_output_balanced(iso,t,p3,f2)) gt 0
          and pre_domain_support_fuel_output(iso,t,p3,f2)
        ],
            (v_fuel_balance_plus(iso,t,p3,f2) + v_fuel_balance_minus(iso,t,p3,f2))
          / scale_fuel_balance(iso,t,p3,f2));

*------------------------------- MODEL -------------------------------*
Model plant_allocation /All/;

*------------------------------- SOLVE -------------------------------*
plant_allocation.optfile = 1;

solve plant_allocation using lp minimizing z;

abort$(plant_allocation.modelstat <> 1)
    "Exact feasible allocation not found under current mapping support, scaled margins, and efficiency bounds.";

*------------------------------- OUTPUT / REPORTING -------------------------------*
* Primary outputs
post_out_allocated_output(iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2) =
    v_allocated_output.l(iso,t,p1,f1,p2,p3,f2);

post_out_allocated_output_export(iso,t,p1,f2) =
    sum((p2,f1,p3)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_out_plant_input_total(iso,t,p1) = total_input(iso,t,p1);

post_out_plant_output_total(iso,t,p1) =
    sum((f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));




*------------------------------- POST-SOLVE PLANT-USE DIAGNOSTICS -------------------------------*
post_domain_count_input_plant(iso,t,p1)$[total_input(iso,t,p1) gt 0] =
    sum((f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2), 1);

post_output_from_input_plant(iso,t,p1)$[total_input(iso,t,p1) gt 0] =
    post_out_plant_output_total(iso,t,p1);

post_missing_output_no_domain(iso,t,p1) = 0;
post_missing_output_has_domain(iso,t,p1) = 0;

post_missing_output_no_domain(iso,t,p1)$[
       total_input(iso,t,p1) gt 0
   and post_domain_count_input_plant(iso,t,p1) = 0
] = 1;

post_missing_output_has_domain(iso,t,p1)$[
       total_input(iso,t,p1) gt 0
   and post_domain_count_input_plant(iso,t,p1) > 0
   and post_out_plant_output_total(iso,t,p1) le consistency_tolerance
] = 1;

post_kpi_missing_output_no_domain =
    sum((iso,t,p1)$[post_missing_output_no_domain(iso,t,p1) > 0], 1);

post_kpi_missing_output_has_domain =
    sum((iso,t,p1)$[post_missing_output_has_domain(iso,t,p1) > 0], 1);

post_out_plant_output_electricity(iso,t,p1) =
    sum((f1,p2,p3,f2)$[allocation_domain(iso,t,p1,f1,p2,p3,f2) and fe(f2)],
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_out_plant_output_heat(iso,t,p1) =
    sum((f1,p2,p3,f2)$[allocation_domain(iso,t,p1,f1,p2,p3,f2) and fh(f2)],
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_out_plant_efficiency_total(iso,t,p1)$[total_input(iso,t,p1) gt 0] =
    post_out_plant_output_total(iso,t,p1)/total_input(iso,t,p1);

post_out_plant_efficiency_electricity(iso,t,p1)$[total_input(iso,t,p1) gt 0] =
    post_out_plant_output_electricity(iso,t,p1)/total_input(iso,t,p1);

post_out_plant_efficiency_heat(iso,t,p1)$[total_input(iso,t,p1) gt 0] =
    post_out_plant_output_heat(iso,t,p1)/total_input(iso,t,p1);

post_out_share_seed_deviation =
    sum((iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        v_seed_deviation.l(iso,t,p1,f1,p2,p3,f2))
 /max(1e-9,
      sum((iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
          abs(seed_allocated_output(iso,t,p1,f1,p2,p3,f2))));

*------------------------------- POST-SOLVE DIAGNOSTICS -------------------------------*

* --- Balance residuals ------------------------------------------------------*
post_plant_balance_residual(iso,t,p2,f2)$plant_output(iso,t,p2,f2) =
    plant_output(iso,t,p2,f2)
  - sum((p1,f1,p3)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_fuel_balance_residual(iso,t,p3,f2)$[abs(fuel_output_balanced(iso,t,p3,f2)) gt 0] =
    fuel_output_balanced(iso,t,p3,f2)
  - sum((p1,f1,p2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_global_balance_residual(iso,t,f) =
    total_plant_output(iso,t,f) - sum(p3, fuel_output_balanced(iso,t,p3,f));

* --- Efficiency diagnostics -------------------------------------------------*
post_efficiency_slack(iso,t,p1)$[total_input(iso,t,p1) gt 0] =
    v_efficiency_excess.l(iso,t,p1);

post_efficiency_slack_share(iso,t,p1)$[total_input(iso,t,p1) gt 0] =
    v_efficiency_excess.l(iso,t,p1)/max(1e-9, total_input(iso,t,p1));

post_realised_total_efficiency(iso,t,p1)$[total_input(iso,t,p1) gt 0] =
    post_out_plant_efficiency_total(iso,t,p1);

* --- Level-3  sets -----------------------------------------------------*
post_high_efficiency_slack(iso,t,p1) = no;
post_extreme_total_efficiency(iso,t,p1) = no;
post_non_manual_plant_map_used(iso,t,p2,p3,f2) = no;
post_heavy_structural_fallback_use(iso,t,p2,p3,f2) = no;
post_missing_output_after_solve(iso,t,p1) = no;
plant_missing_output(iso,t,p1) = no;

post_high_efficiency_slack(iso,t,p1)$[
       total_input(iso,t,p1) gt 0
   and v_efficiency_excess.l(iso,t,p1) gt 0.10*total_input(iso,t,p1)
] = yes;

post_extreme_total_efficiency(iso,t,p1)$[
       total_input(iso,t,p1) gt 0
   and post_out_plant_efficiency_total(iso,t,p1) gt 1.5
] = yes;

post_non_manual_plant_map_used(iso,t,p2,p3,f2)$[
       sum((p1,f1)$[
              allocation_domain(iso,t,p1,f1,p2,p3,f2)
          and not plant_map(p1,p2,p3)
       ], post_out_allocated_output(iso,t,p1,f1,p2,p3,f2)) gt consistency_tolerance
] = yes;

post_structural_fallback_output(iso,t,p2,p3,f2) =
    sum((p1,f1)$[
           allocation_domain(iso,t,p1,f1,p2,p3,f2)
       and pre_structural_infeasibility(iso,t,p2,p3,f2)
    ],
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_total_pair_output(iso,t,p2,p3,f2) =
    sum((p1,f1)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_structural_fallback_share(iso,t,p2,p3,f2)$[post_total_pair_output(iso,t,p2,p3,f2) gt 1e-9] =
    post_structural_fallback_output(iso,t,p2,p3,f2)
  / post_total_pair_output(iso,t,p2,p3,f2);

plant_missing_output(iso,t,p1)$[
       total_input(iso,t,p1) gt 0
   and post_out_plant_output_total(iso,t,p1) le consistency_tolerance
] = yes;

post_missing_output_after_solve(iso,t,p1)$plant_missing_output(iso,t,p1) = yes;

* --- Top-line post-solve KPIs -----------------------------------------------*
post_kpi_level_3 =
      sum((iso,t,p1)$post_high_efficiency_slack(iso,t,p1), 1)
    + sum((iso,t,p1)$post_extreme_total_efficiency(iso,t,p1), 1)
    + sum((iso,t,p2,p3,f2)$post_non_manual_plant_map_used(iso,t,p2,p3,f2), 1)
    + sum((iso,t,p2,p3,f2)$post_heavy_structural_fallback_use(iso,t,p2,p3,f2), 1)
    + sum((iso,t,p1)$[post_missing_output_no_domain(iso,t,p1) > 0], 1)
    + sum((iso,t,p1)$[post_missing_output_has_domain(iso,t,p1) > 0], 1);

post_kpi_max_plant_balance_residual =
    smax((iso,t,p2,f2)$plant_output(iso,t,p2,f2),
         abs(post_plant_balance_residual(iso,t,p2,f2)));

post_kpi_max_fuel_balance_residual =
    smax((iso,t,p3,f2)$[abs(fuel_output_balanced(iso,t,p3,f2)) gt 0],
         abs(post_fuel_balance_residual(iso,t,p3,f2)));

post_kpi_total_efficiency_slack =
    sum((iso,t,p1)$[total_input(iso,t,p1) gt 0],
        v_efficiency_excess.l(iso,t,p1));

post_kpi_total_structural_fallback_share =
    sum((iso,t,p1,f1,p2,p3,f2)$[
           allocation_domain(iso,t,p1,f1,p2,p3,f2)
       and pre_structural_infeasibility(iso,t,p2,p3,f2)
    ], post_out_allocated_output(iso,t,p1,f1,p2,p3,f2))
 /max(1e-9,
      sum((iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
          post_out_allocated_output(iso,t,p1,f1,p2,p3,f2)));

post_kpi_total_non_manual_plant_map_share =
    sum((iso,t,p1,f1,p2,p3,f2)$[
           allocation_domain(iso,t,p1,f1,p2,p3,f2)
       and not plant_map(p1,p2,p3)
    ], post_out_allocated_output(iso,t,p1,f1,p2,p3,f2))
 /max(1e-9,
      sum((iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
          post_out_allocated_output(iso,t,p1,f1,p2,p3,f2)));

post_kpi_total_seed_deviation =
    sum((iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        v_seed_deviation.l(iso,t,p1,f1,p2,p3,f2));

post_kpi_objective_seed_term =
    penalty_weight_seed_deviation
 * sum((iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
       seed_deviation_weight(iso,t,p1,f1,p2,p3,f2)
     * v_seed_deviation.l(iso,t,p1,f1,p2,p3,f2));

post_kpi_objective_plant_anchor_term =
    penalty_weight_plant_anchor
 * sum((iso,t,p1)$[
          total_input(iso,t,p1) gt 0
      and seed_plant_output_target(iso,t,p1) gt 0
   ],
       plant_anchor_weight(iso,t,p1)
     * v_plant_output_deviation.l(iso,t,p1));

post_kpi_objective_efficiency_term =
    penalty_weight_efficiency_excess
 * sum((iso,t,p1)$[total_input(iso,t,p1) gt 0],
       v_efficiency_excess.l(iso,t,p1) / max(1, total_input(iso,t,p1)));

*------------------------------- EXPORT -------------------------------*
execute_unload "%ResultsGDX%";
$call gdxdump %ResultsGDX% output="allocated_output.csv" symb=post_out_allocated_output_export format=csv
$call gdxdump %ResultsGDX% output="allocated_output_full.csv" symb=post_out_allocated_output format=csv

*------------------------------- HARD POST-SOLVE CHECKS -------------------------------*
abort$(post_kpi_max_plant_balance_residual > consistency_tolerance)
    "Plant-output aggregation is not exact — check solver status and domain coverage.";

abort$(post_kpi_max_fuel_balance_residual > consistency_tolerance)
    "Fuel-output aggregation is not exact — check solver status and domain coverage.";
    