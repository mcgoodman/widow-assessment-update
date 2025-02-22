
library("tidyverse")
library("readxl")
library("r4ss")

dir.create(file.path("figures", "current_catches"))

# Data and settings ---------------------------------------

## PacFIN catch data
load(file.path("data_provided", "PacFIN", "PacFIN.WDOW.CompFT.12.Dec.2024.RData"))

## 2015 assessment data
catch_2015 <- read.csv(file.path("data_provided", "2015_assessment", "catch_by_state_fleet.csv"))

## 2019 assessment data
data_2019 <- r4ss::SS_readdat(file.path("data_provided", "2019_assessment", "2019widow.dat"))$catch

## Oregon catch reconstruction
catch_or <- read.csv(file.path("data_provided", "ODFW", "Oregon Commercial landings_431_2023.csv"))
gears_or <- read.csv(file.path("data_provided", "ODFW", "ODFW_Gear_Codes_PacFIN.csv"))

## ASHOP catches
catch_ashop <- read_excel(file.path("data_provided", "ASHOP", "A-SHOP_Widow_CatchData_removedConfidentialFields_1975-2024_012325.xlsx"))

## Gears and fleets ---------------------------------------

### Trawl gears, except shrimp trawls
trawl_names <- unique(catch.pacfin$GEAR_NAME)[grepl("TRAWL", unique(catch.pacfin$GEAR_NAME))]
trawl_names <- trawl_names[!grepl("SHRIMP", trawl_names)]

### Codes associated with trawl, hook & line, and net fleets
trawl_codes <- unique(catch.pacfin$PACFIN_GEAR_CODE[catch.pacfin$GEAR_NAME %in% trawl_names])
hk_ln_codes <- unique(catch.pacfin$PACFIN_GEAR_CODE[catch.pacfin$GEAR_NAME == "HOOK AND LINE"])
net_codes <- unique(catch.pacfin$PACFIN_GEAR_CODE[grepl("NET", catch.pacfin$GEAR_NAME)])

### Join gear codes
gear_codes <- unique(c(trawl_codes, hk_ln_codes, net_codes))

### Associate gear codes with fleets
fleets <- case_when(
  gear_codes == "MDT" ~ "midwater trawl",
  gear_codes %in% trawl_codes & gear_codes != "MDT" ~ "bottom trawl",
  gear_codes %in% hk_ln_codes ~ "hook and line",
  gear_codes %in% net_codes ~ "net"
)

fleet_lvls <- c("bottom trawl", "midwater trawl", "hake", "net", "hook and line")

# Clean and summarize PacFIN catch data -------------------

states <- c("California", "Oregon", "Washington")

## Filter out Puget sound, shrimp trawls
## Classify into fleets - need to add ASHOP data to hake fleet
catch_cleaned <- catch.pacfin |> 
  filter(
    !is.na(COUNTY_STATE) & 
      IOPAC_PORT_GROUP != "PUGET SOUND" & 
      PACFIN_GEAR_CODE %in% gear_codes
  ) |>
  mutate(
    state = states[match(COUNTY_STATE, toupper(substr(states, 1, 2)))],
    fleet = fleets[match(PACFIN_GEAR_CODE, gear_codes)], 
    fleet = ifelse(DAHL_GROUNDFISH_CODE %in% c("03", "17"), "hake", fleet), 
    fleet = factor(fleet , levels = fleet_lvls)
  ) |> 
  select(year = PACFIN_YEAR, state, fleet, landings_mt = LANDED_WEIGHT_MTONS)

## Catch by state, fleet, and year
catch_st_flt_yr <- catch_cleaned |> 
  group_by(year, state, fleet) |> 
  summarize(landings_mt = sum(landings_mt), .groups = "drop") |> 
  complete(year, state, fleet, fill = list(landings_mt = 0))

# Partition 1981-1999 Washington trawls -------------------

catch_2015$state <- states[match(catch_2015$state, toupper(substr(states, 1, 2)))]

trawl_ratio <- catch_2015 |> 
  filter(state == "Washington" & grepl("trawl", fleet) & year %in% 1979:1999) |> 
  group_by(year) |> 
  summarize(p_mdt = landings_mt[fleet == "midwater trawl"]/sum(landings_mt))

for (y in 1981:1999) {
  
  catch_st_flt_yr$landings_mt[
    catch_st_flt_yr$year == y & catch_st_flt_yr$state == "Washington" & grepl("trawl", catch_st_flt_yr$fleet)
  ] <- c(1 - trawl_ratio$p_mdt[trawl_ratio$year == y], trawl_ratio$p_mdt[trawl_ratio$year == y]) * 
    sum(
      catch_st_flt_yr$landings_mt[
        catch_st_flt_yr$year == y & catch_st_flt_yr$state == "Washington" & grepl("trawl", catch_st_flt_yr$fleet)
      ]
    )
    
}

