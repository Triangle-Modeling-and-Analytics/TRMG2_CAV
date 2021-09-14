/*

*/

Macro "NonMotorized" (Args)

    RunMacro("Create NonMotorized Features", Args)
    RunMacro("Calculate NM Probabilities", Args)
    RunMacro("Separate NM Trips", Args)
    RunMacro("Aggregate HB NonMotorized Walk Trips", Args)
    RunMacro("NM Gravity", Args)

    return(1)
endmacro

/*
This macro creates features on the synthetic household and person tables
needed by the non-motorized model.
*/

Macro "Create NonMotorized Features" (Args)

    hh_file = Args.Households
    per_file = Args.Persons

    hh_vw = OpenTable("hh", "FFB", {hh_file})
    per_vw = OpenTable("per", "FFB", {per_file})
    hh_fields = {
        {"veh_per_adult", "Real", 10, 2,,,, "Vehicles per Adult"},
        {"inc_per_capita", "Real", 10, 2,,,, "Income per person in household"}
    }
    RunMacro("Add Fields", {view: hh_vw, a_fields: hh_fields})
    per_fields = {
        {"age_16_18", "Integer", 10, ,,,, "If person's age is 16-18"}
    }
    RunMacro("Add Fields", {view: per_vw, a_fields: per_fields})

    {v_size, v_kids, v_autos, v_inc} = GetDataVectors(
        hh_vw + "|", {"HHSize", "HHKids", "Autos", "HHInc"},
    )

    v_adult = v_size - v_kids
    v_vpa = v_autos / v_adult
    SetDataVector(hh_vw + "|", "veh_per_adult", v_vpa, )
    v_ipc = v_inc / v_size
    SetDataVector(hh_vw + "|", "inc_per_capita", v_vpa, )
    v_age = GetDataVector(per_vw + "|", "Age", )
    v_age_flag = if v_age >= 16 and v_age <= 18 then 1 else 0
    SetDataVector(per_vw + "|", "age_16_18", v_age_flag, )
endmacro

/*
Loops over each trip type and applies the binary choice model to split
trips into a "motorized" or "nonmotorized" mode.
*/

Macro "Calculate NM Probabilities" (Args)

    scen_dir = Args.[Scenario Folder]
    input_dir = Args.[Input Folder]
    input_nm_dir = input_dir + "/resident/nonmotorized"
    output_dir = Args.[Output Folder] + "/resident/nonmotorized"
    households = Args.Households
    persons = Args.Persons

    trip_types = RunMacro("Get HB Trip Types", Args)
    primary_spec = {Name: "person", OField: "ZoneID"}
    for trip_type in trip_types do
        // All escort-k12 trips are motorized so skip
        if trip_type = "W_HB_EK12_All" then continue

        obj = CreateObject("PMEChoiceModel", {ModelName: trip_type})
        obj.OutputModelFile = output_dir + "\\" + trip_type + ".mdl"
        obj.AddTableSource({
            SourceName: "se",
            File: scen_dir + "\\output\\sedata\\scenario_se.bin",
            IDField: "TAZ"
        })
        obj.AddTableSource({
            SourceName: "person",
            IDField: "PersonID",
            JoinSpec: {
                LeftFile: persons,
                LeftID: "HouseholdID",
                RightFile: households,
                RightID: "HouseholdID"
            }
        })
        util = RunMacro("Import MC Spec", input_nm_dir + "/" + trip_type + ".csv")
        obj.AddUtility({UtilityFunction: util})
        obj.AddPrimarySpec(primary_spec)
        nm_table = output_dir + "\\" + trip_type + ".bin"
        obj.AddOutputSpec({ProbabilityTable: nm_table})
        obj.Evaluate()
    end
endmacro

/*
This reduces the trip counts on the synthetic persons tables to represent
only the motorized person trips. The non-motorized person trips are stored
in separate tables in output/resident/nonmotorized.

TODO: This step spends a lot of time reading/writing. It could potentially be
sped up further by doing a single write to the person table at the end. This
only works if all NM output probability files have the exact same order
(it fills a joined view).
*/

