
function add_expr(q, incr)
    q2 = copy(q)
    if q2.head === :call && q2.args[2] === :+
        push!(q2.args, incr)
    else
        q2 = Expr(:call, :+, q2, incr)
    end
    q2
end
function lower_load_scalar!(
    q::Expr, op::Operation, W::Int, unrolled::Symbol, U::Int,
    suffix::Union{Nothing,Int}, mask::Union{Nothing,Symbol,Unsigned} = nothing
)

    loopdeps = loopdependencies(op)
    @assert unrolled ∉ loopdeps
    var = op.variable
    if suffix !== nothing
        var = Symbol(var, :_, suffix)
    end
    ptr = Symbol(:vptr_, var)
    push!(q.args, Expr(:(=), var, Expr(:call, :load,  ptr, mem_offset(op))))
    nothing
end
function lower_load_unrolled!(
    q::Expr, op::Operation, W::Int, unrolled::Symbol, U::Int,
    suffix::Union{Nothing,Int}, mask::Union{Nothing,Symbol,Unsigned} = nothing
)
    loopdeps = loopdependencies(op)
    @assert unrolled ∈ loopdeps
    var = op.variable
    if suffix !== nothing
        var = Symbol(var, :_, suffix)
    end
    ptr = Symbol(:vptr_, var)
    memoff = mem_offset(op)
    upos = symposition(op, unrolled)
    ustride = op.numerical_metadata[upos]
    if ustride == 1 # vload
        if U == 1
            push!(q.args, Expr(:(=), var, Expr(:call,:vload,ptr,memoff)))
        else
            for u ∈ 0:U-1
                instrcall = Expr(:call,:vload, Val{W}(), ptr, u == 0 ? memoff : add_expr(memoff, W*u))
                if mask !== nothing && u == U - 1
                    push!(instrcall.args, mask)
                end
                push!(q.args, Expr(:(=), Symbol(var,:_,u), instrcall))
            end
        end
    else
        # ustep = ustride > 1 ? ustride : op.symbolic_metadata[upos]
        ustrides = Expr(:tuple, (ustride > 1 ? [Core.VecElement{Int}(ustride*w) for w ∈ 0:W-1] : [:(Core.VecElement{Int}($(op.symbolic_metadata[upos])*$w)) for w ∈ 0:W-1])...)
        if U == 1 # we gather, no tile, no extra unroll
            instrcall = Expr(:call,:gather,ptr,Expr(:call,:vadd,memoff,ustrides))
            if mask !== nothing && u == U - 1
                push!(instrcall.args, mask)
            end
            push!(q.args, Expr(:(=), var, instrcall))
        else # we gather, no tile, but extra unroll
            for u ∈ 0:U-1
                memoff2 = if u == 0
                    memoff
                elseif ustride > 1
                    add_expr(memoff, u*W*ustride)
                else
                    add_expr(memoff, Expr(:call,:*,op.symbolic_metadata[upos],u*W) )
                end
                instrcall = Expr(:call, :gather, ptr, Expr(:call,:vadd,memoff2,ustrides))
                if mask !== nothing && u == U - 1
                    push!(instrcall.args, mask)
                end
                push!(q.args, Expr(:(=), Symbol(var,:_,u), instrcall))
            end
        end
    end
    nothing
end

# TODO: this code should be rewritten to be more "orthogonal", so that we're just combining separate pieces.
# Using sentinel values (eg, T = -1 for non tiling) in part to avoid recompilation.
function lower_load!(
    q::Expr, op::Operation, W::Int, unrolled::Symbol, U::Int,
    suffix::Union{Nothing,Int}, mask::Union{Nothing,Symbol,Unsigned} = nothing
)
    if unrolled ∈ loopdependencies(op)
        lower_load_unrolled!(q, op, W, unrolled, U, suffix, mask)
    else
        lower_load_scalar!(q, op, W, unrolled, U, suffix, mask)
    end
end

function lower_store_scalar!(
    q::Expr, op::Operation, W::Int, unrolled::Symbol, U::Int,
    suffix::Union{Nothing,Int}, mask::Union{Nothing,Symbol,Unsigned} = nothing
)
    loopdeps = loopdependencies(op)
    @assert unrolled ∉ loopdeps
    var = first(parents(op)).variable
    if suffix !== nothing
        var = Symbol(var, :_, suffix)
    end
    ptr = Symbol(:vptr_, op.variable)
    # need to find out reduction type
    reduct = CORRESPONDING_REDUCTION[first(parents(op)).instruction]
    storevar = Expr(:call, reduct, var)
    push!(q.args, Expr(:call, :store!, ptr, storevar, mem_offset(op)))
    nothing
