#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

# Nimbus Feature Manifest Language Generator
#
# For more infomration, check out https://experimenter.info/fml-spec
#
# This script generates Swift definitions for all the experimentable features supported by Nimbus.
# It generates Swift code to be included in the final build.
#
# To use it in a Swift project, follow these steps:
# 1. Import the `nimbus-fml.sh` script into your project.
# 2. Edit the `nimbus-fml-configuration.sh` file to suit your project.
# 3. Add a `<NAME>.fml.yaml` feature manifest file. Check out https://experimenter.info/fml-spec for the spec.
# 4. Test the new file by running this file from SOURCE_ROOT.
# 5. Add a new "Run Script" build step and set the command to `bash $PWD/nimbus-fml.sh`.
# 6. Run the build.
# 7. Add the "FML.swift" file in the `Generated` folder to your project.
# 8. Add the same "FML.swift" from the `Generated` folder as Output Files of the newly created "Run Script" step.
# 9. Start using the generated feature code.
set -euo pipefail

DIRNAME=$(dirname "$0")

# CMDNAME is used in the usage text below.
# shellcheck disable=SC2034
CMDNAME=$(basename "$0")
USAGE=$(cat <<HEREDOC
${CMDNAME}

Nimbus Feature Manifest Language generator initializer.

This script generates the code needed to interact with Nimbus, exposing features which are experimentable.

For more infomration, check out https://experimenter.info/fml-spec

The script structure was adopted from the similar script "sdk_generator.sh" written by the Glean team.

This script should be executed as a "Run Build Script" phase from Xcode, but you can run it from the command line
if you define "PROJECT", "CONFIGURATION" and "SOURCE_ROOT" environment variables.

Application-specific configuration options for this script has moved to ./nimbus-fml-configuration.sh alongside this file.

Local developer specific configuration should go in ./nimbus-fml-configuration.local.sh and not checked into to source control.

USAGE:
    ${CMDNAME} [OPTIONS] [FILE]

OPTIONS:
    -a, --use-fml-version <REF>      Version or reference of nimbus-fml to use. If missing, derives from the project.pbxproj file.
    -F, --fresh                      Re-download the nimbus-fml binary.
    -h, --help                       display this help message.
HEREDOC
)

helptext() {
    echo "$USAGE"
}

# fail_trap is executed if an error occurs.
fail_trap() {
  local result=$1
  local line_number=$2
  echo "Error calling nimbus-fml.sh at line ${line_number}"
  exit "$result"
}

#Stop execution on any error
trap 'fail_trap $? $LINENO' ERR

if [ -z "${SOURCE_ROOT:-}" ] ; then
    echo "Warning: No \$SOURCE_ROOT defined."
    echo "  Execute this script as a build step in Xcode."
    echo "  Guessing it as CWD"
    SOURCE_ROOT="$(pwd)"
fi

