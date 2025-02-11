
#   This file is part of Grassmann.jl. It is licensed under the AGPL license
#   Grassmann Copyright (C) 2019 Michael Reed

@pure tvec(N,G,t=Any) = :(Values{$(binomial(N,G)),$t})
@pure tvec(N,t::Type=Any) = :(Values{$(1<<N),$t})
@pure tvec(N,t::Symbol) = :(Values{$(1<<N),$t})
@pure tvec(N,μ::Bool) = tvec(N,μ ? :Any : :t)

# mutating operations

@pure derive(n::N,b) where N<:Number = zero(typeof(n))
derive(n,b,a,t) = t ? (a,derive(n,b)) : (derive(n,b),a)
#derive(n,b,a::T,t) where T<:TensorAlgebra = t ? (a,derive(n,b)) : (derive(n,b),a)

@inline @generated function derive_mul(V,A,B,v,x::Bool)
    if !(istangent(V) && isdyadic(V))
        return :v
    else quote
        sa,sb = symmetricsplit(V,A),symmetricsplit(V,B)
        ca,cb = count_ones(@inbounds sa[2]),count_ones(@inbounds sb[2])
        return if (ca == cb == 0) || ((ca ≠ 0) && (cb ≠ 0))
            v
        else
            prev = ca == 0 ? (x ? one(typeof(v)) : v) : (x ? v : one(typeof(v)))
            for k ∈ Leibniz.indexsplit(@inbounds (ca==0 ? sa : sb)[1],mdims(V))
                prev = derive(prev,getbasis(V,k))
            end
            prev
        end
    end end
end

@inline @generated function derive_mul(V,A,B,a,b,*)
    if !(istangent(V) && isdyadic(V))
        return :(a*b)
    else quote
        sa,sb = symmetricsplit(V,A),symmetricsplit(V,B)
        ca,cb = count_ones(@inbounds sa[2]),count_ones(@inbounds sb[2])
        α,β = if (ca == cb == 0) || ((ca ≠ 0) && (cb ≠ 0))
            a,b
        else
            prev = ca == 0 ? (a,b) : (b,a)
            for k ∈ Leibniz.indexsplit(@inbounds (ca==0 ? sa : sb)[1],mdims(V))
                prev = @inbounds derive(prev[2],getbasis(V,k),prev[1],true)
            end
            #base = getbasis(V,0)
            while typeof(@inbounds prev[1]) <: TensorTerm
                basi = @inbounds basis(prev[1])
                #base *= basi
                inds = Leibniz.indexsplit(UInt(basi),mdims(V))
                prev = @inbounds (value(prev[1]),prev[2])
                for k ∈ inds
                    prev = @inbounds derive(prev[2],getbasis(V,k),prev[1],true)
                end
            end
            #base ≠ getbasis(V,0) && (prev = (base*prev[1],prev[2]))
            ca == 0 ? prev : (@inbounds prev[2],@inbounds prev[1])
        end
        return α*β
    end end
end

function derive_pre(V,A,B,v,x)
    if !(istangent(V) && isdyadic(V))
        return v
    else
        return :(derive_post($V,$(Val{A}()),$(Val{B}()),$v,$x))
    end
end

function derive_pre(V,A,B,a,b,p)
    if !(istangent(V) && isdyadic(V))
        return Expr(:call,p,a,b)
    else
        return :(derive_post($V,$(Val{A}()),$(Val{B}()),$a,$b,$p))
    end
end

function derive_post(V,::Val{A},::Val{B},v,x::Bool) where {A,B}
    sa,sb = symmetricsplit(V,A),symmetricsplit(V,B)
    ca,cb = count_ones(@inbounds sa[2]),count_ones(@inbounds sb[2])
    return if (ca == cb == 0) || ((ca ≠ 0) && (cb ≠ 0))
        v
    else
        prev = ca == 0 ? (x ? one(typeof(v)) : v) : (x ? v : one(typeof(v)))
        for k ∈ Leibniz.indexsplit(@inbounds (ca==0 ? sa : sb)[1],mdims(V))
            prev = derive(prev,getbasis(V,k))
        end
        prev
    end
end

function derive_post(V,::Val{A},::Val{B},a,b,*) where {A,B}
    sa,sb = symmetricsplit(V,A),symmetricsplit(V,B)
    ca,cb = count_ones(@inbounds sa[2]),count_ones(@inbounds sb[2])
    α,β = if (ca == cb == 0) || ((ca ≠ 0) && (cb ≠ 0))
        a,b
    else
        prev = ca == 0 ? (a,b) : (b,a)
        for k ∈ Leibniz.indexsplit(@inbounds (ca==0 ? sa : sb)[1],mdims(V))
            prev = @inbounds derive(prev[2],getbasis(V,k),prev[1],true)
        end
        #base = getbasis(V,0)
        while typeof(@inbounds prev[1]) <: TensorTerm
            basi = @inbounds basis(prev[1])
            #base *= basi
            inds = Leibniz.indexsplit(UInt(basi),mdims(V))
            prev = @inbounds (value(prev[1]),prev[2])
            for k ∈ inds
                prev = @inbounds derive(prev[2],getbasis(V,k),prev[1],true)
            end
        end
        #base ≠ getbasis(V,0) && (prev = (base*prev[1],prev[2]))
        ca == 0 ? prev : (@inbounds prev[2],@inbounds prev[1])
    end
    return α*β
end

bcast(op,arg) = op ∈ (:(AbstractTensors.:∑),:(AbstractTensors.:-)) ? Expr(:.,op,arg) : Expr(:call,op,arg.args...)

set_val(set,expr,val) = Expr(:(=),expr,set≠:(=) ? Expr(:call,:($Sym.:∑),expr,val) : val)

pre_val(set,expr,val) = set≠:(=) ? :(isnull($expr) ? ($expr=Expr(:call,:($Sym.:∑),$val)) : push!($expr.args,$val)) : Expr(:(=),expr,val)

add_val(set,expr,val,OP) = Expr(OP∉(:-,:+) ? :.= : set,expr,OP∉(:-,:+) ? Expr(:.,OP,Expr(:tuple,expr,val)) : val)

function generate_mutators(M,F,set_val,SUB,MUL,i,B)
    for (op,set) ∈ ((:add,:(+=)),(:set,:(=)))
        sm = Symbol(op,:multi!)
        sb = Symbol(op,:blade!)
        for (s,index) ∈ ((sm,:basisindex),(sb,:bladeindex))
            spre = Symbol(s,:_pre)
            @eval begin
                @inline function $s(out::$M,val::S,i::$B) where {M,T<:$F,S<:$F}
                    @inbounds $(set_val(set,:(out[$index(intlog(M),$i)]),:val))
                    return out
                end
                @inline function $s(out::Q,val::S,i::$B,::Val{N}) where Q<:$M where {M,T<:$F,S<:$F,N}
                    @inbounds $(set_val(set,:(out[$index(N,$i)]),:val))
                    return out
                end
                @inline function $spre(out::$M,val::S,i::$B) where {M,T<:$F,S<:$F}
                    ind = $index(intlog(M),$i)
                    @inbounds $(pre_val(set,:(out[ind]),:val))
                    return out
                end
                @inline function $spre(out::Q,val::S,i::$B,::Val{N}) where Q<:$M where {M,T<:$F,S<:$F,N}
                    ind = $index(N,$i)
                    @inbounds $(pre_val(set,:(out[ind]),:val))
                    return out
                end
            end
        end
    end
end

