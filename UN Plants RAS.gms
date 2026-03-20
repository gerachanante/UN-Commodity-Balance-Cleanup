* UN ENERGY BALANCE – POWER PLANT FUEL ALLOCATION
* Detailed plant-fuel allocation using one mapping set:
* plant_map(p1,p2,p3)
*
* p1 = detailed plant process
* p2 = aggregate plant output code
* p3 = aggregate fuel output code
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
$set ResultsXLSXpath    T:\Latest datasets\01.Raw data needing conversion\UN.Commodity balance\UN Commodity Balance\ Cleanup

*------------------------------- SETS -------------------------------*
Sets
    t      time /2007*2023/
*    t      time /2022/
    iso    ISO3 code for countries
    p      process codes matching TRANSACTION in UN COMBAL
    f      fuel output codes matching ProdCode in IRENA Codes
        fe(f) electricity
        fh(f) heat
    pdesc
    ptype
    pmap(p<,ptype<) Mapping of process codes to metadata
        pe(p) electricity plants
        pc(p) chp plants
        ph(p) heat plants
;

Alias (p,p1,p2,p3,p1a,p2a,p3a);
Alias (f,f1,f2,f1a,ff);

Sets
    fuel_map(f1,p3) "manual input-fuel to aggregate fuel-output bucket mapping"
    plant_map(p1,p2,p3) "manual detailed plant to aggregate plant/fuel-output mapping"

    fuel_map_used(f1,p3)  "fuel_map plus data-implied additions"
    plant_map_used(p1,p2,p3) "plant_map plus data-implied additions"

    suggest_fuel_map(f1,p3) "data-implied fuel_map additions"
    suggest_plant_map(p1,p2,p3) "data-implied plant_map additions"

    iso_t_active(iso,t) "active country-year pairs"
    allocation_domain(iso,t,p1,f1,p2,p3,f2)

* pre-solve flags
    unsupported_plant_output(iso,t,p2,f)
    unsupported_fuel_output(iso,t,p3,f)

* post-solve flags
    plant_missing_output(iso,t,p1) "if plant has input but zero allocated output"

    iter /i1*i10/
;

Scalars
    penalty_weight_seed_deviation /1e5/
    penalty_weight_efficiency_excess /1e10/
    penalty_weight_plant_anchor /1e8/
    consistency_tolerance /1e-6/
;

*------------------------------- PARAMETERS -------------------------------*
Parameters
    plant_input(iso<,t,p1,f)                "detailed input rows: p=detailed plant process, f=input fuel code"
    plant_output(iso,t,p2,f)                "aggregate plant output rows: p=aggregate plant code, f=output commodity"
    fuel_output(iso,t,p3,f)                 "aggregate fuel output rows: p=aggregate fuel-output code, f=output commodity"
    max_efficiency(p)                       "target efficiency from UN-based assumptions"

    total_input(iso,t,p)                    "total absolute plant input by detailed process"
    total_plant_output(iso,t,f)             "sum of plant output totals by output commodity"
    total_fuel_output(iso,t,f)              "sum of fuel output totals by output commodity"
    fuel_output_scale(iso,t,f)              "scaling factor to reconcile totals"
    fuel_output_balanced(iso,t,p3,f)        "scaled fuel output totals"

    output_efficiency_upper_bound(p,f)      "upper bound on output-specific efficiency by plant type and output"
    total_output_efficiency_upper_bound(p)  "upper bound on total useful output efficiency by plant type"

    seed_total_output(iso,t,p1,f1,f2)
    seed_allocated_output(iso,t,p1,f1,p2,p3,f2)
    seed_deviation_weight(iso,t,p1,f1,p2,p3,f2)
    share_seed_deviation
    seed_plant_output_target(iso,t,p1)      "target total output by plant implied by seed"
    plant_anchor_weight(iso,t,p1)           "relative weight for plant-level anchor"
    plant_input_total(iso,t,p1)             "total combustible input by detailed plant"
    plant_output_total(iso,t,p1)            "allocated output by detailed plant"
    plant_output_electricity(iso,t,p1)      "allocated electricity output by detailed plant"
    plant_output_heat(iso,t,p1)             "allocated heat output by detailed plant"
    plant_efficiency_total(iso,t,p1)        "total output divided by fuel input"
    plant_efficiency_electricity(iso,t,p1)  "electricity output divided by fuel input"
    plant_efficiency_heat(iso,t,p1)         "heat output divided by fuel input"

