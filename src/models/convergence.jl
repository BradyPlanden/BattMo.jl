function Jutul.convergence_criterion(model::ECModel, storage, eq::ConservationLaw{:Mass}, eq_s, r; dt = 1)
    n = number_of_equations_per_entity(model, eq)
    V = storage.state.Volume
    V_f = storage.state.VolumeFraction
    max_c = maximum_concentration(model.system)
    scale = dt#/max_c
    @tullio max e[i] := scale*abs(r[i, j])/(value(V[j])*value(V_f[j]))
    if n == 1
        names = "R"
    else
        names = map(i -> "R_$i", 1:n)
    end
    R = (AbsMax = (errors = e, names = names), )
    return R
end

function Jutul.convergence_criterion(model::ECModel, storage, eq::ConservationLaw{:Charge}, eq_s, r; dt = 1)
    n = number_of_equations_per_entity(model, eq)
    @tullio max e[i] := abs(r[i, j])
    if n == 1
        names = "R"
    else
        names = map(i -> "R_$i", 1:n)
    end
    R = (AbsMax = (errors = e, names = names), )
    return R
end
