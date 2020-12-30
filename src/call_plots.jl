#=
function _get_matching_param(var_name)
    return Symbol(replace(string(var_name), SUPPORTEDVARPREFIX => SUPPORTEDPARAMPREFIX))
end

function _get_matching_var(param_name)
    return Symbol(replace(string(param_name), SUPPORTEDPARAMPREFIX => SUPPORTEDVARPREFIX))
end

function _filter_results(results::IS.Results; kwargs...)
    names = get(kwargs, :names, nothing)
    load = get(kwargs, :load, false)
    initial_time = get(kwargs, :initial_time, nothing)
    len = get(kwargs, :horizon, nothing)

    existing_var_names = PSI.get_existing_variables(results)
    existing_param_names = PSI.get_existing_parameters(results)

    if isnothing(names)
        var_names = existing_var_names
        param_names = existing_param_names
    else
        var_names = names
        load && ILOAD_VARIABLE in existing_var_names && push!(var_names, ILOAD_VARIABLE)
        param_names =
            [v for v in _get_matching_param.(var_names) if v in existing_param_names]
        load && LOAD_PARAMETER in existing_param_names && push!(param_names, LOAD_PARAMETER)
    end

    filter_variables = [
        key
        for
        key in var_names if startswith("$key", SUPPORTEDVARPREFIX) | any(key .== SLACKVARS)
    ]

    filter_parameters =
        [key for key in param_names if startswith("$key", SUPPORTEDPARAMPREFIX)]

    parameter_values =
        _filter_parameters(results, filter_parameters, load, initial_time, len)
    variable_values = PSI.read_realized_variables(
        results;
        names = filter_variables,
        len = len,
        initial_time = initial_time,
    )

    # fixed output should be added to plots when there exists a parameter of the form
    # :P__max_active_power__SUPPORTEDGENPARAMS but there is no corresponding
    # :P__SUPPORTEDGENPARAMS variable
    for param in filter_parameters
        endswith(string(param), string(LOAD_PARAMETER)) && continue
        if startswith(string(param), SUPPORTEDPARAMPREFIX)
            var_name = _get_matching_var(param)
            if !haskey(variable_values, var_name)
                variable_values[var_name] = parameter_values[param]
            end
        end
    end

    curtailment = get(kwargs, :curtailment, false)
    if curtailment
        curtailment_parameters =
            _curtailment_parameters(filter_parameters, filter_variables)
        _filter_curtailment!(variable_values, parameter_values, curtailment_parameters)
    end
    if load && !haskey(IS.get_parameters(results), LOAD_PARAMETER)
        @warn "$LOAD_PARAMETER not found in results parameters."
    end
    timestamps = DataFrames.DataFrame(
        :DateTime => PSI.get_realized_timestamps(
            results;
            initial_time = initial_time,
            len = len,
        ),
    )
    new_results = Results(
        results.base_power,
        variable_values, #variables
        Dict(), #total_cost
        Dict(), #optimiizer_log
        timestamps, #timestamp
        Dict{Symbol, DataFrames.DataFrame}(), #dual
        parameter_values,
    )
    return new_results
end

function _filter_reserves(results::IS.Results; initial_time = nothing, len = nothing)
    filter_up_reserves = Vector{Symbol}()
    filter_down_reserves = Vector{Symbol}()
    for key in PSI.get_existing_variables(results)
        if any(endswith.(string(key), UP_RESERVES))
            push!(filter_up_reserves, key)
        elseif any(endswith.(string(key), DOWN_RESERVES))
            push!(filter_down_reserves, key)
        end
    end
    if isempty(filter_up_reserves) && isempty(filter_down_reserves)
        @warn "No reserves found in results."
        return nothing
    else
        return Dict(
            "Up" => PSI.read_realized_variables(
                results,
                names = filter_up_reserves,
                initial_time = initial_time,
                len = len,
            ),
            "Down" => PSI.read_realized_variables(
                results,
                names = filter_down_reserves,
                initial_time = initial_time,
                len = len,
            ),
        )
    end