* before-solve diagnostics
    pre_missing_plantmap_input(iso,t,p1,f1)      "1 if detailed input process p1 has no plant_map row"
    pre_missing_plantmap_output(iso,t,p2,f2)     "1 if aggregate output process p2 has no plant_map row"
    pre_missing_plantmap_fuelbucket(iso,t,p3,f2) "1 if fuel bucket p3 has no plant_map row"

    pre_plantmap_support(iso,t,p2,f2)            "count of raw plant_map-supported input links for plant output row"
    pre_fuelmap_support(iso,t,p3,f2)             "count of raw fuel-compatible links for fuel output row"
    pre_domain_support_plant(iso,t,p2,f2)        "count of full allocation-domain links for plant output row"
    pre_domain_support_fuel(iso,t,p3,f2)         "count of full allocation-domain links for fuel output row"

    pre_input_process_has_mapping(iso,t,p1,f1)   "count of plant_map rows reachable from this detailed input"
    pre_output_process_has_mapping(iso,t,p2,f2)  "count of plant_map rows reachable into this aggregate output"
    pre_exact_support_plant(iso,t,p2,f2)         "support using manual exact maps only"
    pre_exact_support_fuel(iso,t,p3,f2)          "support using manual exact maps only"

    pre_used_support_plant(iso,t,p2,f2)          "support using augmented maps"
    pre_used_support_fuel(iso,t,p3,f2)           "support using augmented maps"
    
    pre_structural_infeasibility(iso,t,p2,p3,f2)

    suggest_plant_map_count(p1,p2,p3)            "number of data-supported additions to plant_map"
    suggest_fuel_map_count(f1,p3)                "number of data-supported additions to fuel_map"

    new_plant_rows(iter)                         "number of new plant_map rows added in iteration"
    new_fuel_rows(iter)                          "number of new fuel_map rows added in iteration"

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
iso_t_active(iso,t) =
      sum((p1,f), abs(plant_input(iso,t,p1,f)))
    + sum((p2,f), abs(plant_output(iso,t,p2,f)))
    + sum((p3,f), abs(fuel_output(iso,t,p3,f))) gt 0;

*------------------------------- PREPARE TOTALS -------------------------------*
total_input(iso,t,p1)$iso_t_active(iso,t) = sum(f, abs(plant_input(iso,t,p1,f)));
total_plant_output(iso,t,f)$iso_t_active(iso,t) = sum(p2, plant_output(iso,t,p2,f));
total_fuel_output(iso,t,f)$iso_t_active(iso,t) = sum(p3, fuel_output(iso,t,p3,f));

fuel_output_scale(iso,t,f) = 1;

fuel_output_scale(iso,t,f)$[
       iso_t_active(iso,t)
   and total_plant_output(iso,t,f) gt 1e-9
   and total_fuel_output(iso,t,f) gt 1e-9
] = min(5,
      max(0.2,
          total_plant_output(iso,t,f)
        / total_fuel_output(iso,t,f)
      )
);

fuel_output_balanced(iso,t,p3,f) =
    fuel_output(iso,t,p3,f) * fuel_output_scale(iso,t,f);

*------------------------------- PHYSICAL BOUNDS -------------------------------*
output_efficiency_upper_bound(p,f) = 0;
total_output_efficiency_upper_bound(p) = 0;

output_efficiency_upper_bound(p,f)$[pe(p) and fe(f)] = min(1.1, max_efficiency(p) * 1.2);
output_efficiency_upper_bound(p,f)$[pc(p) and fe(f)] = min(1.1, max_efficiency(p) * 1.2);
output_efficiency_upper_bound(p,f)$[ph(p) and fh(f)] = min(1.1, max_efficiency(p) * 1.2);

total_output_efficiency_upper_bound(p)$pe(p) = min(1.1, max_efficiency(p) * 1.2);
total_output_efficiency_upper_bound(p)$ph(p) = min(1.1, max_efficiency(p) * 1.2);
total_output_efficiency_upper_bound(p)$pc(p) = 1.2;


*=====================================================================*
* DATA-IMPLIED MAP AUGMENTATION                                       *
* Build exact-first augmented maps from the three imported datasets    *
*=====================================================================*

plant_map_used(p1,p2,p3) = plant_map(p1,p2,p3);
fuel_map_used(f1,p3)     = fuel_map(f1,p3);

suggest_plant_map(p1,p2,p3) = no;
suggest_fuel_map(f1,p3)     = no;

suggest_plant_map_count(p1,p2,p3) = 0;
suggest_fuel_map_count(f1,p3)     = 0;

new_plant_rows(iter) = 0;
new_fuel_rows(iter)  = 0;





*=====================================================================*
* BEFORE-SOLVE DIAGNOSTICS                                            *
*=====================================================================*

pre_missing_plantmap_input(iso,t,p1,f1)$plant_input(iso,t,p1,f1) =
    1$[not sum((p2,p3)$plant_map(p1,p2,p3), 1)];

pre_missing_plantmap_output(iso,t,p2,f2)$plant_output(iso,t,p2,f2) =
    1$[not sum((p1,p3)$plant_map(p1,p2,p3), 1)];

pre_missing_plantmap_fuelbucket(iso,t,p3,f2)$abs(fuel_output_balanced(iso,t,p3,f2)) =
    1$[not sum((p1,p2)$plant_map(p1,p2,p3), 1)];

