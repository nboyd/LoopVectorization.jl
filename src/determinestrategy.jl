
# TODO: FIXME for general case
# wrong for transposed matrices, and certain views/SubArrays.
unitstride(op::Operation, s) = first(getindices(op)) === s

function register_pressure(op::Operation)
    if isconstant(op)
        0
    else
        instruction_cost(instruction(op)).register_pressure
    end
end
function cost(op::Operation, unrolled::Symbol, Wshift::Int, size_T::Int = op.elementbytes)
    isconstant(op) && return 0.0, 0, 1
    # Wshift == dependson(op, unrolled) ? Wshift : 0
    # c = first(cost(instruction(op), Wshift, size_T))::Int
    instr = instruction(op)
    if length(parents(op)) == 1
        if instr == Instruction(:-) || instr === Instruction(:vsub) || instr == Instruction(:+) || instr == Instruction(:vadd)
            return 0.0, 0, 1
        end
    end
    opisunrolled = dependson(op, unrolled)
    srt, sl, srp = opisunrolled ? vector_cost(instr, Wshift, size_T) : scalar_cost(instr)
    if accesses_memory(op)
        # either vbroadcast/reductionstore, vmov(a/u)pd, or gather/scatter
        # @show instr, unrolled, loopdependencies(op), unitstride(op, unrolled)
        if opisunrolled
            if !unitstride(op, unrolled)# || !isdense(op) # need gather/scatter
                r = (1 << Wshift)
                srt *= r
                sl *= r
            # else # vmov(a/u)pd
            end
        elseif instr === :setindex! # broadcast or reductionstore; if store we want to penalize reduction
            srt *= 2
            sl *= 2
        end
    end
    srt, sl, srp
end

    # Base._return_type()

function biggest_type_size(ls::LoopSet)
    maximum(elsize, operations(ls))
end
function VectorizationBase.pick_vector_width(ls::LoopSet, u::Symbol)
    VectorizationBase.pick_vector_width(length(ls, u), biggest_type_size(ls))
end
function VectorizationBase.pick_vector_width_shift(ls::LoopSet, u::Symbol)
    VectorizationBase.pick_vector_width_shift(length(ls, u), biggest_type_size(ls))
end
function hasintersection(a, b)
    for aᵢ ∈ a, bᵢ ∈ b
        aᵢ === bᵢ && return true
    end
    false
end
function num_iterations(N, step)
    iter, rem = divrem(N, step)
    iter + (rem != 0)
end

# evaluates cost of evaluating loop in given order
# heuristically, could simplify analysis by just unrolling outer loop?
function evaluate_cost_unroll(
    ls::LoopSet, order::Vector{Symbol}, max_cost = typemax(Float64), vectorized::Symbol = first(order)
)
    # included_vars = Set{UInt}()
    included_vars = fill(false, length(operations(ls)))
    nested_loop_syms = Symbol[]#Set{Symbol}()
    total_cost = 0.0
    iter = 1.0
    # Need to check if fusion is possible
    size_T = biggest_type_size(ls)
    W, Wshift = VectorizationBase.pick_vector_width_shift(length(ls, vectorized), size_T)::Tuple{Int,Int}
    for itersym ∈ order
        # Add to set of defined symbles
        push!(nested_loop_syms, itersym)
        looplength = length(ls, itersym)
        liter = itersym === vectorized ? num_iterations(looplength, W) : looplength
        iter *= liter
        # check which vars we can define at this level of loop nest
        for (id,op) ∈ enumerate(operations(ls))
            # won't define if already defined...
            # id = identifier(op)
            included_vars[id] && continue
            # it must also be a subset of defined symbols
            loopdependencies(op) ⊆ nested_loop_syms || continue
            # hasintersection(reduceddependencies(op), nested_loop_syms) && return Inf
            rd = reduceddependencies(op)
            hasintersection(rd, nested_loop_syms[1:end-length(rd)]) && return Inf
            included_vars[id] = true
            
            total_cost += iter * first(cost(op, vectorized, Wshift, size_T))
            total_cost > max_cost && return total_cost # abort if more expensive; we only want to know the cheapest
        end
    end
    total_cost