end
function lower_store_unrolled!(
    q::Expr, op::Operation, W::Int, unrolled::Symbol, U::Int,
    suffix::Union{Nothing,Int}, mask::Union{Nothing,Symbol,Unsigned} = nothing
)
    loopdeps = loopdependencies(op)
    @assert unrolled ∈ loopdeps
    var = first(parents(op)).variable
    if suffix !== nothing
        var = Symbol(var, :_, suffix)
    end
    ptr = Symbol(:vptr_, op.variable)
    memoff = mem_offset(op)
    upos = symposition(op, unrolled)
    ustride = op.numerical_metadata[upos]
    if ustride == 1 # vload
        if U == 1
            push!(q.args, Expr(:(=), var, Expr(:call,:vload,ptr,memoff)))
        else
            for u ∈ 0:U-1
                instrcall = Expr(:call,:vstore!, ptr, Symbol(var,:_,u), u == 0 ? memoff : add_expr(memoff, incr))
                if mask !== nothing && u == U - 1
                    push!(instrcall.args, mask)
                end
                push!(q.args, instrcall)
            end
        end
    else
        # ustep = ustride > 1 ? ustride : op.symbolic_metadata[upos]
        ustrides = Expr(:tuple, (ustride > 1 ? [Core.VecElement{Int}(ustride*w) for w ∈ 0:W-1] : [:(Core.VecElement{Int}($(op.symbolic_metadata[upos])*$w)) for w ∈ 0:W-1])...)
        if U == 1 # we gather, no tile, no extra unroll
            instrcall = Expr(:call,:scatter!,ptr, var, Expr(:call,:vadd,memoff,ustrides))
            if mask !== nothing && u == U - 1
                push!(instrcall.args, mask)
            end
            push!(q.args, instrcall)
        else # we gather, no tile, but extra unroll
            for u ∈ 0:U-1
                memoff2 = if u == 0 # no increment
                    memoff
                elseif ustride > 1 # integer increment
                    add_expr(memoff, u*W*ustride)
                else # expr increment
                    add_expr(memoff, Expr(:call,:*,op.symbolic_metadata[upos],u*W) )
                end
                instrcall = Expr(:call, :scatter!, ptr, Symbol(var,:_,u), Expr(:call,:vadd,memoff2,ustrides))
                if mask !== nothing && u == U - 1
                    push!(instrcall.args, mask)
                end
                push!(q.args, instrcall)
            end
        end
    end
    nothing
end
function lower_store!(
    q::Expr, op::Operation, W::Int, unrolled::Symbol, U::Int,
    suffix::Union{Nothing,Int}, mask::Union{Nothing,Symbol,Unsigned} = nothing
)
    if unrolled ∈ loopdependencies(op)
        lower_store_unrolled!(q, op, W, unrolled, U, suffix, mask)
    else
        lower_store_scalar!(q, op, W, unrolled, U, suffix, mask)
    end
end
# A compute op needs to know the unrolling and tiling status of each of its parents.
#
function lower_compute_scalar!(
    q::Expr, op::Operation, W::Int, unrolled::Symbol, U::Int,
    suffix::Union{Nothing,Int}, mask::Union{Nothing,Symbol,Unsigned} = nothing
)
    lower_compute!(q, op, W, unrolled, U, suffix, mask, false)
end
function lower_compute_unrolled!(
    q::Expr, op::Operation, W::Int, unrolled::Symbol, U::Int,
    suffix::Union{Nothing,Int}, mask::Union{Nothing,Symbol,Unsigned} = nothing
)
    lower_compute!(q, op, W, unrolled, U, suffix, mask, true)
