using Jutul
export ElectroChemicalComponent, CurrentCollector, Electectrolyte, TestElyte
export vonNeumannBC, DirichletBC, BoundaryCondition, MinimalECTPFAGrid
export ChargeFlow, Conservation, BoundaryPotential, BoundaryCurrent
export Phi, C, T, Charge, Mass, Energy, KGrad
export BOUNDARY_CURRENT, corr_type
export TPFAInterfaceFluxCT,ButlerVolmerInterfaceFluxCT
###########
# Classes #
###########

struct BoundaryFaces <: Jutul.JutulEntity end

abstract type ElectroChemicalComponent <: JutulSystem end
# Alias for a genereal Electro Chemical Model
const ECModel = SimulationModel{<:Any, <:ElectroChemicalComponent, <:Any, <:Any}

abstract type ElectroChemicalGrid <: AbstractJutulMesh end

# Potentials
abstract type Potential <: ScalarVariable end
struct Phi <: Potential end
struct C <: Potential end
struct T <: Potential end

struct Conductivity <: ScalarVariable end
struct Diffusivity <: ScalarVariable end
struct ThermalConductivity <: ScalarVariable end

struct Conservation{T, F} <: JutulEquation
    flow_discretization::F
end

struct ConservationTPFAStorage{T} <: JutulEquation
    accumulation::JutulAutoDiffCache
    accumulation_symbol::Symbol
    half_face_flux_cells::JutulAutoDiffCache
    density::JutulAutoDiffCache
end

function setup_equation_storage(model, eq::ConservationLaw{<:TwoPointPotentialFlowHardCoded}, storage; kwarg...)
    return ConservationLawTPFAStorage(model, eq; kwarg...)
end

# Accumulation variables
abstract type Conserved <: ScalarVariable end
struct Charge <: Conserved end
struct Mass <: Conserved end
struct Energy <: Conserved end

# Currents corresponding to a accumulation type
const BOUNDARY_CURRENT = Dict(
    Charge() => :BCCharge,
    Mass()   => :BCMass,
    Energy() => :BCEnergy,
)
# TODO: Can this not be automated????
corr_type(::Conservation{T}) where T = T()


# Represents k∇T, where k is a tensor, T a potential
abstract type KGrad{T} <: ScalarVariable end
Jutul.associated_entity(::KGrad) = Faces()

struct TPkGrad{T} <: KGrad{T} end

# abstract type ECFlow <: FlowType end
# struct ChargeFlow <: ECFlow end


struct BoundaryPotential{T} <: ScalarVariable end
Jutul.associated_entity(::BoundaryPotential) = BoundaryFaces()

struct BoundaryCurrent{T} <: ScalarVariable 
    cells
end

Jutul.associated_entity(::BoundaryCurrent) = BoundaryFaces()


abstract type Current <: ScalarVariable end
Jutul.associated_entity(::Current) = Faces()

struct TotalCurrent <: Current end
struct ChargeCarrierFlux <: Current end
struct EnergyFlux <: Current end

function number_of_entities(model, pv::Current)
    return 2*count_entities(model.domain, Faces())
end

abstract type NonDiagCellVariables <: JutulVariables end

# Abstract type of a vector that is defined on a cell, from face flux
abstract type CellVector <: NonDiagCellVariables end
struct JCell <: CellVector end

abstract type ScalarNonDiagVaraible <: NonDiagCellVariables end
struct JSq <: ScalarNonDiagVaraible end

struct JSqDiag <: ScalarVariable end

struct MinimalECTPFAGrid{R<:AbstractFloat, I<:Integer} <: ElectroChemicalGrid
    """
    Simple grid for a electro chemical component
    """
    volumes::AbstractVector{R}
    neighborship::AbstractArray{I}
    boundary_cells::AbstractArray{I}
    boundary_T_hf::AbstractArray{R}
    P::AbstractArray{R} # Tensor to map from cells to faces
    S::AbstractArray{R} # Tensor map cell vector to cell scalar
    vol_frac::AbstractVector{R}
end

import Jutul: FlowDiscretization
struct TPFlow <: FlowDiscretization
    # TODO: Declare types ?
    conn_pos
    conn_data
    cellfacecellvec
    cellcellvec
    cellcell
    maps # Maps between indices
end


################
# Constructors #
################