function generate_mutators(M,F,set_val,SUB,MUL)
    generate_mutators(M,F,set_val,SUB,MUL,:i,UInt)
    generate_mutators(M,F,set_val,SUB,MUL,:(UInt(i)),Submanifold)
    for (op,set) ∈ ((:add,:(+=)),(:set,:(=)))
        sm = Symbol(op,:multi!)
        sb = Symbol(op,:blade!)
        for s ∈ (sm,sb)
            @eval @inline function $s(out::$M,val::S,i) where {M,T,S}
                @inbounds $(set_val(set,:(out[i]),:val))
                return out
            end
            spre = Symbol(s,:_pre)
            for j ∈ (:join,:geom)
                for S ∈ (s,spre)
                    @eval @inline function $(Symbol(j,S))(m::$M,v::S,A::Submanifold{V},B::Submanifold{V}) where {V,T<:$F,S<:$F,M}
                        $(Symbol(j,S))(V,m,UInt(A),UInt(B),v)
                    end
                end
            end
            @eval begin
                @inline function $(Symbol(:join,s))(V,m::$M,a::UInt,b::UInt,v::S) where {T<:$F,S<:$F,M}
                    if v ≠ 0 && !diffcheck(V,a,b)
                        A,B,Q,Z = symmetricmask(V,a,b)
                        val = $MUL(parityinner(V,A,B),v)
                        if diffvars(V)≠0
                            !iszero(Z) && (T≠Any ? (return true) : (val *= getbasis(loworder(V),Z)))
                            count_ones(Q)+order(val)>diffmode(V) && (return false)
                        end
                        $s(m,val,(A⊻B)|Q,Val(mdims(V)))
                    end
                    return false
                end
                @inline function $(Symbol(:join,spre))(V,m::$M,a::UInt,b::UInt,v::S) where {T<:$F,S<:$F,M}
                    if v ≠ 0 && !diffcheck(V,a,b)
                        A,B,Q,Z = symmetricmask(V,a,b)
                        val = :($$MUL($(parityinner(V,A,B)),$v))
                        if diffvars(V)≠0
                            !iszero(Z) && (val = Expr(:call,:*,val,getbasis(loworder(V),Z)))
                            val = :(h=$val;iszero(h)||$(count_ones(Q))+order(h)>$(diffmode(V)) ? 0 : h)
                        end
                        $spre(m,val,(A⊻B)|Q,Val(mdims(V)))
                    end
                    return false
                end
                @inline function $(Symbol(:geom,s))(V,m::$M,a::UInt,b::UInt,v::S) where {T<:$F,S<:$F,M}
                    if v ≠ 0 && !diffcheck(V,a,b)
                        A,B,Q,Z = symmetricmask(V,a,b)
                        pcc,bas,cc = (hasinf(V) && hasorigin(V)) ? conformal(V,A,B) : (false,A⊻B,false)
                        val = $MUL(parityinner(V,A,B),pcc ? $SUB(v) : v)
                        if istangent(V)
                            !iszero(Z) && (T≠Any ? (return true) : (val *= getbasis(loworder(V),Z)))
                            count_ones(Q)+order(val)>diffmode(V) && (return false)
                        end
                        $s(m,val,bas|Q,Val(mdims(V)))
                        cc && $s(m,hasinforigin(V,A,B) ? $SUB(val) : val,(conformalmask(V)⊻bas)|Q,Val(mdims(V)))
                    end
                    return false
                end
                @inline function $(Symbol(:geom,spre))(V,m::$M,a::UInt,b::UInt,v::S) where {T<:$F,S<:$F,M}
                    if v ≠ 0 && !diffcheck(V,a,b)
                        A,B,Q,Z = symmetricmask(V,a,b)
                        pcc,bas,cc = (hasinf(V) && hasorigin(V)) ? conformal(V,A,B) : (false,A⊻B,false)
                        val = :($$MUL($(parityinner(V,A,B)),$(pcc ? :($$SUB($v)) : v)))
                        if istangent(V)
                            !iszero(Z) && (val = Expr(:call,:*,val,getbasis(loworder(V),Z)))
                            val = :(h=$val;iszero(h)||$(count_ones(Q))+order(h)>$(diffmode(V)) ? 0 : h)
                        end
                        $spre(m,val,bas|Q,Val(mdims(V)))
                        cc && $spre(m,hasinforigin(V,A,B) ? :($$SUB($val)) : val,(conformalmask(V)⊻bas)|Q,Val(mdims(V)))
                    end
                    return false
                end
            end
            for (prod,uct) ∈ ((:meet,:regressive),(:skew,:interior))
                for S ∈ (s,spre)
                    @eval @inline function $(Symbol(prod,S))(m::$M,A::Submanifold{V},B::Submanifold{V},v::T) where {V,T,M}
                        $(Symbol(prod,S))(V,m,UInt(A),UInt(B),v)
                    end
                end
                @eval begin
                    @inline function $(Symbol(prod,s))(V,m::$M,A::UInt,B::UInt,val::T) where {T,M}
                        if val ≠ 0
                            g,C,t,Z = $uct(V,A,B)
                            v = val
                            if istangent(V) && !iszero(Z)
                                T≠Any && (return true)
                                _,_,Q,_ = symmetricmask(V,A,B)
                                v *= getbasis(loworder(V),Z)
                                count_ones(Q)+order(v)>diffmode(V) && (return false)
                            end
                            t && $s(m,$MUL(g,v),C,Val(mdims(V)))
                        end
                        return false
                    end
                    @inline function $(Symbol(prod,spre))(V,m::$M,A::UInt,B::UInt,val::T) where {T,M}
                        if val ≠ 0
                            g,C,t,Z = $uct(V,A,B)
                            v = val
                            if istangent(V) && !iszero(Z)
                                _,_,Q,_ = symmetricmask(V,A,B)
                                v = Expr(:call,:*,v,getbasis(loworder(V),Z))
                                v = :(h=$v;iszero(h)||$(count_ones(Q))+order(h)>$(diffmode(V)) ? 0 : h)
                            end
                            t && $spre(m,Expr(:call,$(QuoteNode(MUL)),g,v),C,Val(mdims(V)))
                        end
                        return false
                    end
                end
            end
        end
    end
end

@inline exterbits(V,α,β) = diffvars(V)≠0 ? ((a,b)=symmetricmask(V,α,β);count_ones(a&b)==0) : count_ones(α&β)==0
@inline exteraddmulti!(V,out,α,β,γ) = exterbits(V,α,β) && joinaddmulti!(V,out,α,β,γ)
@inline exteraddblade!(V,out,α,β,γ) = exterbits(V,α,β) && joinaddblade!(V,out,α,β,γ)
@inline exteraddmulti!_pre(V,out,α,β,γ) = exterbits(V,α,β) && joinaddmulti!_pre(V,out,α,β,γ)
@inline exteraddblade!_pre(V,out,α,β,γ) = exterbits(V,α,β) && joinaddblade!_pre(V,out,α,β,γ)

# algebra

const FieldsBig = (Fields...,BigFloat,BigInt,Complex{BigFloat},Complex{BigInt},Rational{BigInt})

*(a::UniformScaling,b::Simplex{V}) where V = V(a)*b
*(a::Simplex{V},b::UniformScaling) where V = a*V(b)
*(a::UniformScaling,b::Chain{V}) where V = V(a)*b
*(a::Chain{V},b::UniformScaling) where V = a*V(b)

+(a::Zero{V},::Zero{V}) where V = a
-(a::Zero{V},::Zero{V}) where V = a
*(a::Zero{V},::Zero{V}) where V = a
∧(a::Zero{V},::Zero{V}) where V = a
∨(a::Zero{V},::Zero{V}) where V = a
contraction(a::Zero{V},::Zero{V}) where V = a

+(a::T,b::Zero) where T<:TensorAlgebra{V} where V = a
+(a::Zero,b::T) where T<:TensorAlgebra{V} where V = b
-(a::T,b::Zero) where T<:TensorAlgebra{V} where V = a
-(a::Zero,b::T) where T<:TensorAlgebra{V} where V = -b
*(a::T,b::Zero) where T<:TensorAlgebra{V} where V = b
*(a::Zero,b::T) where T<:TensorAlgebra{V} where V = a
/(a::Zero,b::T) where T<:Number = iszero(b) ? Simplex{V}(0/0) : a
/(a::Zero,b::T) where T<:TensorAlgebra{V} where V = iszero(b) ? Simplex{V}(0/0) : Zero(V)
/(a::Zero,b::T) where T<:SimplexComplex{V} where V = iszero(b) ? Simplex{V}(0/0) : Zero(V)
/(a::Zero{V},b::Zero) where V = Simplex{V}(0/0)
inv(a::Zero{V}) where V = Simplex{V}(inv(value(a)))
∧(a::T,b::Zero) where T<:TensorAlgebra{V} where V = b
∧(a::Zero,b::T) where T<:TensorAlgebra{V} where V = a
∨(a::T,b::Zero) where T<:TensorAlgebra{V} where V = b
∨(a::Zero,b::T) where T<:TensorAlgebra{V} where V = a
contraction(a::T,b::Zero) where T<:TensorAlgebra{V} where V = b
contraction(a::Zero,b::T) where T<:TensorAlgebra{V} where V = a

