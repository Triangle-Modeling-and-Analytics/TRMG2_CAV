/*
A class that implements a nested DC model

Inputs
* output_dir
    * String
    * Output directory where subfolders and files will be written.
* trip_type
    * String
    * Name of the trip type/purpose
* zone_utils
    * String
    * File path of the CSV file containing utility terms for zonal choice
* cluster_utils
    * String
    * File path of the CSV file containing utility terms for cluster choice
* cluster_thetas
    * String
    * File path of the CSV file containing theta/nesting coefficients for cluster choice
* period
    * Optional string (default: null)
    * Time of day. Only used for file naming, so you can use "daily", "all",
    * "am", or just leave it blank.
* segments
    * Optional array of strings (default: null)
    * Names of market segments. If provided, MC will be applied in a loop
    over the segments.
* primary_spec
    * An array that configures the primary data source. It includes
    * Name: the name of the data source (matching `source_name` in `tables` or `matices`)
    * If the primary source is a table, then it also includes:
        * OField: name of the origin field
        * DField: name of the destination field (if applicable)
* dc_spec
    * Array
    * Specifies where to find the list of destination zones.
    * Example: {DestinationsSource: "sov_skim", DestinationsIndex: "Destination"}
* cluster_equiv_spec
    * Array
    * Specifies the file and fields used to build clusters from zones
    * Example: {File: "se.bin", ZoneIDField: "TAZ", ClusterIDField: "Cluster"}
* tables
    * Optional array of table sources (default: null)
    * `tables` and `matrices` cannot both be null
    * Each item in `tables` must include:
    * source_name: (string) name of the source
    * File: (string) file path of the table
    * IDField: (string) name of the ID field in the table
* matrices
    * Optional array of matrix sources(default: null)
    * `tables` and `matrices` cannot both be null
    * Each item in `matrices` must include:
    * source_name: (string) name of the source
    * File: (string) file path of the matrix
*/

