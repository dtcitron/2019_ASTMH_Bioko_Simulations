####
# Clean Data - Regression Model of Trip Frequency
# Clean Data - Multinomial and Negative Binomial Modeling of Travel Flow
#
# Load in the aggregated trip data from cleanaggregated_2015_2018_travel_data.csv
#
# Model trip frequency based on probability of leaving: trip.counts/n
# and combine with the duration of the study period 56 days
# Return: a vector, broken down by areaId, of how frequently people leave home
#
# Model destination choice in 3 different ways:
# 1) Multinomial probability distribution: areaId -> ad2
#    a) weight by population to disambiguate areaId -> ad2 -> areaId
#    b) weight at random to disambiguate areaId -> ad2 -> areaId
# 2) Negative binomial distribution, with exponential cutoff: areaId -> ad2 
#    a) try fitting to population of areaId to full model to disambiguate areaId -> ad2 -> areaId
#    b) weight by areaId population to disambiguate areaId -> ad2 -> areaId
#    c) weight at random to disambiguate areaId -> ad2 -> areaId
#
# Each of these models will be represented as a probability distribution over where they go, given that they've left
# Each of these models will include mean predictions + 1 data table of draws
# 
#
# September 3, 2019
#
####

library(data.table)
library(here)
library(MASS)
library(nnet)

# Load aggregated travel data ####
travel.data <- fread(here("data/clean/aggregated_2015_2018_travel_data.csv"))
# merge with travel distance data set:
reg.travel.dist <- fread(here("data/clean/travel_dist_by_region.csv"))
travel.data <- merge(travel.data, reg.travel.dist, by = "areaId")
# Format:
# areaId
# ad2
# n - number surveyed, by year
# trip.counts - number of people who report leaving (for 2018, this is different from the sum over trips)
# t_eg etc. - number of reported trips to each destination
# pop - population, 2015 and 2018 censuses
# year - year of survey
# 

# here's syntax for how to aggregate over years
# travel.data[,.(n = sum(n), trip.counts = sum(trip.counts), t_eg = sum(t_eg), ti_mal = sum(ti_mal)), by = .(areaId, ad2)]

# list of all unique areaIds
areaId.list <- sort(unique(travel.data$areaId))

# Part 1: Modeling travel frequency for each areaId ####

# Frequency and Probability of Leaving ####
# Model: trip.counts/n
# The probability of leaving, modeled as a binomial choice
# Use as covariates the population, admin2 region, and time to Malabo:
# there are a few places where the total number of trips is more than the number of people
# another way to model this would be with a Poisson-type model of the frequency of leaving
# for now, let's just find the probability of leaving at all
freq.model.data <- travel.data
freq.model.data[trip.counts > n]$trip.counts <- freq.model.data[trip.counts > n]$n

h <- glm( cbind(trip.counts, n - trip.counts) ~ pop + ad2 + dist.mal,
          data = freq.model.data,
          family = binomial(link = logit))
freq.model.data$leave.prob <- h$fitted.values
freq.model.data$leave.freq <- h$fitted.values/56

# how different are the results from if we had aggregated over the years?
# how different are the results from if we had used trip.counts = sum for the 2018 data?
# makes almost no difference


# Perform draws
sampled.model <- mvrnorm(100, coefficients(h), vcov(h))
freq.samples.dt <- matrix(0, nrow = length(freq.model.data$areaId), ncol = 103)
freq.samples.dt[,1] <- freq.model.data$areaId # list of areaIds, across all 4 years
freq.samples.dt[,2] <- freq.model.data$year
freq.samples.dt[,3] <- h$fitted.values # mean value
h.draw <- h # here's where we alter the coefficients and resample
for(i in 1:100){
  h.draw$coefficients <- sampled.model[i,]
  freq.samples.dt[,(i+3)] <- predict(h.draw, freq.model.data, type = "response")
}
freq.samples.dt <- as.data.table(freq.samples.dt)
colnames(freq.samples.dt) <- c("areaId", "year", "draw.mean", paste0("draw.",as.character(1:100)))

