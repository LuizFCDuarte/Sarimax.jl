"""

Δyₜ = α + δt + γ y_(t-1) + ∑ ϕ_i Δy_(t-i) + ϵₜ + ∑ θ_j ϵ_(t-j)

"""
mutable struct OPTSARIMAModel
    y::TimeArray
    α::Union{Float64,Nothing}
    δ::Union{Float64,Nothing}
    γ::Union{Float64,Nothing}
    ϕ::Union{Vector{Float64},Nothing}
    θ::Union{Vector{Float64},Nothing}
    I::Union{Vector{Float64},Nothing}
    K::Union{Int64,Nothing}
    maxK::Union{Int64,Nothing}
    maxp::Union{Int64,Nothing}
    maxq::Union{Int64,Nothing}
    ϵ::Union{Vector{Float64},Nothing}
    fitInSample::Union{TimeArray,Nothing}
    forecast::Union{TimeArray,Nothing}
    aicc::Union{Float64,Nothing}
    silent::Bool
    function OPTSARIMAModel(y::TimeArray;
                            α::Union{Float64,Nothing}=nothing,
                            δ::Union{Float64,Nothing}=nothing,
                            γ::Union{Float64,Nothing}=nothing,
                            ϕ::Union{Vector{Float64},Nothing}=nothing,
                            θ::Union{Vector{Float64},Nothing}=nothing,
                            I::Union{Vector{Float64},Nothing}=nothing,
                            K::Union{Int64,Nothing}=nothing,
                            maxK::Union{Int64,Nothing}=10,
                            maxp::Union{Int64,Nothing}=13,
                            maxq::Union{Int64,Nothing}=5,
                            ϵ::Union{Vector{Float64},Nothing}=nothing,
                            fitInSample::Union{TimeArray,Nothing}=nothing,
                            forecast::Union{TimeArray,Nothing}=nothing,
                            aicc::Union{Float64,Nothing}=nothing,
                            silent::Bool=true)
        @assert maxK >= 0
        @assert maxp >= 0
        @assert maxq >= 0
        return new(y,α,δ,γ,ϕ,θ,I,K,maxK,maxp,maxq,ϵ,fitInSample,forecast,aicc,silent)
    end
end

function OPTSARIMA(y::TimeArray,
    silent::Bool=true)
return OPTSARIMAModel(y;silent=silent)
end

function print(model::OPTSARIMAModel)
    println("=================MODEL===============")
    println("Best K            : ", model.K)
    chosen_index = model.I .> 0
    coeficients = vcat(["δ","γ"],["ϕ_$i" for i =1:model.maxp-1])[chosen_index]
    println("Chosen Coeficients: $coeficients")
    println("Estimated α       : ",model.α)
    println("Estimated δ       : ",model.δ)
    println("Estimated γ       : ",model.γ)
    println("Estimated ϕ       : ", model.ϕ)
end

function print(model::Main.Models.OPTSARIMAModel)
    println("=================MODEL===============")
    println("Best K            : ", model.K)
    chosen_index = model.I .> 0
    coeficients = vcat(["δ","γ"],["ϕ_$i" for i =1:model.maxp-1])[chosen_index]
    println("Chosen Coeficients: $coeficients")
    println("Estimated α       : ",model.α)
    println("Estimated δ       : ",model.δ)
    println("Estimated γ       : ",model.γ)
    println("Estimated ϕ       : ", model.ϕ)
end

function fill_fit_values!(model::OPTSARIMAModel,
                        auxModel::OPTSARIMAModel)
    model.α = auxModel.α
    model.δ = auxModel.δ
    model.γ = auxModel.γ
    model.ϕ = auxModel.ϕ
    model.θ = auxModel.θ
    model.ϵ = auxModel.ϵ
    model.I = auxModel.I
    model.K = auxModel.K
    model.aicc = auxModel.aicc
    model.fitInSample = auxModel.fitInSample
end

function OPTSARIMAModel(α,δ,γ,ϕ,θ,I,K,maxK,maxp,maxq,ϵ,fitInSample,aicc,silent)
    if (maxK < 0 || maxp < 0 || maxq < 0)
        error("Negative values not allowed")
    end

    return OPTSARIMAModel(α,δ,γ,ϕ,θ,I,K,maxK,maxp,maxq,ϵ,fitInSample,aicc,silent)
