
# Load Packages -----------------------------------------------------------

pacman::p_load(
  sf,
  dplyr,
  tmap,
  tidyverse,
  countrycode,
  geosphere
)


# Load and Prepare Mine Data ----------------------------------------------

mines <- st_read("/data/jde/mines/global_mining_polygons_v2.gpkg")

africa_codes <- codelist %>%
  filter(continent == "Africa") %>%
  pluck("iso3c")

m <- mines |> filter(ISO3_CODE %in% africa_codes) |> st_centroid()



# Load and Prepare HydroBASINS Data ---------------------------------------

# https://data.hydrosheds.org/file/hydrobasins/standard/hybas_af_lev01-12_v1c.zip
lvl <- "12"
s <- st_read(paste0("/data/jde/hybas_lakes/hybas_lake_af_lev", lvl, "_v1c.shp"))
s <- st_make_valid(s)
s <- dplyr::filter(s, LAKE == 0)
d <- s |> select(HYBAS_ID, NEXT_DOWN) |> st_drop_geometry()

int <- st_intersects(s, m)

# Get the IDs of the basins that contain mines
treated_id <- s[["HYBAS_ID"]][lengths(int) > 0]



# Get Downstream/Upstream Basins ------------------------------------------

# Function that determines up- and downstream basins from NEXT_DOWN field

stream <- \(id, n = 1L, max = 11L, down = TRUE) {
 if(n >= max) return()
 if(down) {
   id_next <- d[["NEXT_DOWN"]][d[["HYBAS_ID"]] == id]
 } else { # Upstream
   id_next <- d[["HYBAS_ID"]][d[["NEXT_DOWN"]] %in% id]
 }
 if(all(id_next == 0) || length(id_next) == 0) return()
 return(c(id_next, Recall(id_next, n = n + 1L, max = max, down = down)))
}


stream_ordered <- function(id, n = 1L, max = 11L, down = TRUE) {
  if (n >= max) return(NULL)
  if (down) {
    id_next <- d[["NEXT_DOWN"]][d[["HYBAS_ID"]] == id]
  } else {
    id_next <- d[["HYBAS_ID"]][d[["NEXT_DOWN"]] %in% id]
  }
  if (all(id_next == 0) || length(id_next) == 0) return()
  
  results <- cbind(id_next, n)
  recursive_results <- Recall(id_next, n = n + 1L, max = max, down = down)
  if (!is.null(recursive_results)) {
    results <- rbind(results, recursive_results)
  }
  return(results)
}


# Get basins downstream and upstream of mines
downstream_ids <- lapply(treated_id, stream, down = TRUE)
upstream_ids <- lapply(treated_id, stream, down = FALSE)

# Tracking orders of basins
downstream_ids_ordered <- lapply(treated_id, stream_ordered, down = TRUE)
upstream_ids_ordered <- lapply(treated_id, stream_ordered, down = FALSE)



# Relevant Basins Shapefile -----------------------------------------------

su <- s |> mutate(
  status = ifelse(HYBAS_ID %in% treated_id, "mine",
    ifelse(HYBAS_ID %in% unlist(downstream_ids), "downstream",
      ifelse(HYBAS_ID %in% unlist(upstream_ids), "upstream",
        NA_character_)))
  )
su |> pull(status) |> table()

# Plot areas
# t <- st_crop(s, st_bbox(s |> filter(!is.na(status)))) |>
#   tm_shape() +
#   tm_fill("status", colorNA = "transparent") +
#   tm_borders() +
#   tm_shape(m) +
#   tm_dots(col = "black", border.col = "white", size = .3, shape = 23)
# tmap_save(t, paste0("basins_mines-l", lvl, ".png"))


# Extracting the treated and untreated basins to prepare in GEE
downstream_ids_vector <- unlist(downstream_ids)
upstream_ids_vector <- unlist(upstream_ids)

# extracting treated and untreated polygons 
relevant_basins <- su %>%
  filter(HYBAS_ID %in% c(treated_id, upstream_ids_vector, downstream_ids_vector))

write_sf(relevant_basins, "/data/jde/processed/relevant_basins.gpkg")

# Necessary for Earth Engine
write_sf(relevant_basins, "/data/jde/processed/relevant_basins.shp")



# Calculating Distances ---------------------------------------------------

# relevant_basins <- read_sf("~/minesfood/data/relevant_basins.gpkg")

downstream_ids_with_name <- downstream_ids
names(downstream_ids_with_name) <- treated_id

upstream_ids_with_name <- upstream_ids
names(upstream_ids_with_name) <- treated_id

relevant_basins_centroid <- st_centroid(relevant_basins)

basins_df <- relevant_basins_centroid

# Function to calculate the distance between two points
calculate_distance <- function(id1, id2, basins_df) {
  basin1 <- basins_df[basins_df$HYBAS_ID == id1,]
  basin2 <- basins_df[basins_df$HYBAS_ID == id2,]
  
  if (nrow(basin1) == 0 || nrow(basin2) == 0) {
    return(NA)  # If either basin is not found, return NA
  }
  
  # Extract coordinates
  coords1 <- st_coordinates(st_centroid(basin1))
  coords2 <- st_coordinates(st_centroid(basin2))
  
  # Calculate the distance
  dist <- distHaversine(coords1, coords2)
  return(dist)
}