trawl_ratio |> ggplot(aes(year, p_mdt)) + 
  geom_line() + geom_point() + 
  scale_x_continuous(breaks = 1979:1999) + 
  scale_y_continuous(limits = c(0, 1), expand = c(0, 0), breaks = seq(0, 1, 0.1)) + 
  theme_minimal() + 
  theme(
    panel.grid.minor = element_blank(), 
    panel.grid.major.x = element_blank(), 
    plot.background = element_rect(fill = "white", color = NA),
  ) + 
  ylab("Proportion midwater trawls")

ggsave("figures/current_catches/Washington_trawl_proportion.png", height = 5, width = 10, units = "in", dpi = 500)

# Replace Oregon 1981-1986 catches ------------------------

catch_or_cleaned <- catch_or |> 
  pivot_longer(starts_with("X"), names_prefix = "X", names_to = "CODE", values_to = "landings_mt") |> 
  left_join(mutate(gears_or, CODE = as.character(CODE)), by = "CODE") |> 
  mutate(
    gear = tolower(GEAR_DESCR),
    fleet = case_when(
      grepl("midwater", gear) ~ "midwater trawl",
      grepl("trawl", gear) ~ "bottom trawl",
      grepl("hook|line|troll", gear) ~ "hook and line",
      grepl("net", gear) & !grepl("trawl", gear) ~ "net"
    )
  ) |> 
  filter(YEAR %in% 1981:1986 & !is.na(fleet)) |> 
  group_by(year = YEAR, fleet) |> 
  summarize(landings_mt = sum(landings_mt), .groups = "drop") |> 
  mutate(state = "Oregon")

catch_st_flt_yr <- catch_st_flt_yr |> rows_update(catch_or_cleaned, by = c("state", "fleet", "year"))

# Add ASHOP data ------------------------------------------

catch_ashop_cleaned <- catch_ashop |> 
  group_by(year = YEAR) |> 
  summarize(landings_mt_ashop = sum(EXPANDED_SumOfEXTRAPOLATED_2SECTOR_WEIGHT_KG)/1000) |> 
  mutate(fleet = "hake")

catch_flt <- catch_st_flt_yr |> 
  group_by(year, fleet) |> 
  summarize(landings_mt = sum(landings_mt), .groups = "drop") |> 
  left_join(catch_ashop_cleaned, by = c("year", "fleet")) |> 
  mutate(
    landings_mt_ashop = ifelse(is.na(landings_mt_ashop), 0, landings_mt_ashop), 
    landings_mt = landings_mt + landings_mt_ashop
  ) |> 
  select(-landings_mt_ashop)

# Comparison to past assessments --------------------------

## Match fleets from 2019 assessment
catch_2019 <- data_2019 |> 
  filter(year %in% catch_cleaned$year) |> 
  mutate(fleet_name = factor(fleet_lvls[fleet], levels = fleet_lvls)) |> 
  filter(fleet_name != "hake")

## Aggregate catch by year, source
all_pacfin <- catch.pacfin |> group_by(year = PACFIN_YEAR) |> summarize(landings_mt = sum(LANDED_WEIGHT_MTONS))
all_cleaned <- catch_st_flt_yr |> group_by(year) |> summarize(landings_mt = sum(landings_mt))
all_2019 <- catch_2019 |> group_by(year) |> summarize(landings_mt = sum(catch))

## Aggregate ----------------------------------------------

### Pacfin vs. 2019 comparison, coastwide -----------------
  
catch_st_flt_yr |> 
  group_by(year, fleet) |> 
  summarize(landings_mt = sum(landings_mt)) |> 
  ggplot(aes(year, landings_mt)) + 
  geom_segment(aes(xend = year, y = 0, yend = landings_mt), data = all_2019, color = "red") + 
  geom_bar(aes(fill = fleet), stat = "identity", width = 1, color = "black") + 
  geom_point(aes(color = "2019 asessment"), data = all_2019, size = 2) + 
  geom_point(aes(color = "all PacFIN"), data = all_pacfin, size = 2) + 
  scale_fill_viridis_d(option = "mako", begin = 0.2, end = 0.8) + 
  scale_color_manual(values = c("red", "orange")) + 
  theme_classic() + 
  scale_y_continuous(expand = c(0, 0), breaks = seq(0, 25000, 5000), limits = c(0, 28000)) +
  scale_x_continuous(breaks = seq(1980, 2024, 2)) + 
  theme(axis.text.x = element_text(angle = 90, vjust = 0.5)) + 
  coord_cartesian(clip = "off") + 
  labs(color = "reference", fill = "fleet", y = "landings (metric tons)")