end

function _curtailment_parameters(parameters::Vector{Symbol}, variables::Vector{Symbol})
    curtailment_parameters =
        Vector{NamedTuple{(:parameter, :variable), Tuple{Symbol, Symbol}}}()
    for var in variables
        var_param = Symbol(replace(string(var), "P__" => "P__max_active_power__"))
        if var_param in parameters
            push!(curtailment_parameters, (parameter = var_param, variable = var))
        end
    end
    return curtailment_parameters
end

function _filter_curtailment!(
    variable_values::Dict,
    parameter_values::Dict,
    curtailment_parameters::Vector{
        NamedTuple{(:parameter, :variable), Tuple{Symbol, Symbol}},
    },
)
    for curtailment in curtailment_parameters
        if !haskey(variable_values, curtailment.variable)
            variable_values[curtailment.variable] = parameter_values[curtailment.parameter]
        else
            curt =
                parameter_values[curtailment.parameter] .-
                variable_values[curtailment.variable]
            if haskey(variable_values, :Curtailment)
                variable_values[:Curtailment] = hcat(variable_values[:Curtailment], curt)
            else
                variable_values[:Curtailment] = curt
            end
        end
    end
end

function _filter_parameters(
    results::IS.Results,
    filter_parameters::Vector{Symbol},
    load::Bool,
    initial_time,
    len,
)
    parameters = Vector{Symbol}()
    negative_parameters = Vector{Symbol}()
    for key in filter_parameters
        param = split("$key", "_")[end]
        if param in SUPPORTEDGENPARAMS
            push!(parameters, key)
        elseif load && (param in SUPPORTEDLOADPARAMS)
            push!(parameters, key)
            param in NEGATIVE_PARAMETERS && push!(negative_parameters, key)
        end
    end
    parameter_values = PSI.read_realized_parameters(
        results;
        names = parameters,
        len = len,
        initial_time = initial_time,
    )
    for param in negative_parameters
        parameter_values[param] = parameter_values[param] .* -1.0
    end
    return parameter_values
end
=#

function _empty_plot()
    backend = Plots.backend()
    return _empty_plot(backend)
end
#=
"""
    plot_fuel(results)

This function makes a stack plot of the results by fuel type
and assigns each fuel type a specific color.

# Arguments

- `res::Union{Results, Vector{IS.Results}}`: results to be plotted

# Example

```julia
res = solve_op_problem!(OpProblem)
plot = plot_fuel(res)
```

# Accepted Key Words
- `display::Bool`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "html"`: set a different format for saving a PlotlyJS plot
- `seriescolor::Array`: Set different colors for the plots
- `title::String = "Title"`: Set a title for the plots
- `curtailment::Bool`: To plot the curtailment in the stack plot
- `load::Bool`: To plot the load line in the plot
- `stair::Bool`: Make a stair plot instead of a stack plot
- `generator_mapping_file` = "file_path" : file path to yaml definig generator category by fuel and primemover
- `variables::Union{Nothing, Vector{Symbol}}` = nothing : specific variables to plot
"""
function plot_fuel(result::IS.Results; kwargs...)
    return plot_fuel([result]; kwargs...)
end