+(a::T,b::Zero{V}) where {T<:Number,V} = Simplex{V}(a)
+(a::Zero{V},b::T) where {T<:Number,V} = Simplex{V}(b)
-(a::T,b::Zero{V}) where {T<:Number,V} = Simplex{V}(a)
-(a::Zero{V},b::T) where {T<:Number,V} = Simplex{V}(-b)
*(a::T,b::Zero) where T<:Number = b
*(a::Zero,b::T) where T<:Number = a

@inline Base.:^(a::T,b::Zero) where T<:TensorAlgebra{V} where V = One(V)
@inline Base.:^(a::Zero,b::T) where T<:TensorAlgebra{V} where V = Zero(V)
@inline Base.:^(a::T,b::Zero{V}) where {T<:Number,V} = One(V)
@inline Base.:^(a::Zero{V},b::T) where {T<:Number,V} = Zero(V)
@inline Base.:^(a::Zero{V},::Zero) where V = One(V)
@inline Base.:^(a::Zero,::T) where T<:Integer = a

plus(b::Chain{V,G},a::Submanifold{V,G}) where {V,G} = plus(a,b)
plus(b::Chain{V,G},a::Submanifold{V,L}) where {V,G,L} = plus(a,b)
plus(b::Chain{V,G},a::Simplex{V,G}) where {V,G} = plus(a,b)
plus(b::Chain{V,G},a::Simplex{V,L}) where {V,G,L} = plus(a,b)
plus(b::Multivector{V},a::Submanifold{V,G}) where {V,G} = plus(a,b)
plus(b::Multivector{V},a::Simplex{V,G}) where {V,G} = plus(a,b)
-(t::Submanifold) = Simplex(-value(t),t)
-(a::Chain{V,G}) where {V,G} = Chain{V,G}(-value(a))
-(a::Multivector{V}) where V = Multivector{V}(-value(a))
-(a::SimplexComplex{V,B}) where {V,B} = SimplexComplex{V,B}(-a.v)
times(a::Simplex{V,0},b::Chain{V,G}) where {V,G} = Chain{V,G}(a.v*b.v)
times(a::Chain{V,G},b::Simplex{V,0}) where {V,G} = Chain{V,G}(a.v*b.v)
times(a::Submanifold{V,0},b::Chain{W,G}) where {V,W,G} = b
times(a::Chain{V,G},b::Submanifold{W,0}) where {V,W,G} = a

plus(a::Multivector{V},b::SimplexComplex{V}) where V = (a+scalar(b))+imaginary(b)
plus(a::SimplexComplex{V},b::Multivector{V}) where V = (b+scalar(a))+imaginary(a)
minus(a::Multivector{V},b::SimplexComplex{V}) where V = (a-scalar(b))-imaginary(b)
minus(a::SimplexComplex{V},b::Multivector{V}) where V = (scalar(a)-b)+imaginary(a)
plus(a::Chain{V,0},b::SimplexComplex{V}) where V = (a+scalar(b))+imaginary(b)
plus(a::SimplexComplex{V},b::Chain{V,0}) where V = (b+scalar(a))+imaginary(a)
minus(a::Chain{V,0},b::SimplexComplex{V}) where V = (a-scalar(b))-imaginary(b)
minus(a::SimplexComplex{V},b::Chain{V,0}) where V = (scalar(a)-b)+imaginary(a)
plus(a::Chain{V},b::SimplexComplex{V}) where V = (a+imaginary(b))+scalar(b)
plus(a::SimplexComplex{V},b::Chain{V}) where V = (b+imaginary(a))+scalar(a)
minus(a::Chain{V},b::SimplexComplex{V}) where V = (a-imaginary(b))-scalar(b)
minus(a::SimplexComplex{V},b::Chain{V}) where V = (imaginary(a)-b)+scalar(a)

for (op,po) ∈ ((:plus,:+),(:minus,:-))
    @eval $op(a::SimplexComplex{V,B},b::SimplexComplex{V,B}) where {V,B} = SimplexComplex{V,B}($po(a.v,b.v))
end

function times(a::SimplexComplex{V,B},b::SimplexComplex{V,B}) where {V,B}
    SimplexComplex{V,B}(Complex(a.v.re*b.v.re+(a.v.im*b.v.im)*value(B*B),a.v.re*b.v.im+a.v.im*b.v.re))
end

function ∧(a::SimplexComplex{V,B},b::SimplexComplex{V,B}) where {V,B}
    SimplexComplex{V,B}(Complex(a.v.re*b.v.re,a.v.re*b.v.im+a.v.im*b.v.re))
end

function ∨(a::SimplexComplex{V,B},b::SimplexComplex{V,B}) where {V,B}
    grade(B)==grade(V) ? SimplexComplex{V,B}(Complex(a.v.re*b.v.im+a.v.im*b.v.re,a.v.im*b.v.im)) : Zero(V)
end

function contraction(a::SimplexComplex{V,B},b::SimplexComplex{V,B}) where {V,B}
    SimplexComplex{V,B}(Complex(a.v.re*b.v.re+(a.v.im*b.v.im)*value(abs2_inv(B)),a.v.im*b.v.re))
end

for op ∈ (:plus,:minus)
    @eval $op(a::SimplexComplex{V},b::SimplexComplex{V}) where V = $op(Multivector(a),b)
end
times(a::SimplexComplex{V},b::SimplexComplex{V}) where V = Multivector(a)*Multivector(b)
∧(a::SimplexComplex{V},b::SimplexComplex{V}) where V = Multivector(a)∧b
∨(a::SimplexComplex{V},b::SimplexComplex{V}) where V = Multivector(a)∨b
contraction(a::SimplexComplex{V},b::SimplexComplex{V}) where V = contraction(Multivector(a),b)

plus(a::TensorTerm{V,0},b::SimplexComplex{V,B}) where {V,B} = SimplexComplex{V,B}(Complex(value(a)+b.v.re,b.v.im))
plus(a::SimplexComplex{V,B},b::TensorTerm{V,0}) where {V,B} = SimplexComplex{V,B}(Complex(a.v.re+value(b),a.v.im))
function plus(a::TensorTerm{V},b::SimplexComplex{V,B}) where {V,B}
    if basis(a) == B
        SimplexComplex{V,B}(Complex(b.v.re,value(a)+b.v.im))
    else
        a+Multivector(b)
    end
end
function plus(a::SimplexComplex{V,B},b::TensorTerm{V}) where {V,B}
    if B == basis(b)
        SimplexComplex{V,B}(Complex(a.v.re,a.v.im+value(b)))
    else
        Multivector(a)+b
    end
end

minus(a::TensorTerm{V,0},b::SimplexComplex{V,B}) where {V,B} = (re = value(a)-b.v.re; SimplexComplex{V,B}(Complex(re,-oftype(re,b.v.im))))
minus(a::SimplexComplex{V,B},b::TensorTerm{V,0}) where {V,B} = SimplexComplex{V,B}(Complex(a.v.re-value(b),a.v.im))
function minus(a::TensorTerm{V},b::SimplexComplex{V,B}) where {V,G,B}
    if basis(a) == B
        re = value(a)-b.v.im
        SimplexComplex{V,B}(Complex(-oftype(re,b.v.re),re))
    else
        a-Multivector(b)
    end
end
function minus(a::SimplexComplex{V,B},b::TensorTerm{V}) where {V,B}
    if B == basis(b)
        SimplexComplex{V,B}(Complex(a.v.re,a.v.im-value(b)))
    else
        Multivector(a)-b
    end
end

