module Hyperspecialize

using MacroTools
using InteractiveUtils

global concretizations = Dict{Symbol, Any}()

macro isdefined(var)
 quote
   try
     local _ = $(esc(var))
     true
   catch err
     isa(err, UndefVarError) ? false : rethrow(err)
   end
 end
end

function concretesubtypes(t)
  if isconcretetype(t)
    return [t]
  else
    return vcat([concretesubtypes(s) for s in subtypes(t)]...)
  end
end

function make_type_set(t)
  return Set{Type}(t)
end

function make_type_set(t::Type)
  return Set{Type}((t,))
end

function parse_element(base_mod, K)
  if @capture(K, (L_, R_))
    M = L
    K = R
  else
    M = base_mod
  end
  return (M, K)
end

function _concretize(base_mod, target_mod, key, types::Type)
  return _concretize(base_mod, target_mod, key, [types])
end

function _concretize(base_mod, target_mod, key, types)
  if base_mod == target_mod
    if !isdefined(base_mod, :__hyperspecialize__)
      eval(base_mod, quote
        const global __hyperspecialize__ = Dict{Symbol, Any}()
        __hyperspecialize__[:concretizations] = Dict{Symbol, Set{Type}}()
        __hyperspecialize__[:replicables] = Dict{Symbol, Tuple{Module, Any, Any}}()
      end)
    end
    if key in keys(target_mod.__hyperspecialize__[:concretizations])
      error("cannot reconcretize $T")
    else
      target_mod.__hyperspecialize__[:concretizations][key] = Set{Type}(types)
    end
  else
    error("cannot concretize \"$key\" in module \"$target_mod\" from module \"$base_mod\"")
  end
end

macro concretize(K, T)
  (M, K) = parse_element(__module__, K)
  return :(_concretize($(esc(__module__)), $(esc(M)), $(QuoteNode(K)), $(esc(T))))
end

function _widen(base_mod, target_mod, key, types::Type)
  return _widen(base_mod, target_mod, key, [types])
end

function _widen(base_mod, target_mod, key, types)
  _concretization(base_mod, target_mod, key)
  union!(target_mod.__hyperspecialize__[:concretizations][key], Set{Type}(types))
  if key in keys(target_mod.__hyperspecialize__[:replicables])
    for (def_mod, E, elements) in target_mod.__hyperspecialize__[:replicables][key]
      _define(def_mod, E, elements...)
    end
  end
  target_mod.__hyperspecialize__[:concretizations][key]
end

macro widen(K, T)
  (M, K) = parse_element(__module__, K)
  return :(_widen($(esc(__module__)), $(esc(M)), $(QuoteNode(K)), $(esc(T))))
end

function _concretization(base_mod, target_mod, key)
  if isdefined(target_mod, :__hyperspecialize__) && key in keys(target_mod.__hyperspecialize__[:concretizations])
    target_mod.__hyperspecialize__[:concretizations][key]
  else
    if isdefined(target_mod, key)
      types = concretesubtypes(eval(target_mod, key))
    else
      types = []
    end
    _concretize(base_mod, target_mod, key, types)
  end
  target_mod.__hyperspecialize__[:concretizations][key]
end

macro concretization(K)
  (M, K) = parse_element(__module__, K)
  return :(_concretization($(esc(__module__)), $(esc(M)), $(QuoteNode(K))))
end

function _define(def_mod, E, elements...)
  found = false
  target_mod = nothing
  key = nothing
  MacroTools.postwalk(X -> begin
    if @capture(X, @hyperspecialize(I_))
      (target_mod, key) = elements[I]
      found = true
    end
    X
  end, E)
  if found
    for typ in _concretization(def_mod, target_mod, key)
      found = false
      _define(def_mod, MacroTools.postwalk(X -> begin
        if @capture(X, @hyperspecialize(_)) && !found
          found = true
          typ
        else
          X
        end
      end, E), elements...)
    end
  else
    eval(def_mod, E)
  end
end

function _replicable(base_mod, E, elements...)
  MacroTools.postwalk(X -> begin
    if @capture(X, @hyperspecialize(I_))
      (target_mod, key) = elements[I]
      concretization(base_mod, target_mod, key)
      if key in keys(target_mod.__hyperspecialize__[:replicables])
        push!(target_mod.__hyperspecialize__[:replicables][key], (base_mod, E, elements))
      else
        target_mod.__hyperspecialize__[:replicables][key] = (base_mod, E, elements)
      end
    end
    X
  end, E)
  _define(base_mod, E, elements...)
end

macro replicable(E)
  thunk = :()
  count = 0
  E = MacroTools.postwalk(X -> begin
    if @capture(X, @hyperspecialize(K_))
      (M, K) = parse_element(__module__, K)
      if count == 0
        thunk = :(($(esc(M)), $(QuoteNode(K))))
      else
        thunk = :($thunk, ($(esc(M)), $(QuoteNode(K))))
      end
      count += 1
      :(@hyperspecialize($count))
    else
      X
    end
  end, E)
  return :(_replicable($(esc(__module__)), $(QuoteNode(E)), $thunk))
end

export @concretize, @widen, @concretization, @replicable

end # module
