"""
`ParametersDGVIP1`: Parameters for right-hand side function of Discontinuous Galerkin Variational Integrator.

### Parameters

* `DT`: data type
* `TT`: parameter type
* `D`: dimension of the system
* `S`: number of basis nodes
* `R`: number of quadrature nodes

### Fields

* `Θ`:  function of the noncanonical one-form (∂L/∂v)
* `f`:  function of the force (∂L/∂q)
* `g`:  function of the projection ∇ϑ(q)⋅v
* `Δt`: time step
* `b`:  quadrature weights
* `c`:  quadrature nodes
* `m`:  mass matrix
* `a`:  derivative matrix
* `r⁻`: reconstruction coefficients, jump lhs value
* `r⁺`: reconstruction coefficients, jump rhs value
* `t`:  current time
* `q`:  current solution of qₙ
* `q⁻`: current solution of qₙ⁻
* `q⁺`: current solution of qₙ⁺
"""
mutable struct ParametersDGVIP1{DT,TT,D,S,R,ΘT,FT,GT} <: Parameters{DT,TT}
    Θ::ΘT
    f::FT
    g::GT

    Δt::TT

    b::Vector{TT}
    c::Vector{TT}
    m::Matrix{TT}
    a::Matrix{TT}
    r⁻::Vector{TT}
    r⁺::Vector{TT}

    t::TT

    q::Vector{DT}
    q⁻::Vector{DT}
    q⁺::Vector{DT}
end

function ParametersDGVIP1(Θ::ΘT, f::FT, g::GT, Δt::TT,
                b::Vector{TT}, c::Vector{TT}, m::Matrix{TT}, a::Matrix{TT}, r⁻::Vector{TT}, r⁺::Vector{TT},
                q::Vector{DT}, q⁻::Vector{DT}, q⁺::Vector{DT}) where {DT,TT,ΘT,FT,GT}

    @assert length(q)  == length(q⁻)  == length(q⁺)
    @assert length(b)  == length(c)
    @assert length(r⁻) == length(r⁺)

    D = length(q)
    S = length(r⁻)
    R = length(c)

    println()
    println("  Discontinuous Galerkin Variational Integrator")
    println("  =============================================")
    println()
    println("    b = ", b)
    println("    c = ", c)
    println("    m = ", m)
    println("    a = ", a)
    println("    r⁻= ", r⁻)
    println("    r⁺= ", r⁺)
    println()

    ParametersDGVIP1{DT,TT,D,S,R,ΘT,FT,GT}(
                Θ, f, g, Δt, b, c, m, a, r⁻, r⁺, 0, q, q⁻, q⁺)
end

function ParametersDGVIP1(Θ::ΘT, f::FT, g::GT, Δt::TT,
                basis::Basis{TT}, quadrature::Quadrature{TT},
                q::Vector{DT}, q⁻::Vector{DT}, q⁺::Vector{DT}) where {DT,TT,ΘT,FT,GT}

    # compute coefficients
    m = zeros(TT, nnodes(quadrature), nbasis(basis))
    a = zeros(TT, nnodes(quadrature), nbasis(basis))
    r⁻= zeros(TT, nbasis(basis))
    r⁺= zeros(TT, nbasis(basis))

    for i in 1:nbasis(basis)
        for j in 1:nnodes(quadrature)
            m[j,i] = evaluate(basis, i, nodes(quadrature)[j])
            a[j,i] = derivative(basis, i, nodes(quadrature)[j])
        end
        r⁻[i] = evaluate(basis, i, one(TT))
        r⁺[i] = evaluate(basis, i, zero(TT))
    end

    ParametersDGVIP1(Θ, f, g, Δt, weights(quadrature), nodes(quadrature), m, a, r⁻, r⁺, q, q⁻, q⁺)
end

function ParametersDGVIP1(Θ, f, g, Δt, basis, quadrature, q, q⁻)
    q⁺ = zero(q)
    q⁺ .= q
    ParametersDGVIP1(Θ, f, g, Δt, basis, quadrature, q, q⁻, q⁺)
end


"Compute stages of variational partitioned Runge-Kutta methods."
@generated function function_stages!(x::Vector{ST}, b::Vector{ST}, params::ParametersDGVIP1{DT,TT,D,S,R}) where {ST,DT,TT,D,S,R}
    cache = IntegratorCacheDGVI{ST,D,S,R}()

    quote
        @assert length(x) == length(b)

        compute_stages!(x, $cache, params)

        compute_rhs!(b, $cache, params)
    end