times(a::Multivector{V},b::SimplexComplex{V}) where V = a*Multivector(b)
#Multivector{V}(value(a)*b.v.re) + a*imaginary(b)
times(a::SimplexComplex{V},b::Multivector{V}) where V = Multivector(a)*b
#Multivector{V}(a.v.re*value(b)) + imaginary(a)*b
times(a::Chain{V},b::SimplexComplex{V}) where V = a*Multivector(b)
#Chain{V,G}(value(a)*b.v.re) + a*imaginary(b)
times(a::SimplexComplex{V},b::Chain{V}) where V = Multivector(a)*b
#Chain{V,G}(a.v.re*value(b)) + imaginary(a)*b
times(a::TensorTerm{V,0},b::SimplexComplex{V,B}) where {V,B} = SimplexComplex{V,B}(Complex(value(a)*b.v.re,value(a)*b.v.im))
times(a::SimplexComplex{V,B},b::TensorTerm{V,0}) where {V,B} = SimplexComplex{V,B}(Complex(a.v.re*value(b),a.v.im*value(b)))

function times(a::Submanifold{V,G},b::SimplexComplex{V,B}) where {V,G,B}
    if a == B
        SimplexComplex{V,B}(Complex(b.v.im*value(B*B),b.v.re))
    else
        Simplex{V,G,a}(b.v.re) + a*imaginary(b)
    end
end
function times(a::SimplexComplex{V,B},b::Submanifold{V,G}) where {V,G,B}
    if B == b
        SimplexComplex{V,B}(Complex((a.v.im)*value(B*B),a.v.re))
    else
        Simplex{V,G,b}(a.v.re) + imaginary(a)*b
    end
end
function times(a::Simplex{V,G,A},b::SimplexComplex{V,B}) where {V,G,A,B}
    if A == B
        SimplexComplex{V,B}(Complex((value(a)*b.v.im)*value(B*B),value(a)*b.v.re))
    else
        Simplex{V,G,A}(value(a)*b.v.re) + a*imaginary(b)
    end
end
function times(a::SimplexComplex{V,A},b::Simplex{V,G,B}) where {V,G,A,B}
    if A == B
        SimplexComplex{V,A}(Complex((a.v.im*value(b))*value(A*A),a.v.re*value(b)))
    else
        Simplex{V,G,B}(a.v.re*value(b)) + imaginary(a)*b
    end
end

∧(a::Multivector{V},b::SimplexComplex{V}) where V = a∧Multivector(b)
#Multivector{V}(value(a)*b.v.re) + a∧imaginary(b)
∧(a::SimplexComplex{V},b::Multivector{V}) where V = Multivector(a)∧b
#Multivector{V}(a.v.re*value(b)) + imaginary(a)∧b
∧(a::Chain{V},b::SimplexComplex{V}) where V = a∧Multivector(b)
#Chain{V,G}(value(a)*b.v.re) + a∧imaginary(b)
∧(a::SimplexComplex{V},b::Chain{V}) where V = Multivector(a)∧b
#Chain{V,G}(a.v.re*value(b)) + imaginary(a)∧b
∧(a::TensorTerm{V,0},b::SimplexComplex{V}) where V = a*b
∧(a::SimplexComplex{V},b::TensorTerm{V,0}) where V = a*b
function ∧(a::TensorTerm{V,G},b::SimplexComplex{V,B}) where {V,G,B}
    if basis(a) == B
        SimplexComplex{V,B}(Complex(0,value(a)*b.v.re))
    else
        Simplex{V,G,basis(a)}(value(a)*b.v.re) + a∧imaginary(b)
    end
end
function ∧(a::SimplexComplex{V,B},b::TensorTerm{V,G}) where {V,G,B}
    if B == basis(b)
        SimplexComplex{V,B}(Complex(0,a.v.re*value(b)))
    else
        Simplex{V,G,basis(b)}(a.v.re*value(b)) + imaginary(a)∧b
    end
end

∨(a::Multivector{V},b::SimplexComplex{V}) where V = a∨Multivector(b)
∨(a::SimplexComplex{V},b::Multivector{V}) where V = Multivector(a)∨b
∨(a::Chain{V},b::SimplexComplex{V}) where V = a∨Multivector(b)
∨(a::SimplexComplex{V},b::Chain{V}) where V = Multivector(a)∨b
∨(a::TensorTerm{V,0},b::SimplexComplex{V,B}) where {V,B} = grade(B)==grade(V) ? a*b : Zero(V)
∨(a::SimplexComplex{V,B},b::TensorTerm{V,0}) where {V,B} = grade(B)==grade(V) ? a*b : Zero(V)
function ∨(a::TensorTerm{V,G},b::SimplexComplex{V,B}) where {V,G,B}
    if basis(a) == B
        grade(B)==grade(V) ? SimplexComplex{V,B}(Complex(0,value(a)*b.v.im)) : Zero(V)
    else
        a∨imaginary(b)
    end
end
function ∨(a::SimplexComplex{V,B},b::TensorTerm{V,G}) where {V,G,B}
    if B == basis(b)
        grade(B)==grade(V) ? SimplexComplex{V,B}(Complex(0,a.v.im*value(b))) : Zero(V)
    else
        imaginary(a)∨b
    end
end

contraction(a::Multivector{V},b::SimplexComplex{V}) where V = contraction(a,Multivector(b))
#Multivector{V}(value(a)*b.v.re) + contraction(a,imaginary(b))
contraction(a::SimplexComplex{V},b::Multivector{V}) where V = contraction(Multivector(a),b)
#Multivector{V}(a.v.re*value(b)) + contraction(imaginary(a),b)
contraction(a::Chain{V},b::SimplexComplex{V}) where V = contraction(a,Multivector(b))
#Chain{V,G}(value(a)*b.v.re) + contraction(a,imaginary(b))
contraction(a::SimplexComplex{V},b::Chain{V}) where V = contraction(Multivector(a),b)
#Chain{V,G}(a.v.re*value(b)) + contraction(imaginary(a),b)
contraction(a::TensorTerm{V,0},b::SimplexComplex{V}) where V = Simplex{V}(value(a)*b.v.re)
contraction(a::SimplexComplex{V},b::TensorTerm{V,0}) where V = a*b
function contraction(a::TensorTerm{V,G},b::SimplexComplex{V,B}) where {V,G,B}
    if basis(a) == B
        SimplexComplex{V,B}(Complex((conj(value(a))*b.v.im)*value(abs2_inv(B)),conj(value(a))*b.v.re))
    else
        Simplex{V,G,basis(a)}(value(a)*b.v.re) + contraction(a,imaginary(b))
    end
end
function contraction(a::SimplexComplex{V,B},b::TensorTerm{V,G}) where {V,G,B}
    if B == basis(b)
        SimplexComplex{V,B}(Complex((conj(a.v.im)*value(b))*value(abs2_inv(B)),0))
    else
        contraction(imaginary(a),b)
    end
end

# dyadic products

export outer

outer(a::Leibniz.Derivation,b::Chain{V,1}) where V= outer(V(a),b)
outer(a::Chain{W},b::Leibniz.Derivation{T,1}) where {W,T} = outer(a,W(b))
outer(a::Chain{W},b::Chain{V,1}) where {W,V} = Chain{V,1}(a.*value(b))

