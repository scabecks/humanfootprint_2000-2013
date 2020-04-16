#/bin/bash
#### This is GRASS GIS script to recreate the layers to rebuild the HFP for year 2013 ####
#### To change year simply change the date in the code in a text editor ####

#############################################################
####External data to be be loaded to your GRASS database ####
#############################################################
# change paths to data on your machine as required

# Land Mask
r.in.gdal input=$PWD/coastlines.tif output=coastlines -o --overwrite

# Shoreline
r.in.gdal input=$PWD/shoreline.tif output=shoreline -o --overwrite

# DMSP data - data has been intercalibrated between years; values below 6 have been re-classed as 0 (low-end noise in the light data)
r.in.gdal input=$PWD/elvidge2013_dmsp.tif output=elvidge2013_dmsp -o --overwrite

# Crops Data (MERIS)
r.in.gdal input=$PWD/2013_meris_lc.tif output=2013_meris_lc -o --overwrite

# Pastures data
r.in.gdal input=$PWD/pastures2000_filled.tif output=pastures2000_filled -o --overwrite

# Population Density
r.in.gdal input=$PWD/gpwv4_popden_2013.tif output=gpwv4_popden_2013 -o --overwrite

# Navigable Rivers
r.in.gdal input=$PWD/rivers_nav.tif output=rivers_nav -o --overwrite

# Roads
r.in.gdal input=$PWD/roads_osm_groads_union.tif output=roads -o --overwrite

# Railways
r.in.gdal input=$PWD/railways.tif output=railways -o --overwrite

#################################
#### Commands to Build Layers####
#################################

##################################
##### Create Ocean/Lake raster####
##################################

r.reclass input=coastlines output=water_lakes rules=$PWD/reclass_files/ocean_reclass.txt --o

##################################
##### Mask all land areas ########
##################################

echo "Creating Mask of Coastlines"
r.mask raster=coastlines maskcats=1 --o # Use mask of coastlines to limit all processing to coastlines areas.

################################
#### Urban/Built Areas Layer####
################################
echo "Calculating built areas in year 2013"
r.mapcalc "2013_built_areas = if(elvidge2013_dmsp > 20,10,0)" --overwrite

#########################################
####Crops Layer (based on MERIS)####
#########################################
echo "Calculating cropland areas in year 2013"
# NOTE class 10 = Croplands, rainfed, 20 = Cropland, irrigated or post-flooding
r.mapcalc "crops_meris2013 = if(2013_meris_lc == 10 | 2013_meris_lc == 11 | 2013_meris_lc == 12 | 2013_meris_lc == 20, 7, 0)" --overwrite
# Apply hierarchy - Urban > Crops > Pastures
r.mapcalc "crops_meris2013 = if(2013_built_areas > 0, 0, crops_meris2013)" --overwrite

#################################
####Navigable Waterways Layer####
#################################
r.mask -r # Remove mask if present


###################
####Coastlines#####
###################
echo "Calculating navigable coastlines in year 2013"
#Convert dmsp-ols values of >= 6 to values of 1
r.mapcalc "2013_dmsp = if(elvidge2013_dmsp >= 6, 1, null())" --overwrite

#Buffer dmsp areas by 4 km, classed as 1
r.grow input=2013_dmsp output=2013_dmsp_grow_4km radius=4 new=1 --overwrite
r.null map=2013_dmsp_grow_4km null=0

#Select shorelines which intersect with 4m buffered dmsp data
r.mapcalc "2013_popshoreline = if((2013_dmsp_grow_4km * shoreline) == 1,1, null())" --overwrite

#Grow ocean areas by 1 cell so overlaps with coastlines layer
r.grow input=water_lakes output=water_lakes_grow new=1 old=1 --overwrite

#Compute cost distance raster from populated shorelines, max distance 80km
r.cost -k input=water_lakes_grow start_raster=2013_popshoreline max_cost=80 output=2013_popcoast_dist_80km --overwrite

r.mask raster=coastlines maskcats=1 # Add MASK back in