function plot_fuel(results::Array; kwargs...)
    backend = Plots.backend()
    set_display = get(kwargs, :set_display, true)
    save_fig = get(kwargs, :save, nothing)

    stack = StackedGeneration[]
    bar = BarGeneration[]
    base_power = nothing
    time_interval = nothing
    for result in results
        pg_result = _filter_results(result; kwargs...)
        base_power = IS.get_base_power(pg_result)
        time_interval =
            IS.get_timestamp(pg_result)[2, 1] - IS.get_timestamp(pg_result)[1, 1]

        generator_dict = make_fuel_dictionary(PSI.get_system(result); kwargs...)
        push!(stack, get_stacked_aggregation_data(pg_result, generator_dict))
        push!(bar, get_bar_aggregation_data(pg_result, generator_dict))
    end
    default_colors = match_fuel_colors(stack[1], bar[1], backend, FUEL_DEFAULT)
    seriescolor = get(kwargs, :seriescolor, default_colors)
    title = get(kwargs, :title, "Fuel")

    ylabel = (stack = _make_ylabel(base_power), bar = _make_bar_ylabel(base_power))
    if isnothing(backend)
        throw(IS.ConflictingInputsError("No backend detected. Type gr() to set a backend."))
    end
    interval = Dates.Millisecond(Dates.Hour(1)) / time_interval
    return _plot_fuel_internal(
        stack,
        bar,
        seriescolor,
        backend,
        save_fig,
        set_display,
        title,
        ylabel,
        interval;
        kwargs...,
    )
end
=#

#=
"""
   bar_plot(results::IS.Results)

This function plots a bar plot for the generators in each variable within
the results variables dictionary, and makes a bar plot for all of the variables.

# Arguments
- `res::Union{Results, Vector{IS.Results}}`: results to be plotted

# Example

```julia
results = solve_op_problem!(OpProblem)
plot = bar_plot(results)
```

# Accepted Key Words
- `display::Bool`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "html"`: set a different format for saving a PlotlyJS plot
- `seriescolor::Array`: Set different colors for the plots
- `load::Bool`: plot the load line
- `title::String = "Title"`: Set a title for the plots
- `reserve::Bool`: add reserve plot
- `variables::Union{Nothing, Vector{Symbol}}` = nothing : specific variables to plot

"""

function bar_plot(results::IS.Results; kwargs...)
    return bar_plot([results]; kwargs...)
end

function bar_plot(results::Array; kwargs...)
    plt_backend = Plots.backend()
    set_display = get(kwargs, :display, true)
    save_fig = get(kwargs, :save, nothing)
    reserve = get(kwargs, :reserves, false)
    initial_time = get(kwargs, :initial_time, nothing)
    len = get(kwargs, :horizon, nothing)

    reserves = []
    pg_results = []
    for result in results
        push!(reserves, reserve ? _filter_reserves(result, initial_time = initial_time, len = len) : nothing)
        push!(pg_results, _filter_results(result; kwargs...))
    end

    if isnothing(backend)
        throw(IS.ConflictingInputsError("No backend detected. Type gr() to set a backend."))
    end

    time_interval =
        IS.get_timestamp(pg_results[1])[2, 1] - IS.get_timestamp(pg_results[1])[1, 1]
    interval = Dates.Millisecond(Dates.Hour(1)) / time_interval
    plots = _bar_plot_internal(
        pg_results,
        plt_backend,
        save_fig,
        set_display,
        interval,
        reserves;
        kwargs...,
    )
    return plots
end

"""
     stack_plot(results)

This function plots a stack plot for the generators in each variable within
the results variables dictionary, and makes a stack plot for all of the variables.

# Arguments
- `res::Union{Results, Vector{IS.Results}}`: results to be plotted

# Examples

```julia
results = solve_op_problem!(OpProblem)
plot = stack_plot(results)
```

# Accepted Key Words
- `display::Bool`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "png"`: Set a different default format for saving PlotlyJS
- `seriescolor::Array`: Set different colors for the plots
- `stair::Bool`: make a stair plot instead of a stack plot
- `title::String = "Title"`: Set a title for the plots
- `load::Bool`: plot the load line
- `names::Union{Nothing, Vector{Symbol}}` = nothing : specific variables to plot
"""

function stack_plot(res::IS.Results; kwargs...)
    return stack_plot([res]; kwargs...)
end