end

function OPTSARIMAModel!(model,α,δ,γ,ϕ,θ,I,K,ϵ,fitInSample,aicc)
    model.α = α
    model.δ = δ
    model.γ = γ
    model.ϕ = ϕ
    model.θ = θ
    model.I = I
    model.K = K
    model.ϵ = ϵ
    model.fitInSample = fitInSample
    model.aicc = aicc
end

function get_opt_λ(y::Vector{Float64}, X::Matrix{Float64})
    T,p = size(X)
    ratio = p > T ? 0.01*(p/T) : 0.0001
    cv_results = GLMNet.glmnetcv(X, y, alpha=0, nfolds=5, lambda_min_ratio=ratio, standardize=true)
    return cv_results.lambda[argmin(cv_results.meanloss)]
end

function opt_ari(model::OPTSARIMAModel;silent=false, optimizer::DataType=SCIP.Optimizer, reg::Bool=false)
    y_values = values(model.y)
    # Diff y
    diff_y = diff(model.y,differences=1)
    T = length(diff_y)
    diff_y_values = values(diff_y)
    K = 1
    mod = Model(optimizer)
    if solver_name(mod) == "Gurobi"
        set_optimizer_attribute(mod, "NonConvex", 2)
    end
    if silent
        set_silent(mod)
    end
    @variables(mod, begin
        fobj
        α
        δ
        γ
        K_var
        ϕ[1:model.maxp-1] # AR part  
        I[1:1+model.maxp], Bin # 2 + maxp - 1
        ϵ[t = 1:T]
    end)

    all_coefs = vcat([δ],[γ],ϕ)
    lb = model.maxp + 1
    @expression(mod, ŷ[t=lb:T], α + δ*t + γ*y_values[t-1] + sum(ϕ[i]*diff_y_values[t-i] for i=1:model.maxp-1))
    @constraint(mod,[t=lb:T], diff_y_values[t] == ŷ[t] + ϵ[t])
    @constraint(mod, [i = 1:1+model.maxp], all_coefs[i]*(1 - I[i]) == 0) # WARNING: Non linear
    @constraint(mod, sum(I) <= K_var)
    @constraint(mod, fobj == sum(ϵ[i]^2 for i in 1:T))

    X = vcat(zeros(1),y_values[2:end])
    for i=3:model.maxp
        X = hcat(X,vcat(zeros(i-1),y_values[i:end]))
    end
    λ = get_opt_λ(y_values,X)
    reg_multiplier = reg ? 1 : 0

    @objective(mod, Min, fobj + reg_multiplier *  1/(2*λ) * sum(all_coefs.^2)) # Calibrar Ver com o André
    fix.(K_var, K)
    optimize!(mod)

    aiccs = Vector{Float64}()
    aic = 2*K + T*log(var(value.(ϵ)))
    aicc_ = (aic + ((2*K^2 +2*K)/(T - K - 1)))
    fitInSample::TimeArray = TimeArray(timestamp(diff_y)[lb:end], OffsetArrays.no_offset_view(value.(ŷ)))
    fitted_model = OPTSARIMAModel(model.y;α=value(α),δ=value(δ),γ=value(γ),ϕ=value.(ϕ),I=value.(I),K=floor(Int64,sum(value.(I))),ϵ=value.(ϵ),fitInSample=fitInSample,aicc=aicc_)
    fitted_models = [fitted_model]
    push!(aiccs, aicc_)
    K+=1
    while K <= model.maxK
        fix.(K_var, K)
        optimize!(mod)
        @info("Solved for K = $K")

        aic = 2*K + T*log(var(value.(ϵ)))
        aicc_ = (aic + ((2*K^2 +2*K)/(T - K - 1)))
        push!(aiccs, aicc_)

        fitInSample = TimeArray(timestamp(diff_y)[lb:end], OffsetArrays.no_offset_view(value.(ŷ)))
        fitted_model = OPTSARIMAModel(model.y;α=value(α),δ=value(δ),γ=value(γ),ϕ=value.(ϕ),I=value.(I),K=floor(Int64,sum(value.(I))),ϵ=value.(ϵ),fitInSample=fitInSample,aicc=aicc_)
        push!(fitted_models, fitted_model)
        
        if aiccs[end] >= aiccs[end - 1]
            @info("aicc[end]=",aiccs[end])
            @info("aicc[end-1]=",aiccs[end-1])
            @info("Best K found: ", K-1)
            break
        end
       
        K += 1
    end

    # best model
    best_model = fitted_models[K-1]
    adf = best_model.γ/std(best_model.ϵ)
    @info("ADF Test: $(adf)")
    if adf >= -3.60 # t distribuition for size T=50
        best_model.fitInSample = best_model.fitInSample .+ TimeSeries.lag(model.y,1)
    end
    fill_fit_values!(model,best_model)
    #return fitted_models, findfirst(x->x==minimum(aiccs), aiccs)