#Reclass cost raster to 1 or null (within 80km or not)
r.reclass input=2013_popcoast_dist_80km rules=$PWD/waterways_reclass.txt output=2013_popcoast_80km_reclass --overwrite

#Select coastlines which are within 80km of populated coasts
r.mapcalc "2013_navcoast_80km = 2013_popcoast_80km_reclass * shoreline" --overwrite
r.null map=2013_navcoast_80km null=0

##############
####Rivers####
##############
echo "Calculating navigable rivers in year 2013"
#Select rivers which intersect with 4m buffered dmsp data, add in nav coasts
r.mapcalc "2013_poprivers = if((2013_dmsp_grow_4km * rivers_nav) + (rivers_nav * 2013_navcoast_80km) > 0, 1, null())" --overwrite

#Create rivers cost raster
r.reclass input=rivers_nav output=2013_rivers_cost rules=$PWD/rivers_reclass.txt --overwrite

#Grow populated rivers by 1 cell so overlaps with river cost layer
r.grow input=2013_rivers_cost output=rivers_cost radius=1 new=1 --overwrite

# Compute cost distance raster from populated river, max distance 80km
r.cost input=rivers_cost start_raster=2013_poprivers max_cost=80 output=2013_poprivers_dist_80km --overwrite

#Reclass cost raster to 1 or null (within 80km or not)
r.reclass input=2013_poprivers_dist_80km rules=$PWD/waterways_reclass.txt output=2013_poprivers_80km_reclass --overwrite

#Grow reclassed distance raster by one cell to ensure it overlaps with rivers
r.grow input=2013_poprivers_80km_reclass output=2013_poprivers_80km_reclass_grow new=1 old=1 --overwrite

#Select rivers which are within 80km of populated area or nav coasts
r.mapcalc "2013_navrivers_80km = if(2013_poprivers_80km_reclass_grow * (rivers_nav == 1) == 1, 1, 0)" --overwrite

######################################################
####Merge Rivers and Coastlines to Create NavWater####
######################################################
echo "Merging and calculating navigable waterways in year 2013"
r.patch input=2013_navrivers_80km,2013_navcoast_80km output=2013_navwaters -z --overwrite
r.null map=2013_navwaters setnull=0

# Find path distance outwards 15 (max distance of decay function per HFP)
r.cost input=MASK start_raster=2013_navwaters max_cost=15 output=2013_navwaters_dist --overwrite
r.null map=2013_navwaters_dist null=0

##### Two decay functions: one decaying to ~0.25, the other to 0 ####
# Apply decay function; nav river/coastlines get value of 4
#r.mapcalc "2013_navwaters_hfp_v1 = if(2013_navwaters_dist > 0 & 2013_navwaters_dist <= 15, 3.75*exp(-0.7931*2013_navwaters_dist)+0.25, if(2013_navwaters >= 1, 4, 0))" --overwrite
#r.null map=2013_navwaters_hfp_v1 null=0

# Apply decay function; nav river/coastlines get value of 4
r.mapcalc "2013_navwaters_hfp_v2 = if(2013_navwaters_dist > 0 & 2013_navwaters_dist <= 15, 4*exp(-1*2013_navwaters_dist), if(2013_navwaters >= 1, 4, 0))" --overwrite
r.null map=2013_navwaters_hfp_v2 null=0

##########################
####Nightlights Layer#####
##########################
echo "Calculating nightlight areas in year 2013"
# Quantiles computed for year 2013; use same breaks for other year classifications
#r.mapcalc "temp1 = if(elvidge2013_dmsp >= 6, elvidge2013_dmsp, null())" --overwrite # remove zero values as they are a majority of pixles
#r.quantile input=temp1 quantiles=10 | r.recode input=elvidge2013_dmsp output=nightlights2013 rules=- --overwrite

# OR (with a reclass file made in case the above doesnt work)
r.recode input=elvidge2013_dmsp output=nightlights2013 rules=$PWD/nightlights_reclass.txt --overwrite
r.null map=nightlights2013 null=0