end

# only covers vectorized ops; everything else considered lifted?
function depchain_cost!(
    skip::Vector{Bool}, op::Operation, vectorized::Symbol, Wshift::Int, size_T::Int, rt::Float64 = 0.0, sl::Int = 0
)
    skip[identifier(op)] = true
    # depth first search
    for opp ∈ parents(op)
        skip[identifier(opp)] && continue
        rt, sl = depchain_cost!(skip, opp, vectorized, Wshift, size_T, rt, sl)
    end
    # Basically assuming memory and compute don't conflict, but everything else does
    # Ie, ignoring the fact that integer and floating point operations likely don't either
    if iscompute(op)
        rtᵢ, slᵢ = cost(op, vectorized, Wshift, size_T)
        rt += rtᵢ; sl += slᵢ
    end
    rt, sl
end
function parentsnotreduction(op::Operation)
    for opp ∈ parents(op)
        isreduction(opp) && return false
    end
    return true
end
function roundpow2(i::Integer)
    u = VectorizationBase.nextpow2(i)
    l = u >>> 1
    ud = u - i
    ld = i - l
    ud > ld ? l : u
end
function unroll_no_reductions(ls, order, vectorized, Wshift, size_T)
    innermost = last(order)
    compute_rt = 0.0
    load_rt = 0.0
    # latency not a concern, because no depchains
    for op ∈ operations(ls)
        dependson(op, innermost) || continue
        if iscompute(op)
            compute_rt += first(cost(op, vectorized, Wshift, size_T))
        elseif isload(op)
            load_rt += first(cost(op, vectorized, Wshift, size_T))
        end
    end
    # heuristic guess
    # @show compute_rt, load_rt
    # roundpow2(min(4, round(Int, (compute_rt + load_rt + 1) / compute_rt)))
    rt = max(compute_rt, load_rt)
    max(1, roundpow2( min( 4, round(Int, 16 / rt) ) ))
end
function determine_unroll_factor(
    ls::LoopSet, order::Vector{Symbol}, unrolled::Symbol, vectorized::Symbol = first(order)
)
    size_T = biggest_type_size(ls)
    W, Wshift = VectorizationBase.pick_vector_width_shift(length(ls, vectorized), size_T)::Tuple{Int,Int}

    # The strategy is to use an unroll factor of 1, unless there appears to be loop carried dependencies (ie, num_reductions > 0)
    # The assumption here is that unrolling provides no real benefit, unless it is needed to enable OOO execution by breaking up these dependency chains
    num_reductions = 0#sum(isreduction, operations(ls))
    for op ∈ operations(ls)
        if isreduction(op) & iscompute(op) && parentsnotreduction(op)
            num_reductions += 1
        end
    end
    if iszero(num_reductions)
        # if only 1 loop, no need to unroll
        # if more than 1 loop, there is some cost. Picking 2 here as a heuristic.
        return unroll_no_reductions(ls, order, vectorized, Wshift, size_T)
    end
    # So if num_reductions > 0, we set the unroll factor to be high enough so that the CPU can be kept busy
    # if there are, U = max(1, round(Int, max(latency) * throughput / num_reductions)) = max(1, round(Int, latency / (recip_throughput * num_reductions)))
    # We also make sure register pressure is not too high.
    latency = 0
    compute_recip_throughput = 0.0
    visited_nodes = fill(false, length(operations(ls)))
    load_recip_throughput = 0.0
    store_recip_throughput = 0.0
    for op ∈ operations(ls)
        dependson(op, unrolled) || continue
        if isreduction(op)
            rt, sl = depchain_cost!(visited_nodes, op, vectorized, Wshift, size_T)
            latency = max(sl, latency)
            compute_recip_throughput += rt
        elseif isload(op)
            load_recip_throughput += first(cost(op, vectorized, Wshift, size_T))
        elseif isstore(op)
            store_recip_throughput += first(cost(op, vectorized, Wshift, size_T))
        end
    end
    recip_throughput = max(
        compute_recip_throughput,
        load_recip_throughput,
        store_recip_throughput
    )
    roundpow2(max(1, round(Int, latency / (recip_throughput * num_reductions) ) ))