end

function opt_ari_lasso()
    p = 13
    # y = float.(TimeArray(airp, timestamp = :month))
    lag_y = TimeSeries.rename!(TimeSeries.lag(y,1),[:lag_y])
    Δy = TimeSeries.rename!(diff(y),:Δy)
    X = lag_y
    penalty_factor = [0.5]
    for i = 1:p
        penalty_factor = vcat(penalty_factor, [i])
        lag_Δy_i = TimeSeries.rename!(TimeSeries.lag(y,i),[Symbol("Δy_tminus$i")])
        X = merge(X,lag_Δy_i)
    end
    data = merge(Δy,X)

    X_lasso = values(data)[:,2:end]
    y_lasso = values(data)[:,1]
    model = Lasso.fit(LassoModel, X_lasso, y_lasso; penalty_factor = penalty_factor)
    penalty_factor = 1 ./ (0.01 .+ abs.(Lasso.coef(model)[2:end]))
    model = Lasso.fit(LassoModel, X_lasso, y_lasso; penalty_factor = penalty_factor)
    
end

function ari(y;maxp=5, K=1, silent=false, optimizer::DataType=SCIP.Optimizer)
    # Diff y
    Δy = vcat([NaN], diff(y)) 
    T = length(y)
    model = Model(optimizer)

    if solver_name(model) == "Gurobi"
        set_optimizer_attribute(model, "NonConvex", 2)
    end

    if silent
        set_silent(model)
    end
    @variables(model, begin
        epi
        α
        δ
        γ
        K_var
        ϕ[1:maxp-1] # AR part  
        I[1:1+maxp], Bin # 2 + maxp - 1
        ϵ[t = 1:T]
    end)

    all_coefs = vcat([δ],[γ],ϕ)
    @constraint(model,[t = maxp+1:T], Δy[t] == α + δ*t + γ*y[t-1] + sum(ϕ[i]*Δy[t-i] for i=1:maxp-1) + ϵ[t])
    @constraint(model, [i = 1:1+maxp], all_coefs[i]*(1 - I[i]) == 0) # WARNING: Non linear
    @constraint(model, sum(I) == K_var)
    @constraint(model, epi == sum(ϵ[i]^2 for i in 1:T))
    @objective(model, Min, epi)
    fix.(K_var, K)

    optimize!(model)
    return value.(ϵ), value.(ϕ)
end

function arima_start_values(opt_ari_model::OPTSARIMAModel, model, maxq)
    set_start_value(model[:α], opt_ari_model.α)
    set_start_value(model[:δ], opt_ari_model.δ)
    set_start_value(model[:γ], opt_ari_model.γ)

    for i in eachindex(opt_ari_model.I)
        set_start_value(model[:I][i], opt_ari_model.I[i])
    end

    for i in eachindex(opt_ari_model.ϕ)
        set_start_value(model[:ϕ][i], opt_ari_model.ϕ[i])
    end

    for i in eachindex(opt_ari_model.ϵ)
        set_start_value(model[:ϵ][i], opt_ari_model.ϵ[i])
    end

    for i in 1:maxq-1 
        set_start_value(model[:θ][i], 0) # since the opt ari does not have the MA component
    end
end