end
function lower_compute!(
    q::Expr, op::Operation, W::Int, unrolled::Symbol, U::Int,
    suffix::Union{Nothing,Int}, mask::Union{Nothing,Symbol,Unsigned} = nothing,
    opunrolled = unrolled ∈ loopdependencies(op)
)

    var = op.variable
    if suffix === nothing
        optiled = false
    else
        var = Symbol(var, :_, suffix)
        optiled = true
    end
    instr = op.instruction
    
    # cache unroll and tiling check of parents
    # not broadcasted, because we use frequent checks of individual bools
    # making BitArrays inefficient.
    parents_op = parents(op)
    nparents = length(parents_op)
    parentsunrolled = opunrolled ? [unrolled ∈ loopdependencies(opp) for opp ∈ parents_op] : fill(false, nparents)
    parentstiled = optiled ? [tiled ∈ loopdependencies(opp) for opp ∈ parents_op] : fill(false, nparents)
    # parentsyms = [opp.variable for opp ∈ parents(op)]
    Uiter = opunrolled ? U - 1 : 0
    maskreduct = mask !== nothing && any(opp -> opp.variable === var, parents_op)
    # if a parent is not unrolled, the compiler should handle broadcasting CSE.
    # because unrolled/tiled parents result in an unrolled/tiled dependendency,
    # we handle both the tiled and untiled case here.
    # bajillion branches that go the same way on each iteration
    # but smaller function is probably worthwhile. Compiler could theoreically split anyway
    # but I suspect that the branches are so cheap compared to the cost of everything else going on
    # that smaller size is more advantageous.
    for u ∈ 0:Uiter
        intrcall = Expr(:call, instr)
        for n ∈ 1:nparents
            parent = parents_op.variable
            if parentsunrolled[n]
                parent = Symbol(parent,:_,u)
            end
            if parentstiled[n]
                parent = Symbol(parent,:_,t)
            end
            push!(intrcall.args, parent)
        end
        varsym = var
        if optiled
            varsym = Symbol(varsym,:_,suffix)
        end
        if opunrolled
            varsym = Symbol(varsym,:_,u)
        end
        if maskreduct && u == Uiter # only mask last
            push!(q.args, Expr(:(=), varsym, Expr(:call, :vifelse, mask, varsym, instrcall)))
        else
            push!(q.args, Expr(:(=), varsym, instrcall))
        end
    end
end
function lower!(
    q::Expr, op::Operation, W::Int, unrolled::Symbol, U::Int,
    suffix::Union{Nothing,Int}, mask::Union{Nothing,Symbol,Unsigned} = nothing
)
    if isload(op)
        lower_load!(q, op, W, unrolled, U, T, tiled, mask)
    elseif isstore(op)
        lower_store!(q, op, W, unrolled, U, T, tiled, mask)
    else
        lower_compute!(q, op, W, unrolled, U, T, tiled, mask)
    end
end
function lower!(
    q::Expr, ops::AbstractVector{Operation}, W::Int, unrolled::Symbol, U::Int,
    suffix::Union{Nothing,Int}, mask::Union{Nothing,Symbol,Unsigned} = nothing
)
    foreach(op -> lower!(q, op, W, unrolled, U, suffix, mask), ops)
end
function lower_load!(
    q::Expr, ops::AbstractVector{Operation}, W::Int, unrolled::Symbol, U::Int,
    suffix::Union{Nothing,Int}, mask::Union{Nothing,Symbol,Unsigned} = nothing
)
    foreach(op -> lower_load!(q, op, W, unrolled, U, suffix, mask), ops)
end
function lower_compute!(
    q::Expr, ops::AbstractVector{Operation}, W::Int, unrolled::Symbol, U::Int,
    suffix::Union{Nothing,Int}, mask::Union{Nothing,Symbol,Unsigned} = nothing
)
    foreach(op -> lower_compute!(q, op, W, unrolled, U, suffix, mask), ops)
end
function lower_store!(
    q::Expr, ops::AbstractVector{Operation}, W::Int, unrolled::Symbol, U::Int,
    suffix::Union{Nothing,Int}, mask::Union{Nothing,Symbol,Unsigned} = nothing
)
    foreach(op -> lower_store!(q, op, W, unrolled, U, suffix, mask), ops)
end
function lower!(
    q::Expr, ops::AbstractVector{<:AbstractVector{Operation}}, W::Int, unrolled::Symbol, U::Int,
    suffix::Union{Nothing,Int}, mask::Union{Nothing,Symbol,Unsigned} = nothing
)
    @assert length(ops) == 3
    @inbounds begin
        foreach(op -> lower_load!(q, op, W, unrolled, U, suffix, mask), ops[1])
        foreach(op -> lower_compute!(q, op, W, unrolled, U, suffix, mask), ops[2])
        foreach(op -> lower_store!(q, op, W, unrolled, U, suffix, mask), ops[3])
    end
