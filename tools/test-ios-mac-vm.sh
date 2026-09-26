#!/usr/bin/env bash
set -euo pipefail

# Run the focused iOS text interaction suite from a Mac, including when this
# script and source tree are reached through a VMware shared folder. Keep a
# Mac-local checkout and build cache; checksum source files while syncing.
source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state="${IOS_STATE:-$HOME/projects/react-native-inksign-pdf}"
repo="$state/checkout"
tooling="$state/tooling"
logs="$state/logs"
results="$state/results"
mkdir -p "$repo" "$tooling" "$logs" "$results"
result_name="${IOS_RESULT_NAME:-text-interaction}"
log="$logs/$result_name.log"
exec 3>&1
: > "$log"
exec >> "$log" 2>&1

progress() {
  printf '%s\n' "$*" >&3
}

report_failure() {
  exit_code=$?
  trap - EXIT
  if [[ "$exit_code" -ne 0 ]]; then
    printf 'iOS test runner failed (exit %s). Full log: %s\n' "$exit_code" "$log" >&3
    python3 "$source_root/tools/summarize-ios-test-log.py" "$log" >&3 || true
  fi
  exit "$exit_code"
}
trap report_failure EXIT

ruby_bin="${IOS_RUBY_BIN:-}"
if [[ -z "$ruby_bin" && -x /opt/local/bin/ruby ]]; then
  ruby_bin=/opt/local/bin
fi
if [[ -n "$ruby_bin" ]]; then export PATH="$ruby_bin:$PATH"; fi
ruby_version="$(ruby -e 'print RUBY_VERSION')"

developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if ! DEVELOPER_DIR="$developer_dir" xcrun simctl list devices available >/dev/null 2>&1; then
  developer_dir=""
  for candidate in /Applications/Xcode*.app/Contents/Developer "$HOME"/Downloads/Xcode*.app/Contents/Developer; do
    if [[ -x "$candidate/usr/bin/xcodebuild" ]] &&
       DEVELOPER_DIR="$candidate" xcrun simctl list devices available >/dev/null 2>&1; then
      developer_dir="$candidate"
      break
    fi
  done
fi
if [[ -z "$developer_dir" ]]; then
  echo "Xcode with an available iOS Simulator runtime was not found. Set DEVELOPER_DIR." >&2
  exit 1
fi
export DEVELOPER_DIR="$developer_dir"
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"

if [[ -x /opt/local/bin/rsync ]]; then
  rsync_bin=/opt/local/bin/rsync
else
  rsync_bin="$(command -v rsync)"
fi
if [[ "${IOS_SKIP_SYNC:-0}" == 1 ]]; then
  progress "Using the existing Mac-local checkout without source sync: $repo"
else
  progress "Syncing changed files into the Mac-local checkout: $repo"
  "$rsync_bin" -ac --delete --exclude='.git/' --exclude='node_modules/' \
    --exclude='/example/ios/' --exclude='/example/android/' \
    --exclude='/example/.expo/' --exclude='/example/ios/Pods/' \
    --exclude='/android/build/' --exclude='/android/.gradle/' \
    --exclude='/android/.cxx/' --exclude='/build/' --exclude='/coverage/' \
    --exclude='/ios/Pods/' \
    --exclude='/diagnostics/***' --exclude='.DS_Store' "$source_root/" "$repo/"
fi

if [[ -z "${INKSIGN_PDF_TEST_FIXTURES:-}" ]]; then
  fixture_source_root="$source_root"
  if [[ "${IOS_SKIP_SYNC:-0}" == 1 ]]; then
    fixture_source_root="$repo"
  fi
  fixture_dir="$repo/diagnostics"
  mkdir -p "$fixture_dir"
  if [[ "$fixture_source_root" != "$repo" ]]; then
    for fixture in 'RaDaLqz0kjfZbrgDjeEd.pdf' 'גיל אייזנברג 3206.pdf'; do
      if [[ -f "$fixture_source_root/diagnostics/$fixture" ]]; then
        cp -f "$fixture_source_root/diagnostics/$fixture" "$fixture_dir/$fixture"
      else
        rm -f "$fixture_dir/$fixture"
      fi
    done
  fi
  export INKSIGN_PDF_TEST_FIXTURES="$fixture_dir"
fi

node_version="${NODE_VERSION:-22.23.3}"
node_arch="$(uname -m)"
case "$node_arch" in
  x86_64) node_arch=x64 ;;
  arm64) node_arch=arm64 ;;
  *) echo "Unsupported Mac architecture: $node_arch" >&2; exit 1 ;;