pre_input_process_has_mapping(iso,t,p1,f1)$plant_input(iso,t,p1,f1) =
    sum((p2,p3)$plant_map(p1,p2,p3), 1);

pre_output_process_has_mapping(iso,t,p2,f2)$plant_output(iso,t,p2,f2) =
    sum((p1,p3)$plant_map(p1,p2,p3), 1);

pre_plantmap_support(iso,t,p2,f2)$plant_output(iso,t,p2,f2) =
    sum((p1,f1,p3)$[
           plant_input(iso,t,p1,f1)
       and plant_map(p1,p2,p3)
       and (
              (fe(f2) and (pe(p2) or pc(p2)))
           or (fh(f2) and (ph(p2) or pc(p2)))
           )
    ], 1);

pre_fuelmap_support(iso,t,p3,f2)$abs(fuel_output_balanced(iso,t,p3,f2)) =
    sum((p1,f1,p2)$[
           plant_input(iso,t,p1,f1)
       and plant_output(iso,t,p2,f2)
       and plant_map(p1,p2,p3)
       and fuel_map(f1,p3)
       and (
              (fe(f2) and (pe(p2) or pc(p2)))
           or (fh(f2) and (ph(p2) or pc(p2)))
           )
    ], 1);

pre_exact_support_plant(iso,t,p2,f2)$plant_output(iso,t,p2,f2) =
    sum((p1,f1,p3)$[
           plant_input(iso,t,p1,f1)
       and abs(fuel_output_balanced(iso,t,p3,f2)) gt 0
       and plant_map(p1,p2,p3)
       and fuel_map(f1,p3)
       and (
              (fe(f2) and (pe(p2) or pc(p2)) and (pe(p1) or pc(p1)))
           or (fh(f2) and (ph(p2) or pc(p2)) and (ph(p1) or pc(p1)))
           )
    ], 1);

pre_exact_support_fuel(iso,t,p3,f2)$[abs(fuel_output_balanced(iso,t,p3,f2)) gt 0] =
    sum((p1,f1,p2)$[
           plant_input(iso,t,p1,f1)
       and plant_output(iso,t,p2,f2)
       and plant_map(p1,p2,p3)
       and fuel_map(f1,p3)
       and (
              (fe(f2) and (pe(p2) or pc(p2)) and (pe(p1) or pc(p1)))
           or (fh(f2) and (ph(p2) or pc(p2)) and (ph(p1) or pc(p1)))
           )
    ], 1);

pre_used_support_plant(iso,t,p2,f2)$plant_output(iso,t,p2,f2) =
    sum((p1,f1,p3)$[
           plant_input(iso,t,p1,f1)
       and abs(fuel_output_balanced(iso,t,p3,f2)) gt 0
       and plant_map_used(p1,p2,p3)
       and fuel_map_used(f1,p3)
       and (
              (fe(f2) and (pe(p2) or pc(p2)) and (pe(p1) or pc(p1)))
           or (fh(f2) and (ph(p2) or pc(p2)) and (ph(p1) or pc(p1)))
           )
    ], 1);

pre_used_support_fuel(iso,t,p3,f2)$[abs(fuel_output_balanced(iso,t,p3,f2)) gt 0] =
    sum((p1,f1,p2)$[
           plant_input(iso,t,p1,f1)
       and plant_output(iso,t,p2,f2)
       and plant_map_used(p1,p2,p3)
       and fuel_map_used(f1,p3)
       and (
              (fe(f2) and (pe(p2) or pc(p2)) and (pe(p1) or pc(p1)))
           or (fh(f2) and (ph(p2) or pc(p2)) and (ph(p1) or pc(p1)))
           )
    ], 1);



pre_structural_infeasibility(iso,t,p2,p3,f2)$[
       iso_t_active(iso,t)
   and plant_output(iso,t,p2,f2)
   and abs(fuel_output_balanced(iso,t,p3,f2)) gt 0
   and not sum((p1,f1)$[
           plant_input(iso,t,p1,f1)
       and plant_map(p1,p2,p3)
       and fuel_map(f1,p3)

* plant family consistency
       and (
              (pe(p1) and pe(p2))
           or (pc(p1) and pc(p2))
           or (ph(p1) and ph(p2))
           )

* output compatibility
       and (
              (fe(f2) and (pe(p1) or pc(p1)))
           or (fh(f2) and (ph(p1) or pc(p1)))
           )
   ], 1)
] = 1;

*------------------------------- ALLOCATION DOMAIN -------------------------------*
allocation_domain(iso,t,p1,f1,p2,p3,f2)$[
       iso_t_active(iso,t)
    and plant_output(iso,t,p2,f2)
    and abs(fuel_output_balanced(iso,t,p3,f2)) gt 0

* fuel compatibility always required
    and fuel_map(f1,p3)

* plant family consistency
    and (
           (pe(p1) and pe(p2))
        or (pc(p1) and pc(p2))
        or (ph(p1) and ph(p2))
    )

* output compatibility
    and (
           (fe(f2) and (pe(p1) or pc(p1)))
        or (fh(f2) and (ph(p1) or pc(p1)))
    )

*----------------------------------*
* STRICT OR LOCAL REPAIR ONLY      *
*----------------------------------*
    and (
           plant_map(p1,p2,p3)

        or (
               pre_structural_infeasibility(iso,t,p2,p3,f2)
           and plant_input(iso,t,p1,f1)
        )
    )
] = yes;