end


function compute_stages!(x, cache::IntegratorCacheDGVI{ST,D,S}, params::ParametersDGVIP1{DT,TT,D,S}) where {ST,DT,TT,D,S}
    # copy x to X
    for i in 1:S
        for k in 1:D
            cache.X[i][k] = x[D*(i-1)+k]
        end
    end

    # copy x to q̅=qₙ+₁
    for k in 1:D
        cache.q̅[k] = x[D*S+k]
    end

    # copy x to q̅⁺=qₙ+₁⁺
    for k in 1:D
        cache.q̅⁺[k] = x[D*(S+1)+k]
    end

    # compute Q, qₙ⁺ and qₙ₊₁⁻
    compute_stages_q!(cache, params)

    # compute V
    compute_stages_v!(cache, params)

    # compute P and F
    compute_stages_p!(cache, params)

    # compute jump
    compute_stages_λ!(cache, params)
end


"Compute solution at quadrature nodes and across jump."
function compute_stages_q!(cache::IntegratorCacheDGVI{ST,D,S,R},
                           params::ParametersDGVIP1{DT,TT,D,S,R}) where {ST,DT,TT,D,S,R}

    local q::ST
    local q⁺::ST
    local q̅⁻::ST

    local X = cache.X
    local Q = cache.Q

    # copy q and q⁻
    cache.q  .= params.q
    cache.q⁻ .= params.q⁻

    # compute Q
    for i in 1:R
        for k in 1:D
            q = 0
            for j in 1:S
                q += params.m[i,j] * X[j][k]
            end
            Q[i][k] = q
        end
    end

    # compute qₙ⁺ and qₙ₊₁⁻
    for k in 1:D
        q⁺ = 0
        q̅⁻ = 0
        for i in 1:S
            q⁺ += params.r⁺[i] * X[i][k]
            q̅⁻ += params.r⁻[i] * X[i][k]
        end
        cache.q⁺[k] = q⁺
        cache.q̅⁻[k] = q̅⁻
    end
end


"Compute velocities at quadrature nodes."
function compute_stages_v!(cache::IntegratorCacheDGVI{ST,D,S,R},
                           params::ParametersDGVIP1{DT,TT,D,S,R}) where {ST,DT,TT,D,S,R}
    local v::ST

    for i in 1:R
        for k in 1:D
            v = 0
            for j in 1:S
                v += params.a[i,j] * cache.X[j][k]
            end
            cache.V[i][k] = v / params.Δt
        end
    end
end


"Compute one-form and forces at quadrature nodes."
function compute_stages_p!(cache::IntegratorCacheDGVI{ST,D,S,R},
                           params::ParametersDGVIP1{DT,TT,D,S,R}) where {ST,DT,TT,D,S,R}

    local tᵢ::TT

    # compute P=ϑ(Q) and F=f(Q)
    for i in 1:R
        tᵢ = params.t + params.Δt * params.c[i]
        params.Θ(tᵢ, cache.Q[i], cache.V[i], cache.P[i])
        params.f(tᵢ, cache.Q[i], cache.V[i], cache.F[i])
    end
end


