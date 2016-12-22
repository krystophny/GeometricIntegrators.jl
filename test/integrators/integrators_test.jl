
Δt = 0.1
nt = 10

@test typeof(Integrator(ODE(fx, [1.]), getTableauExplicitMidpoint(), Δt)) <: IntegratorERK
@test typeof(Integrator(ODE(fx, [1.]), getTableauCrouzeix(), Δt)) <: IntegratorDIRK
@test typeof(Integrator(ODE(fx, [1.]), getTableauImplicitMidpoint(), Δt)) <: IntegratorFIRK

ode = ODE(fx, [1.])
pode = PODE(fx, fx, [1.], [1.])
iode = IODE(fq, fp, [1.], [1.])
idae = IDAE(fq, fp, gq, gp, gϕ, [1.], [1.], [0.])

int = Integrator(ode, getTableauERK4(), Δt)
sol = integrate(int, nt)

int = Integrator(ode, getTableauImplicitMidpoint(), Δt)
sol = integrate(int, nt)

pint = Integrator(pode, getTableauSymplecticEulerA(), Δt)
psol = integrate(pint, nt)

itab = getTableauGLRK1()
iint = Integrator(iode, TableauIPRK(:pglrk, 2, itab.q, itab.q), Δt)
isol = integrate(iint, nt)

vint = Integrator(iode, getTableauLobIIIAB2(), Δt)
vsol = integrate(vint, nt)

dtab = getTableauGLRK2()
dint = Integrator(idae, getTableauSymplecticProjection(dtab.q, dtab.q), Δt)
dsol = integrate(dint, nt)