function arima(y::Vector{Float64};maxp=6,maxq=6,maxK=8,silent=false,optimizer::DataType=SCIP.Optimizer)
    # Diff y
    Δy = vcat([NaN],diff(y)) 
    T = length(Δy)

    model = Model(optimizer)

    if solver_name(model) == "Gurobi"
        set_optimizer_attribute(model, "NonConvex", 2)
    end

    if silent
        set_silent(model)
    end

    @variables(model, begin
        fo
        -2 <= α <= 2
        -5 <= δ <= 5# explicativa deve ser δ tem que achar outro parâmetro
        -5 <= γ <= 5
        K_var 
        -1 <= ϕ[1:maxp-1] <= 1 # AR part  
        -1 <= θ[1:maxq-1] <= 1# MA part
        I[1:maxp+maxq], Bin # 2 + maxp - 1 + maxq - 1 
        -100 <= ϵ[t = 1:T] <= 100
    end)

    fitted_aris, opt_k = opt_ari(y;maxp=maxp,silent=silent)
    K = opt_k 
    if opt_k > 1
        K = opt_k-1
    end

    arima_start_values(fitted_aris[K], model, maxq)
    
    all_coefs = vcat([δ],[γ],ϕ,θ)
    @constraint(model,[t = max(maxp+1, maxq+1):T], Δy[t] == α + δ*t + γ*y[t-1] + sum(ϕ[i]*Δy[t-i] for i=1:maxp-1) + ϵ[t] + sum(θ[j]*ϵ[t-j] for j=1:max(maxq-1,1)))
    @constraint(model, [i = 1:maxp+maxq], all_coefs[i]*(1 - I[i]) == 0) # WARNING: Non linear
    @constraint(model, sum(I) <= K_var)
    @constraint(model, fo == sum(ϵ[i]^2 for i in 1:T))
    @objective(model, Min, fo)
    @expression(model, fit[t=max(maxp+1, maxq+1):T], α + δ*t + γ*y[t-1] + sum(ϕ[i]*Δy[t-i] for i=1:maxp-1) + ϵ[t] + sum(θ[j]*ϵ[t-j] for j=1:maxq-1))
    fix.(K_var, K)
    
    optimize!(model)
    @info("Solved for K= $K")
    aiccs = Vector{Float64}()
    aic = 2*K + T*log(var(value.(ϵ)))
    aicc_ = (aic + ((2*K^2 +2*K)/(T - K - 1)))
    fitted_model = OPTSARIMAModel(value(α),value(δ), value(γ),value.(ϕ),value.(θ),value.(I),K,maxK,maxp,maxq,value.(ϵ),vcat([NaN for _=1:max(maxp,maxq)],  OffsetArrays.no_offset_view(value.(fit))),aicc_,silent)
    push!(aiccs, aicc_)
    K+=1
    while K <= maxK
        OPTSARIMAModel!(fitted_model,value(α),value(δ),value(γ),value.(ϕ),value.(θ),value.(I),K-1,value.(ϵ),vcat([NaN for _=1:max(maxp,maxq)], OffsetArrays.no_offset_view(value.(fit))),aicc_)
        # Start Viable Point
        arima_start_values(fitted_aris[min(K,length(fitted_aris))], model, maxq)
        fix.(K_var, K)
        optimize!(model)
        @info("Solved for K = $K")

        aic = 2*K + T*log(var(value.(ϵ)))
        aicc_ = (aic + ((2*K^2 +2*K)/(T - K - 1)))
        push!(aiccs, aicc_)
        if aiccs[end] >= aiccs[end - 1]
            @info("Best K found: ",K-1)
            break
        end
       
        K += 1
    end
 
    return fitted_model
end

function predict!(model::OPTSARIMAModel, stepsAhead::Int64=1)
    y_values = copy(values(model.y))
    T = length(y_values)

    for t=T+1:T+stepsAhead
        # y_t = α + δt + (γ+1+ϕ_1)y_t-1 + Σ(phi_j - phi_j-1)y_t-j - ϕ_p-1 y_t-p
        forec = model.α + model.δ*t + (model.γ+1+model.ϕ[1])*y_values[t-1] + sum((model.ϕ[j]-model.ϕ[j-1])*y_values[t-j] for j=2:model.maxp-1) - model.ϕ[model.maxp-1]*y_values[t-model.maxp]
        push!(y_values,forec)
    end
    forecast_dates = [ timestamp(model.y)[T] + Dates.Month(i) for i=1:stepsAhead ]
    model.forecast = TimeArray(forecast_dates,y_values[T+1:end])
