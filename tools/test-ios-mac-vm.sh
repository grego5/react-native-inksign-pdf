#!/usr/bin/env bash
set -euo pipefail

# Run the focused iOS text interaction suite from a Mac, including when this
# script and source tree are reached through a VMware shared folder. Keep a
# Mac-local checkout and build cache; rsync updates only changed source files.
source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state="${INKSIGN_IOS_MAC_STATE:-$HOME/ios-validation}"
repo="$state/ios-text-interaction-plan-8811106b-local"
tooling="$state/tooling"
logs="$state/logs"
results="$state/results"
mkdir -p "$repo" "$tooling" "$logs" "$results"

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

echo "Syncing changed files into persistent Mac checkout: $repo"
rsync -a --delete --exclude='.git/' --exclude='node_modules/' \
  --exclude='/example/ios/' --exclude='/ios/Pods/' \
  --exclude='diagnostics/' --exclude='.DS_Store' "$source_root/" "$repo/"

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
npm install --no-package-lock --ignore-scripts --install-links --no-audit --no-fund
if [[ ! -f ios/Podfile || "${IOS_MAC_PREBUILD:-0}" == 1 ]]; then
  npx expo prebuild --platform ios --no-install
else
  echo 'Using the existing generated iOS project (set IOS_MAC_PREBUILD=1 to refresh it).'
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

gem_home="$tooling/gems"
system_gem_path="$(gem env path)"
export GEM_HOME="$gem_home"
export GEM_PATH="$GEM_HOME:$system_gem_path"
export PATH="$GEM_HOME/bin:$PATH"
if ! "$GEM_HOME/bin/bundle" _2.4.22_ --version >/dev/null 2>&1; then
  gem install bundler -v 2.4.22 --no-document --install-dir "$GEM_HOME" --bindir "$GEM_HOME/bin"
fi
cat > "$tooling/Gemfile" <<'GEMFILE'
source 'https://rubygems.org'
gem 'cocoapods', '1.16.2'
gem 'ffi', '1.17.1'
gem 'activesupport', '6.1.7.10'
gem 'logger', '1.3.0'
GEMFILE
export BUNDLE_GEMFILE="$tooling/Gemfile"
export BUNDLE_APP_CONFIG="$tooling/bundle-config"
tool_path="$GEM_HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset DEVELOPER_DIR
export PATH="$tool_path"
export LANG=en_US.UTF-8
export RUBYOPT=-rlogger
bundle _2.4.22_ install --path "$tooling/bundle"
export DEVELOPER_DIR="$developer_dir"
export PATH="$DEVELOPER_DIR/usr/bin:$node_bin:$tool_path"
bundle _2.4.22_ exec pod install --project-directory=ios

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

echo "Running $scheme/InkSignViewTextInteractionTests on simulator $simulator_id."
log="$logs/xcodebuild.log"
result_bundle="$results/text-interaction.xcresult"
rm -rf "$result_bundle"
if xcodebuild \
  -workspace "$workspace" \
  -scheme "$scheme" \
  -destination "platform=iOS Simulator,id=$simulator_id,arch=$(uname -m)" \
  -derivedDataPath "$state/derived-data" \
  -resultBundlePath "$result_bundle" \
  -only-testing:"$scheme/InkSignViewTextInteractionTests" \
  test > "$log" 2>&1; then
  grep -E 'Executed [0-9]+ tests|TEST SUCCEEDED|Result bundle written' "$log" | tail -20 || true
else
  grep -E -i 'error:|failed|Executed [0-9]+ tests|TEST FAILED' "$log" | tail -80 || tail -80 "$log"
  exit 1
fi
