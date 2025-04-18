#' Extract response values
#'
#' Extract response values from a \code{\link{brmsfit}} object.
#'
#' @param x A \code{\link{brmsfit}} object.
#' @param resp Optional names of response variables for which to extract values.
#' @param warn For internal use only.
#' @param ... Further arguments passed to \code{\link{standata}}.
#' @inheritParams posterior_predict.brmsfit
#'
#' @return Returns a vector of response values for univariate models and a
#'   matrix of response values with one column per response variable for
#'   multivariate models.
#'
#' @keywords internal
#' @export
get_y <- function(x, resp = NULL, sort = FALSE, warn = FALSE,  ...) {
  stopifnot(is.brmsfit(x))
  resp <- validate_resp(resp, x)
  sort <- as_one_logical(sort)
  warn <- as_one_logical(warn)
  args <- list(x, resp = resp, ...)
  args$re_formula <- NA
  args$check_response <- TRUE
  args$only_response <- TRUE
  args$internal <- TRUE
  sdata <- do_call(standata, args)
  if (warn) {
    if (any(paste0("cens", usc(resp)) %in% names(sdata))) {
      warning2("Results may not be meaningful for censored models.")
    }
  }
  Ynames <- paste0("Y", usc(resp))
  if (length(Ynames) > 1L) {
    out <- do_call(cbind, sdata[Ynames])
    colnames(out) <- resp
  } else {
    out <- sdata[[Ynames]]
  }
  old_order <- attr(sdata, "old_order")
  if (!is.null(old_order) && !sort) {
    stopifnot(length(old_order) == NROW(out))
    out <- p(out, old_order)
  }
  out
}

#' Prepare Response Data
#'
#' Prepare data related to response variables in \pkg{brms}.
#' Only exported for use in package development.
#'
#' @param x An \R object.
#' @param ... Further arguments passed to or from other methods.
#'
#' @return A named list of data related to response variables.
#'
#' @keywords internal
#' @export
data_response <- function(x, ...) {
  UseMethod("data_response")
}

#' @export
data_response.mvbrmsframe <- function(x, ...) {
  out <- list()
  for (i in seq_along(x$terms)) {
    c(out) <- data_response(x$terms[[i]], ...)
  }
  if (x$rescor) {
    out$nresp <- length(x$responses)
    out$nrescor <- out$nresp * (out$nresp - 1) / 2
  }
  out
}