function TPFlow(grid::AbstractJutulMesh, T; tensor_map = false)
    N = get_neighborship(grid)
    faces, face_pos = get_facepos(N)

    nhf = length(faces)
    nc = length(face_pos) - 1
    if !isnothing(T)
        @assert length(T) == nhf ÷ 2
    end
    get_el = (face, cell) -> Jutul.get_connection(face, cell, faces, N, T, nothing, nothing, false)
    el_type = typeof(get_el(1, 1))
    
    conn_data = Vector{el_type}(undef, nhf)
    Threads.@threads for cell = 1:nc
        @inbounds for fpos = face_pos[cell]:(face_pos[cell+1]-1)
            conn_data[fpos] = get_el(faces[fpos], cell)
        end
    end

    cfcv, ccv, cc, map = [[], [], [], []]
    if tensor_map
        cfcv = get_cellfacecellvec_tbl(conn_data, face_pos)
        ccv = get_cellcellvec_tbl(conn_data, face_pos)
        cc = get_cellcell_tbl(conn_data, face_pos)

        cfcv2ccv = get_cfcv2ccv_map(cfcv, ccv)
        ccv2cc = get_ccv2cc_map(ccv, cc)
        cfcv2fc, cfcv2fc_bool = get_cfcv2fc_map(cfcv, conn_data)

        map = (
            cfcv2ccv = cfcv2ccv, 
            ccv2cc = ccv2cc, 
            cfcv2fc = cfcv2fc,
            cfcv2fc_bool = cfcv2fc_bool
        )
    end

    TPFlow(face_pos, conn_data, cfcv, ccv, cc, map)
end


function MinimalECTPFAGrid(pv, N, bc=[], T_hf=[], P=[], S=[], vf=[])
    nc = length(pv)
    pv::AbstractVector
    @assert size(N, 1) == 2
    if length(N) > 0
        @assert minimum(N) > 0
        @assert maximum(N) <= nc
    end
    @assert all(pv .> 0)
    @assert size(bc) == size(T_hf)

    if size(vf) != nc
        vf = ones(nc)
    end

    MinimalECTPFAGrid{eltype(pv), eltype(N)}(pv, N, bc, T_hf, P, S, vf)
end

function ConservationTPFAStorage(
        model, eq::Conservation{C, <:Any}; kwarg...
    ) where C
    """
    A conservation law corresponding to a conserved charge acc_type
    """
    acc_type = C()
    accumulation_symbol = acc_symbol(acc_type)

    D = model.domain
    cell_entity = Cells()
    face_entity = Faces()
    nc = count_entities(D, cell_entity)
    nf = count_entities(D, face_entity)
    nhf = 2 * nf
    nn = size(get_neighborship(D.grid), 2)
    n_tot = nc + 2 * nn
    neq = Jutul.number_of_equations(model, eq)

    alloc = (n, entity, n_entities_pos) -> CompactAutoDiffCache(
        neq, n, model, entity = entity, n_entities_pos = n_entities_pos,
        context = model.context; kwarg...
    )

    acc = alloc(nc, cell_entity, nc)
    hf_cells = alloc(nhf, cell_entity, nhf)
    density = alloc(n_tot, cell_entity, n_tot)

    ConservationTPFAStorage{C}(
        acc, accumulation_symbol, hf_cells, density
    )
end

function Jutul.setup_equation_storage(model, eq::Conservation, storage; kwarg...)
    return ConservationTPFAStorage(model, eq; kwarg...)
end

function acc_symbol(::Charge)
    return :Charge
end

function acc_symbol(::Mass)
    return :Mass
end

function acc_symbol(::Energy)
    return :Energy
end

struct TPFAInterfaceFluxCT{T,F} <: Jutul.AdditiveCrossTerm
    target_cells::T
    source_cells::T
    trans::F
    is_symmetric::Bool
    function TPFAInterfaceFluxCT(target::T, source::T, trans::F; symmetric = true) where {T, F}
        new{T, F}(target, source, trans, symmetric)
    end
end

Jutul.has_symmetry(ct::TPFAInterfaceFluxCT) = ct.is_symmetric

export AccumulatorInterfaceFluxCT
struct AccumulatorInterfaceFluxCT{T,F} <: Jutul.AdditiveCrossTerm
    target_cell::Integer
    source_cells::T
    trans::F
    function AccumulatorInterfaceFluxCT(target::Integer, source::T, trans::F) where {T, F}
        new{T, F}(target, source, trans)
    end
end

struct ButlerVolmerInterfaceFluxCT{T} <: Jutul.AdditiveCrossTerm
    target_cells::T
    source_cells::T
end