function stack_plot(results::Array{}; kwargs...)
    backend = Plots.backend()
    set_display = get(kwargs, :set_display, true)
    save_fig = get(kwargs, :save, nothing)
    reserve = get(kwargs, :reserves, false)
    initial_time = get(kwargs, :initial_time, nothing)
    len = get(kwargs, :horizon, nothing)
    if get(kwargs, :stair, false)
        kwargs = hcat(kwargs..., :stairs => "hv")
        kwargs = hcat(kwargs..., :linetype => :steppost)
    end

    reserves = []
    pg_results = []
    for result in results
        push!(reserves, reserve ? _filter_reserves(result, initial_time = initial_time, len = len) : nothing)
        push!(pg_results, _filter_results(result; kwargs...))
    end

    if isnothing(backend)
        throw(IS.ConflictingInputsError("No backend detected. Type gr() to set a backend."))
    end
    return _stack_plot_internal(
        pg_results,
        backend,
        save_fig,
        set_display,
        reserves;
        kwargs...,
    )
end
=#
function _make_ylabel(base_power::Float64)
    if isapprox(base_power, 1.0)
        ylabel = "Generation (MW)"
    elseif isapprox(base_power, 1000.0)
        ylabel = "Generation (GW)"
    else
        ylabel = "Generation (MW x$base_power)"
    end
    return ylabel
end

function _make_bar_ylabel(base_power::Float64)
    if isapprox(base_power, 1.0)
        ylabel = "Generation (MWh)"
    elseif isapprox(base_power, 1000.0)
        ylabel = "Generation (GWh)"
    else
        ylabel = "Generation (MWh x$base_power)"
    end
    return ylabel
end

################################### DEMAND #################################

"""
    plot_demand(results)

This function makes a plot of the demand in the system.

# Arguments

- `res::Union{Results, Vector{IS.Results}}`: results to be plotted

# Example

```julia
res = solve_op_problem!(OpProblem)
plot = plot_demand(res)
```

# Accepted Key Words
- `display::Bool`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "html"`: set a different format for saving a PlotlyJS plot
- `seriescolor::Array`: Set different colors for the plots
- `title::String = "Title"`: Set a title for the plots
- `horizon::Int64 = 12`: To plot a shorter window of time than the full results
- `initial_time::DateTime`: To start the plot at a different time other than the results initial time
- `aggregate::String = "System", "PowerLoad", or "Bus"`: aggregate the demand other than by generator
"""

function plot_demand(result::IS.Results; kwargs...)
    return plot_demand(nothing, result; kwargs...)
end
function plot_demand(p::Union{Plots.Plot, Nothing}, result::IS.Results; kwargs...)
    backend = Plots.backend()
    set_display = get(kwargs, :set_display, true)
    save_fig = get(kwargs, :save, nothing)
    title = get(kwargs, :title, "Demand")

    load = get_load_data(result; kwargs...)
    load_agg = combine_categories(load.data) .* -1.0
    p = plot_dataframe(
        p,
        load_agg,
        load.time;
        seriescolor = ["black"],
        linestyle = :dash,
        linewidth = 3,
        y_label = _make_ylabel(result.base_power),
        title = title,
        kwargs...,
    )

    set_display && display(p)
    if !isnothing(save_fig)
        title = replace(title, " " => "_")
        Plots.savefig(p, joinpath(save_fig, "$(title).png"))
    end
    return p
end

function plot_demand(results::Array; kwargs...)
    backend = Plots.backend()
    set_display = get(kwargs, :set_display, true)
    save_fig = get(kwargs, :save, nothing)

    demand_plots = []
    for result in results
        p = plot_demand(result; kwargs)
        push!(demand_plots, p)
    end
    p1 = Plots.plot(demand_plots...; layout = (length(results), 1))
    set_display && display(p1)
    if !isnothing(save_fig)
        title = replace(title, " " => "_")
        stack_title = linetype == :line ? "$(title)_Stack" : "$(title)_Stair"
        Plots.savefig(p1, joinpath(save_fig, "$(stack_title).png"))
    end
    return PlotList(Dict(:Fuel_Stack => p1))#, :Fuel_Bar => p2))
end

################################### INPUT DEMAND #################################