# Write out frequency model estimates ####
fwrite(freq.samples.dt, file = here("data/clean/trip_frequency_model_estimates.csv"))

# What we've done here:
# freq.model.data = data table with mean freq (and probability) of leaving
# freq.samples.dt = data table with draws from same model of probability of leaving

# Part 2: Modeling destination choice ####
#
# Multinomial probability distribution ####
# Need to reformat the data somewhat to fit to a multinomial model:

mul.model.data <- travel.data[,.(areaId, pop, year, ad2, n, 
                                 t_eg, ti_ban, ti_lub, ti_mal, ti_mok, ti_ria, ti_ure,
                                 dist.eg, dist.ban, dist.lub, dist.mal, dist.mok, dist.ria, dist.ure)]
mul.model.data$dist.to.malabo <- mul.model.data$dist.mal
holder.1 <- melt(mul.model.data,
                 id.vars = c("areaId", "pop", "year", "ad2", "dist.eg", "dist.ban", "dist.lub", "dist.mal", "dist.mok", "dist.ria", "dist.ure"),
                 measure.vars = list(c("t_eg", "ti_ban", "ti_lub", "ti_mal", "ti_mok", "ti_ria", "ti_ure")),
                 value.name = c("counts"),
                 variable.name = "ix")

# Destination names and populations
dummy <- data.table(ix = c(1:7),
        dest.reg = c("t_eg", "ti_ban", "ti_lub", "ti_mal",  "ti_ria", "ti_mok", "ti_ure"),
        dest.pop = c(1071785, # this is the off-island population of equatorial guinea
          round(sum(mul.model.data[ad2 == "Baney"]$pop)/4), 
          round(sum(mul.model.data[ad2 == "Luba"]$pop)/4),
          round(sum(mul.model.data[ad2 %in% c("Malabo", "Peri")]$pop)/4),
          round(sum(mul.model.data[ad2 == "Moka"]$pop)/4),
          round(sum(mul.model.data[ad2 == "Riaba"]$pop)/4),
          round(sum(mul.model.data[ad2 == "Ureka"]$pop)/4)
          )  
        )
holder.1 <- merge(holder.1, dummy, by = "ix")
# Create dummy variable for location, the crazy aggregation function is for setting everything to binary
dummy.2 <- dcast(mul.model.data, areaId ~ ad2, fun.aggregate = function(ad2){return(as.numeric(length(ad2)>0))}, value.var = "ad2")

# multinom.data.predict is a dt that holds all of our data, and can be used to make predictions later
multinom.data.predict <- merge(holder.1, dummy.2, by = "areaId")

# multinom.data.fit is a dt that is the same as multinom.data.predict, but with the rows exploded out so that the multinom
# fitter can work as intended
#
# Now we explode out the number of rows
# https://stackoverflow.com/questions/44291855/melt-dataframe-multiple-columns-enhanced-new-functionality-from-data-tabl
multinom.data.fit <- multinom.data.predict[counts > 0]
multinom.data.fit <- multinom.data.fit[rep(seq(1, nrow(multinom.data.fit)), multinom.data.fit$counts)]
# and now we perform the fit:
# fitting probability of choosing destination (dest.reg) vs. 
# origin ad2, population, distance from malabo, distance to destination, destination population
mul.model <- multinom(dest.reg ~ pop + 
                        dist.eg + dist.ban + dist.lub + dist.mal + dist.mok + dist.ria + dist.ure + 
                        Baney + Luba + Malabo + Moka + Peri + Riaba + Ureka, 
                      data = multinom.data.fit, 
                      maxit = 1000)

# Extract Predictions
mul.predict <- predict(mul.model,
                       # newdata = holder.1[ix == "to"],
                       multinom.data.predict[dest.reg == "t_eg"],
                       type = "probs") # note that everything row does sum to 1

mul.predict <- as.data.table(mul.predict)
mul.predict$areaId <- multinom.data.predict[dest.reg == "t_eg"]$areaId
mul.predict$year <- multinom.data.predict[dest.reg == "t_eg"]$year
multinomial.areaId.reg.predictions <- merge(mul.model.data[,.(areaId, ad2, pop, year)], mul.predict, by = c("areaId", "year"))
# This "draw" will represent the mean model prediction
multinomial.areaId.reg.predictions$draw <- "draw.mean"

