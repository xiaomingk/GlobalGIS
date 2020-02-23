export GADM, NUTS, makeregions, makeregions_nuts, makeoffshoreregions, saveregions, loadregions

struct GADM{T}
    parentregions::Vector{T}
    subregionnames::NTuple{N,T} where N
end
GADM(regionnames::T...) where T = GADM(T[], regionnames)
GADM(parentregions::Vector{T}, subregionnames::T...) where T = GADM(parentregions, subregionnames)

struct NUTS{T}
    subregionnames::NTuple{N,T} where N
end
NUTS(regionnames::T...) where T = NUTS(regionnames)

const NOREGION = typemax(Int16)

function saveregions(regionname, regiondefinitionarray; autocrop=true, bbox=[-90 -180; 90 180])
    land = JLD.load(in_datafolder("landcover.jld"), "landcover")
    if !all(bbox .== [-90 -180; 90 180])
        autocrop = false         # ignore supplied autocrop option if user changed bbox
    end
    saveregions(regionname, regiondefinitionarray, land, autocrop, bbox)
end

function saveregions(regionname, regiondefinitionarray, landcover, autocrop, bbox)
    regions, regiontype = makeregions(regiondefinitionarray; allowmixed=(regionname=="Europe_background"))
    if autocrop
        # get indexes of the bounding box containing onshore region data with 3 degrees of padding
        lonrange, latrange = getbboxranges(regions, round(Int, 3/0.01))
    else
        latrange, lonrange = bbox2ranges(roundbbox(bbox,100), 100)          # TO DO: remove hardcoded raster density
    end
    landcover = landcover[lonrange, latrange]
    regions = regions[lonrange, latrange]

    if regionname != "Global_GADM0" && regionname != "Europe_background"
        if regiontype == :NUTS
            println("\nNUTS region definitions detected (using Europe_background region file)...")
            europeregions = loadregions("Europe_background")[1][lonrange, latrange]
            regions[(regions.==0) .& (europeregions.>0)] .= NOREGION
        elseif regiontype == :GADM
            println("\nGADM region definitions detected (using Global_GADM0 region file)...")
            globalregions = loadregions("Global_GADM0")[1][lonrange, latrange]
            regions[(regions.==0) .& (globalregions.>0)] .= NOREGION
        end
    end

    # Find the closest region pixel for all non-region pixels (land and ocean)
    println("\nAllocate non-region pixels to the nearest region (for offshore wind)...")
    territory = regions[feature_transform(regions.>0)]

    # Allocate ocean and lake pixels to the region with the closest land region.
    # Even VERY far offshore pixels will be allocated to whatever region is nearest, but
    # those areas still won't be available for offshore wind power because of the
    # requirement to be close enough to the electricity grid (or rather the grid proxy).
    offshoreregions = territory .* (landcover .== 0)

    if regionname != "Global_GADM0" && regionname != "Europe_background"
        # Allocate land pixels with region==0 to the closest land region.
        # This ensures that the regions dataset is pixel-compatible with the landcover dataset.
        regions = territory .* (landcover .> 0)
    end

    println("\nSaving regions and offshoreregions...")
    regionlist = Symbol.(regiondefinitionarray[:,1])

    JLD.save(in_datafolder("regions_$regionname.jld"), "regions", regions, "offshoreregions", offshoreregions,
                "regionlist", regionlist, "lonrange", lonrange, "latrange", latrange, compress=true)
end

function saveregions_global(; args...)
    println("Creating a global GADM region file to identify countries and land areas later...\n")
    g = readdlm(in_datafolder("gadmfields.csv"), ',', skipstart=1)
    gadm0 = unique(string.(g[:,2]))
    regiondefinitionarray = [gadm0 GADM.(gadm0)]
    saveregions("Global_GADM0", regiondefinitionarray; args..., autocrop=false)
    println("\nGlobal GADM region file saved.")

    println("\nCreating a 'background' NUTS region file to identify non-European land areas later...\n")
    regiondefinitionarray = [NUTS_Europe; non_NUTS_Europe]
    saveregions("Europe_background", regiondefinitionarray; args..., autocrop=false)
    println("\nEurope_background region file saved.")
end

function loadregions(regionname)
    jldopen(in_datafolder("regions_$regionname.jld"), "r") do file
        return read(file, "regions"), read(file, "offshoreregions"), read(file, "regionlist"),
                    read(file, "lonrange"), read(file, "latrange")
    end