function compute_stages_λ!(cache::IntegratorCacheDGVI{ST,D,S,R},
                           params::ParametersDGVIP1{DT,TT,D,S,R}) where {ST,DT,TT,D,S,R}

    local t₀::TT = params.t
    local t₁::TT = params.t + params.Δt

    # compute ϕ and ϕ̅
    cache.ϕ  .= 0.5 * (cache.q⁻ .+ cache.q⁺)
    cache.ϕ⁻ .= 0.5 * (cache.q⁻ .+ cache.q )
    cache.ϕ⁺ .= 0.5 * (cache.q  .+ cache.q⁺)

    cache.ϕ̅  .= 0.5 * (cache.q̅⁻ .+ cache.q̅⁺)
    cache.ϕ̅⁻ .= 0.5 * (cache.q̅⁻ .+ cache.q̅ )
    cache.ϕ̅⁺ .= 0.5 * (cache.q̅  .+ cache.q̅⁺)

    # compute λ and λ̅
    cache.λ  .= cache.q⁺ .- cache.q⁻
    cache.λ⁻ .= cache.q  .- cache.q⁻
    cache.λ⁺ .= cache.q⁺ .- cache.q

    cache.λ̅  .= cache.q̅⁺ .- cache.q̅⁻
    cache.λ̅⁻ .= cache.q̅  .- cache.q̅⁻
    cache.λ̅⁺ .= cache.q̅⁺ .- cache.q̅

    # compute ϑ
    params.Θ(t₀, cache.q,  cache.q,  cache.θ)
    params.Θ(t₀, cache.q⁻, cache.q⁻, cache.θ⁻)
    params.Θ(t₀, cache.q⁺, cache.q⁺, cache.θ⁺)

    params.Θ(t₁, cache.q̅,  cache.q̅,  cache.Θ̅)
    params.Θ(t₁, cache.q̅⁻, cache.q̅⁻, cache.Θ̅⁻)
    params.Θ(t₁, cache.q̅⁺, cache.q̅⁺, cache.Θ̅⁺)

    # compute projection
    params.g(t₀, cache.q,  cache.λ,  cache.g)
    params.g(t₀, cache.q⁻, cache.λ⁻, cache.g⁻)
    params.g(t₀, cache.q⁺, cache.λ⁺, cache.g⁺)

    params.g(t₁, cache.q̅,  cache.λ̅,  cache.g̅)
    params.g(t₁, cache.q̅⁻, cache.λ̅⁻, cache.g̅⁻)
    params.g(t₁, cache.q̅⁺, cache.λ̅⁺, cache.g̅⁺)

    # # compute ϑ
    # params.Θ(t₀, cache.ϕ⁻, cache.ϕ⁻, cache.θ⁻)
    # params.Θ(t₀, cache.ϕ⁺, cache.ϕ⁺, cache.θ⁺)
    # params.Θ(t₁, cache.ϕ̅⁻, cache.ϕ̅⁻, cache.Θ̅⁻)
    #
    # # compute projection
    # params.g(t₀, cache.ϕ⁻, cache.λ⁻, cache.g⁻)
    # params.g(t₀, cache.ϕ⁺, cache.λ⁺, cache.g⁺)
    # params.g(t₁, cache.ϕ̅⁻, cache.λ̅⁻, cache.g̅⁻)
end


function compute_rhs!(b::Vector{ST}, cache::IntegratorCacheDGVI{ST,D,S,R},
                params::ParametersDGVIP1{DT,TT,D,S,R}) where {ST,DT,TT,D,S,R}

    local z::ST

    # compute b = - [(P-AF)]
    for i in 1:S
        for k in 1:D
            z = 0
            for j in 1:R
                z += params.b[j] * params.m[j,i] * cache.F[j][k] * params.Δt
                z += params.b[j] * params.a[j,i] * cache.P[j][k]
            end

            z += params.r⁺[i] * 0.5 * ( cache.θ[k] + cache.θ⁺[k] )
            z -= params.r⁻[i] * 0.5 * ( cache.Θ̅[k] + cache.Θ̅⁻[k] )

            z += params.r⁺[i] * 0.5 * cache.g⁺[k]
            z += params.r⁻[i] * 0.5 * cache.g̅⁻[k]

            b[D*(i-1)+k] = z
        end
    end

    # compute b = qₙ⁺ - r⁺⋅X
    for k in 1:D
        b[D*S+k] = params.q⁺[k] - cache.q⁺[k]
    end

    for k in 1:D
        b[D*(S+1)+k] = cache.Θ̅⁺[k] - cache.Θ̅⁻[k] - cache.g̅[k]
    end
end


"""
`IntegratorDGVIP1`: Discontinuous Galerkin Variational Integrator.

### Parameters

### Fields

* `equation`: Implicit Ordinary Differential Equation
* `basis`: piecewise polynomial basis
* `quadrature`: numerical quadrature rule
* `Δt`: time step
* `params`: ParametersDGVIP1
* `solver`: nonlinear solver
* `iguess`: initial guess
* `q`: current solution vector for trajectory
* `p`: current solution vector for one-form
* `cache`: temporary variables for nonlinear solver
"""
struct IntegratorDGVIP1{DT,TT,D,S,R,ΘT,FT,GT,VT,FPT,ST,IT,BT<:Basis} <: DeterministicIntegrator{DT,TT}
    equation::IODE{DT,TT,ΘT,FT,GT,VT}

    basis::BT
    quadrature::Quadrature{TT,R}

    Δt::TT

    params::FPT
    solver::ST
    iguess::InitialGuessPODE{DT,TT,VT,FT,IT}

    q::Vector{DT}
    q⁻::Vector{DT}
    q⁺::Vector{DT}

    cache::IntegratorCacheDGVI{DT}