Macro "Separate NM Trips" (Args)
    
    output_dir = Args.[Output Folder] + "/resident/nonmotorized"
    per_file = Args.Persons
    // periods = Args.periods
    
    per_vw = OpenTable("persons", "FFB", {per_file})

    trip_types = RunMacro("Get HB Trip Types", Args)

    for trip_type in trip_types do
        // All escort-k12 trips are motorized so skip
        if trip_type = "W_HB_EK12_All" then continue
        
        nm_file = output_dir + "/" + trip_type + ".bin"
        nm_vw = OpenTable("nm", "FFB", {nm_file})
        
        // Add fields to the NM table before joining
        a_fields_to_add = null
        output = null
        a_fields_to_add = a_fields_to_add + {
            {trip_type, "Real", 10, 2,,,, "Non-motorized person trips"}
        }
        RunMacro("Add Fields", {view: nm_vw, a_fields: a_fields_to_add})

        // Join tables and calculate results
        jv = JoinViews("jv", per_vw + ".PersonID", nm_vw + ".ID", )
        v_pct_nm = GetDataVector(jv + "|", "nonmotorized Probability", )
        nmoto_data = null
        per_fields = null
        per_fields = per_fields + {per_vw + "." + trip_type}
        person_data = GetDataVectors(jv + "|", per_fields, {OptArray: "true"})
        
            field_name = trip_type
            nmoto_data.(nm_vw + "." + field_name) = person_data.(per_vw + "." + field_name) * v_pct_nm
            person_data.(per_vw + "." + field_name) = person_data.(per_vw + "." + field_name) * (1 - v_pct_nm)
        
        SetDataVectors(jv + "|", nmoto_data, )
        SetDataVectors(jv + "|", person_data, )
        CloseView(jv)
        CloseView(nm_vw)
    end

    CloseView(per_vw)
endmacro


/*
Aggregates the non-motorized trips to TAZ
*/

Macro "Aggregate HB NonMotorized Walk Trips" (Args)

    hh_file = Args.Households
    per_file = Args.Persons
    se_file = Args.SE
    nm_dir = Args.[Output Folder] + "/resident/nonmotorized"

    per_df = CreateObject("df", per_file)
    per_df.select({"PersonID", "HouseholdID"})
    hh_df = CreateObject("df", hh_file)
    hh_df.select({"HouseholdID", "ZoneID"})
    per_df.left_join(hh_df, "HouseholdID", "HouseholdID")

    trip_types = RunMacro("Get HB Trip Types", Args)
    // Remove W_HB_EK12_All because it is all motorized by definition
    pos = trip_types.position("W_HB_EK12_All")
    trip_types = ExcludeArrayElements(trip_types, pos, 1)
    for trip_type in trip_types do
        file = nm_dir + "/" + trip_type + ".bin"
        vw = OpenTable("temp", "FFB", {file})
        v = GetDataVector(vw + "|", trip_type, )
        CloseView(vw)
        per_df.tbl.(trip_type) = v
    end
    per_df.group_by("ZoneID")
    per_df.summarize(trip_types, "sum")
    for trip_type in trip_types do
        per_df.rename("sum_" + trip_type, trip_type)
    end
    
    // Add the walk accessibility attractions from the SE bin file, which will
    // be used in the gravity application.
    se_df = CreateObject("df", se_file)
    se_df.select({"TAZ", "access_walk_attr"})
    se_df.left_join(per_df, "TAZ", "ZoneID")

    se_df.write_bin(nm_dir + "/_agg_nm_trips_daily.bin")
endmacro

/*

*/

Macro "NM Gravity" (Args)

    grav_params = Args.[Input Folder] + "/resident/nonmotorized/distribution/nm_gravity.csv"
    out_dir = Args.[Output Folder] 
    nm_dir = out_dir + "/resident/nonmotorized"
    prod_file = nm_dir + "/_agg_nm_trips_daily.bin"

    RunMacro("Gravity", {
        se_file: prod_file,
        skim_file: out_dir + "/skims/nonmotorized/walk_skim.mtx",
        param_file: grav_params,
        output_matrix: nm_dir + "/nm_gravity.mtx"
    })
endmacro