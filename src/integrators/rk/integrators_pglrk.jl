
"Holds the coefficients of a projected Gauss-Legendre Runge-Kutta method."
struct CoefficientsPGLRK{T} <: AbstractCoefficients{T}
    @HeaderCoefficientsRK
    @CoefficientsRK

    P::Matrix{T}
    Q::Matrix{T}
    X::Matrix{T}
    W::Matrix{T}
    A::Matrix{T}

    function CoefficientsPGLRK{T}(name,o,s,a,b,c,P,X,W) where {T}
        @assert T <: Real
        @assert isa(name, Symbol)
        @assert isa(o, Integer)
        @assert isa(s, Integer)
        @assert s ≥ 2 "Number of stages must be ≥ 2"
        @assert s==size(a,1)==size(a,2)==length(b)==length(c)
        @assert s==size(P,1)==size(P,2)
        @assert s==size(X,1)==size(X,2)
        @assert s==size(W,1)==size(W,2)

        Q = inv(P)
        A = zero(a)
        B = zero(a)

        simd_mult!(B, W, Q)
        simd_mult!(A, P, B)

        new(name,o,s,a,b,c,P,Q,X,W,A)
    end
end

function CoefficientsPGLRK(name::Symbol, order::Int, a::Matrix{T}, b::Vector{T}, c::Vector{T}, P::Matrix{T}, X::Matrix{T}, W::Matrix{T}) where {T}
    CoefficientsPGLRK{T}(name, order, length(c), a, b, c, P, X, W)
end

Base.hash(tab::CoefficientsPGLRK, h::UInt) = hash(tab.o, hash(tab.s, hash(tab.a, hash(tab.b, hash(tab.c, hash(tab.P, hash(tab.Q, hash(tab.X, hash(tab.W, hash(tab.A, h))))))))))

Base.:(==)(tab1::CoefficientsPGLRK, tab2::CoefficientsPGLRK) = (tab1.o == tab2.o
                                                             && tab1.s == tab2.s
                                                             && tab1.a == tab2.a
                                                             && tab1.b == tab2.b
                                                             && tab1.c == tab2.c
                                                             && tab1.P == tab2.P
                                                             && tab1.Q == tab2.Q
                                                             && tab1.X == tab2.X
                                                             && tab1.W == tab2.W
                                                             && tab1.A == tab2.A)

Base.isequal(tab1::CoefficientsPGLRK{T1}, tab2::CoefficientsPGLRK{T2}) where {T1,T2} = (tab1 == tab2 && T1 == T2 && typeof(tab1) == typeof(tab2))

"Print Runge-Kutta coefficients."
function Base.show(io::IO, tab::CoefficientsPGLRK)
    print(io, "Projected Gauss-Legendre Runge-Kutta Coefficients ", tab.name, " with ", tab.s, " stages and order ", tab.o)
    print(io, "  a = ", tab.a)
    print(io, "  b = ", tab.b)
    print(io, "  c = ", tab.c)
    print(io, "  P = ", tab.P)
    print(io, "  Q = ", tab.Q)
    print(io, "  X = ", tab.X)
    print(io, "  W = ", tab.W)
    print(io, "  A = ", tab.A)
end

function getTableauPGLRK(coeff::CoefficientsPGLRK{T}, λ::T, a::Matrix{T}) where {T}
    a .= coeff.a .+ λ .* coeff.A
end


"Parameters for right-hand side function of variational partitioned Runge-Kutta methods."
mutable struct ParametersPGLRK{DT,TT,D,S,ET} <: Parameters{DT,TT}
    equ::ET
    tab::CoefficientsPGLRK{TT}
    Δt::TT

    A_q::Array{TT, 3}
    A_p::Array{TT, 3}
    a_q::Matrix{TT}
    a_p::Matrix{TT}

    t̅::TT

    q̅::Vector{DT}
    p̅::Vector{DT}


    function ParametersPGLRK{DT,TT,D,S,ET}(equ, tab, Δt) where {DT,TT,D,S,ET}
        # create coefficient matrices
        A_q = zeros(TT, S, S, D)
        A_p = zeros(TT, S, S, D)
        a_q = zero(tab.a)
        a_p = zero(tab.a)

        new(equ, tab, Δt, A_q, A_p, a_q, a_p, zero(TT), zeros(DT,D), zeros(DT,D))
    end
end


