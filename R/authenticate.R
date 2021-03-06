# Copyright 2014 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the 'License');
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an 'AS IS' BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

.authStore <- new.env()

.APIScope <- "https://www.googleapis.com/auth/genomics"

#' Returns the standard location for application default credentials as
#' generated by the gcloud CLI tool.
#' @return File path for credentials json.
#' @examples
#' defaultGcloudCredsPath()
defaultGcloudCredsPath <- function() {
  gcloudCredsPath <- Sys.getenv("GOOGLE_APPLICATION_CREDENTIALS")
  if ((nchar(gcloudCredsPath) > 0)) {
    if (file.exists(gcloudCredsPath)) {
      return(gcloudCredsPath)
    } else {
      warning(paste("GOOGLE_APPLICATION_CREDENTIALS environment variable",
                    "points to a non-existent file; ignoring the value."))
    }
  }

  if (.Platform$OS.type == "windows") {
    rootDir <- Sys.getenv("APPDATA")
  } else {
    rootDir <- file.path(Sys.getenv("HOME"), ".config")
  }

  return(file.path(rootDir, "gcloud", "application_default_credentials.json"))
}

#' Configure how to authenticate for Google Genomics API.
#'
#' Follow the sign up instructions at
#'   \url{https://cloud.google.com/genomics/install-genomics-tools}.
#'
#'   There are four primary ways, in order of preference, of authenticating:
#'
#'   1. When running on Google Compute Engine, configure your VM to be
#'   authenticated at the time of initial setup. See
#'   \url{https://cloud.google.com/compute/docs/access/create-enable-service-accounts-for-instances#using}.
#'
#'   2. Use the gcloud tool to generate application default credentials. If the
#'   generated file is not in its standard location, you can set the environment
#'   variable GOOGLE_APPLICATION_CREDENTIALS with its path, or provide the
#'   gcloudCredsPath argument.
#'
#'   3. For public data, use a public API key from the project that you want to
#'   access. You can either set the GOOGLE_API_KEY environment variable, or
#'   provide the apiKey argument. Does not work with gRPC.
#'
#'   4. Download secrets file (native application or service account) or
#'   provide the clientId and clientSecret pair. See
#'   \url{https://cloud.google.com/genomics/downloading-credentials-for-api-access}.
#'   Native application credentials should only be used when accessing data for
#'   which your own account is not authorized.
#'
#'   This method is called with default arguments at package load time.
#'
#' @param file Client secrets file obtained from Google Developer Console. This
#'   file could be for a native application or a service account. If this file
#'   is not present, clientId and clientSecret must be provided for native
#'   application credentials.
#' @param clientId Client ID from Google Developer Console, overridden if file
#'   is provided.
#' @param clientSecret Client Secret from Google Developer Console, overridden
#'   if file is provided.
#' @param invokeBrowser If TRUE or not provided, the default browser is invoked
#'   with the auth URL iff the \code{\link[httpuv]{httpuv}} package is
#'   installed (suggested). If FALSE, a URL is output which needs to be copy
#'   pasted in a browser, and the resulting token needs to be pasted back into
#'   the R session. With both the options, you will still need to login to your
#'   Google account if not logged in already.
#' @param apiKey Public API key that can be used to call the Genomics API for
#'   public datasets. This method of authentication does not need you to login
#'   to your Google account. Providing this key overrides all other arguments.
#' @param gcloudCredsPath Path to the generated json file with application
#'   default credentials.
#' @param tryGCEServiceAccount If TRUE, will try checking if this is a GCE VM
#'   instance with a valid service account. If valid credentials are found,
#'   will use them over all other options.
#' @return TRUE if successful, FALSE if not.
#' @examples
#' apiKey <- Sys.getenv("GOOGLE_API_KEY")
#' if (!is.na(apiKey) && nchar(apiKey)>0) {
#'   authenticate(apiKey=apiKey)
#' }
#' \dontrun{
#' authenticate()
#' authenticate(file="clientSecrets.json")
#' authenticate(file="clientSecrets.json", invokeBrowser=FALSE)
#' authenticate(clientId="abc", clientSecret="xyz", invokeBrowser=FALSE)
#' }
authenticate <- function(file, clientId, clientSecret, invokeBrowser,
                         apiKey=Sys.getenv("GOOGLE_API_KEY"),
                         gcloudCredsPath=defaultGcloudCredsPath(),
                         tryGCEServiceAccount=TRUE) {
  rm(list = ls(name=.authStore), envir=.authStore)

  .authStore$use_api_key <- FALSE

  if (isTRUE(tryGCEServiceAccount) && GCEServiceAccountAuthenticate()) {
    message("Configured GCE Service Account.")
    return(TRUE)
  }

  # Check for credentials in order of preference.
  appDefaultCreds <- NULL
  serviceAccount <- FALSE
  if (nchar(gcloudCredsPath) > 0 && file.exists(gcloudCredsPath)) {
    appDefaultCreds <- fromJSON(file=gcloudCredsPath)
    if (appDefaultCreds$type == "authorized_user") {
      .authStore$json_refresh_token <- appDefaultCreds
    } else if (appDefaultCreds$type == "service_account") {
      serviceAccount <- TRUE
      clientSecrets <- appDefaultCreds
      appDefaultCreds <- NULL
    } else {
      stop("Invalid application default credentials file found at ",
           gcloudCredsPath)
    }
  } else if (is.character(apiKey) && nchar(apiKey) > 0) {
    .authStore$use_api_key <- TRUE
    .authStore$api_key <- apiKey

    if (isTRUE(getOption("google_genomics_use_grpc"))) {
      warning(paste0("Removing gRPC as default because gRPC ",
                     "does not work with API keys."))
    }
    options("google_genomics_use_grpc"=FALSE)

    message("Configured public API key.")
    return(TRUE)
  } else if (!missing(file)) {
    clientSecrets <- fromJSON(file=file)
    serviceAccount <- !is.null(clientSecrets$type) &&
        clientSecrets$type == "service_account"
    if (!serviceAccount) {
      clientId <- clientSecrets$installed$client_id
      clientSecret <- clientSecrets$installed$client_secret
    }
  } else if (missing(clientId) || missing(clientSecret)) {
    return(FALSE)
  }

  # Get oauth token.
  endpoint <- oauth_endpoints("google")
  if (!is.null(appDefaultCreds)) {
    app <- oauth_app("google", appDefaultCreds$client_id,
                     appDefaultCreds$client_secret)
    params <- list(scope=.APIScope, user_params=NULL, type=appDefaultCreds$type,
                   use_oob=NULL, as_header=TRUE, use_basic_auth=FALSE)
    credentials <- list(access_token=NULL, expires_in=NULL,
                        refresh_token=appDefaultCreds$refresh_token,
                        token_type="Bearer")
    .authStore$google_token <- Token2.0$new(endpoint=endpoint, app=app,
                                            params=params,
                                            credentials=credentials,
                                            cache_path=FALSE)
  } else if (!serviceAccount) {
    if (missing(invokeBrowser)) {
      invokeBrowser <- "httpuv" %in% rownames(installed.packages())
    }

    app <- oauth_app("google", clientId, clientSecret)
    .authStore$google_token <- oauth2.0_token(
        endpoint, app,
        scope=.APIScope,
        use_oob=!invokeBrowser,
        cache=getOption("google_auth_cache_httr"))
  } else {
    .authStore$google_token <- oauth_service_token(
        endpoint, clientSecrets, scope=.APIScope)
  }

  message("Configured OAuth token.")
  return(TRUE)
}