contraction(a::Proj,b::TensorGraded) = a.v⊗(a.λ*(a.v⋅b))
contraction(a::Dyadic,b::TensorGraded) = a.x⊗(a.y⋅b)
contraction(a::TensorGraded,b::Dyadic) = (a⋅b.x)⊗b.y
contraction(a::TensorGraded,b::Proj) = ((a⋅b.v)*b.λ)⊗b.v
contraction(a::Dyadic,b::Dyadic) = (a.x*(a.y⋅b.x))⊗b.y
contraction(a::Dyadic,b::Proj) = (a.x*((a.y⋅b.v)*b.λ))⊗b.v
contraction(a::Proj,b::Dyadic) = (a.v*(a.λ*(a.v⋅b.x)))⊗b.y
contraction(a::Proj,b::Proj) = (a.v*((a.λ*b.λ)*(a.v⋅b.v)))⊗b.v
contraction(a::Dyadic{V},b::TensorGraded{V,0}) where V = Dyadic{V}(a.x*b,a.y)
contraction(a::Proj{V},b::TensorTerm{V,0}) where V = Proj{V}(a.v,a.λ*value(b))
contraction(a::Proj{V},b::Chain{V,0}) where V = Proj{V}(a.v,a.λ*(@inbounds b[1]))
contraction(a::Proj{V,<:Chain{V,1,<:TensorNested}},b::TensorGraded{V,0}) where V = Proj(Chain{V,1}(contraction.(value(a.v),b)))
#contraction(a::Chain{W,1,<:Proj{V}},b::Chain{V,1}) where {W,V} = Chain{W,1}(value(a).⋅b)
contraction(a::Chain{W,1,<:Dyadic{V}},b::Chain{V,1}) where {W,V} = Chain{W,1}(value(a).⋅Ref(b))
contraction(a::Proj{W,<:Chain{W,1,<:TensorNested{V}}},b::Chain{V,1}) where {W,V} = a.v:b
contraction(a::Chain{W},b::Chain{V,G,<:Chain}) where {W,G,V} = Chain{V,G}(column(Ref(a).⋅value(b)))
contraction(a::Chain{W,L,<:Chain},b::Chain{V,G,<:Chain{W,L}}) where {W,L,G,V} = Chain{V,G}(column(Ref(a).⋅value(b)))
contraction(a::Multivector{W,<:Multivector},b::Multivector{V,<:Multivector{W}}) where {W,V} = Multivector{V}(column(Ref(a).⋅value(b)))
Base.:(:)(a::Chain{V,1,<:Chain},b::Chain{V,1,<:Chain}) where V = sum(value(a).⋅value(b))
Base.:(:)(a::Chain{W,1,<:Dyadic{V}},b::Chain{V,1}) where {W,V} = sum(value(a).⋅Ref(b))
#Base.:(:)(a::Chain{W,1,<:Proj{V}},b::Chain{V,1}) where {W,V} = sum(broadcast(⋅,value(a),Ref(b)))

contraction(a::Submanifold{W},b::Chain{V,G,<:Chain}) where {W,G,V} = Chain{V,G}(column(Ref(a).⋅value(b)))
contraction(a::Simplex{W},b::Chain{V,G,<:Chain}) where {W,G,V} = Chain{V,G}(column(Ref(a).⋅value(b)))
contraction(x::Chain{V,G,<:Chain},y::Simplex{V,G}) where {V,G} = value(y)*x[bladeindex(mdims(V),UInt(basis(y)))]
contraction(x::Chain{V,G,<:Chain},y::Submanifold{V,G}) where {V,G} = x[bladeindex(mdims(V),UInt(y))]
contraction(a::Chain{V,L,<:Chain{V,G}},b::Chain{V,G,<:Chain{V}}) where {V,G,L} = Chain{V,G}(matmul(value(a),value(b)))
contraction(x::Chain{W,L,<:Chain{V,G},N},y::Chain{V,G,T,N}) where {W,L,N,V,G,T} = Chain{V,G}(matmul(value(x),value(y)))
contraction(x::Chain{W,L,<:Multivector{V},N},y::Chain{V,G,T,N}) where {W,L,N,V,G,T} = Multivector{V}(matmul(value(x),value(y)))
contraction(x::Multivector{W,<:Chain{V,G},N},y::Multivector{V,T,N}) where {W,N,V,G,T} = Chain{V,G}(matmul(value(x),value(y)))
contraction(x::Multivector{W,<:Multivector{V},N},y::Multivector{V,T,N}) where {W,N,V,T} = Multivector{V}(matmul(value(x),value(y)))
@inline @generated function matmul(x::Values{N,<:Simplex{V,G}},y::Values{N}) where {N,V,G}
    Expr(:call,:Values,[Expr(:call,:+,:(@inbounds y[$i]*value(x[$i]))) for i ∈ 1:N]...)
end
@inline @generated function matmul(x::Values{N,<:Chain{V,G}},y::Values{N}) where {N,V,G}
    Expr(:call,:Values,[Expr(:call,:+,[:(@inbounds y[$i]*x[$i][$j]) for i ∈ 1:N]...) for j ∈ 1:binomial(mdims(V),G)]...)
end
@inline @generated function matmul(x::Values{N,<:Multivector{V}},y::Values{N}) where {N,V,G}
    Expr(:call,:Values,[Expr(:call,:+,[:(@inbounds y[$i]*value(x[$i])[$j]) for i ∈ 1:N]...) for j ∈ 1:1<<mdims(V)]...)
end

contraction(a::Dyadic{V,<:Chain{V,1,<:Chain},<:Chain{V,1,<:Chain}} where V,b::TensorGraded) = sum(value(a.x).⊗(value(a.y).⋅b))
contraction(a::Dyadic{V,<:Chain{V,1,<:Chain}} where V,b::TensorGraded) = sum(value(a.x).⊗(a.y.⋅b))
contraction(a::Dyadic{V,T,<:Chain{V,1,<:Chain}} where {V,T},b::TensorGraded) = sum(a.x.⊗(value(a.y).⋅b))
contraction(a::Proj{V,<:Chain{W,1,<:Chain} where W} where V,b::TensorGraded) = sum(value(a.v).⊗(value(a.λ).*value(a.v).⋅b))
contraction(a::Proj{V,<:Chain{W,1,<:Chain{V,1}} where W},b::TensorGraded{V,1}) where V = sum(value(a.v).⊗(value(a.λ).*column(value(a.v).⋅b)))

+(a::Proj{V}...) where V = Proj{V}(Chain(Values(eigvec.(a)...)),Chain(Values(eigval.(a)...)))
+(a::Dyadic{V}...) where V = Proj(Chain(a...))
+(a::TensorNested{V}...) where V = Proj(Chain(Dyadic.(a)...))
plus(a::Proj{W,<:Chain{W,1,<:TensorNested{V}}} where W,b::TensorNested{V}) where V = +(value(a.v)...,b)
plus(a::TensorNested{V},b::Proj{W,<:Chain{W,1,<:TensorNested{V}}} where W) where V = +(a,value(b.v)...)
+(a::Proj{M,<:Chain{M,1,<:TensorNested{V}}} where M,b::Proj{W,<:Chain{W,1,<:TensorNested{V}}} where W) where V = +(value(a.v)...,value(b.v)...)
+(a::Proj{M,<:Chain{M,1,<:Chain{V}}} where M,b::Proj{W,<:Chain{W,1,<:Chain{V}}} where W) where V = Chain(Values(value(a.v)...,value(b.v)...))
#+(a::Proj{W,<:Chain{W,1,<:TensorNested{V}}} where W,b::TensorNested{V}) where V = +(b,Proj.(value(a.v),value(a.λ))...)
#+(a::TensorNested{V},b::Proj{W,<:Chain{W,1,<:TensorNested{V}}} where W) where V = +(a,value(b.v)...)

-(a::TensorNested) where V = -1a
minus(a::TensorNested,b::TensorNested) where V = a+(-b)
*(a::Number,b::TensorNested{V}) where V = (a*One(V))*b
*(a::TensorNested{V},b::Number) where V = a*(b*One(V))
@inline times(a::TensorGraded{V,0},b::TensorNested{V}) where V = b⋅a
@inline times(a::TensorNested{V},b::TensorGraded{V,0}) where V = a⋅b
@inline times(a::TensorGraded{V,0},b::Proj{V,<:Chain{V,1,<:TensorNested}}) where V = Proj{V}(a*b.v)
@inline times(a::Proj{V,<:Chain{V,1,<:TensorNested}},b::TensorGraded{V,0}) where V = Proj{V}(a.v*b)

@inline times(a::DyadicChain,b::DyadicChain) where V = a⋅b
@inline times(a::DyadicChain,b::Chain) where V = a⋅b
@inline times(a::DyadicChain,b::TensorTerm) where V = a⋅b
@inline times(a::TensorGraded,b::DyadicChain) where V = a⋅b
@inline times(a::DyadicChain,b::TensorNested) where V = a⋅b
@inline times(a::TensorNested,b::DyadicChain) where V = a⋅b

