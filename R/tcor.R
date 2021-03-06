#' Thresholded Correlation
#'
#' Compute a thresholded correlation matrix, returning vector indices
#' and correlation values that exceed the specified threshold \code{t}.
#' If \code{y} is a matrix then the thresholded correlations
#' between the columns of \code{x} and the columns of \code{y} are computed,
#' otherwise the correlation matrix defined by the columns of \code{x} is computed.
#'
#' @param x an m by n real-valued dense or sparse matrix
#' @param y \code{NULL} (default) or a matrix with compatible dimensions to \code{x} (same number of rows). The default
#' is equivalent to \code{y=x} but more efficient.
#' @param t a threshold value for correlation, -1 < t < 1, but usually t is near 1 (see \code{include_anti} below).
#' @param p projected subspace dimension, p << n (if p >= n it will be reduced)
#' (Increase \code{p} to cut down the total number of candidate pairs evaluated.
#' at the expense of costlier matrix-vector products. See the notes on tuning \code{p}.)
#' @param include_anti logical value, if \code{TRUE} then return both correlated
#'        and anti-correlated values that meet the threshold in absolute value. NB Can be much more expensive when \code{TRUE}.
#' @param filter "local" filters candidate set sequentially,
#'  "distributed" computes thresholded correlations in a parallel code section which can be
#'  faster but requires the data matrix (see notes).
#' @param dry_run set \code{TRUE} to return statistics and truncated SVD for tuning
#' \code{p} (see notes).
#' @param rank when \code{TRUE}, the threshold \code{t} represents the top \code{t}
#' closest vectors, otherwise the threshold \code{t} specifies absolute correlation value.
#' @param max_iter when \code{rank=TRUE}, a portion of the algorithm may iterate; this
#' number sets the maximum numer of such iterations.
#' @param restart either output from a previous run of \code{tcor} with \code{dry_run=TRUE},
#' or direct output from from \code{\link{irlba}} used to restart the \code{irlba}
#' algorithm when tuning \code{p} (see notes).
#' @param ... additional arguments passed to \code{\link{irlba}}.
#'
#' @return A list with elements:
#' \enumerate{
#'   \item \code{indices} A three-column matrix. The first two columns contain
#'         indices of vectors meeting the correlation threshold \code{t},
#'         the third column contains the corresponding correlation value
#'         (not returned when \code{dry_run=TRUE}).
#'   \item \code{restart} The truncated SVD from \code{\link{irlba}}, used to restart
#'   the \code{irlba} algorithm (only returned when \code{dry_run=TRUE}).
#'   \item \code{longest_run} The largest number of successive entries in the
#'     ordered first singular vector within a projected distance defined by the
#'     correlation threshold. This is the minimum number of \code{n * p} matrix-vector
#'     products required by the algorithm.
#'   \item \code{tot} The total number of _candidate_ vectors that met
#'     the correlation threshold identified by the algorithm, subsequently filtered
#'     down to just those indices corresponding to values meeting the threshold.
#'   \item \code{t} The threshold value.
#'   \item \code{svd_time} Time spent computing truncated SVD.
#'   \item \code{total_time} Total run time.
#' }
#'
#' @note Register a parallel backend with \code{\link{foreach}} before invoking \code{\link{tcor}}
#' to run in parallel, otherwise it runs sequentially.
#' When \code{A} is large, use \code{filter=local} to avoid copying A to the
#' parallel R worker processes (unless the \code{doMC} parallel backend is used with
#' \code{\link{foreach}}).
#'
#' Specify \code{dry_run=TRUE} to compute and return a truncated SVD of rank \code{p},
#' a lower bound on the number of \code{n*p} matrix vector products required by the full algorithm, and a lower-bound
#' estimate on the number of unpruned candidate vector pairs to be evaluated by the algorithm. You
#' can pass the returned value back in as input using the \code{restart} parameter to avoid
#' fully recomputing a truncated SVD. Use these options to tune \code{p} for a balance between
#' the matrix-vector product work and pruning efficiency.
#'
#' When \code{rank=TRUE}, the method returns at least, and perhaps more than, the top \code{t} most correlated
#' indices, unless they couldn't be found within \code{max_iter} iterations.
#'
#' @seealso \code{\link{cor}}, \code{\link{tdist}}
#' @references \url{http://arxiv.org/abs/1512.07246} (preprint)
#' @examples
#' # Construct a 100 x 2,000 example matrix A:
#' set.seed(1)
#' s <- svd(matrix(rnorm(100 * 2000), nrow=100))
#' A <- s$u %*% (1 /( 1:100) * t(s$v)) 
#'
#' C <- cor(A)
#' C <- C * upper.tri(C)
#' # Compare i with x$indices below:
#' (i <- which(C >= 0.98, arr.ind=TRUE))
#' (x <- tcor(A, t=0.98))
#'
#' # Same example with thresholded correlation _and_ anticorrelation
#' (i <- which(abs(C) >= 0.98, arr.ind=TRUE))
#' (x <- tcor(A, t=0.98, include_anti=TRUE))
#'
#' # Example of tuning p with dry_run=TRUE:
#' x1 <- tcor(A, t=0.98, p=3, dry_run=TRUE)
#' print(x1$tot)
#' # 211, see how much we can reduce this without increasing p too much...
#' x1 <- tcor(A, t=0.98, p=5, dry_run=TRUE, restart=x1)
#' print(x1$tot)
#' # 39,  much better...
#' x1 <- tcor(A, t=0.98, p=10, dry_run=TRUE, restart=x1)
#' print(x1$tot)
#' # 3,   even better!
#'
#' # Once tuned, compute the full thresholded correlation:
#' x <- tcor(A, t=0.98, p=10, restart=x1)
#'
#' \dontrun{
#' # Optionally, register a parallel backend first:
#' library(doMC)
#' registerDoMC()
#' x <- tcor(A, t=0.98)  # Should now run faster on a multicore machine
#' }
#'
#' @importFrom irlba irlba
#' @importFrom stats cor
#' @importFrom Matrix colMeans
#' @export
tcor = function(x, y=NULL, t=0.99, p=10, include_anti=FALSE, filter=c("distributed", "local"),
                dry_run=FALSE, rank=FALSE, max_iter=4, restart, ...)
{
  filter = match.arg(filter)
  group = NULL
  if(!is.null(y))
  {
    group = c(rep(1L, ncol(x)), rep(-1L, ncol(y)))
    x = cbind(x, y) # XXX Future version: custom irlba matrix product instead for large matrices?
  }
  if(ncol(x) < p) p = max(1, floor(ncol(x) / 2 - 1))
  t0 = proc.time()
  mu = colMeans(x)
  s  = sqrt(apply(x, 2, crossprod) - nrow(x) * mu ^ 2) # col norms of centered matrix
  if(include_anti) filter_fun = function(v, t) abs(v) >= t
  else filter_fun = function(v, t) v >= t
  if(any(s < 10 * .Machine$double.eps)) stop("the standard deviation is zero for some columns")
  if(missing(restart)) L  = irlba(x, p, center=mu, scale=s, ...)
  else
  {
    # Handle either output from tcor(..., dry_run=TRUE), or direct output from irlba:
    if("restart" %in% names(restart)) restart = restart$restart
    L = irlba(x, p, center=mu, scale=s, v=restart, ...)
  }
  t1 = (proc.time() - t0)[[3]]

  if(rank)
  {
    N = t
    t = 0.99
  }
  iter = 1
  old_n = 0
  while(iter <= max_iter)
  {
# steps 2--7 of algorithm 2.1
    ans = two_seven(x, L, t, filter, dry_run=dry_run, filter_fun=filter_fun, anti=include_anti, group=group)
    ans$tot = old_n + ans$tot
    old_n = ans$tot
    if(dry_run) return(list(restart=L, longest_run=ans$longest_run, tot=ans$tot, t=t, svd_time=t1))
    if(!rank || (nrow(ans$indices) >= N)) break
    iter = iter + 1
    t = max(t - 0.02, -1)
  }
  ans$indices = ans$indices[order(ans$indices[,"val"], decreasing=TRUE),]
  c(ans, svd_time=t1, total_time=(proc.time() - t0)[[3]])
}