end

function tile_cost(X, U, T, UL, TL)
    X[1] + X[4] + X[2] * (num_iterations(TL, T)/TL) + X[3] * (num_iterations(UL, U)/UL)
end
function solve_tilesize(X, R, UL, TL)
    @inbounds any(iszero, (R[1],R[2],R[3])) && return -1,-1,Inf #solve_smalltilesize(X, R, Umax, Tmax)
    # @inbounds any(iszero, (R[1],R[2],R[3])) && return -1,-1,Inf #solve_smalltilesize(X, R, Umax, Tmax)
    # We use a lagrange multiplier to find floating point values for U and T
    # first solving for U via quadratic formula
    # X is vector of costs, and R is of register pressures
    RR = REGISTER_COUNT - R[3] - R[4] # RR ≡ RemainingRegisters
    a = (R[1])^2*X[2] - (R[2])^2*R[1]*X[3]/RR
    b = 2*R[1]*R[2]*X[3]
    c = -RR*R[1]*X[3]
    Ufloat = (sqrt(b^2 - 4a*c) - b) / (2a)
    Tfloat = (RR - Ufloat*R[2])/(Ufloat*R[1])
    # @show Ufloat, Tfloat
    (isfinite(Tfloat) && isfinite(Ufloat)) || return -1,-1,Inf
    Ulow = max(1, floor(Int, Ufloat)) # must be at least 1
    Tlow = max(1, floor(Int, Tfloat)) # must be at least 1
    Uhigh = Ulow + 1 #ceil(Int, Ufloat)
    Thigh = Tlow + 1 #ceil(Int, Tfloat)

    # RR = REGISTER_COUNT - R[3] - R[4]
    U, T = Ulow, Tlow
    tcost = tile_cost(X, Ulow, Tlow, UL, TL)
    # @show Ulow*Thigh*R[1] + Ulow*R[2]
    if RR ≥ Ulow*Thigh*R[1] + Ulow*R[2]
        tcost_temp = tile_cost(X, Ulow, Thigh, UL, TL)
        # @show tcost_temp, tcost
        if tcost_temp < tcost
            tcost = tcost_temp
            U, T = Ulow, Thigh
        end
    end
    # The RR + 1 is a hack to get it to favor Uhigh in more scenarios
    Tl = Tlow
    while RR < Uhigh*Tl*R[1] + Uhigh*R[2] && Tl > 1
        Tl -= 1
    end
    tcost_temp = tile_cost(X, Uhigh, Tl, UL, TL)
    if tcost_temp < tcost
        tcost = tcost_temp
        U, T = Uhigh, Tl
    end
    if RR > Uhigh*Thigh*R[1] + Uhigh*R[2]
        throw("Something went wrong when solving for Tfloat and Ufloat.")
    end
    U, T, tcost
end
function solve_tilesize_constU(X, R, U)
    floor(Int, (REGISTER_COUNT - R[3] - R[4] - U*R[2]) / (U * R[1]))
end
function solve_tilesize_constT(X, R, T)
    floor(Int, (REGISTER_COUNT - R[3] - R[4]) / (T * R[1] + R[2]))
end
function solve_tilesize_constT(ls, T)
    R = @view ls.reg_pres[:,1]
    floor(Int, (REGISTER_COUNT - R[3] - R[4]) / (T * R[1] + R[2]))