######################
####Pastures Layer####
######################
echo "Calculating pasture land in year 2013"
r.mapcalc "pastures2013_hfp_meris = if(2013_built_areas > 0, 0, if(crops_meris2013 > 0, 0, pastures2000_filled))" --overwrite # Accounts for hierarchy Urban > Crops > Pasture

#################################
####Population Density Layers####
#################################
echo "Calculating population density scores in year 2013"
r.mapcalc "popden2013_hfp = if(3.333 * log(gpwv4_popden_2013 + 1, 10) > 10, 10, 3.333 * log(gpwv4_popden_2013 + 1, 10))" --overwrite
r.null map=popden2013_hfp null=0

#################
####Roadways#####
#################

echo "Calculating HFP scores for roadways in year 2013"
# Set 0 values (e.g., not roads) to null
r.mapcalc "roads_zeroed = if(roads == 1, 1, null())" --overwrite

# Find path distance outwards 15 (max distance of decay function per HFP)
r.cost input=MASK start_raster=roads_zeroed max_cost=15 output=roads_dist --overwrite

# Apply decay function; nav river/coastlines get value of 4
r.mapcalc "roads_hfp = if(roads_dist == 0, 8, if(roads_dist < 16 && roads_dist >=1, 3.75*exp(-1*(roads_dist-1))+0.25, 0))" --overwrite
r.null map=roads_hfp null=0

########################
####### Railways #######
########################
echo "Calculating HFP scores for railways"
# Make railway values 8; no decay function
r.mapcalc "railways_hfp = if(railways == 1, 8, 0)" --overwrite

#########################################################
####Combine all layers into new HFP2013 (Meris) Layer####
#########################################################
echo "Calculating final HFP values from pressure rasters in year 2013"
r.mapcalc "hfp2013_meris = 2013_built_areas + 2013_navwaters_hfp_v2 + crops_meris2013 + popden2013_hfp + roads_hfp + railways_hfp + nightlights2013 + pastures2013_hfp_meris" --overwrite

echo "Exporting rasters to individual Geotiffs"
#Write out to GeoTiff
r.out.gdal input=hfp2013_meris output=hfp2013_meris.tif format=GTiff type=Float32 createopt="COMPRESS=LZW,TILED=YES,NUM_THREADS=6" -m -c -f --overwrite

##############################################
####Write out Intermediary files to GeoTifs####
###############################################

r.out.gdal input=2013_built_areas output=built_areas2013.tif format=GTiff type=Byte createopt="COMPRESS=LZW,TILED=YES,NUM_THREADS=6" -m -c -f --overwrite

r.out.gdal input=crops_meris2013 output=crops_meris2013.tif format=GTiff type=Byte createopt="COMPRESS=LZW,TILED=YES,NUM_THREADS=6" -m -c -f --overwrite

r.out.gdal input=pastures2013_hfp_meris output=pastures_meris2013.tif format=GTiff type=Float32 createopt="COMPRESS=LZW,TILED=YES,NUM_THREADS=6" -m -c -f --overwrite

r.out.gdal input=2013_navwaters_hfp_v2  output=navwaters2013.tif format=GTiff type=Float32 createopt="COMPRESS=LZW,TILED=YES,NUM_THREADS=6" -m -c -f --overwrite

r.out.gdal input=popden2013_hfp  output=popden2013.tif format=GTiff type=Float32 createopt="COMPRESS=LZW,TILED=YES,NUM_THREADS=6" -m -c -f --overwrite

r.out.gdal input=nightlights2013  output=nightlights2013.tif format=GTiff type=Byte createopt="COMPRESS=LZW,TILED=YES,NUM_THREADS=6" -m -c -f --overwrite

r.out.gdal input=roads_hfp output=roads.tif format=GTiff type=Float32 createopt="COMPRESS=LZW,TILED=YES,NUM_THREADS=6" -m -c -f --overwrite

r.out.gdal input=railways_hfp output=railways_hfp.tif format=GTiff type=Byte createopt="COMPRESS=LZW,TILED=YES,NUM_THREADS=6" -m -c -f --overwrite