#' @export
data_response.brmsframe <- function(x, data, check_response = TRUE,
                                    internal = FALSE, ...) {
  data <- subset_data(data, x)
  N <- nrow(data)
  # TODO: rename 'Y' to 'y'
  Y <- model.response(model.frame(x$respform, data, na.action = na.pass))
  out <- list(N = N, Y = unname(Y))
  if (is_binary(x$family)) {
    bin_levels <- x$frame$basis$resp_levels
    if (is.null(bin_levels)) {
      bin_levels <- levels(as.factor(out$Y))
    }
    # fixes issues #1298 and #1511
    if (is.numeric(out$Y) && length(bin_levels) == 1L) {
      if (0 %in% bin_levels) {
        # 1 as default event level
        bin_levels <- c(0, 1)
      } else {
        # 0 as default non-event level
        bin_levels <- c(0, bin_levels)
      }
    }
    out$Y <- as.integer(as_factor(out$Y, levels = bin_levels)) - 1
  }
  if (is_categorical(x$family)) {
    out$Y <- as.integer(as_factor(out$Y, levels = x$frame$basis$resp_levels))
  }
  if (is_ordinal(x$family) && is.ordered(out$Y)) {
    diff <- ifelse(has_extra_cat(x$family), 1L, 0L)
    out$Y <- as.integer(out$Y) - diff
  }
  if (check_response) {
    family4error <- family_names(x$family)
    if (is.mixfamily(x$family)) {
      family4error <- paste0(family4error, collapse = ", ")
      family4error <- paste0("mixture(", family4error, ")")
    }
    if (!allow_factors(x$family) && !is.numeric(out$Y)) {
      stop2("Family '", family4error, "' requires numeric responses.")
    }
    if (is_binary(x$family)) {
      if (any(!out$Y %in% c(0, 1))) {
        stop2("Family '", family4error, "' requires responses ",
              "to contain only two different values.")
      }
    }
    if (is_ordinal(x$family)) {
      extra_cat <- has_extra_cat(x$family)
      min_int <- ifelse(extra_cat, 0L, 1L)
      msg <- ifelse(extra_cat, "non-negative", "positive")
      if (any(!is_wholenumber(out$Y)) || any(out$Y < min_int)) {
        stop2("Family '", family4error, "' requires either ", msg,
              " integers or ordered factors as responses.")
      }
    }
    if (use_int(x$family)) {
      if (!all(is_wholenumber(out$Y))) {
        stop2("Family '", family4error, "' requires integer responses.")
      }
    }
    if (has_multicol(x$family)) {
      if (!is.matrix(out$Y)) {
        stop2("This model requires a response matrix.")
      }
    }
    if (is_simplex(x$family)) {
      if (!is_equal(rowSums(out$Y), rep(1, nrow(out$Y)))) {
        stop2("Response values in simplex models must sum to 1.")
      }
    }
    ybounds <- family_info(x$family, "ybounds")
    closed <- family_info(x$family, "closed")
    if (is.finite(ybounds[1])) {
      y_min <- min(out$Y, na.rm = TRUE)
      if (closed[1] && y_min < ybounds[1]) {
        stop2("Family '", family4error, "' requires response greater ",
              "than or equal to ", ybounds[1], ".")
      } else if (!closed[1] && y_min <= ybounds[1]) {
        stop2("Family '", family4error, "' requires response greater ",
              "than ", round(ybounds[1], 2), ".")
      }
    }
    if (is.finite(ybounds[2])) {
      y_max <- max(out$Y, na.rm = TRUE)
      if (closed[2] && y_max > ybounds[2]) {
        stop2("Family '", family4error, "' requires response smaller ",
              "than or equal to ", ybounds[2], ".")
      } else if (!closed[2] && y_max >= ybounds[2]) {
        stop2("Family '", family4error, "' requires response smaller ",
              "than ", round(ybounds[2], 2), ".")
      }
    }
    out$Y <- as.array(out$Y)
  }

  # data for addition arguments of the response
  # TODO: replace is.formula(x$adforms$term) pattern with has_ad_terms()
  if (has_trials(x$family) || is.formula(x$adforms$trials)) {
    if (!length(x$adforms$trials)) {
      stop2("Specifying 'trials' is required for this model.")
    }
    if (!is.formula(x$adforms$trials)) {
      stop2("Argument 'trials' is misspecified.")
    }
    trials <- get_ad_values(x, "trials", "trials", data)
    if (!is.numeric(trials)) {
      stop2("Number of trials must be numeric.")
    }
    if (any(!is_wholenumber(trials) | trials < 0)) {
      stop2("Number of trials must be non-negative integers.")
    }
    if (length(trials) == 1L) {
      trials <- rep(trials, nrow(data))
    }
    if (check_response) {
      if (is_multinomial(x$family)) {
        if (!is_equal(rowSums(out$Y), trials)) {
          stop2("Number of trials does not match the number of events.")
        }
      } else if (has_trials(x$family)) {
        if (max(trials) == 1L && !internal) {
          message("Only 2 levels detected so that family 'bernoulli' ",
                  "might be a more efficient choice.")
        }
        if (any(out$Y > trials)) {
          stop2("Number of trials is smaller than the number of events.")
        }
      }
    }
    out$trials <- as.array(trials)
  }
  if (has_cat(x$family)) {
    ncat <- length(get_cats(x$family))
    if (min(ncat) < 2L) {
      stop2("At least two response categories are required.")
    }
    if (!has_multicol(x$family)) {
      if (ncat == 2L && !internal) {
        message("Only 2 levels detected so that family 'bernoulli' ",
                "might be a more efficient choice.")
      }
      if (check_response && any(out$Y > ncat)) {
        stop2("Number of categories is smaller than the response ",
              "variable would suggest.")
      }
    }
    out$ncat <- ncat
  }
  if (has_thres(x$family)) {
    thres <- family_info(x, "thres")
    if (has_thres_groups(x$family)) {
      groups <- get_thres_groups(x)
      out$ngrthres <- length(groups)
      grthres <- get_ad_values(x, "thres", "gr", data)
      grthres <- factor(rename(grthres), levels = groups)
      # create an matrix of threshold indices per observation
      Jgrthres <- match(grthres, groups)
      nthres <- as.array(rep(NA, length(groups)))
      for (i in seq_along(groups)) {
        nthres[i] <- max(subset2(thres, group = groups[i])$thres)
      }
      if (check_response && any(out$Y > nthres[Jgrthres] + 1)) {
        stop2("Number of thresholds is smaller than required by the response.")
      }
      Kthres_cumsum <- cumsum(nthres)
      Kthres_start <- c(1, Kthres_cumsum[-length(nthres)] + 1)
      Kthres_end <- Kthres_cumsum
      Jthres <- cbind(Kthres_start, Kthres_end)[Jgrthres, , drop = FALSE]
      out$Jthres <- Jthres
    } else {
      nthres <- max(thres$thres)
      if (check_response && any(out$Y > nthres + 1)) {
        stop2("Number of thresholds is smaller than required by the response.")
      }
    }
    if (max(nthres) == 1L && !internal) {
      message("Only 2 levels detected so that family 'bernoulli' ",
              "might be a more efficient choice.")
    }
    out$nthres <- nthres
  }
  if (is.formula(x$adforms$cat)) {
    warning2("Addition argument 'cat' is deprecated. Use 'thres' instead. ",
             "See ?brmsformula for more details.")
  }

  if (is.formula(x$adforms$se)) {
    se <- get_ad_values(x, "se", "se", data)
    if (!is.numeric(se)) {
      stop2("Standard errors must be numeric.")
    }
    if (min(se) < 0) {
      stop2("Standard errors must be non-negative.")
    }
    out$se <- as.array(se)
  }
  if (is.formula(x$adforms$weights)) {
    weights <- get_ad_values(x, "weights", "weights", data)
    if (!is.numeric(weights)) {
      stop2("Weights must be numeric.")
    }
    if (min(weights) < 0) {
      stop2("Weights must be non-negative.")
    }
    if (get_ad_flag(x, "weights", "scale")) {
      weights <- weights / sum(weights) * length(weights)
    }
    out$weights <- as.array(weights)
  }
  if (is.formula(x$adforms$dec)) {
    dec <- get_ad_values(x, "dec", "dec", data)
    if (is.character(dec) || is.factor(dec)) {
      if (!all(unique(dec) %in% c("lower", "upper"))) {
        stop2("Decisions should be 'lower' or 'upper' ",
              "when supplied as characters or factors.")
      }
      dec <- ifelse(dec == "lower", 0, 1)
    } else {
      dec <- as.numeric(as.logical(dec))
    }
    out$dec <- as.array(dec)
  }
  if (is.formula(x$adforms$rate)) {
    denom <- get_ad_values(x, "rate", "denom", data)
    if (!is.numeric(denom)) {
      stop2("Rate denomiators should be numeric.")
    }
    if (isTRUE(any(denom <= 0))) {
      stop2("Rate denomiators should be positive.")
    }
    out$denom <- as.array(denom)
  }
  if (is.formula(x$adforms$cens) && check_response) {
    cens <- get_ad_values(x, "cens", "cens", data)
    cens <- prepare_cens(cens)
    if (!all(is_wholenumber(cens) & cens %in% -1:2)) {
      stop2(
        "Invalid censoring data. Accepted values are ",
        "'left', 'none', 'right', and 'interval'\n",
        "(abbreviations are allowed) or -1, 0, 1, and 2.\n",
        "TRUE and FALSE are also accepted ",
        "and refer to 'right' and 'none' respectively."
      )
    }
    if (length(cens) == 1L) {
      cens <- rep(cens, N)
    }
    if (length(cens) != N) {
      stop2("Censoring information needs to have length ",
            "equal to the number of data rows.")
    }
    out$cens <- as.array(cens)
    icens <- cens %in% 2
    if (any(icens) || has_interval_cens(x)) {
      # interval censoring is required
      y2 <- unname(get_ad_values(x, "cens", "y2", data))
      if (is.null(y2)) {
        stop2("Argument 'y2' is required for interval censored data.")
      }
      if (length(y2) != N) {
        stop2("Argument 'y2' needs to have length equal to the number of data rows.")
      }
      if (anyNA(y2[icens])) {
        stop2("'y2' should not be NA for interval censored observations.")
      }
      if (any(out$Y[icens] >= y2[icens])) {
        stop2("Left censor points must be smaller than right ",
              "censor points for interval censored data.")
      }
      y2[!icens] <- 0  # not used in Stan
      out$rcens <- as.array(y2)
    }
  }
  if (is.formula(x$adforms$trunc)) {
    lb <- as.numeric(get_ad_values(x, "trunc", "lb", data))
    ub <- as.numeric(get_ad_values(x, "trunc", "ub", data))
    if (any(lb >= ub)) {
      stop2("Truncation bounds are invalid: lb >= ub")
    }
    if (length(lb) == 1L) {
      lb <- rep(lb, N)
    }
    if (length(ub) == 1L) {
      ub <- rep(ub, N)
    }
    if (length(lb) != N || length(ub) != N) {
      stop2("Invalid truncation bounds.")
    }
    inv_bounds <- out$Y < lb | out$Y > ub
    if (check_response && isTRUE(any(inv_bounds))) {
      stop2("Some responses are outside of the truncation bounds.")
    }
    out$lb <- lb
    out$ub <- ub
  }
  if (is.formula(x$adforms$mi)) {
    sdy <- get_sdy(x, data)
    if (is.null(sdy)) {
      # missings only
      which_mi <- which(is.na(out$Y))
      out$Jmi <- as.array(which_mi)
      out$Nmi <- length(out$Jmi)
    } else {
      # measurement error in the response
      if (length(sdy) == 1L) {
        sdy <- rep(sdy, length(out$Y))
      }
      if (length(sdy) != length(out$Y)) {
        stop2("'sdy' must have the same length as the response.")
      }
      # all observations will have a latent score
      which_mi <- which(is.na(out$Y) | is.infinite(sdy))
      out$Jme <- as.array(setdiff(seq_along(out$Y), which_mi))
      out$Nme <- length(out$Jme)
      out$noise <- as.array(sdy)
      if (!internal) {
        out$noise[which_mi] <- Inf
      }
    }
    # bounds are required for predicting new missing values
    # not required in Stan right now as bounds are hard-coded there
    tbounds <- trunc_bounds(x, data, incl_family = TRUE)
    out$lbmi <- tbounds$lb
    out$ubmi <- tbounds$ub
    if (!internal) {
      # Stan does not allow NAs in data
      # use Inf to that min(Y) is not affected
      out$Y[which_mi] <- Inf
    }
  }
  if (is.formula(x$adforms$vreal)) {
    # vectors of real values for use in custom families
    vreal <- eval_rhs(x$adforms$vreal)
    vreal <- lapply(vreal$vars, eval2, data)
    names(vreal) <- paste0("vreal", seq_along(vreal))
    for (i in seq_along(vreal)) {
      if (length(vreal[[i]]) == 1L) {
        vreal[[i]] <- rep(vreal[[i]], N)
      }
      vreal[[i]] <- as.array(as.numeric(vreal[[i]]))
    }
    c(out) <- vreal
  }
  if (is.formula(x$adforms$vint)) {
    # vectors of integer values for use in custom families
    vint <- eval_rhs(x$adforms$vint)
    vint <- lapply(vint$vars, eval2, data)
    names(vint) <- paste0("vint", seq_along(vint))
    for (i in seq_along(vint)) {
      if (length(vint[[i]]) == 1L) {
        vint[[i]] <- rep(vint[[i]], N)
      }
      if (!all(is_wholenumber(vint[[i]]))) {
        stop2("'vint' requires whole numbers as input.")
      }
      vint[[i]] <- as.array(vint[[i]])
    }
    c(out) <- vint
  }
  if (length(out)) {
    resp <- usc(combine_prefix(x))
    out <- setNames(out, paste0(names(out), resp))
  }
  out
}

