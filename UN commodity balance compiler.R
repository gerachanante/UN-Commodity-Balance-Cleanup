# 1. Load necessary libraries
library(curl)
library(data.table)

# 2. Define input and output paths
output_folder <- "T:/Latest datasets"

full_file     <- file.path(output_folder, "UN.Commodity balance.csv")
filtered_file <- file.path(output_folder, "UN.Commodity balance filtered.csv")

# 3. UNSD energy dataset URL
url <- "https://data.un.org/ws/rest/data/UNSD,DF_UNDATA_ENERGY/all/ALL/?detail=full&dimensionAtObservation=TIME_PERIOD&format=csv"

# 4. Download once
curl_download(url, full_file)

cat("Saved full dataset:", full_file, "\n")

dt <- fread(full_file, colClasses = "character")

years <- as.integer(substr(dt$TIME_PERIOD,1,4))

year_start <- 2000
year_end   <- 2100

filtered <- dt[years >= year_start & years <= year_end]

fwrite(filtered, filtered_file, quote = TRUE)

cat("Saved filtered dataset:", filtered_file)


