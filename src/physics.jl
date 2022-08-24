using Tullio
export half_face_two_point_kgrad


#####################
# Gradient operator #
#####################

@inline function half_face_two_point_kgrad(
    conn_data::NamedTuple, p::AbstractArray, k::AbstractArray
    )
    half_face_two_point_kgrad(
        conn_data.self, conn_data.other, conn_data.T, p, k
        )
end

@inline function harm_av(
    c_self::I, c_other::I, T::R, k::AbstractArray
    ) where {R<:Real, I<:Integer}
    return T * (k[c_self]^-1 + value(k[c_other])^-1)^-1
end

@inline function grad(c_self, c_other, p::AbstractArray)
    return +(p[c_self] - value(p[c_other]))
end

@inline function half_face_two_point_kgrad(
    c_self::I, c_other::I, T::R, phi::AbstractArray, k::AbstractArray
    ) where {R<:Real, I<:Integer}
    k_av = harm_av(c_self, c_other, T, k)
    grad_phi = grad(c_self, c_other, phi)
    return k_av * grad_phi
end

function Jutul.update_equation!(eq_s,law::Conservation, storage, model, dt)
    update_accumulation!(eq_s,law, storage, model, dt)
    update_half_face_flux!(eq_s,law, storage, model, dt)
    #update_density!(eq_s,law, storage, model)
end


function update_accumulation!(eq_s,law::Conservation, storage, model, dt)
    conserved = eq_s.accumulation_symbol
    acc = get_entries(eq_s.accumulation)
    state = storage.state
    state0 = storage.state0
    m = state[conserved]
    m0 = state0[conserved]

    @tullio acc[c] = (m[c] - m0[c])/dt
    return acc
end

# function update_accumulation!(eq_s,law::Conservation{Charge}, storage, model, dt)
#     conserved = eq_s.accumulation_symbol
#     acc = get_entries(eq_s.accumulation)
#     #m = storage.state[conserved]
#     #m0 = storage.state0[conserved]
#     @tullio acc[c] = 0#(m[c] - m0[c])/dt
#     return acc
# end

function update_half_face_flux!(eq_s,    
    law::Conservation, storage, model, dt
    )
    fd = law.flow_discretization
    update_half_face_flux!(eq_s, law, storage, model, dt, fd)
end

function update_half_face_flux!(eq_s, law::Conservation, storage, model, dt, flow::TPFlow)
    f = get_entries(eq_s.half_face_flux_cells)
    internal_flux!(f, model, law, storage.state, flow.conn_data)
end

function internal_flux!(kGrad, model::ECModel, law::Conservation{Mass}, state, conn_data)
    @tullio kGrad[i] = -half_face_two_point_kgrad(conn_data[i], state.C, state.Diffusivity)
end

function internal_flux!(kGrad, model, law::Conservation{Charge}, state, conn_data)
    @tullio kGrad[i] = -half_face_two_point_kgrad(conn_data[i], state.Phi, state.Conductivity)
end

function internal_flux!(kGrad, model::ElectrolyteModel, law::Conservation{Mass}, state, conn_data)
    t = 1#param.t
    z =-0.202#param.z
    F = FARADAY_CONST

    for i in eachindex(kGrad)
        TPDGrad_C = half_face_two_point_kgrad(conn_data[i], state.C, state.Diffusivity)
        TPDGrad_Phi = half_face_two_point_kgrad(conn_data[i], state.Phi, state.Conductivity)
        TotalCurrent = -TPDGrad_C - TPDGrad_Phi
        ChargeCarrierFlux = TPDGrad_C + t / (F * z) * TotalCurrent
        kGrad[i] = ChargeCarrierFlux
    end
end

# @jutul_secondary function update_as_secondary!(
#     j, tv::TotalCurrent, model, param, TPkGrad_C, TPkGrad_Phi
#     )
#     @tullio j[i] =  - TPkGrad_C[i] - TPkGrad_Phi[i]
# end

function update_density!(law::Conservation, storage, model)
    nothing
end


#######################
# Boundary conditions #
#######################
# TODO: Add possibilites for different potentials to have different boundary cells

function corr_type(::Conservation{T}) return T() end


# Called from uppdate_state_dependents
function Jutul.apply_boundary_conditions!(storage, parameters, model::ECModel)
    equations_storage = storage.equations
    equations = model.equations
    for (eq, eq_s) in zip(values(equations), equations_storage)
        apply_bc_to_equation!(storage, parameters, model, eq, eq_s)
    end
end


function apply_boundary_potential!(
    acc, state, parameters, model, eq::Conservation{Charge}
    )
    # values
    Phi = state[:Phi]
    BoundaryPhi = state[:BoundaryPhi]
    κ = state[:Conductivity]

    bc = model.domain.grid.boundary_cells
    T_hf = model.domain.grid.boundary_T_hf

    for (i, c) in enumerate(bc)
        @inbounds acc[c] -= - κ[c]*T_hf[i]*(Phi[c] - BoundaryPhi[i])
    end
end

function apply_boundary_potential!(
    acc, state, parameters, model, eq::Conservation{Mass}
    )
    # values
    C = state[:C]
    BoundaryC = state[:BoundaryC]
    D = state[:Diffusivity]

    # Type
    bc = model.domain.grid.boundary_cells
    T_hf = model.domain.grid.boundary_T_hf

    for (i, c) in enumerate(bc)
        @inbounds acc[c] += - D[c]*T_hf[i]*(C[c] - BoundaryC[i])
    end
end

function apply_boundary_potential!(
    acc, state, parameters, model, eq::Conservation{Energy}
    )
    # values
    T = state[:T]
    BoundaryT = state[:BoundaryT]
    λ = state[:ThermalConductivity]

    bc = model.domain.grid.boundary_cells
    T_hf = model.domain.grid.boundary_T_hf

    for (i, c) in enumerate(bc)
        @inbounds acc[c] += - λ[c]*T_hf[i]*(T[c] - BoundaryT[i])
    end
end


function apply_bc_to_equation!(storage, parameters, model, eq::Conservation, eq_s)
    acc = get_entries(eq_s.accumulation)
    state = storage.state

    apply_boundary_potential!(acc, state, parameters, model, eq)

    jkey = BOUNDARY_CURRENT[corr_type(eq)]
    if haskey(state, jkey)
        apply_boundary_current!(acc, state, jkey, model, eq)
    end
end

function apply_boundary_current!(acc, state, jkey, model, eq::Conservation)
    J = state[jkey]

    jb = model.secondary_variables[jkey]
    for (i, c) in enumerate(jb.cells)
        @inbounds acc[c] -= J[i]
    end
end