end
# Tiling here is about alleviating register pressure for the UxT
function solve_tilesize(X, R, Umax, Tmax, UL, TL)
    first(R) == 0 && return -1,-1,Inf #solve_smalltilesize(X, R, Umax, Tmax)
    U, T, cost = solve_tilesize(X, R, UL, TL)
    # T -= T & 1
    # U = min(U, T)
    U_too_large = U > Umax
    T_too_large = T > Tmax
    if U_too_large
        if T_too_large
            U = Umax
            T = Tmax
        else # U too large, resolve T
            U = Umax
            T = min(Tmax, solve_tilesize_constU(X, R, U))
        end
    elseif T_too_large
        T = Tmax
        U = min(Umax, solve_tilesize_constT(X, R, T))
    end
    U, T, cost
end
function maybedemotesize(U::Int, N::Int)
    # U > 1 || return 1
    Um1 = U - 1
    urep = num_iterations(N, U)
    um1rep = num_iterations(N, Um1)
    um1rep > urep ? U : Um1
end
function maybedemotesize(T::Int, N::Int, U::Int, Uloop::Loop, maxTbase::Int)
    T > 1 || return T
    T == N && return T
    T = maybedemotesize(T, N)
    if !(isstaticloop(Uloop) && length(Uloop) == U)
        if N % T != 0
            T = min(T, maxTbase)
        end
    end
    T
end
function solve_tilesize(
    ls::LoopSet, unrolled::Symbol, tiled::Symbol,
    cost_vec::AbstractVector{Float64}, 
    reg_pressure::AbstractVector{Int},
    W::Int, vectorized::Symbol
)
    maxTbase = maxUbase = 4
    maxT = maxTbase#8
    maxU = maxUbase#8
    tiledloop = getloop(ls, tiled)
    unrolledloop = getloop(ls, unrolled)
    if isstaticloop(tiledloop)
        maxT = min(4maxT, length(tiledloop))
    end
    if isstaticloop(unrolledloop)
        UL = length(unrolledloop)
        UL = unrolled === vectorized ? cld(UL,W) : UL
        maxU = min(4maxU, UL)
    end
    U, T, cost = solve_tilesize(cost_vec, reg_pressure, maxU, maxT, length(unrolledloop), length(tiledloop))
    # heuristic to more evenly divide small numbers of iterations
    if isstaticloop(tiledloop)
        T = maybedemotesize(T, length(tiledloop), U, unrolledloop, maxTbase)
    end
    if isstaticloop(unrolledloop)
        U = maybedemotesize(U, length(unrolledloop), T, tiledloop, maxUbase)
    end
    U, T, cost
end

function set_upstream_family!(adal::Vector{T}, op::Operation, val::T) where {T}
    adal[identifier(op)] == val && return # must already have been set
    adal[identifier(op)] = val
    for opp ∈ parents(op)
        set_upstream_family!(adal, opp, val)
    end
end

function stride_penalty(ls::LoopSet, op::Operation, order::Vector{Symbol})
    num_loops = length(order)
    contigsym = first(loopdependencies(op))
    contigsym == Symbol("##DISCONTIGUOUSSUBARRAY##") && return 0
    iter = 0
    for i ∈ 0:num_loops - 1
        loopsym = order[num_loops - i]
        loopsym === contigsym && return iter
        iter *= length(getloop(ls, loopsym))
    end
    iter
end
function stride_penalty(ls::LoopSet, order::Vector{Symbol})
    stridepenalty = 0
    for op ∈ operations(ls)
        if accesses_memory(op)
            stridepenalty += stride_penalty(ls, op, order)
        end
    end
    stridepenalty * 1e-9