function _get_loads(system::PSY.System, bus::PSY.Bus)
    return [
        load
        for load in PSY.get_components(PSY.PowerLoad, system) if PSY.get_bus(load) == bus
    ]
end
function _get_loads(system::PSY.System, agg::T) where {T <: PSY.AggregationTopology}
    return PSY.get_components_in_aggregation_topology(PSY.PowerLoad, system, agg)
end
function _get_loads(system::PSY.System, load::PSY.PowerLoad)
    return [load]
end
function _get_loads(system::PSY.System, sys::PSY.System)
    return PSY.get_components(PSY.PowerLoad, system)
end

function make_demand_plot_data(
    system::PSY.System,
    aggregation::Union{
        Type{PSY.PowerLoad},
        Type{PSY.Bus},
        Type{PSY.System},
        Type{<:PSY.AggregationTopology},
    } = PSY.PowerLoad;
    kwargs...,
)
    aggregation_components =
        aggregation == PSY.System ? [system] : PSY.get_components(aggregation, system)
    if isempty(aggregation_components)
        throw(ArgumentError("System does not have type $aggregation."))
    end
    horizon = get(kwargs, :horizon, PSY.get_forecast_horizon(system))
    initial_time = get(kwargs, :initial_time, PSY.get_forecast_initial_timestamp(system))
    parameters = DataFrames.DataFrame(timestamp = Dates.DateTime[])
    PSY.set_units_base_system!(system, "SYSTEM_BASE")
    for agg in aggregation_components
        loads = _get_loads(system, agg)
        length(loads) == 0 && continue
        colname = aggregation == PSY.System ? "System" : PSY.get_name(agg)
        load_values = []
        for load in loads
            f = PSY.get_time_series_array(
                PSY.Deterministic,
                load,
                "max_active_power",
                start_time = initial_time,
                len = horizon,
            )
            push!(load_values, values(f))
            parameters = DataFrames.outerjoin(
                parameters,
                DataFrames.DataFrame(timestamp = TimeSeries.timestamp(f)),
                on = :timestamp,
                makeunique = false,
                indicator = nothing,
                validate = (false, false),
            )
        end
        load_values =
            length(loads) == 1 ? load_values[1] :
            dropdims(sum(Matrix(reduce(hcat, load_values)), dims = 2), dims = 2)
        parameters[:, Symbol(colname)] = load_values
    end
    save_fig = get(kwargs, :save, nothing)
    return parameters
end

"""
    plot_demand(system)

This function makes a plot of the demand in the system.

# Arguments

- `sys::Union{PSY.System, Vector{PSY.System}}`: the system to be plotted

# Example

```julia
plot = plot_demand(sys)
```

# Accepted Key Words
- `display::Bool`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "html"`: set a different format for saving a PlotlyJS plot
- `seriescolor::Array`: Set different colors for the plots
- `title::String = "Title"`: Set a title for the plots
- `horizon::Int64 = 12`: To plot a shorter window of time than the full results
- `initial_time::DateTime`: To start the plot at a different time other than the results initial time
- `aggregate::String = "System", "PowerLoad", or "Bus"`: aggregate the demand other than by generator
"""

function plot_demand(system::PSY.System; kwargs...)
    return plot_demand([system]; kwargs...)
end

function plot_demand(systems::Array{PSY.System}; kwargs...)
    parameter_list = []
    base_powers = []
    aggregation = get(kwargs, :aggregate, PSY.PowerLoad)
    for system in systems
        push!(base_powers, PSY.get_base_power(system))
        push!(parameter_list, make_demand_plot_data(system, aggregation; kwargs...))
    end
    backend = Plots.backend()
    return _demand_plot_internal(parameter_list, base_powers, backend; kwargs...)
end

################################## Plot Forecasts ###########################
#=
function plot_forecast(forecast; kwargs...)
end
=#