Class "NestedDC" (ClassOpts)

    init do
        if ClassOpts.output_dir = null then Throw("NestedDC: 'output_dir' is null")
        if ClassOpts.trip_type = null then Throw("NestedDC: 'trip_type' is null")
        if ClassOpts.period = null then Throw("NestedDC: 'period' is null")
        if ClassOpts.segments = null then ClassOpts.segments = {null}
        if ClassOpts.zone_utils = null then Throw("NestedDC: 'zone_utils' is null")
        if ClassOpts.cluster_utils = null then Throw("NestedDC: 'cluster_utils' is null")
        if ClassOpts.cluster_thetas = null then Throw("NestedDC: 'cluster_thetas' is null")
        if ClassOpts.primary_spec = null then Throw("NestedDC: 'primary_spec' is null")
        if ClassOpts.dc_spec = null then Throw("NestedDC: 'dc_spec' is null")
        if ClassOpts.cluster_equiv_spec = null then Throw("NestedDC: 'cluster_equiv_spec' is null")
        if ClassOpts.tables = null then Throw("NestedDC: 'tables' is null")
        if ClassOpts.matrices = null then Throw("NestedDC: 'matrices' is null")

        self.ClassOpts = ClassOpts
        self.ClassOpts.mdl_dir = ClassOpts.output_dir + "/model_files"
        self.ClassOpts.prob_dir = ClassOpts.output_dir + "/probabilities"
        self.ClassOpts.logsum_dir = ClassOpts.output_dir + "/logsums"
        self.ClassOpts.util_dir = ClassOpts.output_dir + "/utilities"
    enditem

    Macro "Run" do
        // Run zone-level DC
        self.util_file = self.ClassOpts.zone_utils
        self.zone_level = "true"
        self.RunChoiceModels(zone_opts)
        
        // Build cluster-level choice data
        self.BuildClusterData()

        // Run cluster-level model
        self.util_file = self.ClassOpts.cluster_utils
        self.zone_level = "false"
        self.dc_spec = {DestinationsSource: "mtx", DestinationsIndex: "Col_AggregationID"}
        self.RunChoiceModels(cluster_opts)
    enditem

    /*
    Generic choice model calculator.

    Inputs (other than Class inputs)
    * util_file
        * String
        * Either `zone_utils` or `cluster_utils` from the ClassOpts
    * zone_level
        * True/False
        * If this is being run on the zone level (false = cluster level)
    */

    Macro "RunChoiceModels" do
        
        util_file = self.util_file
        zone_level = self.zone_level
        dc_spec = self.ClassOpts.dc_spec
        trip_type = self.ClassOpts.trip_type
        segments = self.ClassOpts.segments
        period = self.ClassOpts.period
        tables = self.ClassOpts.tables
        matrices = self.ClassOpts.matrices
        primary_spec = self.ClassOpts.primary_spec

        // Create output subdirectories
        mdl_dir = self.ClassOpts.mdl_dir
        if GetDirectoryInfo(mdl_dir, "All") = null then CreateDirectory(mdl_dir)
        prob_dir = self.ClassOpts.prob_dir
        if GetDirectoryInfo(prob_dir, "All") = null then CreateDirectory(prob_dir)
        logsum_dir = self.ClassOpts.logsum_dir
        if GetDirectoryInfo(logsum_dir, "All") = null then CreateDirectory(logsum_dir)
        util_dir = self.ClassOpts.util_dir
        if GetDirectoryInfo(util_dir, "All") = null then CreateDirectory(util_dir)

        // Import util CSV file into an options array
        util = self.ImportChoiceSpec(util_file)
        
        // if nest_file <> null then nest_tree = self.ImportChoiceSpec(nest_file)

        for seg in segments do
            tag = trip_type
            if seg <> null then tag = tag + "_" + seg
            if period <> null then tag = tag + "_" + period

            // Set up and run model
            obj = CreateObject("PMEChoiceModel", {ModelName: tag})
            obj.Segment = seg

            if zone_level then do
                obj.OutputModelFile = mdl_dir + "\\" + tag + "_zone.dcm"
            end else do
                obj.OutputModelFile = mdl_dir + "\\" + tag + "_cluster.dcm"
                matrices = matrices + {
                    mtx: {File: logsum_dir + "/agg_zonal_ls_" + tag + ".mtx"}
                }
            end
            
            // Add sources
            for i = 1 to tables.length do
                source_name = tables[i][1]
                source = tables.(source_name)

                obj.AddTableSource({
                    SourceName: source_name,
                    File: source.file,
                    IDField: source.IDField,
                    JoinSpec: source.JoinSpec
                })
            end
            for i = 1 to matrices.length do
                source_name = matrices[i][1]
                source = matrices.(source_name)

                obj.AddMatrixSource({
                    SourceName: source_name,
                    File: source.file
                })
            end

            // Add alternatives, utility and specify the primary source
            // if nest_tree <> null then
            //     obj.AddAlternatives({AlternativesTree: nest_tree})
            if zone_level 
                then obj.AddPrimarySpec(primary_spec)
                else obj.AddPrimarySpec({Name: "mtx"})
            obj.AddDestinations(dc_spec)
            obj.AddUtility({UtilityFunction: util})
            
            // Specify outputs
            if zone_level then do
                output_opts = {
                    Probability: prob_dir + "\\probability_" + tag + "_zone.mtx",
                    Utility: util_dir + "\\utility_" + tag + "_zone.mtx"
                }
            end else do
                output_opts = {
                    Probability: prob_dir + "\\probability_" + tag + "_cluster.mtx",
                    Utility: util_dir + "\\utility_" + tag + "_cluster.mtx",
                    Logsum: logsum_dir + "\\logsum_" + tag + "_cluster.mtx"
                }
            end
            obj.AddOutputSpec(output_opts)
            
            //obj.CloseFiles = 0 // Uncomment to leave files open, so you can save a workspace
            ret = obj.Evaluate()
            if !ret then
                Throw("Running mode choice model failed for: " + tag)
            obj = null
        end
    enditem

    Macro "ImportChoiceSpec" (file) do
        vw = OpenTable("Spec", "CSV", {file,})
        {flds, specs} = GetFields(vw,)
        vecs = GetDataVectors(vw + "|", flds, {OptArray: 1})
        
        util = null
        for fld in flds do
            util.(fld) = v2a(vecs.(fld))
        end
        CloseView(vw)
        Return(util)
    enditem

    /*
    Aggregates the DC logsums into cluster-level values
    */

    Macro "BuildClusterData" do

        trip_type = self.ClassOpts.trip_type
        period = self.ClassOpts.period
        segments = self.ClassOpts.segments
        equiv_spec = self.ClassOpts.cluster_equiv_spec
        util_dir = self.ClassOpts.util_dir
        logsum_dir = self.ClassOpts.logsum_dir
        cluster_thetas = self.ClassOpts.cluster_thetas

        // Collect vectors of cluster names, IDs, and theta values
        theta_vw = OpenTable("thetas", "CSV", {cluster_thetas})
        {
            v_cluster_ids, v_cluster_names, v_cluster_theta, v_cluster_asc,
            v_cluster_ic
        } = GetDataVectors(
            theta_vw + "|",
            {"Cluster", "ClusterName", "Theta", "ASC", "IC"},
        )
        CloseView(theta_vw)

        for segment in segments do
            name = trip_type + "_" + segment + "_" + period
            mtx_file = util_dir + "/utility_" + name + "_zone.mtx"
            mtx = CreateObject("Matrix", mtx_file)
            mtx.AddCores({"ScaledTotal", "ExpScaledTotal", "IntraCluster"})
            cores = mtx.data.cores

            // The utilities must be scaled by the cluster thetas, which requires
            // an index for each cluster
            cores.ScaledTotal := cores.Total
            self.CreateClusterIndices(mtx)
            for i = 1 to v_cluster_ids.length do
                cluster_id = v_cluster_ids[i]
                cluster_name = v_cluster_names[i]
                theta = v_cluster_theta[i]

                mtx.SetColIndex(cluster_name)
                cores = mtx.data.cores
                cores.ScaledTotal := cores.ScaledTotal / theta

                // Also mark intra-cluster ij pairs
                mtx.SetRowIndex(cluster_name)
                cores = mtx.data.cores
                cores.IntraCluster := 1
                mtx.SetRowIndex("Origins")
            end

            // e^(scaled_x)
            mtx.SetColIndex("Destinations")
            cores = mtx.data.cores
            cores.ExpScaledTotal := exp(mtx.data.cores.scaledTotal)

            // Aggregate the columns into clusters
            agg = mtx.Aggregate({
                Matrix: {MatrixFile: logsum_dir + "/agg_zonal_ls_" + name + ".mtx", MatrixLabel: "Cluster Logsums"},
                Matrices: {"ExpScaledTotal", "IntraCluster"}, 
                Method: "Sum",
                Rows: {
                    Data: equiv_spec.File, 
                    MatrixID: equiv_spec.ZoneIDField, 
                    AggregationID: equiv_spec.ZoneIDField // i.e. don't aggregate rows
                },
                Cols: {
                    Data: equiv_spec.File, 
                    MatrixID: equiv_spec.ZoneIDField, 
                    AggregationID: equiv_spec.ClusterIDField
                }
            })
            o = CreateObject("Matrix", agg)
            o.AddCores({"LnSumExpScaledTotal", "final", "ic", "asc"})
            cores = o.data.cores
            cores.LnSumExpScaledTotal := Log(cores.[Sum of ExpScaledTotal])
            cores.final := cores.LnSumExpScaledTotal * v_cluster_theta
            cores.ic := if nz(cores.[Sum of IntraCluster]) > 0 then 1 else 0
            cores.ic := cores.ic * v_cluster_ic
            cores.asc := v_cluster_asc
            
            // TODO: this is needed because Matrix.Aggregate() is not writing to
            // the correct place, but to a temp file. Remove after fixing
            // Matrix.Aggregate()
            temp_file = agg.Name
            agg = null
            CopyFile(temp_file, logsum_dir + "/agg_zonal_ls_" + name + ".mtx")

            // // Export a table of IntraCluster flags with cluster names
            // // instead of IDs
            // opts.v_cluster_ids = v_cluster_ids
            // opts.v_cluster_names = v_cluster_names
            // opts.mc = cores.[Sum of IntraCluster]
            // opts.out_file = logsum_dir + "/cluster_ic_" + name + ".bin"
            // self.WriteClusterTables(opts)
            // opts.mc = cores.final
            // opts.out_file = logsum_dir + "/agg_zonal_ls_" + name + ".bin"
            // self.WriteClusterTables(opts)
        end
    enditem

    /*
    Creates indices that can be used to select the zones in each cluster
    */

    Macro "CreateClusterIndices" (mtx) do
        
        cluster_thetas = self.ClassOpts.cluster_thetas
        equiv_spec = self.ClassOpts.cluster_equiv_spec

        theta_vw = OpenTable("thetas", "CSV", {cluster_thetas})
        {v_cluster_ids, v_cluster_names} = GetDataVectors(
            theta_vw + "|",
            {"Cluster", "ClusterName"},
        )
        CloseView(theta_vw)

        for i = 1 to v_cluster_ids.length do
            cluster_id = v_cluster_ids[i]
            cluster_name = v_cluster_names[i]

            mtx.AddIndex({
                Matrix: mtx.data.MatrixHandle,
                IndexName: cluster_name,
                Filter: "Cluster = " + String(cluster_id),
                Dimension: "Both",
                TableName: equiv_spec.File,
                OriginalID: equiv_spec.ZoneIDField,
                NewID: equiv_spec.ZoneIDField
            })
        end
    enditem

    Macro "WriteClusterTables" (MacroOpts) do

        mc = MacroOpts.mc
        out_file = MacroOpts.out_file
        v_cluster_ids = MacroOpts.v_cluster_ids
        v_cluster_names = MacroOpts.v_cluster_names

        col_ids = V2A(GetMatrixVector(mc, {Index: "Column"}))
        ExportMatrix(
            mc,
            col_ids,
            "Rows",
            "FFB",
            out_file,
        )
        // Convert the column names from IDs to names
        vw = OpenTable("ls", "FFB", {out_file})
        for i = 1 to v_cluster_ids.length do
            id = v_cluster_ids[i]
            name = v_cluster_names[i]
            RunMacro("Rename Field", vw, String(id), name)
        end
        RunMacro("Rename Field", vw, "Row_AggregationID", "TAZ")
        CloseView(vw)
    enditem
endclass