mutable struct IntegratorCachePGLRK{DT,D,S} <: IODEIntegratorCache{DT,D}
    θ::Vector{DT}
    θ̅::Vector{DT}
    λ::Vector{DT}
    λ̅::Vector{DT}

    q̃::Vector{DT}
    p̃::Vector{DT}
    ṽ::Vector{DT}
    f̃::Vector{DT}
    θ̃::Vector{DT}
    λ̃::Vector{DT}
    s̃::Vector{DT}

    Q::Vector{Vector{DT}}
    V::Vector{Vector{DT}}
    P::Vector{Vector{DT}}
    F::Vector{Vector{DT}}
    Y::Vector{Vector{DT}}
    Z::Vector{Vector{DT}}

    function IntegratorCachePGLRK{DT,D,S}() where {DT,D,S}
        # create solution vectors
        θ = zeros(DT,D)
        θ̅ = zeros(DT,D)
        λ = zeros(DT,D)
        λ̅ = zeros(DT,D)

        # create temporary vectors
        q̃ = zeros(DT,D)
        p̃ = zeros(DT,D)
        ṽ = zeros(DT,D)
        f̃ = zeros(DT,D)
        θ̃ = zeros(DT,D)
        λ̃ = zeros(DT,D)
        s̃ = zeros(DT,D)

        # create internal stage vectors
        Q = create_internal_stage_vector(DT, D, S)
        P = create_internal_stage_vector(DT, D, S)
        V = create_internal_stage_vector(DT, D, S)
        F = create_internal_stage_vector(DT, D, S)
        Y = create_internal_stage_vector(DT, D, S)
        Z = create_internal_stage_vector(DT, D, S)


        new(θ, θ̅, λ, λ̅,
            q̃, p̃, ṽ, f̃, θ̃, λ̃, s̃,
            Q, P, V, F, Y, Z)
    end
end


"Variational partitioned Runge-Kutta integrator."
struct IntegratorPGLRK{DT, TT, PT <: ParametersPGLRK{DT,TT},
                               ST <: NonlinearSolver{DT},
                               IT <: InitialGuessPODE{DT,TT}, N, D, S} <: IntegratorPRK{DT,TT}
    params::PT
    solver::ST
    iguess::IT
    cache::IntegratorCachePGLRK{DT,D,S}
end

function IntegratorPGLRK(equation::IODE{DT,TT,ΑT,FT,GT,VT,N}, tableau::CoefficientsPGLRK{TT}, Δt::TT) where {DT,TT,ΑT,FT,GT,VT,N}
    D = equation.d
    M = equation.n
    S = tableau.s

    # create params
    params = ParametersPGLRK{DT,TT,D,S,typeof(equation)}(equation, tableau, Δt)

    # create solver
    solver = create_nonlinear_solver(DT, D*(S+3), params)

    # create initial guess
    iguess = InitialGuessPODE(get_config(:ig_interpolation), equation, Δt)

    # create cache
    cache = IntegratorCachePGLRK{DT,D,S}()

    # create integrator
    IntegratorPGLRK{DT, TT, typeof(params), typeof(solver), typeof(iguess), N, D, S}(params, solver, iguess, cache)
end


@inline nstages(integrator::IntegratorPGLRK{DT,TT,PT,ST,IT,N,D,S}) where {DT,TT,PT,ST,IT,N,D,S} = S


function update_params!(params::ParametersPGLRK, sol::AtomicSolutionPODE)
    # set time for nonlinear solver and copy previous solution
    params.t̅  = sol.t
    params.q̅ .= sol.q
    params.p̅ .= sol.p
end


function compute_stages!(x::Vector{ST}, cache::IntegratorCachePGLRK{ST}, params::ParametersPGLRK) where {ST}
    compute_stages!(x, cache.Q, cache.V,
                       cache.P, cache.F,
                       cache.Y, cache.Z,
                       cache.q̃, cache.p̃,
                       cache.θ̃, cache.λ̃,
                       cache.ṽ, cache.f̃,
                       params)
end

function compute_stages!(x::Vector{ST}, Q::Vector{Vector{ST}}, V::Vector{Vector{ST}},
                                        P::Vector{Vector{ST}}, F::Vector{Vector{ST}},
                                        Y::Vector{Vector{ST}}, Z::Vector{Vector{ST}},
                                        q::Vector{ST}, p::Vector{ST},
                                        θ::Vector{ST}, λ::Vector{ST},
                                        y::Vector{ST}, z::Vector{ST},
                                        params::ParametersPGLRK{DT,TT,D,S}) where {ST,DT,TT,D,S}

    local tᵢ::TT
    local t₀::TT = params.t̅
    local t₁::TT = params.t̅ + params.Δt

    # copy x to V
    for i in 1:S
        for k in 1:D
            V[i][k] = x[D*(i-1)+k]
        end
    end

    # copy x to λ, q and p
    for k in 1:D
        q[k] = x[D*(S+0)+k]
        p[k] = x[D*(S+1)+k]
        λ[k] = x[D*(S+2)+k]
    end

    # compute tableaus
    for k in 1:D
        getTableauPGLRK(params.tab, λ[k], params.a_q)
        # get_symplectic_conjugate_coefficients(params.a_q, params.tab.b, params.a_p)
        for j=1:S
            for i=1:S
                params.A_q[i,j,k] = params.a_q[i,j]
                params.A_p[i,j,k] = params.a_q[i,j]
            end
        end
    end

    # compute Y and Q
    for i in 1:S
        for k in 1:D
            Y[i][k] = 0
            for j in 1:S
                Y[i][k] += params.A_q[i,j,k] * V[j][k]
            end
            Q[i][k] = params.q̅[k] + params.Δt * Y[i][k]
        end
    end

    # compute P=ϑ(Q,V) and F=f(Q,V)
    for i in 1:S
        tᵢ = params.t̅ + params.Δt * params.tab.c[i]
        params.equ.ϑ(tᵢ, Q[i], V[i], P[i])
        params.equ.f(tᵢ, Q[i], V[i], F[i])
    end

    # compute Z
    for i in 1:S
        for k in 1:D
            Z[i][k] = 0
            for j in 1:S
                Z[i][k] += params.A_p[i,j,k] * F[j][k]
            end
        end
    end

    # compute y and z
    y .= 0
    z .= 0
    for k in 1:D
        for j in 1:S
            y[k] += params.tab.b[j] * V[j][k]
            z[k] += params.tab.b[j] * F[j][k]
        end
    end

    # compute θ=ϑ(q,λ)
    params.equ.ϑ(t₁, q, λ, θ)