# data specific for mixture models
data_mixture <- function(bframe, data2, prior) {
  stopifnot(is.brmsterms(bframe))
  out <- list()
  if (is.mixfamily(bframe$family)) {
    families <- family_names(bframe$family)
    dp_classes <- dpar_class(names(c(bframe$dpars, bframe$fdpars)))
    if (!any(dp_classes %in% "theta")) {
      # estimate mixture probabilities directly
      take <- find_rows(prior, class = "theta", resp = bframe$resp)
      theta_prior <- prior$prior[take]
      con_theta <- eval_dirichlet(theta_prior, length(families), data2)
      out$con_theta <- as.array(con_theta)
      p <- usc(combine_prefix(bframe))
      names(out) <- paste0(names(out), p)
    }
  }
  out
}

# data for the baseline functions of Cox models
data_bhaz <- function(bframe, data, data2, prior) {
  out <- list()
  if (!is_cox(bframe$family)) {
    return(out)
  }
  y <- bframe$frame$resp$values
  bhaz <- family_info(bframe, "bhaz")
  bs <- bframe$basis$bhaz$basis_matrix
  out$Zbhaz <- bhaz_basis_matrix(y, bhaz$args, basis = bs)
  out$Zcbhaz <- bhaz_basis_matrix(y, bhaz$args, integrate = TRUE, basis = bs)
  out$Kbhaz <- NCOL(out$Zbhaz)
  groups <- bhaz$groups
  if (!is.null(groups)) {
    out$ngrbhaz <- length(groups)
    gr <- get_ad_values(bframe, "bhaz", "gr", data)
    gr <- factor(rename(gr), levels = groups)
    out$Jgrbhaz <- match(gr, groups)
    out$con_sbhaz <- matrix(nrow = out$ngrbhaz, ncol = out$Kbhaz)
    sbhaz_prior <- subset2(prior, class = "sbhaz", resp = bframe$resp)
    sbhaz_prior_global <- subset2(sbhaz_prior, group = "")
    con_sbhaz_global <- eval_dirichlet(sbhaz_prior_global$prior, out$Kbhaz, data2)
    for (k in seq_along(groups)) {
      sbhaz_prior_group <- subset2(sbhaz_prior, group = groups[k])
      if (nzchar(sbhaz_prior_group$prior)) {
        out$con_sbhaz[k, ] <- eval_dirichlet(sbhaz_prior_group$prior, out$Kbhaz, data2)
      } else {
        out$con_sbhaz[k, ] <- con_sbhaz_global
      }
    }
  } else {
    sbhaz_prior <- subset2(prior, class = "sbhaz", resp = bframe$resp)
    con_sbhaz <- eval_dirichlet(sbhaz_prior$prior, out$Kbhaz, data2)
    out$con_sbhaz <- as.array(con_sbhaz)
  }
  out
}