# Re-format the data to make the prediction analytically:
dat = multinom.data.predict[dest.reg == "t_eg", .(pop, dist.eg, dist.ban, dist.lub, dist.mal, dist.mok, dist.ria, dist.ure,
                                          Baney, Luba, Malabo, Moka, Peri, Riaba, Ureka)]
dat <- as.matrix(dat)
dat.matrix <- matrix(0, ncol = ncol(dat), nrow = nrow(dat))
for(i in 1:ncol(dat)){dat.matrix[,i] <- as.numeric(dat[,i])}
# add a bunch of 1s to the data, for the left-hand column is for the (intercept)
dat.matrix <- cbind(rep(1,nrow(dat.matrix)),dat.matrix)

# Perform draws ####
# store each of them in multinomial.areaId.reg.predictions with the ith draw indexed as draw.i
v <- vcov(mul.model)
coefs <- coefficients(mul.model)
draw.coefs.mat <- mvrnorm(n = 100, mu = as.vector(t(coefs)), Sigma = v)

# Loop over each of the draws
for(j in 1:100){
  # Pull out one set of coefficients
  draw.coefs <- matrix(draw.coefs.mat[j,], ncol = ncol(coefs), byrow = TRUE)
  # This is where the numerical prediction happens
  init.pred <- exp(draw.coefs %*% t(dat.matrix))
  init.pred <- rbind(rep(1, nrow(dat.matrix)),init.pred)
  draw.coef.pred <- t(init.pred)/rowSums(t(init.pred))
  # reformat, to combine with the other data set
  draw.coef.pred <- as.data.table(draw.coef.pred)
  colnames(draw.coef.pred) <- c("t_eg", "ti_ban", "ti_lub", "ti_mal", "ti_mok", "ti_ria", "ti_ure")
  draw.coef.pred$areaId <- multinom.data.predict[dest.reg == "t_eg"]$areaId #areaId.list
  draw.coef.pred$year <- multinom.data.predict[dest.reg == "t_eg"]$year
  draw.coef.pred$ad2 <- multinom.data.predict[dest.reg == "t_eg"]$ad2
  draw.coef.pred$pop <- multinom.data.predict[dest.reg == "t_eg"]$pop
  draw.coef.pred$draw <- paste0("draw.",as.character(j))
  setcolorder(draw.coef.pred, colnames(multinomial.areaId.reg.predictions))
  # combine
  multinomial.areaId.reg.predictions <- rbind(multinomial.areaId.reg.predictions, draw.coef.pred)
}

# Output multinomial model results ####
fwrite(multinomial.areaId.reg.predictions, here("data/clean/multinomial_predictions_by_destination_region.csv"))

# Modeling destination choice 1a ####
#
# construct transformation matrix, a 199 column x 7 row matrix
# each column will represent a different areaId
# each row will represent the ad2s
# the nonzero values will occur in the row corresponding to each areaId's ad2
# the nonzero values will be the fraction of the population which occurs in that areaId
#
# Use the script "region_to_areaId_mapping.R"
# source(region_to_areaId_mapping.R)

# First way: Multinomial probability distribution, weighting the choice of destination by destination areaId population
# draw.mat <- multinomial.areaId.reg.predictions[draw == "draw.mean" & year == 2018][,.(t_eg, ti_ban, ti_lub, ti_mal, ti_mok, ti_ria, ti_ure)]
# draw.mat <- as.matrix(draw.mat)
# draw.mat <- rbind(draw.mat, c(1,0,0,0,0,0,0)) # append a dummy row, representing travel by off-island folks

# and here's where the actual transformation occurs:
# pixel.2.pixel <- draw.mat %*% reg.2.pixel
# Check:
#dim(pixel.2.pixel)
#rowSums(pixel.2.pixel)