# Downstream Distances ----------------------------------------------------

# Initialize an empty list to store the results
downstream_distances_list <- list()

# Loop through each basin and calculate distances to its downstream basins
for (basin_id in names(downstream_ids_with_name)) {
  downstream_ids <- downstream_ids_with_name[[basin_id]]
  
  if (!is.null(downstream_ids)) {
    for (downstream_id in downstream_ids) {
      distance <- calculate_distance(as.numeric(basin_id), as.numeric(downstream_id), basins_df)
      downstream_distances_list[[length(downstream_distances_list) + 1]] <- data.frame(
        basin_id = basin_id,
        downstream_id = downstream_id,
        distance = distance
      )
    }
  }
}

downstream_distances_df <- bind_rows(downstream_distances_list)


# Upstream Distances ------------------------------------------------------

# Initialize an empty list to store the results
upstream_distances_list <- list()

# Loop through each basin and calculate distances to its upstream basins
for (basin_id in names(upstream_ids_with_name)) {
  upstream_ids <- upstream_ids_with_name[[basin_id]]
  
  if (!is.null(upstream_ids)) {
    for (upstream_id in upstream_ids) {
      distance <- calculate_distance(as.numeric(basin_id), as.numeric(upstream_id), basins_df)
      upstream_distances_list[[length(upstream_distances_list) + 1]] <- data.frame(
        basin_id = basin_id,
        upstream_id = upstream_id,
        distance = distance
      )
    }
  }
}

# Combine the list into a data frame
upstream_distances_df <- bind_rows(upstream_distances_list)



# Merge Upstream Distances/Downstream Distances DFs -----------------------

downstream_distances_df <- downstream_distances_df %>%
  mutate(downstream = 1) %>%
  rename(HYBAS_ID = downstream_id)  %>%
  rename(mine_basin = basin_id)

upstream_distances_df <- upstream_distances_df %>%
  mutate(downstream = 0) %>%
  rename(HYBAS_ID = upstream_id) %>%
  rename(mine_basin = basin_id)

downstream_upstream_distance <- rbind(downstream_distances_df, upstream_distances_df)

downstream_upstream_distance <- downstream_upstream_distance %>%
  group_by(mine_basin) %>%
  summarize(mine_basin = first(mine_basin),
            HYBAS_ID = first(mine_basin),
            distance = 0,
            downstream = 1) %>%
  rbind(downstream_upstream_distance,.) 

write.csv(downstream_upstream_distance, "/data/jde/processed/downstream_upstream_distance.csv", row.names = FALSE)


# Lookup DF with Order ----------------------------------------------------

downstream_df_ordered <- do.call("rbind", downstream_ids_ordered) %>%
  data.frame() %>%
  mutate(id = rep(treated_id, lengths(downstream_ids_ordered)/2),
         status = "downstream") %>%
  relocate(id_next, id, status, n) %>%
  `colnames<-`(c("basin", "mine_basin", "status", "order"))

updstream_df_ordered <- do.call("rbind", upstream_ids_ordered) %>%
  data.frame() %>%
  mutate(id = rep(treated_id, lengths(upstream_ids_ordered)/2),
         status = "upstream") %>%
  relocate(id_next, id, status, n) %>%
  `colnames<-`(c("basin", "mine_basin", "status", "order"))

mine_df_ordered <- data.frame(treated_id, treated_id) %>%
  mutate(status = "mine",
         order = 0) %>%
  `colnames<-`(c("basin", "mine_basin", "status", "order"))

basins_ordered <- rbind(downstream_df_ordered, updstream_df_ordered, mine_df_ordered)


# Relevant Basins Shapefile with Order ------------------------------------

# If a basin is down- or upstream of multiple mines, it is considered to
# be only down- or upstream of the closest mine.

basins_ordered_unique <- basins_ordered %>%
  group_by(basin) %>%
  arrange(order, .by_group = T) %>%
  slice_head(n = 1)

so <- s %>%
  left_join(basins_ordered_unique, by = join_by("HYBAS_ID" == "basin")) %>%
  dplyr::filter(!is.na(status)) %>%
  dplyr::select(HYBAS_ID, mine_basin, status, order)


# For some reason, I cannot write this without getting errors,
# and I cannot currently resolve this --Max 20240701

# write_sf(so, "./data/relevant_basins_ordered.gpkg")
# write_sf(so, "/data/jde/processed/relevant_basins_ordered.shp")


# Add Order to Downstream/Upstream Distance DF ----------------------------

downstream_upstream_distance_ordered <- downstream_upstream_distance %>%
  mutate(mine_basin = as.double(mine_basin)) %>%
  full_join(basins_ordered_unique, by = join_by("HYBAS_ID" == "basin", "mine_basin")) %>%
  drop_na(status) %>%
  mutate_at(vars(downstream, distance), ~replace_na(., 0)) 

write.csv(downstream_upstream_distance_ordered, "/data/jde/processed/downstream_upstream_distance_ordered.csv", row.names = FALSE)