end

function makeregions(regiondefinitionarray; allowmixed=false)
    regionnames, nutsdef, gadmdef = splitregiondefinitions(regiondefinitionarray)
    use_nuts, use_gadm = !all(isempty.(nutsdef)), !all(isempty.(gadmdef))
    regiontype =  (use_gadm && !use_nuts) ? :GADM  :
                  (use_nuts && !use_gadm) ? :NUTS  :
                  (use_nuts && use_gadm) ? :MIXED  :  :WEIRD
    !allowmixed && regiontype==:MIXED && error("Sorry, mixed NUTS & GADM definitions are not supported yet.")
    region = zeros(Int16, (36000,18000))    # hard code size for now
    if use_nuts
        nuts, subregionnames = read_nuts()
        makeregions_nuts!(region, nuts, subregionnames, nutsdef)
    end
    if use_gadm
        gadm, subregionnames = read_gadm()
        makeregions_gadm!(region, gadm, subregionnames, gadmdef)
    end
    return region, regiontype
end

function regions2matlab(gisregion)
    regions, offshoreregions, regionlist, lonrange, latrange = loadregions(gisregion)
    matopen(in_datafolder("regions_$gisregion.mat"), "w", compress=true) do file
        write(file, "regions", regions)
        write(file, "offshoreregions", offshoreregions)
        write(file, "regionlist", string.(regionlist))
        write(file, "lonrange", collect(lonrange))
        write(file, "latrange", collect(latrange))
    end
end

function splitregiondefinitions(regiondefinitionarray)
    regionnames = regiondefinitionarray[:,1]
    regiondefinitions = [regdef isa Tuple ? regdef : (regdef,) for regdef in regiondefinitionarray[:,2]]
    nutsdef = [Tuple(rd for rd in regdef if rd isa NUTS) for regdef in regiondefinitions]
    gadmdef = [Tuple(rd for rd in regdef if rd isa GADM) for regdef in regiondefinitions]
    return regionnames, nutsdef, gadmdef
end

function makeregions_gadm!(region, gadm, subregionnames, regiondefinitions)
    println("Making region index matrix...")
    regionlookup = build_inverseregionlookup(regiondefinitions)
    rows, cols = size(region)
    updateprogress = Progress(cols, 1)
    for c in randperm(cols)
        for r = 1:rows
            gadm_uid = gadm[r,c]
            (gadm_uid == 0 || gadm_uid == 78413 || region[r,c] > 0) && continue    # ignore Caspian Sea (weirdly classified as a region in GADM)
            reg0, reg1, reg2 = subregionnames[gadm_uid,:]
            regid = lookup_regionnames(regionlookup, reg0, reg1, reg2)
            if regid > 0
                region[r,c] = regid
            end
        end
        next!(updateprogress)
    end
end

function makeregions_nuts!(region, nuts, subregionnames, regiondefinitions)
    println("Making region index matrix...")
    regionlookup = Dict(r => i for (i,tuptup) in enumerate(regiondefinitions)
                                    for ntup in tuptup for r in ntup.subregionnames)
    rows, cols = size(region)
    updateprogress = Progress(cols, 1)
    for c in randperm(cols)
        for r = 1:rows
            nuts_id = nuts[r,c]
            (nuts_id == 0 || region[r,c] > 0) && continue
            reg = subregionnames[nuts_id]
            while length(reg) >= 2
                regid = get(regionlookup, reg, 0)
                if regid > 0
                    region[r,c] = regid
                    break
                end
                reg = reg[1:end-1]
            end
        end
        next!(updateprogress)
    end
end

function lookup_regionnames(regionlookup, reg0, reg1, reg2)
    v = get(regionlookup, (reg0, "*", "*"), 0)
    v > 0 && return v
    v = get(regionlookup, (reg0, reg1, "*"), 0)
    v > 0 && return v
    return get(regionlookup, (reg0, reg1, reg2), 0)
end

function build_inverseregionlookup(regiondefinitions)
    d = Dict{Tuple{String,String,String}, Int}()
    for reg = 1:length(regiondefinitions)
        for regdef in regiondefinitions[reg]
            parentregions, subregionnames = regdef.parentregions, regdef.subregionnames
            regions = ["*", "*", "*"]
            regions[1:length(parentregions)] = parentregions
            for s in subregionnames
                regions[length(parentregions)+1] = s
                d[regions...] = reg
            end
        end
    end
    return d
end