pre_domain_support_plant(iso,t,p2,f2) = 0;
pre_domain_support_fuel(iso,t,p3,f2)  = 0;
unsupported_plant_output(iso,t,p2,f2) = no;
unsupported_fuel_output(iso,t,p3,f2)  = no;

pre_domain_support_plant(iso,t,p2,f2)$plant_output(iso,t,p2,f2) =
    sum((p1,f1,p3)$allocation_domain(iso,t,p1,f1,p2,p3,f2), 1);

pre_domain_support_fuel(iso,t,p3,f2)$[abs(fuel_output_balanced(iso,t,p3,f2)) gt 0] =
    sum((p1,f1,p2)$allocation_domain(iso,t,p1,f1,p2,p3,f2), 1);

unsupported_plant_output(iso,t,p2,f2)$[
       plant_output(iso,t,p2,f2)
   and not pre_domain_support_plant(iso,t,p2,f2)
] = yes;

unsupported_fuel_output(iso,t,p3,f2)$[
       abs(fuel_output_balanced(iso,t,p3,f2)) gt 0
   and not pre_domain_support_fuel(iso,t,p3,f2)
] = yes;
*------------------------------- PLANT INPUT TOTAL -------------------------------*
plant_input_total(iso,t,p1)$iso_t_active(iso,t) =
    sum(f, abs(plant_input(iso,t,p1,f)));

*------------------------------- BUILD SEED -------------------------------*
seed_total_output(iso,t,p1,f1,f2) = 0;

seed_total_output(iso,t,p1,f1,f2)$[
       plant_input(iso,t,p1,f1)
   and pe(p1)
   and fe(f2)
] = abs(plant_input(iso,t,p1,f1)) * max_efficiency(p1);

seed_total_output(iso,t,p1,f1,f2)$[
       plant_input(iso,t,p1,f1)
   and ph(p1)
   and fh(f2)
] = abs(plant_input(iso,t,p1,f1)) * max_efficiency(p1);

seed_total_output(iso,t,p1,f1,f2)$[
       plant_input(iso,t,p1,f1)
   and pc(p1)
   and (fe(f2) or fh(f2))
] =
    abs(plant_input(iso,t,p1,f1))
  * max_efficiency(p1)
  * total_plant_output(iso,t,f2)
  / max(1e-9, sum(ff$(fe(ff) or fh(ff)), total_plant_output(iso,t,ff)));


seed_plant_output_target(iso,t,p1) = 0;

* Electricity plants: anchor within electricity family only
seed_plant_output_target(iso,t,p1)$[
       total_input(iso,t,p1) gt 0
   and pe(p1)
] =
    total_input(iso,t,p1)
  / max(1e-9, sum(p1a$pe(p1a), total_input(iso,t,p1a)))
  * sum((p2,f2)$[pe(p2) and fe(f2)], plant_output(iso,t,p2,f2));

* Heat plants: anchor within heat family only
seed_plant_output_target(iso,t,p1)$[
       total_input(iso,t,p1) gt 0
   and ph(p1)
] =
    total_input(iso,t,p1)
  / max(1e-9, sum(p1a$ph(p1a), total_input(iso,t,p1a)))
  * sum((p2,f2)$[ph(p2) and fh(f2)], plant_output(iso,t,p2,f2));

* CHP plants: anchor within CHP family only
seed_plant_output_target(iso,t,p1)$[
       total_input(iso,t,p1) gt 0
   and pc(p1)
] =
    total_input(iso,t,p1)
  / max(1e-9, sum(p1a$pc(p1a), total_input(iso,t,p1a)))
  * sum((p2,f2)$[pc(p2) and (fe(f2) or fh(f2))], plant_output(iso,t,p2,f2));

plant_anchor_weight(iso,t,p1) = 1;


seed_allocated_output(iso,t,p1,f1,p2,p3,f2) = 0;

seed_allocated_output(iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2) =
    seed_total_output(iso,t,p1,f1,f2)
  * plant_output(iso,t,p2,f2)
  / max(1e-9,
        sum((p2a,p3a)$allocation_domain(iso,t,p1,f1,p2a,p3a,f2),
            plant_output(iso,t,p2a,f2)
        )
    );
seed_deviation_weight(iso,t,p1,f1,p2,p3,f2) = 0;

