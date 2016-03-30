module ShapleyValues

export shapley_values


"Designed to determine the Shapley values (importance) of each feature for f(x)."
function shapley_values(x, f::Function, Xt, g::Function=identity; featureGroups=nothing, sampleWeights=nothing, nsamples=10000, fnull=nothing) # maxStdDevFraction=0.02
    x = reshape(x, length(x),1)
    P = length(x)
    N = size(Xt)[2]

    sampleWeights != nothing || (sampleWeights = ones(N))

    # find the feature groups we will test. If a feature rarely changes from its
    # current value then we know it doesn't have a large impact on the model
    featureGroups != nothing || (featureGroups = Array{Int64,1}[Int64[i] for i in 1:length(x)])
    featureGroups = convert(Array{Array{Int64,1},1}, featureGroups)
    varyingInds = varying_feature_groups(x, Xt, featureGroups)
    varyingFeatureGroups = featureGroups[varyingInds]
    M = length(varyingFeatureGroups)

    # loop through the estimation process focusing samples on groups with high variance
    nextSamples = allocate_samples(ones(M), min(20M, nsamples))
    withi = [MeanVarianceAccumulator() for i in 1:M]
    withouti = [MeanVarianceAccumulator() for i in 1:M]
    deltas = [MeanVarianceAccumulator() for i in 1:M]
    counts = zeros(Int64, M)
    totalSamples = 0
    while true

        # update our estimates for a block of samples
        update_estimates!(withi, withouti, deltas, x, f, Xt, varyingFeatureGroups, nextSamples, sampleWeights)

        # keep track of our samples and optimize their allocation to minimize variance (Neyman allocation)
        totalSamples += sum(nextSamples)
        counts .+= nextSamples
        if totalSamples < nsamples
            vs = [var(a) for a in deltas]
            nextSamples = allocate_samples(vs, min(round(Int, nsamples/3), nsamples-totalSamples))
            #sum(abs((totals1-totals2) ./ counts))*maxStdDevFraction <= sqrt(sum(vs./counts)) || break
        else break end
    end
    r = Float64[(mean(withi[i])*withi[i].sumw)/deltas[i].sumw for i in 1:M]
    s = Float64[(mean(withouti[i])*withouti[i].sumw)/deltas[i].sumw for i in 1:M]

    # compute the Shapley values along with estimated variances of the estimates
    φ = zeros(length(featureGroups))
    φ[varyingInds] = g(r) - g(s)
    φ[varyingInds[r .== s]] = 0.0 # we know positions where r == s are are zero (even if g is undefined for that value)
    φVar = zeros(length(featureGroups))
    φVar[varyingInds] = [var(a) for a in deltas]./counts
    p = (r+s)./2
    φVar[varyingInds] ./= (g(p+1e-6) - g(p))./1e-6

    # If a base value was provided then we ensure that the total of all features equals f(x)
    if fnull != nothing
        trueSum = g(f(x)[1]) - g(fnull)
        β = inv(φ*φ' + I*(trueSum*1e-8))*φ*(sum(φ) - trueSum)
        φ .-= β.*φ
    end

    # return the Shapley values along with estimated variances of the estimates
    φ,φVar
end

"Distributes the given number of samples proportionally."
function allocate_samples(proportions, nsamples)
    counts = round(Int, nsamples*proportions/sum(proportions))
    total = sum(counts)
    for ind in randperm(length(counts))
        total != nsamples || break

        if total < nsamples
            counts[ind] += 1
            total += 1
        elseif counts[ind] > 0
            counts[ind] -= 1
            total -= 1
        end
    end
    counts
end

"Identifies which feature groups often vary from the observed value in data set."
function varying_feature_groups(x, Xt, featureGroups::Array{Array{Int64,1},1}; nsamples=100, threshold=5)
    N = size(Xt)[2]
    M = length(featureGroups)
    found = zeros(Int64, M)
    for i in 1:nsamples
        r = full(Xt[:,rand(1:N)])
        for j in 1:M
            for ind in featureGroups[j]
                if x[ind] != r[ind]
                    found[j] += 1
                end
            end
        end
    end
    find(found .> threshold)
end

"The core method that updates the Shapley value estimates."
function update_estimates!(withi, withouti, deltas, x, f, Xt, featureGroups, sampleCounts, sampleWeights)
    M = length(featureGroups)
    P = length(x)
    N = size(Xt)[2]
    @assert length(sampleCounts) == M "sampleCounts should be an array of counts for each feature group!"

    # build the synthentic samples
    inds = collect(1:M)
    r = zeros(P)
    unchangedCounts = zeros(Int64, M)
    unchangedInds = Array(Int64, M)
    synthLength = sum(sampleCounts)*2
    synthSamples = zeros(Float32, P, synthLength)
    synthInds = Array(Int64, synthLength)
    synthWeights = Array(Float64, synthLength)
    pos = 1
    for j in 1:maximum(sampleCounts)
        shuffle!(inds)
        rind = rand(1:N)
        r[:] = full(Xt[:,rind])

        for i in 1:M
            j <= sampleCounts[i] || continue

            # find where in the permutation we are
            ind = findfirst(inds, i)

            # see if this group is unchanged for this sample
            ginds = featureGroups[inds[ind]]
            unchanged = true
            for k in ginds
                if x[k] != r[k]
                    unchanged = false
                    break
                end
            end

            # if the current group does not change we can skip running the model
            if unchanged
                unchangedCounts[i] += 1
                observe!(deltas[i], 0.0, sampleWeights[rind]) # unchanged samples have a difference of zero
                continue
            end

            # save two synthetic samples with and without the current group replaced
            synthSamples[:,pos] = x
            synthSamples[:,pos+1] = x
            synthSamples[featureGroups[inds[ind]],pos+1] = r[featureGroups[inds[ind]]]
            for k in ind+1:M
                for l in featureGroups[inds[k]]
                    synthSamples[l,pos] = r[l]
                    synthSamples[l,pos+1] = r[l]
                end
            end

            # record which feature was varied for this sample, and the weight of the random sample
            synthInds[pos] = i
            synthWeights[pos] = sampleWeights[rind]

            pos += 2
        end
    end

    # run the provided function
    y = f(synthSamples[:,1:2*(sum(sampleCounts)-sum(unchangedCounts))])

    # sum the totals and keep an estimate of the variance differences
    for pos in 1:2:length(y)
        ind = synthInds[pos]
        observe!(withi[ind], y[pos], synthWeights[pos])
        observe!(withouti[ind], y[pos+1], synthWeights[pos])
        observe!(deltas[ind], y[pos] - y[pos+1], synthWeights[pos])
    end
end

# http://www.nowozin.net/sebastian/blog/streaming-mean-and-variance-computation.html
type MeanVarianceAccumulator
    sumw::Float64
    wmean::Float64
    t::Float64
    n::Int

    function MeanVarianceAccumulator()
        new(0.0, 0.0, 0.0, 0)
    end
end
function observe!(mvar::MeanVarianceAccumulator, value, weight)
    @assert weight >= 0.0
    q = value - mvar.wmean
    temp_sumw = mvar.sumw + weight
    r = q*weight / temp_sumw

    mvar.wmean += r
    mvar.t += q*r*mvar.sumw
    mvar.sumw = temp_sumw
    mvar.n += 1

    nothing
end
count(mvar::MeanVarianceAccumulator) = mvar.n
Base.mean(mvar::MeanVarianceAccumulator) = mvar.wmean
var(mvar::MeanVarianceAccumulator) = (mvar.t*mvar.n)/(mvar.sumw*(mvar.n-1))
std(mvar::MeanVarianceAccumulator) = sqrt(var(mvar))

end # module