# dyadic identity element

Base.:+(t::LinearAlgebra.UniformScaling,g::TensorNested) = t+DyadicChain(g)
Base.:+(g::TensorNested,t::LinearAlgebra.UniformScaling) = DyadicChain(g)+t
Base.:+(g::Chain{V,1,<:Chain{V,1}},t::LinearAlgebra.UniformScaling) where V = t+g
Base.:-(t::LinearAlgebra.UniformScaling,g::TensorNested) = t-DyadicChain(g)
Base.:-(g::TensorNested,t::LinearAlgebra.UniformScaling) = DyadicChain(g)-t
@generated Base.:+(t::LinearAlgebra.UniformScaling{Bool},g::Chain{V,1,<:Chain{V,1}}) where V = :(Chain{V,1}($(getalgebra(V).b[Grassmann.list(2,mdims(V)+1)]).+value(g)))
@generated Base.:+(t::LinearAlgebra.UniformScaling,g::Chain{V,1,<:Chain{V,1}}) where V = :(Chain{V,1}(t.λ*$(getalgebra(V).b[Grassmann.list(2,mdims(V)+1)]).+value(g)))
@generated Base.:-(t::LinearAlgebra.UniformScaling{Bool},g::Chain{V,1,<:Chain{V,1}}) where V = :(Chain{V,1}($(getalgebra(V).b[Grassmann.list(2,mdims(V)+1)]).-value(g)))
@generated Base.:-(t::LinearAlgebra.UniformScaling,g::Chain{V,1,<:Chain{V,1}}) where V = :(Chain{V,1}(t.λ*$(getalgebra(V).b[Grassmann.list(2,mdims(V)+1)]).-value(g)))
@generated Base.:-(g::Chain{V,1,<:Chain{V,1}},t::LinearAlgebra.UniformScaling{Bool}) where V = :(Chain{V,1}(value(g).-$(getalgebra(V).b[Grassmann.list(2,mdims(V)+1)])))
@generated Base.:-(g::Chain{V,1,<:Chain{V,1}},t::LinearAlgebra.UniformScaling) where V = :(Chain{V,1}(value(g).-t.λ*$(getalgebra(V).b[Grassmann.list(2,mdims(V)+1)])))

# more algebra

for F ∈ Fields
    @eval begin
        *(a::F,b::SimplexComplex{V,B}) where {F<:$F,V,B} = SimplexComplex{V,B}(a*b.v)
        *(a::SimplexComplex{V,B},b::F) where {F<:$F,V,B} = SimplexComplex{V,B}(a.v*b)
        *(a::F,b::Multivector{V}) where {F<:$F,V} = Multivector{V}(a*b.v)
        *(a::Multivector{V},b::F) where {F<:$F,V} = Multivector{V}(a.v*b)
        *(a::F,b::Chain{V,G}) where {F<:$F,V,G} = Chain{V,G}(a*b.v)
        *(a::Chain{V,G},b::F) where {F<:$F,V,G} = Chain{V,G}(a.v*b)
        *(a::F,b::Simplex{V,G,B,T} where B) where {F<:$F,V,G,T} = Simplex{V,G}($Sym.:∏(a,b.v),basis(b))
        *(a::Simplex{V,G,B,T} where B,b::F) where {F<:$F,V,G,T} = Simplex{V,G}($Sym.:∏(a.v,b),basis(a))
        *(a::F,b::Simplex{V,G,B,T} where B) where {F<:$F,V,G,T<:Number} = Simplex{V,G}(*(a,b.v),basis(b))
        *(a::Simplex{V,G,B,T} where B,b::F) where {F<:$F,V,G,T<:Number} = Simplex{V,G}(*(a.v,b),basis(a))
    end
end
for op ∈ (:+,:-)
    for Term ∈ (:TensorGraded,:TensorMixed,:Zero)
        @eval begin
            $op(a::T,b::NSE) where T<:$Term = iszero(b) ? a : $op(a,b*One(Manifold(a)))
            $op(a::NSE,b::T) where T<:$Term = iszero(a) ? $op(b) : $op(a*One(Manifold(b)),b)
        end
    end
end
for (op,po) ∈ ((:+,:plus),(:-,:minus))
    @eval begin
        @generated function $po(a::TensorTerm{V,L},b::TensorTerm{V,G}) where {V,L,G}
            adder(a,b,$(QuoteNode(op)))
        end
        @generated function $po(a::TensorTerm{V,G},b::Chain{V,G,T}) where {V,G,T}
            adder(a,b,$(QuoteNode(op)))
        end
        @generated function $po(a::TensorTerm{V,L},b::Chain{V,G,T}) where {V,G,T,L}
            adder(a,b,$(QuoteNode(op)))
        end
        @generated function $po(a::TensorTerm{V,G},b::Multivector{V,T}) where {V,G,T}
            adder(a,b,$(QuoteNode(op)))
        end
    end
end
@generated minus(b::Chain{V,G,T},a::TensorTerm{V,G}) where {V,G,T} = adder(a,b,:-,true)
@generated minus(b::Chain{V,G,T},a::TensorTerm{V,L}) where {V,G,T,L} = adder(a,b,:-,true)
@generated minus(b::Multivector{V,T},a::TensorTerm{V,G}) where {V,G,T} = adder(a,b,:-,true)

@eval begin
    @generated function Base.adjoint(m::Chain{V,G,T}) where {V,G,T}
        CONJ,VEC = conjvec(m)
        TF = T ∉ FieldsBig ? :Any : :T
        if binomial(mdims(V),G)<(1<<cache_limit)
            if isdyadic(V)
                $(insert_expr((:N,:M,:ib),:svec)...)
                out = zeros(svec(N,G,Any))
                for i ∈ 1:binomial(N,G)
                    @inbounds setblade!_pre(out,:($CONJ(@inbounds m.v[$i])),dual(V,ib[i],M),Val{N}())
                end
                return :(Chain{$(dual(V)),G}($(Expr(:call,tvec(N,TF),out...))))
            else
                return :(Chain{$(dual(V)),G}($CONJ.(value(m))))
            end
        else return quote
            if isdyadic(V)
                $(insert_expr((:N,:M,:ib),:svec)...)
                out = zeros($VEC(N,G,$TF))
                for i ∈ 1:binomial(N,G)
                    @inbounds setblade!(out,$CONJ(m.v[i]),dual(V,ib[i],M),Val{N}())
                end
            else
                out = $CONJ.(value(m))
            end
            Chain{dual(V),G}(out)
        end end
    end
    @generated function Base.adjoint(m::Multivector{V,T}) where {V,T}
        CONJ,VEC = conjvec(m)
        TF = T ∉ FieldsBig ? :Any : :T
        if mdims(V)<cache_limit
            if isdyadic(V)
                $(insert_expr((:N,:M,:bs,:bn),:svec)...)
                out = zeros(svec(N,Any))
                for g ∈ 1:N+1
                    ib = indexbasis(N,g-1)
                    @inbounds for i ∈ 1:bn[g]
                        @inbounds setmulti!_pre(out,:($CONJ(@inbounds m.v[$(bs[g]+i)])),dual(V,ib[i],M))
                    end
                end
                return :(Multivector{$(dual(V))}($(Expr(:call,tvec(N,TF),out...))))
            else
                return :(Multivector{$(dual(V))}($CONJ.(value(m))))
            end
        else return quote
            if isdyadic(V)
                $(insert_expr((:N,:M,:bs,:bn),:svec)...)
                out = zeros($VEC(N,$TF))
                for g ∈ 1:N+1
                    ib = indexbasis(N,g-1)
                    @inbounds for i ∈ 1:bn[g]
                        @inbounds setmulti!(out,$CONJ(m.v[bs[g]+i]),dual(V,ib[i],M))
                    end
                end
            else
                out = $CONJ.(value(m))
            end
            Multivector{dual(V)}(out)
        end end
    end
end