seed_deviation_weight(iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2) =
      1 / max(10, abs(seed_allocated_output(iso,t,p1,f1,p2,p3,f2)))
    * (
          1
* penalty: missing manual plant map
        + 100$[not plant_map(p1,p2,p3)]
* penalty: missing manual fuel map
        + 50$[not fuel_map(f1,p3)]
* penalty: fallback case (no input mapping)
        + 5000$[pre_structural_infeasibility(iso,t,p2,p3,f2)]
      );

*------------------------------- EXPORT BEFORE-SOLVE PACKAGE -------------------------------*
execute_unload "data_input.gdx"

*------------------------------- VARIABLES -------------------------------*
Positive Variables
    v_allocated_output(iso,t,p1,f1,p2,p3,f2)
    v_seed_deviation(iso,t,p1,f1,p2,p3,f2)
    v_efficiency_excess(iso,t,p1)
    v_plant_output_deviation(iso,t,p1)
;

Variable z;

v_allocated_output.l(iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2) =
    seed_allocated_output(iso,t,p1,f1,p2,p3,f2);

*------------------------------- EQUATIONS -------------------------------*
Equations
    eq_plant_balance
    eq_fuel_balance
    eq_total_output_efficiency_upper_bound
    eq_seed_deviation_upper
    eq_seed_deviation_lower
    eq_plant_output_anchor_upper
    eq_plant_output_anchor_lower
    eq_objective
;

eq_plant_balance(iso,t,p2,f2)$[
       plant_output(iso,t,p2,f2)
   and pre_domain_support_plant(iso,t,p2,f2)
]..
    sum((p1,f1,p3)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        v_allocated_output(iso,t,p1,f1,p2,p3,f2))
    =e= plant_output(iso,t,p2,f2);