if [ -z "${PROJECT:-}" ]; then
    echo "Warning: No \$PROJECT defined."
    echo "  Execute this script as a build step in Xcode."
    xcodeproj=$(ls -d "${SOURCE_ROOT}"/*.xcodeproj || exit 2 | head -n 1 )
    PROJECT=$(basename -s .xcodeproj "$xcodeproj")
    echo "  Detected it as $PROJECT"
fi

if [ -z "${CONFIGURATION:-}" ] ; then
    echo "Warning: No \$CONFIGURATION defined."
    echo "  Execute this script as a build step in Xcode."
    echo "  Guessing it as Debug"
    CONFIGURATION=Debug
fi

find_as_version() {
    # We can derive the version we need by looking at the project file.
    number_string=$(grep -A 3 $'https://github.com/mozilla/rust-components-swift' "$SOURCE_ROOT/$PROJECT.xcodeproj/project.pbxproj" | grep -E -o "\d+\.\d+\.\d+")

    if [ -z "$number_string" ]; then
        # If there is no rust-components then perhaps we're building with a local versions of rust_components, using rust_components_local.sh .
        # We try to resolve that, and find the version from the Package.swift file in that local directory.
        # https://github.com/mozilla-mobile/firefox-ios/issues/12243
        rust_components_path=$(grep -A 3 $'XCRemoteSwiftPackageReference "rust-components-swift"' "$SOURCE_ROOT/$PROJECT.xcodeproj/project.pbxproj" | grep 'repositoryURL = "file://' | grep -o -E '/\w[^"]+')
        number_string=$(grep 'let version =' "$rust_components_path/Package.swift" | grep -E -o "\d+\.0.\d+")
    fi

    if [ -z "$number_string" ]; then
        echo "Error: No https://github.com/mozilla/rust-components-swift package was detected."
        echo "The package must be added as a project dependency."
        exit 2
    fi

    AS_VERSION=${number_string//\.0\./\.} # rust-component-swift tags have a middle `.0.` to force it to align with spm. We remove it
}
FRESHEN_FML=
AS_VERSION=
MOZ_APPSERVICES_LOCAL=
REPO_FILES=
NIMBUS_DIR="$SOURCE_ROOT/build/nimbus"

export CACHE_DIR="$NIMBUS_DIR/fml-cache"
export APP_FML_FILE="$PROJECT/nimbus.fml.yaml"
export GENERATED_SRC_DIR=
export MOZ_APPSERVICES_MODULE=MozillaAppServices
export MODULES=$PROJECT

echo "Using $DIRNAME/nimbus-fml-configuration.sh as config"
# shellcheck disable=SC1091
source "$DIRNAME/nimbus-fml-configuration.sh"

local_config="$DIRNAME/nimbus-fml-configuration.local.sh"
if [ -f "$local_config" ] ; then
    echo "Modifying with $local_config"
    # shellcheck disable=SC1090
    source "$local_config"
fi

while (( "$#" )); do
    case "$1" in
        -o|--output)
            GENERATED_SRC_DIR=$2
            shift 2
            ;;
        -h|--help)
            helptext
            exit 0
            ;;
        -a|--use-fml-version)
            AS_VERSION=$2
            shift 2
            ;;
        -F|--fresh)
            FRESHEN_FML="true"
            shift 2
            ;;
        --verbose)
            set -x
            shift 1
            ;;
        --) # end argument parsing
            shift
            break
            ;;
        --*=|-*) # unsupported flags
            echo "Error: Unsupported flag $1" >&2
            exit 1
            ;;
        *) # preserve positional arguments
            APP_FML_FILE=$1
            shift
            ;;
    esac
done

if [ -z "$APP_FML_FILE" ]; then
    if [ -z "$SCRIPT_INPUT_FILE_COUNT" ] || [ "$SCRIPT_INPUT_FILE_COUNT" -eq 0 ]; then
        echo "Error: No input files provided for the Nimbus Feature Manifest."
        exit 2
    fi
    APP_FML_FILE=$SCRIPT_INPUT_FILE_0
fi

if [ -n "$MOZ_APPSERVICES_LOCAL" ] ; then
    # If we've specified where app-services lives, perhaps we can run from a local copy.
    LOCAL_FML_DIR="$MOZ_APPSERVICES_LOCAL/components/support/nimbus-fml"
    export BINARY_PATH="$HOME/.cargo/bin/cargo run --manifest-path $LOCAL_FML_DIR/Cargo.toml --"
else
    if [ -z "$AS_VERSION" ] ; then
        find_as_version
    fi

    # Otherwise, we should download a pre-built copy
    AS_DOWNLOAD_URL="https://archive.mozilla.org/pub/app-services/releases/$AS_VERSION"
    CHECKSUM_URL="$AS_DOWNLOAD_URL/nimbus-fml.sha256"
    FML_URL="$AS_DOWNLOAD_URL/nimbus-fml.zip"
    RELEASE_STATUS_CODE=$(curl -L --write-out '%{http_code}' --silent --output /dev/null "$CHECKSUM_URL" >/dev/null)
    if [ "$RELEASE_STATUS_CODE" != "200" ]; then
        AS_DOWNLOAD_URL="https://firefox-ci-tc.services.mozilla.com/api/index/v1/task/project.application-services.v2.nimbus-fml.$AS_VERSION/artifacts/public%2Fbuild%2F"
        CHECKSUM_URL="${AS_DOWNLOAD_URL}nimbus-fml.sha256"
        FML_URL="${AS_DOWNLOAD_URL}nimbus-fml.zip"
    fi
    FML_DIR="$NIMBUS_DIR/$AS_VERSION/bin"
    export BINARY_PATH="$FML_DIR/nimbus-fml"
    # Check whether the cached copy is still the right one to use.
    if [[ -f $FML_DIR/nimbus-fml.sha256 ]]; then
        echo "Checking if we need to redownload the FML"
        NEW_CHECKSUM=$(curl -L "$CHECKSUM_URL")
        OLD_CHECKSUM=$(cat "$FML_DIR/nimbus-fml.sha256")
        if [ ! "$OLD_CHECKSUM" == "$NEW_CHECKSUM" ]; then
            FRESHEN_FML="true"
            echo "The checksums don't match, redownloading the new FML"
        fi
    fi

    if [ -n "$FRESHEN_FML" ]; then
        rm -Rf "$FML_DIR"
    fi
    mkdir -p "$FML_DIR"
    if [[ ! -f "$FML_DIR/nimbus-fml.zip" ]] ; then
        echo "Downloading to $FML_DIR"
        # We now download the nimbus-fml from the github release
        curl -L "$FML_URL" --output "$FML_DIR/nimbus-fml.zip"
        # We also download the checksum
        curl -L "$CHECKSUM_URL" --output "$FML_DIR/nimbus-fml.sha256"
        pushd "${FML_DIR}" || exit 1
        shasum --check nimbus-fml.sha256
        popd
    fi

    ## We definitely have a zip file on disk, but we might already have done the work of unzipping it.
    if [[ ! -f "$BINARY_PATH" ]] ; then
        ## So we've looked and there's no executable file of that name
        ## Now work out what arch version of the executable we want.
        ARCH=$(uname -m)
        if [[ "$ARCH" == 'x86_64' ]]
        then
            EXE_ARCH=x86_64-apple-darwin
        elif [[ "$ARCH" == 'arm64' ]]
        then
            EXE_ARCH=aarch64-apple-darwin
        else
            echo "Error: Unsupported architecture. This script can only run on Mac devices running x86_64 or arm64"
            exit 2
        fi
        # -o overwrites a file (if the file existed but isn't executable)
        # -j junks the path, so we don't have to have $EXE_ARCH/release/ in our directory
        # -d outputs to the directory of our choice.
        unzip -o -j "$FML_DIR/nimbus-fml.zip" $EXE_ARCH/release/nimbus-fml -d "$FML_DIR"
    fi
fi

echo_eval() {
    local CMD="$*"
    # Truncating the absolute paths into something easier to read.
    local display=${CMD//"$SOURCE_ROOT"/\$SOURCE_ROOT}
    echo "$display"
    eval "$CMD"
}

echo "SOURCE_ROOT=$SOURCE_ROOT"
pushd "${SOURCE_ROOT}" > /dev/null || true
# We're going to assemble the repo args from the repo files that
repo_args=
for repo_file in $REPO_FILES ; do
    repo_args="$repo_args --repo-file $repo_file"
done

# Now validate the FML file. This will load the YAML and print warnings or errors for each channel.
echo_eval "$BINARY_PATH validate $repo_args --cache-dir $CACHE_DIR $APP_FML_FILE"

# We'll generate the command, and output some nice copy/pastable version of the command to the Build console…
for module in $MODULES ; do
    output_dir=""
    input_pattern="$module"
    output_dir=${GENERATED_SRC_DIR:-"${module}/Generated"}
    # If $module is a file, then set the output directory to $PROJECT/Generated
    # otherwise,
    if [ -f "$module" ] ; then
        output_dir="$PROJECT/Generated"
    fi

    mkdir -p "$output_dir"
    echo_eval "$BINARY_PATH generate $repo_args --channel $CHANNEL --language swift --cache-dir $CACHE_DIR $input_pattern $output_dir"
done
popd > /dev/null || exit 0