end

# function bic(ϵ::Float64,σ::Float64,K::Int64,N::Int64)
#     return K*(log(N))
# end

# function logpdfNormal(ϵ::T,σ::T) where {T<:Real}
#     return logpdf.(Normal(0.0,σ),ϵ)
# end

# function arima_bic(y::Vector{Float64};maxp=6,maxq=6,maxK=8,silent=false,optimizer::DataType=SCIP.Optimizer)
#     # Diff y
#     Δy = vcat([NaN],diff(y)) 
#     T = length(Δy)
#     model = Model(optimizer)

#     if solver_name(model) == "Gurobi"
#         set_optimizer_attribute(model, "NonConvex", 2)
#     end

#     if silent
#         set_silent(model)
#     end

#     @variables(model, begin
#         fo
#         σ 
#         α
#         δ # explicativa deve ser δ tem que achar outro parâmetro
#         γ
#         K_var 
#         -1 <= ϕ[1:maxp-1] <= 1 # AR part  
#         -1 <= θ[1:maxq-1] <= 1# MA part
#         I[1:maxp+maxq], Bin # 2 + maxp - 1 + maxq - 1 
#         -100 <= ϵ[t = 1:T] <= 100
#     end)
#     register(model, :logpdfNormal, 2, logpdfNormal, autodiff=true)
#     opt_ari_model = opt_ari(y;maxp=maxp,silent=silent)
#     @info("Solved auto ari")

#     set_start_value(model[:α], opt_ari_model.α)
#     set_start_value(model[:δ], opt_ari_model.δ)
#     set_start_value(model[:γ], opt_ari_model.γ)

#     for i in eachindex(opt_ari_model.I)
#         set_start_value(model[:I][i], opt_ari_model.I[i])
#     end

#     for i in eachindex(opt_ari_model.ϕ)
#         set_start_value(model[:ϕ][i], opt_ari_model.ϕ[i])
#     end

#     for i in eachindex(opt_ari_model.ϵ)
#         set_start_value(model[:ϵ][i], opt_ari_model.ϵ[i])
#     end

#     for i in 1:maxq-1 
#         set_start_value(model[:θ][i], 0) # since the opt ari does not have the MA component
#     end

#     fix.(K_var, opt_ari_model.K)
    
#     all_coefs = vcat([δ],[γ],ϕ,θ)
#     @constraint(model,[t = max(maxp+1, maxq+1):T], Δy[t] == α + δ*t + γ*y[t-1] + sum(ϕ[i]*Δy[t-i] for i=1:maxp-1) + ϵ[t] + sum(θ[j]*ϵ[t-j] for j=1:max(maxq-1,1)))
#     @constraint(model, [i = 1:maxp+maxq], all_coefs[i]*(1 - I[i]) == 0) # WARNING: Non linear
#     @constraint(model, sum(I) == K_var)
#     @NLconstraint(model, fo == -2.0*sum(logpdfNormal(ϵ[t],σ) for t=1:T) + K_var*(log(T)))
#     @objective(model, Min, fo)
#     @expression(model, fit[t=max(maxp+1, maxq+1):T], α + δ*t + γ*y[t-1] + sum(ϕ[i]*Δy[t-i] for i=1:maxp-1) + ϵ[t] + sum(θ[j]*ϵ[t-j] for j=1:maxq-1))
    
#     optimize!(model)
#     @info("Solved")
#     fitted_model = OPTSARIMAModel(value(α),value(δ), value(γ),value.(ϕ),value.(θ),value.(I),value(K),maxK,maxp,maxq,value.(ϵ),vcat([NaN for _=1:max(maxp,maxq)],  OffsetArrays.no_offset_view(value.(fit))),aicc_,silent)
#     return fitted_model
# end