# Basis matrices for baseline hazard functions of the Cox model
# @param y vector of response values
# @param args arguments passed to the spline generating functions
# @param integrate compute the I-spline instead of the M-spline basis?
# @param basis optional precomputed basis matrix
# @return the design matrix of the baseline hazard function
bhaz_basis_matrix <- function(y, args = list(), integrate = FALSE,
                              basis = NULL) {
  # version check is required due to class name changes #1580
  require_package("splines2", version = "0.5.0")
  if (!is.null(basis)) {
    # perform predictions based on an existing basis matrix
    stopifnot(inherits(basis, "MSpline"))
    if (integrate) {
      # for predictions just the attributes are required
      # which are the same of M-Splines and I-Splines
      class(basis) <- c("matrix", "ISpline")
    }
    return(predict(basis, y))
  }
  stopifnot(is.list(args))
  args$x <- y
  if (is.null(args$Boundary.knots)) {
    # avoid 'knots' outside 'Boundary.knots' error (#1143)
    # we also need a smaller lower boundary knot to avoid lp = -Inf
    # the below choices are ad-hoc and may need further thought
    min_y <- min(y, na.rm = TRUE)
    max_y <- max(y, na.rm = TRUE)
    diff_y <- max_y - min_y
    lower_knot <- max(min_y - diff_y / 50, 0)
    upper_knot <- max_y + diff_y / 50
    args$Boundary.knots <- c(lower_knot, upper_knot)
  }
  if (integrate) {
    out <- do_call(splines2::iSpline, args)
  } else {
    out <- do_call(splines2::mSpline, args)
  }
  out
}