authenticated <- function() {
  return(isTRUE(.authStore$use_api_key) || !is.null(.authStore$google_token))
}

# Attempt refreshing the token if the access token is near expiry.
attemptRefresh <- function() {
  if (!is.null(.authStore$google_token)) {
    currentTime <- as.integer(Sys.time())
    tokenTTL <- .authStore$google_token$credentials$expires_in
    if (!isTRUE(.authStore$do_not_refresh) &&
        (
          is.null(.authStore$google_token$credentials$access_token)
          || is.null(.authStore$last_refresh)
          || .authStore$last_refresh + 0.8 * tokenTTL < currentTime
        )) {
      .authStore$google_token$refresh()
      .authStore$last_refresh <- currentTime
    }
    # Do not attempt refresh again if this attempt was unsuccessful.
    if (is.null(.authStore$google_token$credentials$access_token)) {
      .authStore$do_not_refresh <- TRUE
    }
  }
}

# Inherits from httr::TokenServiceAccount and overrides the refresh
# mechanism to fetch a token from the GCE metadata servers.
TokenGCE <- R6::R6Class("TokenGCE", inherit = TokenServiceAccount, list(
  secrets = NULL,
  initialize = function(credentials) {
    stopifnot(!is.null(credentials))
    self$credentials <- credentials
  },
  refresh = function() {
    self$credentials <- GCEServiceAccountCredentials()
    stopifnot(!is.null(self$credentials))
  }
))

# Fetches a valid token from GCE metadata servers, NULL if none were found.
GCEServiceAccountCredentials <- function() {
  metadataURLRoot <-
    "http://metadata/computeMetadata/v1/instance/service-accounts/"
  metadataConfig <- add_headers("Metadata-Flavor"="Google")

  response <- NULL
  try(response <- GET(metadataURLRoot, metadataConfig), silent=TRUE)
  if (is.null(response) || (status_code(response) != 200)) {
    return(NULL)
  }

  universalScope <- "https://www.googleapis.com/auth/cloud-platform"
  response <- content(response, as="text", encoding="UTF-8")
  serviceAccounts <- strsplit(response, "\n")[[1]]
  for (serviceAccount in serviceAccounts) {
    response <- GET(paste0(metadataURLRoot, serviceAccount, "scopes"),
                    metadataConfig)
    stopifnot(status_code(response) == 200)
    scopes <-
      strsplit(content(response, as="text", encoding="UTF-8"), "\n")[[1]]
    if (any(scopes %in% c(universalScope, .APIScope))) {
      response <- GET(paste0(metadataURLRoot, serviceAccount, "token"),
                      metadataConfig)
      stopifnot(status_code(response) == 200)
      return(content(response))
    }
  }

  # No service accounts on this instance have the right scopes.
  return(NULL)
}

# Stores the token from GCE metadata server. Returns TRUE if successful,
# FALSE otherwise.
GCEServiceAccountAuthenticate <- function() {
  credentials <- GCEServiceAccountCredentials()
  if (is.null(credentials)) {
    return(FALSE)
  }

  .authStore$google_token <- TokenGCE$new(credentials=credentials)
  return(TRUE)
}

# Create a list of various credentials for use by GRPC.
getGRPCCreds <- function() {
  if (!authenticated()) {
    stop("You are not authenticated; see ?GoogleGenomics::authenticate.")
  }

  attemptRefresh()

  json_refresh_token <- NULL
  if (!is.null(.authStore$json_refresh_token)) {
    json_refresh_token <- toJSON(.authStore$json_refresh_token)
  }
  # The elements are referenced by name in C++ code; order is not important.
  list(api_key=.authStore$api_key,
       json_refresh_token=json_refresh_token,
       access_token=.authStore$google_token$credentials$access_token)
}
