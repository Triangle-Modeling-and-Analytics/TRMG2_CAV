/*
Calculates aggregate mode choice probabilities between zonal ij pairs
*/

Macro "Calculate MC Probabilities" (Args)

    RunMacro("Create MC Features", Args)
    RunMacro("Calculate MC", Args)
    // TODO: remove if we aren't going to do this
    // RunMacro("Combine Logsum Files", Args)

    return(1)
endmacro

/*
Creates any additional fields/cores needed by the mode choice models
*/

Macro "Create MC Features" (Args)

    se_file = Args.SE
    hh_file = Args.Households

    hh_vw = OpenTable("hh", "FFB", {hh_file})
    se_vw = OpenTable("se", "FFB", {se_file})
    hh_fields = {
        {"HiIncome", "Integer", 10, ,,,, "IncomeCategory > 2"},
        {"HHSize1", "Integer", 10, ,,,, "HHSize = 1"},
        {"LargeHH", "Integer", 10, ,,,, "HHSize > 2"}
    }
    RunMacro("Add Fields", {view: hh_vw, a_fields: hh_fields})
    se_fields = {
        {"HiIncomePct", "Real", 10, 2,,,, "Percentage of households where IncomeCategory > 2"},
        {"HHSize1Pct", "Real", 10, 2,,,, "Percentage of households where HHSize = 1"},
        {"LargeHHPct", "Real", 10, 2,,,, "Percentage of households where HHSize > 1"}
    }
    RunMacro("Add Fields", {view: se_vw, a_fields: se_fields})

    {v_inc_cat, v_size} = GetDataVectors(hh_vw + "|", {"IncomeCategory", "HHSize"}, )
    data.HiIncome = if v_inc_cat > 2 then 1 else 0
    data.HHSize1 = if v_size = 1 then 1 else 0
    data.LargeHH = if v_size > 2 then 1 else 0
    SetDataVectors(hh_vw + "|", data, )
    grouped_vw = AggregateTable(
        "grouped_vw", hh_vw + "|", "FFB", GetTempFileName(".bin"), "ZoneID", 
        {{"HiIncome", "AVG", }, {"HHSize1", "AVG", }, {"LargeHH", "AVG"}}, 
        {"Missing As Zero": "true"}
    )
    jv = JoinViews("jv", se_vw + ".TAZ", grouped_vw + ".ZoneID", )
    v = nz(GetDataVector(jv + "|", "Avg HiIncome", ))
    SetDataVector(jv + "|", "HiIncomePct", v, )
    v = nz(GetDataVector(jv + "|", "Avg HHSize1", ))
    SetDataVector(jv + "|", "HHSize1Pct", v, )
    v = nz(GetDataVector(jv + "|", "Avg LargeHH", ))
    SetDataVector(jv + "|", "LargeHHPct", v, )

    CloseView(jv)
    CloseView(grouped_vw)
    CloseView(se_vw)
    CloseView(hh_vw)
endmacro

/*
Loops over purposes and preps options for the "MC" macro
*/

Macro "Calculate MC" (Args)

    scen_dir = Args.[Scenario Folder]
    skims_dir = scen_dir + "\\output\\skims\\"
    input_dir = Args.[Input Folder]
    input_mc_dir = input_dir + "/resident/mode"
    output_dir = Args.[Output Folder] + "/resident/mode"
    periods = Args.periods

    // Determine trip purposes
    prod_rate_file = input_dir + "/resident/generation/production_rates.csv"
    rate_vw = OpenTable("rate_vw", "CSV", {prod_rate_file})
    trip_types = GetDataVector(rate_vw + "|", "trip_type", )
    trip_types = SortVector(trip_types, {Unique: "true"})
    CloseView(rate_vw)

    opts = null
    opts.primary_spec = {Name: "w_lb_skim"}
    for trip_type in trip_types do
        if Lower(trip_type) = "w_hb_w_all"
            then opts.segments = {"v0", "ilvi", "ihvi", "ilvs", "ihvs"}
            else opts.segments = {"v0", "vi", "vs"}
        opts.trip_type = trip_type
        opts.util_file = input_mc_dir + "/" + trip_type + ".csv"
        nest_file = input_mc_dir + "/" + trip_type + "_nest.csv"
        if GetFileInfo(nest_file) <> null then opts.nest_file = nest_file

        for period in periods do
            opts.period = period
            
            // Determine which sov & hov skim to use
            if period = "MD" or period = "NT" then do
                tour_type = "All"
                homebased = "All"
            end else do
                tour_type = Upper(Left(trip_type, 1))
                homebased = "HB"
            end
            sov_skim = skims_dir + "roadway\\avg_skim_" + period + "_" + tour_type + "_" + homebased + "_sov.mtx"
            hov_skim = skims_dir + "roadway\\avg_skim_" + period + "_" + tour_type + "_" + homebased + "_hov.mtx"
            
            // Set sources
            opts.tables = {
                se: {File: scen_dir + "\\output\\sedata\\scenario_se.bin", IDField: "TAZ"},
                parking: {File: scen_dir + "\\output\\resident\\parking\\ParkingLogsums.bin", IDField: "TAZ"}
            }
            opts.matrices = {
                sov_skim: {File: sov_skim},
                hov_skim: {File: hov_skim},
                w_lb_skim: {File: skims_dir + "transit\\skim_" + period + "_w_lb.mtx"},
                w_eb_skim: {File: skims_dir + "transit\\skim_" + period + "_w_eb.mtx"},
                pnr_lb_skim: {File: skims_dir + "transit\\skim_" + period + "_pnr_lb.mtx"},
                pnr_eb_skim: {File: skims_dir + "transit\\skim_" + period + "_pnr_eb.mtx"},
                knr_lb_skim: {File: skims_dir + "transit\\skim_" + period + "_knr_lb.mtx"},
                knr_eb_skim: {File: skims_dir + "transit\\skim_" + period + "_knr_eb.mtx"}
            }
            opts.output_dir = output_dir
            RunMacro("MC", Args, opts)
        end
    end