esac
node_root="$tooling/node-v${node_version}-darwin-${node_arch}"
if ! command -v node >/dev/null 2>&1 || [[ "$(node --version)" != v22.* ]]; then
  archive="node-v${node_version}-darwin-${node_arch}.tar.gz"
  if [[ ! -x "$node_root/bin/node" ]]; then
    curl -fsSL "https://nodejs.org/dist/v${node_version}/${archive}" -o "$tooling/$archive"
    curl -fsSL "https://nodejs.org/dist/v${node_version}/SHASUMS256.txt" -o "$tooling/SHASUMS256.txt"
    grep "${archive}$" "$tooling/SHASUMS256.txt" | (cd "$tooling" && shasum -a 256 -c -)
    tar -xzf "$tooling/$archive" -C "$tooling"
  fi
  export PATH="$node_root/bin:$PATH"
fi
node_bin="$(dirname "$(command -v node)")"

cd "$repo/example"
npm pkg set 'dependencies.@grego5/react-native-inksign-pdf=file:..'
if [[ "${IOS_NPM_INSTALL:-0}" == 1 || ! -d node_modules/react-native || \
      ! -f node_modules/expo/package.json ]]; then
  npm install --no-package-lock --ignore-scripts --install-links --no-audit --no-fund
else
  progress 'Using existing npm dependencies (set IOS_NPM_INSTALL=1 to refresh them).'
fi
linked_package="$repo/example/node_modules/@grego5/react-native-inksign-pdf"
rm -rf "$linked_package"
ln -s "$repo" "$linked_package"
if [[ ! -f ios/Podfile || "${IOS_PREBUILD:-0}" == 1 ]]; then
  npx expo prebuild --platform ios --no-install
else
  progress 'Using the existing generated iOS project (set IOS_PREBUILD=1 to refresh it).'
fi

podfile="$repo/example/ios/Podfile"
ruby - "$podfile" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
declaration = "  pod 'ReactNativeInkSignPdf', :path => '../node_modules/@grego5/react-native-inksign-pdf', :testspecs => ['LifecycleTests']\n"
unless text.include?(declaration)
  abort 'LifecycleTests test spec has a conflicting Podfile declaration' if text.include?(":testspecs => ['LifecycleTests']")
  updated = text.sub(/target [^\n]+ do\n/, "\\0#{declaration}")
  abort 'Could not find an application target in the generated Podfile' if updated == text
  File.write(path, updated)
end
RUBY

ios_source_manifest="$(find ../ios -type f \( -name '*.swift' -o -name '*.m' -o -name '*.mm' -o -name '*.h' \) -print | LC_ALL=C sort | shasum -a 256 | awk '{print $1}')"
pod_fingerprint="$(
  {
    printf '%s\n' "$ios_source_manifest"
    shasum -a 256 ios/Podfile ../ReactNativeInkSignPdf.podspec package.json
  } | shasum -a 256 | awk '{print $1}'
)"
pod_fingerprint_file="$tooling/pod-manifest.sha256"
if [[ "${IOS_POD_INSTALL:-0}" == 1 || ! -f ios/Pods/Manifest.lock || \
      ! -f "$pod_fingerprint_file" || "$(cat "$pod_fingerprint_file")" != "$pod_fingerprint" ]]; then
  gem_home="$tooling/ruby-$ruby_version/gems"
  mkdir -p "$gem_home"
  system_gem_path="$(gem env path)"
  export GEM_HOME="$gem_home"
  export GEM_PATH="$GEM_HOME:$system_gem_path"
  # Ruby 4 ships logger as a separate gem. Bundler narrows GEM_PATH while
  # building native extensions, so resolve the file before Bundler and preload
  # it by absolute path.
  logger_path="$("$ruby_bin/ruby" -e 'print Gem.find_files("logger.rb").first')"
  if [[ -z "$logger_path" ]]; then
    gem install logger --no-document
    logger_path="$(find "$GEM_HOME" -path '*/logger-*/lib/logger.rb' -print -quit)"
  fi
  export PATH="$GEM_HOME/bin:$PATH"
  bundle_path="$tooling/ruby-$ruby_version/bundle"
  gemfile="$tooling/ruby-$ruby_version/Gemfile"