ggsave("figures/current_catches/PacFIN_landings_by_fleet.png", height = 5, width = 10, units = "in", dpi = 500)

catch_2019 |> 
  group_by(year, fleet_name) |> 
  summarize(landings_mt = sum(catch)) |>
  mutate(fleet_name = factor(fleet_name, levels = fleet_lvls)) |> 
  filter(fleet_name != "hake") |> 
  ggplot(aes(year, landings_mt)) + 
  geom_bar(aes(fill = fleet_name), stat = "identity", width = 1, color = "black") + 
  geom_point(aes(color = "cleaned PacFIN"), data = all_cleaned, size = 2) + 
  geom_point(aes(color = "all PacFIN"), data = all_pacfin, size = 2) + 
  scale_fill_viridis_d(option = "mako", begin = 0.2, end = 0.8) + 
  scale_color_manual(values = c("red", "orange")) + 
  theme_classic() + 
  scale_y_continuous(expand = c(0, 0), breaks = seq(0, 25000, 5000), limits = c(0, 28000)) +
  scale_x_continuous(breaks = seq(1980, 2024, 2)) + 
  theme(axis.text.x = element_text(angle = 90, vjust = 0.5)) + 
  coord_cartesian(clip = "off") + 
  labs(color = "reference", fill = "fleet", y = "landings (metric tons)")
  
ggsave("figures/current_catches/2019_landings_by_fleet.png", height = 5, width = 10, units = "in", dpi = 500)

## By state ------------------------------------------------

state_2015 <- catch_2015 |> group_by(year, state) |> summarize(landings_mt = sum(landings_mt))

catch_st_flt_yr |>  
  filter(fleet != "hake") |> 
  ggplot(aes(year, landings_mt)) + 
  geom_bar(aes(fill = fleet), stat = "identity") + 
  geom_point(aes(color = "2015 assessment"), data = filter(state_2015, year >= 1981)) + 
  facet_wrap(~state, ncol = 1) + 
  scale_color_manual(values = "red") +
  scale_fill_viridis_d(option = "mako", begin = 0.2, end = 0.8) + 
  theme_classic() + 
  theme(
    strip.background = element_blank(), 
    strip.text = element_text(hjust = 0, face = "bold")
  ) + 
  labs(y = "landings (mt)", color = "", fill = "fleet")
  
ggsave("figures/current_catches/landings_by_state_fleet.png", height = 6, width = 10, units = "in", dpi = 500)

## Correlation --------------------------------------------

### All years ---------------------------------------------

state_fleet_joined <- catch_2015 |>
  rename(landings_2015 = landings_mt) |> 
  right_join(rename(catch_st_flt_yr, landings_pacfin = landings_mt), by = c("year", "state", "fleet"))

state_fleet_joined |> 
  filter(!is.na(landings_2015)) |> 
  ggplot(aes(landings_2015, landings_pacfin)) + 
  geom_abline(intercept = 0, slope = 1) +
  geom_point(aes(color = fleet)) + 
  facet_wrap(~state, nrow = 1) + 
  coord_fixed() + 
  theme_bw() + 
  theme(
    strip.background = element_blank(), 
    strip.text = element_text(hjust = 0, face = "bold")
  ) + 
  labs(x = "2015 landings (mt)", y = "Reconstructed landings (mt)") + 
  scale_color_viridis_d(option = "mako", begin = 0.2, end = 0.8)

ggsave("figures/current_catches/cor_landings_by_state_fleet.png", height = 4, width = 10, units = "in", dpi = 500)

### 2000 onward -------------------------------------------

state_fleet_joined |> 
  filter(year >= 2000 & !is.na(landings_2015)) |> 
  ggplot(aes(landings_2015, landings_pacfin)) + 
  geom_abline(intercept = 0, slope = 1) +
  geom_point(aes(color = fleet)) + 
  facet_wrap(~state, nrow = 1, scales = "free") + 
  theme_bw() + 
  theme(
    strip.background = element_blank(), 
    strip.text = element_text(hjust = 0, face = "bold")
  ) + 
  labs(x = "2015 landings (mt)", y = "Reconstructed landings (mt)") + 
  scale_color_viridis_d(option = "mako", begin = 0.2, end = 0.8)