function generate_products(Field=Field,VEC=:mvec,MUL=:*,ADD=:+,SUB=:-,CONJ=:conj,PAR=false)
    if Field == Grassmann.Field
        generate_mutators(:(Variables{M,T}),Number,Expr,SUB,MUL)
    elseif Field ∈ (SymField,:(SymPy.Sym))
        generate_mutators(:(FixedVector{M,T}),Field,set_val,SUB,MUL)
    end
    PAR && (Leibniz.extend_field(eval(Field)); global parsym = (parsym...,eval(Field)))
    TF = Field ∉ FieldsBig ? :Any : :T
    EF = Field ≠ Any ? Field : ExprField
    Field ∉ Fields && @eval begin
        *(a::F,b::Submanifold{V}) where {F<:$EF,V} = Simplex{V}(a,b)
        *(a::Submanifold{V},b::F) where {F<:$EF,V} = Simplex{V}(b,a)
        *(a::F,b::SimplexComplex{V,B}) where {F<:$EF,V,B} = a*Multivector(b)
        *(a::SimplexComplex{V,B},b::F) where {F<:$EF,V,B} = Multivector(a)*b
        *(a::F,b::Multivector{V}) where {F<:$EF,V} = Multivector{V}(a*b.v)
        *(a::Multivector{V},b::F) where {F<:$EF,V} = Multivector{V}(a.v*b)
        *(a::F,b::Chain{V,G}) where {F<:$EF,V,G} = Chain{V,G}(a*b.v)
        *(a::Chain{V,G},b::F) where {F<:$EF,V,G} = Chain{V,G}(a.v*b)
        *(a::F,b::Simplex{V,G,B,T} where B) where {F<:$EF,V,G,T} = Simplex{V,G}($Sym.:∏(a,b.v),basis(b))
        *(a::Simplex{V,G,B,T} where B,b::F) where {F<:$EF,V,G,T} = Simplex{V,G}($Sym.:∏(a.v,b),basis(a))
        *(a::F,b::Simplex{V,G,B,T} where B) where {F<:$EF,V,G,T<:Number} = Simplex{V,G}($Sym.:∏(a,b.v),basis(b))
        *(a::Simplex{V,G,B,T} where B,b::F) where {F<:$EF,V,G,T<:Number} = Simplex{V,G}($Sym.:∏(a.v,b),basis(a))
        adjoint(b::Simplex{V,G,B,T}) where {V,G,B,T<:$Field} = Simplex{dual(V),G,B',$TF}($CONJ(value(b)))
        #Base.promote_rule(::Type{Simplex{V,G,B,T}},::Type{S}) where {V,G,T,B,S<:$Field} = Simplex{V,G,B,promote_type(T,S)}
        #Base.promote_rule(::Type{Multivector{V,T,B}},::Type{S}) where {V,T,B,S<:$Field} = Multivector{V,promote_type(T,S),B}
    end
    #=Field ∉ Fields && Field≠Any && @eval begin
        Base.promote_rule(::Type{Chain{V,G,T,B}},::Type{S}) where {V,G,T,B,S<:$Field} = Chain{V,G,promote_type(T,S),B}
    end=#
    @eval begin
        Base.:-(a::Simplex{V,G,B,T}) where {V,G,B,T<:$Field} = Simplex{V,G,B,$TF}($SUB(value(a)))
        function times(a::Simplex{V,G,A,T} where {G,A},b::Simplex{V,L,B,S} where {L,B}) where {V,T<:$Field,S<:$Field}
            ba,bb = basis(a),basis(b)
            v = derive_mul(V,UInt(ba),UInt(bb),a.v,b.v,$MUL)
            Simplex(v,mul(ba,bb,v))
        end
        ∧(a::$Field,b::$Field) = $MUL(a,b)
        ∧(a::F,b::B) where B<:TensorTerm{V,G} where {F<:$EF,V,G} = Simplex{V,G}(a,b)
        ∧(a::A,b::F) where A<:TensorTerm{V,G} where {F<:$EF,V,G} = Simplex{V,G}(b,a)
        #=∧(a::$Field,b::Chain{V,G,T}) where {V,G,T<:$Field} = Chain{V,G,T}(a.*b.v)
        ∧(a::Chain{V,G,T},b::$Field) where {V,G,T<:$Field} = Chain{V,G,T}(a.v.*b)
        ∧(a::$Field,b::Multivector{V,T}) where {V,T<:$Field} = Multivector{V,T}(a.*b.v)
        ∧(a::Multivector{V,T},b::$Field) where {V,T<:$Field} = Multivector{V,T}(a.v.*b)=#
    end
    for (op,po,eop,bop) ∈ ((:+,:plus,:(+=),ADD),(:-,:minus,:(-=),SUB))
        @eval begin
            function $po(a::Chain{V,G,T},b::Chain{V,L,S}) where {V,G,T<:$Field,L,S<:$Field}
                $(insert_expr((:N,:t,:out,:r,:bng),VEC)...)
                @inbounds out[r+1:r+bng] = value(a,$VEC(N,G,t))
                rb = binomsum(N,L)
                Rb = binomial(N,L)
                @inbounds out[rb+1:rb+Rb] = $(bcast(bop,:(value(b,$VEC(N,L,t)),)))
                return Multivector{V}(out)
            end
            function $po(a::Chain{V,G,T},b::Chain{V,G,S}) where {V,G,T<:$Field,S<:$Field}
                return Chain{V,G}($(bcast(bop,:(a.v,b.v))))
            end
            function $po(a::Multivector{V,T},b::Multivector{V,S}) where {V,T<:$Field,S<:$Field}
                $(insert_expr((:N,:t),VEC)...)
                out = value(a,$VEC(N,t))
                $(add_val(eop,:out,:(value(b,$VEC(N,t))),bop))
                return Multivector{V}(out)
            end
            function $po(a::Chain{V,G,T},b::Multivector{V,S}) where {V,G,T<:$Field,S<:$Field}
                $(insert_expr((:N,:t,:r,:bng),VEC)...)
                out = convert($VEC(N,t),$(bcast(bop,:(value(b,$VEC(N,t)),))))
                @inbounds $(add_val(:(+=),:(out[r+1:r+bng]),:(value(a,$VEC(N,G,t))),ADD))
                return Multivector{V}(out)
            end
            function $po(a::Multivector{V,T},b::Chain{V,G,S}) where {V,T<:$Field,G,S<:$Field}
                $(insert_expr((:N,:t,:r,:bng),VEC)...)
                out = value(a,$VEC(N,t))
                @inbounds $(add_val(eop,:(out[r+1:r+bng]),:(value(b,$VEC(N,G,t))),bop))
                return Multivector{V}(out)
            end
        end
    end
end

### Product Algebra

@generated function contraction2(a::TensorGraded{V,L},b::Chain{V,G,T}) where {V,G,L,T}
    product_contraction(a,b,false,:product)
end
for (op,prop) ∈ ((:times,:product),(:contraction,:product_contraction))
    @eval begin
        @generated function $op(b::Chain{V,G,T},a::TensorTerm{V,L}) where {V,G,L,T}
            $prop(a,b,true)
        end
        @generated function $op(a::TensorGraded{V,L},b::Chain{V,G,T}) where {V,G,L,T}
            $prop(a,b)
        end
    end
end
for op ∈ (:∧,:∨)
    prop = Symbol(:product_,op)
    @eval begin
        @generated function $op(a::Chain{w,G,T},b::Chain{W,L,S}) where {T,w,S,W,G,L}
            $prop(a,b)
        end
        @generated function $op(b::Chain{Q,G,T},a::TensorTerm{R,L}) where {Q,G,T,R,L}
            $prop(a,b,true)
        end
        @generated function $op(a::TensorTerm{Q,G},b::Chain{R,L,T}) where {Q,R,T,G,L}
            $prop(a,b)
        end
    end
end
for (op,product!) ∈ ((:∧,:exteraddmulti!),(:times,:geomaddmulti!),
                     (:∨,:meetaddmulti!),(:contraction,:skewaddmulti!))
    preproduct! = Symbol(product!,:_pre)
    prop = op≠:times ? Symbol(:product_,op) : :product
    @eval begin
        @generated function $op(b::Multivector{V,T},a::TensorGraded{V,G}) where {V,T,G}
            $prop(a,b,true)
        end
        @generated function $op(a::TensorGraded{V,G},b::Multivector{V,S}) where {V,G,S}
            $prop(a,b)
        end
        @generated function $op(a::Multivector{V,T},b::Multivector{V,S}) where {V,T,S}
            MUL,VEC = mulvec(a,b)
            loop = generate_loop_multivector(V,:(a.v),:(b.v),MUL,$product!,$preproduct!)
            if mdims(V)<cache_limit/2
                return insert_t(:(Multivector{V}($(loop[2].args[2]))))
            else return quote
                $(insert_expr(loop[1],VEC)...)
                $(loop[2])
                return Multivector{V,t}(out)
            end end
        end
    end
end

for side ∈ (:left,:right)
    c,p = Symbol(:complement,side),Symbol(:parity,side)
    h,pg,pn = Symbol(c,:hodge),Symbol(p,:hodge),Symbol(p,:null)
    pnp = :(Leibniz.$(Symbol(pn,:pre)))
    for (c,p) ∈ ((c,p),(h,pg))
        @eval begin
            function $c(z::SimplexComplex{V}) where V
                G = grade(V)
                Simplex{V,G,getbasis(V,UInt(1)<<G-1)}(z.v.re) + $c(imaginary(z))
            end
            @generated function $c(b::Chain{V,G,T}) where {V,G,T}
                isdyadic(V) && throw(error("Complement for dyadic tensors is undefined"))
                istangent(V) && (return :($$c(Multivector(b))))
                SUB,VEC,MUL = subvec(b)
                if binomial(mdims(V),G)<(1<<cache_limit)
                    $(insert_expr((:N,:ib,:D),:svec)...)
                    P = $(c≠h ? 0 : :(hasinf(V)+hasorigin(V)))
                    out = zeros(svec(N,G,Any))
                    D = diffvars(V)
                    for k ∈ 1:binomial(N,G)
                        B = @inbounds ib[k]
                        val = :(conj(@inbounds b.v[$k]))
                        v = Expr(:call,MUL,$p(V,B),$(c≠h ? :($pnp(V,B,val)) : :val))
                        setblade!_pre(out,v,complement(N,B,D,P),Val{N}())
                    end
                    return :(Chain{V,$(N-G)}($(Expr(:call,tvec(N,N-G,:T),out...))))
                else return quote
                    $(insert_expr((:N,:ib,:D),:svec)...)
                    P = $(c≠h ? 0 : :(hasinf(V)+hasorigin(V)))
                    out = zeros($VEC(N,G,T))
                    D = diffvars(V)
                    for k ∈ 1:binomial(N,G)
                        @inbounds val = b.v[k]
                        if val≠0
                            @inbounds ibk = ib[k]
                            v = conj($MUL($$p(V,ibk),$(c≠h ? :($$pn(V,ibk,val)) : :val)))
                            setblade!(out,v,complement(N,ibk,D,P),Val{N}())
                        end
                    end
                    return Chain{V,N-G}(out)
                end end
            end
            @generated function $c(m::Multivector{V,T}) where {V,T}
                isdyadic(V) && throw(error("Complement for dyadic tensors is undefined"))
                SUB,VEC = subvec(m)
                if mdims(V)<cache_limit
                    $(insert_expr((:N,:bs,:bn),:svec)...)
                    P = $(c≠h ? 0 : :(hasinf(V)+hasorigin(V)))
                    out = zeros(svec(N,Any))
                    D = diffvars(V)
                    for g ∈ 1:N+1
                        ib = indexbasis(N,g-1)
                        @inbounds for i ∈ 1:bn[g]
                            ibi = @inbounds ib[i]
                            val = :(conj(@inbounds m.v[$(bs[g]+i)]))
                            v = Expr(:call,:*,$p(V,ibi),$(c≠h ? :($pnp(V,ibi,val)) : :val))
                            @inbounds setmulti!_pre(out,v,complement(N,ibi,D,P),Val{N}())
                        end
                    end
                    return :(Multivector{V}($(Expr(:call,tvec(N,:T),out...))))
                else return quote
                    $(insert_expr((:N,:bs,:bn),:svec)...)
                    P = $(c≠h ? 0 : :(hasinf(V)+hasorigin(V)))
                    out = zeros($VEC(N,T))
                    D = diffvars(V)
                    for g ∈ 1:N+1
                        ib = indexbasis(N,g-1)
                        @inbounds for i ∈ 1:bn[g]
                            @inbounds val = m.v[bs[g]+i]
                            if val≠0
                                ibi = @inbounds ib[i]
                                v = conj($$p(V,ibi)*$(c≠h ? :($$pn(V,ibi,val)) : :val))
                                setmulti!(out,v,complement(N,ibi,D,P),Val{N}())
                            end
                        end
                    end
                    return Multivector{V}(out)
                end end
            end
        end
    end
end
for reverse ∈ (:reverse,:involute,:conj,:clifford)
    p = Symbol(:parity,reverse)
    @eval begin
        function $reverse(z::SimplexComplex{V,B}) where {V,B}
            SimplexComplex{V,B}(Complex(z.v.re,$p(grade(B)) ? -z.v.im : z.v.im))
        end
        @generated function $reverse(b::Chain{V,G,T}) where {V,G,T}
            SUB,VEC = subvec(b)
            if binomial(mdims(V),G)<(1<<cache_limit)
                D = diffvars(V)
                D==0 && !$p(G) && (return :b)
                $(insert_expr((:N,:ib),:svec)...)
                out = zeros(svec(N,G,Any))
                for k ∈ 1:binomial(N,G)
                    v = :(@inbounds b.v[$k])
                    if D==0
                        @inbounds setblade!_pre(out,:($SUB($v)),ib[k],Val{N}())
                    else
                        @inbounds B = ib[k]
                        setblade!_pre(out,$p(grade(V,B)) ? :($SUB($v)) : v,B,Val{N}())
                    end
                end
                return :(Chain{V,G}($(Expr(:call,tvec(N,G,:T),out...))))
            else return quote
                D = diffvars(V)
                D==0 && !$$p(G) && (return b)
                $(insert_expr((:N,:ib),:svec)...)
                out = zeros($VEC(N,G,T))
                for k ∈ 1:binomial(N,G)
                    @inbounds v = b.v[k]
                    v≠0 && if D==0
                        @inbounds setblade!(out,$SUB(v),ib[k],Val{N}())
                    else
                        @inbounds B = ib[k]
                        setblade!(out,$$p(grade(V,B)) ? $SUB(v) : v,B,Val{N}())
                    end
                end
                return Chain{V,G}(out)
            end end
        end
        @generated function $reverse(m::Multivector{V,T}) where {V,T}
            if mdims(V)<cache_limit
                $(insert_expr((:N,:bs,:bn,:D),:svec)...)
                out = zeros(svec(N,Any))
                for g ∈ 1:N+1
                    pg = $p(g-1)
                    ib = indexbasis(N,g-1)
                    @inbounds for i ∈ 1:bn[g]
                        v = :(@inbounds m.v[$(@inbounds bs[g]+i)])
                        if D==0
                            @inbounds setmulti!(out,pg ? :($SUB($v)) : v,ib[i],Val{N}())
                        else
                            @inbounds B = ib[i]
                            setmulti!(out,$p(grade(V,B)) ? :($SUB($v)) : v,B,Val{N}())
                        end
                    end
                end
                return :(Multivector{V}($(Expr(:call,tvec(N,:T),out...))))
            else return quote
                $(insert_expr((:N,:bs,:bn,:D),:svec)...)
                out = zeros($VEC(N,T))
                for g ∈ 1:N+1
                    pg = $$p(g-1)
                    ib = indexbasis(N,g-1)
                    @inbounds for i ∈ 1:bn[g]
                        @inbounds v = m.v[bs[g]+i]
                        v≠0 && if D==0
                            @inbounds setmulti!(out,pg ? $SUB(v) : v,ib[i],Val{N}())
                        else
                            @inbounds B = ib[i]
                            setmulti!(out,$$p(grade(V,B)) ? $SUB(v) : v,B,Val{N}())
                        end
                    end
                end
                return Multivector{V}(out)
            end end
        end
    end
end
