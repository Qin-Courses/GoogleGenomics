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

.onLoad <- function(libname, pkgname) {
  currentOptions <- options()
  defaultOptions <- list(
      google_genomics_endpoint="https://genomics.googleapis.com/v1",
      google_auth_cache_httr=file.path("~", ".r-google-auth-httr"),
      google_genomics_use_grpc=isGRPCAvailable())
  toset <- !(names(defaultOptions) %in% names(currentOptions))
  if (any(toset)) options(defaultOptions[toset])

  authenticate()

  invisible()
}

.onAttach <- function(libname, pkgname) {
    msg <- sprintf(
        "Package '%s' is deprecated and will be removed from Bioconductor
         version %s", pkgname, "3.8")
    .Deprecated(msg=paste(strwrap(msg, exdent=2), collapse="\n"))
}