end

tiledsym(s::Symbol) = Symbol("##outer##", s, "##outer##")
function lower_nest(
    ls::LoopSet, n::Int, U::Int, T::Int, loopq_old::Union{Expr,Nothing},
    loopstart::Union{Int,Symbol}, W::Int,
    mask::Union{Nothing,Symbol,Unsigned} = nothing, exprtype::Symbol = :while
)
    lo = ls.loop_order
    ops = lo.oporder
    order = lo.loopnames
    istiled = T != -1
    loopsym = order[n]
    nloops = num_loops(ls)
    if istiled
        if n == nloops
            loopsym = tiledsym(loopsym)
        end
        unrolled = order[2]
        loopincr = if n == nloops - 1
            U*W
        elseif n == nloops
            T
        else
            1
        end        
    else
        unrolled = first(order)
        loopincr = n == nloops ? U*W : 1
    end
    blockq = if n == 1
        Expr(:block, )
    else
        Expr(:block, Expr(:(=), order[n-1], loopstart))
    end
    loopq = if exprtype === :block
        blockq
    else
        @assert exprtype === :while || exprtype === :if
        Expr(exprtype, looprange(ls, loopsym, loopincr), blockq)
    end
    for prepost ∈ 1:2
        # !U && !T
        lower!(blockq, @view(ops[:,1,1,prepost,n]), W, unrolled, U, nothing, mask)
        for u ∈ 0:U-1     #  U && !T
            lower!(blockq, @view(ops[:,2,1,prepost,n]), W, unrolled, U, nothing, mask)
        end
        if sum(length, @view(ops[:,:,2,prepost,n])) > 0
            for t ∈ 0:T-1   # !U &&  T
                if t == 0
                    push!(blockq.args, Expr(:(=), first(order), tiledsym(first(order))))
                else
                    push!(blockq.args, Expr(:+=, first(order), 1))
                end
                lower!(blockq, @view(ops[:,1,2,prepost,n]), W, unrolled, U, t, mask)
                for u ∈ 0:U-1 #  U &&  T
                    lower!(blockq, @view(ops[:,2,2,prepost,n]), W, unrolled, U, t, mask)
                end
            end
        end
        if loopq_old !== nothing && n > 1 && prepost == 1
            push!(blockq.args, loopq_old)
        end
    end
    push!(blockq.args, Expr(:+=, loopsym, loopincr))
    loopq
end

# Calculates nested loop set,
# if tiled, it will not lower the tiled iteration.
function lower_set(ls::LoopSet, U::Int, T::Int, W::Int, mask, Uexprtype::Symbol)
    loopq = lower_nest(ls, 1, U, T, nothing, 0, W, mask, :while)
    nl = num_loops(ls) - (T != -1)
    for n ∈ 2:nl
        exprtype = n == nl ? Uexprtype : :while
        loopq = lower_nest(ls, n, U, T, loopq, 0, W, mask, exprtype)
    end
    loopq