# extract baseline hazard information from data for storage in the model family
# @return a named list with elements:
#  args: arguments that can be passed to bhaz_basis_matrix
#  groups: optional names of the groups for which to stratify
extract_bhaz <- function(x, data) {
  stopifnot(is.brmsformula(x) || is.brmsterms(x), is_cox(x))
  if (is.null(x$adforms)) {
    x$adforms <- terms_ad(x$formula, x$family)
  }
  out <- list()
  if (is.null(x$adforms$bhaz)) {
    # bhaz is an optional addition term so defaults need to be listed here too
    out$args <- list(df = 5, intercept = TRUE)
  } else {
    out$args <- eval_rhs(x$adforms$bhaz)$flags
    gr <- get_ad_values(x, "bhaz", "gr", data)
    if (!is.null(gr)) {
      out$groups <- rename(levels(factor(gr)))
    }
  }
  out
}

# extract names of response categories
# @param x a brmsterms object or one that can be coerced to it
# @param data user specified data
# @return a vector of category names
extract_cat_names <- function(x, data) {
  stopifnot(is.brmsformula(x) || is.brmsterms(x))
  respform <- validate_resp_formula(x$formula)
  mr <- model.response(model.frame(respform, data))
  if (has_multicol(x)) {
    mr <- as.matrix(mr)
    out <- as.character(colnames(mr))
    if (!length(out)) {
      out <- as.character(seq_cols(mr))
    }
  } else {
    out <- levels(factor(mr))
  }
  out
}