end

"Compute stages of variational partitioned Runge-Kutta methods."
@generated function function_stages!(x::Vector{ST}, b::Vector{ST}, params::ParametersPGLRK{DT,TT,D,S}) where {ST,DT,TT,D,S}

    cache = IntegratorCachePGLRK{ST,D,S}()

    quote
        compute_stages!(x, $cache, params)

        # compute b = [P-p-AF]
        for i in 1:S
            for k in 1:D
                b[D*(i-1)+k] = $cache.P[i][k] - params.p̅[k] - params.Δt * $cache.Z[i][k]
            end
        end

        # compute b = [q̅-q-bV, p̅-p-bF, p̅-α(q̅)]
        for k in 1:D
            b[D*(S+0)+k] = $cache.q̃[k] - params.q̅[k] - params.Δt * $cache.ṽ[k]
            b[D*(S+1)+k] = $cache.p̃[k] - params.p̅[k] - params.Δt * $cache.f̃[k]
            b[D*(S+2)+k] = $cache.p̃[k] - $cache.θ̃[k]
        end
    end
end


function initialize!(int::IntegratorPGLRK, sol::AtomicSolutionPODE)
    sol.t̅ = sol.t - timestep(int)

    equation(int).v(sol.t, sol.q, sol.p, sol.v)
    equation(int).f(sol.t, sol.q, sol.p, sol.f)

    initialize!(int.iguess, sol.t, sol.q, sol.p, sol.v, sol.f,
                            sol.t̅, sol.q̅, sol.p̅, sol.v̅, sol.f̅)
end


function initial_guess!(int::IntegratorPGLRK{DT,TT}, sol::AtomicSolutionPODE{DT,TT}) where {DT,TT}
    for i in eachstage(int)
        evaluate!(int.iguess, sol.q, sol.p, sol.v, sol.f,
                              sol.q̅, sol.p̅, sol.v̅, sol.f̅,
                              int.cache.q̃, int.cache.ṽ,
                              tableau(int).c[i])

        for k in eachdim(int)
            int.solver.x[ndims(int)*(i-1)+k] = int.cache.ṽ[k]
        end
    end

    evaluate!(int.iguess, sol.q, sol.p, sol.v, sol.f,
                          sol.q̅, sol.p̅, sol.v̅, sol.f̅,
                          int.cache.q̃, int.cache.p̃,
                          one(TT), one(TT))

    for k in eachdim(int)
        int.solver.x[ndims(int)*(nstages(int)+0)+k] = int.cache.q̃[k]
    end
    for k in eachdim(int)
        int.solver.x[ndims(int)*(nstages(int)+1)+k] = int.cache.p̃[k]
    end
    for k in eachdim(int)
        int.solver.x[ndims(int)*(nstages(int)+2)+k] = 0
    end
end


"Integrate PODE with variational partitioned Runge-Kutta integrator."
function integrate_step!(int::IntegratorPGLRK{DT,TT}, sol::AtomicSolutionPODE{DT,TT}) where {DT,TT}
    # update nonlinear solver parameters from cache
    update_params!(int.params, sol)

    # compute initial guess
    initial_guess!(int, sol)

    # reset cache
    reset!(sol, timestep(int))

    # call nonlinear solver
    solve!(int.solver)

    # print solver status
    print_solver_status(int.solver.status, int.solver.params)

    # check if solution contains NaNs or error bounds are violated
    check_solver_status(int.solver.status, int.solver.params)

    # compute vector fields at internal stages
    compute_stages!(int.solver.x, int.cache, int.params)

    # compute final update
    update_solution!(sol.q, sol.q̃, int.cache.V, tableau(int).b, timestep(int))
    update_solution!(sol.p, sol.p̃, int.cache.F, tableau(int).b, timestep(int))

    # copy solution to initial guess
    update!(int.iguess, sol.t, sol.q, sol.p, sol.v, sol.f)
end