eq_fuel_balance(iso,t,p3,f2)$[
       abs(fuel_output_balanced(iso,t,p3,f2)) gt 0
   and pre_domain_support_fuel(iso,t,p3,f2)
]..
    sum((p1,f1,p2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        v_allocated_output(iso,t,p1,f1,p2,p3,f2))
    =e= fuel_output_balanced(iso,t,p3,f2);

eq_total_output_efficiency_upper_bound(iso,t,p1)$[
       total_output_efficiency_upper_bound(p1) gt 0
   and total_input(iso,t,p1) gt 0
]..
    sum((f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        v_allocated_output(iso,t,p1,f1,p2,p3,f2))
    =l= total_output_efficiency_upper_bound(p1) * total_input(iso,t,p1) + v_efficiency_excess(iso,t,p1);

eq_seed_deviation_upper(iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2)..
    v_allocated_output(iso,t,p1,f1,p2,p3,f2)
  - seed_allocated_output(iso,t,p1,f1,p2,p3,f2)
    =l= v_seed_deviation(iso,t,p1,f1,p2,p3,f2);

eq_seed_deviation_lower(iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2)..
    seed_allocated_output(iso,t,p1,f1,p2,p3,f2)
  - v_allocated_output(iso,t,p1,f1,p2,p3,f2)
    =l= v_seed_deviation(iso,t,p1,f1,p2,p3,f2);

eq_plant_output_anchor_upper(iso,t,p1)$[
       total_input(iso,t,p1) gt 0
   and seed_plant_output_target(iso,t,p1) gt 0
]..
    sum((f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        v_allocated_output(iso,t,p1,f1,p2,p3,f2))
  - seed_plant_output_target(iso,t,p1)
    =l= v_plant_output_deviation(iso,t,p1);

eq_plant_output_anchor_lower(iso,t,p1)$[
       total_input(iso,t,p1) gt 0
   and seed_plant_output_target(iso,t,p1) gt 0
]..
    seed_plant_output_target(iso,t,p1)
  - sum((f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        v_allocated_output(iso,t,p1,f1,p2,p3,f2))
    =l= v_plant_output_deviation(iso,t,p1);
    
eq_objective..
    z =e= penalty_weight_seed_deviation
       * sum((iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
             seed_deviation_weight(iso,t,p1,f1,p2,p3,f2)
           * v_seed_deviation(iso,t,p1,f1,p2,p3,f2))

       + penalty_weight_plant_anchor
       * sum((iso,t,p1)$[
                total_input(iso,t,p1) gt 0
            and seed_plant_output_target(iso,t,p1) gt 0
             ],
             plant_anchor_weight(iso,t,p1)
           * v_plant_output_deviation(iso,t,p1))

       + penalty_weight_efficiency_excess
       * sum((iso,t,p1)$[total_input(iso,t,p1) gt 0],
             10 * v_efficiency_excess(iso,t,p1));

*------------------------------- MODEL -------------------------------*
Model plant_allocation /All/;

*------------------------------- SOLVE -------------------------------*
plant_allocation.optfile = 1;

solve plant_allocation using lp minimizing z;

abort$(plant_allocation.modelstat <> 1)
    "Exact feasible allocation not found under current mapping support, scaled margins, and efficiency bounds.";

*=====================================================================*
* POST-SOLVE REPORTING + DIAGNOSTICS                                  *
*=====================================================================*

Parameters
*------------------------------- OUTPUT / REPORTING -------------------------------*
    post_out_allocated_output(iso,t,p1,f1,p2,p3,f2)      "final allocated flow"
    post_out_allocated_output_export(iso,t,p1,f2)        "allocated output summed by detailed plant and final output"
    post_out_plant_input_total(iso,t,p1)                 "total combustible input by detailed plant"
    post_out_plant_output_total(iso,t,p1)                "allocated output by detailed plant"
    post_out_plant_output_electricity(iso,t,p1)          "allocated electricity output by detailed plant"
    post_out_plant_output_heat(iso,t,p1)                 "allocated heat output by detailed plant"
    post_out_plant_efficiency_total(iso,t,p1)            "total output divided by fuel input"
    post_out_plant_efficiency_electricity(iso,t,p1)      "electricity output divided by fuel input"
    post_out_plant_efficiency_heat(iso,t,p1)             "heat output divided by fuel input"
    post_out_share_seed_deviation                        "share of allocation volume deviating from seed"

*------------------------------- CORE BALANCE DIAGNOSTICS -------------------------------*
    post_diag_check_plant_balance(iso,t,p2,f)            "post-solve plant residual check"
    post_diag_check_fuel_balance(iso,t,p3,f)             "post-solve fuel residual check"
    post_diag_check_global_balance(iso,t,f)              "difference between plant and fuel totals after scaling"

*------------------------------- MAPPING / STRUCTURE DIAGNOSTICS -------------------------------*
    post_diag_manual_map_share(iso,t,p2,p3,f2)           "share of allocated flow using manual plant_map and fuel_map"
    post_diag_augmented_map_share(iso,t,p2,p3,f2)        "share of allocated flow using at least one suggested mapping"
    post_diag_missing_manual_plant_map_flow(iso,t,p1,p2,p3,f2) "allocated flow that relied on suggested plant_map"
    post_diag_missing_manual_fuel_map_flow(iso,t,p1,f1,p3,f2)  "allocated flow that relied on suggested fuel_map"
    post_diag_suggest_plant_map_priority(p1,p2,p3)       "total allocated flow supported by suggested plant_map row"
    post_diag_suggest_fuel_map_priority(f1,p3)           "total allocated flow supported by suggested fuel_map row"

*------------------------------- EFFICIENCY DIAGNOSTICS -------------------------------*
    post_diag_efficiency_excess(iso,t,p1)                "slack above total output efficiency upper bound"
    post_diag_efficiency_excess_share(iso,t,p1)          "efficiency excess relative to total input"
    post_diag_bound_total_output(iso,t,p1)               "hard RHS of total output efficiency bound without slack"
    post_diag_actual_total_output(iso,t,p1)              "actual total allocated output entering efficiency bound"

*------------------------------- SEED / DISTORTION DIAGNOSTICS -------------------------------*
    post_diag_seed_deviation_abs(iso,t,p1,f1,p2,p3,f2)   "absolute deviation from seed at cell level"
    post_diag_seed_deviation_weighted(iso,t,p1,f1,p2,p3,f2) "weighted deviation contribution at cell level"
    post_diag_seed_deviation_by_plant(iso,t,p1)          "sum of seed deviations by detailed plant"
    post_diag_seed_deviation_by_output(iso,t,p2,p3,f2)   "sum of seed deviations by aggregate output pair"

*------------------------------- FLAG / PRIORITY DIAGNOSTICS -------------------------------*
    post_diag_flag_high_efficiency(iso,t,p1)             "flag value for plants with notable efficiency excess"
    post_diag_flag_extreme_efficiency(iso,t,p1)          "flag value for plants with extreme realized efficiency"
    post_diag_flag_high_fallback(iso,t,p2,p3,f2)         "flag value for output rows heavily relying on fallback"
    post_diag_flag_missing_output(iso,t,p1)              "flag value for plants with input but zero allocated output"
    post_diag_flag_augmented_mapping(iso,t,p2,p3,f2)     "flag value for output rows using augmented mappings"
    post_diag_repair_priority_plantmap(p1,p2,p3)         "priority score for adding/fixing plant_map row"
    post_diag_repair_priority_fuelmap(f1,p3)             "priority score for adding/fixing fuel_map row"

*------------------------------- MODEL PERFORMANCE DIAGNOSTICS -------------------------------*
    post_kpi_total_seed_deviation
    post_kpi_total_efficiency_excess
    post_kpi_total_fallback_share
    post_kpi_total_augmented_share
    post_kpi_total_manual_share
    post_kpi_objective_breakdown_seed
    post_kpi_objective_breakdown_efficiency
;

*------------------------------- OUTPUT / REPORTING -------------------------------*
post_out_allocated_output(iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2) =
    v_allocated_output.l(iso,t,p1,f1,p2,p3,f2);

post_out_allocated_output_export(iso,t,p1,f2) =
    sum((p2,f1,p3)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_out_plant_input_total(iso,t,p1) = total_input(iso,t,p1);

post_out_plant_output_total(iso,t,p1) =
    sum((f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_out_plant_output_electricity(iso,t,p1) =
    sum((f1,p2,p3,f2)$[
            allocation_domain(iso,t,p1,f1,p2,p3,f2)
        and fe(f2)
    ],
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_out_plant_output_heat(iso,t,p1) =
    sum((f1,p2,p3,f2)$[
            allocation_domain(iso,t,p1,f1,p2,p3,f2)
        and fh(f2)
    ],
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_out_plant_efficiency_total(iso,t,p1)$total_input(iso,t,p1) =
    post_out_plant_output_total(iso,t,p1) / total_input(iso,t,p1);

post_out_plant_efficiency_electricity(iso,t,p1)$total_input(iso,t,p1) =
    post_out_plant_output_electricity(iso,t,p1) / total_input(iso,t,p1);

post_out_plant_efficiency_heat(iso,t,p1)$total_input(iso,t,p1) =
    post_out_plant_output_heat(iso,t,p1) / total_input(iso,t,p1);

post_out_share_seed_deviation =
    sum((iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        v_seed_deviation.l(iso,t,p1,f1,p2,p3,f2))
  / max(1e-9,
        sum((iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
            abs(seed_allocated_output(iso,t,p1,f1,p2,p3,f2)))
    );

*------------------------------- CORE BALANCE DIAGNOSTICS -------------------------------*
post_diag_check_plant_balance(iso,t,p2,f2)$plant_output(iso,t,p2,f2) =
    plant_output(iso,t,p2,f2)
  - sum((p1,f1,p3)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_diag_check_fuel_balance(iso,t,p3,f2)$abs(fuel_output_balanced(iso,t,p3,f2)) =
    fuel_output_balanced(iso,t,p3,f2)
  - sum((p1,f1,p2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_diag_check_global_balance(iso,t,f) =
    total_plant_output(iso,t,f) - sum(p3, fuel_output_balanced(iso,t,p3,f));

*------------------------------- MAPPING / STRUCTURE DIAGNOSTICS -------------------------------*
post_diag_manual_map_share(iso,t,p2,p3,f2)$[
       abs(fuel_output_balanced(iso,t,p3,f2)) gt 0
   and plant_output(iso,t,p2,f2)
] =
    sum((p1,f1)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2)
      $ (plant_map(p1,p2,p3) and fuel_map(f1,p3))
    )
  / max(1e-9,
        sum((p1,f1)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
            post_out_allocated_output(iso,t,p1,f1,p2,p3,f2)));

post_diag_augmented_map_share(iso,t,p2,p3,f2)$[
       abs(fuel_output_balanced(iso,t,p3,f2)) gt 0
   and plant_output(iso,t,p2,f2)
] =
    sum((p1,f1)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2)
      $ (not plant_map(p1,p2,p3) or not fuel_map(f1,p3))
    )
  / max(1e-9,
        sum((p1,f1)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
            post_out_allocated_output(iso,t,p1,f1,p2,p3,f2)));


post_diag_missing_manual_plant_map_flow(iso,t,p1,p2,p3,f2)$[
       not plant_map(p1,p2,p3)
   and sum(f1$allocation_domain(iso,t,p1,f1,p2,p3,f2), 1)
] =
    sum(f1$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_diag_missing_manual_fuel_map_flow(iso,t,p1,f1,p3,f2)$[
       not fuel_map(f1,p3)
   and sum(p2$allocation_domain(iso,t,p1,f1,p2,p3,f2), 1)
] =
    sum(p2$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_diag_suggest_plant_map_priority(p1,p2,p3)$[not plant_map(p1,p2,p3)] =
    sum((iso,t,f1,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

post_diag_suggest_fuel_map_priority(f1,p3)$[not fuel_map(f1,p3)] =
    sum((iso,t,p1,p2,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

*------------------------------- EFFICIENCY DIAGNOSTICS -------------------------------*
post_diag_efficiency_excess(iso,t,p1)$[total_input(iso,t,p1) gt 0] =
    v_efficiency_excess.l(iso,t,p1);

post_diag_efficiency_excess_share(iso,t,p1)$[total_input(iso,t,p1) gt 0] =
    v_efficiency_excess.l(iso,t,p1) / max(1e-9, total_input(iso,t,p1));

post_diag_bound_total_output(iso,t,p1)$[total_input(iso,t,p1) gt 0] =
    total_output_efficiency_upper_bound(p1) * total_input(iso,t,p1);

post_diag_actual_total_output(iso,t,p1)$[total_input(iso,t,p1) gt 0] =
    sum((f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        post_out_allocated_output(iso,t,p1,f1,p2,p3,f2));

*------------------------------- SEED / DISTORTION DIAGNOSTICS -------------------------------*
post_diag_seed_deviation_abs(iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2) =
    v_seed_deviation.l(iso,t,p1,f1,p2,p3,f2);

post_diag_seed_deviation_weighted(iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2) =
    seed_deviation_weight(iso,t,p1,f1,p2,p3,f2)
  * v_seed_deviation.l(iso,t,p1,f1,p2,p3,f2);

post_diag_seed_deviation_by_plant(iso,t,p1) =
    sum((f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        v_seed_deviation.l(iso,t,p1,f1,p2,p3,f2));

post_diag_seed_deviation_by_output(iso,t,p2,p3,f2) =
    sum((p1,f1)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        v_seed_deviation.l(iso,t,p1,f1,p2,p3,f2));

*------------------------------- FLAG / PRIORITY DIAGNOSTICS -------------------------------*
post_diag_flag_high_efficiency(iso,t,p1)$[
       total_input(iso,t,p1) gt 0
   and v_efficiency_excess.l(iso,t,p1) > 0.10 * total_input(iso,t,p1)
] = v_efficiency_excess.l(iso,t,p1);

post_diag_flag_extreme_efficiency(iso,t,p1)$[
       total_input(iso,t,p1) gt 0
   and post_out_plant_efficiency_total(iso,t,p1) > 1.5
] = post_out_plant_efficiency_total(iso,t,p1);



plant_missing_output(iso,t,p1)$[
       total_input(iso,t,p1) gt 0
   and post_out_plant_output_total(iso,t,p1) <= consistency_tolerance
] = yes;

post_diag_flag_missing_output(iso,t,p1)$plant_missing_output(iso,t,p1) = 1;

post_diag_flag_augmented_mapping(iso,t,p2,p3,f2)$[
       post_diag_augmented_map_share(iso,t,p2,p3,f2) > 0
] = post_diag_augmented_map_share(iso,t,p2,p3,f2);

post_diag_repair_priority_plantmap(p1,p2,p3)$[not plant_map(p1,p2,p3)] =
      post_diag_suggest_plant_map_priority(p1,p2,p3)
    + penalty_weight_efficiency_excess
      * sum((iso,t)$[total_input(iso,t,p1) gt 0],
            post_diag_efficiency_excess_share(iso,t,p1));

post_diag_repair_priority_fuelmap(f1,p3)$[not fuel_map(f1,p3)] =
    post_diag_suggest_fuel_map_priority(f1,p3);
    
*------------------------------- MODEL PERFORMANCE DIAGNOSTICS -------------------------------*
post_kpi_total_seed_deviation =
    sum((iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        v_seed_deviation.l(iso,t,p1,f1,p2,p3,f2));

post_kpi_total_efficiency_excess =
    sum((iso,t,p1)$[total_input(iso,t,p1) gt 0],
        v_efficiency_excess.l(iso,t,p1));



post_kpi_total_augmented_share =
    sum((iso,t,p2,p3,f2),
        post_diag_augmented_map_share(iso,t,p2,p3,f2))
    / max(1e-9,
        sum((iso,t,p2,p3,f2),
            1$[post_diag_augmented_map_share(iso,t,p2,p3,f2)]));

post_kpi_total_manual_share =
    sum((iso,t,p2,p3,f2),
        post_diag_manual_map_share(iso,t,p2,p3,f2))
    / max(1e-9,
        sum((iso,t,p2,p3,f2),
            1$[post_diag_manual_map_share(iso,t,p2,p3,f2)]));

post_kpi_objective_breakdown_seed =
    penalty_weight_seed_deviation
  * sum((iso,t,p1,f1,p2,p3,f2)$allocation_domain(iso,t,p1,f1,p2,p3,f2),
        seed_deviation_weight(iso,t,p1,f1,p2,p3,f2)
      * v_seed_deviation.l(iso,t,p1,f1,p2,p3,f2));

post_kpi_objective_breakdown_efficiency =
    penalty_weight_efficiency_excess
  * sum((iso,t,p1)$[total_input(iso,t,p1) gt 0],
        v_efficiency_excess.l(iso,t,p1));

*------------------------------- HARD POST-SOLVE CHECKS -------------------------------*
abort$(smax((iso,t,p2,f)$plant_output(iso,t,p2,f),
            abs(post_diag_check_plant_balance(iso,t,p2,f))) > consistency_tolerance)
    "Plant-output aggregation is not exact.";

abort$(smax((iso,t,p3,f)$abs(fuel_output_balanced(iso,t,p3,f)),
            abs(post_diag_check_fuel_balance(iso,t,p3,f))) > consistency_tolerance)
    "Fuel-output aggregation is not exact.";

*------------------------------- EXPORT -------------------------------*
execute_unload '%ResultsGDX%'
$call gdxdump %ResultsGDX% output="allocated_output.csv" symb=post_out_allocated_output_export format=csv
*$call gdxdump %ResultsGDX% output="%ResultsXLSXpath%allocated_output.csv" symb=post_out_allocated_output format=csv