# extract names of ordinal thresholds
# @param x a brmsterms object or one that can be coerced to it
# @param data user specified data
# @return a data.frame with columns 'thres' and 'group'
extract_thres_names <- function(x, data) {
  stopifnot(is.brmsformula(x) || is.brmsterms(x), has_thres(x))
  if (is.null(x$adforms)) {
    x$adforms <- terms_ad(x$formula, x$family)
  }
  nthres <- get_ad_values(x, "thres", "thres", data)
  if (any(!is_wholenumber(nthres) | nthres < 1L)) {
    stop2("Number of thresholds must be a positive integer.")
  }
  # has an extra category that is not part of the ordinal scale? (#1429)
  extra_cat <- has_extra_cat(x$family)
  grthres <- get_ad_values(x, "thres", "gr", data)
  if (!is.null(grthres)) {
    # grouping variable was specified
    if (!is_like_factor(grthres)) {
      stop2("Variable 'gr' in 'thres' needs to be factor-like.")
    }
    grthres <- factor(grthres)
    group <- levels(grthres)
    if (!length(nthres)) {
      # extract number of thresholds from the response values
      nthres <- rep(NA, length(group))
      for (i in seq_along(group)) {
        take <- grthres %in% group[i]
        nthres[i] <- extract_nthres(
          x$formula, data[take, , drop = FALSE],
          extra_cat = extra_cat
        )
      }
    } else if (length(nthres) == 1L) {
      # replicate number of thresholds across groups
      nthres <- rep(nthres, length(group))
    } else {
      # number of thresholds is a variable in the data
      for (i in seq_along(group)) {
        # validate values of the same level
        take <- grthres %in% group[i]
        if (length(unique(nthres[take])) > 1L) {
          stop2("Number of thresholds should be unique for each group.")
        }
      }
      nthres <- get_one_value_per_group(nthres, grthres)
    }
    group <- rep(rename(group), nthres)
    thres <- ulapply(unname(nthres), seq_len)
  } else {
    # no grouping variable was specified
    group <- ""
    if (!length(nthres)) {
      # extract number of thresholds from the response values
      nthres <- extract_nthres(x$formula, data, extra_cat = extra_cat)
    }
    if (length(nthres) > 1L) {
      stop2("Number of thresholds needs to be a single value.")
    }
    thres <- seq_len(nthres)
  }
  data.frame(thres, group, stringsAsFactors = FALSE)
}

# extract number of thresholds from the response values
# @param formula with the response on the LHS
# @param data a data.frame from which to extract responses
# @param extra_cat is the first category an extra (hurdle) category?
# @return a single value for the number of thresholds
extract_nthres <- function(formula, data, extra_cat = FALSE) {
  extra_cat <- as_one_logical(extra_cat)
  respform <- validate_resp_formula(formula)
  mr <- model.response(model.frame(respform, data))
  if (is_like_factor(mr)) {
    # the first factor level is the extra category
    diff <- ifelse(extra_cat, 2L, 1L)
    out <- length(levels(factor(mr))) - diff
  } else {
    # 0 is the extra category which does not affect max
    out <- max(mr) - 1L
  }
  if (out < 1L) {
    stop2("Could not extract the number of thresholds. Use ordered factors ",
          "or positive integers as your ordinal response and ensure that ",
          "more than on response category is present.")
  }
  out
}