end
# Just tile outer two loops?
# But optimal order within tile must still be determined
# as well as size of the tiles.
function evaluate_cost_tile(
    ls::LoopSet, order::Vector{Symbol}, vectorized::Symbol
)
    N = length(order)
    @assert N ≥ 2 "Cannot tile merely $N loops!"
    tiled = order[1]
    unrolled = order[2]
    ops = operations(ls)
    nops = length(ops)
    included_vars = fill(false, nops)
    unrolledtiled = fill(false, 2, nops)
    descendentsininnerloop = fill(false, nops)
    innerloop = last(order)
    iters = fill(-99.9, nops)
    nested_loop_syms = Symbol[]# Set{Symbol}()
    # Need to check if fusion is possible
    size_T = biggest_type_size(ls)
    W, Wshift = VectorizationBase.pick_vector_width_shift(length(ls, vectorized), size_T)::Tuple{Int,Int}
    # costs = 
    # cost_mat[1] / ( unrolled * tiled)
    # cost_mat[2] / ( tiled)
    # cost_mat[3] / ( unrolled)
    # cost_mat[4]
    # @show order
    cost_vec = cost_vec_buf(ls)
    reg_pressure = reg_pres_buf(ls)
    # @inbounds reg_pressure[2] = 1
    # @inbounds reg_pressure[3] = 1
    unrollediter = length(ls, unrolled)
    tilediter = length(ls, tiled)
    unrollediter = unrolled === vectorized ? num_iterations(unrollediter, W) : unrollediter # tiled cannot be vectorized, so do not check
    iter::Int = tilediter * unrollediter
    for n ∈ 1:N
        itersym = order[n]
        # Add to set of defined symbles
        push!(nested_loop_syms, itersym)
        stepsize = 1
        if n > 2
            itersymlooplen = length(ls, itersym)
            iter *= itersym === vectorized ? num_iterations(itersymlooplen, W) : itersymlooplen
        end
        # check which vars we can define at this level of loop nest
        for (id, op) ∈ enumerate(ops)
            # isconstant(op) && continue
            # @assert id == identifier(op)+1 # testing, for now
            # won't define if already defined...
            included_vars[id] && continue
            # it must also be a subset of defined symbols
            loopdependencies(op) ⊆ nested_loop_syms || continue
            # # @show nested_loop_syms
            # # @show reduceddependencies(op)
            rd = reduceddependencies(op)
            hasintersection(rd, nested_loop_syms[1:end-length(rd)]) && return 0,0,Inf
            included_vars[id] = true
            unrolledtiled[1,id] = unrolled ∈ loopdependencies(op)
            unrolledtiled[2,id] = tiled ∈ loopdependencies(op)
            iters[id] = iter
            innerloop ∈ loopdependencies(op) && set_upstream_family!(descendentsininnerloop, op, true)
        end
    end
    for (id, op) ∈ enumerate(ops)
        iters[id] == -99.9 && continue
        opisininnerloop = descendentsininnerloop[id]
        isunrolled = unrolledtiled[1,id]
        istiled = unrolledtiled[2,id]
        rt, lat, rp = cost(op, vectorized, Wshift, size_T)
        rp = opisininnerloop ? rp : 0 # we only care about register pressure within the inner most loop
        rt *= iters[id]
        if isunrolled && istiled # no cost decrease; cost must be repeated
            cost_vec[1] += rt
            reg_pressure[1] += rp
        elseif isunrolled # cost decreased by tiling
            cost_vec[2] += rt
            reg_pressure[2] += rp
        elseif istiled # cost decreased by unrolling
            cost_vec[3] += rt
            reg_pressure[3] += rp
        else# neither unrolled or tiled
            cost_vec[4] += rt
            reg_pressure[4] += rp
        end
    end
    sum(reg_pressure) > VectorizationBase.REGISTER_COUNT && return 0, 0, Inf
    # @show order, vectorized cost_vec reg_pressure
    # @show solve_tilesize(ls, unrolled, tiled, cost_vec, reg_pressure)
    U, T, tcost = solve_tilesize(ls, unrolled, tiled, cost_vec, reg_pressure, W, vectorized)
    U, T, tcost + stride_penalty(ls, order)
end