################################# Plotting a Single Variable ##########################
#=
"""
    plot_variable(results, variable_name)
    plot_variable(plot, results, variable_name)

This function makes a plot of a specific variable

# Arguments

- `result::Results = result`: results to be plotted
- `variable::Union{String, Symbol}`: The variable name to be plotted

# Example

```julia
res = solve_op_problem!(OpProblem)
plot = plot_variable(res, variable)
```

# Accepted Key Words
- `display::Bool`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "html"`: set a different format for saving a PlotlyJS plot
- `seriescolor::Array`: Set different colors for the plots
- `title::String = "Title"`: Set a title for the plots
- `curtailment::Bool`: plot the curtailment with the variable
- `load::Bool`: plot the load with the variable
"""
function plot_variable(result::IS.Results, variable_name::Union{Symbol, String}; kwargs...)
    return plot_variable(_empty_plot(), result, variable_name; kwargs...)
end

function plot_variable(
    plot::Any,
    result::IS.Results,
    variable_name::Union{Symbol, String};
    kwargs...,
)
    var = Symbol(variable_name)
    pg_result = _filter_results(result, names = [var]; kwargs...)
    variable = pg_result.variable_values[var]
    time_range = IS.get_timestamp(pg_result)[:, 1]
    plots = _variable_plots_internal(
        plot,
        variable,
        time_range,
        IS.get_base_power(pg_result),
        var,
        Plots.backend();
        kwargs...,
    )
    return plots
end
=#

################################# Plotting a Single DataFrame ##########################

"""
    plot_dataframe(df, time_range)
    plot_dataframe(plot, variable, time_range)

This function makes a plot of a specific dataframe and time range, not necessarily from the results

# Arguments

- `df::DataFrames.DataFrame`: The dataframe to be plotted
- `time_range::Union{Array, DataFrame}`: The time range to be plotted

# Example

```julia
var_name = :P__ThermalStandard
df = PSI.read_realized_variables(results, names = [var_name])[var_name]
time_range = PSI.get_realized_timestamps(results)
plot = plot_dataframe(df, time_range)
```

# Accepted Key Words
- `display::Bool`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "html"`: set a different format for saving a PlotlyJS plot
- `seriescolor::Array`: Set different colors for the plots
- `title::String = "Title"`: Set a title for the plots
- `curtailment::Bool`: plot the curtailment with the variable
- `stack::Bool`: stack plot traces
- `bar::Bool` : create bar plot
"""
function plot_dataframe(
    variable::DataFrames.DataFrame,
    time_range::Union{DataFrames.DataFrame, Array, StepRange};
    kwargs...,
)
    return plot_dataframe(_empty_plot(), variable, time_range; kwargs...)
end

function plot_dataframe(
    p::Any,
    variable::DataFrames.DataFrame,
    time_range::Union{DataFrames.DataFrame, Array, StepRange};
    kwargs...,
)
    time_range =
        typeof(time_range) == DataFrames.DataFrame ? time_range[:, 1] : collect(time_range)
    backend = Plots.backend()
    p = _dataframe_plots_internal(p, variable, time_range, backend; kwargs...)
    return p
end

################################# Plotting PGData ##########################

"""
    plot_pgdata(pgdata, time_range)
    plot_pgdata(plot, pgdata, time_range)

This function makes a plot of a PGdata object

# Arguments

- `pgdata::PGData`: The dataframe to be plotted

# Example

```julia
var_name = :P__ThermalStandard
df = PSI.read_realized_variables(results, names = [var_name])[var_name]
time_range = PSI.get_realized_timestamps(results)
plot = plot_dataframe(df, time_range)
```

# Accepted Key Words
- `combine_categories::Bool = false` : plot category values or each value in a category
- `display::Bool`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "html"`: set a different format for saving a PlotlyJS plot
- `seriescolor::Array`: Set different colors for the plots
- `title::String = "Title"`: Set a title for the plots
- `curtailment::Bool`: plot the curtailment with the variable
- `stack::Bool`: stack plot traces
- `bar::Bool` : create bar plot
"""
function plot_pgdata(pgdata::PGData; kwargs...)
    return plot_pgdata(_empty_plot(), pgdata; kwargs...)
