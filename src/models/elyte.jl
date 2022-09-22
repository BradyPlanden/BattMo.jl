using Polynomials
export Electrolyte, TestElyte, DmuDc, ConsCoeff
export p1, p2, p3, cnst, diffusivity
export ElectrolyteModel

abstract type Electrolyte <: ElectroChemicalComponent end
struct TestElyte <: Electrolyte end

# Alias for convinience
const ElectrolyteModel = SimulationModel{<:Any, <:Electrolyte, <:Any, <:Any}
const TestElyteModel = SimulationModel{<:Any, <:TestElyte, <:Any, <:Any}

struct TPDGrad{T} <: KGrad{T} end
# Is it necesessary with a new struxt for all these?
struct DmuDc <: ScalarVariable end
struct ConsCoeff <: ScalarVariable end

struct DGradCCell <: CellVector end
struct DGradCSq <: ScalarNonDiagVaraible end
struct DGradCSqDiag <: ScalarVariable end
struct EnergyDensity <: ScalarNonDiagVaraible end
struct EDDiag <: ScalarVariable end

function select_equations_system!(eqs, domain, system::Electrolyte, formulation)
    # TODO: FIXME.
    charge_cons = (arg...; kwarg...) -> Conservation(:Charge, arg...; kwarg...)
    mass_cons = (arg...; kwarg...) -> Conservation(:Mass, arg...; kwarg...)
    energy_cons = (arg...; kwarg...) -> Conservation(:Energy, arg...; kwarg...)
    
    eqs[:charge_conservation] = (charge_cons, 1)
    eqs[:mass_conservation] = (mass_cons, 1)
    eqs[:energy_conservation] = (energy_cons, 1)
end

function select_primary_variables!(S, system::Electrolyte, model)
    S[:Phi] = Phi()
    S[:C] = C()
    S[:T] = T()
end


function select_secondary_variables!(S, system::Electrolyte, model)
    S[:Conductivity] = Conductivity()
    S[:ThermalConductivity] = Conductivity()
    S[:Diffusivity] = Diffusivity()
    S[:DmuDc] = DmuDc()
    S[:ConsCoeff] = ConsCoeff()

    # S[:TotalCurrent] = TotalCurrent()
    # S[:ChargeCarrierFlux] = ChargeCarrierFlux()

    S[:JCell] = JCell()
    S[:JSq] = JSq()
    S[:DGradCCell] = DGradCCell()
    S[:DGradCSq] = DGradCSq()

    S[:EnergyDensity] = EnergyDensity()

    S[:Charge] = Charge()
    S[:Mass] = Mass()
    S[:Energy] = Energy()

    # Variables for plotting
    S[:DGradCSqDiag] = DGradCSqDiag()
    S[:JSqDiag] = JSqDiag()
    S[:EDDiag] = EDDiag()
end

function select_minimum_output_variables!(out, system::Electrolyte, model)
    for k in [:Charge, :Mass, :Energy, :Conductivity, :Diffusivity]
        push!(out, k)
    end
end


#######################
# Secondary Variables #
#######################
const poly_param = [
    -10.5       0.074       -6.96e-5    ;
    0.668e-3    -1.78e-5    2.80e-8     ;
    0.494e-6    -8.86e-10   0           ;
]
const p1 = Polynomial(poly_param[1:end, 1])
const p2 = Polynomial(poly_param[1:end, 2])
const p3 = Polynomial(poly_param[1:end, 3])

@inline function cond(T::Real, C::Real, ::Electrolyte)
    fact = 1e-4  # * 500 # fudge factor
    return fact * C * (p1(C) + p2(C) * T + p3(C) * T^2)^2
end

const diff_params = [
    -4.43   -54 ;
    -0.22   0.0 ;
]
const Tgi = [229 5.0]

@inline function diffusivity(T::Real, C::Real, ::Electrolyte)
    return (
        1e-4 * 10 ^ ( 
            diff_params[1,1] + 
            diff_params[1,2] / ( T - Tgi[1] - Tgi[2] * C * 1e-3) + 
            diff_params[2,1] * C * 1e-3
            )
        )
end


@jutul_secondary(
function update_as_secondary!(dmudc, sv::DmuDc, model, T, C)
    R = GAS_CONSTANT
    @tullio dmudc[i] = R * (T[i] / C[i])
end
)

# ? Does this maybe look better ?
@jutul_secondary(
function update_as_secondary!(
    con, tv::Conductivity, model::ElectrolyteModel, T, C
    )
    s = model.system
    vf = model.domain.grid.vol_frac
    @tullio con[i] = cond(T[i], C[i], s) * vf[i]^1.5
end
)

@jutul_secondary function update_as_secondary!(
    D, sv::Diffusivity, model::ElectrolyteModel, C, T
    )
    s = model.system
    vf = model.domain.grid.vol_frac
    @tullio D[i] = diffusivity(T[i], C[i], s)  * vf[i]^1.5
end


@jutul_secondary function update_as_secondary!(
    coeff, tv::ConsCoeff, model::ElectrolyteModel, Conductivity, DmuDc
    )
    sys = model.system
    t = sys.t
    z = sys.z
    F = FARADAY_CONST
    @tullio coeff[i] = Conductivity[i]*DmuDc[i] * t/(F*z)
end

function apply_boundary_potential!(
    acc, stateeters, model::ElectrolyteModel, eq::ConservationLaw{:Charge}
    )
    # values
    Phi = state[:Phi]
    C = state[:C]
    κ = state[:Conductivity]
    coeff = state[:ConsCoeff]

    BPhi = state[:BoundaryPhi]
    BC = state[:BoundaryC]

    bc = model.domain.grid.boundary_cells
    T_hf = model.domain.grid.boundary_T_hf

    for (i, c) in enumerate(bc)
        @inbounds acc[c] -= (
            - coeff[c] * T_hf[i] * (C[c] - BC[i])
            - κ[c] * T_hf[i] * (Phi[c] - BPhi[i])
        )
    end
end


function apply_boundary_potential!(
    acc, stateeters, model::ElectrolyteModel, eq::ConservationLaw{:Mass}
    )
    # values
    Phi = state[:Phi]
    C = state[:C]
    κ = state[:Conductivity]
    D = state[:Diffusivity]

    F = FARADAY_CONST
    sys = model.system
    t = sys.t
    z = sys.z

    coeff = state[:ConsCoeff]

    BPhi = state[:BoundaryPhi]
    BC = state[:BoundaryC]

    bc = model.domain.grid.boundary_cells
    T_hf = model.domain.grid.boundary_T_hf

    for (i, c) in enumerate(bc)
        @inbounds j = (
            - coeff[c] * T_hf[i] * (C[c] - BC[i])
            - κ[c] * T_hf[i] * (Phi[c] - BPhi[i])
        )
        @inbounds acc[c] -= (
            - D[c] * T_hf[i] * (C[c] - BC[i])
            + t / (F * z) * j
        )
    end
end

function apply_boundary_potential!(
    acc, stateeters, model::ElectrolyteModel, eq::ConservationLaw{:Energy}
    )
    # values
    T = state[:T]
    λ = state[:ThermalConductivity]
    BT = state[:BoundaryT]


    # Type
    bc = model.domain.grid.boundary_cells
    T_hf = model.domain.grid.boundary_T_hf

    for (i, c) in enumerate(bc)
        # TODO: Add influence of boundary on energy density
        @inbounds acc[c] -= - λ[c] * T_hf[i] * (T[c] - BT[i])
    end
end