endmacro

/*

*/

Macro "Combine Logsum Files" (Args)

    ls_dir = Args.[Output Folder] + "/resident/mode/logsums"
    periods = Args.periods

    trip_types = RunMacro("Get Trip Types", Args)
    for trip_type in trip_types do
        
        if Lower(trip_type) = "w_hb_w_all"
            then segments = {"v0", "ilvi", "ihvi", "ilvs", "ihvs"}
            else segments = {"v0", "vi", "vs"}

        for period in periods do

            a_mtx_to_combine = null
            a_files_to_delete = null
            for i = 1 to segments.length do
                segment = segments[i]

                mtx = CreateObject("Matrix")
                mtx_file = ls_dir + "/logsum_" + trip_type + "_" + segment + "_" + period + ".mtx"
                mtx.LoadMatrix(mtx_file)
                core_names = mtx._GetCoreNames()
                mh = mtx._GetMatrixHandle()
                for core in core_names do
                    SetMatrixCoreName(mh, core, core + "_" + segment)
                end
                a_mtx_to_combine = a_mtx_to_combine + {mh}
                a_files_to_delete = a_files_to_delete + {mtx_file}
            end
            out_file = ls_dir + "/logsum_" + trip_type + "_" + period + ".mtx"
            ConcatMatrices(a_mtx_to_combine, "true", {
                "File Name": out_file,
                Label: trip_type + " " + period
            })
            a_mtx_to_combine = null
            mtx = null
            mh = null
            for mtx in a_files_to_delete do
                DeleteFile(mtx)
            end
        end
    end
endmacro



    //         // Post process logsum matrix. Transform using log(1 + exp(LS))
    //         spec = {File: output_opts.Logsum, Tag: tag, Segment: seg}
    //         self.PostProcessLogsum(spec)

    // Macro "PostProcessLogsum"(spec) do
    //     seg = spec.Segment

    //     // Create NonHHAuto and Transit logsum
    //     m = OpenMatrix(spec.File,)
    //     cores = GetMatrixCoreNames(m)
    //     modified = 0
    //     if ArrayPosition(cores, {"nonhh_auto"},) > 0 then do
    //         if ArrayPosition(cores, {"NonHHAutoComposite"},) = 0 then
    //             AddMatrixCore(m, "NonHHAutoComposite")
            
    //         mc = CreateMatrixCurrency(m, "nonhh_auto",,,)
    //         mcOut = CreateMatrixCurrency(m, "NonHHAutoComposite",,,)
    //         mcOut := log(1 + nz(exp(mc)))
    //         mcOut = null
    //         mc = null
    //         modified = 1
    //     end

    //     /*
    //     if modified then do // Export to OMX. Export the root logsum and any of the others
    //         cores = GetMatrixCoreNames(m)
    //         mc = CreateMatrixCurrency(m, "ROOT",,,)
            
    //         // Get core position names for CopyMatrix() for selected cores. Daft.
    //         posRoot = ArrayPosition(cores, {"ROOT"},)
    //         posA = ArrayPosition(cores, {"AutoComposite"},)
    //         posT = ArrayPosition(cores, {"TransitComposite"},)
    //         posNA = ArrayPosition(cores, {"NonHHAutoComposite"},)
    //         pos = {posRoot} // {1} essentially
    //         if posA > 0 then
    //             pos = pos + {posA}
    //         if posT > 0 then
    //             pos = pos + {posT}
    //         if posNA > 0 then
    //             pos = pos + {posNA}

    //         pth = SplitPath(spec.File)
    //         fn = pth[1] + pth[2] + "OMX\\" + pth[3] + ".omx"
    //         mOpts = {"File Name": fn, OMX: "True", Label: "Logsum " + spec.Tag, Cores: pos}
    //         new_mat = CopyMatrix(mc, mOpts)
    //         new_mat = null
    //         mc = null
    //     end*/

    //     m = null
    // enditem