end

function IntegratorDGVIP1(equation::IODE{DT,TT,ΘT,FT,GT,VT}, basis::Basis{TT,P},
                quadrature::Quadrature{TT,R}, Δt::TT;
                interpolation=HermiteInterpolation{DT}) where {DT,TT,ΘT,FT,GT,VT,P,R}

    D = equation.d
    S = nbasis(basis)

    N = D*(S+2)

    # create solution vector for nonlinear solver
    x = zeros(DT,N)

    # create solution vectors
    q  = zeros(DT,D)
    q⁻ = zeros(DT,D)
    q⁺ = zeros(DT,D)

    # create cache for internal stage vectors and update vectors
    cache = IntegratorCacheDGVI{DT,D,S,R}()

    # create params
    params = ParametersDGVIP1(equation.α, equation.f, equation.g,
                Δt, basis, quadrature, q, q⁻, q⁺)

    # create rhs function for nonlinear solver
    function_stages = (x,b) -> function_stages!(x, b, params)

    # create nonlinear solver
    solver = get_config(:nls_solver)(x, function_stages)

    # create initial guess
    iguess = InitialGuessPODE(interpolation, equation, Δt)

    # create integrator
    IntegratorDGVIP1{DT, TT, D, S, R, ΘT, FT, GT, VT, typeof(params), typeof(solver),
                typeof(iguess.int), typeof(basis)}(
                equation, basis, quadrature, Δt, params, solver, iguess,
                q, q⁻, q⁺, cache)
end



function initialize!(int::IntegratorDGVIP1, sol::Union{SolutionPODE, SolutionPDAE}, m::Int)
    @assert m ≥ 1
    @assert m ≤ sol.ni

    # copy initial conditions from solution
    get_initial_conditions!(sol, int.q, int.q⁺, m)
    int.q⁻ .= int.q

    # initialise initial guess
    initialize!(int.iguess, m, sol.t[0], int.q, int.q⁺)
end


function update_solution!(int::IntegratorDGVIP1{DT,TT}, cache::IntegratorCacheDGVI{DT}) where {DT,TT}
    int.q  .= cache.q̅
    int.q⁻ .= cache.q̅⁻
    int.q⁺ .= cache.q̅⁺
end


@generated function initial_guess!(int::IntegratorDGVIP1{DT,TT, D, S, R}, m::Int) where {DT,TT,D,S,R}
    v = zeros(DT,D)
    y = zeros(DT,D)
    z = zeros(DT,D)

    quote
        # compute initial guess
        if nnodes(int.basis) > 0
            for i in 1:S
                evaluate!(int.iguess, m, $y, $z, $v, nodes(int.basis)[i], nodes(int.basis)[i])
                for k in 1:D
                    int.solver.x[D*(i-1)+k] = $y[k]
                end
            end
        else
            for i in 1:S
                for k in 1:D
                    int.solver.x[D*(i-1)+k] = 0
                end
            end
        end

        evaluate!(int.iguess, m, $y, $z, $v, one(TT), one(TT))
        for k in 1:D
            int.solver.x[D*(S+0)+k] = $y[k]
            int.solver.x[D*(S+1)+k] = $y[k]
        end
    end
end


function integrate_step!(int::IntegratorDGVIP1{DT,TT}, sol::Union{SolutionPODE{DT,TT}, SolutionPDAE{DT,TT}}, m::Int, n::Int) where {DT,TT}
    # set time for nonlinear solver
    int.params.t = sol.t[0] + (n-1)*int.Δt

    # compute initial guess
    initial_guess!(int, m)

    # call nonlinear solver
    solve!(int.solver)

    # print solver status
    print_solver_status(int.solver.status, int.solver.params)

    # check if solution contains NaNs or error bounds are violated
    check_solver_status(int.solver.status, int.solver.params)

    # compute final update
    compute_stages!(int.solver.x, int.cache, int.params)

    # copy solution from cache to integrator
    update_solution!(int, int.cache)

    # copy solution to initial guess for next time step
    update!(int.iguess, m, sol.t[0] + n*int.Δt, int.q, int.q⁺)

    # take care of periodic solutions
    cut_periodic_solution!(int.q,  int.equation.periodicity)
    cut_periodic_solution!(int.q⁻, int.equation.periodicity)
    cut_periodic_solution!(int.q⁺, int.equation.periodicity)

    # copy to solution
    copy_solution!(sol, int.q, int.q⁺, n, m)
end