end

function plot_pgdata(p::Any, pgdata::PGData; kwargs...)
    if get(kwargs, :combine_categories, true)
        agg = get(kwargs, :agg, nothing)
        names = get(kwargs, :names, nothing)
        data = combine_categories(pgdata.data; names = names, agg = agg)
    else
        data = pgdata.data
    end
    plot_dataframe(p, data, pgdata.time; kwargs...)
    return p
end

################################# Plotting Fuel Plot of Results ##########################
"""
    plot_fuel(results)

This function makes a stack plot of the results by fuel type
and assigns each fuel type a specific color.

# Arguments

- `res::Union{Results, Vector{IS.Results}}`: results to be plotted

# Example

```julia
res = solve_op_problem!(OpProblem)
plot = plot_fuel(res)
```

# Accepted Key Words
- `display::Bool`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "html"`: set a different format for saving a PlotlyJS plot
- `seriescolor::Array`: Set different colors for the plots
- `title::String = "Title"`: Set a title for the plots
- `curtailment::Bool`: To plot the curtailment in the stack plot
- `load::Bool`: To plot the load line in the plot
- `stair::Bool`: Make a stair plot instead of a stack plot
- `generator_mapping_file` = "file_path" : file path to yaml definig generator category by fuel and primemover
- `variables::Union{Nothing, Vector{Symbol}}` = nothing : specific variables to plot
"""

function plot_fuel(result::IS.Results; kwargs...)
    return plot_fuel(nothing, result; kwargs...)
end

function plot_fuel(p::Union{Plots.Plot, Nothing}, result::IS.Results; kwargs...)
    backend = Plots.backend()
    set_display = get(kwargs, :set_display, true)
    save_fig = get(kwargs, :save, nothing)
    curtailment = get(kwargs, :curtailment, true)
    title = get(kwargs, :title, "Fuel")

    # Generation stack
    gen = get_generation_data(result; kwargs...)
    cat = make_fuel_dictionary(PSI.get_system(result); kwargs...)
    fuel = categorize_data(gen.data, cat; curtailment = curtailment)

    # passing names here enforces order
    # TODO: enable custom sort with kwarg
    fuel_agg = combine_categories(fuel; names = intersect(CATEGORY_DEFAULT, keys(fuel)))

    seriescolor = get(kwargs, :seriescolor, match_fuel_colors(fuel_agg, backend))
    p = plot_dataframe(
        fuel_agg,
        gen.time;
        stack = true,
        seriescolor = seriescolor,
        y_label = _make_ylabel(result.base_power),
        title = title,
        kwargs...,
    )

    # load line
    p = plot_demand(p, result; kwargs...)

    # service stack
    # TODO: how to display this?

    set_display && display(p)
    if !isnothing(save_fig)
        title = replace(title, " " => "_")
        Plots.savefig(p, joinpath(save_fig, "$(title).png"))
    end
    return p
end

function plot_fuels(results::Array; kwargs...)
    backend = Plots.backend()
    set_display = get(kwargs, :set_display, true)
    save_fig = get(kwargs, :save, nothing)
    curtailment = get(kwargs, :curtailment, true)
    title = get(kwargs, :title, "Fuel")

    stack_plots = []
    for result in results
        p = plot_fuel(result; kwargs...)
        push!(stack_plots, p)
    end
    p1 = Plots.plot(stack_plots...; layout = (length(results), 1))
    set_display && display(p1)
    if !isnothing(save_fig)
        title = replace(title, " " => "_")
        stack_title = linetype == :line ? "$(title)_Stack" : "$(title)_Stair"
        Plots.savefig(p1, joinpath(save_fig, "$(stack_title).png"))
    end
    return PlotList(Dict(:Fuel_Stack => p1))#, :Fuel_Bar => p2))
end