# Modeling destination choice 1b ####
# Second way: multinomial probability distribution, weighting choice o destination equally across areaIds
# reg.2.pixel.b <- reg.2.pixel
# reg.2.pixel.b[which(reg.2.pixel > 0)] = 1
# reg.2.pixel.b[which(reg.2.pixel > 0)]
# reg.2.pixel.b <- t(t(reg.2.pixel.b)/rowSums(t(reg.2.pixel.b)))
# reg.2.pixel.b <- reg.2.pixel.b/rowSums(reg.2.pixel.b)
# 
# pixel.2.pixel.b <- draw.mat %*% reg.2.pixel.b
# dim(pixel.2.pixel.b)
# rowSums(pixel.2.pixel.b)


# Negative Binomial Model ####
# Based on the summaries that Zhanhao put together, we are going to fit a gravity-type model 
# that splits the data at 20k distance traveled.  Above 20k, we will use a power-law dependence
# on the distance traveled.  Below 20k, we will use an exponential dependence on the distance
# traveled. We will also use origin ad2, origin population, destination population, and distance to malabo
nb.model.dat <- travel.data
nb.model.dat$dist.from.malabo <- nb.model.dat$dist.mal
nb.model.dat <- melt(nb.model.dat[,.(areaId, year, pop, ad2, n, dist.from.malabo,
                     t_eg, ti_ban, ti_lub, ti_mal, ti_mok, ti_ria, ti_ure,
                     dist.eg, dist.ban, dist.lub, dist.mal, dist.mok, dist.ria, dist.ure)],
                     id.vars = c("areaId", "year", "pop", "ad2", "n", "dist.from.malabo"),
                     measure.vars = list(c("t_eg", "ti_ban", "ti_lub", "ti_mal", "ti_mok","ti_ria", "ti_ure"),
                                         c("dist.eg", "dist.ban", "dist.lub", "dist.mal", "dist.mok", "dist.ria", "dist.ure")),
                     value.name = c("trip.counts","distance"),
                     variable.name = "destination"
)
dummy <- data.table(destination = c(1:7),
                    dest.reg = c("t_eg", "ti_ban", "ti_lub", "ti_mal",  "ti_ria", "ti_mok", "ti_ure"),
                    dest.pop = c(1071785, # this is the off-island population of equatorial guinea
                                 round(sum(nb.model.dat[ad2 == "Baney" & destination == 1]$pop)/4), 
                                 round(sum(nb.model.dat[ad2 == "Luba" & destination == 1]$pop)/4),
                                 round(sum(nb.model.dat[ad2 %in% c("Malabo", "Peri") & destination == 1]$pop)/4),
                                 round(sum(nb.model.dat[ad2 == "Moka" & destination == 1]$pop)/4),
                                 round(sum(nb.model.dat[ad2 == "Riaba" & destination == 1]$pop)/4),
                                 round(sum(nb.model.dat[ad2 == "Ureka" & destination == 1]$pop)/4)
                    )
)
nb.model.dat <- merge(nb.model.dat, dummy, by = "destination")

# I can now try to perform a fit using the offset:
#h.offset <- glm.nb(trip.counts ~ log(pop) + log(dest.pop) + log(distance) + ad2 + dist.from.malabo + offset(log((n+1)/pop)),
#                   data = nb.model.dat, link = log)

# Cutoff distance: 20k
# Split the model into short-distance and long-distance
# Use 2 different models with different dependencies on distance for the short- and long-distance models
# This, using AIC, is measurably better than including only a single model.
cutoff = 20000;
nb.model.dat.near <- nb.model.dat[distance < cutoff]
nb.model.dat.far <- nb.model.dat[distance >= cutoff]
# Perform the fit
h1.near <- glm.nb(trip.counts ~ log(pop) + log(dest.pop) + distance + ad2 + dist.from.malabo + offset(log((n+.1)/pop)), 
                  data = nb.model.dat.near, link = log)
h1.far <- glm.nb(trip.counts ~ log(pop) + log(dest.pop) + log(distance) + ad2 + dist.from.malabo + offset(log((n+.1)/pop)), 
                 data = nb.model.dat.far, link = log)