struct LoopOrders
    syms::Vector{Symbol}
    buff::Vector{Symbol}
end
function LoopOrders(ls::LoopSet)
    syms = copy(ls.loopsymbols)
    LoopOrders(syms, similar(syms))
end
function Base.iterate(lo::LoopOrders)
    lo.syms, zeros(Int, length(lo.syms))# - 1)
end

function swap!(x, i, j)
    xᵢ, xⱼ = x[i], x[j]
    x[j], x[i] = xᵢ, xⱼ
end
function advance_state!(state)
    N = length(state)
    for n ∈ 1:N
        sₙ = state[n]
        if sₙ == N - n
            if n == N
                return false
            else
                state[n] = 0
            end
        else
            state[n] = sₙ + 1
            break
        end
    end
    true
end
# I doubt this is the most efficient algorithm, but it's the simplest thing
# that I could come up with.
function Base.iterate(lo::LoopOrders, state)
    advance_state!(state) || return nothing
    # # @show state
    syms = copyto!(lo.buff, lo.syms)
    for i ∈ eachindex(state)
        sᵢ = state[i]
        sᵢ == 0 || swap!(syms, i, i + sᵢ)
    end
    syms, state
end
function choose_unroll_order(ls::LoopSet, lowest_cost::Float64 = Inf)
    lo = LoopOrders(ls)
    best_order = lo.syms
    new_order, state = iterate(lo) # right now, new_order === best_order
    best_vec = first(new_order)
    while true
        for new_vec ∈ new_order
            cost_temp = evaluate_cost_unroll(ls, new_order, lowest_cost, new_vec)
            if cost_temp < lowest_cost
                lowest_cost = cost_temp
                best_order = new_order
                best_vec = new_vec
            end
        end
        iter = iterate(lo, state)
        iter === nothing && return best_order, best_vec, lowest_cost
        new_order, state = iter
    end    
end
function choose_tile(ls::LoopSet)
    lo = LoopOrders(ls)
    # @show lo.syms ls.loop_order.bestorder
    best_order = copyto!(ls.loop_order.bestorder, lo.syms)
    best_vec = first(best_order) # filler
    new_order, state = iterate(lo) # right now, new_order === best_order
    U, T, lowest_cost = 0, 0, Inf
    while true
        for new_vec ∈ @view(new_order[2:end]) # view to skip first
            U_temp, T_temp, cost_temp = evaluate_cost_tile(ls, new_order, new_vec)
            if cost_temp < lowest_cost
                lowest_cost = cost_temp
                U, T = U_temp, T_temp
                best_vec = new_vec
                copyto!(best_order, new_order)
                save_tilecost!(ls)
            end
        end
        iter = iterate(lo, state)
        iter === nothing && return best_order, best_vec, U, T, lowest_cost
        new_order, state = iter
    end
end
# Last in order is the inner most loop
function choose_order(ls::LoopSet)
    if num_loops(ls) > 1
        torder, tvec, tU, tT, tc = choose_tile(ls)
    else
        tc = Inf
    end
    uorder, uvec, uc = choose_unroll_order(ls, tc)
    if num_loops(ls) > 1 && tc ≤ uc
        return torder, tvec, min(tU, tT), tT
        # return torder, tvec, 4, 4#5, 5
    else
        return uorder, uvec, determine_unroll_factor(ls, uorder, first(uorder), uvec), -1
    end
end

function register_pressure(ls::LoopSet)
    # uses unroll of 1 if not tiling
    if num_loops(ls) > 1
        torder, tvec, tU, tT, tc = choose_tile(ls)
    else
        tc = Inf
    end
    uorder, uvec, uc = choose_unroll_order(ls, tc)
    if num_loops(ls) > 1 && tc ≤ uc # tile
        rp = @view ls.reg_pressure[:,1]
        tU * tT * rp[1] + tU * rp[2] + rp[3] + rp[4]
    else
        sum(register_pressure, operations(ls))
    end    
end

