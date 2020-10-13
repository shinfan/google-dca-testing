#!/bin/bash

# Copyright 2019 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

##
# system_tests.sh
# Runs CI checks for entire repository.
#
# Parameters
#
# [ARG 1]: Directory for the samples. Default: github/golang-samples.
# KOKORO_GFILE_DIR: Persistent filesystem location. (environment variable)
# KOKORO_KEYSTORE_DIR: Secret storage location. (environment variable)
# GOLANG_SAMPLES_GO_VET: If set, run code analysis checks. (environment variable)
##

set -ex

go version
date

export GO111MODULE=on # Always use modules.
export GOPROXY=https://proxy.golang.org
TIMEOUT=60m

# Also see trampoline.sh - system_tests.sh is only run for PRs when there are
# significant changes.
SIGNIFICANT_CHANGES=$(git --no-pager diff --name-only master..HEAD | grep -Ev '(\.md$|^\.github)' || true)
# CHANGED_DIRS is the list of significant top-level directories that changed,
# but weren't deleted by the current PR.
# CHANGED_DIRS will be empty when run on master.
CHANGED_DIRS=$(echo "$SIGNIFICANT_CHANGES" | tr ' ' '\n' | grep "/" | cut -d/ -f1 | sort -u | tr '\n' ' ' | xargs ls -d 2>/dev/null || true)

# List all modules in changed directories.
# If running on master will collect all modules in the repo, including the root module.
# shellcheck disable=SC2086
GO_CHANGED_MODULES="$(find ${CHANGED_DIRS:-.} -name go.mod)"
# If we didn't find any modules, use the root module.
GO_CHANGED_MODULES=${GO_CHANGED_MODULES:-./go.mod}
# Exclude the root module, if present, from the list of sub-modules.
GO_CHANGED_SUBMODULES=${GO_CHANGED_MODULES#./go.mod}

# Override to determine if all go tests should be run.
# Does not include static analysis checks.
RUN_ALL_TESTS="0"
# If this is a nightly test (not a PR), run all tests.
if [ -z "${KOKORO_GITHUB_PULL_REQUEST_NUMBER:-}" ]; then
  RUN_ALL_TESTS="1"
# If the change touches a repo-spanning file or directory of significance, run all tests.
elif echo "$SIGNIFICANT_CHANGES" | tr ' ' '\n' | grep "^go.mod$" || [[ $CHANGED_DIRS =~ "testing" || $CHANGED_DIRS =~ "internal" ]]; then
  RUN_ALL_TESTS="1"
fi

# Don't print environment variables in case there are secrets.
# If you need a secret, use a keystore_resource in common.cfg.
set +x

export GOLANG_SAMPLES_KMS_KEYRING=ring1
export GOLANG_SAMPLES_KMS_CRYPTOKEY=key1

export GOLANG_SAMPLES_IOT_PUB="$KOKORO_GFILE_DIR/rsa_cert.pem"
export GOLANG_SAMPLES_IOT_PRIV="$KOKORO_GFILE_DIR/rsa_private.pem"

export GCLOUD_ORGANIZATION=1081635000895
export SCC_PUBSUB_PROJECT="project-a-id"
export SCC_PUBSUB_TOPIC="projects/project-a-id/topics/notifications-sample-topic"
export SCC_PUBSUB_SUBSCRIPTION="notification-sample-subscription"

export GOLANG_SAMPLES_SPANNER=projects/golang-samples-tests/instances/golang-samples-tests
export GOLANG_SAMPLES_BIGTABLE_PROJECT=golang-samples-tests
export GOLANG_SAMPLES_BIGTABLE_INSTANCE=testing-instance

export GOLANG_SAMPLES_FIRESTORE_PROJECT=golang-samples-fire-0
export GOOGLE_API_USE_CLIENT_CERTIFICATE=true

echo $CREDENTIALS > ~/secret.json
export GOOGLE_APPLICATION_CREDENTIALS=~/secret.json

set -x

go install ./testing/sampletests

pwd

date

if [[ $KOKORO_BUILD_ARTIFACTS_SUBDIR = *"system-tests"* && -n $GOLANG_SAMPLES_GO_VET ]]; then
  echo "This test run will run end-to-end tests.";
  export GOLANG_SAMPLES_E2E_TEST=1
fi

export PATH="$PATH:/tmp/google-cloud-sdk/bin";
if [[ $KOKORO_BUILD_ARTIFACTS_SUBDIR = *"system-tests"* ]]; then
  ./testing/kokoro/configure_gcloud.bash;
fi

./testing/kokoro/mtls_smoketest.bash

date

echo "$GOOGLE_APPLICATION_CREDENTIALS"
echo "$CLIENT_CERTIFICATE"

echo "Setting up client cert"
mkdir -p ~/.secureConnect/
cp ./testing/kokoro/context_aware_metadata.json ~/.secureConnect/context_aware_metadata.json

# exit_code collects all of the exit codes of the tests, and is used to set the
# exit code at the end of the script.
exit_code=0
set +e # Don't exit on errors to make sure we run all tests.

# runTests runs the tests in the current directory. If an argument is specified,
# it is used as the argument to `go test`.
runTests() {
  set +x
  echo "Running 'go test' in '$(pwd)'..."
  set -x
  2>&1 go test -timeout $TIMEOUT -v "${1:-./...}"
  exit_code=$((exit_code + $?))
  set +x
}

# Returns 0 if the test should be skipped because the current Go
# version is too old for the current module.
goVersionShouldSkip() {
  modVersion="$(go list -m -f '{{.GoVersion}}')"
  if [ -z "$modVersion" ]; then
    # Not in a module or minimum Go version not specified, don't skip.
    return 1
  fi

  go list -f "{{context.ReleaseTags}}" | grep -q -v "go$modVersion\b"
}

if [[ $RUN_ALL_TESTS = "1" ]]; then
  echo "Running all tests"
  # shellcheck disable=SC2044
  for i in $(find . -name go.mod); do
    pushd "$(dirname "$i")" > /dev/null;
      runTests
    popd > /dev/null;
  done
elif [[ -z "${CHANGED_DIRS// }" ]]; then
  echo "Only running root tests"
  runTests .
else
  runTests . # Always run root tests.
  echo "Running tests in modified directories: $CHANGED_DIRS"
  for d in $CHANGED_DIRS; do
    mods=$(find "$d" -name go.mod)
    # If there are no modules, just run the tests directly.
    if [[ -z "$mods" ]]; then
      pushd "$d" > /dev/null;
        runTests
      popd > /dev/null;
    # Otherwise, run the tests in all Go directories. This way, we don't have to
    # check to see if there are tests that aren't in a sub-module.
    else
      goDirectories="$(find "$d" -name "*.go" -printf "%h\n" | sort -u)"
      if [[ -n "$goDirectories" ]]; then
        for gd in $goDirectories; do
          pushd "$gd" > /dev/null;
            runTests .
          popd > /dev/null;
        done
      fi
    fi
  done
fi

exit $exit_code