# this is the data set for prediction, which "scales up" by setting the sample size to the population
nb.model.dat.clone <- nb.model.dat
nb.model.dat.clone$n <- nb.model.dat.clone$pop
nb.model.dat.clone.near <- nb.model.dat.clone[distance < cutoff]
nb.model.dat.clone.far <- nb.model.dat.clone[distance >= cutoff]

# nb.areaId.reg.predictions - starting a new data frame which will old all output data ####
# Recombine the predictions into a data set
nb.model.dat.clone.near$gravity.model.trip.counts <- predict.glm(h1.near, nb.model.dat.clone.near, type = "response")
nb.model.dat.clone.far$gravity.model.trip.counts <- predict.glm(h1.far, nb.model.dat.clone.far, type = "response")
scaled.prediction <- rbind(nb.model.dat.clone.near, nb.model.dat.clone.far)[,.(areaId, year, ad2, pop, dest.reg, gravity.model.trip.counts)]
scaled.prediction[, weight := gravity.model.trip.counts/sum(gravity.model.trip.counts) , by = c("areaId", "year")]
scaled.prediction <- dcast(scaled.prediction, areaId + year + ad2 + pop ~ dest.reg, value.var = "weight")
scaled.prediction$draw <- "draw.mean"
# reformat to match multinomial.areaId.reg.predictions
nb.areaId.reg.predictions <- scaled.prediction

# Perform draws to get ensemble of negative binomial models: ####
sampled.model.near <- mvrnorm(250, coefficients(h1.near), vcov(h1.near))
sampled.model.far <- mvrnorm(250, coefficients(h1.far), vcov(h1.far))
freq.samples.dt.near <- matrix(0, nrow = length(nb.model.dat.near$areaId), ncol = 102)
freq.samples.dt.near[,1] <- nb.model.dat.near$areaId
freq.samples.dt.near[,2] <- h1.near$fitted.values
freq.samples.dt.far <- matrix(0, nrow = length(nb.model.dat.far$areaId), ncol = 102)
freq.samples.dt.far[,1] <- nb.model.dat.far$areaId
freq.samples.dt.far[,2] <- h1.far$fitted.values
# clone model to perform draws by altering coefficients
h1.near.draw <- h1.near
h1.far.draw <- h1.far
# loop over each of the draws:
j = 1 # keep track of the first 100 draws with sensible predictions for Ureka travel
for(i in 1:250){
  # perform the draw
  h1.near.draw$coefficients <- sampled.model.near[i,]
  h1.far.draw$coefficients <- sampled.model.far[i,]
  # fit with the draw
  nb.model.dat.clone.near$gravity.model.trip.counts <- predict(h1.near.draw, nb.model.dat.near, type = "response")
  nb.model.dat.clone.far$gravity.model.trip.counts <- predict.glm(h1.far.draw, nb.model.dat.clone.far, type = "response")
  # bind results back together
  scaled.prediction <- rbind(nb.model.dat.clone.near, nb.model.dat.clone.far)[,.(areaId, year, ad2, pop, dest.reg, gravity.model.trip.counts)]
  # rewrite as weights
  scaled.prediction[, weight := gravity.model.trip.counts/sum(gravity.model.trip.counts) , by = c("areaId", "year")]
  scaled.prediction <- dcast(scaled.prediction, areaId + year + ad2 + pop ~ dest.reg, value.var = "weight")
  
  # combine with data set
  # only combine if the Ureka travel is nonzero
  if(scaled.prediction[ad2 == "Ureka" & year == 2018]$t_eg > 0 & j <= 100){
    scaled.prediction$draw <- paste0("draw.",j, sep ="")
    nb.areaId.reg.predictions <- rbind(nb.areaId.reg.predictions, scaled.prediction)
    j <- j + 1}
}

# An important note: some of the draws for the negative binomial model have 0s for everything for Ureka
# This is because ureka has so little travel, maybe?  so many zeroes?
# we should probably forget those draws...
# but it isn't clear to me whether this is artificially biasing the fit in some way?

# Output binomial model results ####
fwrite(nb.areaId.reg.predictions, here("data/clean/negative_binomial_predictions_by_destination_region.csv"))


# Next Steps ####
# can also use the negative binomial model using the populations of each areaId as the destination
# populations; this is an alternative way