cat > "$gemfile" <<'GEMFILE'
source 'https://rubygems.org'
gem 'cocoapods'
gem 'bigdecimal'
gem 'benchmark'
GEMFILE
  export BUNDLE_GEMFILE="$gemfile"
  export BUNDLE_APP_CONFIG="$tooling/ruby-$ruby_version/bundle-config"
  if [[ "$ruby_bin" == /usr/bin ]]; then
    unset BUNDLE_PATH
  else
    export BUNDLE_PATH="$bundle_path"
  fi
  # This runner's lockfile is local Mac tooling state; use the installed
  # Bundler instead of downloading a version pinned by a stale local lock.
  export BUNDLE_VERSION=system
  tool_path="$GEM_HOME/bin:$ruby_bin:/opt/local/bin:/opt/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
  unset DEVELOPER_DIR
  export PATH="$tool_path"
  export LANG=en_US.UTF-8
  if [[ -z "$logger_path" ]]; then
    echo 'Ruby logger gem was not found.' >&2
    exit 1
  fi
  export RUBYOPT="-r$logger_path"
  if [[ "${IOS_POD_INSTALL:-0}" == 1 && -f "$gemfile.lock" ]]; then
    bundle update cocoapods
  else
    bundle install
  fi
  export DEVELOPER_DIR="$developer_dir"
  export PATH="$DEVELOPER_DIR/usr/bin:$node_bin:$tool_path"
  bundle exec pod install --project-directory=ios
  printf '%s\n' "$pod_fingerprint" > "$pod_fingerprint_file"
else
  progress 'Using existing CocoaPods installation (set IOS_POD_INSTALL=1 to refresh it).'
fi

workspace="$(find ios -maxdepth 1 -type d -name '*.xcworkspace' -print -quit)"
if [[ -z "$workspace" ]]; then
  echo "No Xcode workspace found under $repo/example/ios." >&2
  exit 1
fi
xcodebuild -list -json -workspace "$workspace" > "$tooling/workspace-list.json"
scheme="$(python3 - "$tooling/workspace-list.json" <<'PY'
import json, sys
schemes = json.load(open(sys.argv[1]))['workspace']['schemes']
print(next((item for item in schemes if item.endswith('LifecycleTests')), ''))
PY
)"
if [[ -z "$scheme" ]]; then
  echo "No LifecycleTests scheme exists in $workspace." >&2
  exit 1
fi
simulator_id="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; devices=[d for group in json.load(sys.stdin)["devices"].values() for d in group if d.get("isAvailable") and d.get("name", "").startswith("iPhone")]; print(sorted(devices,key=lambda d:(d["name"],d["udid"]))[0]["udid"] if devices else "")')"
if [[ -z "$simulator_id" ]]; then
  echo "No available iPhone simulator is installed." >&2
  exit 1
fi

progress "Running focused placement, text, lifecycle, and PDF navigation tests on simulator $simulator_id."
result_bundle="$results/$result_name.xcresult"
rm -rf "$result_bundle"
test_selection=(
  -only-testing:"$scheme/InkSignViewTextInteractionTests"
  -only-testing:"$scheme/InkSignViewLifecycleTests"
  -only-testing:"$scheme/InkSignViewPDFNavigationTests"
  -only-testing:"$scheme/PlacementRuleDetectorTests"
)
if [[ -n "${IOS_TEST_ONLY:-}" ]]; then
  test_identifier="$IOS_TEST_ONLY"
  if [[ "$test_identifier" != */* && "$test_identifier" != *Tests ]]; then
    test_identifier="InkSignViewTextInteractionTests/$test_identifier"
  fi
  test_selection=(-only-testing:"$scheme/$test_identifier")
fi
if xcodebuild \
  -workspace "$workspace" \
  -scheme "$scheme" \
  -destination "platform=iOS Simulator,id=$simulator_id,arch=$(uname -m)" \
  -derivedDataPath "$state/derived-data" \
  -resultBundlePath "$result_bundle" \
  "${test_selection[@]}" \
  test; then
  if ! grep -Eq "^Test Case .* (passed|failed|skipped) \\(" "$log"; then
    echo "Xcode reported success without executing any XCTest cases. Check IOS_TEST_ONLY." >&2
    exit 1
  fi
  case_count="$(grep -Ec "^Test Case .* (passed|failed|skipped) \\(" "$log" || true)"
  progress "Completed $case_count XCTest cases. Full log: $log"
  grep -E 'Executed [0-9]+ tests|TEST SUCCEEDED|Result bundle written' "$log" | tail -20 >&3 || true
else
  exit 1
fi