end
function lower_unrolled!(
    q::Expr, ls::LoopSet, U::Int, T::Int, W::Int,
    static_unroll::Bool, unrolled_iter::Int, unrolled_itersym::Symbol
)
    if static_unroll
        Urem = unrolled_iter
        # if static, we use Urem to indicate remainder.
        if unrolled_iter ≥ 2U*W # we need at least 2 iterations
            Uexprtype = :while
        elseif unrolled_iter ≥ U*W # complete unroll
            Uexprtype = :block
        else# we have only a single block
            Uexprtype = :skip
        end
    else
        Urem = 0
        Uexprtype = :while
    end
    Wt = W
    Ut = U
    Urem = 0
    Urepeat = true
    while Urepeat
        if Uexprtype !== :skip
            loopq = if Urem == 0 # dynamic
                if Ut == 0 # remainder iter
                    lower_set(ls, Ut, T, Wt, Symbol("##mask##"), Uexprtype)
                else
                    lower_set(ls, 1, T, Wt, nothing, Uexprtype)
                end
            elseif Urem == unrolled_iter || Urem == -1 # static, no mask
                lower_set(ls, Ut, T, Wt, nothing, Uexprtype)
            else # static, need mask
                lower_set(ls, Ut, T, Wt, VectorizationBase.unstable_mask(Wt, Urem), Uexprtype)
            end
            push!(q.args, loopq)
        end
        if static_unroll
            if Urem == unrolled_iter
                remUiter = unrolled_iter % (U*W)
                if remUiter == 0 # no remainder, we're done with the unroll
                    Urepeat = false
                else # remainder, requires another iteration; what size?
                    Ut, Urem = divrem(remUiter, W)
                    if Urem == 0 # Ut iters of W
                        Urem = -1 
                    else
                        if Ut == 0 # if Urem == unrolled_iter, we may already be done, othererwise, we may be able to shrink Wt
                            if Urem == unrolled_iter && Uexprtype !== :skip
                                Urepeat = false
                            else
                                Wt = VectorizationBase.nextpow2(Urem)
                                if Wt == Urem # no mask needed
                                    Urem = -1
                                end
                            end
                        end
                        # because initial Urem > 0 (it either still is, or we shrunk Wt and made it a complete iter)
                        # we must increment Ut (to perform masked or shrunk complete iter)
                        Ut += 1
                    end
                    Uexprtype = :block
                end
            else
                Urepeat = false
            end
        elseif Ut == 0 # dynamic, terminate because we completed the masked iteration
            Urepeat = false
        else # dynamic
            oldUt = Ut
            Ut >>>= 1
            if Ut == 0
                Uexprtype = :if
                # W == Wt when !static_unroll
                push!(q.args, Expr(:(=), Symbol("##mask##"), VectorizationBase.mask(Val{$W}(), $unrolled_itersym & $(W-1))))
            elseif 2Ut == oldUt
                Uexprtype = :if
            else
                Uexprtype = :while
            end
        end
    end
    q
end
function lower_tiled(ls::LoopSet, U::Int, T::Int)
    order = ls.loop_order.loopnames
    tiled    = order[1]
    unrolled = order[2]
    mangledtiled = tiledsym(tiled)
    W = VectorizationBase.pick_vector_width(ls, unrolled)
    static_tile = isstaticloop(ls, tiled)
    static_unroll = isstaticloop(ls, unrolled)
    unrolled_iter = looprangehint(ls, unrolled)
    unrolled_itersym = looprangesym(ls, unrolled)
    q = Expr(:block, Expr(:(=), mangledtiled, 0))
    # we build up the loop expression.
    Trem = Tt = T
    Texprtype = (static_tile && tiled_iter < 2T) ? :block : :while
    while Tt > 0
        tiledloopbody = Expr(:block, Expr(:(=), unrolled, 0))
        push!(q.args, Texprtype === :block ? tiledloopbody : Expr(Texprtype, looprange(ls, tiled, Tt), tiledloopbody))
        lower_unrolled!(tiledloopbody, ls, U, Tt, W, static_unroll, unrolled_iter, unrolled_itersym)
        if static_tile
            Tt = if Tt == T
                push!(tiledloopbody.args, Expr(:+=, mangledtiled, Tt))
                Texprtype = :block
                looprangehint(ls, tiled) % T
            else
                0 # terminate
            end
            nothing
        else
            Ttold = Tt
            Tt >>>= 1
            Tt == 0 || push!(tiledloopbody.args, Expr(:+=, mangledtiled, Ttold))
            Texprtype = 2Tt == Ttold ? :if : :while
            nothing
        end
    end
    q
end
function lower_unrolled(ls::LoopSet, U::Int)
    order = ls.loop_order.loopnames
    unrolled = first(order)
    W = VectorizationBase.pick_vector_width(ls, unrolled)
    static_unroll = isstaticloop(ls, unrolled)
    unrolled_iter = looprangehint(ls, unrolled)
    unrolled_itersym = looprangesym(ls, unrolled)
    lower_unrolled!(Expr(:block,), ls, U, -1, W, static_unroll, unrolled_iter, unrolled_itersym)
end


# Here, we have to figure out how to convert the loopset into a vectorized expression.
# This must traverse in a parent -> child pattern
# but order is also dependent on which loop inds they depend on.
# Requires sorting 
function lower(ls::LoopSet)
    order, U, T = choose_order(ls)
    istiled = T == -1
    fillorder!(ls, order, istiled)
    if T == -1
        lower_unrolled(ls, U)
    else
        lower_tiled(ls, U, T)
    end
end

Base.convert(::Type{Expr}, ls::LoopSet) = lower(ls)
